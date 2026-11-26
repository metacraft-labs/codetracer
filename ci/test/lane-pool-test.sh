#!/usr/bin/env bash
#
# lane-pool-test.sh — contract suite for the file pool in
# ci/lib/run-nim-test-lane.sh (sized by ci/lib/job-pool.sh).
#
# The runner may build and run several files of a lane at once. What it must
# not do is let that show: the report has to come out in the lane's own file
# order, with the same verdicts and totals as a serial run, a failing file's
# whole output has to be in it, and every file has to have a time. These
# contracts RUN the runner, in a scratch repository whose `nim` copies the
# fixture to the artifact path, so each "test binary" is a shell script:
#
#   1. a pool of three runs files at the same time (the fixtures record their
#      start and end), never more than three;
#   2. the report lists the files in lane order although the first file is
#      the slowest and finishes after the files behind it;
#   3. the failing file fails the lane, and the totals are the serial run's;
#   4. the failing file's output is printed in full, including a line far
#      past the excerpt its verdict prints;
#   5. the pool's report is the serial run's, line for line (but for the line
#      that names the pool size);
#   6. test-logs/<lane>.timings.tsv has one row per file, in lane order, with
#      its outcome;
#   7. a file that does not compile is reported with the compiler's whole
#      output, and the files after it still run.
#
# Hermetic and a few seconds long.

set -uo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
scratch="$(mktemp -d "${TMPDIR:-/tmp}/lane-pool-test.XXXXXX")"
trap 'rm -rf "${scratch}"' EXIT

passes=0
failures=0
t_pass() {
	passes=$((passes + 1))
	echo "  ok   $1"
}
t_fail() {
	failures=$((failures + 1))
	echo "  FAIL $1" >&2
}

fake="${scratch}/repo"
mkdir -p "${fake}/ci/lib" "${fake}/tests" "${scratch}/bin" "${scratch}/tmp" "${scratch}/home"
cp "${repo_root}/ci/lib/run-nim-test-lane.sh" \
	"${repo_root}/ci/lib/codetracer-home.sh" \
	"${repo_root}/ci/lib/job-pool.sh" \
	"${repo_root}/ci/lib/test-lane-report.sh" \
	"${repo_root}/ci/lib/known_failures.py" "${fake}/ci/lib/"
: >"${fake}/ci/lib/known-test-failures.tsv"

cat >"${fake}/ci/lib/test-lane-files.sh" <<'LANES'
test_lane_ids() { printf '%s\n' pool pool-compile; }
test_lane_recipe() { echo ""; }
test_lane_file_skip_reason() { :; }
test_lane_backend() { echo "c"; }
test_lane_extra_flags() { echo ""; }
test_lane_run_library_path() { echo ""; }
test_lane_is_compile_only() { echo "0"; }
test_lane_parallel_safe() { echo "1"; }
test_lane_description() { echo "lane-pool-test fixture lane $1"; }
test_lane_files() {
	case "$1" in
	pool)
		echo tests/test_a_slow.nim
		echo tests/test_b.nim
		echo tests/test_c_fails.nim
		echo tests/test_d.nim
		echo tests/test_e.nim
		echo tests/test_f.nim
		;;
	pool-compile)
		echo tests/test_b.nim
		echo tests/test_x_broken.nim
		echo tests/test_d.nim
		;;
	esac
}
LANES

# `nim c ... -o:<artifact> <file>`: the artifact is the fixture itself; a
# fixture whose name says "broken" does not compile.
cat >"${scratch}/bin/nim" <<'NIM'
#!/usr/bin/env bash
out=""
src=""
for a in "$@"; do
	case "$a" in
	-o:*) out="${a#-o:}" ;;
	-*) ;;
	c) ;;
	*) src="$a" ;;
	esac
done
case "$src" in
*broken*)
	for i in $(seq 1 60); do echo "broken.nim(${i}, 1) template/generic instantiation from here"; done
	echo "broken.nim(61, 3) Error: undeclared identifier: 'nope'"
	echo "COMPILER-TAIL-MARKER"
	exit 1
	;;
esac
mkdir -p "$(dirname "$out")"
cp "$src" "$out" && chmod +x "$out"
NIM
chmod +x "${scratch}/bin/nim"

fixture() { # NAME SECONDS [fail]
	cat <<FIX
#!/usr/bin/env bash
echo "start \$(date +%s.%N) $1" >>"${scratch}/tmp/spans.txt"
sleep $2
echo "end \$(date +%s.%N) $1" >>"${scratch}/tmp/spans.txt"
echo "[OK] $1 first"
echo "[OK] $1 second"
FIX
	if [ "${3:-}" = fail ]; then
		cat <<'FIX'
for i in $(seq 1 300); do echo "noise line ${i}"; done
echo "DEEP-FAILURE-MARKER the cause is here"
for i in $(seq 1 300); do echo "more noise ${i}"; done
echo "  Check failed: x == 1"
echo "[FAILED] it fails"
exit 1
FIX
	fi
}
fixture test_a_slow 2 >"${fake}/tests/test_a_slow.nim"
fixture test_b 0.3 >"${fake}/tests/test_b.nim"
fixture test_c_fails 0.3 fail >"${fake}/tests/test_c_fails.nim"
fixture test_d 0.3 >"${fake}/tests/test_d.nim"
fixture test_e 0.3 >"${fake}/tests/test_e.nim"
fixture test_f 0.3 >"${fake}/tests/test_f.nim"
cp "${fake}/tests/test_b.nim" "${fake}/tests/test_x_broken.nim"

run_lane() { # LANE JOBS OUT
	rm -f "${scratch}/tmp/spans.txt"
	(
		cd "${fake}" || exit 2
		env -u CODETRACER_HOME -u CODETRACER_TUI_LAYOUT_DIR -u XDG_STATE_HOME \
			-u XDG_DATA_HOME -u XDG_CONFIG_HOME -u GITHUB_ACTIONS \
			HOME="${scratch}/home" TMPDIR="${scratch}/tmp" CT_LANE_JOBS="$2" \
			PATH="${scratch}/bin:${PATH}" CT_NIM_CACHE_ROOT="${scratch}/cache" \
			bash ci/lib/run-nim-test-lane.sh "$1"
	) >"$3" 2>&1
	echo $?
}

echo "lane-pool-test:"

rc_par="$(run_lane pool 3 "${scratch}/par.out")"
cp "${fake}/test-logs/pool.timings.tsv" "${scratch}/par.timings.tsv" 2>/dev/null
spans="$(cat "${scratch}/tmp/spans.txt" 2>/dev/null)"
rc_ser="$(run_lane pool 1 "${scratch}/ser.out")"

# 1. Concurrency, bounded by the pool.
max_live="$(printf '%s\n' "${spans}" | sort -k2,2n | awk '$1 == "start" {n++; if (n > m) m = n} $1 == "end" {n--} END {print m + 0}')"
if [ "${max_live}" -ge 2 ] && [ "${max_live}" -le 3 ]; then
	t_pass "a pool of 3 ran up to ${max_live} files at the same time"
else
	t_fail "a pool of 3 ran at most ${max_live} file(s) at once (want 2 or 3)"
	printf '%s\n' "${spans}" | sed 's/^/       /' >&2
fi

# 2. Lane order, although test_a_slow finished last.
order="$(grep -oE 'tests/test_[a-z_]+\.nim \.\.\.' "${scratch}/par.out" | sed 's/ \.\.\.//' | tr '\n' ' ')"
want="tests/test_a_slow.nim tests/test_b.nim tests/test_c_fails.nim tests/test_d.nim tests/test_e.nim tests/test_f.nim "
a_end="$(printf '%s\n' "${spans}" | awk '$1 == "end" && $3 == "test_a_slow" {print $2}')"
b_end="$(printf '%s\n' "${spans}" | awk '$1 == "end" && $3 == "test_b" {print $2}')"
if [ "${order}" = "${want}" ] && awk -v a="${a_end:-0}" -v b="${b_end:-0}" 'BEGIN {exit !(b > 0 && a > b)}'; then
	t_pass "the report is in lane order although the first file finished after the second"
else
	t_fail "report order '${order}' (test_a_slow ended ${a_end}, test_b ${b_end})"
fi

# 3. The failing file fails the lane, with the serial run's totals.
if [ "${rc_par}" = 1 ] && [ "${rc_ser}" = 1 ] &&
	grep -qF 'pool: 5 file(s) passed, 1 failed, 12 case(s)' "${scratch}/par.out"; then
	t_pass "the failing file fails the lane: 5 passed, 1 failed, 12 cases"
else
	t_fail "rc parallel=${rc_par} serial=${rc_ser}; summary: $(grep '^pool:' "${scratch}/par.out" | head -1)"
fi

# 4. Its whole output, past the excerpt.
if grep -q 'DEEP-FAILURE-MARKER the cause is here' "${scratch}/par.out" &&
	grep -q 'more noise 300' "${scratch}/par.out" &&
	grep -q -- '--- tests/test_c_fails.nim: full test output ---' "${scratch}/par.out"; then
	t_pass "the failing file's whole output is in the report"
else
	t_fail "the failing file's output is not all there"
fi

# 5. Pool and serial reports are the same report.
if diff <(grep -v 'file(s) at a time' "${scratch}/ser.out") \
	<(grep -v 'file(s) at a time' "${scratch}/par.out") >"${scratch}/diff.txt"; then
	t_pass "the pool's report is the serial run's, line for line"
else
	t_fail "the pool's report differs from the serial run's:"
	sed 's/^/       /' "${scratch}/diff.txt" >&2
fi

# 6. One timing row per file, in lane order, with its outcome.
rows="$(tail -n +2 "${scratch}/par.timings.tsv" 2>/dev/null | cut -f1,2 | tr '\t\n' ': ')"
want_rows="tests/test_a_slow.nim:passed tests/test_b.nim:passed tests/test_c_fails.nim:failed tests/test_d.nim:passed tests/test_e.nim:passed tests/test_f.nim:passed "
slow_run="$(awk -F'\t' '$1 == "tests/test_a_slow.nim" {print $4}' "${scratch}/par.timings.tsv" 2>/dev/null)"
if [ "${rows}" = "${want_rows}" ] && awk -v s="${slow_run:-0}" 'BEGIN {exit !(s >= 1.5)}'; then
	t_pass "timings.tsv has every file in order, and the slow file's run time (${slow_run}s)"
else
	t_fail "timings rows '${rows}', slow run '${slow_run}'"
fi

# 7. A compile error: the whole compiler output, and the lane goes on.
rc_c="$(run_lane pool-compile 3 "${scratch}/compile.out")"
if [ "${rc_c}" = 1 ] && grep -q 'tests/test_x_broken.nim ... COMPILE ERROR' "${scratch}/compile.out" &&
	grep -q 'COMPILER-TAIL-MARKER' "${scratch}/compile.out" &&
	grep -q 'tests/test_d.nim ... OK' "${scratch}/compile.out"; then
	t_pass "a compile error shows the compiler's whole output, and the next file still runs"
else
	t_fail "compile-error contract (rc ${rc_c}):"
	sed 's/^/       /' "${scratch}/compile.out" | tail -20 >&2
fi

echo
if [ "${failures}" -eq 0 ]; then
	echo "all ${passes} assertions passed"
	exit 0
fi
echo "${failures} of $((passes + failures)) assertions failed" >&2
exit 1
