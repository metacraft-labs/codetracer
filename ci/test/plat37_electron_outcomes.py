#!/usr/bin/env python3
"""PLAT-37 Electron lane — what happened to EACH scenario, read from the run.

Reads the Playwright JSON report that `ci/test/plat37-macos-electron-capture.sh`
writes beside its human list log, and returns, per scenario: its title, status,
the PHASE it failed in, the first line of the error, the error's location, and
whether the capture phase was reached and completed. The lane stores the result
in `manifest.json` under `scenarioOutcomes` and prints one line per failure.

WHY. On 2026-10-17 the lane's run had four failures, and the readings written
from it said "all four failures are the same assertion at :862 ... AFTER the
window has been captured". Two had died in the launch fixture (a
`Performance limit exceeded` on "first window"), one inside `drive`, and only
one at that assertion after capturing (codetracer-pm issues/2026-10-17-plat37-
readings-of-2026-10-17-misreport-all-four-playwright-failures-as-one-
assertion.md). The lane offered nothing but a list log to summarise, so the
phase of each failure was inferred from an assertion's line number. This
module replaces the inference with a record, and is deliberately unable to do
the thing that went wrong: it ENUMERATES. It never groups failures under a
common cause, and it says "capture reached" only when the run entered the
capture step.

HOW A PHASE IS DECIDED
  * The spec wraps its body in `test.step`s named in `LANE_PHASES`. The JSON
    reporter keeps only `test.step` steps (fixture steps are category
    "fixture" and are filtered out — playwright/lib/reporters/json.js,
    `_serializeTestResult`), each with an `error` when it threw.
  * The phase is the INNERMOST step carrying an error; `stepPath` is the path
    of failing steps from the outermost to it.
  * A failed test that entered NO step failed before the body ran its first
    phase: the launch fixture (`ctPage` / `electronApp` setup). Its phase is
    `LAUNCH_PHASE`, and its error location says which file threw.
  * A failed test that entered steps but whose error no step carries (a test
    timeout while the running step never settled, a fixture teardown) is
    `UNATTRIBUTED_PHASE`, with the last step it entered beside it. It is never
    guessed into a phase.

HOW THE CAUSE IS DECIDED
  * `error` is the first line of the test's FIRST recorded error, the one
    that ended it, and `errorLocation` its location. For a step assertion
    that is the step's own error.
  * A test timeout is the case where they differ: the timeout is the cause,
    and the step that was running usually completes afterwards with a
    consequence of fixture teardown ("Target page, context or browser has
    been closed"). The phase is still that step; its error is kept as
    `stepError`, never promoted to the cause.

THE REPORT CAN BE ABSENT, AND THAT IS NOT "NO FAILURES". `reportStatus` is
`parsed`, `missing`, `unparseable` or `empty` (parsed, but holding no test),
and in every case but `parsed` the counts are `None`, not 0.

Reference for the report shape: https://playwright.dev/docs/test-reporters#json-reporter
(checked against @playwright/test 1.56.1, the version src/tests/gui/package.json
pins).

    python3 ci/test/plat37_electron_outcomes.py --report build/plat37-macos-electron/playwright.json
    python3 ci/test/plat37_electron_outcomes.py --report R --expect-views shell,editor --format lines

Library use: `summarise(path, expected_views)` returns the same dict the
`json` format prints; `failure_lines(summary)` the lines the `lines` format
prints. Neither prints, exits or raises on a bad report.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
from typing import Any, Dict, List, Optional, Sequence, Tuple

# The `test.step` titles the spec
# (src/tests/gui/tests/visual/plat37-electron-window-capture.spec.ts) declares,
# in the order the test body enters them. ci/test/plat37-electron-outcomes-test.sh
# fails if the spec stops declaring any of them.
LANE_PHASES: Tuple[str, ...] = ("viewport", "drive", "capture", "verify-capture")
# The step whose ENTRY means the scenario was driven and its capture attempted,
# and whose clean completion means this run ran the window-capture driver and
# wrote the route record. It does NOT mean the window was captured: the
# driver's own `outcome` is asserted in the following `verify-capture` step.
CAPTURE_STEP = "capture"
# Failed before entering any step: the launch fixture.
LAUNCH_PHASE = "launch"
# Failed with steps entered, but no step carries the error.
UNATTRIBUTED_PHASE = "unattributed"

# `test.describe("plat37-electron <scenario id>")` / `test("capture <view>")`.
_DESCRIBE_RE = re.compile(r"^plat37-electron (?P<id>\S+)$")
_TEST_RE = re.compile(r"^capture (?P<view>\S+)$")
_ANSI_RE = re.compile(r"\x1b\[[0-9;]*[A-Za-z]")


def _first_line(message: Optional[str]) -> Optional[str]:
    """The first non-blank line of an error message, ANSI colour removed."""
    if not message:
        return None
    for line in _ANSI_RE.sub("", message).splitlines():
        if line.strip():
            return line.strip()
    return None


def _relative_location(location: Optional[Dict[str, Any]],
                       root_dir: Optional[str]) -> Optional[str]:
    """`file:line`, the file relative to `root_dir` when under it.

    `root_dir` is the directory of the Playwright config (src/tests/gui), not
    the report's `rootDir`: that is the config's `testDir` (src/tests/gui/tests),
    and the launch fixture lives beside it in lib/, so relative to `rootDir`
    the one location that matters most would stay absolute.
    """
    if not isinstance(location, dict) or not location.get("file"):
        return None
    path = str(location["file"])
    if root_dir and os.path.isabs(path):
        rel = os.path.relpath(path, root_dir)
        if not rel.startswith(".."):
            path = rel
    line = location.get("line")
    return f"{path}:{line}" if line is not None else path


def _failing_path(steps: Optional[List[Dict[str, Any]]]) -> List[Dict[str, Any]]:
    """The chain of failing steps, outermost first, down to the innermost.

    At each level the LAST step carrying an error is followed: a test body
    stops at its first uncaught error, so later siblings were never entered,
    and a caught-and-continued failure earlier in the list is not the one that
    ended the test.
    """
    chain: List[Dict[str, Any]] = []
    level = steps or []
    while True:
        failed = [s for s in level if isinstance(s, dict) and s.get("error")]
        if not failed:
            return chain
        chain.append(failed[-1])
        level = failed[-1].get("steps") or []


def _walk_specs(suite: Dict[str, Any], titles: List[str]):
    """Yield (title path, spec) for every spec under `suite`, depth first."""
    here = titles + ([suite["title"]] if suite.get("title") else [])
    for spec in suite.get("specs") or []:
        yield here, spec
    for child in suite.get("suites") or []:
        yield from _walk_specs(child, here)


def _outcome(titles: List[str], spec: Dict[str, Any], test: Dict[str, Any],
             root_dir: Optional[str]) -> Dict[str, Any]:
    describe = next((m for m in (_DESCRIBE_RE.match(t) for t in titles) if m),
                    None)
    test_m = _TEST_RE.match(spec.get("title", ""))
    results = test.get("results") or []
    last = results[-1] if results else {}
    status = last.get("status") or ("skipped" if not results else "unknown")
    steps = last.get("steps") or []
    entered = [s.get("title") for s in steps if isinstance(s, dict)]
    capture = next((s for s in steps if isinstance(s, dict)
                    and s.get("title") == CAPTURE_STEP), None)

    out: Dict[str, Any] = {
        "scenario": describe.group("id") if describe else None,
        "view": test_m.group("view") if test_m else None,
        "title": " › ".join(titles[1:] + [spec.get("title", "")]),
        "status": status,
        "outcome": test.get("status"),
        "attempts": len(results),
        "stepsEntered": entered,
        "captureReached": capture is not None,
        "captureCompleted": capture is not None and not capture.get("error"),
        "phase": None,
        "stepPath": [],
        "lastStepEntered": entered[-1] if entered else None,
        "error": None,
        "errorLocation": None,
        # The failing step's own error when it differs from `error`, e.g. the
        # closed-page rejection a step completes with after a test timeout.
        "stepError": None,
        "stepErrorLocation": None,
    }
    if status in ("passed", "skipped"):
        return out

    # THE CAUSE is the test's FIRST recorded error: the one that ended it.
    # For an assertion that threw inside a step it is that step's error. For a
    # TEST TIMEOUT it is "Test timeout of …ms exceeded", and it is NOT the
    # error the running step later completes with: when the timeout fires,
    # Playwright abandons the body and tears the fixtures down, the step's
    # pending action then rejects with a consequence ("Target page, context or
    # browser has been closed"), and the step records THAT. Measured against
    # @playwright/test 1.56.1: `errors` is [timeout, consequence] and the step
    # carries only the consequence. Reporting the step's error as the cause
    # would turn every timeout into a closed-page failure — the misattribution
    # this record exists to prevent. The step's own error is kept beside the
    # cause as `stepError` whenever it says something else.
    chain = _failing_path(steps)
    errors = last.get("errors") or []
    first_error = errors[0] if errors else (last.get("error") or {})
    out["error"] = _first_line(first_error.get("message")
                               or first_error.get("value"))
    # A timeout has no location of its own; leave it absent rather than
    # borrow the consequence's.
    out["errorLocation"] = _relative_location(
        first_error.get("location") or last.get("errorLocation"), root_dir)
    if chain:
        innermost = chain[-1]
        err = innermost.get("error") or {}
        step_error = _first_line(err.get("message") or err.get("value"))
        out["phase"] = innermost.get("title")
        out["stepPath"] = [s.get("title") for s in chain]
        if out["error"] is None:
            # No test-level error at all (not produced by 1.56.1 for a failed
            # test, but a hand-trimmed report can lack it): the step's error
            # is the only cause on record.
            out["error"] = step_error
            out["errorLocation"] = _relative_location(err.get("location"),
                                                      root_dir)
        elif step_error and step_error != out["error"]:
            out["stepError"] = step_error
            out["stepErrorLocation"] = _relative_location(err.get("location"),
                                                          root_dir)
    else:
        out["phase"] = UNATTRIBUTED_PHASE if entered else LAUNCH_PHASE
    return out


def scenario_outcomes(report: Dict[str, Any]) -> List[Dict[str, Any]]:
    """One outcome per test in a parsed Playwright JSON report, in report order."""
    config = report.get("config") or {}
    root_dir = (os.path.dirname(config["configFile"])
                if config.get("configFile") else config.get("rootDir"))
    outcomes = []
    for top in report.get("suites") or []:
        for titles, spec in _walk_specs(top, []):
            for test in spec.get("tests") or []:
                outcomes.append(_outcome(titles, spec, test, root_dir))
    return outcomes


def summarise(path: str,
              expected_views: Sequence[str] = ()) -> Dict[str, Any]:
    """Read the report at `path` and return the `scenarioOutcomes` record.

    Never raises on a bad report: a missing, unparseable or empty one is
    stated in `reportStatus`/`problem`, with counts of `None`.
    """
    summary: Dict[str, Any] = {
        "schemaVersion": 1,
        "source": "playwright JSON reporter",
        "reportPath": path,
        "reportStatus": None,
        "problem": None,
        "reportStartTime": None,
        "phases": [LAUNCH_PHASE] + list(LANE_PHASES),
        "rule": "enumerated per scenario from the run's own record; failures "
                "are never grouped under a common cause, and captureReached "
                "is true only when the run entered the capture step",
        "passedCount": None,
        "failedCount": None,
        "scenarios": [],
        "missingScenarios": list(expected_views),
        "reportErrors": [],
    }
    if not os.path.exists(path):
        summary["reportStatus"] = "missing"
        summary["problem"] = (f"no Playwright JSON report at {path}: the "
                              "driver did not write one, so no per-scenario "
                              "outcome is known")
        return summary
    try:
        with open(path, encoding="utf-8") as f:
            report = json.load(f)
        if not isinstance(report, dict):
            raise ValueError("the top level is not an object")
    except (OSError, ValueError) as e:
        summary["reportStatus"] = "unparseable"
        summary["problem"] = f"the Playwright JSON report at {path} did not parse: {e}"
        return summary

    outcomes = scenario_outcomes(report)
    summary["reportStartTime"] = (report.get("stats") or {}).get("startTime")
    summary["reportErrors"] = [
        _first_line(e.get("message") if isinstance(e, dict) else str(e))
        for e in report.get("errors") or []]
    seen = {o["view"] for o in outcomes}
    summary["missingScenarios"] = [v for v in expected_views if v not in seen]
    if not outcomes:
        summary["reportStatus"] = "empty"
        summary["problem"] = (f"the Playwright JSON report at {path} holds no "
                              "test, so no per-scenario outcome is known")
        return summary
    summary["reportStatus"] = "parsed"
    summary["scenarios"] = outcomes
    summary["passedCount"] = sum(o["status"] == "passed" for o in outcomes)
    summary["failedCount"] = sum(o["status"] not in ("passed", "skipped")
                                 for o in outcomes)
    return summary


def failure_lines(summary: Dict[str, Any]) -> List[str]:
    """One human line per failed scenario, plus what the record cannot say."""
    if summary.get("reportStatus") != "parsed":
        return [f"NO PER-SCENARIO OUTCOMES ({summary.get('reportStatus')}): "
                f"{summary.get('problem')}"]
    lines = []
    for o in summary["scenarios"]:
        if o["status"] in ("passed", "skipped"):
            continue
        reached = "capture reached" if o["captureReached"] else \
            "capture NOT reached"
        where = f" at {o['errorLocation']}" if o["errorLocation"] else ""
        after = f" (last step entered: {o['lastStepEntered']})" \
            if o["phase"] == UNATTRIBUTED_PHASE else ""
        step = f" (the step itself recorded: {o['stepError']})" \
            if o.get("stepError") else ""
        lines.append(f"FAILED {o['scenario']} ({o['view']}): phase "
                     f"{o['phase']}{after}, {reached}, {o['status']}: "
                     f"{o['error']}{where}{step}")
    for v in summary.get("missingScenarios") or []:
        lines.append(f"NOT IN REPORT: {v} — the report holds no test for this "
                     "declared view")
    for e in summary.get("reportErrors") or []:
        lines.append(f"REPORT ERROR (outside any test): {e}")
    if not lines:
        lines.append(f"no scenario failed ({summary['passedCount']} passed)")
    return lines


def main(argv: Optional[Sequence[str]] = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n", 1)[0])
    ap.add_argument("--report", required=True,
                    help="the Playwright JSON report")
    ap.add_argument("--expect-views", default="",
                    help="comma-separated views the run was asked to drive")
    ap.add_argument("--format", choices=("json", "lines"), default="json")
    args = ap.parse_args(argv)
    views = [v for v in args.expect_views.split(",") if v]
    summary = summarise(args.report, views)
    if args.format == "json":
        json.dump(summary, sys.stdout, indent=2, sort_keys=True)
        sys.stdout.write("\n")
        return 0
    for line in failure_lines(summary):
        print(line)
    # 2: the record cannot say what happened. Distinct from 0 so a caller that
    # reads only the status can still not mistake "unknown" for "no failures".
    return 0 if summary["reportStatus"] == "parsed" else 2


if __name__ == "__main__":
    sys.exit(main())
