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
#                  compile, or failed to start.
#
#                  THIS LINE USED TO END "or asserted nothing", AND THAT WAS
#                  FALSE. `oks` is `grep -c '\[OK\]'`, and `std/unittest` prints
#                  one `[OK] <name>` PER TEST BLOCK THAT DID NOT FAIL — never one
#                  per `check`. Measured on this host with the repo's own Nim:
#
#                      suite "a suite that asserts nothing":
#                        test "case one asserts nothing":
#                          discard
#
#                  prints `[OK] case one asserts nothing` and exits 0. A file of
#                  fifty empty cases scores `OK (50 tests)`. This classifier
#                  cannot see assertions at all; it counts case markers, and no
#                  amount of arithmetic over `[OK]` lines can become an assertion
#                  count. The `no-assertions` verdict below is the only branch
#                  that observes one, and only when the file DECLARES it.
#   no-assertions  the file declared `CHECKS: 0` — it ran cases and asserted
#                  nothing. An assertion that did not run is not an assertion
#                  that passed.
#   silent-failure it exited non-zero having printed no [FAILED] line. Two ways
#                  that happens and both are invisible otherwise: a `check`
#                  inside a plain `proc` (unittest's `fail` only marks the case
#                  when it expands inside a `test`), and a crash or `quit`
#                  after the last case.
#   partial        it reported at least one [FAILED]. The ordinary red run.
#   ok             every case reported [OK] and the process exited 0.
classify_test_run() {
	local rc="$1" oks="$2" fails="$3" checks="${4:-}"

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

	# THE ONLY BRANCH THAT OBSERVES AN ASSERTION RATHER THAN A CASE MARKER, and
	# it fires only when the file states its own count. A file that prints
	#
	#     CHECKS: 0
	#
	# ran its cases and asserted nothing, which every branch above reads as `ok`
	# because every branch above is counting `[OK]` lines. Ranked BELOW `partial`
	# and `silent-failure` on purpose: a file that failed has a more specific
	# story than one that asserted nothing, and the reader should get that one.
	#
	# An UNDECLARED count is deliberately NOT a failure here. Almost no file in
	# this tree declares one yet, so scoring absence would redden every lane on
	# day one — the guard-that-gets-switched-off argument this repository makes
	# about its other backlogs. It is instead COUNTED AND REPORTED by
	# `run-nim-test-lane.sh`, the same treatment `[SKIPPED]` gets and for the
	# same reason: the reader is told how much of the tally is unmeasured.
	if [ -n "${checks}" ] && [ "${checks}" -eq 0 ]; then
		echo "no-assertions"
		return 0
	fi

	echo "ok"
}

# test_run_headline VERDICT RC OKS FAILS [SKIPS]
#
# The one line a lane prints per test file. Every non-ok headline names the
# exit code, so a reader never has to infer it from the shape of the sentence.
#
# SKIPS IS OPTIONAL AND IS NOT PART OF THE VERDICT, deliberately.
#
# `std/unittest`'s `skip()` prints `[SKIPPED] <name>` and neither `[OK]` nor
# `[FAILED]`, so a suite that skips every case exits 0 with a tally the
# classifier above reads as `ok`. Measured on this tree:
# `src/tests/gui/tests/integration/language_smoke_test.nim` declares 15 cases
# across three languages and reported
#
#     src/tests/gui/tests/integration/language_smoke_test.nim ... OK (5 tests)
#
# on a machine with only the Python recorder built. Ten cases had announced
# `SKIP: Ruby recorder not available` / `SKIP: Noir recorder not available`
# and the lane's own summary said nothing. That is the same shape as the
# crash this file exists to catch — a green line that is a prefix of the run —
# and it is worth naming even though the remedy differs.
#
# The remedy differs because a missing cross-repo recorder is a DECLARED,
# supported condition here (`viewmodel/tests/unit/recorder_gate.nim` exists to
# make it uniform and greppable), not a defect. Failing the lane on it would
# make every developer machine without six recorder siblings permanently red,
# and a lane that is always red is a lane nobody reads. So the count is
# REPORTED and never scored: `ok` still means `ok`, and the reader is told how
# much of the file it covers.
test_run_headline() {
	local verdict="$1" rc="$2" oks="$3" fails="$4" skips="${5:-0}"
	local skipped_note=""
	if [ "${skips}" -gt 0 ]; then
		skipped_note=", ${skips} SKIPPED"
	fi
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
	no-assertions)
		echo "ASSERTED NOTHING (exit ${rc}, ${oks} [OK] case(s), CHECKS: 0) —" \
			"the cases ran and made no assertion; a case marker is not an assertion"
		;;
	silent-failure)
		echo "FAILED WITHOUT A [FAILED] LINE (exit ${rc}, ${oks} OK)"
		;;
	partial)
		echo "PARTIAL (${oks} OK, ${fails} FAILED${skipped_note}, exit ${rc})"
		;;
	ok)
		echo "OK (${oks} tests${skipped_note})"
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
