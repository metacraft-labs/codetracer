#!/usr/bin/env python3
"""inline-codetracer-workflow.py -- codetracer.yml as TEXT, with its called jobs inlined.

NOT-A-CI-GATE: a library for the contract suites that read codetracer.yml
line by line (awk, grep). ci/lib/codetracer_workflow.py does the same for the
ones that parse YAML.

Several of codetracer.yml's jobs live in reusable workflows of their own, to
keep the file under GitHub's 512,000-byte limit; codetracer.yml keeps a stub
job of the same id:

    windows-headless-test:
      needs:
        - windows-rust-components
      permissions: ...
      uses: ./.github/workflows/windows-headless-test.yml
      secrets: inherit

A suite that reads only codetracer.yml would see the stub, find no steps, and
pass vacuously over the job it is about. This prints codetracer.yml with each
stub replaced by the called workflow's job of the same id, comments and all,
plus the stub's `needs:` and `if:`, so a suite sees the jobs as CI runs them.

Usage: inline-codetracer-workflow.py [codetracer.yml] > inlined.yml
"""

import re
import sys
from pathlib import Path

KEY = re.compile(r"^  ([A-Za-z0-9_-]+):$")


def job_blocks(lines):
    """[(job_id, first_line, end_line)] for the 2-space keys under `jobs:`."""
    try:
        start = lines.index("jobs:")
    except ValueError:
        return []
    keys = [(i, KEY.match(line).group(1)) for i, line in enumerate(lines) if i > start and KEY.match(line)]
    out = []
    for n, (i, job) in enumerate(keys):
        end = keys[n + 1][0] if n + 1 < len(keys) else len(lines)
        out.append((job, i, end))
    return out


def called_job(path, job):
    lines = path.read_text().split("\n")
    blocks = job_blocks(lines)
    match = [b for b in blocks if b[0] == job] or (blocks if len(blocks) == 1 else [])
    if not match:
        raise SystemExit(f"{path} has no job `{job}`")
    _, first, end = match[0]
    return lines[first + 1:end]


def inline(path):
    path = Path(path)
    lines = path.read_text().split("\n")
    out = list(lines)
    for job, first, end in reversed(job_blocks(lines)):
        body = lines[first + 1:end]
        uses = [m.group(1) for m in (re.match(r"^    uses: \./\.github/workflows/(\S+)$", l) for l in body) if m]
        if not uses:
            continue
        # The stub's `needs:` (with a block list's `      - ` lines) and `if:`.
        keep = []
        for n, line in enumerate(body):
            if line.startswith("    needs:") or line.startswith("    if:"):
                keep.append(line)
                m = n + 1
                while m < len(body) and body[m].startswith("      - "):
                    keep.append(body[m])
                    m += 1
        callee = called_job(path.parent / uses[0], job)
        if any(k.startswith("    if:") for k in keep):
            callee = [l for l in callee if not l.startswith("    if:")]
        out[first + 1:end] = keep + callee
    return "\n".join(out)


if __name__ == "__main__":
    default = Path(__file__).resolve().parents[2] / ".github" / "workflows" / "codetracer.yml"
    sys.stdout.write(inline(sys.argv[1] if len(sys.argv) > 1 else default))
