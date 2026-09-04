#!/usr/bin/env bash
#
# test-lane-report-test.sh — contract suite for ci/lib/test-lane-report.sh, the
# shared verdict every compile-and-run test lane in the justfile reports through.
#
# WHY THIS EXISTS
# ---------------
# This is the FOURTH and FIFTH variant of "tests that do not run but look like
# they pass" found in this repo:
#
#   1. a `check` inside a top-level `proc` printed [OK] while the process
#      exited 1 (unittest's `fail` only marks the case when it expands inside a
#      `test`);
#   2. lane runners that discarded the exit code entirely;
#   3. Playwright tests that swallowed their own failure in a `catch` and
#      reported themselves skipped;
#   4. and this one — a lane that scored the [OK]/[FAILED] tally BEFORE the
#      exit status, so a binary killed by SIGSEGV mid-run was reported as
#
#          src/tests/gui/tests/views/isonim_views_test.nim ... PARTIAL (212 OK, 4 FAILED)
#
#      That file declares 461 cases. A nil `MockNode` dereference killed the
#      process at case 216; the remaining 245 never ran. The report said
#      nothing a reader could distinguish from an ordinary partial run, because
#      a tally cannot count cases that were never reached.
#   5. and a lane that reported `OK (5 tests)` for a file declaring fifteen,
#      because `std/unittest`'s `skip()` prints neither [OK] nor [FAILED] and
#      exits 0. Measured on `integration/language_smoke_test.nim` with only one
#      of its three recorders built. Contracts 11-13 cover it; unlike the other
#      four it is REPORTED rather than scored, and the reason is written up
#      above `test_run_headline`.
#
# The class is recurrent enough to deserve a standing guard, so the contracts
# below do not grep the classifier — they RUN it, against fixture processes
# that print plausible `[OK]` lines and then die. If the exit status ever slips
# back behind the tally, contract 1 fails.
#
# DESIGN CONSTRAINTS
# ------------------
# Cheap and hermetic: the fixtures are shell scripts, not Nim binaries, so this
# suite needs no compiler, no dev shell and no network, and runs in well under
# a second on a stock runner. What it exercises is the exact function the six
# lanes call, sourced from the exact file they source.
#
# The suite carries its own mutation. Contract 5 re-implements the PRE-FIX
# ordering (tally first) and asserts that it *would* mislabel the crash fixture
# as PARTIAL. Without that, a future refactor could make every other contract
# vacuously true and nobody would notice; with it, this file states in
# executable form what the bug actually was and that the fixture reproduces it.
#
# Run directly:  bash ci/test/test-lane-report-test.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
LIB="${REPO_ROOT}/ci/lib/test-lane-report.sh"
JUSTFILE="${REPO_ROOT}/justfile"

# Every contract below, counted once. The reconciliation at the end fails
# loudly if this disagrees with what actually ran, so a contract can never go
# missing silently.
#
# 13 -> 16 on 2026-09-04, for the three assertion-count contracts: `CHECKS: 0`
# is a failure, `CHECKS: 7` is not, and a file declaring nothing classifies
# exactly as it did before. The number went UP because the suite gained three
# contracts; it is raised here, in the same diff, rather than the reconciliation
# being relaxed — that check caught this edit and is the reason it is correct.
TOTAL_CONTRACTS=16

pass_count=0

fail() {
	echo "test-lane-report-test: FAIL: $1" >&2
	shift
	for line in "$@"; do echo "    ${line}" >&2; done
	exit 1
}

ok() {
	pass_count=$((pass_count + 1))
	echo "  ok — $1"
}

[ -f "${LIB}" ] || fail "ci/lib/test-lane-report.sh not found at ${LIB}"
[ -f "${JUSTFILE}" ] || fail "justfile not found at ${JUSTFILE}"

# The library is resolved at runtime from REPO_ROOT; shellcheck cannot
# follow a computed path without -x, and the lint gate does not pass it.
# shellcheck source=../lib/test-lane-report.sh
# shellcheck disable=SC1091
source "${LIB}"

tmp_dir="$(mktemp -d)"
trap 'rm -rf "${tmp_dir}"' EXIT

# --- fixtures --------------------------------------------------------------
#
# Each prints output a lane would find entirely plausible, then ends in a
# specific way. They are the only thing standing between this suite and a set
# of assertions about a classifier nobody ever fed a crash.

# A suite that gets a long way, reports real results, and is then killed by a
# signal — the isonim_views_test shape.
cat >"${tmp_dir}/crash.sh" <<'EOF'
#!/usr/bin/env bash
echo "[Suite] A perfectly ordinary suite"
for i in 1 2 3 4 5 6 7 8 9 10 11 12; do echo "  [OK] case ${i}"; done
echo "  [FAILED] a case that genuinely failed"
echo "SIGSEGV: Illegal storage access. (Attempt to read from nil?)"
kill -SEGV $$
EOF

# A suite whose every case says [OK] and whose process still exits non-zero:
# a `check` in a plain `proc`, or a `quit` after the last case.
cat >"${tmp_dir}/silent.sh" <<'EOF'
#!/usr/bin/env bash
echo "[Suite] All green, red process"
for i in 1 2 3; do echo "  [OK] case ${i}"; done
exit 1
EOF

# The ordinary red run, which must keep reading as PARTIAL.
cat >"${tmp_dir}/partial.sh" <<'EOF'
#!/usr/bin/env bash
echo "[Suite] Ordinary partial"
echo "  [OK] case 1"
echo "  [FAILED] case 2"
exit 1
EOF

# The ordinary green run.
cat >"${tmp_dir}/green.sh" <<'EOF'
#!/usr/bin/env bash
echo "[Suite] All green"
for i in 1 2 3; do echo "  [OK] case ${i}"; done
EOF

# Compiled/built but produced nothing — the vacuous-pass shape.
cat >"${tmp_dir}/empty.sh" <<'EOF'
#!/usr/bin/env bash
echo "could not load: libsqlite3.so(|.0)"
exit 1
EOF

# Green, and two thirds of it never ran. This is the fifth variant of "tests
# that do not run but look like they pass", and it was measured rather than
# imagined: `src/tests/gui/tests/integration/language_smoke_test.nim` on a
# machine with only the Python recorder built reported `OK (5 tests)` while ten
# of its fifteen cases printed `[SKIPPED]` after announcing a missing recorder.
# `std/unittest`'s `skip()` prints neither [OK] nor [FAILED] and exits 0, so
# the tally cannot see it at all.
cat >"${tmp_dir}/skippy.sh" <<'EOF'
#!/usr/bin/env bash
echo "[Suite] Language smoke: Python sudoku"
for i in 1 2 3 4 5; do echo "  [OK] python case ${i}"; done
echo "[Suite] Language smoke: Ruby sudoku"
echo "  SKIP: Ruby recorder not available: ct record failed (exit 1)"
for i in 1 2 3 4 5; do echo "  [SKIPPED] ruby case ${i}"; done
EOF

# THE SIXTH VARIANT, AND THE ONE `green.sh` ABOVE HAS ALWAYS BEEN. Three bare
# `[OK]` lines are EXACTLY what a file of three empty test cases prints —
# measured with this repo's own Nim on 2026-09-04:
#
#     suite "a suite that asserts nothing":
#       test "case one asserts nothing":
#         discard
#
#     [Suite] a suite that asserts nothing
#       [OK] case one asserts nothing
#
# `std/unittest` prints one `[OK]` per test BLOCK that did not fail, never one
# per `check`, and no formatter hook fires on a check that passes. So the count
# has to come from the file, and a file that states `CHECKS: 0` is saying it ran
# its cases and asserted nothing.
cat >"${tmp_dir}/zero-assertions.sh" <<'EOF'
#!/usr/bin/env bash
echo "[Suite] Cases that assert nothing"
for i in 1 2 3; do echo "  [OK] case ${i}"; done
echo "CHECKS: 0"
EOF

# And the same shape with the assertions actually made, which must stay green —
# otherwise the branch above is just a way to fail every file that declares.
cat >"${tmp_dir}/declared-assertions.sh" <<'EOF'
#!/usr/bin/env bash
echo "[Suite] Cases that assert"
for i in 1 2 3; do echo "  [OK] case ${i}"; done
echo "CHECKS: 7"
EOF

chmod +x "${tmp_dir}"/*.sh

# run_fixture NAME — sets the globals a lane would compute, exactly the way the
# lanes compute them, so the contracts test the real pipeline and not a
# hand-written triple of numbers.
run_fixture() {
	local script="${tmp_dir}/$1"
	set +e
	fixture_output="$("${script}" 2>&1)"
	fixture_rc=$?
	set -e
	fixture_oks=$(echo "${fixture_output}" | grep -c '\[OK\]' || true)
	fixture_fails=$(echo "${fixture_output}" | grep -c '\[FAILED\]' || true)
	fixture_skips=$(echo "${fixture_output}" | grep -c '\[SKIPPED\]' || true)
	# Extracted exactly as `run-nim-test-lane.sh` extracts it, for the reason in
	# this helper's own comment: the contracts have to test the real pipeline. An
	# absent declaration stays the empty string, which is the backward-compatible
	# case and must keep classifying as it always did.
	fixture_checks=""
	if echo "${fixture_output}" | grep -qE '^[[:space:]]*CHECKS:[[:space:]]*[0-9]+'; then
		fixture_checks=$(echo "${fixture_output}" |
			grep -oE '^[[:space:]]*CHECKS:[[:space:]]*[0-9]+' |
			grep -oE '[0-9]+' | awk '{s += $1} END {print s + 0}')
	fi
	fixture_verdict="$(classify_test_run "${fixture_rc}" "${fixture_oks}" \
		"${fixture_fails}" "${fixture_checks}")"
	fixture_headline="$(test_run_headline "${fixture_verdict}" "${fixture_rc}" \
		"${fixture_oks}" "${fixture_fails}" "${fixture_skips}")"
}

echo "test-lane-report contracts"

# --- 1. the headline defect ------------------------------------------------

run_fixture crash.sh
crash_headline="${fixture_headline}"
crash_oks="${fixture_oks}"
crash_fails="${fixture_fails}"
crash_rc="${fixture_rc}"

if [ "${fixture_verdict}" = "crashed" ]; then
	ok "a binary that prints 12 [OK] and then SIGSEGVs is classified 'crashed'"
else
	fail "a binary that prints 12 [OK] and then SIGSEGVs is classified 'crashed'" \
		"Got '${fixture_verdict}' for exit ${crash_rc}, ${crash_oks} OK," \
		"${crash_fails} FAILED. This is the isonim_views_test shape: if the" \
		"tally is scored before the exit status, a suite that died at case 216" \
		"of 461 is reported as a partial run and the 245 cases that never ran" \
		"leave no trace in the report."
fi

# --- 2. the headline must not be mistakable for a partial or a pass --------

if grep -qi 'partial' <<<"${crash_headline}"; then
	fail "the crash headline never contains the word PARTIAL" \
		"Got: ${crash_headline}" \
		"PARTIAL is the vocabulary of a run that finished. This one did not."
else
	ok "the crash headline never contains the word PARTIAL"
fi

if grep -qE '(^|[^A-Z])OK \(' <<<"${crash_headline}"; then
	fail "the crash headline is not shaped like the OK headline" \
		"Got: ${crash_headline}"
else
	ok "the crash headline is not shaped like the OK headline"
fi

# --- 3. it must say the rest never ran, and name the signal ----------------

if grep -q 'NEVER RAN' <<<"${crash_headline}" &&
	grep -q 'signal 11' <<<"${crash_headline}"; then
	ok "the crash headline names the signal and says the suite did not finish"
else
	fail "the crash headline names the signal and says the suite did not finish" \
		"Got: ${crash_headline}" \
		"Naming the signal is what tells a reader this was a crash rather than" \
		"an assertion, and saying the rest never ran is what stops the counts" \
		"from being read as the whole run."
fi

# --- 4. a crash is a lane failure, not a pass ------------------------------

if test_run_is_failure "${fixture_verdict}"; then
	ok "a crashed run counts as a failed file for the lane's exit status"
else
	fail "a crashed run counts as a failed file for the lane's exit status" \
		"The lane would have counted this file as passed."
fi

# --- 5. the mutation: prove the fixture reproduces the original bug --------
#
# This is the pre-fix ordering, verbatim in shape: tally first, exit code last.
# It MUST mislabel the crash fixture. If it stops doing so, the fixture no
# longer reproduces the defect and contracts 1-4 are decorative.
legacy_classify() {
	local rc="$1" oks="$2" fails="$3"
	if [ "${oks}" -eq 0 ] && [ "${fails}" -eq 0 ]; then
		echo "no-results"
	elif [ "${fails}" -gt 0 ]; then
		echo "partial"
	elif [ "${rc}" -ne 0 ]; then
		echo "silent-failure"
	else
		echo "ok"
	fi
}

legacy_verdict="$(legacy_classify "${crash_rc}" "${crash_oks}" "${crash_fails}")"
if [ "${legacy_verdict}" = "partial" ]; then
	ok "the pre-fix ordering does mislabel this fixture as 'partial' (red-before)"
else
	fail "the pre-fix ordering does mislabel this fixture as 'partial'" \
		"Got '${legacy_verdict}'. The fixture is supposed to reproduce the" \
		"original defect; if the old ordering no longer trips on it, this" \
		"suite is not testing what its header claims."
fi

# --- 7-9. the other verdicts must keep working ----------------------------

run_fixture silent.sh
if [ "${fixture_verdict}" = "silent-failure" ] &&
	grep -q 'exit 1' <<<"${fixture_headline}"; then
	ok "all-[OK] output over a non-zero exit is 'silent-failure' and names the code"
else
	fail "all-[OK] output over a non-zero exit is 'silent-failure'" \
		"Got '${fixture_verdict}': ${fixture_headline}"
fi

run_fixture partial.sh
if [ "${fixture_verdict}" = "partial" ] &&
	grep -q 'exit 1' <<<"${fixture_headline}"; then
	ok "an ordinary red run is still 'partial', and now names its exit code too"
else
	fail "an ordinary red run is still 'partial'" \
		"Got '${fixture_verdict}': ${fixture_headline}" \
		"Reclassifying ordinary failures would make the crash branch useless" \
		"noise, so this is as load-bearing as the crash contract."
fi

run_fixture green.sh
green_verdict="${fixture_verdict}"
run_fixture empty.sh
if [ "${green_verdict}" = "ok" ] && [ "${fixture_verdict}" = "no-results" ] &&
	! test_run_is_failure "${green_verdict}" &&
	test_run_is_failure "${fixture_verdict}"; then
	ok "a clean run passes and a run that produced no results does not"
else
	fail "a clean run passes and a run that produced no results does not" \
		"green='${green_verdict}', empty='${fixture_verdict}'" \
		"A build that reports nothing must never be scored 'OK (0 tests)'."
fi

# --- a declared assertion count is the only assertion evidence there is ----
#
# `green.sh` above — three bare `[OK]` lines — is byte-for-byte what a file of
# three EMPTY test cases prints, and this suite has always certified it as `ok`.
# That is correct and stays correct: with no declaration there is nothing to go
# on, and scoring absence would redden every lane in the repository at once.
# What was wrong was the claim, in this library's own header, that `no-results`
# covers a run that "asserted nothing". It cannot: `oks` counts case markers.

run_fixture zero-assertions.sh
if [ "${fixture_verdict}" = "no-assertions" ] &&
	test_run_is_failure "${fixture_verdict}" &&
	grep -q 'ASSERTED NOTHING' <<<"${fixture_headline}"; then
	ok "three [OK] cases that declare CHECKS: 0 is a failure, not a green run"
else
	fail "three [OK] cases that declare CHECKS: 0 is a failure, not a green run" \
		"Got '${fixture_verdict}': ${fixture_headline}" \
		"This is the shape a file of empty test cases prints. If it scores" \
		"'ok', the tally is counting cases that assert nothing as passes."
fi

run_fixture declared-assertions.sh
if [ "${fixture_verdict}" = "ok" ] && ! test_run_is_failure "${fixture_verdict}"; then
	ok "the same three cases declaring CHECKS: 7 stay green"
else
	fail "the same three cases declaring CHECKS: 7 stay green" \
		"Got '${fixture_verdict}': ${fixture_headline}" \
		"Otherwise the branch above is not a check on assertions, it is just" \
		"a way to fail every file that declares one."
fi

run_fixture green.sh
if [ "${fixture_verdict}" = "ok" ]; then
	ok "a run declaring NO count classifies exactly as before — the change is additive"
else
	fail "a run declaring NO count classifies exactly as before" \
		"Got '${fixture_verdict}': ${fixture_headline}" \
		"Almost no file declares a count yet; if absence scored as a failure" \
		"every lane would go red at once and the guard would be switched off."
fi

# --- 11-13. a green run that skipped most of itself must say so -----------
#
# Reporting, not scoring: see the note above `test_run_headline`. A missing
# cross-repo recorder is a declared, supported condition in this repo
# (`viewmodel/tests/unit/recorder_gate.nim` exists to make it uniform), so
# failing on it would make every developer machine permanently red. What must
# never happen is the count being invisible.

run_fixture skippy.sh
if [ "${fixture_verdict}" = "ok" ] && [ "${fixture_skips}" -eq 5 ]; then
	ok "a run that skipped 5 of 10 cases is still classified 'ok'"
else
	fail "a run that skipped 5 of 10 cases is still classified 'ok'" \
		"Got '${fixture_verdict}' with ${fixture_skips} skips." \
		"skip() is a supported outcome here; the verdict must not change."
fi

if grep -q '5 SKIPPED' <<<"${fixture_headline}"; then
	ok "the OK headline names the skipped count"
else
	fail "the OK headline names the skipped count" \
		"Got: ${fixture_headline}" \
		"This is the measured shape: language_smoke_test printed 'OK (5 tests)'" \
		"while ten of its fifteen cases had been skipped for want of a recorder," \
		"and nothing in the report said so."
fi

# The mutation for this contract: the pre-fix headline, which took four
# arguments and could not have named a skip. It must NOT contain the count —
# otherwise the two contracts above are satisfied by something other than the
# change they are guarding.
legacy_headline="$(test_run_headline "${fixture_verdict}" "${fixture_rc}" \
	"${fixture_oks}" "${fixture_fails}")"
if ! grep -q 'SKIPPED' <<<"${legacy_headline}"; then
	ok "the pre-fix headline is silent about skips (red-before)"
else
	fail "the pre-fix headline is silent about skips" \
		"Got: ${legacy_headline}" \
		"A four-argument call must keep the old wording, both because that is" \
		"the compatibility contract for existing callers and because if it did" \
		"not, the contract above would pass without the fifth argument working."
fi

# --- 10. every lane actually goes through this classifier -----------------
#
# The contracts above are worthless if a lane keeps its own inline copy. Pin
# the call sites. Comments are stripped first for the same reason
# vm-js-lane-test.sh strips them: this justfile explains the defect in prose
# that necessarily quotes the tokens under test.
#
# A lane satisfies this TWO ways, and both are followed rather than assumed:
#
#   a. it sources ci/lib/test-lane-report.sh and calls classify_test_run in its
#      own body (test-vm-recorder-gated still does, because its
#      MISSING-RECORDER SKIP handling sits between the verdict and the tally);
#   b. it hands off to ci/lib/run-nim-test-lane.sh, the shared compile-run-report
#      loop, which does both on the lane's behalf.
#
# (b) is why this check had to change: five of these six lanes stopped carrying
# the loop and started delegating, and a guard pinned to "the recipe body
# contains classify_test_run" reported that as five lanes losing the
# classifier. They had not; the classifier had moved. Following the delegation
# is what keeps this assertion about BEHAVIOUR rather than about layout.
#
# The runner is verified once, here, rather than trusted: if it stopped
# classifying, every delegating lane would silently satisfy (b) while doing
# nothing of the sort.
runner_rel="ci/lib/run-nim-test-lane.sh"
runner_abs="${REPO_ROOT}/${runner_rel}"
runner_classifies=0
if [ -f "${runner_abs}" ] &&
	grep -qE 'source "?\$?\{?[a-z_]*\}?/?ci/lib/test-lane-report\.sh"?' "${runner_abs}" &&
	grep -q 'classify_test_run' "${runner_abs}"; then
	runner_classifies=1
fi

# shellcheck disable=SC2001 # parameter expansion cannot express this trim
justfile_code="$(sed 's/[[:space:]]*#.*$//' <"${JUSTFILE}")"

# Every justfile recipe that compiles and runs Nim test files. The five that
# delegate, the one that still loops inline, and the lanes added when the file
# selection moved into ci/lib/test-lane-files.sh -- listed so a new lane cannot
# quietly opt out of the classifier by being new.
lane_names=(
	test-vm-native test-vm-js test-cli-record test-ct-trace-units
	test-mcr-enrichment-units test-vm-recorder-gated
	test-common-units test-ct-cli-units test-frontend-units test-vm-unit
	test-vm-unit-js
	test-vm-collab-units test-vm-collab-integration test-ct-test-incremental
	test-ct-test-incremental-e2e test-vm-gui-headless test-online-sharing-compile
	test-host-instantiations
)
missing_lanes=()
delegating=0
inline=0
for lane in "${lane_names[@]}"; do
	lane_body="$(awk -v target="^${lane}( |:)" '
		$0 ~ target { inrec = 1; next }
		inrec && /^[^[:space:]]/ { exit }
		inrec { print }
	' <<<"${justfile_code}")"
	if [ -z "${lane_body}" ]; then
		missing_lanes+=("${lane} (no such recipe)")
	elif grep -qE 'source "?\$?\{?[a-z_]*\}?/?ci/lib/test-lane-report\.sh"?' <<<"${lane_body}" &&
		grep -q 'classify_test_run' <<<"${lane_body}"; then
		inline=$((inline + 1))
	elif grep -q "${runner_rel}" <<<"${lane_body}" && [ "${runner_classifies}" -eq 1 ]; then
		delegating=$((delegating + 1))
	else
		missing_lanes+=("${lane}")
	fi
done

if [ "${#missing_lanes[@]}" -eq 0 ]; then
	ok "all ${#lane_names[@]} compile-and-run lanes classify through the shared library" \
		"(${delegating} via ${runner_rel}, ${inline} inline)"
else
	fail "all ${#lane_names[@]} compile-and-run lanes classify through the shared library" \
		"These neither classify inline nor delegate to a runner that does:" \
		"${missing_lanes[*]}" \
		"A lane with its own inline if-chain is a lane this suite cannot" \
		"protect, and an inline chain is exactly how the defect got in."
fi

echo

if [ "${pass_count}" -ne "${TOTAL_CONTRACTS}" ]; then
	fail "every contract is accounted for" \
		"declared TOTAL_CONTRACTS=${TOTAL_CONTRACTS} but ${pass_count} ran." \
		"A contract that neither ran nor announced itself is invisible, so this" \
		"suite refuses to print a total it cannot justify."
fi

echo "contracts: ${pass_count} of ${TOTAL_CONTRACTS} ran, 0 skipped"
echo "test-lane-report: all contracts hold."
