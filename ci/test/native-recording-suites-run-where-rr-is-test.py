#!/usr/bin/env python3
"""native-recording-suites-run-where-rr-is-test.py -- a job that runs a suite
recording a native program under rr must provide rr and build `ct-native-replay`
first.

WHY THIS EXISTS
---------------
`src/frontend/tui/tests/test_plat60_native_low_level_code.nim` opens an rr
recording of `codetracer-native-test-programs/c/sudoku_solver`, made by
`src/frontend/tui/tests/fixtures/native_recording.nim` through rr and replayed
through `ct-native-replay`. It sat in the `tui` lane, which the `tui-tests` job
of `codetracer.yml` runs on the generic Linux hosts -- where rr does not work and
no step builds `ct-native-replay`. So the suite skipped every case
("ct-native-replay was not found"), and the lane, which fails an all-skipped
file, was red (codetracer-pm
issues/2026-11-09-tui-job-runs-plat60-and-plat65-without-their-prerequisites.md).

The fix moves such suites into a lane of their own, `tui-native`, run by the
`test-tui-native` recipe in `test-ui-tests-rr` -- the job the workflow routes
rr work to, which already sets rr up and builds `ct-native-replay` (through
`just test-gui` -> `build-siblings` -> `scripts/build-siblings.sh`) for its
`plat60-native-capture-electron` step. This test keeps that true, for every
job and every lane, so a native-recording suite added to any lane a job runs
is covered with no edit here.

WHAT IS ASSERTED, for every job of the workflow
-----------------------------------------------
A job "runs a native-recording suite" when a step of it invokes a `just` recipe
that reaches (through `just <recipe>` calls and recipe dependencies) a lane of
`ci/lib/run-nim-test-lane.sh` whose files, as `ci/lib/test-lane-files.sh` lists
them, `import` `fixtures/native_recording` outside a comment. Every such job
must, in steps BEFORE the first step that runs such a lane:

  1. run `ci/setup-rr-backend.sh`, which puts rr on the PATH of later steps
     and checks out `../codetracer-native-backend`;
  2. run a `just` recipe that reaches `ensure-ct-native-replay` or
     `scripts/build-siblings.sh`, the two routes that build
     `../codetracer-native-backend/target/debug/ct-native-replay`, the path
     the fixture's `findCtNativeReplay` looks at.

Not asserted here: that the job is ROUTED to a host where rr works. That is a
fact about the runner pool, not about the workflow file; the comment on
`test-ui-tests-rr` records it.

CONTROLS
--------
  * Positive: the detector finds `test_plat60_native_low_level_code.nim` in
    some lane. The live workflow has at least one job that runs a
    native-recording suite, `test-ui-tests-rr` is one of them, and `tui-tests`
    is not.
  * Negative: copies of the live workflow with the rr setup step removed from
    `test-ui-tests-rr`, with its `just test-gui` step removed, with its
    native-lane step moved before both, and with that native-lane step copied
    into `tui-tests`, must each be reported, naming the job. These prove the
    checker sees the absence it exists to report.

No mocks: the subject is the committed workflow, justfile and lane file list;
the negative arms are real copies of the parsed workflow with one step changed.
Needs python3 and PyYAML (stock ubuntu-latest has both), and bash for the lane
list. The structure follows `ci/test/launcher-suites-build-launcher-test.py`,
which asks the same question about the launcher binary.

Run:  python3 ci/test/native-recording-suites-run-where-rr-is-test.py
Lane: a step of `ci-contract-suites` in `.github/workflows/codetracer.yml`.
"""

import copy
import pathlib
import re
import subprocess
import sys

try:
    import yaml
except ImportError:  # pragma: no cover
    print("native-recording-suites-run-where-rr-is: PyYAML is required", file=sys.stderr)
    sys.exit(2)

REPO_ROOT = pathlib.Path(__file__).resolve().parents[2]
WORKFLOW = REPO_ROOT / ".github" / "workflows" / "codetracer.yml"

# The suite the issue names. The positive control requires the detector to find
# it, so a detector that stopped seeing it cannot pass vacuously.
KNOWN_NATIVE_SUITE = "src/frontend/tui/tests/test_plat60_native_low_level_code.nim"
# The job rr work is routed to, and the job it must not reach.
RR_JOB = "test-ui-tests-rr"
TUI_JOB = "tui-tests"

# An `import` of the fixture, by any relative spelling (`./fixtures/...`,
# `../../tui/tests/fixtures/...`), alone or in a list. The same dependency
# `ci/lib/test-lane-files.sh` selects the `tui-native` lane by.
NATIVE_IMPORT_RE = re.compile(r"^\s*import\s+.*\bfixtures/native_recording\b")
LANE_RE = re.compile(r"run-nim-test-lane\.sh\s+([A-Za-z0-9_-]+)")
JUST_RE = re.compile(r"\bjust\s+([A-Za-z0-9_-]+)")
# A recipe header: the name at column 0, optional parameters, `:`, then the
# dependencies. `name := value` is an assignment, not a recipe.
RECIPE_HEADER_RE = re.compile(r"^(@?)([A-Za-z0-9_-]+)([^:=]*):(?!=)(.*)$")
RR_SETUP_RE = re.compile(r"(^|[\s/])ci/setup-rr-backend\.sh\b")
# The two routes that build `ct-native-replay`: the recipe of that name, or the
# sibling builder `build-siblings` drives (codetracer-native-backend among the
# siblings it builds).
NATIVE_REPLAY_RECIPE = "ensure-ct-native-replay"
BUILD_SIBLINGS_RE = re.compile(r"\bscripts/build-siblings\.sh\b")


def code_lines(text):
    """`text` without shell/YAML/Nim comment lines, which name things in prose."""
    return [ln for ln in text.splitlines() if not ln.lstrip().startswith("#")]


def parse_justfile(path):
    """{recipe: (dependencies, body lines)} for every recipe in `path`."""
    recipes = {}
    current = None
    for line in path.read_text().splitlines():
        if line and not line[0].isspace():
            current = None
            m = RECIPE_HEADER_RE.match(line)
            if m and not line.startswith("#"):
                deps = re.findall(r"[A-Za-z0-9_-]+", m.group(4).split("#")[0])
                current = m.group(2)
                recipes[current] = (deps, [])
        elif current is not None:
            recipes[current][1].append(line)
    return recipes


def reachable(name, recipes, seen=None):
    """Every recipe `just <name>` runs, itself included, following `just` calls
    in bodies and dependencies in headers."""
    seen = set() if seen is None else seen
    if name in seen or name not in recipes:
        return seen
    seen.add(name)
    deps, body = recipes[name]
    body_text = "\n".join(code_lines("\n".join(body)))
    for callee in list(deps) + JUST_RE.findall(body_text):
        reachable(callee, recipes, seen)
    return seen


def body_text(name, recipes):
    return "\n".join(code_lines("\n".join(recipes[name][1])))


def recipe_lanes(name, recipes):
    """The test lanes `just <name>` runs."""
    lanes = set()
    for r in reachable(name, recipes):
        lanes |= set(LANE_RE.findall(body_text(r, recipes)))
    return lanes


def builds_native_replay(name, recipes):
    """Whether `just <name>` reaches a build of `ct-native-replay`."""
    return any(r == NATIVE_REPLAY_RECIPE or BUILD_SIBLINGS_RE.search(body_text(r, recipes))
               for r in reachable(name, recipes))


def bash_lines(script):
    out = subprocess.run(
        ["bash", "-c", "source ci/lib/test-lane-files.sh && " + script],
        cwd=REPO_ROOT, capture_output=True, text=True, check=True,
    ).stdout
    return [ln for ln in out.splitlines() if ln]


_lane_files_cache = {}


def lane_files(lane):
    if lane not in _lane_files_cache:
        _lane_files_cache[lane] = bash_lines(f'test_lane_files "{lane}"')
    return _lane_files_cache[lane]


def imports_native_recording(rel_path):
    path = REPO_ROOT / rel_path
    if not path.is_file():
        return False
    return any(NATIVE_IMPORT_RE.search(ln) for ln in code_lines(path.read_text()))


def native_suites_of_lane(lane):
    return [f for f in lane_files(lane) if imports_native_recording(f)]


def step_run(step):
    run = step.get("run") if isinstance(step, dict) else None
    return "\n".join(code_lines(run)) if isinstance(run, str) else ""


def step_recipes(step):
    return JUST_RE.findall(step_run(step))


def sets_up_rr(step):
    return bool(RR_SETUP_RE.search(step_run(step)))


def step_builds_native_replay(step, recipes):
    return any(builds_native_replay(r, recipes) for r in step_recipes(step))


def check_workflow(workflow, recipes):
    """(violations, {job: sorted native-recording suites}) for a parsed workflow."""
    violations = []
    examined = {}
    for job_id, job in (workflow.get("jobs") or {}).items():
        steps = job.get("steps") or [] if isinstance(job, dict) else []
        first_lane_step = None
        suites = set()
        for i, step in enumerate(steps):
            for recipe in step_recipes(step):
                for lane in recipe_lanes(recipe, recipes):
                    found = native_suites_of_lane(lane)
                    if found:
                        suites.update(found)
                        if first_lane_step is None:
                            first_lane_step = i
        if first_lane_step is None:
            continue
        examined[job_id] = sorted(suites)
        what = f"job `{job_id}` runs {', '.join(sorted(suites))}"
        before = steps[:first_lane_step]
        if not any(sets_up_rr(s) for s in before):
            violations.append(
                f"{what}, but no step before them runs `ci/setup-rr-backend.sh` "
                "(rr on the PATH, ../codetracer-native-backend checked out)")
        if not any(step_builds_native_replay(s, recipes) for s in before):
            violations.append(
                f"{what}, but no step before them runs a `just` recipe that builds "
                f"ct-native-replay (`{NATIVE_REPLAY_RECIPE}`, or `scripts/build-siblings.sh` "
                "as `just test-gui` reaches it)")
    return violations, examined


# --- the test itself ---------------------------------------------------------

checks = 0
failures = 0


def ok(msg):
    global checks
    checks += 1
    print(f"  [OK]     {msg}")


def bad(msg, *detail):
    global checks, failures
    checks += 1
    failures += 1
    print(f"  [FAILED] {msg}")
    for d in detail:
        print(f"             {d}")


def main():
    recipes = parse_justfile(REPO_ROOT / "justfile")
    workflow = yaml.safe_load(WORKFLOW.read_text())

    print("=== native-recording-suites-run-where-rr-is — does every job that records under rr have rr and ct-native-replay? ===")
    print()
    print("Step 1: positive control — the detector sees the native-recording suite")
    detected = set()
    for lane in bash_lines("test_lane_ids"):
        detected |= set(native_suites_of_lane(lane))
    if KNOWN_NATIVE_SUITE in detected:
        ok(f"{KNOWN_NATIVE_SUITE} is detected as importing fixtures/native_recording")
    else:
        bad(f"{KNOWN_NATIVE_SUITE} is NOT detected — the detector or the lane list moved")
    print()

    print("Step 2: the live workflow provides rr and ct-native-replay wherever it runs such a suite")
    violations, examined = check_workflow(workflow, recipes)
    if RR_JOB in examined:
        ok(f"{len(examined)} job(s) run a native-recording suite, `{RR_JOB}` among them")
    else:
        bad(f"`{RR_JOB}` is not seen running a native-recording suite — the walk found: "
            + (", ".join(examined) or "nothing"))
    if TUI_JOB in examined:
        bad(f"`{TUI_JOB}` runs {', '.join(examined[TUI_JOB])}, on hosts where rr does not work")
    else:
        ok(f"`{TUI_JOB}` runs no native-recording suite")
    if violations:
        bad(f"{len(violations)} violation(s) in {WORKFLOW.relative_to(REPO_ROOT)}", *violations)
    else:
        ok("every such job sets rr up and builds ct-native-replay first")
    print()

    print("Step 3: negative controls — copies with one step changed are each reported")
    jobs = workflow["jobs"]

    def runs_native_lane(step):
        return any(native_suites_of_lane(lane)
                   for r in step_recipes(step) for lane in recipe_lanes(r, recipes))

    def arm(label, job, mutate):
        wf = copy.deepcopy(workflow)
        steps = (wf["jobs"].get(job) or {}).get("steps")
        if not steps or not mutate(steps):
            bad(f"{label}: nothing to change in the live `{job}` — the arm proves nothing")
            return
        v, _ = check_workflow(wf, recipes)
        if any(f"`{job}`" in x for x in v):
            ok(f"{label}: reported for `{job}`")
        else:
            bad(f"{label}: NOT reported — the checker cannot see this absence")

    def drop(pred):
        def mutate(steps):
            before = len(steps)
            steps[:] = [s for s in steps if not pred(s)]
            return len(steps) != before
        return mutate

    def native_lane_first(steps):
        moved = [s for s in steps if runs_native_lane(s)]
        if not moved:
            return False
        steps[:] = moved + [s for s in steps if not runs_native_lane(s)]
        return True

    def add_native_lane(steps):
        # A COPY of the live `test-ui-tests-rr` step that runs the native lane,
        # appended to `tui-tests` -- the lane split undone by running the split-
        # out lane in the job it was split out of. Copied rather than spelled
        # here: a literal `just <recipe>` in this file would read as a call to
        # `ci/test/shell-gate-coverage.sh`'s reachability walk, which would then
        # credit the recipe as reached through this test instead of through the
        # workflow (and `ci/test/ci-reached-recipes-test.sh` checks exactly
        # that credit).
        native = [s for s in (jobs.get(RR_JOB) or {}).get("steps") or [] if runs_native_lane(s)]
        if not native:
            return False
        steps.append(copy.deepcopy(native[0]))
        return True

    if RR_JOB not in jobs:
        bad(f"the live workflow has no `{RR_JOB}` job to mutate")
    else:
        arm("without the rr setup step", RR_JOB, drop(sets_up_rr))
        arm("without the step that builds ct-native-replay", RR_JOB,
            drop(lambda s: step_builds_native_replay(s, recipes)))
        arm("with the native lane moved before both", RR_JOB, native_lane_first)
    if TUI_JOB not in jobs:
        bad(f"the live workflow has no `{TUI_JOB}` job to mutate")
    else:
        arm("with the native-lane step copied into `tui-tests`", TUI_JOB, add_native_lane)

    print()
    print(f"{checks} check(s), {failures} failure(s)")
    print("RESULT: " + ("FAILED" if failures else "OK"))
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
