#!/usr/bin/env bash
# =============================================================================
# Flake pin alignment — this repo's `runquota` must be EXACTLY the `runquota`
# its `reprobuild` was locked against.
#
# ## The defect this exists to catch
#
# `flake.nix` used to pin BOTH `reprobuild` and `runquota` to exact SHAs, and
# then override five of reprobuild's own inputs — one of them
#
#     inputs.runquota-src.follows = "runquota";
#
# which was the whole hazard: bumping the `reprobuild` SHA moved the code,
# while `runquota` stayed wherever its own SHA left it. reprobuild was then
# compiled against a runquota it was never developed against, and the failure
# is an ordinary Nim `undeclared identifier` several minutes into a `nix
# develop` — attributed to reprobuild, in a store path, with nothing naming the
# pin that actually moved.
#
# ## That hazard is now STRUCTURALLY REMOVED, and this check guards the removal
#
# `flake.nix` no longer states either revision. `reprobuild` names a BRANCH
# (`agents` since 2026-10-15; `release/0.2.10` before that — either way a
# line, never a SHA) and `runquota` is DERIVED from it:
#
#     runquota.follows = "reprobuild/runquota-src";
#
# so the closure holds exactly ONE runquota node and it is reprobuild's own.
# Two revisions that could disagree have become one that cannot. This script
# therefore now checks TWO things, and the first is the important one:
#
#   1. STRUCTURE — that root input `runquota` is still a `follows` path onto
#      `reprobuild`'s `runquota-src`. If someone reintroduces an independent
#      `runquota` input, the guarantee is gone even on the day the two
#      revisions happen to match, so that is a failure in its own right.
#   2. VALUE — that the revision this repo's flake.lock resolves `runquota` to
#      equals the `runquota-src` revision reprobuild's OWN committed flake.lock
#      states. This is NOT vacuous under (1): the two numbers come from two
#      different files, and a hand-edited or half-relocked codetracer
#      flake.lock can state a runquota-src its reprobuild never locked.
#
# That is not hypothetical. Commit c9cb186c ("build(deps): mirror the
# nixos-modules reprobuild pin (b5b88139)") bumped reprobuild to b5b88139
# while `runquota` stayed at f3382f5 (2026-07-04). reprobuild@b5b88139's OWN
# flake.lock pins runquota-src at b71e8e9 — the commit that introduced
# `ExtensionCellWire`. The result was that `nix develop` (and therefore
# `just build-once`, `just test`, and every lane that needs the dev shell)
# died with
#
#     libs/repro_runquota/src/repro_runquota.nim(932, 18)
#       Error: undeclared identifier: 'ExtensionCellWire'
#
# on a tree whose own sources were fine.
#
# ## The invariant: EQUALITY, in both directions
#
# The revision this repo pins for `runquota` must EQUAL the `runquota-src`
# revision that the pinned `reprobuild` locks. Not "at least" — equal.
#
# "At least" was the first thing tried here and it is wrong, which is worth
# recording because it looks so reasonable. `runquota` was moved forward from
# f3382f5 to its `dev` tip (6dea983) to acquire `ExtensionCellWire`; that fixed
# the error above and produced a new one in the same file,
#
#     libs/repro_runquota/src/repro_runquota.nim(501, 52)
#       Error: undeclared identifier: 'LeaseFinishOutcome'
#
# because `dev` had since REMOVED that type ("Make a self-contradicting finish
# unrepresentable"). reprobuild@b5b88139 is source that compiles against
# runquota@b71e8e9 and against nothing else; ahead breaks exactly as behind
# does. So the check is `=`, and the remedy is to mirror, never to freshen.
#
# Only `runquota` is checked, because it is the only overridden input that is
# a flake whose code reprobuild COMPILES AGAINST. The nixpkgs/flake-parts/
# git-hooks overrides are environment.
#
# ## Why this is a static check and not "just build it"
#
# Building the dev shell does prove it, and takes minutes and a warm store.
# This compares two strings read out of two flake.lock files: no toolchain, no
# network, well under a second — so it can sit in `just test` and fail the
# moment a pin is bumped alone, instead of at the far end of a lane.
#
# ## Skips are loud, never silent
#
# The check needs one thing it cannot synthesise: the sibling `reprobuild`
# checkout, which is where the revision to compare against is read from (that
# revision's own flake.lock). When it is absent, or is present but has not
# fetched the pinned revision, this script prints a SKIP naming exactly what is
# missing and the command that fixes it, and exits 0 — it never reports success
# for a comparison it did not make. Set CT_FLAKE_PIN_ALIGNMENT_STRICT=1 to turn
# those skips into failures, which is what a lane with a guaranteed workspace
# should do.
#
# The sibling `runquota` checkout is OPTIONAL and its absence is not a skip:
# comparing two SHAs needs no repository. It is consulted only to label a
# failure "BEHIND" or "AHEAD of", which changes the message and never the
# verdict.
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
# than a node key — and since this repo made `runquota` derived
# (`runquota.follows = "reprobuild/runquota-src"`) that is the normal case
# here. The resolver below walks such a path to the node it lands on, so
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
    print(node.get("locked", {}).get("rev", "") if node else "")
' "$1" "$2" 2>&1)"
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
# Assert that `runquota` is still derived rather than independently pinned.
# `nodes.root.inputs.runquota` is a JSON list (a follows path) exactly when
# flake.nix says `runquota.follows = "..."`; it is a bare string (a node key)
# when flake.nix declares an input with a url of its own.
#
# A failure here is NOT "the revisions disagree" — they may well agree today.
# It is "the mechanism that makes them unable to disagree has been removed",
# which is worth catching in its own right.
#
# It runs AFTER Check 1 and BEFORE Check 3 deliberately: by here the lock is
# known to parse and to carry both inputs, so every outcome below is a real
# statement about the SHAPE of the edge rather than a restatement of a parse
# or a missing-input failure Check 1 already named.
# shellcheck disable=SC2016
RUNQUOTA_EDGE="$(python3 -c '
import json, sys
with open(sys.argv[1]) as handle:
    nodes = json.load(handle)["nodes"]
edge = nodes.get("root", {}).get("inputs", {}).get("runquota")
if edge is None:
    print("ABSENT")
elif isinstance(edge, list):
    print("FOLLOWS " + "/".join(edge))
else:
    print("OWN-NODE " + edge)
' "$CT_LOCK" 2>&1)" || fail "could not read '$CT_LOCK' to classify the 'runquota' input edge. This is a parse failure, NOT a statement about any pin. Parser output:
$RUNQUOTA_EDGE"

case "$RUNQUOTA_EDGE" in
"FOLLOWS reprobuild/runquota-src")
	echo "structure: runquota follows reprobuild/runquota-src (derived, cannot diverge)"
	;;
"FOLLOWS "*)
	fail "root input 'runquota' is a follows path, but onto '${RUNQUOTA_EDGE#FOLLOWS }' rather than 'reprobuild/runquota-src'. reprobuild is COMPILED against this source, so it must be reprobuild's own runquota-src and nothing else. Fix flake.nix: \`runquota.follows = \"reprobuild/runquota-src\";\`"
	;;
"OWN-NODE "*)
	# Not fatal by itself — fall through to the value comparison below, which
	# is the check that was in force while runquota was independently pinned.
	echo "structure: WARNING — 'runquota' is an independent input node (${RUNQUOTA_EDGE#OWN-NODE }), not a follows path onto reprobuild/runquota-src." >&2
	echo "structure: the two revisions can drift again; the value comparison below is now the only thing stopping them." >&2
	;;
"ABSENT")
	# Defensive only, and say so: Check 1 resolves `runquota` before this runs
	# and already fails with "flake.lock has no locked rev for input
	# 'runquota'" when the root declares no such input, so nothing reaches
	# here today. It is kept because the two checks read the lock through
	# different code paths, and a classifier that silently treated "absent"
	# as "fine" would be the worse failure.
	fail "flake.lock's root has no input named 'runquota' at all. If the input was renamed or dropped, update this check (scripts/test-flake-pin-alignment.sh) to match."
	;;
*)
	fail "unrecognised classification '$RUNQUOTA_EDGE' for the 'runquota' input edge; update this check."
	;;
esac

# --- Check 3: VALUE ----------------------------------------------------------

REPROBUILD_DIR="${CT_REPROBUILD_CHECKOUT:-$WORKSPACE_ROOT/reprobuild}"
RUNQUOTA_DIR="${CT_RUNQUOTA_CHECKOUT:-$WORKSPACE_ROOT/runquota}"

# Only the reprobuild checkout is REQUIRED: it is the sole source of the
# revision this check compares against. The runquota checkout is optional —
# comparing two SHAs for equality needs no repository; it is consulted purely
# to label a failure "BEHIND" or "AHEAD of", and its absence weakens the
# message, not the verdict.
[ -d "$REPROBUILD_DIR/.git" ] || skip "no reprobuild checkout at $REPROBUILD_DIR (set CT_REPROBUILD_CHECKOUT, or clone it beside this repo) — cannot read the flake.lock of reprobuild@${REPROBUILD_REV}."

git -C "$REPROBUILD_DIR" cat-file -e "${REPROBUILD_REV}^{commit}" 2>/dev/null ||
	skip "reprobuild checkout at $REPROBUILD_DIR does not have revision ${REPROBUILD_REV}. Run: git -C '$REPROBUILD_DIR' fetch origin ${REPROBUILD_REV}"

RB_LOCK_TMP="$(mktemp)"
trap 'rm -f "$RB_LOCK_TMP"' EXIT HUP INT TERM
git -C "$REPROBUILD_DIR" show "${REPROBUILD_REV}:flake.lock" >"$RB_LOCK_TMP" 2>/dev/null ||
	fail "reprobuild@${REPROBUILD_REV} has no flake.lock. The pin cannot be validated; re-examine this check."

# reprobuild calls its own input `runquota-src`; this repo calls the override
# `runquota` and wires them with `inputs.runquota-src.follows = "runquota"`.
RB_RUNQUOTA="$(lock_rev "$RB_LOCK_TMP" runquota-src)" || exit 1
[ -n "$RB_RUNQUOTA" ] || fail "reprobuild@${REPROBUILD_REV} flake.lock has no locked rev for 'runquota-src'; the input reprobuild expects has been renamed. Update this check to match."

echo "reprobuild pinned here:       ${REPROBUILD_REV}"
echo "  its runquota-src:           ${RB_RUNQUOTA}"
echo "this repo's runquota:         ${CT_RUNQUOTA}"

if [ "$CT_RUNQUOTA" = "$RB_RUNQUOTA" ]; then
	echo "OK: runquota is pinned to exactly the revision reprobuild was locked against."
	exit 0
fi

# Not equal. Say WHICH WAY it diverged when the checkout can tell us, because
# the two directions read very differently in the resulting compile error even
# though the remedy is the same.
RELATION="diverged from"
if [ -d "$RUNQUOTA_DIR/.git" ] &&
	git -C "$RUNQUOTA_DIR" cat-file -e "${RB_RUNQUOTA}^{commit}" 2>/dev/null &&
	git -C "$RUNQUOTA_DIR" cat-file -e "${CT_RUNQUOTA}^{commit}" 2>/dev/null; then
	if git -C "$RUNQUOTA_DIR" merge-base --is-ancestor "$CT_RUNQUOTA" "$RB_RUNQUOTA"; then
		RELATION="BEHIND"
	elif git -C "$RUNQUOTA_DIR" merge-base --is-ancestor "$RB_RUNQUOTA" "$CT_RUNQUOTA"; then
		RELATION="AHEAD of"
	fi
fi

cat >&2 <<EOF
FAIL: this repo's 'runquota' pin is ${RELATION} the runquota revision that the
      pinned reprobuild was locked against. They must be EQUAL.

  flake.lock          runquota     = ${CT_RUNQUOTA}
  reprobuild@${REPROBUILD_REV}
                      runquota-src = ${RB_RUNQUOTA}

'inputs.runquota-src.follows = "runquota"' means reprobuild is COMPILED against
the revision on the first line, while it was written against the second.
Divergence in EITHER direction surfaces minutes later as an 'undeclared
identifier' inside reprobuild's own sources — behind it loses types that were
added, ahead of it loses types that were removed.

Remedy — mirror, do not freshen. In flake.nix set the runquota input url to

    github:metacraft-labs/runquota/${RB_RUNQUOTA}

then 'nix flake update runquota' and confirm with 'nix develop --command true'.
EOF
exit 1
