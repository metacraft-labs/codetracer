#!/usr/bin/env python3
"""Assert that every job in a workflow declares an explicit `timeout-minutes`.

exit 0 -> every job in every workflow examined carries a usable bound
exit 1 -> at least one does not; each violation names the workflow and the job
exit 2 -> the check examined nothing, or a workflow could not be read

Usage: ci/verdict/job-timeouts.py [WORKFLOW ...]
       defaults to .github/workflows/codetracer.yml

WHY THIS CHECK EXISTS
---------------------
A job with no `timeout-minutes` does not run unbounded in some abstract sense --
it inherits GitHub's default of 360 minutes. On `ubuntu-latest` that costs a
slow queue. On a SELF-HOSTED runner it costs the runner: the job holds the
machine for six hours and the org GARM pool was measured at fourteen runners
total, twelve busy, two offline. An unbounded self-hosted job does not idle, it
strands a scarce resource, and it holds its workflow's concurrency group while
doing so.

On 2026-09-06 thirty of codetracer.yml's forty-two jobs declared no
`timeout-minutes`, and twenty-five of those thirty ran on self-hosted runners --
including every build-artefact job and all four lint lanes. That is the state
this check exists to prevent recurring. It is cheap to reintroduce: adding a job
requires actively remembering a key that nothing else in the file demands.

WHY 360 IS TREATED AS ABSENT
----------------------------
`timeout-minutes: 360` is exactly GitHub's default, so declaring it changes
nothing and communicates nothing. Accepting it would let the check be satisfied
by a value chosen to satisfy the check. The upper bound here is 359: any real
bound must be at least one minute tighter than no bound at all.

WHY AN EXPRESSION IS A VIOLATION
--------------------------------
`timeout-minutes` accepts `${{ }}`, but a bound that is computed cannot be read
off the file, and the point of the bound is that the worst-case hold on a
concurrency group is computable from the `needs:` graph without running
anything. If a job ever genuinely needs a conditional bound, widen this check
deliberately rather than by accident.

WHAT IS NOT ASSERTED, AND WHY
-----------------------------
This defaults to codetracer.yml alone. The other workflows in `.github/workflows`
are also unbounded -- `--report-only` will list them -- but they are owned
elsewhere, and turning someone else's green red as a side effect of this change
would be the wrong way to raise the subject. Widen the default argument list
when their owners have set bounds.

Nor does this check judge whether a bound is WELL CHOSEN. It cannot: that
requires the job's measured green duration, which lives in the run history and
not in the file. The reasoning for each bound in codetracer.yml is recorded in a
comment on the job itself.

Contract suite: ci/test/job-timeouts-test.sh
"""

import sys
import pathlib

try:
    import yaml
except ImportError:  # pragma: no cover
    print("job-timeouts: PyYAML is required", file=sys.stderr)
    sys.exit(2)

DEFAULT_WORKFLOWS = [".github/workflows/codetracer.yml"]

# GitHub's own default. A declared bound must be strictly tighter than this,
# or it is not a bound.
GITHUB_DEFAULT_MINUTES = 360


def check_workflow(path):
    """Return (n_jobs_examined, [violation strings])."""
    try:
        doc = yaml.safe_load(pathlib.Path(path).read_text())
    except FileNotFoundError:
        return None, ["%s: no such workflow" % path]
    except yaml.YAMLError as exc:
        return None, ["%s: could not be parsed: %s" % (path, exc)]

    if not isinstance(doc, dict):
        return None, ["%s: not a workflow document" % path]

    jobs = doc.get("jobs")
    if not isinstance(jobs, dict) or not jobs:
        return None, ["%s: declares no jobs" % path]

    violations = []
    examined = 0
    for name, job in jobs.items():
        if not isinstance(job, dict):
            violations.append("%s: %s: job is not a mapping" % (path, name))
            continue
        if "uses" in job:
            # A reusable-workflow call cannot carry `timeout-minutes`; the
            # bound belongs to the jobs inside the called workflow.
            continue
        examined += 1
        if "timeout-minutes" not in job:
            violations.append(
                "%s: %s: no `timeout-minutes`; inherits GitHub's %d-minute "
                "default (runs-on: %s)"
                % (path, name, GITHUB_DEFAULT_MINUTES, job.get("runs-on", "?"))
            )
            continue
        value = job["timeout-minutes"]
        if isinstance(value, bool) or not isinstance(value, int):
            violations.append(
                "%s: %s: `timeout-minutes` must be a literal integer, got %r"
                % (path, name, value)
            )
            continue
        if value < 1:
            violations.append(
                "%s: %s: `timeout-minutes: %d` is not a usable bound"
                % (path, name, value)
            )
            continue
        if value >= GITHUB_DEFAULT_MINUTES:
            violations.append(
                "%s: %s: `timeout-minutes: %d` is not tighter than GitHub's "
                "%d-minute default, so it bounds nothing"
                % (path, name, value, GITHUB_DEFAULT_MINUTES)
            )
    return examined, violations


def main(argv):
    report_only = "--report-only" in argv
    paths = [a for a in argv if not a.startswith("--")] or DEFAULT_WORKFLOWS

    total_examined = 0
    all_violations = []
    for path in paths:
        examined, violations = check_workflow(path)
        all_violations.extend(violations)
        if examined is None:
            if not report_only:
                for v in violations:
                    print("job-timeouts: %s" % v, file=sys.stderr)
                return 2
            continue
        total_examined += examined

    if total_examined == 0 and not report_only:
        print("job-timeouts: examined no jobs", file=sys.stderr)
        return 2

    if all_violations:
        print(
            "job-timeouts: %d job(s) without a usable `timeout-minutes` "
            "(of %d examined):" % (len(all_violations), total_examined),
            file=sys.stderr,
        )
        for v in sorted(all_violations):
            print("  %s" % v, file=sys.stderr)
        if report_only:
            return 0
        print(
            "\nAn unbounded job inherits a %d-minute ceiling and holds its "
            "runner and its concurrency group for the duration. Give it a "
            "bound derived from its own measured green duration, and record "
            "the measurement in a comment on the job."
            % GITHUB_DEFAULT_MINUTES,
            file=sys.stderr,
        )
        return 1

    print("job-timeouts: %d job(s) bounded, 0 unbounded" % total_examined)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
