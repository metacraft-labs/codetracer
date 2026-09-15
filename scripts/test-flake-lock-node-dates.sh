#!/usr/bin/env bash
# =============================================================================
# Flake lock node dates — every `flake.lock` node whose repository is checked
# out beside this one must record the `lastModified` that its own `rev` carries.
#
# ## The defect this exists to catch
#
# A lock node is four coupled facts (`rev`, `narHash`, `lastModified`, and the
# `original` ref) and nix verifies ALL of them the moment it actually FETCHES
# the input:
#
#     error: mismatch in field 'lastModified' of input
#       '{...,"lastModified":1787817463,"rev":"e19a92179a2a...",...}',
#       got '{...,"lastModified":1789112885,...same rev...}'
#
# A node can therefore be INTERNALLY INCOHERENT: its timestamp naming one
# commit's date while its `rev` names another commit. That is what commit
# 4d15c1ea shipped — it moved `codetracer-trace-format-nim` from `d7eca441` to
# `e19a9217` and left `lastModified` at `d7eca441`'s date, fifteen days stale —
# and it is a nasty failure mode for a reason that has nothing to do with nix
# being strict:
#
#   * nix trusts a cached `lastModified` when it already has the entry, so a
#     WARM store never re-resolves and never notices;
#   * a workspace checkout overrides that input with a sibling path through
#     `.envrc`, so the github node is not fetched at all;
#   * only a COLD runner re-resolves, and there the mismatch is fatal before
#     anything has evaluated.
#
# So it passes locally, passes on warm runners, and fails intermittently on cold
# ones — which reads exactly like flake. It cost a real investigation: a PR
# whose diff touched no nix file and no lock file went red on
# `reprobuild-linux-smoke` while `dev` was green.
#
# ## Why a SECOND check, next to the network one
#
# `ci/test/flake-lock-metadata-test.sh` already asks GitHub for the true commit
# date of every DIRECT `github` input. It is the complete check and it is the
# right one to have. What it cannot do is run before the push: it needs
# authenticated GitHub access, so off a runner it skips loudly and verifies
# nothing, and its home is `ci/lint/bash.sh` — a CI lane that, on a queue-bound
# fleet, is the better part of an hour away from the commit that broke it.
#
# This check answers the same question with NO NETWORK, from the workspace that
# is already on disk, and it is not an approximation of the network one: a
# commit's sha COMMITS TO ITS COMMITTER DATE, so where a sibling checkout has
# the object, `git show -s --format=%ct` and the GitHub API cannot disagree.
# Where it can answer, it answers identically — at the cost of a `git show`.
#
# ## What it covers, which is more than the direct github inputs
#
# Every node in the lock, `github` and `git` alike, whose repository is checked
# out as a workspace sibling — 42 of the 259 locked nodes as of this writing.
# That is the 31 direct `github` inputs the network check sees, MINUS the
# third-party ones with no sibling, PLUS two things it does not:
#
#   * `type: git` inputs. `noir` is a direct input, a metacraft-labs fork
#     tracking a `codetracer` branch, and the network check filters it out
#     because it is not `type: github`.
#   * transitive nodes. This repo commits its whole 260-node closure, and nix
#     verifies whatever it fetches regardless of who wrote it, so an incoherent
#     `ct-trace-format-src` breaks this repo exactly as a direct input would.
#     The REMEDY differs, which is why every diagnostic below says which kind of
#     node it is talking about.
#
# ## What it does NOT cover, stated so nobody reads more into a pass
#
#   * Any node with no sibling checkout — 211 of 259 today, all third-party
#     (nixpkgs, fenix, flake-parts, status-im/*, spectrum-os). Those are the
#     network check's job. Neither check subsumes the other.
#   * Any node whose `rev` the sibling has not fetched. Reported by name with
#     the `git fetch` that fixes it; never counted as verified.
#   * `narHash`. Only a real fetch proves that, and the first `nix` invocation
#     in any lane already does.
#   * Nodes that record no `lastModified` at all — three do. There is nothing
#     for the `rev` to disagree with, so this is NOT a finding; it is counted
#     and named, and the count is the honest statement of what was skipped.
#   * `tarball` nodes. No commit, no commit date.
#
# ## Siblings are matched by REMOTE URL, never by directory name
#
# Directory names in this workspace do not track repository names — `../
# codetracer-nim` is `metacraft-labs/nim`, `../nim-langserver` is
# `metacraft-labs/langserver` — so a name-keyed lookup would simply miss them.
# Worse, it would MIS-MATCH: every `nim-stew` node in this lock is
# `status-im/nim-stew`, while `../nim-stew` is `metacraft-labs/nim-stew`, a
# fork. Reading a commit date out of a fork and reporting it as the upstream's
# is the definition of a check accusing the wrong thing, so the lookup is on
# the normalised remote of `remote.origin.url` and nothing else.
#
# ## Skips are loud, never silent — and there is deliberately NO floor
#
# A run that compared nothing prints a SKIP saying so and never "OK". Set
# CT_FLAKE_LOCK_NODE_DATES_STRICT=1 to make that a failure, which is what a
# lane with a guaranteed workspace should do.
#
# The network check guards its own vacuity with a floor (`MIN_CHECKED=15`),
# which is right there and would be WRONG here. Its universe is fixed — the
# direct inputs are in the lock whatever the machine looks like — so a low count
# can only mean the parse broke. This check's universe is whatever happens to be
# cloned, which legitimately ranges from nothing (a bare clone outside a
# workspace) to everything. A floor would therefore fail honest runs, so instead
# every run prints how many nodes it compared AND how many it could not, and the
# only vacuity that is refused is zero.
#
# Contract suite: ci/test/flake-lock-node-dates-test.sh
# =============================================================================
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORKSPACE_ROOT="${CT_FLAKE_LOCK_WORKSPACE:-$(cd "$REPO_ROOT/.." && pwd)}"
STRICT="${CT_FLAKE_LOCK_NODE_DATES_STRICT:-0}"
LOCK="$REPO_ROOT/flake.lock"

fail() {
	echo "FAIL: $*" >&2
	exit 1
}

# A skip is a statement that the check did NOT run, and says why.
skip() {
	if [ "$STRICT" = "1" ]; then
		echo "FAIL (CT_FLAKE_LOCK_NODE_DATES_STRICT=1): $*" >&2
		exit 1
	fi
	echo "SKIP: $*" >&2
	echo "SKIP: flake.lock node dates were NOT verified by this run." >&2
	exit 0
}

# The one tool this check cannot do without. `flake.lock` is JSON with 260
# nodes and is read with a JSON parser on purpose: a grep for `"lastModified"`
# cannot say which node it belongs to, and a confidently misattributed node is
# worse than no answer. A missing python3 is therefore a HARD FAILURE THAT
# NAMES ITSELF — never a fallback, never an empty answer that the code below
# would go on to describe as "no comparable nodes".
command -v python3 >/dev/null 2>&1 || fail \
	"python3 is required to read flake.lock (it is JSON) and is not on PATH. This check does NOT fall back to grepping the lock, because a date attributed to the wrong node is worse than no answer. Run it inside the dev shell (\`nix develop '.?submodules=1#ci' --command just test-flake-lock-node-dates\`), or put python3 on PATH. NOTHING about flake.lock has been established by this run."

[ -f "$LOCK" ] || fail "$LOCK does not exist; this script must run inside the codetracer checkout."

# -----------------------------------------------------------------------------
# Projection of the lock, one TSV row per node.
#
#   status  node  reach  slug  rev  lastModified
#
# status is `cmp` (a rev and a lastModified and a repository to read them
# from), `nodate` (a rev but no lastModified — nothing to disagree with), or
# `nocommit` (a type with no commit, i.e. tarball).
#
# reach is `direct:<input>` when `nodes.root.inputs` names this node, else
# `via:<parent>:<input>`. The distinction is resolved through the root's INPUT
# EDGES, not through node keys, because node keys are arbitrary labels that nix
# disambiguates with `_2`, `_3`, … and hands the plain name to whichever node
# was written first. In this very lock the root's `codetracer-trace-format`
# input is node `codetracer-trace-format_4`, while node
# `codetracer-trace-format` is a transitive one from a sibling's closure. A
# key-keyed classification would print the transitive remedy for a direct input
# and send the reader to the wrong repository — the same shadowing trap
# scripts/test-flake-pin-alignment.sh was fixed for.
# -----------------------------------------------------------------------------
lock_rows() {
	local out rc
	# The single quotes are the point: this is a python program, not a shell
	# string, and nothing in it is meant to expand.
	# shellcheck disable=SC2016
	out="$(python3 -c '
import json, sys

with open(sys.argv[1]) as handle:
    lock = json.load(handle)
nodes = lock["nodes"]
root_key = lock.get("root", "root")
root_inputs = nodes.get(root_key, {}).get("inputs", {})

# node key -> how it is reached. Direct edges win over transitive ones.
reach = {}
for parent, node in nodes.items():
    if parent == root_key:
        continue
    for name, edge in (node.get("inputs") or {}).items():
        # A list value is a `follows` path, not a node key.
        if isinstance(edge, str) and edge not in reach:
            reach[edge] = "via:%s:%s" % (parent, name)
for name, edge in root_inputs.items():
    if isinstance(edge, str):
        reach[edge] = "direct:%s" % name


def normalise(url):
    """A remote URL reduced to `host/path`, so the same repository spelled
    https, ssh or scp-style compares equal to the remote of a sibling checkout.
    NOTE: this program is embedded in a single-quoted shell string, so it must
    contain no apostrophe anywhere."""
    url = str(url).strip()
    for prefix in ("git+ssh://", "git+https://", "git+http://", "ssh://",
                   "https://", "http://", "git://"):
        if url.startswith(prefix):
            url = url[len(prefix):]
            break
    if url.startswith("git@"):
        # scp-style: git@host:owner/repo
        url = url[len("git@"):].replace(":", "/", 1)
    elif "@" in url.split("/", 1)[0]:
        url = url.split("@", 1)[1]
    if url.endswith(".git"):
        url = url[: -len(".git")]
    return url.strip("/").lower()


def slug_of(locked):
    kind = locked.get("type")
    if kind == "github":
        host = locked.get("host") or "github.com"
        owner = locked.get("owner", "")
        repo = locked.get("repo", "")
        return ("%s/%s/%s" % (host, owner, repo)).lower()
    if kind == "git":
        return normalise(locked.get("url", ""))
    # `tarball`, `path`, `indirect`, … carry no repository this check can read a
    # commit date out of. Reported as `nocommit`, never as verified.
    return ""


rows = []
for key in sorted(nodes):
    if key == root_key:
        continue
    locked = nodes[key].get("locked")
    if not locked:
        continue
    rev = locked.get("rev")
    stamp = locked.get("lastModified")
    slug = slug_of(locked)
    how = reach.get(key, "via:?:?")
    if not slug or not rev:
        rows.append(("nocommit", key, how, slug or locked.get("type", "?"), rev or "-", "-"))
    elif stamp is None:
        rows.append(("nodate", key, how, slug, rev, "-"))
    else:
        rows.append(("cmp", key, how, slug, rev, str(stamp)))
sys.stdout.write("".join("\t".join(r) + "\n" for r in rows))
' "$1" 2>&1)"
	rc=$?
	# "Unreadable" and "no comparable nodes" are DIFFERENT answers and must not
	# share the empty string: the second is a verdict, the first means this
	# script learned nothing.
	[ "$rc" -eq 0 ] || fail \
		"could not read '$1' as a flake.lock (python3 exited $rc). This is a parse failure, NOT a statement about any node's dates — do not read it as 'no nodes to compare'. Parser output:
$out"
	printf '%s' "$out"
}

# `|| exit 1` IS LOAD-BEARING. `lock_rows` runs inside a command substitution,
# so its `fail` exits THAT SUBSHELL and nothing else; without this the script
# sails on with zero rows and reports the honest-looking "no comparable nodes"
# skip directly underneath the parse diagnostic — the same false accusation,
# printed under the real one, that ci/test/flake-pin-alignment-test.sh exists to
# keep out of its sibling guard. Proven by the mutation case in
# ci/test/flake-lock-node-dates-test.sh.
ROWS="$(lock_rows "$LOCK")" || exit 1

# -----------------------------------------------------------------------------
# Normalised remote -> checkout, over the workspace siblings. Built once.
# -----------------------------------------------------------------------------
declare -A SIBLING_OF=()

# Must reduce a remote to exactly the same `host/path` the python projection
# above produces for a lock node, or every comparison silently becomes a "no
# checkout" skip and the check reports a smaller universe than it has. The two
# implementations are held together by the contract suite, which drives real
# checkouts whose remotes are spelled https, scp-style and `.git`-suffixed.
normalise_remote() {
	local url="${1%/}"
	case "$url" in
	git+ssh://*) url="${url#git+ssh://}" ;;
	git+https://*) url="${url#git+https://}" ;;
	git+http://*) url="${url#git+http://}" ;;
	ssh://*) url="${url#ssh://}" ;;
	https://*) url="${url#https://}" ;;
	http://*) url="${url#http://}" ;;
	git://*) url="${url#git://}" ;;
	esac
	case "$url" in
	git@*)
		url="${url#git@}"
		url="${url/://}"
		;;
	*@*/*) url="${url#*@}" ;;
	esac
	url="${url%.git}"
	url="${url#/}"
	url="${url%/}"
	printf '%s' "${url,,}"
}

if [ -d "$WORKSPACE_ROOT" ]; then
	for candidate in "$WORKSPACE_ROOT"/*; do
		[ -e "$candidate/.git" ] || continue
		remote="$(git -C "$candidate" config --get remote.origin.url 2>/dev/null)" || continue
		[ -n "$remote" ] || continue
		slug="$(normalise_remote "$remote")"
		# First checkout of a slug wins; a workspace with two clones of one
		# repository would otherwise depend on readdir order.
		[ -n "${SIBLING_OF[$slug]:-}" ] || SIBLING_OF["$slug"]="$candidate"
	done
fi

iso() { python3 -c 'import datetime,sys; print(datetime.datetime.fromtimestamp(int(sys.argv[1]), datetime.timezone.utc).isoformat().replace("+00:00","Z"))' "$1"; }

CHECKED=0
MISMATCHED=0
NO_SIBLING=0
UNFETCHED=0
NO_DATE=0
NO_COMMIT=0
MISMATCH_REPORT=""
UNFETCHED_REPORT=""

while IFS=$'\t' read -r status node reach slug rev stamp; do
	[ -n "$status" ] || continue
	case "$status" in
	nocommit)
		NO_COMMIT=$((NO_COMMIT + 1))
		continue
		;;
	nodate)
		NO_DATE=$((NO_DATE + 1))
		continue
		;;
	esac

	dir="${SIBLING_OF[$slug]:-}"
	if [ -z "$dir" ]; then
		NO_SIBLING=$((NO_SIBLING + 1))
		continue
	fi

	if ! actual="$(git -C "$dir" show -s --format=%ct "${rev}^{commit}" 2>/dev/null)" || [ -z "$actual" ]; then
		UNFETCHED=$((UNFETCHED + 1))
		UNFETCHED_REPORT+="  $node ($slug): $dir does not have ${rev}
      fetch it with: git -C '$dir' fetch origin ${rev}
"
		continue
	fi

	CHECKED=$((CHECKED + 1))
	[ "$actual" = "$stamp" ] && continue

	MISMATCHED=$((MISMATCHED + 1))
	case "$reach" in
	direct:*)
		remedy="This is a DIRECT input of this repo's flake.nix ('${reach#direct:}'), so the
      edit that broke it was made here. Either re-lock the input —
          nix flake lock --update-input ${reach#direct:}
      — or, to move nothing else, set this node's \"lastModified\" to ${actual}
      AND leave its \"narHash\" alone only if the rev did not change. If the rev
      DID change, the narHash is wrong too and only a re-lock will do."
		;;
	*)
		parent="${reach#via:}"
		remedy="This is a TRANSITIVE node, reached as '${parent%%:*}' -> '${parent#*:}'. It was
      written by that flake's own lock, so do not hand-edit it here: fix it in
      ${parent%%:*}'s repository, then re-mirror that pin and re-lock. nix will
      refuse the input regardless of which repository wrote the node."
		;;
	esac
	MISMATCH_REPORT+="  node ${node} (${slug})
      rev                  ${rev}
      lastModified locked  ${stamp}  ($(iso "$stamp"))
      rev's commit date    ${actual}  ($(iso "$actual"))
      read from            ${dir}
      ${remedy}

"
done <<ROWS_EOF
$ROWS
ROWS_EOF

echo "flake.lock node dates (${LOCK}, workspace ${WORKSPACE_ROOT})"
echo "  compared:                        ${CHECKED}"
echo "  not comparable, no checkout:     ${NO_SIBLING}"
echo "  not comparable, rev not fetched: ${UNFETCHED}"
echo "  not comparable, no lastModified: ${NO_DATE}"
echo "  not comparable, no commit:       ${NO_COMMIT}"

if [ -n "$UNFETCHED_REPORT" ]; then
	echo
	echo "These nodes have a checkout that has not fetched the pinned revision, so"
	echo "their dates were NOT verified:"
	printf '%s' "$UNFETCHED_REPORT"
fi

if [ "$MISMATCHED" -gt 0 ]; then
	{
		echo
		echo "FAIL: ${MISMATCHED} flake.lock node(s) record a 'lastModified' that is not the"
		echo "      commit date of the 'rev' they name. nix verifies that field whenever it"
		echo "      FETCHES the input and refuses it outright:"
		echo
		echo "          error: mismatch in field 'lastModified' of input ..."
		echo
		echo "      A warm store and a workspace checkout that overrides the input with a"
		echo "      sibling path both never fetch it, so this is invisible until a COLD"
		echo "      runner re-resolves — where it kills the job before anything evaluates."
		echo
		printf '%s' "$MISMATCH_REPORT"
	} >&2
	exit 1
fi

# A run that compared nothing is not a pass. It is the shape of rot this whole
# family of guards exists to refuse: an empty comparison reported as a green
# tick.
if [ "$CHECKED" -eq 0 ]; then
	skip "no lock node could be compared — there is no workspace sibling holding any locked revision (looked under $WORKSPACE_ROOT). Clone this repo inside its reprobuild workspace, or set CT_FLAKE_LOCK_WORKSPACE."
fi

echo
echo "OK: all ${CHECKED} comparable flake.lock node(s) record the commit date their rev carries."
echo "    This did NOT verify the ${NO_SIBLING} node(s) with no sibling checkout — those are"
echo "    ci/test/flake-lock-metadata-test.sh's job, and it needs the network."
exit 0
