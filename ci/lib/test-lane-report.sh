#!/usr/bin/env bash
#
# test-lane-report.sh — the shared verdict for "compile a Nim test file, run it,
# say what happened".
#
# WHY THIS EXISTS
# ---------------
# Six `just` recipes (`test-vm-native`, `test-vm-js`, `test-cli-record`,
# `test-ct-trace-units`, `test-mcr-enrichment-units`, `test-vm-recorder-gated`)
# each grew their own copy of the same classifier, and each copy scored the
# `[OK]`/`[FAILED]` tally BEFORE the process's exit status. That ordering has a
# specific, silent failure mode:
#
#     src/tests/gui/tests/views/isonim_views_test.nim ... PARTIAL (212 OK, 4 FAILED)
#
# That line was printed by a binary that had SEGV-ed. The file declares 461
# cases; a nil `MockNode` dereference killed the process at case 216 and the
# remaining 245 — 53% of the file — never ran. Nothing in the report said so,
# because the tally branch matched first and a tally cannot count cases that
# were never reached. `PARTIAL (212 OK, 4 FAILED)` is exactly what an ordinary
# partial run prints, so the crash hid inside a shape the reader had learned to
# skim.
#
# So the rule this file exists to enforce: THE EXIT STATUS IS READ FIRST. A
# process that died is reported as having died, in its own vocabulary, before
# any count of the lines it managed to print is consulted.
#
# It is a sourceable library rather than six inline `if` chains so that the
# classification can be tested directly, without a Nim toolchain and without
# running a real lane — see `ci/test/test-lane-report-test.sh`, which feeds it
# fixture processes that print plausible `[OK]` lines and then abort.
#
# Usage:
#   source ci/lib/test-lane-report.sh
#   output=$(some_test_binary 2>&1) && rc=0 || rc=$?
#   oks=$(echo "$output" | grep -c '\[OK\]' || true)
#   fails=$(echo "$output" | grep -c '\[FAILED\]' || true)
#   verdict=$(classify_test_run "$rc" "$oks" "$fails")
#   test_run_headline "$verdict" "$rc" "$oks" "$fails"

# classify_test_run RC OKS FAILS
#
# Prints exactly one verdict token on stdout:
#
#   crashed        the process was killed by a signal. Whatever it printed is a
#                  prefix of the run, not the run.
#   no-results     it produced no [OK] and no [FAILED] at all: it failed to
#                  compile, failed to start, or asserted nothing.
#   silent-failure it exited non-zero having printed no [FAILED] line. Two ways
#                  that happens and both are invisible otherwise: a `check`
#                  inside a plain `proc` (unittest's `fail` only marks the case
#                  when it expands inside a `test`), and a crash or `quit`
#                  after the last case.
#   partial        it reported at least one [FAILED]. The ordinary red run.
#   ok             every case reported [OK] and the process exited 0.
classify_test_run() {
	local rc="$1" oks="$2" fails="$3"

	# FIRST, and deliberately so: a death by signal outranks every count.
	# Bash reports a signalled child as 128+N, and no Nim `unittest` run exits
	# in that range on purpose.
	if [ "${rc}" -gt 128 ]; then
		echo "crashed"
		return 0
	fi

	if [ "${oks}" -eq 0 ] && [ "${fails}" -eq 0 ]; then
		echo "no-results"
		return 0
	fi

	# Still ahead of the tally: non-zero with nothing claiming to have failed.
	if [ "${rc}" -ne 0 ] && [ "${fails}" -eq 0 ]; then
		echo "silent-failure"
		return 0
	fi

	if [ "${fails}" -gt 0 ]; then
		echo "partial"
		return 0
	fi

	if [ "${rc}" -ne 0 ]; then
		echo "silent-failure"
		return 0
	fi

	echo "ok"
}

# test_run_headline VERDICT RC OKS FAILS
#
# The one line a lane prints per test file. Every non-ok headline names the
# exit code, so a reader never has to infer it from the shape of the sentence.
test_run_headline() {
	local verdict="$1" rc="$2" oks="$3" fails="$4"
	case "${verdict}" in
	crashed)
		# Never the word PARTIAL, and never a bare count: the counts are a
		# prefix and saying so is the whole point of this branch.
		echo "CRASHED — killed by signal $((rc - 128)) (exit ${rc}) after printing" \
			"${oks} [OK] and ${fails} [FAILED]; THE REST OF THE SUITE NEVER RAN"
		;;
	no-results)
		echo "DID NOT RUN (exit ${rc}; no [OK] or [FAILED] lines — compile error," \
			"or the binary produced no test results)"
		;;
	silent-failure)
		echo "FAILED WITHOUT A [FAILED] LINE (exit ${rc}, ${oks} OK)"
		;;
	partial)
		echo "PARTIAL (${oks} OK, ${fails} FAILED, exit ${rc})"
		;;
	ok)
		echo "OK (${oks} tests)"
		;;
	*)
		echo "UNKNOWN VERDICT '${verdict}' (exit ${rc}, ${oks} OK, ${fails} FAILED)"
		;;
	esac
}

# test_run_is_failure VERDICT — returns 0 when the lane must count this file as
# failed. Kept next to the classifier so no caller has to re-derive the set.
test_run_is_failure() {
	case "$1" in
	ok) return 1 ;;
	*) return 0 ;;
	esac
}
