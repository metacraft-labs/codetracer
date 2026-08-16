#!/usr/bin/env bash
#
# queue-watchdog-test.sh — contract suite for ci/verdict/queue-watchdog.sh.
#
# The two decisive fixtures under testdata/ are NOT synthetic. They are real
# job payloads of real codetracer runs, captured from the GitHub jobs API
# during the runner-pool outage this watchdog was written for:
#
#   jobs-stalled-real.json    run 31958803529 (dev, 096c78045, 2026-08-16)
#                             22 queued, 0 running, 5 completed
#   jobs-serviced-real.json   run 31951371601 (dev, a4c2daa35, 2026-08-16)
#                             6 queued, 3 running, 19 completed
#
# The second is the one that gives this suite its teeth. It is ALSO a run with
# queued jobs — six of them — and it must NOT be reported as stalled, because
# three jobs are running and the run is therefore still advancing. Any
# implementation that fires on "something is queued" passes the first fixture
# and fails the second. Both were captured within four hours of each other from
# the same branch, so they differ in the predicate and very little else.
#
# Synthetic fixtures are used only for states that cannot be harvested: the
# self-exclusion pair (which needs a snapshot whose only running job is the
# watchdog itself) and the malformed-input paths.
#
# Run directly:  bash ci/verdict/queue-watchdog-test.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GATE="${SCRIPT_DIR}/queue-watchdog.sh"
DATA="${SCRIPT_DIR}/testdata"

if ! command -v jq >/dev/null 2>&1; then
	echo "queue-watchdog-test: jq not found on PATH; cannot build fixtures" >&2
	exit 3
fi

tmp_dir="$(mktemp -d)"
trap 'rm -rf "${tmp_dir}"' EXIT

pass_count=0

fail() {
	echo "queue-watchdog-test: FAIL: $*" >&2
	exit 1
}

# run_gate <payload-file> [extra args...] -> sets RC and OUT
run_gate() {
	local payload="$1"
	shift
	set +e
	OUT="$("${GATE}" --jobs-json "${payload}" "$@" 2>&1)"
	RC=$?
	set -e
}

expect_rc() {
	local want="$1" desc="$2"
	[[ ${RC} -eq ${want} ]] || fail "${desc}: expected exit ${want}, got ${RC}. Output:
${OUT}"
}

expect_contains() {
	local frag="$1" desc="$2"
	[[ ${OUT} == *"${frag}"* ]] || fail "${desc}: expected output to contain '${frag}'. Output:
${OUT}"
}

expect_not_contains() {
	local frag="$1" desc="$2"
	[[ ${OUT} != *"${frag}"* ]] || fail "${desc}: expected output NOT to contain '${frag}'. Output:
${OUT}"
}

ok() {
	pass_count=$((pass_count + 1))
	echo "  ok — $1"
}

echo "queue-watchdog contracts"

# --- 1. the two real runs -------------------------------------------------

run_gate "${DATA}/jobs-stalled-real.json"
expect_rc 4 "real stalled run"
ok "a real starved run (22 queued, 0 running) is exit 4"

expect_contains "CI IS NOT BEING SERVICED" "stalled banner"
ok "the stalled verdict is stated in words, not just an exit code"

# The whole point of the diagnostic is to name what is stuck, so a reader does
# not have to open the run to find out.
expect_contains "test-ui-tests" "stalled names jobs"
ok "the stalled report lists the jobs that are still queued"

# A starved run is not a broken commit, and saying so is what stops someone
# re-pushing to "fix" it.
expect_contains "NOT a test failure" "stalled disclaimer"
ok "the stalled report denies being a verdict on the code"

run_gate "${DATA}/jobs-serviced-real.json"
expect_rc 0 "real serviced run"
ok "a real advancing run (6 queued, 3 running) is exit 0"

expect_not_contains "CI IS NOT BEING SERVICED" "serviced quiet"
ok "an advancing run raises no alarm even though jobs are queued"

# --- 2. self-exclusion ----------------------------------------------------
#
# The watchdog is a job in the run it watches. If it counted itself as
# `in_progress`, the predicate would be false forever and this gate would be
# silently inert -- passing on every run, including the starved ones. That is
# the single most dangerous bug available to this script, so it is pinned from
# both sides.

cat >"${tmp_dir}/only-self-running.json" <<'EOF'
{"jobs":[
  {"name":"queue-watchdog","status":"in_progress","conclusion":null},
  {"name":"lint-nim","status":"queued","conclusion":null},
  {"name":"test-non-gui","status":"queued","conclusion":null}
]}
EOF

run_gate "${tmp_dir}/only-self-running.json" --self-job-name queue-watchdog
expect_rc 4 "self excluded"
ok "the watchdog's own job does not count as the run making progress"

run_gate "${tmp_dir}/only-self-running.json" --self-job-name some-other-name
expect_rc 0 "self-exclusion is name-driven"
ok "with a different self name that same job DOES count as progress"

# --- 3. terminal and empty states ----------------------------------------

cat >"${tmp_dir}/finished.json" <<'EOF'
{"jobs":[
  {"name":"lint-nim","status":"completed","conclusion":"success"},
  {"name":"test-non-gui","status":"completed","conclusion":"failure"}
]}
EOF

run_gate "${tmp_dir}/finished.json"
expect_rc 0 "finished run"
ok "a finished run is exit 0 however its jobs concluded"

# A run that has failed every job is still not STALLED -- this watchdog must
# never add its own noise to an ordinary red run.
expect_not_contains "CI IS NOT BEING SERVICED" "finished quiet"
ok "a fully red but finished run raises no stall alarm"

echo '{"jobs":[]}' >"${tmp_dir}/empty.json"
run_gate "${tmp_dir}/empty.json"
expect_rc 0 "empty run"
ok "an empty job list is exit 0, not a vacuous stall"

# --- 4. payload shapes ----------------------------------------------------

cat >"${tmp_dir}/bare-array.json" <<'EOF'
[
  {"name":"lint-nim","status":"queued","conclusion":null}
]
EOF
run_gate "${tmp_dir}/bare-array.json"
expect_rc 4 "bare array"
ok 'a bare JSON array is accepted as well as {"jobs":[...]}'

printf '%s' '{"jobs":[{"name":"lint-nim","status":"queued"}]}' >"${tmp_dir}/stdin.json"
set +e
OUT="$("${GATE}" --jobs-json - <"${tmp_dir}/stdin.json" 2>&1)"
RC=$?
set -e
expect_rc 4 "stdin"
ok "the payload can be piped in on stdin"

# --- 5. refusing to guess -------------------------------------------------
#
# Same principle as required-jobs.sh: a gate that cannot read its input must
# fail loudly (exit 3), never quietly report that all is well (exit 0).

echo '"not-a-run"' >"${tmp_dir}/scalar.json"
run_gate "${tmp_dir}/scalar.json"
expect_rc 3 "scalar payload"
ok "a payload that is neither object nor array is exit 3, not exit 0"

echo '{"jobs":[{"name":"lint-nim"}]}' >"${tmp_dir}/no-status.json"
run_gate "${tmp_dir}/no-status.json"
expect_rc 3 "status-less entry"
ok "a job entry with no status is exit 3, not silently ignored"

echo '{"jobs":["lint-nim"]}' >"${tmp_dir}/string-entry.json"
run_gate "${tmp_dir}/string-entry.json"
expect_rc 3 "string entry"
ok "a job entry that is not an object is exit 3"

run_gate "${DATA}/jobs-stalled-real.json" --deadline-minutes not-a-number
expect_rc 3 "bad deadline"
ok "a non-numeric --deadline-minutes is exit 3"

set +e
OUT="$("${GATE}" --nonsense 2>&1)"
RC=$?
set -e
expect_rc 3 "unknown arg"
ok "an unknown argument is exit 3"

set +e
OUT="$("${GATE}" 2>&1)"
RC=$?
set -e
expect_rc 3 "no args"
ok "no arguments at all is exit 3, not a vacuous pass"

echo
echo "assertions: ${pass_count}  fail: 0"
echo "queue-watchdog: all contracts hold."
