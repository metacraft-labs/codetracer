#!/usr/bin/env bash
#
# run-nim-test-lane.sh — compile and run one Nim test lane, and report what
# actually happened to every file in it.
#
# WHY THIS EXISTS
# ---------------
# Six `just` recipes had each grown their own copy of "loop over some files,
# `nim c -r` each, count [OK] lines". Every copy drifted: some scored the tally
# before the exit status (the bug ci/lib/test-lane-report.sh exists to prevent),
# some threw away the one diagnostic line that named a missing shared library,
# some could not observe a non-zero exit at all. Adding a lane meant copying the
# loop a seventh time and inheriting whichever bugs the donor still had.
#
# So there is one loop, here, and lanes differ only in DATA:
# ci/lib/test-lane-files.sh says which files and which compiler flags, and this
# script says what running them means. A new lane is a one-line `just` recipe.
#
# Behaviour worth knowing:
#
#   * Compile and run are SEPARATE steps, never a single `nim c -r`. Conflating
#     them turns "the binary could not find libsqlite3" into "COMPILE ERROR",
#     and then prints only lines matching `Error:` — which that diagnostic does
#     not match, so the one line naming the missing library is discarded.
#
#   * The run inherits CT_LD_LIBRARY_PATH (the dev shell's
#     sqlite/pcre/glib/openssl/zstd set). It is applied to the RUN only, never
#     to the compile, so those libraries are not put in front of the Nim
#     compiler's own loader path.
#
#   * The verdict comes from ci/lib/test-lane-report.sh, which reads the exit
#     status before the [OK]/[FAILED] tally. A lane must never invent `OK (0
#     tests)` for a binary that produced nothing.
#
#   * A lane that ran zero cases fails. A glob that silently matches nothing,
#     or suites that compile but assert nothing, is not a pass — it is the same
#     invisible-coverage failure this whole area is about.
#
# Usage:
#   bash ci/lib/run-nim-test-lane.sh <lane-id> [--compile-only]
#
# Environment:
#   CT_NIM_CACHE_ROOT  nimcache root (default /tmp/ct-nim-cache)
#   CT_LANE_TIMEOUT    per-file timeout in seconds (default 1800)

set -uo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${repo_root}" || exit 2

# shellcheck source=ci/lib/test-lane-files.sh
# shellcheck disable=SC1091 # resolved at runtime from $repo_root
source "${repo_root}/ci/lib/test-lane-files.sh"
# shellcheck source=ci/lib/test-lane-report.sh
# shellcheck disable=SC1091 # resolved at runtime from $repo_root
source "${repo_root}/ci/lib/test-lane-report.sh"

lane="${1:-}"
if [ -z "${lane}" ]; then
	echo "usage: run-nim-test-lane.sh <lane-id> [--compile-only]" >&2
	echo "lanes:" >&2
	test_lane_ids | sed 's/^/  /' >&2
	exit 2
fi
shift

compile_only=0
while [ $# -gt 0 ]; do
	case "$1" in
	--compile-only) compile_only=1 ;;
	*)
		echo "run-nim-test-lane.sh: unknown argument '$1'" >&2
		exit 2
		;;
	esac
	shift
done

cache_root="${CT_NIM_CACHE_ROOT:-/tmp/ct-nim-cache}"
lane_timeout="${CT_LANE_TIMEOUT:-1800}"
backend="$(test_lane_backend "${lane}")"
read -r -a extra_flags <<<"$(test_lane_extra_flags "${lane}")"

mkdir -p test-logs "${cache_root}"

echo "=== ${lane}: $(test_lane_description "${lane}") ==="
if [ "${compile_only}" -eq 1 ]; then
	echo "    (compile-only: these files are never executed — see"
	echo "     ci/lib/test-lane-files.sh for why)"
fi

failed=0
passed=0
total_oks=0
files=0

while read -r f; do
	[ -n "${f}" ] || continue
	files=$((files + 1))
	name="$(basename "${f}" .nim)"
	cache="${cache_root}/${lane}-${name}"
	printf '  %s ... ' "${f}"

	if [ "${backend}" = "js" ]; then
		# `-d:nodejs` is load-bearing: without it `std/exitprocs
		# .setProgramResult` is undeclared on the JS target, `std/unittest`
		# substitutes a no-op, and node exits 0 even when a case fails.
		compile_cmd=(nim js -d:nodejs --hints:off --warnings:off
			"${extra_flags[@]}" --nimcache:"${cache}" -o:"${cache}/${name}.js" "${f}")
		artifact="${cache}/${name}.js"
	else
		compile_cmd=(nim c --hints:off --warnings:off
			"${extra_flags[@]}" --nimcache:"${cache}" -o:"${cache}/${name}" "${f}")
		artifact="${cache}/${name}"
	fi

	if ! compile_output="$(timeout "${lane_timeout}" "${compile_cmd[@]}" 2>&1)"; then
		echo "COMPILE ERROR"
		printf '%s\n' "${compile_output}" | grep -E 'Error:' | head -3 | sed 's/^/      /'
		failed=$((failed + 1))
		continue
	fi

	if [ "${compile_only}" -eq 1 ]; then
		echo "COMPILES (not executed)"
		passed=$((passed + 1))
		continue
	fi

	ct_libs="${CT_LD_LIBRARY_PATH:-${CODETRACER_LD_LIBRARY_PATH:-}}"
	if [ "${backend}" = "js" ]; then
		output="$(timeout "${lane_timeout}" node "${artifact}" 2>&1)" && rc=0 || rc=$?
	else
		output="$(LD_LIBRARY_PATH="${ct_libs}${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" \
			timeout "${lane_timeout}" "${artifact}" 2>&1)" && rc=0 || rc=$?
	fi

	oks="$(printf '%s\n' "${output}" | grep -c '\[OK\]' || true)"
	fails="$(printf '%s\n' "${output}" | grep -c '\[FAILED\]' || true)"
	total_oks=$((total_oks + oks))
	verdict="$(classify_test_run "${rc}" "${oks}" "${fails}")"
	test_run_headline "${verdict}" "${rc}" "${oks}" "${fails}"

	case "${verdict}" in
	ok)
		passed=$((passed + 1))
		;;
	no-results)
		# It BUILT, so this is not a compile error: the binary could not start,
		# or ran and reported nothing. Show all of its output — the reason is in
		# there, and filtering is exactly what lost it last time (a
		# `could not load: libsqlite3.so` line that matched no `Error:` grep).
		printf '%s\n' "${output}" | head -20 | sed 's/^/      /'
		failed=$((failed + 1))
		;;
	crashed)
		# What it managed to report AND how it died: the traceback in the tail
		# names the line, which is what turns "it crashed" into "here is the
		# case that crashed it".
		printf '%s\n' "${output}" | grep '\[FAILED\]' | sed 's/^/      /'
		printf '%s\n' "${output}" | tail -20 | sed 's/^/      /'
		failed=$((failed + 1))
		;;
	silent-failure)
		printf '%s\n' "${output}" |
			grep -E 'Check failed|Error|Exception|SIGSEGV' | head -20 | sed 's/^/      /'
		failed=$((failed + 1))
		;;
	*)
		# `-B` is load-bearing, not decoration. Nim's `unittest` prints the
		# evidence -- `checkpoint` output, `Check failed: <expr>` and the
		# `<name> was <value>` lines -- BEFORE the `[FAILED] <test name>`
		# marker. Grepping for the marker alone therefore reports *that* a test
		# failed while showing none of *why*, which is how a real defect in this
		# repo's own trace_index migration cost a full extra
		# reproduce-from-scratch cycle: the lane said
		# `[FAILED] recording a real program produces a real container` and
		# discarded the `[codetracer] FATAL:` line immediately above it that
		# named the cause.
		#
		# Consolidating six hand-copied loops into this runner is precisely the
		# kind of change that quietly loses a lesson like that, so it is
		# recorded here rather than left to the reader of a diff.
		printf '%s\n' "${output}" |
			grep -B 25 -A 12 '\[FAILED\]' | head -120 | sed 's/^/      /'
		failed=$((failed + 1))
		;;
	esac
done < <(test_lane_files "${lane}")

echo ""
echo "${lane}: ${passed} file(s) passed, ${failed} failed, ${total_oks} case(s)"

# Vacuous-pass guards. A lane whose file list is empty, or whose files all
# compiled and asserted nothing, must not read as green: that is the same
# invisible-coverage failure the lane exists to prevent, one level up.
if [ "${files}" -eq 0 ]; then
	echo "ERROR: lane '${lane}' matched no files at all." >&2
	exit 1
fi
if [ "${compile_only}" -eq 0 ] && [ "${total_oks}" -eq 0 ]; then
	echo "ERROR: lane '${lane}' ran ${files} file(s) but reported no test cases." >&2
	exit 1
fi

[ "${failed}" -eq 0 ]
