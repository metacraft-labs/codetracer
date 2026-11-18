#!/usr/bin/env bash
#
# Contract suite for scripts/test-flake-pin-alignment.sh.
#
# The guard checks that this repo's own runquota input and the runquota-src
# its reprobuild was locked against are on the same reprobuild-packages
# catalog (or are the one pair recorded in
# ci/runquota-catalog-known-mismatch.txt), and that reprobuild's own
# runquota-src is not overridden.
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

# A flake.lock with the nodes the guard reads: this repo's own `runquota`
# input and `reprobuild`. With <rb-edge> = "follows", reprobuild's
# runquota-src is overridden (a follows path), which the guard must refuse.
# write_lock <path> <runquota-rev> <reprobuild-rev> [follows]
write_lock() {
	local rb_inputs='{ "runquota-src": "runquota-src_2" }'
	[ "${4:-}" = follows ] && rb_inputs='{ "runquota-src": [ "runquota" ] }'
	cat >"$1" <<EOF
{
  "nodes": {
    "root": { "inputs": { "runquota": "runquota", "reprobuild": "reprobuild" } },
    "runquota": {
      "locked": { "rev": "$2", "type": "github", "owner": "metacraft-labs", "repo": "runquota" },
      "original": { "type": "github", "owner": "metacraft-labs", "repo": "runquota", "ref": "agents" }
    },
    "reprobuild": {
      "inputs": $rb_inputs,
      "locked": { "rev": "$3", "type": "github", "owner": "metacraft-labs", "repo": "reprobuild" }
    },
    "runquota-src_2": {
      "locked": { "rev": "0000000000000000000000000000000000000000", "type": "github", "owner": "metacraft-labs", "repo": "runquota" }
    }
  },
  "root": "root",
  "version": 7
}
EOF
}

init_repo() {
	mkdir -p "$1"
	git -C "$1" init -q 2>/dev/null
	git -C "$1" config user.email pin-test@example.invalid
	git -C "$1" config user.name "pin test"
	git -C "$1" config commit.gpgsign false
}

# A fake runquota repo; each call commits a repro.lock pinning catalog <cat>
# ("none" for a lock with no catalog entry, "nolock" for no repro.lock at
# all) and prints the commit sha.
# runquota_commit <dir> <cat>
runquota_commit() {
	local dir="$1" cat="$2"
	[ -d "$dir/.git" ] || init_repo "$dir"
	case "$cat" in
	nolock) rm -f "$dir/repro.lock" ;;
	none) printf 'deps = [{ name = "nim-shm-lease", coord_kind = "vcs", url = "https://github.com/metacraft-labs/nim-shm-lease", revision = "%s" }]\n' "$(printf '5%.0s' {1..40})" >"$dir/repro.lock" ;;
	*) printf 'deps = [{ name = "reprobuild-packages", coord_kind = "vcs", url = "https://github.com/metacraft-labs/reprobuild-packages", revision = "%s", integrity = "" }]\n' "$cat" >"$dir/repro.lock" ;;
	esac
	echo "$cat" >>"$dir/marker"
	git -C "$dir" add -A
	git -C "$dir" commit -qm "runquota on catalog $cat"
	git -C "$dir" rev-parse HEAD
}

# A fake reprobuild checkout whose HEAD commit carries a flake.lock pinning
# runquota-src at <rev>. Prints the commit sha.
#
# With a third argument the lock is written in the SHADOWED shape reprobuild
# really produces since it began committing its whole lock: a nested flake in
# the closure (there, `nixos-modules -> reprobuild`) also has an input called
# `runquota-src`, so nix hands that one the plain node key and gives the ROOT's
# own input the `_2` suffix. The decoy rev is the nested one; <rev> stays the
# revision the root is actually locked against.
# make_reprobuild <dir> <runquota-src-rev> [<shadowing-decoy-rev>]
make_reprobuild() {
	local dir="$1" rev="$2" decoy="${3:-}"
	init_repo "$dir"
	if [ -n "$decoy" ]; then
		cat >"$dir/flake.lock" <<EOF
{
  "nodes": {
    "root": { "inputs": { "runquota-src": "runquota-src_2" } },
    "runquota-src": {
      "locked": { "rev": "$decoy", "type": "github", "owner": "metacraft-labs", "repo": "runquota" }
    },
    "runquota-src_2": {
      "locked": { "rev": "$rev", "type": "github", "owner": "metacraft-labs", "repo": "runquota" }
    }
  },
  "root": "root",
  "version": 7
}
EOF
	else
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
	fi
	git -C "$dir" add flake.lock
	git -C "$dir" commit -qm "pin runquota-src at $rev"
	git -C "$dir" rev-parse HEAD
}

CAT_A=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
CAT_B=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
ISSUE=reprobuild-pm:issues/2026-11-18-example.md

# Build a workspace: <ws>/repo is the fake codetracer checkout, <ws>/reprobuild
# and <ws>/runquota the siblings. Sets CT_RQ and RB_RQ to this repo's runquota
# and reprobuild's runquota-src, on catalogs <ct-cat> and <rb-cat>.
# make_ws <ws> <ct-cat> <rb-cat> [<shadowing-decoy-cat>]
make_ws() {
	local ws="$1" rb decoy=""
	mkdir -p "$ws/repo/scripts" "$ws/repo/ci"
	cp "$GUARD" "$ws/repo/scripts/"
	RB_RQ="$(runquota_commit "$ws/runquota" "$3")"
	CT_RQ="$(runquota_commit "$ws/runquota" "$2")"
	[ -n "${4:-}" ] && decoy="$(runquota_commit "$ws/runquota" "$4")"
	rb="$(make_reprobuild "$ws/reprobuild" "$RB_RQ" "$decoy")"
	write_lock "$ws/repo/flake.lock" "$CT_RQ" "$rb"
}

# known <ws> <line>... -> writes the known-mismatch file
known() {
	local ws="$1"
	shift
	printf '# comment lines are ignored\n' >"$ws/repo/ci/runquota-catalog-known-mismatch.txt"
	printf '%s\n' "$@" >>"$ws/repo/ci/runquota-catalog-known-mismatch.txt"
}

run_guard() { # <ws> [env...]
	local ws="$1"
	shift
	env "$@" bash "$ws/repo/scripts/test-flake-pin-alignment.sh" 2>&1
}

echo
echo "the guard passes on one catalog, and fails on two that nobody recorded"

WS="$TMP/aligned"
make_ws "$WS" "$CAT_A" "$CAT_A"
OUT="$(run_guard "$WS")"
RC=$?
assert_rc "one catalog exits 0" "$RC" 0
assert_contains "one catalog says so" "$OUT" "OK: this repo's runquota and reprobuild's runquota-src are on the same catalog"
assert_contains "the structure is this repo's own input" "$OUT" "runquota is this repo's own input"

WS="$TMP/misaligned"
make_ws "$WS" "$CAT_A" "$CAT_B"
OUT="$(run_guard "$WS")"
RC=$?
assert_rc "two catalogs exit 1" "$RC" 1
assert_contains "two catalogs are named as such" "$OUT" "on different reprobuild-packages catalogs"
assert_contains "the failure names this repo's runquota" "$OUT" "$CT_RQ  (catalog $CAT_A)"
assert_contains "the failure names reprobuild's runquota-src" "$OUT" "$RB_RQ  (catalog $CAT_B)"
assert_contains "the failure names the known-mismatch file" "$OUT" "ci/runquota-catalog-known-mismatch.txt"
assert_absent "an unrecorded mismatch is not called known" "$OUT" "known mismatch"

WS="$TMP/uncatalogued"
make_ws "$WS" "$CAT_A" none
OUT="$(run_guard "$WS")"
RC=$?
assert_rc "a lock with no catalog against one with a catalog exits 1" "$RC" 1
assert_contains "and reads as catalog 'none'" "$OUT" "(catalog none)"

echo
echo "a recorded pair passes; any other entry is stale and fails"

WS="$TMP/known"
make_ws "$WS" "$CAT_A" "$CAT_B"
known "$WS" "$CT_RQ $RB_RQ $ISSUE"
OUT="$(run_guard "$WS")"
RC=$?
assert_rc "the recorded pair exits 0" "$RC" 0
assert_contains "the recorded pair says it is a known mismatch" "$OUT" "OK (known mismatch)"
assert_contains "and names the issue tracking it" "$OUT" "$ISSUE"

# Positive control for the entry above: the same workspace with the entry
# gone must fail, or the pass proved nothing about the file.
known "$WS"
OUT="$(run_guard "$WS")"
RC=$?
assert_rc "the same pair without its entry exits 1" "$RC" 1

known "$WS" "$RB_RQ $CT_RQ $ISSUE"
OUT="$(run_guard "$WS")"
RC=$?
assert_rc "a swapped pair is stale and exits 1" "$RC" 1
assert_contains "the stale entry is named" "$OUT" "stale entr"

known "$WS" "$CT_RQ $RB_RQ"
OUT="$(run_guard "$WS")"
RC=$?
assert_rc "an entry without an issue is stale and exits 1" "$RC" 1

known "$WS" "$CT_RQ $RB_RQ $ISSUE" "$(printf '9%.0s' {1..40}) $RB_RQ $ISSUE"
OUT="$(run_guard "$WS")"
RC=$?
assert_rc "an extra entry for an old pair fails although the current pair is listed" "$RC" 1
assert_contains "and names the old pair" "$OUT" "$(printf '9%.0s' {1..40})"

WS="$TMP/known-but-agreed"
make_ws "$WS" "$CAT_A" "$CAT_A"
known "$WS" "$CT_RQ $RB_RQ $ISSUE"
OUT="$(run_guard "$WS")"
RC=$?
assert_rc "a recorded pair whose catalogs now agree is stale and exits 1" "$RC" 1
assert_contains "and the remedy is to delete it" "$OUT" "Delete the stale line"
assert_absent "it does not report the agreement as a pass" "$OUT" "OK: this repo's runquota"

echo
echo "structure: this repo pins its own runquota, and reprobuild keeps its own"

WS="$TMP/follows"
make_ws "$WS" "$CAT_A" "$CAT_A"
python3 - "$WS/repo/flake.lock" <<'PY_FOLLOWS'
import json, sys
path = sys.argv[1]
with open(path) as handle:
    lock = json.load(handle)
lock["nodes"]["root"]["inputs"]["runquota"] = ["reprobuild", "runquota-src"]
with open(path, "w") as handle:
    json.dump(lock, handle)
PY_FOLLOWS
OUT="$(run_guard "$WS")"
RC=$?
assert_rc "a runquota that follows reprobuild again exits 1" "$RC" 1
assert_contains "and says why this repo pins its own" "$OUT" "follows 'reprobuild/runquota-src'"

WS="$TMP/override"
make_ws "$WS" "$CAT_A" "$CAT_A"
write_lock "$WS/repo/flake.lock" "$CT_RQ" "$(git -C "$WS/reprobuild" rev-parse HEAD)" follows
OUT="$(run_guard "$WS")"
RC=$?
assert_rc "an overridden reprobuild runquota-src exits 1, on one catalog too" "$RC" 1
assert_contains "the override is named as the compile hazard" "$OUT" "reprobuild is COMPILED against that source"
assert_absent "the override cannot claim a pass" "$OUT" "OK:"

echo
echo "a homonym node deeper in reprobuild's closure does not shadow the root's own input"

WS="$TMP/shadowed-aligned"
make_ws "$WS" "$CAT_A" "$CAT_A" "$CAT_B"
OUT="$(run_guard "$WS")"
RC=$?
assert_rc "the root's runquota-src is the one compared" "$RC" 0
assert_contains "and it reports the root's rev, not the nested one" "$OUT" "runquota-src:           $RB_RQ"

WS="$TMP/shadowed-misaligned"
make_ws "$WS" "$CAT_A" "$CAT_B" "$CAT_A"
OUT="$(run_guard "$WS")"
RC=$?
assert_rc "a real mismatch is still caught through the shadow" "$RC" 1
assert_contains "and the comparison names the root's rev" "$OUT" "runquota-src = $RB_RQ"

echo
echo "a runquota revision with no repro.lock is a failure, not catalog 'none'"

WS="$TMP/nolock"
make_ws "$WS" "$CAT_A" nolock
OUT="$(run_guard "$WS")"
RC=$?
assert_rc "a revision without repro.lock exits 1" "$RC" 1
assert_contains "and says its catalog cannot be read" "$OUT" "has no repro.lock"

echo
echo "a missing python3 names ITSELF and does not accuse the lock file"

WS="$TMP/nopython"
make_ws "$WS" "$CAT_A" "$CAT_A"
mkdir -p "$TMP/emptybin"
OUT="$(PATH="$TMP/emptybin" "$BASH_ABS" "$WS/repo/scripts/test-flake-pin-alignment.sh" 2>&1)"
RC=$?
assert_rc "missing python3 exits 1" "$RC" 1
assert_contains "missing python3 is named" "$OUT" "python3 is required to read flake.lock"
assert_contains "missing python3 says nothing was established" "$OUT" "NOTHING about the pins has been established"
assert_absent "missing python3 does not accuse the lock" "$OUT" "has no locked rev for input"
assert_absent "missing python3 does not claim a verdict" "$OUT" "OK:"

echo
echo "an unparseable lock reports a PARSE failure, and stops there"

WS="$TMP/badjson"
make_ws "$WS" "$CAT_A" "$CAT_A"
printf 'this is not json\n' >"$WS/repo/flake.lock"
OUT="$(run_guard "$WS")"
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
# the mutant MUST fail the assertion the healthy script just passed.
WS="$TMP/mutant"
make_ws "$WS" "$CAT_A" "$CAT_A"
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
make_ws "$WS" "$CAT_A" "$CAT_A"
cat >"$WS/repo/flake.lock" <<'EOF'
{ "nodes": { "root": { "inputs": {} } }, "root": "root", "version": 7 }
EOF
OUT="$(run_guard "$WS")"
RC=$?
assert_rc "a dropped input exits 1" "$RC" 1
assert_contains "a dropped input is reported as such" "$OUT" "has no locked rev for input 'runquota'"
assert_absent "a dropped input is not called a parse failure" "$OUT" "NOT a statement about any pin"

echo
echo "skips are loud, say they verified nothing, and STRICT turns them into failures"

WS="$TMP/nosibling"
make_ws "$WS" "$CAT_A" "$CAT_B"
rm -rf "$WS/reprobuild"
OUT="$(run_guard "$WS")"
RC=$?
assert_rc "an absent reprobuild checkout skips with exit 0" "$RC" 0
assert_contains "the skip names what is missing" "$OUT" "no reprobuild checkout at"
assert_contains "the skip states it verified nothing" "$OUT" "was NOT verified by this run"
assert_absent "the skip does not claim a pass" "$OUT" "OK:"

OUT="$(run_guard "$WS" CT_FLAKE_PIN_ALIGNMENT_STRICT=1)"
RC=$?
assert_rc "STRICT=1 turns that skip into exit 1" "$RC" 1
assert_contains "STRICT=1 says why it is a failure" "$OUT" "CT_FLAKE_PIN_ALIGNMENT_STRICT=1"

WS="$TMP/staleclone"
make_ws "$WS" "$CAT_A" "$CAT_A"
write_lock "$WS/repo/flake.lock" "$CT_RQ" 3333333333333333333333333333333333333333
OUT="$(run_guard "$WS")"
RC=$?
assert_rc "a reprobuild checkout without the pinned rev skips with exit 0" "$RC" 0
assert_contains "that skip names the fetch that fixes it" "$OUT" "fetch origin 3333333333333333333333333333333333333333"

WS="$TMP/norunquota-checkout"
make_ws "$WS" "$CAT_A" "$CAT_B"
rm -rf "$WS/runquota"
OUT="$(run_guard "$WS")"
RC=$?
assert_rc "an absent runquota checkout skips with exit 0" "$RC" 0
assert_contains "the skip names the runquota checkout" "$OUT" "no runquota checkout at"
assert_absent "a skipped mismatch is not reported as a pass" "$OUT" "OK"
OUT="$(run_guard "$WS" CT_FLAKE_PIN_ALIGNMENT_STRICT=1)"
RC=$?
assert_rc "STRICT=1 turns the runquota skip into exit 1" "$RC" 1

WS="$TMP/runquota-lacks-rev"
make_ws "$WS" "$CAT_A" "$CAT_A"
write_lock "$WS/repo/flake.lock" 4444444444444444444444444444444444444444 "$(git -C "$WS/reprobuild" rev-parse HEAD)"
OUT="$(run_guard "$WS")"
RC=$?
assert_rc "a runquota checkout without a pinned rev skips with exit 0" "$RC" 0
assert_contains "that skip names the fetch that fixes it" "$OUT" "fetch origin 4444444444444444444444444444444444444444"

echo
echo "checkouts may be linked worktrees, and may live elsewhere"

WS="$TMP/worktrees"
make_ws "$WS" "$CAT_A" "$CAT_A"
mv "$WS/reprobuild" "$TMP/rb-main"
git -C "$TMP/rb-main" worktree add -q --detach "$WS/reprobuild" HEAD
OUT="$(run_guard "$WS")"
RC=$?
assert_rc "a linked-worktree reprobuild checkout is read" "$RC" 0
assert_contains "and the comparison really ran" "$OUT" "OK: this repo's runquota"

WS="$TMP/envdir"
make_ws "$WS" "$CAT_A" "$CAT_A"
mv "$WS/reprobuild" "$TMP/elsewhere-reprobuild"
mv "$WS/runquota" "$TMP/elsewhere-runquota"
OUT="$(run_guard "$WS" CT_REPROBUILD_CHECKOUT="$TMP/elsewhere-reprobuild" CT_RUNQUOTA_CHECKOUT="$TMP/elsewhere-runquota")"
RC=$?
assert_rc "out-of-tree checkouts are used and pass" "$RC" 0
assert_contains "and the comparison really ran" "$OUT" "OK: this repo's runquota"

echo
if [ "$FAILED" -ne 0 ]; then
	echo "$PASS assertion(s) passed, $FAILED FAILED" >&2
	exit 1
fi
echo "all $PASS assertions passed"
