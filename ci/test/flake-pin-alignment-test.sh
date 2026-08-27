#!/usr/bin/env bash
#
# Contract suite for scripts/test-flake-pin-alignment.sh.
#
# The guard it covers exists because `inputs.runquota-src.follows = "runquota"`
# makes the pinned `reprobuild` COMPILE against whatever this repo's `runquota`
# input resolves to, so the two pins must be equal. That much the guard's own
# header explains.
#
# What THIS suite is for is narrower and was learned the hard way: a check whose
# failure path accuses the wrong thing is worse than no check. Three separate
# ways of doing exactly that were observed in this guard before it had a suite:
#
#   * python3 absent -> `lock_rev` returned the empty string, and the guard
#     announced "flake.lock has no locked rev for input 'runquota'" about a lock
#     file that was perfectly correct, sending the reader to edit the very pin
#     the guard protects.
#   * an unparseable lock -> the same empty string, the same false accusation.
#   * `fail` called from inside `lock_rev` -> `lock_rev` runs in a command
#     substitution, so `exit 1` left only the SUBSHELL. The parse diagnostic
#     printed and then the script carried on and printed the false accusation
#     underneath it, which is strictly worse than printing it alone.
#
# So every case below asserts two things: that the RIGHT diagnostic appears,
# and that the WRONG one does not. A suite that only grepped for the expected
# string would have passed on all three of those defects.
#
# Pure bash + git. No network, no nix, no dev shell, well under a second.
#
# Run: bash ci/test/flake-pin-alignment-test.sh

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
GUARD="$REPO_ROOT/scripts/test-flake-pin-alignment.sh"

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

# A flake.lock with just the two nodes the guard reads.
# write_lock <path> <runquota-rev> <reprobuild-rev>
write_lock() {
	cat >"$1" <<EOF
{
  "nodes": {
    "root": { "inputs": { "runquota": "runquota", "reprobuild": "reprobuild" } },
    "runquota": {
      "locked": { "rev": "$2", "type": "github", "owner": "metacraft-labs", "repo": "runquota" }
    },
    "reprobuild": {
      "locked": { "rev": "$3", "type": "github", "owner": "metacraft-labs", "repo": "reprobuild" }
    }
  },
  "root": "root",
  "version": 7
}
EOF
}

# A fake reprobuild checkout whose HEAD commit carries a flake.lock pinning
# runquota-src at <rev>. Prints the commit sha.
# make_reprobuild <dir> <runquota-src-rev>
make_reprobuild() {
	local dir="$1" rev="$2"
	mkdir -p "$dir"
	git -C "$dir" init -q 2>/dev/null
	git -C "$dir" config user.email pin-test@example.invalid
	git -C "$dir" config user.name "pin test"
	cat >"$dir/flake.lock" <<EOF
{
  "nodes": {
    "root": { "inputs": { "runquota-src": "runquota-src" } },
    "runquota-src": {
      "locked": { "rev": "$rev", "type": "github", "owner": "metacraft-labs", "repo": "runquota" }
    }
  },
  "root": "root",
  "version": 7
}
EOF
	git -C "$dir" add flake.lock
	git -C "$dir" commit -qm "pin runquota-src at $rev"
	git -C "$dir" rev-parse HEAD
}

# Build a workspace: <ws>/repo is the fake codetracer checkout, <ws>/reprobuild
# the sibling. Echoes the reprobuild commit sha.
# make_ws <ws> <ct-runquota-rev> <rb-runquota-src-rev>
make_ws() {
	local ws="$1"
	mkdir -p "$ws/repo/scripts"
	cp "$GUARD" "$ws/repo/scripts/"
	local rb
	rb="$(make_reprobuild "$ws/reprobuild" "$3")"
	write_lock "$ws/repo/flake.lock" "$2" "$rb"
	echo "$rb"
}

RQ_A=1111111111111111111111111111111111111111
RQ_B=2222222222222222222222222222222222222222

echo
echo "the guard passes when the two pins are equal, and fails when they are not"

WS="$TMP/aligned"
make_ws "$WS" "$RQ_A" "$RQ_A" >/dev/null
OUT="$(bash "$WS/repo/scripts/test-flake-pin-alignment.sh" 2>&1)"
RC=$?
assert_rc "aligned pins exit 0" "$RC" 0
assert_contains "aligned pins say so" "$OUT" "OK: runquota is pinned to exactly the revision"

WS="$TMP/misaligned"
make_ws "$WS" "$RQ_A" "$RQ_B" >/dev/null
OUT="$(bash "$WS/repo/scripts/test-flake-pin-alignment.sh" 2>&1)"
RC=$?
assert_rc "misaligned pins exit 1" "$RC" 1
assert_contains "misaligned pins demand equality" "$OUT" "They must be EQUAL"
assert_contains "misaligned pins name this repo's rev" "$OUT" "$RQ_A"
assert_contains "misaligned pins name reprobuild's rev" "$OUT" "$RQ_B"
assert_contains "misaligned pins give the remedy url" "$OUT" "github:metacraft-labs/runquota/$RQ_B"

echo
echo "a missing python3 names ITSELF and does not accuse the lock file"

WS="$TMP/nopython"
make_ws "$WS" "$RQ_A" "$RQ_A" >/dev/null
mkdir -p "$TMP/emptybin"
OUT="$(PATH="$TMP/emptybin" "$BASH_ABS" "$WS/repo/scripts/test-flake-pin-alignment.sh" 2>&1)"
RC=$?
assert_rc "missing python3 exits 1" "$RC" 1
assert_contains "missing python3 is named" "$OUT" "python3 is required to read flake.lock"
assert_contains "missing python3 says nothing was established" "$OUT" "NOTHING about the pins has been established"
assert_absent "missing python3 does not accuse the lock" "$OUT" "has no locked rev for input"
assert_absent "missing python3 does not claim a verdict" "$OUT" "OK: runquota is pinned"

echo
echo "an unparseable lock reports a PARSE failure, and stops there"

WS="$TMP/badjson"
make_ws "$WS" "$RQ_A" "$RQ_A" >/dev/null
printf 'this is not json\n' >"$WS/repo/flake.lock"
OUT="$(bash "$WS/repo/scripts/test-flake-pin-alignment.sh" 2>&1)"
RC=$?
assert_rc "unparseable lock exits 1" "$RC" 1
assert_contains "unparseable lock is called a parse failure" "$OUT" "as a flake.lock"
assert_contains "unparseable lock disclaims any pin verdict" "$OUT" "NOT a statement about any pin"
# THE REGRESSION THIS SUITE WAS WRITTEN FOR: `fail` inside `lock_rev` exits only
# the command substitution, so without `|| exit 1` at the call site the false
# accusation printed directly underneath the honest diagnostic.
assert_absent "unparseable lock does not then accuse the input" "$OUT" "has no locked rev for input"

echo
echo "mutation: that last assertion is LIVE, not decorative"
# Removing `|| exit 1` from the lock_rev call sites is exactly the defect, so
# the mutant MUST fail the assertion the healthy script just passed. Without
# this case the assertion is untrustworthy: it passed on a half-mutated script
# during development, because the SECOND call site still carried `|| exit 1`
# and aborted before the false accusation could print.
WS="$TMP/mutant"
make_ws "$WS" "$RQ_A" "$RQ_A" >/dev/null
MUTANT="$WS/repo/scripts/test-flake-pin-alignment.sh"
sed 's/)" || exit 1$/)"/' "$GUARD" >"$MUTANT"
if cmp -s "$GUARD" "$MUTANT"; then
	bad "the mutation changed nothing — the call sites no longer end in '|| exit 1'" \
		"update this mutation to match how scripts/test-flake-pin-alignment.sh now propagates lock_rev failures"
else
	ok "the mutation removed the propagation it claims to remove"
	printf 'this is not json\n' >"$WS/repo/flake.lock"
	OUT="$(bash "$MUTANT" 2>&1)"
	assert_contains "the mutant DOES print the false accusation" "$OUT" "has no locked rev for input"
fi

echo
echo "a lock that really has lost the input says THAT, and it is a failure"

WS="$TMP/norunquota"
make_ws "$WS" "$RQ_A" "$RQ_A" >/dev/null
cat >"$WS/repo/flake.lock" <<'EOF'
{ "nodes": { "root": { "inputs": {} } }, "root": "root", "version": 7 }
EOF
OUT="$(bash "$WS/repo/scripts/test-flake-pin-alignment.sh" 2>&1)"
RC=$?
assert_rc "a dropped input exits 1" "$RC" 1
assert_contains "a dropped input is reported as such" "$OUT" "has no locked rev for input 'runquota'"
assert_absent "a dropped input is not called a parse failure" "$OUT" "NOT a statement about any pin"

echo
echo "skips are loud, say they verified nothing, and STRICT turns them into failures"

WS="$TMP/nosibling"
mkdir -p "$WS/repo/scripts"
cp "$GUARD" "$WS/repo/scripts/"
write_lock "$WS/repo/flake.lock" "$RQ_A" "$RQ_A"
OUT="$(bash "$WS/repo/scripts/test-flake-pin-alignment.sh" 2>&1)"
RC=$?
assert_rc "an absent reprobuild checkout skips with exit 0" "$RC" 0
assert_contains "the skip names what is missing" "$OUT" "no reprobuild checkout at"
assert_contains "the skip states it verified nothing" "$OUT" "was NOT verified by this run"
assert_absent "the skip does not claim a pass" "$OUT" "OK: runquota is pinned"

OUT="$(CT_FLAKE_PIN_ALIGNMENT_STRICT=1 bash "$WS/repo/scripts/test-flake-pin-alignment.sh" 2>&1)"
RC=$?
assert_rc "STRICT=1 turns that skip into exit 1" "$RC" 1
assert_contains "STRICT=1 says why it is a failure" "$OUT" "CT_FLAKE_PIN_ALIGNMENT_STRICT=1"

WS="$TMP/staleclone"
make_ws "$WS" "$RQ_A" "$RQ_A" >/dev/null
# A reprobuild checkout that exists but has never fetched the pinned revision:
# rewrite the lock to name a commit that repo does not contain.
write_lock "$WS/repo/flake.lock" "$RQ_A" 3333333333333333333333333333333333333333
OUT="$(bash "$WS/repo/scripts/test-flake-pin-alignment.sh" 2>&1)"
RC=$?
assert_rc "a reprobuild checkout without the pinned rev skips with exit 0" "$RC" 0
assert_contains "that skip names the fetch that fixes it" "$OUT" "fetch origin 3333333333333333333333333333333333333333"

echo
echo "CT_REPROBUILD_CHECKOUT redirects where the comparison rev is read from"

WS="$TMP/envdir"
mkdir -p "$WS/repo/scripts"
cp "$GUARD" "$WS/repo/scripts/"
RB="$(make_reprobuild "$TMP/elsewhere-reprobuild" "$RQ_A")"
write_lock "$WS/repo/flake.lock" "$RQ_A" "$RB"
OUT="$(CT_REPROBUILD_CHECKOUT="$TMP/elsewhere-reprobuild" bash "$WS/repo/scripts/test-flake-pin-alignment.sh" 2>&1)"
RC=$?
assert_rc "an out-of-tree reprobuild checkout is used and passes" "$RC" 0
assert_contains "and the comparison really ran" "$OUT" "OK: runquota is pinned to exactly the revision"

echo
if [ "$FAILED" -ne 0 ]; then
	echo "$PASS assertion(s) passed, $FAILED FAILED" >&2
	exit 1
fi
echo "all $PASS assertions passed"
