#!/usr/bin/env bash
# =============================================================================
# Reprobuild dependency pins — every sibling this repo's `repro.lock` pins that
# reprobuild ALSO pins (a root input of the `flake.lock` of the reprobuild
# revision this repo is locked against) must be pinned here at reprobuild's
# revision or at a DESCENDANT of it. Behind, or diverged, fails.
#
# ## Why
#
# The pre-push gate (`committed_lock_dependency_set_unverified`) compiles
# `repro.nim`'s interface against the develop-mode siblings: `../reprobuild` at
# the reprobuild revision this repo pins, and every other sibling at THIS
# repo's `repro.lock` pin. reprobuild is therefore compiled against this repo's
# pins of its own dependencies, not against the pins reprobuild was developed
# and locked with. When a reprobuild bump needs a newer dependency and the
# bump does not move this repo's pin of that dependency along with it, the
# interface compile fails inside reprobuild's sources, and no push can pass.
#
# That is exactly what happened when a7f34bb5a moved `reprobuild` to
# 2f7cb5db52 (0.2.31). That reprobuild's flake.lock pins `nim-shm-gset-src` at
# fc0c74478d, because `libs/repro_local_store/src/repro_local_store/
# action_index.nim:746` calls `insertShardIndex`, which first exists in
# nim-shm-gset after 0b2896a. This repo still pinned nim-shm-gset at 0b2896a,
# and every gate run died with
#
#     …/reprobuild/libs/repro_local_store/src/repro_local_store/action_index.nim(746, 16)
#       Error: attempting to call undeclared routine: 'insertShardIndex'
#
# (codetracer-pm issues/2026-11-22-reprobuild-0-2-31-bump-leaves-the-nim-shm-
# gset-pin-behind-so-no-agents-push-passes-the-gate.md). The gate's other
# findings (`flake_lock_stale`, `committed_lock_sibling_pin_stale`) insist the
# sibling checkout sits AT this repo's pin, so the only way out is to move the
# pin, which is what this check asks for, before anybody pushes.
#
# ## The rule
#
# A sibling is compared when its `repro.lock` URL names the same repository
# (host/owner/repo, case-insensitive, `.git` stripped) as a root input of
# reprobuild's flake.lock — `github` inputs by owner/repo, `git` inputs by
# their url — or as a vcs entry of reprobuild's own repro.lock (reported as
# `repro.lock:<name>`). Matching is by REPOSITORY, never by name: this repo's
# `nim-stew` is metacraft-labs' fork, reprobuild's `nim-stew-src` is
# status-im's, and those are different pins, not a mismatch. This repo's own
# entry (`self = "true"`) is never compared.
#
# EQUAL or DESCENDANT passes: a newer dependency is what this repo is entitled
# to choose for its own reasons, and the libraries involved keep their API
# additive. BEHIND fails (the motivating case). DIVERGED fails too: neither
# side then carries the other's changes, and reprobuild may need a commit this
# pin lacks.
#
# Ancestry is asked of the sibling checkout `<workspace>/<repo.lock name>`.
#
# ## Static, and loud when it cannot run
#
# It reads two flake.locks and one repro.lock and asks git about ancestry: no
# toolchain, no network, well under a second, so it sits in `just test`.
#
# It needs checkouts it cannot synthesise: reprobuild (for that revision's
# flake.lock) and each compared sibling holding both revisions. When one is
# missing this script prints a SKIP naming it and the command that fixes it.
# A SKIP never counts as a pass: every sibling it could check is still
# checked, a real failure still fails, and a run with any SKIP says it did NOT
# verify everything. Set CT_REPROBUILD_DEPENDENCY_PINS_STRICT=1 to turn skips
# into failures, which is what a lane with a guaranteed workspace should do.
#
# Overrides: CT_REPROBUILD_CHECKOUT (the reprobuild checkout), CT_WORKSPACE_ROOT
# (where the other siblings live; default: the nearest directory above this
# checkout that holds `repro-workspace.toml`, else the main worktree's
# parent, else this checkout's parent).
# =============================================================================
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
STRICT="${CT_REPROBUILD_DEPENDENCY_PINS_STRICT:-0}"

# The workspace root the siblings live in. A checkout is not always a direct
# child of it: linked worktrees live wherever their author put them (e.g.
# `<workspace>/fixes/<name>`), and taking "the parent directory" there finds
# no reprobuild and turns the whole check into a SKIP that `just test` reports
# as success. So, in order:
#   1. CT_WORKSPACE_ROOT, when set;
#   2. the nearest directory above this checkout that holds
#      `repro-workspace.toml`, the file that marks a reprobuild workspace root;
#   3. the parent of this repository's MAIN worktree, for a linked worktree
#      (the pre-push gate also resolves siblings against the main checkout);
#   4. this checkout's parent directory.
find_marked_root() { # <dir> -> the nearest ancestor holding repro-workspace.toml
	local dir="$1"
	while [ -n "$dir" ] && [ "$dir" != "/" ]; do
		if [ -f "$dir/repro-workspace.toml" ]; then
			printf '%s\n' "$dir"
			return 0
		fi
		dir="$(dirname "$dir")"
	done
	return 1
}

resolve_workspace_root() {
	local common main top
	if [ -n "${CT_WORKSPACE_ROOT:-}" ]; then
		printf '%s\n' "$CT_WORKSPACE_ROOT"
		return 0
	fi
	find_marked_root "$(dirname "$REPO_ROOT")" && return 0
	# `--git-common-dir` is the main worktree's `.git` for a linked worktree.
	# Only when this checkout IS a git work tree's top level: an exported copy
	# that happens to sit inside some other repository must not adopt it.
	top="$(git -C "$REPO_ROOT" rev-parse --show-toplevel 2>/dev/null)" || top=""
	common="$(git -C "$REPO_ROOT" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" || common=""
	if [ -n "$top" ] && [ "$(cd "$top" && pwd -P)" = "$(cd "$REPO_ROOT" && pwd -P)" ] &&
		[ -n "$common" ] && [ "$(basename "$common")" = ".git" ]; then
		main="$(dirname "$common")"
		dirname "$main"
		return 0
	fi
	dirname "$REPO_ROOT"
}
WORKSPACE_ROOT="$(resolve_workspace_root)"

fail() {
	echo "FAIL: $*" >&2
	exit 1
}

# A skip of the WHOLE check: nothing could be compared.
skip() {
	if [ "$STRICT" = "1" ]; then
		echo "FAIL (CT_REPROBUILD_DEPENDENCY_PINS_STRICT=1): $*" >&2
		exit 1
	fi
	echo "SKIP: $*" >&2
	echo "SKIP: reprobuild dependency pins were NOT verified by this run." >&2
	exit 0
}

# Both locks are structured data and are read with real parsers (json,
# tomllib) on purpose. A missing python3 is a HARD FAILURE THAT NAMES ITSELF,
# never a fallback to grep and never an empty answer that a later line would
# turn into an accusation against a correct lock — the false-attribution
# defect scripts/test-flake-pin-alignment.sh documents and was fixed for.
command -v python3 >/dev/null 2>&1 || fail \
	"python3 is required to read flake.lock (JSON) and repro.lock (TOML) and is not on PATH. This check does NOT fall back to grepping the locks, because a confidently wrong revision is worse than no answer. Run it inside the dev shell (\`nix develop '.?submodules=1#ci' --command just test-reprobuild-dependency-pins\`), or put python3 on PATH. NOTHING about the pins has been established by this run."

# <flake.lock> <input> -> locked.rev of that ROOT input, or empty when the
# root has no such input. Resolved through `nodes.root.inputs` and follows
# paths, never by node key: node keys are labels nix suffixes with `_2`, `_3`
# when two flakes in the closure share an input name, so a bare key lookup can
# answer with a nested flake's homonym (see scripts/test-flake-pin-alignment.sh
# for the measured case). A file that cannot be parsed is a FAILURE that says
# so, distinct from the empty "no such input" answer.
lock_rev() {
	local out rc
	# shellcheck disable=SC2016
	out="$(python3 -c '
import json, sys
with open(sys.argv[1]) as handle:
    nodes = json.load(handle)["nodes"]

def resolve(start, path):
    current = start
    for segment in path:
        edge = nodes[current]["inputs"][segment]
        current = resolve("root", edge) if isinstance(edge, list) else edge
    return current

name = sys.argv[2]
if name not in nodes.get("root", {}).get("inputs", {}):
    print("")
else:
    node = nodes.get(resolve("root", [name]))
    print(node.get("locked", {}).get("rev", "") if node else "")
' "$1" "$2" 2>&1)"
	rc=$?
	[ "$rc" -eq 0 ] || fail \
		"could not read '$1' as a flake.lock (python3 exited $rc). This is a parse failure, NOT a statement about any pin. Parser output:
$out"
	printf '%s\n' "$out"
}

CT_FLAKE_LOCK="$REPO_ROOT/flake.lock"
CT_REPRO_LOCK="$REPO_ROOT/repro.lock"
[ -f "$CT_FLAKE_LOCK" ] || fail "$CT_FLAKE_LOCK does not exist; this script must run inside the codetracer checkout."
[ -f "$CT_REPRO_LOCK" ] || fail "$CT_REPRO_LOCK does not exist; this script must run inside the codetracer checkout."

# `|| exit 1` is load-bearing: `lock_rev` runs in a command substitution, so
# its `fail` exits only that subshell. Without it, a parse failure would be
# followed by the "no locked rev" accusation below.
REPROBUILD_REV="$(lock_rev "$CT_FLAKE_LOCK" reprobuild)" || exit 1
[ -n "$REPROBUILD_REV" ] || fail "flake.lock has no locked rev for input 'reprobuild'. If the input was renamed or dropped, update this check (scripts/test-reprobuild-dependency-pins.sh) to match."

REPROBUILD_DIR="${CT_REPROBUILD_CHECKOUT:-$WORKSPACE_ROOT/reprobuild}"
[ -e "$REPROBUILD_DIR/.git" ] || skip "no reprobuild checkout at $REPROBUILD_DIR (set CT_REPROBUILD_CHECKOUT, or clone it beside this repo) — cannot read the flake.lock of reprobuild@${REPROBUILD_REV}."
git -C "$REPROBUILD_DIR" cat-file -e "${REPROBUILD_REV}^{commit}" 2>/dev/null ||
	skip "reprobuild checkout at $REPROBUILD_DIR does not have revision ${REPROBUILD_REV}. Run: git -C '$REPROBUILD_DIR' fetch origin ${REPROBUILD_REV}"

RB_LOCK_TMP="$(mktemp)"
RB_REPRO_LOCK_TMP="$(mktemp)"
trap 'rm -f "$RB_LOCK_TMP" "$RB_REPRO_LOCK_TMP"' EXIT HUP INT TERM
git -C "$REPROBUILD_DIR" show "${REPROBUILD_REV}:flake.lock" >"$RB_LOCK_TMP" 2>/dev/null ||
	fail "reprobuild@${REPROBUILD_REV} has no flake.lock. Its dependency pins cannot be read; re-examine this check."
# reprobuild's own repro.lock is its develop set, and it names siblings its
# flake.lock does not (reprobuild-packages, measured at 2f7cb5db52), while the
# flake.lock names some the repro.lock does not (io-mon, nim-shm-gset). Both
# are read. An absent repro.lock (older revisions) leaves the file empty, and
# an empty file contributes no pins.
git -C "$REPROBUILD_DIR" show "${REPROBUILD_REV}:repro.lock" >"$RB_REPRO_LOCK_TMP" 2>/dev/null ||
	: >"$RB_REPRO_LOCK_TMP"

# The pairs to compare, one per line:
#   <repro.lock name> <this repo's rev> <reprobuild input> <reprobuild's rev> <owner/repo>
# Exit 2 = a file could not be parsed (the message says which); nothing else
# is a verdict about a pin.
# shellcheck disable=SC2016
PAIRS="$(python3 -c '
import json, re, sys

ct_repro_path, rb_flake_path, rb_repro_path = sys.argv[1], sys.argv[2], sys.argv[3]

def parse_failure(path, kind, err):
    print(f"could not read {path!r} as a {kind}: {err}. This is a parse failure, NOT a statement about any pin.")
    sys.exit(2)

try:
    import tomllib
except ImportError:
    print("python3 has no tomllib (it needs Python >= 3.11) and repro.lock is TOML. Run inside the dev shell. NOTHING about the pins has been established by this run.")
    sys.exit(2)

def repo_key(url):
    """https://github.com/Owner/Repo(.git) or git+https://... -> host/owner/repo."""
    m = re.match(r"^(?:git\+)?(?:https?|ssh)://(?:[^@/]+@)?([^/]+)/([^/]+)/([^/?#]+?)(?:\.git)?/?(?:[?#].*)?$", url or "")
    return "/".join(p.lower() for p in m.groups()) if m else None

try:
    with open(ct_repro_path, "rb") as handle:
        repro = tomllib.load(handle)
    deps = repro["lock"]["deps"]
    if not isinstance(deps, list):
        raise ValueError("lock.deps is not an array")
except (OSError, ValueError, KeyError, TypeError) as err:
    parse_failure(ct_repro_path, "repro.lock (lock.deps)", err)

try:
    with open(rb_flake_path) as handle:
        nodes = json.load(handle)["nodes"]

    def resolve(start, path):
        current = start
        for segment in path:
            edge = nodes[current]["inputs"][segment]
            current = resolve("root", edge) if isinstance(edge, list) else edge
        return current

    rb_pins = {}
    for name in nodes["root"]["inputs"]:
        locked = nodes[resolve("root", [name])].get("locked", {})
        if locked.get("type") == "github":
            key = repo_key("https://github.com/%s/%s" % (locked.get("owner", ""), locked.get("repo", "")))
        elif locked.get("type") == "git":
            key = repo_key(locked.get("url", ""))
        else:
            continue
        if key and locked.get("rev"):
            rb_pins.setdefault(key, []).append((name, locked["rev"]))
except (OSError, ValueError, KeyError, TypeError, RecursionError) as err:
    parse_failure("reprobuild flake.lock", "flake.lock", err)

try:
    with open(rb_repro_path, "rb") as handle:
        rb_repro = tomllib.load(handle)
    rb_deps = rb_repro.get("lock", {}).get("deps", []) if rb_repro else []
    if not isinstance(rb_deps, list):
        raise ValueError("lock.deps is not an array")
    for dep in rb_deps:
        if not isinstance(dep, dict) or dep.get("coord_kind") != "vcs" or dep.get("self") == "true":
            continue
        key, rev = repo_key(dep.get("url", "")), dep.get("revision", "")
        if key and rev and rev not in [r for _, r in rb_pins.get(key, [])]:
            rb_pins.setdefault(key, []).append(("repro.lock:" + dep.get("name", "?"), rev))
except (OSError, ValueError, KeyError, TypeError, AttributeError) as err:
    parse_failure("reprobuild repro.lock", "repro.lock (lock.deps)", err)

for dep in deps:
    if not isinstance(dep, dict) or dep.get("coord_kind") != "vcs" or dep.get("self") == "true":
        continue
    key = repo_key(dep.get("url", ""))
    for rb_name, rb_rev in rb_pins.get(key, []):
        print(dep.get("name", "?"), dep.get("revision", "") or "-", rb_name, rb_rev, key)
' "$CT_REPRO_LOCK" "$RB_LOCK_TMP" "$RB_REPRO_LOCK_TMP" 2>&1)" || fail "$PAIRS"

echo "reprobuild pinned here: ${REPROBUILD_REV}"
echo "workspace root: ${WORKSPACE_ROOT}"
[ -n "$PAIRS" ] || fail "no sibling in repro.lock names a repository that reprobuild@${REPROBUILD_REV}'s flake.lock also pins. reprobuild has always shared some (io-mon, nim-shm-queue, …), so the lock layout this check reads has probably changed; re-examine scripts/test-reprobuild-dependency-pins.sh."

failures=()
skips=()
checked=0
while read -r name ct_rev rb_input rb_rev key; do
	[ -n "$name" ] || continue
	label="$name ($key)"
	if [ "$ct_rev" = "-" ]; then
		failures+=("$label: repro.lock records no revision for it, while reprobuild@${REPROBUILD_REV} pins $rb_rev ($rb_input). Run: repro lock update $name --repo-root=$REPO_ROOT --to $rb_rev")
		continue
	fi
	if [ "$ct_rev" = "$rb_rev" ]; then
		echo "  ok   $label: $ct_rev (equal to reprobuild's $rb_input)"
		checked=$((checked + 1))
		continue
	fi
	dir="$WORKSPACE_ROOT/$name"
	if [ ! -e "$dir/.git" ]; then
		skips+=("$label: no checkout at $dir (clone it beside this repo, or set CT_WORKSPACE_ROOT) — cannot tell whether $ct_rev descends from reprobuild's $rb_rev.")
		continue
	fi
	missing=""
	for rev in "$ct_rev" "$rb_rev"; do
		git -C "$dir" cat-file -e "${rev}^{commit}" 2>/dev/null || missing="$missing $rev"
	done
	if [ -n "$missing" ]; then
		skips+=("$label: checkout at $dir lacks revision(s)$missing. Run: git -C '$dir' fetch origin$missing")
		continue
	fi
	if git -C "$dir" merge-base --is-ancestor "$rb_rev" "$ct_rev"; then
		echo "  ok   $label: $ct_rev (descends from reprobuild's $rb_input $rb_rev)"
		checked=$((checked + 1))
	elif git -C "$dir" merge-base --is-ancestor "$ct_rev" "$rb_rev"; then
		failures+=("$label is BEHIND reprobuild's pin.
         repro.lock here:                     $ct_rev
         reprobuild@${REPROBUILD_REV} $rb_input: $rb_rev
       reprobuild is compiled against this repo's pin in develop mode, so it
       would be built against an older $name than it was locked with.
       Run: repro lock update $name --repo-root=$REPO_ROOT --to $rb_rev")
	else
		failures+=("$label has DIVERGED from reprobuild's pin (neither revision contains the other).
         repro.lock here:                     $ct_rev
         reprobuild@${REPROBUILD_REV} $rb_input: $rb_rev
       reprobuild may need a commit this pin lacks. Move this pin to a
       revision that contains both, e.g. after merging them in $name:
       Run: repro lock update $name --repo-root=$REPO_ROOT --to <rev containing $rb_rev and $ct_rev>")
	fi
done <<<"$PAIRS"

for s in "${skips[@]}"; do
	if [ "$STRICT" = "1" ]; then
		failures+=("(CT_REPROBUILD_DEPENDENCY_PINS_STRICT=1) not verified: $s")
	else
		echo "SKIP: $s" >&2
	fi
done

if [ "${#failures[@]}" -gt 0 ]; then
	for f in "${failures[@]}"; do
		echo "FAIL: $f" >&2
	done
	echo "FAIL: ${#failures[@]} sibling pin(s) here cannot build reprobuild@${REPROBUILD_REV} (see scripts/test-reprobuild-dependency-pins.sh)." >&2
	exit 1
fi

if [ "${#skips[@]}" -gt 0 ]; then
	echo "SKIP: reprobuild dependency pins were NOT fully verified by this run (${checked} checked, ${#skips[@]} skipped)." >&2
	exit 0
fi

echo "OK: all ${checked} sibling pin(s) shared with reprobuild@${REPROBUILD_REV} are at or ahead of its pins."
exit 0
