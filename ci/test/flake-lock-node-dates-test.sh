#!/usr/bin/env bash
#
# Contract suite for scripts/test-flake-lock-node-dates.sh.
#
# The guard it covers exists because a `flake.lock` node can be INTERNALLY
# INCOHERENT — its `lastModified` naming one commit's date while its `rev` names
# a different commit — and nix refuses such an input outright, but only when it
# actually FETCHES it. A warm store does not; a workspace checkout that
# overrides the input with a sibling path does not; a cold runner does. That is
# the whole hazard, and the guard's own header explains it.
#
# What THIS suite is for is narrower, and it is the lesson
# ci/test/flake-pin-alignment-test.sh was written down for: A CHECK WHOSE
# FAILURE PATH ACCUSES THE WRONG THING IS WORSE THAN NO CHECK. That suite
# records three ways its guard managed exactly that — python3 absent and an
# unparseable lock both yielding an empty answer that got reported as a
# confident verdict about the lock, and `fail` called inside a command
# substitution so `exit 1` left only the subshell and the false accusation
# printed UNDERNEATH the real diagnostic. This guard is built the same way and
# can fail the same three ways, plus four of its own:
#
#   * SIBLING LOOKUP BY DIRECTORY NAME. `../stew` here is a fork of a
#     `status-im` repository under a different owner; reading a commit date out
#     of the fork and reporting it as the upstream node's date would be a
#     mismatch reported against a node that is perfectly correct. The `stew`
#     fixture below exists to hold the lookup to remote URLs.
#   * CLASSIFYING BY NODE KEY INSTEAD OF BY ROOT INPUT EDGE. Node keys are
#     arbitrary labels nix disambiguates with `_2`, and in the real lock the
#     root's `codetracer-trace-format` input is node
#     `codetracer-trace-format_4` while node `codetracer-trace-format` is a
#     transitive one. A direct input told to go fix a sibling repository, or a
#     transitive node told to hand-edit this lock, is the wrong repository in
#     both directions. The `alpha` / `alpha_2` pair below is that shape.
#   * A NODE WITH NO `lastModified` REPORTED AS A FINDING. Three real nodes are
#     in that shape; there is nothing for the rev to disagree with, so calling
#     it a defect would send a reader to repair a correct node.
#   * TWO NORMALISERS DRIFTING. The lock side is python, the checkout side is
#     bash, and if they disagree every comparison silently becomes a "no
#     checkout" skip and the guard reports a smaller universe while still
#     printing OK — a green tick over a defect. The fixtures put the `.git`
#     suffix on each side in turn: `alpha`'s CHECKOUT has it (against a
#     `type: github` node, which carries no URL at all), and `gamma`'s LOCK URL
#     has it (against an scp-style checkout remote that does not).
#
# So every case below asserts two things: that the RIGHT diagnostic appears,
# and that the WRONG one does not. A suite that only grepped for the expected
# string would have passed on all seven of those defects.
#
# AND THE ASSERTIONS ARE LIVE, WHICH WAS MEASURED AND NOT ASSUMED
# ---------------------------------------------------------------
# Every case below passed on the guard's first run, which is exactly when a
# suite is least trustworthy. Nine mutations were introduced into the guard one
# at a time and the suite had to go red for each:
#
#   1. sibling lookup keyed on the bare repository name on BOTH sides   17 red
#   2. the bash remote normaliser stops stripping `.git`                19 red
#   3. the python lock normaliser stops stripping `.git`                11 red
#   4. direct/transitive classified by node key, not root input edge     4 red
#   5. a node with no `lastModified` reported as a mismatch              3 red
#   6. "OK" printed when nothing at all was compared                     6 red
#   7. an unfetched revision counted among the comparisons               1 red
#   8. a mismatch exits 0                                                3 red
#   9. the `python3` prerequisite check deleted                          2 red
#
# Two of those started as mutations the suite did NOT catch, and both were the
# suite's fault rather than the mutation's: no fixture put a `.git` suffix on
# the CHECKOUT side of a `type: github` node (fixed by giving `alpha` such a
# remote), and the `stew` fork was unreachable by name-keying alone because the
# lock side still carried the owner (fixed by mutating both sides at once, which
# is what that defect would really look like). Keep that habit: a mutation the
# suite survives is a finding about the suite.
#
# Pure bash + git + python3 (which the guard requires anyway). No network, no
# nix, no dev shell, about a second.
#
# Run: bash ci/test/flake-lock-node-dates-test.sh

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
GUARD="$REPO_ROOT/scripts/test-flake-lock-node-dates.sh"

[ -f "$GUARD" ] || {
	echo "FAIL: the script under test is missing: $GUARD" >&2
	exit 1
}

BASH_ABS="$(command -v bash)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT HUP INT TERM

PASS=0
FAILED=0

ok() {
	PASS=$((PASS + 1))
	echo "  ok   $1"
}

bad() {
	FAILED=$((FAILED + 1))
	echo "  FAIL $1" >&2
	if [ $# -gt 1 ]; then
		printf '       %s\n' "$2" >&2
	fi
}

# assert_contains <label> <haystack> <needle>
assert_contains() {
	case "$2" in
	*"$3"*) ok "$1" ;;
	*) bad "$1" "expected to find: $3" ;;
	esac
}

# assert_absent <label> <haystack> <needle>
assert_absent() {
	case "$2" in
	*"$3"*) bad "$1" "expected NOT to find, but did: $3" ;;
	*) ok "$1" ;;
	esac
}

assert_rc() {
	if [ "$2" -eq "$3" ]; then
		ok "$1"
	else
		bad "$1" "rc=$2, expected $3"
	fi
}

# -----------------------------------------------------------------------------
# Fixtures.
#
# `make_commit <dir> <remote-url> <epoch> <message>` appends a commit whose
# COMMITTER date is exactly <epoch> — which is the field nix records as
# `lastModified`, and the field `git show -s --format=%ct` reads back — and
# prints its sha. GIT_COMMITTER_DATE is what matters here; the author date is
# set alongside it only so the two do not look confusingly different in `git
# log` while debugging a fixture.
# -----------------------------------------------------------------------------
make_commit() {
	local dir="$1" remote="$2" epoch="$3" message="$4"
	if [ ! -d "$dir/.git" ]; then
		mkdir -p "$dir"
		git -C "$dir" init -q
		git -C "$dir" config user.email lock-dates-test@example.invalid
		git -C "$dir" config user.name "lock dates test"
		git -C "$dir" remote add origin "$remote"
	fi
	printf '%s\n' "$message" >>"$dir/log.txt"
	git -C "$dir" add log.txt
	GIT_AUTHOR_DATE="@$epoch +0000" GIT_COMMITTER_DATE="@$epoch +0000" \
		git -C "$dir" commit -qm "$message"
	git -C "$dir" rev-parse HEAD
}

# The five dates the fixtures are built on. Distinct and far enough apart that a
# report showing the wrong one cannot be mistaken for a rounding artefact.
D_ALPHA_1=1700000000 # 2023-11-14T22:13:20Z
D_ALPHA_2=1750000000 # 2025-06-15T14:26:40Z
D_GAMMA=1720000000   # 2024-07-03T08:26:40Z
D_STEW=1730000000    # 2024-10-27T02:13:20Z
WRONG=1600000000     # 2020-09-13T12:26:40Z — never any fixture commit date

# write_lock <path> <alpha1-rev> <alpha1-lm> <alpha2-rev> <alpha2-lm> \
#            <gamma-rev> <gamma-lm> <stew-rev> <stew-lm>
#
# The shape mirrors the real lock in every way this guard can get wrong:
#
#   root.inputs.alpha -> node `alpha_2`, while node `alpha` is a TRANSITIVE
#     homonym reached through node `nested`. Both name the same repository, so
#     one sibling checkout serves both and the only thing that can differ in the
#     two diagnostics is the classification.
#   `gamma` is a `type: git` node, which the network-based
#     ci/test/flake-lock-metadata-test.sh filters out entirely, and its URL ends
#     in `.git` while the sibling's remote does not.
#   `nested` has no sibling checkout at all.
#   `stew` is owned by `other-org`, while the sibling DIRECTORY called `stew`
#     is `fixture-org/stew`.
#   `delta` carries a rev and no `lastModified`.
#   `tar` is a tarball: a rev, and no repository to date it against.
write_lock() {
	cat >"$1" <<EOF
{
  "nodes": {
    "root": {
      "inputs": {
        "alpha": "alpha_2",
        "gamma": "gamma",
        "nested": "nested",
        "delta": "delta",
        "tar": "tar",
        "stew": "stew"
      }
    },
    "alpha_2": {
      "locked": {
        "lastModified": $3,
        "narHash": "sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=",
        "owner": "fixture-org",
        "repo": "alpha",
        "rev": "$2",
        "type": "github"
      }
    },
    "nested": {
      "inputs": { "alpha": "alpha" },
      "locked": {
        "lastModified": 1699999999,
        "narHash": "sha256-BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB=",
        "owner": "fixture-org",
        "repo": "nested",
        "rev": "0000000000000000000000000000000000000001",
        "type": "github"
      }
    },
    "alpha": {
      "locked": {
        "lastModified": $5,
        "narHash": "sha256-CCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCC=",
        "owner": "fixture-org",
        "repo": "alpha",
        "rev": "$4",
        "type": "github"
      }
    },
    "gamma": {
      "locked": {
        "lastModified": $7,
        "narHash": "sha256-DDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDD=",
        "ref": "fixture",
        "rev": "$6",
        "type": "git",
        "url": "https://github.com/fixture-org/gamma.git"
      }
    },
    "stew": {
      "locked": {
        "lastModified": $9,
        "narHash": "sha256-EEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEE=",
        "owner": "other-org",
        "repo": "stew",
        "rev": "$8",
        "type": "github"
      }
    },
    "delta": {
      "flake": false,
      "locked": {
        "owner": "fixture-org",
        "repo": "delta",
        "rev": "0000000000000000000000000000000000000002",
        "type": "github"
      }
    },
    "tar": {
      "locked": {
        "lastModified": 1699999998,
        "narHash": "sha256-FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF=",
        "rev": "0000000000000000000000000000000000000003",
        "type": "tarball",
        "url": "https://example.invalid/source.tar.gz"
      }
    }
  },
  "root": "root",
  "version": 7
}
EOF
}

# A workspace: <ws>/repo is the fake codetracer checkout, and the siblings sit
# beside it exactly as CLAUDE.md requires of a real one — which is also what
# lets the default `$REPO_ROOT/..` resolution be the thing under test, rather
# than an env override that a real run would never use.
#
# Sets ALPHA_1 ALPHA_2 GAMMA STEW to the fixture revisions.
make_ws() {
	local ws="$1"
	mkdir -p "$ws/repo/scripts"
	cp "$GUARD" "$ws/repo/scripts/"
	# `.git`-suffixed remote against a `type: github` node, which has no URL at
	# all: the BASH normaliser has to strip the suffix or `alpha` — the node
	# every mismatch case below is built on — silently becomes "no checkout".
	ALPHA_1="$(make_commit "$ws/alpha" https://github.com/fixture-org/alpha.git "$D_ALPHA_1" "alpha one")"
	ALPHA_2="$(make_commit "$ws/alpha" https://github.com/fixture-org/alpha.git "$D_ALPHA_2" "alpha two")"
	# The mirror image: an scp-style remote with no `.git`, against a lock URL
	# that has both a scheme and the suffix. Here it is the PYTHON normaliser
	# that has to do the stripping.
	GAMMA="$(make_commit "$ws/gamma" git@github.com:fixture-org/gamma "$D_GAMMA" "gamma one")"
	# THE FORK. Directory `stew`, owner fixture-org; every `stew` node in the
	# lock is other-org.
	STEW="$(make_commit "$ws/stew" https://github.com/fixture-org/stew.git "$D_STEW" "stew one")"
}

run_guard() { # <ws> [env assignments...]
	local ws="$1"
	shift
	env "$@" bash "$ws/repo/scripts/test-flake-lock-node-dates.sh" 2>&1
}

echo
echo "a coherent lock passes, counts every node it did NOT verify, and never"
echo "touches the fork that merely shares a directory name"

WS="$TMP/coherent"
make_ws "$WS"
write_lock "$WS/repo/flake.lock" \
	"$ALPHA_1" "$D_ALPHA_1" "$ALPHA_2" "$D_ALPHA_2" \
	"$GAMMA" "$D_GAMMA" "$STEW" "$WRONG"
OUT="$(run_guard "$WS")"
RC=$?
assert_rc "a coherent lock exits 0" "$RC" 0
assert_contains "it says how many it compared" "$OUT" "OK: all 3 comparable"
assert_contains "and counts the nodes with no checkout" "$OUT" "no checkout:     2"
assert_contains "and the node that records no lastModified" "$OUT" "no lastModified: 1"
assert_contains "and the node with no commit at all" "$OUT" "no commit:       1"
assert_absent "a pass is not a skip" "$OUT" "SKIP:"
assert_absent "a pass accuses nothing" "$OUT" "FAIL"
# The fork's lastModified is deliberately WRONG. If the sibling lookup keyed on
# directory names it would have found ../stew, read a real commit date out of a
# repository the lock never named, and reported a mismatch against a correct
# node.
assert_absent "the same-named fork is never read" "$OUT" "other-org/stew"
assert_absent "and never accused" "$OUT" "node stew"

echo
echo "a direct input's stale timestamp is caught, and the remedy points HERE"

WS="$TMP/direct"
make_ws "$WS"
write_lock "$WS/repo/flake.lock" \
	"$ALPHA_1" "$WRONG" "$ALPHA_2" "$D_ALPHA_2" \
	"$GAMMA" "$D_GAMMA" "$STEW" "$WRONG"
OUT="$(run_guard "$WS")"
RC=$?
assert_rc "a stale direct timestamp exits 1" "$RC" 1
assert_contains "the node is named by KEY" "$OUT" "node alpha_2 (github.com/fixture-org/alpha)"
assert_contains "the locked value is shown" "$OUT" "lastModified locked  $WRONG"
assert_contains "so is the truth it disagrees with" "$OUT" "rev's commit date    $D_ALPHA_1"
assert_contains "both are shown as dates a human can read" "$OUT" "2020-09-13T12:26:40Z"
assert_contains "it is called a direct input" "$OUT" "This is a DIRECT input"
assert_contains "named by the INPUT name, not the node key" "$OUT" "update-input alpha"
assert_contains "and the checkout it was read from is named" "$OUT" "$WS/alpha"
# The shadow. Node `alpha` exists and IS transitive; the root's input resolves
# to `alpha_2`. A key-keyed classification would print the transitive remedy
# and send the reader to fix `nested`.
assert_absent "a direct input is not called transitive" "$OUT" "TRANSITIVE node"
assert_absent "nor handed the upstream remedy" "$OUT" "reached as"
assert_absent "and no verdict of success is printed" "$OUT" "OK: all"

echo
echo "a transitive node's stale timestamp is caught too, and the remedy points"
echo "at the flake that wrote it"

WS="$TMP/transitive"
make_ws "$WS"
write_lock "$WS/repo/flake.lock" \
	"$ALPHA_1" "$D_ALPHA_1" "$ALPHA_2" "$WRONG" \
	"$GAMMA" "$D_GAMMA" "$STEW" "$WRONG"
OUT="$(run_guard "$WS")"
RC=$?
assert_rc "a stale transitive timestamp exits 1" "$RC" 1
assert_contains "the node is named" "$OUT" "node alpha (github.com/fixture-org/alpha)"
assert_contains "it is called transitive" "$OUT" "This is a TRANSITIVE node"
assert_contains "and the edge that reaches it is named" "$OUT" "reached as 'nested' -> 'alpha'"
assert_contains "the remedy is upstream" "$OUT" "do not hand-edit it here"
# The other half of the shadow: `alpha` is the plain key, and the naive lookup
# would have called it the root's own input.
assert_absent "a transitive node is not called direct" "$OUT" "This is a DIRECT input"
assert_absent "nor handed a local re-lock command" "$OUT" "update-input"
assert_absent "and no verdict of success is printed" "$OUT" "OK: all"

echo
echo "a 'type: git' node is covered, which is precisely what the network-based"
echo "suite filters out — and the two URL normalisers are held together by it"

WS="$TMP/gitnode"
make_ws "$WS"
write_lock "$WS/repo/flake.lock" \
	"$ALPHA_1" "$D_ALPHA_1" "$ALPHA_2" "$D_ALPHA_2" \
	"$GAMMA" "$WRONG" "$STEW" "$WRONG"
OUT="$(run_guard "$WS")"
RC=$?
assert_rc "a stale git-type timestamp exits 1" "$RC" 1
# `https://github.com/fixture-org/gamma.git` in the lock had to reduce to the
# same slug as the sibling's `git@github.com:fixture-org/gamma`. If the two
# normalisers drifted, this node would have been counted as "no checkout" and
# the run would have printed OK over a defect.
assert_contains "the git node is compared, not skipped" "$OUT" "node gamma (github.com/fixture-org/gamma)"
assert_contains "and the true date is the fixture commit date" "$OUT" "rev's commit date    $D_GAMMA"
assert_absent "it is not written off as having no checkout" "$OUT" "no checkout:     3"
assert_absent "and no verdict of success is printed" "$OUT" "OK: all"

echo
echo "a missing python3 names ITSELF and does not accuse the lock"

WS="$TMP/nopython"
make_ws "$WS"
write_lock "$WS/repo/flake.lock" \
	"$ALPHA_1" "$D_ALPHA_1" "$ALPHA_2" "$D_ALPHA_2" \
	"$GAMMA" "$D_GAMMA" "$STEW" "$WRONG"
mkdir -p "$TMP/emptybin"
OUT="$(PATH="$TMP/emptybin" "$BASH_ABS" "$WS/repo/scripts/test-flake-lock-node-dates.sh" 2>&1)"
RC=$?
assert_rc "missing python3 exits 1" "$RC" 1
assert_contains "missing python3 is named" "$OUT" "python3 is required to read flake.lock"
assert_contains "and says nothing was established" "$OUT" "NOTHING about flake.lock has been established"
assert_absent "it does not claim there is nothing to compare" "$OUT" "no lock node could be compared"
assert_absent "it does not report a count of anything" "$OUT" "not comparable"
assert_absent "it does not accuse a node" "$OUT" "record a 'lastModified'"
assert_absent "and it does not claim a pass" "$OUT" "OK: all"

echo
echo "an unparseable lock reports a PARSE failure, and stops there"

WS="$TMP/badjson"
make_ws "$WS"
printf 'this is not json\n' >"$WS/repo/flake.lock"
OUT="$(run_guard "$WS")"
RC=$?
assert_rc "unparseable lock exits 1" "$RC" 1
assert_contains "it is called a parse failure" "$OUT" "as a flake.lock"
assert_contains "and disclaims any verdict about dates" "$OUT" "NOT a statement about any node's dates"
# THE REGRESSION THIS SUITE WAS WRITTEN FOR, in the shape
# ci/test/flake-pin-alignment-test.sh found it: `fail` inside `lock_rows` exits
# only the command substitution, so without `|| exit 1` at the call site the
# script carries on with zero rows and prints the honest-LOOKING skip directly
# underneath the real diagnostic — and exits 0.
assert_absent "it does not then claim there was nothing to compare" "$OUT" "no lock node could be compared"
assert_absent "nor report counts it never computed" "$OUT" "compared:"

echo
echo "mutation: that last pair of assertions is LIVE, not decorative"
WS="$TMP/mutant"
make_ws "$WS"
MUTANT="$WS/repo/scripts/test-flake-lock-node-dates.sh"
sed 's/)" || exit 1$/)"/' "$GUARD" >"$MUTANT"
if cmp -s "$GUARD" "$MUTANT"; then
	bad "the mutation changed nothing — the call site no longer ends in '|| exit 1'" \
		"update this mutation to match how scripts/test-flake-lock-node-dates.sh now propagates lock_rows failures"
else
	ok "the mutation removed the propagation it claims to remove"
	printf 'this is not json\n' >"$WS/repo/flake.lock"
	OUT="$(bash "$MUTANT" 2>&1)"
	RC=$?
	assert_contains "the mutant DOES print the false accusation" "$OUT" "no lock node could be compared"
	assert_rc "and the mutant exits 0 on an unreadable lock" "$RC" 0
fi

echo
echo "a workspace with no siblings skips LOUDLY, and STRICT makes it a failure"

WS="$TMP/nosiblings"
mkdir -p "$WS/repo/scripts"
cp "$GUARD" "$WS/repo/scripts/"
write_lock "$WS/repo/flake.lock" \
	0000000000000000000000000000000000000011 "$D_ALPHA_1" \
	0000000000000000000000000000000000000012 "$D_ALPHA_2" \
	0000000000000000000000000000000000000013 "$D_GAMMA" \
	0000000000000000000000000000000000000014 "$WRONG"
OUT="$(run_guard "$WS")"
RC=$?
assert_rc "nothing comparable exits 0" "$RC" 0
assert_contains "the skip says no node could be compared" "$OUT" "no lock node could be compared"
assert_contains "and states it verified nothing" "$OUT" "were NOT verified by this run"
assert_contains "and names where it looked" "$OUT" "$WS"
assert_absent "a skip is not a pass" "$OUT" "OK: all"

OUT="$(run_guard "$WS" CT_FLAKE_LOCK_NODE_DATES_STRICT=1)"
RC=$?
assert_rc "STRICT=1 turns that skip into exit 1" "$RC" 1
assert_contains "and says which setting made it one" "$OUT" "CT_FLAKE_LOCK_NODE_DATES_STRICT=1"

echo
echo "siblings that exist but have never fetched the pinned revision are named,"
echo "with the fetch that fixes them, and are never counted as verified"

WS="$TMP/unfetched"
make_ws "$WS"
MISSING=0000000000000000000000000000000000000021
write_lock "$WS/repo/flake.lock" \
	"$ALPHA_1" "$D_ALPHA_1" "$ALPHA_2" "$D_ALPHA_2" \
	"$MISSING" "$D_GAMMA" "$STEW" "$WRONG"
OUT="$(run_guard "$WS")"
RC=$?
assert_rc "an unfetched revision does not fail the run" "$RC" 0
assert_contains "it is counted apart from the comparisons" "$OUT" "rev not fetched: 1"
assert_contains "the pass line counts only what was compared" "$OUT" "OK: all 2 comparable"
assert_contains "the node is named" "$OUT" "gamma (github.com/fixture-org/gamma)"
assert_contains "with the command that fixes it" "$OUT" "fetch origin $MISSING"
assert_absent "and it is not accused of a stale timestamp" "$OUT" "record a 'lastModified'"

echo
echo "CT_FLAKE_LOCK_WORKSPACE redirects where siblings are looked for"

WS="$TMP/envdir"
mkdir -p "$WS/repo/scripts"
cp "$GUARD" "$WS/repo/scripts/"
ELSEWHERE="$TMP/elsewhere"
mkdir -p "$ELSEWHERE"
ALPHA_1="$(make_commit "$ELSEWHERE/alpha" https://github.com/fixture-org/alpha.git "$D_ALPHA_1" "alpha one")"
ALPHA_2="$(make_commit "$ELSEWHERE/alpha" https://github.com/fixture-org/alpha.git "$D_ALPHA_2" "alpha two")"
GAMMA="$(make_commit "$ELSEWHERE/gamma" git@github.com:fixture-org/gamma "$D_GAMMA" "gamma one")"
write_lock "$WS/repo/flake.lock" \
	"$ALPHA_1" "$D_ALPHA_1" "$ALPHA_2" "$D_ALPHA_2" \
	"$GAMMA" "$D_GAMMA" 0000000000000000000000000000000000000031 "$WRONG"
OUT="$(run_guard "$WS" "CT_FLAKE_LOCK_WORKSPACE=$ELSEWHERE")"
RC=$?
assert_rc "an out-of-tree workspace is used and passes" "$RC" 0
assert_contains "and the comparison really ran" "$OUT" "OK: all 3 comparable"
assert_contains "naming the workspace it used" "$OUT" "workspace $ELSEWHERE"

echo
if [ "$FAILED" -ne 0 ]; then
	echo "$PASS assertion(s) passed, $FAILED FAILED" >&2
	exit 1
fi
echo "all $PASS assertions passed"
