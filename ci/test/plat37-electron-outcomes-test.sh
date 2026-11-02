#!/usr/bin/env bash
#
# plat37-electron-outcomes-test.sh — the contract suite for
# ci/test/plat37_electron_outcomes.py and for the wiring that makes the PLAT-37
# Electron capture lane (ci/test/plat37-macos-electron-capture.sh) record WHAT
# HAPPENED TO EACH SCENARIO, rather than leave it to be inferred from a list log.
#
# WHY THIS EXISTS
# ---------------
# On 2026-10-17 the lane ran six scenarios: two passed and four failed. The
# readings written from that run said, twice, that "all four failures are the
# same assertion at plat37-electron-window-capture.spec.ts:862 ... AFTER the
# window has been captured". The log said otherwise:
#
#   advanced-state      Performance limit exceeded: "first window" took 35567ms
#                       — thrown by the LAUNCH fixture (fixtures.ts:1449)
#   returned-calltrace  the same, 32122ms
#   stepped-editor      `#step-in-image` toHaveCount(1) timing out inside DRIVE
#   entry-shell         `the editor drew no rows` — the only one of the four
#                       that is the line-862 assertion, and the only one that
#                       had captured
#
# Three of the four never reached the capture, and the pass went on to grade
# five-day-old frames for those three views as if they were fresh (codetracer-pm
# issues/2026-10-17-plat37-readings-of-2026-10-17-misreport-all-four-
# playwright-failures-as-one-assertion.md). The lane gave the reader nothing
# better than a human log to summarise, so "which PHASE did each scenario die
# in" was a judgement call. This suite pins the record that replaces the
# judgement: per scenario, its status, the test.step it failed in (or the launch
# fixture, when it failed before entering any), the first line of the error, its
# location, and whether the capture phase was reached and completed.
#
# The checks driven here:
#
#   1. THE 2026-10-17 SHAPE — a synthetic Playwright JSON report with two
#      fixture perf-limit failures (no step entered), one failure inside
#      `drive`, one inside `verify-capture`, and two passes. Four failures are
#      reported, each with its own phase and cause; only entry-shell is reported
#      as having reached the capture.
#   2. one line per failed scenario, naming scenario, phase and cause — and
#      four DISTINCT lines, so no single cause is asserted for all of them.
#   3. a failure in a NESTED step reports the innermost step as its phase and
#      the outer phase in its step path.
#   4. a scenario that failed with steps entered but no step carrying the error
#      (a test timeout) is UNATTRIBUTED, never guessed into a phase; and a test
#      timeout whose running step then completed with a teardown consequence
#      ("Target page ... has been closed") is phased to that step but keeps the
#      TIMEOUT as its cause, the step's error beside it as `stepError`.
#   5. VACUITY CONTROLS: a report with zero failures reports none; a MISSING
#      report is reported as missing, not as "no failures"; an unparseable one
#      as unparseable; a report with no tests in it as empty; a declared
#      scenario absent from the report is named.
#   6. WIRING: the lane runs the JSON reporter beside the list reporter, removes
#      a stale report before the run, writes `scenarioOutcomes` into
#      manifest.json and names the failed scenarios in its final message; the
#      spec declares every phase the parser knows as a `test.step`.
#
# Pure bash + python3, no Playwright, no GUI, seconds to run: it belongs in the
# lint stage next to the other contract suites.
#
# WHY THE REPORTS ARE SYNTHETIC (the one stand-in this suite uses)
# ----------------------------------------------------------------
# The parser's input is a Playwright JSON report, and the reports below are
# written by hand rather than produced by a Playwright run. A real run of the
# lane's spec needs a macOS GUI session and a built Electron front-end, and the
# failures that matter (a launch perf limit, a toolbar button missing in drive,
# a test timeout) cannot be provoked on demand there. A throwaway Playwright
# project would need `src/tests/gui/node_modules`, which the lint stage does
# not install. So the reports are hand-written in the exact shape
# @playwright/test 1.56.1 writes, and that shape was checked against real
# reports: on 2026-10-27, a scratch project using the installed 1.56.1 with
# the same describe/test titles and `test.step` names, a throwing launch
# fixture, failures in `drive`, in a nested step and in `verify-capture`, a
# plain test timeout, a timeout whose step was then rejected by fixture
# teardown, and a retried flake, was parsed by this module with the results
# the checks below assert. Every field the fixtures carry (step `error` with
# `location`, `errors[]` timeout without `location`, `errorLocation`) is one
# that run produced.

set -uo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
parser="${repo_root}/ci/test/plat37_electron_outcomes.py"
lane="${repo_root}/ci/test/plat37-macos-electron-capture.sh"
spec="${repo_root}/src/tests/gui/tests/visual/plat37-electron-window-capture.spec.ts"

failures=0
checks=0

work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT

# expect NAME EXPECTED_STATUS ACTUAL_STATUS OUTPUT [MUST_CONTAIN...]
expect() {
	local name="$1" want_status="$2" got_status="$3" output="$4"
	shift 4
	checks=$((checks + 1))
	local ok=1
	if [ "${got_status}" != "${want_status}" ]; then
		ok=0
		echo "  [FAILED] ${name}: expected exit ${want_status}, got ${got_status}"
	fi
	local needle
	for needle in "$@"; do
		if ! grep -qF -- "${needle}" <<<"${output}"; then
			ok=0
			echo "  [FAILED] ${name}: output lacks '${needle}'"
		fi
	done
	if [ "${ok}" -eq 1 ]; then
		echo "  [OK] ${name}"
	else
		failures=$((failures + 1))
		# Capped: a wiring check's output is a whole file.
		printf '%s\n' "${output}" | head -40 | sed 's/^/      | /'
	fi
}

# refute NAME OUTPUT [MUST_NOT_CONTAIN...]
refute() {
	local name="$1" output="$2"
	shift 2
	checks=$((checks + 1))
	local ok=1 needle
	for needle in "$@"; do
		if grep -qF -- "${needle}" <<<"${output}"; then
			ok=0
			echo "  [FAILED] ${name}: output contains '${needle}'"
		fi
	done
	if [ "${ok}" -eq 1 ]; then
		echo "  [OK] ${name}"
	else
		failures=$((failures + 1))
		printf '%s\n' "${output}" | sed 's/^/      | /'
	fi
}

# Every view scenarios.json declares, in the order the lane drives them.
all_views="shell,editor,state,calltrace,eventLog,editorWithMark"

run_summary() { # run_summary REPORT [EXTRA_ARGS...]
	local report="$1"
	shift
	python3 "${parser}" --report "${report}" --expect-views "${all_views}" \
		--format json "$@" 2>&1
}

run_lines() { # run_lines REPORT
	python3 "${parser}" --report "$1" --expect-views "${all_views}" \
		--format lines 2>&1
}

# query SUMMARY_JSON PYTHON_EXPR — evaluates EXPR with `s` bound to the parsed
# summary and `by` to its scenarios keyed by scenario id; prints the result.
query() {
	python3 -c '
import json, sys
s = json.loads(sys.argv[1])
by = {o["scenario"]: o for o in s.get("scenarios", [])}
print(eval(sys.argv[2]))
' "$1" "$2" 2>&1
}

echo "=== ci/test/plat37_electron_outcomes.py contract suite ==="

# ---------------------------------------------------------------------------
# Synthetic reports, in the shape @playwright/test 1.56.1's JSON reporter
# writes (node_modules/playwright/lib/reporters/json.js): suites nest by file
# then by describe; each spec has one test per project; each test a result per
# attempt; each result `steps` holding ONLY `test.step` steps (fixture steps
# are filtered out by the reporter), `errors` as formatted {message, location},
# and `errorLocation` from the first error's stack.
# ---------------------------------------------------------------------------
python3 - "${work}" <<'PY' || {
import json, os, sys

work = sys.argv[1]
ROOT = "/ws/codetracer/src/tests/gui"
SPEC = ROOT + "/tests/visual/plat37-electron-window-capture.spec.ts"
FIXTURES = ROOT + "/lib/fixtures.ts"


def err(message, file, line):
    loc = {"file": file, "line": line, "column": 11}
    return {"message": message, "location": loc}


def step(title, error=None, steps=None):
    s = {"title": title, "duration": 10}
    if error is not None:
        s["error"] = {"message": error["message"],
                      "stack": error["message"] + "\n    at " +
                      f"{error['location']['file']}:{error['location']['line']}:11",
                      "location": error["location"]}
    if steps:
        s["steps"] = steps
    return s


def result(status, errors=(), steps=None):
    r = {"workerIndex": 0, "parallelIndex": 0, "status": status,
         "duration": 1000, "errors": list(errors), "stdout": [], "stderr": [],
         "retry": 0, "startTime": "2026-10-17T13:10:00.000Z",
         "annotations": [], "attachments": []}
    if errors:
        r["error"] = {"message": errors[0]["message"]}
        if "location" in errors[0]:
            r["errorLocation"] = errors[0]["location"]
    if steps:
        r["steps"] = steps
    return r


def scenario(sid, view, *results):
    outcome = "expected" if results[-1]["status"] == "passed" else "unexpected"
    return {"title": f"plat37-electron {sid}", "file": "visual/plat37-electron-window-capture.spec.ts",
            "line": 984, "column": 3,
            "specs": [{"title": f"capture {view}", "ok": outcome == "expected",
                       "tags": [], "id": sid,
                       "file": "visual/plat37-electron-window-capture.spec.ts",
                       "line": 1015, "column": 5,
                       "tests": [{"timeout": 600000, "annotations": [],
                                  "expectedStatus": "passed",
                                  "projectId": "chromium",
                                  "projectName": "chromium",
                                  "results": list(results),
                                  "status": outcome}]}]}


def report(*describes):
    return {"config": {"configFile": ROOT + "/playwright.config.ts",
                       "rootDir": ROOT + "/tests", "projects": []},
            "suites": [{"title": "visual/plat37-electron-window-capture.spec.ts",
                        "file": "visual/plat37-electron-window-capture.spec.ts",
                        "line": 0, "column": 0, "specs": [],
                        "suites": list(describes)}],
            "errors": [],
            "stats": {"startTime": "2026-10-17T13:09:58.000Z",
                      "duration": 384000, "expected": 0, "skipped": 0,
                      "unexpected": 0, "flaky": 0}}


ALL = ["viewport", "drive", "capture", "verify-capture"]
passed_steps = [step(t) for t in ALL]


def passing(sid, view):
    return scenario(sid, view, result("passed", steps=passed_steps))


perf35 = err('Error: Performance limit exceeded: "first window" took 35567ms '
             '(limit: 10000ms)\n\n    at timed (lib/fixtures.ts:1449:11)',
             FIXTURES, 1449)
perf32 = err('Error: Performance limit exceeded: "first window" took 32122ms '
             '(limit: 10000ms)', FIXTURES, 1449)
stepin = err("Error: the 'stepIn' toolbar button (#step-in-image) is not in "
             "the DOM\n\nexpect(locator).toHaveCount(expected) failed\n\n"
             "Timeout: 15000ms", SPEC, 640)
norows = err("Error: the editor drew no rows, so the captured window holds "
             "no source text whatever its pane grounds look like\n\n"
             "expect(received).toBeGreaterThan(expected)", SPEC, 1228)

oct17 = report(
    scenario("entry-shell", "shell",
             result("failed", [norows],
                    [step("viewport"), step("drive"), step("capture"),
                     step("verify-capture", norows)])),
    scenario("stepped-editor", "editor",
             result("failed", [stepin],
                    [step("viewport"), step("drive", stepin)])),
    scenario("advanced-state", "state", result("failed", [perf35])),
    scenario("returned-calltrace", "calltrace", result("failed", [perf32])),
    passing("continued-event-log", "eventLog"),
    passing("breakpoint-editor", "editorWithMark"),
)

nested_err = err("Error: stepIn #1/1 did not move the program", SPEC, 777)
nested = report(scenario(
    "stepped-editor", "editor",
    result("failed", [nested_err],
           [step("viewport"),
            step("drive", nested_err,
                 [step("stepIn #1/1", nested_err)])])))

timeout_err = {"message": "Test timeout of 600000ms exceeded."}
timedout = report(scenario(
    "returned-calltrace", "calltrace",
    result("timedOut", [timeout_err], [step("viewport"), step("drive")])))

# The common real timeout: the body is abandoned at the deadline, fixture
# teardown closes the app, and the action `drive` was awaiting rejects. 1.56.1
# then records errors = [timeout (no location), consequence], and the `drive`
# step carries only the consequence.
closed = err("Error: locator.click: Target page, context or browser has been "
             "closed", SPEC, 655)
timeout_closed = report(scenario(
    "stepped-editor", "editor",
    result("timedOut", [timeout_err, closed],
           [step("viewport"), step("drive", closed)])))

green = report(*[passing(s, v) for s, v in [
    ("entry-shell", "shell"), ("stepped-editor", "editor"),
    ("advanced-state", "state"), ("returned-calltrace", "calltrace"),
    ("continued-event-log", "eventLog"),
    ("breakpoint-editor", "editorWithMark")]])

partial = report(passing("entry-shell", "shell"))
empty = report()
empty["suites"] = []

for name, doc in [("oct17", oct17), ("nested", nested),
                  ("timedout", timedout),
                  ("timeout_closed", timeout_closed), ("green", green),
                  ("partial", partial), ("empty", empty)]:
    with open(os.path.join(work, f"{name}.json"), "w") as f:
        json.dump(doc, f, indent=2)
with open(os.path.join(work, "truncated.json"), "w") as f:
    f.write(json.dumps(oct17)[:500])
PY
	echo "plat37-electron-outcomes contract: the synthetic reports could not be written" >&2
	exit 1
}

# ---------------------------------------------------------------------------
# 1. The 2026-10-17 shape.
# ---------------------------------------------------------------------------
echo "--- 1. the 2026-10-17 shape: four failures, three phases, one capture ---"
out="$(run_summary "${work}/oct17.json")"
status=$?
expect "the report parses" 0 "${status}" "${out}" '"reportStatus": "parsed"'

check_eq() { # check_eq NAME SUMMARY EXPR EXPECTED
	local got
	got="$(query "$2" "$3")"
	checks=$((checks + 1))
	if [ "${got}" = "$4" ]; then
		echo "  [OK] $1"
	else
		failures=$((failures + 1))
		echo "  [FAILED] $1: expected '$4', got '${got}'"
	fi
}

check_eq "four failed, two passed" "${out}" \
	'(s["failedCount"], s["passedCount"])' "(4, 2)"
check_eq "advanced-state died in the launch fixture, before any step" "${out}" \
	'(by["advanced-state"]["phase"], by["advanced-state"]["stepPath"])' \
	"('launch', [])"
check_eq "advanced-state's cause is its own perf-limit reading, at fixtures.ts:1449" "${out}" \
	'(by["advanced-state"]["error"], by["advanced-state"]["errorLocation"])' \
	"('Error: Performance limit exceeded: \"first window\" took 35567ms (limit: 10000ms)', 'lib/fixtures.ts:1449')"
check_eq "returned-calltrace died in the launch fixture with ITS reading" "${out}" \
	'(by["returned-calltrace"]["phase"], "32122ms" in by["returned-calltrace"]["error"])' \
	"('launch', True)"
check_eq "stepped-editor died in drive, on the stepIn button" "${out}" \
	'(by["stepped-editor"]["phase"], "#step-in-image" in by["stepped-editor"]["error"])' \
	"('drive', True)"
check_eq "entry-shell died in verify-capture, on the no-rows assertion" "${out}" \
	'(by["entry-shell"]["phase"], by["entry-shell"]["error"].startswith("Error: the editor drew no rows"))' \
	"('verify-capture', True)"
check_eq "ONLY entry-shell, of the four failures, reached the capture" "${out}" \
	'sorted(o["scenario"] for o in s["scenarios"] if o["status"] != "passed" and o["captureReached"])' \
	"['entry-shell']"
check_eq "entry-shell's capture phase completed; the three others never entered it" "${out}" \
	'[(k, by[k]["captureReached"], by[k]["captureCompleted"]) for k in ("entry-shell", "stepped-editor", "advanced-state", "returned-calltrace")]' \
	"[('entry-shell', True, True), ('stepped-editor', False, False), ('advanced-state', False, False), ('returned-calltrace', False, False)]"
check_eq "the two passes captured and carry no phase or error" "${out}" \
	'[(by[k]["status"], by[k]["phase"], by[k]["error"], by[k]["captureCompleted"]) for k in ("continued-event-log", "breakpoint-editor")]' \
	"[('passed', None, None, True), ('passed', None, None, True)]"
check_eq "the failures fall in three distinct phases" "${out}" \
	'sorted({o["phase"] for o in s["scenarios"] if o["status"] != "passed"})' \
	"['drive', 'launch', 'verify-capture']"
check_eq "views are carried beside scenario ids" "${out}" \
	'[(o["scenario"], o["view"]) for o in s["scenarios"]]' \
	"[('entry-shell', 'shell'), ('stepped-editor', 'editor'), ('advanced-state', 'state'), ('returned-calltrace', 'calltrace'), ('continued-event-log', 'eventLog'), ('breakpoint-editor', 'editorWithMark')]"
check_eq "nothing declared is missing from the report" "${out}" \
	's["missingScenarios"]' "[]"

# ---------------------------------------------------------------------------
# 2. One line per failed scenario — and no common cause.
# ---------------------------------------------------------------------------
echo "--- 2. one line per failed scenario, each with its own phase and cause ---"
out="$(run_lines "${work}/oct17.json")"
status=$?
expect "four failure lines, one per scenario, each naming its phase" \
	0 "${status}" "${out}" \
	"advanced-state (state): phase launch" \
	"returned-calltrace (calltrace): phase launch" \
	"stepped-editor (editor): phase drive" \
	"entry-shell (shell): phase verify-capture" \
	"35567ms" "32122ms" "#step-in-image" "the editor drew no rows" \
	"capture reached" "capture NOT reached"
checks=$((checks + 1))
n_lines="$(grep -c '^FAILED ' <<<"${out}" || true)"
n_distinct="$(grep '^FAILED ' <<<"${out}" | sort -u | wc -l | tr -d ' ')"
if [ "${n_lines}" = "4" ] && [ "${n_distinct}" = "4" ]; then
	echo "  [OK] exactly four FAILED lines, all distinct"
else
	failures=$((failures + 1))
	echo "  [FAILED] expected 4 distinct FAILED lines, got ${n_lines} (${n_distinct} distinct)"
	printf '%s\n' "${out}" | sed 's/^/      | /'
fi
refute "passing scenarios are not listed as failures" "${out}" \
	"continued-event-log" "breakpoint-editor"

# ---------------------------------------------------------------------------
# 3. Nested step: the innermost failing step is the phase.
# ---------------------------------------------------------------------------
echo "--- 3. a nested step failure ---"
out="$(run_summary "${work}/nested.json")"
check_eq "the innermost failing step is the phase, under its outer phase" "${out}" \
	'(by["stepped-editor"]["phase"], by["stepped-editor"]["stepPath"], by["stepped-editor"]["captureReached"])' \
	"('stepIn #1/1', ['drive', 'stepIn #1/1'], False)"

# ---------------------------------------------------------------------------
# 4. A failure no step carries is unattributed, not guessed.
# ---------------------------------------------------------------------------
echo "--- 4. a timeout with steps entered but none failing ---"
out="$(run_summary "${work}/timedout.json")"
check_eq "a timeout is unattributed, with the last step it entered" "${out}" \
	'(by["returned-calltrace"]["status"], by["returned-calltrace"]["phase"], by["returned-calltrace"]["lastStepEntered"], by["returned-calltrace"]["captureReached"])' \
	"('timedOut', 'unattributed', 'drive', False)"

out="$(run_summary "${work}/timeout_closed.json")"
check_eq "a timeout whose step then saw the app close: phased to drive, CAUSED by the timeout" "${out}" \
	'(by["stepped-editor"]["phase"], by["stepped-editor"]["error"], by["stepped-editor"]["errorLocation"], "has been closed" in (by["stepped-editor"]["stepError"] or ""))' \
	"('drive', 'Test timeout of 600000ms exceeded.', None, True)"
out="$(run_lines "${work}/timeout_closed.json")"
status=$?
expect "the line names the timeout as the cause and the step's error beside it" \
	0 "${status}" "${out}" \
	"phase drive, capture NOT reached, timedOut: Test timeout of 600000ms exceeded. (the step itself recorded: Error: locator.click: Target page"

# ---------------------------------------------------------------------------
# 5. Vacuity controls.
# ---------------------------------------------------------------------------
echo "--- 5. vacuity controls ---"
out="$(run_summary "${work}/green.json")"
check_eq "a run with zero failures reports zero failures and six passes" "${out}" \
	'(s["reportStatus"], s["failedCount"], s["passedCount"])' "('parsed', 0, 6)"
out="$(run_lines "${work}/green.json")"
status=$?
expect "a green run prints no FAILED line" 0 "${status}" "${out}" \
	"no scenario failed (6 passed)"
refute "a green run names no failure" "${out}" "FAILED "

out="$(run_summary "${work}/does-not-exist.json")"
status=$?
expect "a MISSING report is reported as missing" 0 "${status}" "${out}" \
	'"reportStatus": "missing"'
check_eq "a missing report states no failure count at all" "${out}" \
	'(s["failedCount"], s["passedCount"], s["scenarios"])' "(None, None, [])"
out="$(run_lines "${work}/does-not-exist.json")"
status=$?
expect "the line form of a missing report says so and exits 2" 2 "${status}" \
	"${out}" "NO PER-SCENARIO OUTCOMES" "missing"
refute "a missing report is never read as 'no scenario failed'" "${out}" \
	"no scenario failed"

out="$(run_summary "${work}/truncated.json")"
status=$?
expect "an unparseable report is reported as unparseable" 0 "${status}" \
	"${out}" '"reportStatus": "unparseable"'

out="$(run_summary "${work}/empty.json")"
check_eq "a report with no tests is EMPTY, and every declared scenario is missing" \
	"${out}" '(s["reportStatus"], len(s["missingScenarios"]))' "('empty', 6)"
out="$(run_lines "${work}/empty.json")"
status=$?
expect "the line form of an empty report exits 2" 2 "${status}" "${out}" \
	"NO PER-SCENARIO OUTCOMES"

out="$(run_summary "${work}/partial.json")"
check_eq "a declared scenario absent from the report is named" "${out}" \
	's["missingScenarios"]' \
	"['editor', 'state', 'calltrace', 'eventLog', 'editorWithMark']"
out="$(run_lines "${work}/partial.json")"
status=$?
expect "the line form names the scenarios the report does not cover" 0 \
	"${status}" "${out}" "NOT IN REPORT: editor" "NOT IN REPORT: editorWithMark"

# ---------------------------------------------------------------------------
# 6. Wiring: the lane and the spec.
# ---------------------------------------------------------------------------
echo "--- 6. wiring ---"
lane_text="$(cat "${lane}")"
# The needles below are LITERAL lane source text, so `${...}` must not expand.
# shellcheck disable=SC2016
{
	expect "the lane runs the JSON reporter beside the list reporter" 0 0 \
		"${lane_text}" "--reporter=list,json" \
		'PLAYWRIGHT_JSON_OUTPUT_NAME="${PW_JSON}"'
	expect "the lane removes a previous run's report before driving" 0 0 \
		"${lane_text}" 'rm -f "${PW_JSON}"'
	expect "the lane records scenarioOutcomes in manifest.json via the parser" 0 0 \
		"${lane_text}" "plat37_electron_outcomes" '"scenarioOutcomes"'
	expect "the lane's fail messages name the failed scenarios" 0 0 \
		"${lane_text}" '${failed_scenarios}'
}

spec_text="$(cat "${spec}")"
phases="$(python3 -c '
import importlib.util, sys
spec = importlib.util.spec_from_file_location("o", sys.argv[1])
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
print(" ".join(m.LANE_PHASES))' "${parser}" 2>/dev/null)" || phases=""
needles=()
for p in ${phases}; do needles+=("test.step(\"${p}\""); done
expect "the spec declares every lane phase the parser knows as a test.step (${phases:-none})" \
	0 "$([ "${#needles[@]}" -eq 4 ] && echo 0 || echo 1)" "${spec_text}" \
	"${needles[@]}"

echo ""
# The count itself is asserted: a suite that returned early must not be able to
# report success.
expected_checks=37
if [ "${checks}" -ne "${expected_checks}" ]; then
	echo "plat37-electron-outcomes contract: ran ${checks} check(s), expected ${expected_checks}" >&2
	exit 1
fi
if [ "${failures}" -eq 0 ]; then
	echo "plat37-electron-outcomes contract: ${checks} check(s) passed"
	exit 0
fi
echo "plat37-electron-outcomes contract: ${failures} of ${checks} check(s) FAILED" >&2
exit 1
