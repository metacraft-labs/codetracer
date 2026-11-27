#!/usr/bin/env bash
#
# image-diff-consumers.sh -- run CodeTracer's consumers of codetracer-image-diff
# against the codetracer-image-diff checkout beside this one.
#
# WHAT THIS IS
#   The body of codetracer-image-diff's downstream lane for this repository.
#   codetracer-image-diff (NVIDIA FLIP: a C ABI shim, src/flip_wrapper.cpp,
#   and a Nim API, src/image_diff.nim) reaches CodeTracer three ways:
#     * the PLAT-37 parity tooling compiles the C ABI shim and binds it from
#       Python (ci/test/plat37-parity.sh, ci/test/plat37_parity.py);
#     * Nim tools import `image_diff` (tools/story-parity/story_diff.nim,
#       built by scripts/story-parity.sh);
#     * flake.nix pins the library's source as the `codetracer-image-diff`
#       input (`flake = false`), following the library's `agents` branch.
#   Each runs in this repository's CI against whatever revision codetracer
#   pins, so without this lane a library change is first checked against
#   them when codetracer next picks it up. The library calls this through
#   the reusable workflow .github/workflows/image-diff-downstream.yml, with
#   the library checked out at the commit under test and this repository at
#   the revision the library's committed ci/downstream/codetracer.pin
#   names. It runs the same way locally:
#
#     just test-image-diff-consumers [--expect-image-diff-rev SHA]
#
#   from a codetracer checkout inside its dev shell (`nix develop
#   '.?submodules=1#ci'`, which provides nim, python3 and a C++ compiler),
#   with ../codetracer-image-diff beside it.
#
# WHAT IT RUNS
#   1. `bash ci/test/plat37-parity.sh --test`: compiles the library's C ABI
#      shim exactly as the parity gate does and runs the parity tool's
#      unittest suite through REAL FLIP over synthetic PNGs (no window, no
#      GPU). Every unittest case counts.
#   2. Every Nim module of this repository that imports `image_diff`, found by
#      scanning the tracked sources for the import (not a list kept here), is
#      compiled against the checkout under test with `nim c` (how
#      scripts/story-parity.sh builds story_diff) and with `nim cpp` (the
#      library's declared backend). Each compile counts as one test.
#   3. The flake's `codetracer-image-diff` input is locked to the checkout
#      under test (`nix flake lock --override-input ... --output-lock-file`
#      into a temporary file, so flake.lock is untouched), and the lock is
#      required to record exactly that commit. No output of the flake reads
#      the input today, so locking it is everything the flake does with it;
#      a tree Nix cannot fetch, or a lock that records another commit, fails.
#      This counts as one test.
#
# HOW IT FAILS
#   It prints one final line,
#
#     TEST-COUNTS: executed=N passed=N failed=N skipped=N
#
#   and exits non-zero when a test failed or was skipped, no test ran, no
#   module imports image_diff, a part could not be run, or a count could not
#   be read. A cross-repo gate may never degrade into a zero-test or skipped
#   run: a missing prerequisite (the library checkout, a tool) is an error,
#   never a skip, and no skip is allowed.
#
# Usage: ci/test/image-diff-consumers.sh [--expect-image-diff-rev SHA] [--list]
#   --expect-image-diff-rev SHA  refuse unless ../codetracer-image-diff is a
#                                git checkout whose HEAD is SHA (CI passes the
#                                commit it checked out)
#   --list                       print the selected Nim modules and exit
# Environment:
#   IMAGE_DIFF_CONSUMERS_KEEP=1  keep the temporary work directory.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
WORKSPACE_ROOT="$(cd "$REPO_ROOT/.." && pwd -P)"
LIB_DIR="$WORKSPACE_ROOT/codetracer-image-diff"
# A module imports image_diff when an import, from or include statement names
# it. Kept to one line per statement: a bracketed import list split over
# several lines that names image_diff on a continuation line is not found,
# and the empty-selection refusal below is what stops that from passing
# silently when it is the only one.
IMPORT_RE='^[[:space:]]*(import|from|include)[[:space:]][^#]*\bimage_diff\b'

die() {
	echo "image-diff-consumers: $*" >&2
	echo "TEST-COUNTS: executed=0 passed=0 failed=0 skipped=0"
	exit 1
}

expect_rev=""
list_only=0
while [ $# -gt 0 ]; do
	case "$1" in
	--expect-image-diff-rev)
		[ $# -ge 2 ] || die "--expect-image-diff-rev needs a value"
		expect_rev="$2"
		shift 2
		;;
	--list)
		list_only=1
		shift
		;;
	*) die "unknown argument '$1'" ;;
	esac
done

cd "$REPO_ROOT" || die "cannot enter $REPO_ROOT"

# --- the library under test ----------------------------------------------------
# ci/test/plat37-parity.sh and scripts/story-parity.sh name
# ../codetracer-image-diff literally, so that is the only checkout they see.
for f in src/image_diff.nim src/flip_wrapper.cpp vendor/flip/FLIP.h; do
	[ -f "$LIB_DIR/$f" ] || die "$LIB_DIR/$f does not exist; check codetracer-image-diff out beside $REPO_ROOT"
done
lib_rev="$(git -C "$LIB_DIR" rev-parse HEAD 2>/dev/null)" || die "$LIB_DIR is not a git checkout"
if [ -n "$expect_rev" ]; then
	[[ $expect_rev =~ ^[0-9a-f]{40}$ ]] || die "--expect-image-diff-rev must be a 40-hex commit (got '$expect_rev')"
	[ "$lib_rev" = "$expect_rev" ] || die "$LIB_DIR is at $lib_rev, not the commit under test $expect_rev"
fi
echo "image-diff-consumers: codetracer-image-diff $lib_rev$([ -z "$(git -C "$LIB_DIR" status --porcelain 2>/dev/null)" ] || echo ' (+ uncommitted changes)')"
echo "image-diff-consumers: codetracer $(git rev-parse HEAD 2>/dev/null || echo '?')$([ -z "$(git status --porcelain 2>/dev/null)" ] || echo ' (+ uncommitted changes)')"

# --- selection -------------------------------------------------------------------
mapfile -t modules < <(git ls-files -z -- '*.nim' | xargs -0 grep -lE "$IMPORT_RE" -- 2>/dev/null | LC_ALL=C sort)
[ "${#modules[@]}" -gt 0 ] ||
	die "no tracked Nim module imports image_diff; the selection is broken, not empty (tools/story-parity/story_diff.nim did)"
echo "image-diff-consumers: ${#modules[@]} module(s) import image_diff:"
printf '  %s\n' "${modules[@]}"
[ "$list_only" -eq 1 ] && exit 0

for tool in nim python3 nix; do
	command -v "$tool" >/dev/null 2>&1 || die "'$tool' is not on PATH; run inside codetracer's dev shell (nix develop '.?submodules=1#ci')"
done
command -v "${CXX:-c++}" >/dev/null 2>&1 || die "no C++ compiler (${CXX:-c++}) on PATH; run inside codetracer's dev shell"

work="$(mktemp -d "${TMPDIR:-/tmp}/image-diff-consumers.XXXXXX")" || die "mktemp failed"
# shellcheck disable=SC2329 # invoked by the EXIT trap
cleanup() {
	if [ "${IMAGE_DIFF_CONSUMERS_KEEP:-}" = 1 ]; then
		echo "image-diff-consumers: kept $work" >&2
	else
		rm -rf "$work"
	fi
}
trap cleanup EXIT

passed=0 failed=0 skipped=0
problems=()

# check_one NAME LOG RC: a check that counts as one test.
check_one() {
	if [ "$3" -eq 0 ]; then
		passed=$((passed + 1))
		printf '  %-60s ok\n' "$1"
	else
		failed=$((failed + 1))
		problems+=("$1: failed (exit $3)")
		printf '  %-60s FAILED (exit %s)\n' "$1" "$3"
		tail -n 30 "$2" | sed 's/^/    | /'
	fi
}

# --- 1. the PLAT-37 parity suite, through real FLIP ------------------------------
echo "=== image-diff-consumers: ci/test/plat37-parity.sh --test (the C ABI shim + real FLIP)"
plat_log="$work/plat37-parity.log"
plat_rc=0
bash ci/test/plat37-parity.sh --test -v >"$plat_log" 2>&1 || plat_rc=$?
# unittest's verbose summary: `Ran N tests` and then `OK`, `OK (skipped=S)` or
# `FAILED (failures=F, errors=E, skipped=S)`.
ran="$(sed -nE 's/^Ran ([0-9]+) tests? in .*/\1/p' "$plat_log" | tail -n 1)"
verdict="$(grep -E '^(OK|FAILED)( \(.*\))?$' "$plat_log" | tail -n 1)"
if [ -z "$ran" ] || [ -z "$verdict" ]; then
	failed=$((failed + 1))
	problems+=("plat37-parity --test: no unittest summary (exit $plat_rc); it did not run")
	tail -n 30 "$plat_log" | sed 's/^/    | /'
else
	# field NAME -> the count unittest printed for NAME, 0 when absent.
	field() {
		local v
		v="$(sed -nE "s/.*[(, ]$1=([0-9]+).*/\\1/p" <<<"$verdict")"
		echo "${v:-0}"
	}
	p_fail=$(($(field failures) + $(field errors) + $(field 'unexpected successes')))
	p_skip=$(($(field skipped) + $(field 'expected failures')))
	p_exec=$((ran - p_skip))
	if [ "$plat_rc" -ne 0 ] && [ "$p_fail" -eq 0 ]; then p_fail=1; fi
	if [[ $verdict == FAILED* ]] && [ "$p_fail" -eq 0 ]; then p_fail=1; fi
	passed=$((passed + p_exec - p_fail))
	failed=$((failed + p_fail))
	skipped=$((skipped + p_skip))
	printf '  %-60s ran=%s failed=%s skipped=%s (%s)\n' "plat37-parity --test" "$ran" "$p_fail" "$p_skip" "$verdict"
	[ "$p_fail" -eq 0 ] || {
		problems+=("plat37-parity --test: $p_fail failed (exit $plat_rc); see the log tail above")
		grep -E '^(FAIL|ERROR):|Error|assert' "$plat_log" | head -n 20 | sed 's/^/    | /'
		tail -n 30 "$plat_log" | sed 's/^/    | /'
	}
	[ "$p_skip" -eq 0 ] || problems+=("plat37-parity --test: $p_skip skipped; no skip is allowed in this lane")
fi

# --- 2. every Nim module that imports image_diff ---------------------------------
echo "=== image-diff-consumers: compile the Nim modules that import image_diff"
for m in "${modules[@]}"; do
	stem="$(basename "$m" .nim)"
	for backend in c cpp; do
		log="$work/$stem.$backend.log"
		rc=0
		nim "$backend" --hints:off -d:release --path:"$LIB_DIR/src" \
			--nimcache:"$work/nimcache/$stem.$backend" -o:"$work/bin/$stem.$backend" \
			"$m" >"$log" 2>&1 || rc=$?
		check_one "nim $backend $m" "$log" "$rc"
	done
done

# --- 3. the flake input, locked to the checkout under test -----------------------
echo "=== image-diff-consumers: lock flake input codetracer-image-diff to $lib_rev"
lock_log="$work/flake-lock.log"
out_lock="$work/flake.lock"
rc=0
nix flake lock --override-input codetracer-image-diff "git+file://$LIB_DIR?rev=$lib_rev" \
	--output-lock-file "$out_lock" "$REPO_ROOT?submodules=1" >"$lock_log" 2>&1 || rc=$?
if [ "$rc" -eq 0 ]; then
	locked="$(
		python3 - "$out_lock" <<'PYTHON' 2>>"$lock_log"
import json, sys
node = json.load(open(sys.argv[1]))["nodes"]["codetracer-image-diff"]["locked"]
print(node.get("rev", ""), node.get("narHash", ""))
PYTHON
	)" || rc=1
	read -r locked_rev locked_nar <<<"${locked:-}"
	if [ "$rc" -eq 0 ] && { [ "${locked_rev:-}" != "$lib_rev" ] || [ -z "${locked_nar:-}" ]; }; then
		echo "the lock records codetracer-image-diff at rev='${locked_rev:-}' narHash='${locked_nar:-}', not $lib_rev" >>"$lock_log"
		rc=1
	fi
fi
check_one "nix flake lock --override-input codetracer-image-diff" "$lock_log" "$rc"

# --- report -------------------------------------------------------------------------
executed=$((passed + failed))
[ "$executed" -gt 0 ] || problems+=("no test was executed")
if [ "${#problems[@]}" -gt 0 ]; then
	echo "PROBLEMS:"
	printf '  %s\n' "${problems[@]}"
fi
echo "TEST-COUNTS: executed=$executed passed=$passed failed=$failed skipped=$skipped"
[ "${#problems[@]}" -eq 0 ]
