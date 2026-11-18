#!/usr/bin/env bash
# =============================================================================
# Flake pin alignment — this repo's `runquota` and the `runquota-src` its
# `reprobuild` was locked against must be on the SAME reprobuild-packages
# catalog, and reprobuild must still be compiled against its own runquota.
#
# ## The two hazards
#
# 1. reprobuild COMPILES AGAINST runquota's sources. `flake.nix` once
#    overrode reprobuild's own input (`inputs.runquota-src.follows =
#    "runquota"`), so bumping reprobuild compiled it against a runquota it was
#    never developed against. Commit c9cb186c did exactly that, and `nix
#    develop` died minutes in with
#
#        libs/repro_runquota/src/repro_runquota.nim(932, 18)
#          Error: undeclared identifier: 'ExtensionCellWire'
#
#    (and, moved the other way, `'LeaseFinishOutcome'`). Ahead breaks exactly
#    as behind does. The fix is that reprobuild's `runquota-src` is never
#    overridden from here; this script fails if the locked graph shows it
#    overridden, and ci/test/dev-env-flake-metadata-test.sh fails if
#    flake.nix declares the override.
#
# 2. reprobuild compiles a SOLVE against one reprobuild-packages catalog and
#    refuses a closure that resolves catalog interfaces from two. This repo
#    used to derive its runquota from reprobuild (`runquota.follows =
#    "reprobuild/runquota-src"`). That runquota's own repro.lock was on catalog
#    15ceea67 while repro.lock here was on a newer one, so every refresh and
#    platform re-solve of repro.lock failed. flake.nix now pins runquota as
#    its own input, on this repo's catalog. That reopens a gap the follows edge
#    had closed: the `repro` client these shells ship is built against
#    reprobuild's runquota-src, the `runquotad` and `runquota_process` they
#    ship come from this runquota. So this script compares the CATALOGS the
#    two runquota revisions' locks pin, and fails when they differ.
#
# ## Known mismatches
#
# A pair whose catalogs differ is allowed only when it is recorded, exactly,
# in ci/runquota-catalog-known-mismatch.txt with the issue that tracks it:
#
#     <this repo's runquota sha> <reprobuild's runquota-src sha> <issue>
#
# The file holds at most the CURRENT pair. An entry naming any other pair, or
# a listed pair whose catalogs now agree, is stale and fails: it would
# otherwise excuse a mismatch nobody has looked at.
#
# ## Why this is a static check and not "just build it"
#
# Building the dev shell proves hazard 1 and takes minutes and a warm store;
# hazard 2 shows only in a refresh, which takes half an hour. This reads two
# flake.locks and two repro.locks out of git: no toolchain, no network, well
# under a second, so it sits in `just test`.
#
# ## Skips are loud, never silent
#
# The check needs two things it cannot synthesise: the sibling `reprobuild`
# checkout (for that revision's flake.lock) and the sibling `runquota`
# checkout holding both runquota revisions (for their repro.locks). When
# either is missing, this script prints a SKIP naming what is missing and the
# command that fixes it, and exits 0 — it never reports success for a
# comparison it did not make. Set CT_FLAKE_PIN_ALIGNMENT_STRICT=1 to turn
# those skips into failures, which is what a lane with a guaranteed
# workspace should do.
# =============================================================================
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORKSPACE_ROOT="$(cd "$REPO_ROOT/.." && pwd)"
STRICT="${CT_FLAKE_PIN_ALIGNMENT_STRICT:-0}"

fail() {
	echo "FAIL: $*" >&2
	exit 1
}

# A skip is a statement that the check did NOT run, and says why.
skip() {
	if [ "$STRICT" = "1" ]; then
		echo "FAIL (CT_FLAKE_PIN_ALIGNMENT_STRICT=1): $*" >&2
		exit 1
	fi
	echo "SKIP: $*" >&2
	echo "SKIP: flake pin alignment was NOT verified by this run." >&2
	exit 0
}

# The one tool this check cannot do without. `flake.lock` is JSON and is read
# with a JSON parser on purpose: a grep for `"rev"` would pick up whichever of
# the ~200 nodes happened to sort first and answer confidently with the wrong
# revision. So a missing python3 is a HARD FAILURE THAT NAMES ITSELF, never a
# fallback and never an empty answer.
#
# This is not hypothetical. Before this check existed, `lock_rev` swallowed
# every error and returned the empty string, so running the script outside the
# dev shell printed
#
#   scripts/test-flake-pin-alignment.sh: line 105: python3: command not found
#   FAIL: flake.lock has no locked rev for input 'runquota'.
#
# — a diagnostic that accuses a lock file which is in fact correct, and sends
# the reader to edit the very pin the check is protecting. That is the same
# false-attribution failure the direnv step in
# .github/workflows/launcher-recorder-e2e.yml was fixed for; it has no more
# business here than it had there.
command -v python3 >/dev/null 2>&1 || fail \
	"python3 is required to read flake.lock (it is JSON) and is not on PATH. This check does NOT fall back to grepping the lock, because a confidently wrong revision is worse than no answer. Run it inside the dev shell (\`nix develop '.?submodules=1#ci' --command just test-flake-pin-alignment\`), or put python3 on PATH. NOTHING about the pins has been established by this run."

# Read <lock-file> <input-name> -> locked.rev, or empty when the input is absent.
#
# "Absent node" and "unreadable file" are DIFFERENT answers and must not share
# the empty string: the first is a real verdict the caller turns into a precise
# message about a renamed input, the second means this script learned nothing.
#
# The lookup goes through `nodes.root.inputs`, NOT through the node key. Node
# keys are arbitrary labels nix disambiguates with `_2`, `_3`, … whenever two
# flakes in the closure name an input the same thing, and the plain name is
# handed to whichever node was written first — which is not necessarily the
# root's. reprobuild started committing its whole lock (so its closure now
# carries a nested `nixos-modules -> reprobuild -> runquota-src`), and from
# that moment a bare `nodes["runquota-src"]` lookup answered with the NESTED
# reprobuild's runquota (b71e8e9) while the root's own input sat under
# `runquota-src_2` (7a79877). The check then demanded this repo pin a revision
# its reprobuild is not compiled against — the precise inversion of what it
# exists to prevent, delivered with a paste-ready remedy. Resolve the input
# edge, and the answer cannot be shadowed by a homonym.
#
# A root input may ALSO be a `follows` path — a JSON list of segments rather
# than a node key — as `runquota` was while this repo derived it
# (`runquota.follows = "reprobuild/runquota-src"`). The resolver below walks such a path to the node it lands on, so
# `lock_rev <lock> runquota` answers with the revision the edge resolves to
# whichever shape the input has. The previous version did NOT: its comment
# said "a list would be a follows path, which no root input in either lock
# uses; fall back rather than guess", and the fall-back looked up
# `nodes["runquota"]`, which does not exist once the edge is a follows path.
# It therefore answered the empty string and the script died with "flake.lock
# has no locked rev for input 'runquota'" — correctly refusing to guess, and
# correctly telling the reader to update this file. This is that update.
lock_rev() {
	local out rc
	# The single quotes are the point: this is a python program, not a shell
	# string, and nothing in it is meant to expand. Its two arguments are
	# passed positionally and read as sys.argv.
	# shellcheck disable=SC2016
	out="$(python3 -c '
import json, sys
with open(sys.argv[1]) as handle:
    nodes = json.load(handle)["nodes"]


def resolve(start, path):
    """Walk a nix lock input path from `start`, following `follows` edges.

    A node input is either a node key (str) or a follows path (list of
    segments resolved from the ROOT). Recursion terminates because every
    follows path is strictly shorter to resolve than the node it names;
    a malformed lock with a cycle raises RecursionError, which the caller
    reports as a parse failure rather than as a verdict about a pin.
    """
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
    if len(sys.argv) > 3 and sys.argv[3] == "source":
        print(json.dumps(node.get("original", {}), sort_keys=True) if node else "")
    else:
        print(node.get("locked", {}).get("rev", "") if node else "")
' "$1" "$2" "${3:-rev}" 2>&1)"
	rc=$?
	[ "$rc" -eq 0 ] || fail \
		"could not read '$1' as a flake.lock (python3 exited $rc). This is a parse failure, NOT a statement about any pin — do not read it as 'the input is missing'. Parser output:
$out"
	printf '%s\n' "$out"
}

CT_LOCK="$REPO_ROOT/flake.lock"
[ -f "$CT_LOCK" ] || fail "$CT_LOCK does not exist; this script must run inside the codetracer checkout."

# `|| exit 1` IS LOAD-BEARING, and it is the whole reason the parse-failure
# diagnostic above is worth anything. `lock_rev` runs inside a command
# substitution, so its `fail` exits THAT SUBSHELL and nothing else; without
# this the script sails on with an empty rev and reports "flake.lock has no
# locked rev for input 'runquota'" a few lines later — the exact false
# accusation the parse diagnostic exists to replace, printed directly beneath
# it. Proven by ci/test/flake-pin-alignment-test.sh.
# --- Check 1: RESOLUTION -----------------------------------------------------
#
# Resolve both revisions FIRST, before any structural claim. Ordering is a
# property of the DIAGNOSTICS, not a preference: a lock that cannot be parsed,
# or that has lost the input entirely, must be reported as exactly that, by the
# one routine that distinguishes the two — and `ci/test/flake-pin-alignment-
# test.sh` asserts each of those messages. A structural classifier placed ahead
# of them answers both cases in its own words and silently retires three of
# that suite's assertions, including the mutation case that keeps the
# `|| exit 1` propagation below honest. (It did: 3 of 35 assertions failed
# until this was reordered, measured 2026-10-15 at codetracer `4e2201692`
# plus working-tree changes.)
CT_RUNQUOTA="$(lock_rev "$CT_LOCK" runquota)" || exit 1
REPROBUILD_REV="$(lock_rev "$CT_LOCK" reprobuild)" || exit 1

# These two nodes are the subject of the check. If either has stopped existing,
# the flake was restructured and this script is asserting about a shape that is
# gone — that is a failure to re-examine, not a pass and not a skip.
[ -n "$CT_RUNQUOTA" ] || fail "flake.lock has no locked rev for input 'runquota'. If the input was renamed or dropped, update this check (scripts/test-flake-pin-alignment.sh) to match."
[ -n "$REPROBUILD_REV" ] || fail "flake.lock has no locked rev for input 'reprobuild'. If the input was renamed or dropped, update this check (scripts/test-flake-pin-alignment.sh) to match."

# --- Check 2: STRUCTURE ------------------------------------------------------
#
# `nodes.root.inputs.runquota` is a bare string (a node key) when flake.nix
# declares an input with a url of its own, and a JSON list (a follows path)
# when it says `runquota.follows = "..."`. This repo pins its own (see
# flake.nix for why). And reprobuild's `runquota-src` edge must be a node key:
# a follows path there is an override of the source reprobuild compiles
# against — hazard 1 above.
#
# It runs AFTER Check 1: by here the lock is known to parse and to carry both
# inputs, so every outcome below is a statement about the SHAPE of the edges.
# shellcheck disable=SC2016
EDGES="$(python3 -c '
import json, sys
with open(sys.argv[1]) as handle:
    nodes = json.load(handle)["nodes"]
root = nodes.get("root", {}).get("inputs", {})
edge = root.get("runquota")
if isinstance(edge, list):
    print("FOLLOWS " + "/".join(edge))
else:
    print("OWN-NODE " + str(edge))
rb = root.get("reprobuild")
rb_edge = nodes.get(rb, {}).get("inputs", {}).get("runquota-src") if isinstance(rb, str) else None
if isinstance(rb_edge, list):
    print("RB-OVERRIDDEN " + "/".join(rb_edge))
else:
    print("RB-OWN " + str(rb_edge))
' "$CT_LOCK" 2>&1)" || fail "could not read '$CT_LOCK' to classify the runquota input edges. This is a parse failure, NOT a statement about any pin. Parser output:
$EDGES"
RUNQUOTA_EDGE="$(sed -n 1p <<<"$EDGES")"
RB_EDGE="$(sed -n 2p <<<"$EDGES")"

case "$RB_EDGE" in
"RB-OVERRIDDEN "*)
	fail "reprobuild's 'runquota-src' input is overridden to follow '${RB_EDGE#RB-OVERRIDDEN }'. reprobuild is COMPILED against that source, so it must be reprobuild's own locked runquota-src. Remove the override from flake.nix and re-lock with 'nix flake update reprobuild'."
	;;
esac

case "$RUNQUOTA_EDGE" in
"OWN-NODE "*)
	echo "structure: runquota is this repo's own input (${RUNQUOTA_EDGE#OWN-NODE }); reprobuild keeps its own runquota-src"
	;;
"FOLLOWS "*)
	fail "root input 'runquota' follows '${RUNQUOTA_EDGE#FOLLOWS }'. flake.nix pins runquota as its own input because reprobuild's runquota-src is on another reprobuild-packages catalog than repro.lock (see the comment on the runquota input). If a reprobuild pin now carries a runquota on this repo's catalog, returning to the follows edge is right: update this check, and repro.lock's runquota, with it."
	;;
*)
	fail "unrecognised classification '$RUNQUOTA_EDGE' for the 'runquota' input edge; update this check."
	;;
esac

# --- Check 3: CATALOG --------------------------------------------------------

REPROBUILD_DIR="${CT_REPROBUILD_CHECKOUT:-$WORKSPACE_ROOT/reprobuild}"
RUNQUOTA_DIR="${CT_RUNQUOTA_CHECKOUT:-$WORKSPACE_ROOT/runquota}"
KNOWN="$REPO_ROOT/ci/runquota-catalog-known-mismatch.txt"

[ -e "$REPROBUILD_DIR/.git" ] || skip "no reprobuild checkout at $REPROBUILD_DIR (set CT_REPROBUILD_CHECKOUT, or clone it beside this repo) — cannot read the flake.lock of reprobuild@${REPROBUILD_REV}."

git -C "$REPROBUILD_DIR" cat-file -e "${REPROBUILD_REV}^{commit}" 2>/dev/null ||
	skip "reprobuild checkout at $REPROBUILD_DIR does not have revision ${REPROBUILD_REV}. Run: git -C '$REPROBUILD_DIR' fetch origin ${REPROBUILD_REV}"

RB_LOCK_TMP="$(mktemp)"
trap 'rm -f "$RB_LOCK_TMP"' EXIT HUP INT TERM
git -C "$REPROBUILD_DIR" show "${REPROBUILD_REV}:flake.lock" >"$RB_LOCK_TMP" 2>/dev/null ||
	fail "reprobuild@${REPROBUILD_REV} has no flake.lock. The pin cannot be validated; re-examine this check."

RB_RUNQUOTA="$(lock_rev "$RB_LOCK_TMP" runquota-src)" || exit 1
[ -n "$RB_RUNQUOTA" ] || fail "reprobuild@${REPROBUILD_REV} flake.lock has no locked rev for 'runquota-src'; the input reprobuild expects has been renamed. Update this check to match."

echo "reprobuild pinned here:       ${REPROBUILD_REV}"
echo "  its runquota-src:           ${RB_RUNQUOTA}"
echo "this repo's runquota:         ${CT_RUNQUOTA}"

[ -e "$RUNQUOTA_DIR/.git" ] || skip "no runquota checkout at $RUNQUOTA_DIR (set CT_RUNQUOTA_CHECKOUT, or clone it beside this repo) — cannot read the repro.locks of runquota@${CT_RUNQUOTA} and runquota@${RB_RUNQUOTA}."
for rev in "$CT_RUNQUOTA" "$RB_RUNQUOTA"; do
	git -C "$RUNQUOTA_DIR" cat-file -e "${rev}^{commit}" 2>/dev/null ||
		skip "runquota checkout at $RUNQUOTA_DIR does not have revision ${rev}. Run: git -C '$RUNQUOTA_DIR' fetch origin ${rev}"
done

# <runquota rev> -> the reprobuild-packages revision its repro.lock pins,
# "none" when it pins none. A revision without a repro.lock is a failure: the
# question cannot be answered, and "none" would be a guess.
catalog_of() {
	local text entry='name = "reprobuild-packages", coord_kind = "vcs", url = "[^"]*", revision = "([0-9a-f]{40})"'
	text="$(git -C "$RUNQUOTA_DIR" show "$1:repro.lock" 2>/dev/null)" ||
		fail "runquota@$1 has no repro.lock, so its catalog cannot be read. Re-examine this check."
	if [[ $text =~ $entry ]]; then
		echo "${BASH_REMATCH[1]}"
	else
		echo none
	fi
}
CT_CATALOG="$(catalog_of "$CT_RUNQUOTA")" || exit 1
RB_CATALOG="$(catalog_of "$RB_RUNQUOTA")" || exit 1
echo "  catalogs:                   this repo's runquota ${CT_CATALOG}, reprobuild's ${RB_CATALOG}"

known=()
if [ -f "$KNOWN" ]; then
	while read -r line; do
		line="${line%%#*}"
		[ -n "${line// /}" ] && known+=("$line")
	done <"$KNOWN"
fi
CURRENT="$CT_RUNQUOTA $RB_RUNQUOTA"
listed=""
stale=()
for entry in "${known[@]}"; do
	read -r a b issue <<<"$entry"
	if [ "$a $b" = "$CURRENT" ] && [ -n "$issue" ] && [ "$CT_CATALOG" != "$RB_CATALOG" ]; then
		listed="$issue"
	else
		stale+=("$entry")
	fi
done

if [ "${#stale[@]}" -gt 0 ]; then
	echo "FAIL: ${#stale[@]} stale entr(y/ies) in ${KNOWN#"$REPO_ROOT"/}:" >&2
	printf '  %s\n' "${stale[@]}" >&2
	cat >&2 <<STALE
An entry must name exactly the current pair, <this repo's runquota>
<reprobuild's runquota-src>, followed by the issue that tracks it, and the two
must still be on different catalogs. The current pair is
  ${CURRENT}  (catalogs ${CT_CATALOG} / ${RB_CATALOG})
Delete the stale line; record the current pair only if its catalogs differ.
STALE
	exit 1
fi

if [ "$CT_CATALOG" = "$RB_CATALOG" ]; then
	echo "OK: this repo's runquota and reprobuild's runquota-src are on the same catalog (${CT_CATALOG})."
	exit 0
fi

if [ -n "$listed" ]; then
	echo "OK (known mismatch): runquota catalogs differ, as recorded in ${KNOWN#"$REPO_ROOT"/}; tracked by ${listed}"
	exit 0
fi

cat >&2 <<EOF2
FAIL: this repo's runquota and the runquota-src its reprobuild was locked
      against are on different reprobuild-packages catalogs.

  flake.lock          runquota     = ${CT_RUNQUOTA}  (catalog ${CT_CATALOG})
  reprobuild@${REPROBUILD_REV}
                      runquota-src = ${RB_RUNQUOTA}  (catalog ${RB_CATALOG})

Move whichever side is behind onto the other's catalog: this repo's runquota
with 'repro lock update runquota --to <rev>' (it moves repro.lock and
flake.lock together), or reprobuild to a revision whose runquota-src is on
this catalog. If neither can move yet, record the pair and the issue that
tracks it in ${KNOWN#"$REPO_ROOT"/}.
EOF2
exit 1
