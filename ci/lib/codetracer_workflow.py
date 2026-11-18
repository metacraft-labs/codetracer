"""codetracer_workflow.py -- codetracer.yml with its local reusable workflows inlined.

NOT-A-CI-GATE: a library, not a check -- the contract suites that read
codetracer.yml import it (ci/test/launcher-suites-build-launcher-test.py,
ci/test/native-recording-suites-run-where-rr-is-test.py, both run by
ci-contract-suites), so their verdicts cover the jobs it inlines.

codetracer.yml reached GitHub's 512,000-byte limit, so some of its jobs live in
reusable workflows of their own (`tui-tests.yml`, `gpui-window-captures.yml`),
called from a stub job:

    tui-tests:
      uses: ./.github/workflows/tui-tests.yml
      secrets: inherit

A contract suite that reads only codetracer.yml would see the stub, find no
steps, and pass vacuously over the very job it is about. `load()` returns the
workflow with each such stub replaced by the called workflow's job of the same
id (falling back to its only job), so a suite sees the jobs as CI runs them.
"""

from pathlib import Path

import yaml

REPO_ROOT = Path(__file__).resolve().parents[2]
WORKFLOW = REPO_ROOT / ".github" / "workflows" / "codetracer.yml"


def inline_called(workflow, workflows_dir):
    """Replace every `uses: ./.github/workflows/<file>` job stub in place."""
    jobs = workflow.get("jobs") or {}
    for job_id, job in list(jobs.items()):
        uses = (job or {}).get("uses") if isinstance(job, dict) else None
        if not isinstance(uses, str) or not uses.startswith("./.github/workflows/"):
            continue
        called = yaml.safe_load((Path(workflows_dir) / Path(uses).name).read_text())
        called_jobs = called.get("jobs") or {}
        if job_id in called_jobs:
            body = called_jobs[job_id]
        elif len(called_jobs) == 1:
            body = next(iter(called_jobs.values()))
        else:
            raise ValueError(f"{uses} has no job `{job_id}` and more than one job")
        merged = dict(body)
        for key in ("needs", "if"):
            if key in job:
                merged[key] = job[key]
        jobs[job_id] = merged
    return workflow


def load(path=WORKFLOW):
    """codetracer.yml (or `path`), with its called local workflows inlined."""
    path = Path(path)
    return inline_called(yaml.safe_load(path.read_text()), path.parent)
