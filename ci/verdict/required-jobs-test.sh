#!/usr/bin/env bash
#
# required-jobs-test.sh — contract tests for ci/verdict/required-jobs.sh.
#
# Two of the fixtures under testdata/ are NOT synthetic: they are the real
# `needs`-shaped job results of actual codetracer CI runs, captured from the
# GitHub API, and they are what this gate was built to catch:
#
#   needs-lock-famine.json   run 31180327493 (dev, 2026-08-07)
#   needs-locked-commit.json run 30726348404 (dev, 2026-08-02)
#
# In both, `test-non-gui` — the entire non-GUI test suite — is `skipped`,
# together with every build job, because `lint-rust` failed. The run was red
# either way, so nothing in the GitHub UI distinguished "the tests failed"
# from "the tests never ran". These fixtures pin that distinction down.
#
# The two files are byte-identical, and deliberately kept as two files: one
# commit had a published workspace lock and the other did not, and they still
# produced the same verdict, job for job. See contract 2.
#
# Mock/synthetic data is used only for the cases that cannot be harvested from
# history: a fully healthy run (codetracer has not had one on `dev`), a run
# where everything executed and one job failed, and the manifest-drift and
# malformed-input paths. Everything reachable from real runs uses real data.
#
# Run directly:  bash ci/verdict/required-jobs-test.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
GATE="${SCRIPT_DIR}/required-jobs.sh"
MANIFEST="${SCRIPT_DIR}/required-jobs.txt"
WORKFLOW="${REPO_ROOT}/.github/workflows/codetracer.yml"

# This suite builds fixtures with jq. The gate under test degrades
# cleanly without jq (exit 3, with a message); this driver would instead
# die mid-fixture under `set -e` with a bare "jq: command not found", so
# say it plainly up front rather than reporting it as a failed contract.
if ! command -v jq >/dev/null 2>&1; then
	echo "required-jobs-test: jq not found on PATH; cannot build fixtures" >&2
	exit 3
fi

tmp_dir="$(mktemp -d)"
# Preserve the exit status across the cleanup. A bare `trap 'rm -rf ...' EXIT`
# lets the trap's own (successful) status become the script's on bash 3.2 --
# which is /bin/bash on macOS, where developers run this. The effect is that
# this suite dies mid-way (`declare -A` is a bash-4 feature, so contract 6
# aborts under `set -u`) and still exits 0: the count assertion at the bottom,
# which is what protects against exactly that, is never reached. CI's bash 5
# is unaffected, so this was invisible there -- a self-test that cannot fail,
# in the one script the rest of this pipeline is read through.
trap 'rc=$?; rm -rf "${tmp_dir}"; exit "${rc}"' EXIT

pass_count=0

fail() {
	echo "required-jobs-test: FAIL: $*" >&2
	exit 1
}

# run_gate <payload-file> <manifest> -> sets RC and OUT
run_gate() {
	set +e
	OUT="$("${GATE}" --needs-json "$1" --manifest "$2" 2>&1)"
	RC=$?
	set -e
}

expect_rc() {
	local want="$1" desc="$2"
	[[ ${RC} -eq ${want} ]] || fail "${desc}: expected exit ${want}, got ${RC}. Output:\n${OUT}"
}

expect_contains() {
	local frag="$1" desc="$2"
	[[ ${OUT} == *"${frag}"* ]] || fail "${desc}: expected output to contain '${frag}'. Output:\n${OUT}"
}

expect_not_contains() {
	local frag="$1" desc="$2"
	[[ ${OUT} != *"${frag}"* ]] || fail "${desc}: expected output NOT to contain '${frag}'. Output:\n${OUT}"
}

ok() {
	pass_count=$((pass_count + 1))
	echo "  ok — $1"
}

echo "required-jobs-test: contract tests for ${GATE}"

# ---------------------------------------------------------------------
# 1. REGRESSION (real data): the lock-famine run must be reported as
#    "did not run", not as an ordinary test failure.
# ---------------------------------------------------------------------
run_gate "${SCRIPT_DIR}/testdata/needs-lock-famine.json" "${MANIFEST}"
expect_rc 2 "lock-famine run"
expect_contains "CI DID NOT RUN THE TESTS" "lock-famine run"
expect_contains "test-non-gui=skipped" "lock-famine run"
expect_contains "nix-build=skipped" "lock-famine run"
expect_not_contains "did-not-run=0" "lock-famine run"
ok "real run 31180327493 (lock famine) -> exit 2, 'CI DID NOT RUN THE TESTS'"

# ---------------------------------------------------------------------
# 2. REGRESSION (real data): the ONE commit in this window that had a
#    published workspace lock still lost its test suite. In that run
#    `Setup dev env` succeeded in every job; `lint-rust` then died in a
#    later step (`direnv: not found`, exit 127), and every job gated
#    behind it was skipped anyway.
#
#    The two fixtures are byte-identical, and that identity IS the
#    finding rather than a copy-paste slip: a commit WITH a published
#    lock and a commit WITHOUT one produced exactly the same 26-job
#    verdict, down to which twelve jobs never ran. Publishing locks
#    would not have restored one line of coverage. The assertion below
#    pins that equivalence so a future edit to either fixture has to
#    confront it.
# ---------------------------------------------------------------------
run_gate "${SCRIPT_DIR}/testdata/needs-locked-commit.json" "${MANIFEST}"
expect_rc 2 "locked-commit run"
expect_contains "CI DID NOT RUN THE TESTS" "locked-commit run"
expect_contains "test-non-gui=skipped" "locked-commit run"
if ! cmp -s "${SCRIPT_DIR}/testdata/needs-locked-commit.json" \
	"${SCRIPT_DIR}/testdata/needs-lock-famine.json"; then
	fail "the locked-commit and lock-famine fixtures used to be identical; if a real difference has been captured, update the comment above and this assertion rather than deleting it"
fi
ok "real run 30726348404 (lock present, lint-rust failed) -> exit 2, verdict identical to the lockless run"

# ---------------------------------------------------------------------
# 3. A fully healthy run passes.
# ---------------------------------------------------------------------
healthy="${tmp_dir}/healthy.json"
{
	echo '{'
	first=1
	while IFS= read -r job; do
		job="${job%%#*}"
		job="${job// /}"
		[[ -z ${job} ]] && continue
		[[ ${first} -eq 1 ]] || echo ','
		first=0
		printf '  "%s": {"result": "success"}' "${job}"
	done <"${MANIFEST}"
	echo ''
	echo '}'
} >"${healthy}"
run_gate "${healthy}" "${MANIFEST}"
expect_rc 0 "healthy run"
expect_contains "did-not-run=0" "healthy run"
expect_contains "executed and succeeded" "healthy run"
ok "all required jobs succeeded -> exit 0"

# ---------------------------------------------------------------------
# 4. Everything executed, one job failed: ordinary redness, and it must
#    NOT be dressed up as lost coverage.
# ---------------------------------------------------------------------
ran_failed="${tmp_dir}/ran-failed.json"
sed 's/"test-non-gui": {"result": "success"}/"test-non-gui": {"result": "failure"}/' \
	"${healthy}" >"${ran_failed}"
run_gate "${ran_failed}" "${MANIFEST}"
expect_rc 1 "executed-and-failed run"
expect_contains "Tests ran and reported failures" "executed-and-failed run"
expect_contains "did-not-run=0" "executed-and-failed run"
expect_not_contains "CI DID NOT RUN THE TESTS" "executed-and-failed run"
ok "all jobs ran, one failed -> exit 1, distinct wording from 'did not run'"

# ---------------------------------------------------------------------
# 5. A required job missing from the payload entirely (renamed, deleted,
#    or dropped from the gate's needs:) is lost coverage, not a pass.
# ---------------------------------------------------------------------
dropped="${tmp_dir}/dropped.json"
jq 'del(."test-non-gui")' "${healthy}" >"${dropped}"
run_gate "${dropped}" "${MANIFEST}"
expect_rc 2 "dropped-job run"
expect_contains "CI DID NOT RUN THE TESTS" "dropped-job run"
expect_contains "absent from the needs payload" "dropped-job run"
ok "required job absent from payload -> exit 2, reported as lost coverage"

# ---------------------------------------------------------------------
# 6. An empty manifest must not pass vacuously.
# ---------------------------------------------------------------------
empty_manifest="${tmp_dir}/empty.txt"
printf '# only comments\n\n' >"${empty_manifest}"
run_gate "${healthy}" "${empty_manifest}"
expect_rc 3 "empty manifest"
expect_contains "refusing to pass vacuously" "empty manifest"
ok "empty manifest -> exit 3, refuses to pass vacuously"

# ---------------------------------------------------------------------
# 7. Malformed / degenerate payloads must fail loudly, never report
#    success. These are the ways a verdict gate silently stops being a
#    verdict gate, so each shape is pinned individually:
#
#      * unparseable text, a truncated write, an empty file
#      * a JSON value that is not an object (null, array)
#      * an object whose entries are not objects (jq would abort
#        mid-loop with an undocumented exit status)
#      * an object with NO jobs at all — every required job is then
#        missing, which is lost coverage (exit 2), not a pass
#      * every job present but `skipped` — the exact production shape
#        this gate was built for
# ---------------------------------------------------------------------
declare -A malformed=(
	[unparseable]='not json at all'
	[truncated]='{"lint-bash": {"result": "suc'
	[empty-file]=''
	[json-null]='null'
	[json-array]='[]'
	[entry-not-object]='{"test-non-gui": "success"}'
)
for name in "${!malformed[@]}"; do
	bad="${tmp_dir}/bad-${name}.json"
	printf '%s' "${malformed[${name}]}" >"${bad}"
	run_gate "${bad}" "${MANIFEST}"
	expect_rc 3 "malformed payload (${name})"
	expect_not_contains "executed and succeeded" "malformed payload (${name})"
done
ok "6 malformed needs payloads -> exit 3, never a pass"

zero_jobs="${tmp_dir}/zero-jobs.json"
printf '{}' >"${zero_jobs}"
run_gate "${zero_jobs}" "${MANIFEST}"
expect_rc 2 "payload with zero jobs"
expect_contains "CI DID NOT RUN THE TESTS" "payload with zero jobs"
expect_contains "absent from the needs payload" "payload with zero jobs"
ok "payload with zero jobs -> exit 2, all coverage reported missing"

all_skipped="${tmp_dir}/all-skipped.json"
jq 'map_values({result: "skipped"})' "${healthy}" >"${all_skipped}"
run_gate "${all_skipped}" "${MANIFEST}"
expect_rc 2 "every job skipped"
expect_contains "CI DID NOT RUN THE TESTS" "every job skipped"
expect_not_contains "Tests ran and reported failures" "every job skipped"
ok "every required job skipped -> exit 2, never mistaken for a test failure"

# The step summary is a rendering surface, not the verdict. An
# unwritable GITHUB_STEP_SUMMARY must not be able to downgrade exit 2
# (no coverage) into exit 1 (ordinary redness) and swallow the banner.
unwritable="${tmp_dir}/summary-is-a-directory"
mkdir -p "${unwritable}"
set +e
OUT="$(GITHUB_STEP_SUMMARY="${unwritable}" "${GATE}" \
	--needs-json "${SCRIPT_DIR}/testdata/needs-lock-famine.json" \
	--manifest "${MANIFEST}" 2>&1)"
RC=$?
set -e
expect_rc 2 "unwritable step summary"
expect_contains "CI DID NOT RUN THE TESTS" "unwritable step summary"
ok "unwritable GITHUB_STEP_SUMMARY cannot change the verdict"

# ---------------------------------------------------------------------
# 8. DRIFT GUARD: every job id in the manifest must still exist in the
#    workflow. Without this, deleting a job from codetracer.yml would
#    quietly shrink what this gate protects.
# ---------------------------------------------------------------------
missing_jobs=""
while IFS= read -r job; do
	job="${job%%#*}"
	job="${job// /}"
	[[ -z ${job} ]] && continue
	if ! grep -qE "^  ${job}:[[:space:]]*$" "${WORKFLOW}"; then
		missing_jobs="${missing_jobs} ${job}"
	fi
done <"${MANIFEST}"
[[ -z ${missing_jobs} ]] || fail "manifest lists job ids absent from ${WORKFLOW}:${missing_jobs}"
ok "every manifest job id exists in codetracer.yml"

# ---------------------------------------------------------------------
# 9. DRIFT GUARD (other direction): the ci-verdict job must declare each
#    manifest job in its needs:, or the payload can never contain it.
# ---------------------------------------------------------------------
verdict_needs="$(sed -n '/^  ci-verdict:/,/^  [a-zA-Z0-9_-]*:[[:space:]]*$/p' "${WORKFLOW}")"
missing_needs=""
while IFS= read -r job; do
	job="${job%%#*}"
	job="${job// /}"
	[[ -z ${job} ]] && continue
	# Match the whole needs entry, not a substring of it. A plain
	# `*"- ${job}"*` test is satisfied by `- test-non-gui-renamed`,
	# so renaming a gated job would silently drop it from the payload
	# while this guard still reported "all contracts hold".
	if ! grep -qE "^      - ${job}[[:space:]]*$" <<<"${verdict_needs}"; then
		missing_needs="${missing_needs} ${job}"
	fi
done <"${MANIFEST}"
[[ -z ${missing_needs} ]] || fail "ci-verdict job is missing needs: entries for:${missing_needs}"
ok "ci-verdict declares every manifest job in needs:"

# ---------------------------------------------------------------------
# 10. ORDERING GUARD: the verdict must publish even when a guard breaks.
#
#     This gate spent its life answering in its FOURTEENTH step, behind
#     thirteen unrelated static self-tests. Any one of them exiting
#     non-zero ended the job before the verdict step ran, and GitHub then
#     showed `ci-verdict` red with no verdict in it -- making the alarm
#     ("a required job never ran") indistinguishable from "some unrelated
#     contract suite is broken". The instrument every other gate is read
#     through could be silenced by a defect it does not even watch for.
#
#     The fix is structural, so the guard on it must be structural too: a
#     comment saying "keep the verdict first" is exactly the kind of prose
#     that goes stale while the thing it describes drifts. These are the
#     three properties that make the failure unreachable, asserted against
#     the workflow file itself.
# ---------------------------------------------------------------------
verdict_block="$(sed -n '/^  ci-verdict:/,/^  [a-zA-Z0-9_-]*:[[:space:]]*$/p' "${WORKFLOW}")"

# (a) The verdict step exists and is unconditional.
verdict_step="$(awk '
	/^      - name: Assert the required jobs actually ran$/ { grab = 1; next }
	grab && /^      - name: / { exit }
	grab { print }
' <<<"${verdict_block}")"
[[ -n ${verdict_step} ]] ||
	fail "ci-verdict has no step named 'Assert the required jobs actually ran'"
grep -qE '^        if: always\(\)[[:space:]]*$' <<<"${verdict_step}" ||
	fail "the verdict step must carry 'if: always()', or a failure in any earlier step suppresses the answer this job exists to produce"

# (b) No step before the verdict may abort the job. Checkout is exempt:
#     without a work tree there is nothing to compute a verdict from, so
#     its failure is not a suppressed verdict, it is no verdict possible.
preceding="$(awk '
	/^      - name: Assert the required jobs actually ran$/ { exit }
	{ print }
' <<<"${verdict_block}")"
offenders=""
current=""
current_body=""
check_step() {
	[[ -z ${current} ]] && return 0
	[[ ${current} == "Checkout" ]] && return 0
	grep -qE '^        continue-on-error: true[[:space:]]*$' <<<"${current_body}" ||
		offenders="${offenders}
  - ${current}"
}
while IFS= read -r line; do
	if [[ ${line} =~ ^\ {6}-\ name:\ (.*)$ ]]; then
		check_step
		current="${BASH_REMATCH[1]}"
		current_body=""
	else
		current_body="${current_body}
${line}"
	fi
done <<<"${preceding}"
check_step
[[ -z ${offenders} ]] || fail "these ci-verdict steps run BEFORE the verdict and can abort the job, suppressing it:${offenders}
Move them to ci-contract-suites, or mark them continue-on-error and re-raise after the verdict."

# (c) A self-test made non-fatal must still be able to fail the job, or
#     this guard would have traded a suppressed verdict for a silent one.
grep -qE "steps\.verdict-selftest\.outcome == 'failure'" <<<"${verdict_block}" ||
	fail "ci-verdict marks its self-test continue-on-error but never re-raises it; a broken gate would report success"
ok "the verdict publishes before any guard can abort the job, and a broken guard still fails it"

echo
# The count is asserted so that a contract deleted or short-circuited by
# an early `return` cannot leave this suite quietly reporting success on
# fewer checks than it claims to run.
echo "required-jobs-test summary: expected=13 executed=${pass_count} failed=0"
[[ ${pass_count} -eq 13 ]] || fail "expected 12 assertions to run, ran ${pass_count}"
echo "required-jobs-test: all contracts hold."
