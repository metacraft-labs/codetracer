#!/usr/bin/env python3
"""launcher-suites-build-launcher-test.py -- a job that runs a suite executing
the real launcher must build that launcher first, from the lock's revision.

WHY THIS EXISTS
---------------
`src/tests/launcher/test_launcher_routes_tui.nim` (the `tui` lane) and
`src/frontend/tui/tests/real_terminal/test_real_launcher_exec.nim` (the
`tui-real-terminal` lane) execute `../codetracer-launcher/out/launcher`, the real
`ct`, and fail when it is missing. The `tui-tests` job of `codetracer.yml` ran
both lanes and neither cloned nor built `codetracer-launcher`. The suites passed
on a persistent runner, which kept a launcher an earlier job had built (of some
older revision), and failed on an ephemeral one with
`missing .../codetracer-launcher/out/launcher` (codetracer PR #915; codetracer-pm
issues/2026-11-09-tui-job-runs-launcher-suites-without-building-the-launcher.md).

WHAT IS ASSERTED, for every job of the workflow
-----------------------------------------------
A job "runs a launcher suite" when a step of it invokes a `just` recipe that
reaches (through `just <recipe>` calls and recipe dependencies) a lane of
`ci/lib/run-nim-test-lane.sh` whose files, as `ci/lib/test-lane-files.sh` lists
them, build the path of the launcher BINARY (`"out" / "launcher"` or
`codetracer-launcher/out/launcher` outside a comment). Every such job must,
before the first step that runs such a lane:

  1. clone `codetracer-launcher` as a BARE entry of a `siblings:` /
     `extra-siblings:` input, which `clone-siblings` resolves to the revision
     this commit's `repro.lock` pins. An entry with an explicit `=<ref>` names a
     branch tip or a hand-copied commit, not the lock;
  2. build it, after the clone: a `run:` command line that enters
     `../codetracer-launcher` and runs its `just build` (or `build.sh`) --
     `just build-once` or `just build-gpui` beside a mention of the checkout
     does not count.

The file list is the lanes' own, so a launcher suite added to any lane a job runs
is covered with no edit here.

CONTROLS
--------
  * Positive: the detector finds both launcher suites named above, and does not
    count `test_caps_file_shape.nim`, which imports the launcher's SOURCE and
    executes no binary. The live workflow has at least one job that runs a
    launcher suite, and `tui-tests` is one of them.
  * Negative: copies of the live workflow with the build step removed, with the
    clone entry removed, with the entry pinned to `=agents`, with the build
    moved after the lanes, and with the build step running `just lint` instead
    of `just build` must each be reported, naming `tui-tests`. These prove
    the checker sees the absence it exists to report.

No mocks: the subject is the committed workflow, justfile and lane file list;
the negative arms are real copies of the parsed workflow with one step changed.
Needs python3 and PyYAML (stock ubuntu-latest has both), and bash for the lane
list.

Run:  python3 ci/test/launcher-suites-build-launcher-test.py
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
    print("launcher-suites-build-launcher: PyYAML is required", file=sys.stderr)
    sys.exit(2)

REPO_ROOT = pathlib.Path(__file__).resolve().parents[2]
WORKFLOW = REPO_ROOT / ".github" / "workflows" / "codetracer.yml"
LAUNCHER_REPO = "codetracer-launcher"

# The two suites the issue names. The positive control requires the detector to
# find both, so a detector that stopped seeing them cannot pass vacuously.
KNOWN_LAUNCHER_SUITES = {
    "src/tests/launcher/test_launcher_routes_tui.nim",
    "src/frontend/tui/tests/real_terminal/test_real_launcher_exec.nim",
}
# Imports `codetracer-launcher/src/caps` and runs no binary: a clone suffices.
SOURCE_ONLY_SUITE = "src/frontend/tui/app/tests/test_caps_file_shape.nim"

LAUNCHER_BIN_RE = re.compile(r'"out"\s*/\s*"launcher"|codetracer-launcher/out/launcher')
LANE_RE = re.compile(r"run-nim-test-lane\.sh\s+([A-Za-z0-9_-]+)")
JUST_RE = re.compile(r"\bjust\s+([A-Za-z0-9_-]+)")
# A recipe header: the name at column 0, optional parameters, `:`, then the
# dependencies. `name := value` is an assignment, not a recipe.
RECIPE_HEADER_RE = re.compile(r"^(@?)([A-Za-z0-9_-]+)([^:=]*):(?!=)(.*)$")


def code_lines(text):
    """`text` without shell/YAML comment lines, which name recipes in prose."""
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


def recipe_lanes(name, recipes, seen=None):
    """The test lanes `just <name>` runs, following calls and dependencies."""
    seen = set() if seen is None else seen
    if name in seen or name not in recipes:
        return set()
    seen.add(name)
    deps, body = recipes[name]
    body_text = "\n".join(code_lines("\n".join(body)))
    lanes = set(LANE_RE.findall(body_text))
    for callee in list(deps) + JUST_RE.findall(body_text):
        lanes |= recipe_lanes(callee, recipes, seen)
    return lanes


_lane_files_cache = {}


def lane_files(lane):
    if lane not in _lane_files_cache:
        out = subprocess.run(
            ["bash", "-c", 'source ci/lib/test-lane-files.sh && test_lane_files "$1"', "_", lane],
            cwd=REPO_ROOT, capture_output=True, text=True, check=True,
        ).stdout
        _lane_files_cache[lane] = [f for f in out.splitlines() if f]
    return _lane_files_cache[lane]


def runs_launcher_binary(rel_path):
    path = REPO_ROOT / rel_path
    if not path.is_file():
        return False
    return any(LAUNCHER_BIN_RE.search(ln) for ln in code_lines(path.read_text()))


def launcher_suites_of_lane(lane):
    return [f for f in lane_files(lane) if runs_launcher_binary(f)]


def step_run(step):
    run = step.get("run") if isinstance(step, dict) else None
    return "\n".join(code_lines(run)) if isinstance(run, str) else ""


# The `with:` inputs that take `clone-siblings` entries: `setup-dev-env`'s
# `siblings` and `setup-db-backend-siblings`' `extra-siblings`. Only these are
# resolved against the lock; an `actions/checkout` `repository:` or a `path:`
# that happens to name the launcher is a clone at some `ref:`, not a bare entry.
SIBLING_INPUTS = ("siblings", "extra-siblings")

# A build of the launcher: a command line that enters `../codetracer-launcher`
# and runs its `just build` recipe or `build.sh`. `just build` must end there --
# `just build-once` and `just build-gpui` are this repo's recipes, and a step
# that merely mentions the checkout beside one of them builds no launcher.
LAUNCHER_BUILD_RE = re.compile(
    rf"\bcd\s+\S*\.\./{LAUNCHER_REPO}(?![\w-]).*?(\bjust\s+build(?![\w-])|\bbuild\.sh\b)")


def clone_entries(step):
    """The `codetracer-launcher` entries `step`'s sibling-list inputs hold."""
    found = []
    for key, value in (step.get("with") or {}).items() if isinstance(step, dict) else []:
        if key not in SIBLING_INPUTS or not isinstance(value, str):
            continue
        for ln in value.splitlines():
            for token in ln.split("#")[0].split():
                name = token.split("=", 1)[0].split("/")[-1]
                if name == LAUNCHER_REPO:
                    found.append(token)
    return found


def builds_launcher(step):
    return any(LAUNCHER_BUILD_RE.search(ln) for ln in step_run(step).splitlines())


def check_workflow(workflow, recipes):
    """(violations, {job: sorted launcher suites}) for a parsed workflow."""
    violations = []
    examined = {}
    for job_id, job in (workflow.get("jobs") or {}).items():
        steps = job.get("steps") or [] if isinstance(job, dict) else []
        first_lane_step = None
        suites = set()
        for i, step in enumerate(steps):
            for recipe in JUST_RE.findall(step_run(step)):
                for lane in recipe_lanes(recipe, recipes):
                    found = launcher_suites_of_lane(lane)
                    if found:
                        suites.update(found)
                        if first_lane_step is None:
                            first_lane_step = i
        if first_lane_step is None:
            continue
        examined[job_id] = sorted(suites)
        what = f"job `{job_id}` runs {', '.join(sorted(suites))}"

        clone_at = None
        for i, step in enumerate(steps[:first_lane_step]):
            entries = clone_entries(step)
            pinned = [e for e in entries if "=" in e]
            if pinned:
                violations.append(
                    f"{what}, and clones the launcher as {', '.join(pinned)}: name it BARE "
                    "so clone-siblings takes the revision this commit's repro.lock pins")
            if clone_at is None and entries and not pinned:
                clone_at = i
        if clone_at is None:
            violations.append(
                f"{what}, but no step before them clones `{LAUNCHER_REPO}` as a bare sibling entry")

        build_at = next((i for i, s in enumerate(steps[:first_lane_step]) if builds_launcher(s)), None)
        if build_at is None:
            violations.append(
                f"{what}, but no step before them builds the launcher "
                f"(`cd ../{LAUNCHER_REPO} && ... just build`)")
        elif clone_at is not None and build_at < clone_at:
            violations.append(f"{what}, but builds the launcher before it clones it")
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

    print("=== launcher-suites-build-launcher — does every job that runs the real launcher build it? ===")
    print()
    print("Step 1: positive control — the detector sees the launcher suites")
    detected = set(launcher_suites_of_lane("tui")) | set(launcher_suites_of_lane("tui-real-terminal"))
    for suite in sorted(KNOWN_LAUNCHER_SUITES):
        if suite in detected:
            ok(f"{suite} is detected as executing the launcher binary")
        else:
            bad(f"{suite} is NOT detected — the detector or the lane list moved")
    if SOURCE_ONLY_SUITE in detected:
        bad(f"{SOURCE_ONLY_SUITE} is counted, but it only imports the launcher's source")
    else:
        ok(f"{SOURCE_ONLY_SUITE}, which imports only the launcher's source, is not counted")
    print()

    print("Step 2: the live workflow builds the launcher wherever it runs a launcher suite")
    violations, examined = check_workflow(workflow, recipes)
    if "tui-tests" in examined:
        ok(f"{len(examined)} job(s) run a launcher suite, `tui-tests` among them")
    else:
        bad("`tui-tests` is not seen running a launcher suite — the walk found: "
            + (", ".join(examined) or "nothing"))
    if violations:
        bad(f"{len(violations)} violation(s) in {WORKFLOW.relative_to(REPO_ROOT)}", *violations)
    else:
        ok("every such job clones the launcher at the lock's revision and builds it first")
    print()

    print("Step 3: negative controls — copies with one step changed are each reported")
    jobs = workflow["jobs"]
    tui_steps = jobs.get("tui-tests", {}).get("steps", [])

    def arm(label, mutate):
        wf = copy.deepcopy(workflow)
        changed = mutate(wf["jobs"]["tui-tests"]["steps"])
        if not changed:
            bad(f"{label}: nothing to change in the live `tui-tests` — the arm proves nothing")
            return
        v, _ = check_workflow(wf, recipes)
        if any("`tui-tests`" in x for x in v):
            ok(f"{label}: reported for `tui-tests`")
        else:
            bad(f"{label}: NOT reported — the checker cannot see this absence")

    def drop_build(steps):
        before = len(steps)
        steps[:] = [s for s in steps if not builds_launcher(s)]
        return len(steps) != before

    def drop_clone(steps):
        changed = False
        for s in steps:
            for key, value in (s.get("with") or {}).items():
                if isinstance(value, str) and clone_entries(s):
                    new = "\n".join(ln for ln in value.splitlines()
                                    if LAUNCHER_REPO not in ln.split("#")[0])
                    if new != value:
                        s["with"][key] = new
                        changed = True
        return changed

    def pin_clone(steps):
        changed = False
        for s in steps:
            for key, value in (s.get("with") or {}).items():
                if isinstance(value, str):
                    new = re.sub(rf"(?m)^(\s*){LAUNCHER_REPO}\s*$", rf"\g<1>{LAUNCHER_REPO}=agents", value)
                    if new != value:
                        s["with"][key] = new
                        changed = True
        return changed

    def build_after_lanes(steps):
        builds = [s for s in steps if builds_launcher(s)]
        if not builds:
            return False
        steps[:] = [s for s in steps if not builds_launcher(s)] + builds
        return True

    def build_other_recipe(steps):
        changed = False
        for s in steps:
            if builds_launcher(s):
                s["run"] = re.sub(r"\bjust\s+build(?![\w-])", "just lint", s["run"])
                changed = True
        return changed

    if not tui_steps:
        bad("the live workflow has no `tui-tests` job to mutate")
    else:
        arm("without the build step", drop_build)
        arm("without the clone entry", drop_clone)
        arm("with the clone entry pinned to `=agents`", pin_clone)
        arm("with the build moved after the lanes", build_after_lanes)
        arm("with the launcher step running `just lint` instead of `just build`", build_other_recipe)

    print()
    print(f"{checks} check(s), {failures} failure(s)")
    print("RESULT: " + ("FAILED" if failures else "OK"))
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
