#!/usr/bin/env python3
"""late-clone-token-test.py -- a clone after a long step uses a token minted after it.

A GitHub App installation token lives an hour. A job's `Generate CI token`
mints one at the start, and a clone that hands `steps.ci_token.outputs.token`
to clone-repo after a step that can run for most of an hour on a cold runner
(provisioning the lock's siblings, a `nix build`, a `nix develop` or
`build-once`) gets a dead token: test-ui-tests' codetracer-js-recorder clone
in run 43996043232 failed with "Invalid username or token".

So every clone-repo or actions/checkout step that takes a token and comes
after such a step must take it from a `./.github/actions/refresh-github-token`
step placed between the last long step and the clone. Git fetches that use no
explicit token (Nix's, through ci/git-credential-job-netrc.sh) are covered at
run time instead, by ci/test/github-token-freshness-test.sh.

Negative control: with every such clone pointed back at `steps.ci_token`, the
checker must name each of them.

Second rule: a job that registers the git credential helper (every job using
provision-repro-lock-siblings) sets no github.com extraHeader after it. The
registration blanks the job's header, because git sends a header before it
would ask a helper and a header fixed at a step's start outlives its token
(ci/test/git-credential-header-test.sh reproduces that against a local git
server). A later step that set one again would bring the defect back.
Negative control: one such step injected into every helper job is named.
"""

import copy
import pathlib
import re
import sys

import yaml

ROOT = pathlib.Path(__file__).resolve().parents[2]
WORKFLOWS = ROOT / ".github" / "workflows"
LONG_RUN = re.compile(r"\bnix (build|develop)\b|build-once|repro develop")
TOKEN_REF = re.compile(r"steps\.([A-Za-z0-9_-]+)\.outputs\.token")


def is_long(step):
    uses = step.get("uses") or ""
    return "provision-repro-lock-siblings" in uses or bool(LONG_RUN.search(str(step.get("run") or "")))


def token_input(step):
    uses = step.get("uses") or ""
    if "clone-repo" not in uses and "actions/checkout" not in uses:
        return None
    w = step.get("with") or {}
    return w.get("gh-token") or w.get("token")


def defects(workflows):
    found = []
    for name, wf in workflows.items():
        for job_name, job in (wf.get("jobs") or {}).items():
            steps = job.get("steps") or []
            last_long = None
            refreshed_since = set()
            for step in steps:
                if is_long(step):
                    last_long = step.get("name")
                    refreshed_since = set()
                if "refresh-github-token" in (step.get("uses") or "") and step.get("id"):
                    refreshed_since.add(step["id"])
                tok = token_input(step)
                if last_long is None or not tok:
                    continue
                ids = TOKEN_REF.findall(str(tok))
                if not ids or not all(i in refreshed_since for i in ids):
                    found.append(
                        f"{name}: job '{job_name}', step '{step.get('name')}' clones with "
                        f"{tok} after '{last_long}'; mint one with refresh-github-token in between"
                    )
    return found


HEADER = re.compile(r"extraheader", re.IGNORECASE)


def registers_helper(step):
    return "provision-repro-lock-siblings" in (step.get("uses") or "")


def header_defects(workflows):
    found = []
    for name, wf in workflows.items():
        for job_name, job in (wf.get("jobs") or {}).items():
            registered = False
            for step in job.get("steps") or []:
                if registers_helper(step):
                    registered = True
                    continue
                if not registered:
                    continue
                run = "\n".join(
                    line for line in str(step.get("run") or "").splitlines() if not line.lstrip().startswith("#")
                )
                text = yaml.safe_dump({"env": step.get("env"), "with": step.get("with"), "run": run})
                if HEADER.search(text):
                    found.append(
                        f"{name}: job '{job_name}', step '{step.get('name')}' sets an extraHeader "
                        "after the credential helper was registered"
                    )
    return found


def main():
    workflows = {p.name: yaml.safe_load(p.read_text()) for p in sorted(WORKFLOWS.glob("*.yml"))}
    failures = 0

    live = defects(workflows)
    if live:
        failures += 1
        print("  FAIL a clone after a long step uses a token minted before it")
        for d in live:
            print(f"         {d}")
    else:
        print("  ok   every clone after a long step uses a token minted after it")

    # Negative control: point every refreshed late clone back at ci_token.
    reverted = copy.deepcopy(workflows)
    expected = 0
    for wf in reverted.values():
        for job in (wf.get("jobs") or {}).values():
            seen_long = False
            for step in job.get("steps") or []:
                seen_long = seen_long or is_long(step)
                tok = token_input(step)
                if seen_long and tok and "ci_token" not in str(tok):
                    key = "gh-token" if "gh-token" in step["with"] else "token"
                    step["with"][key] = "${{ steps.ci_token.outputs.token }}"
                    expected += 1
    caught = len(defects(reverted))
    if expected == 0:
        failures += 1
        print("  FAIL the negative control found no late clone to revert: the check proves nothing")
    elif caught != expected:
        failures += 1
        print(f"  FAIL with {expected} late clone(s) reverted to the job's first token, the checker named {caught}")
    else:
        print(f"  ok   negative control: all {expected} late clone(s) reverted to the first token are named")

    live = header_defects(workflows)
    if live:
        failures += 1
        print("  FAIL a job that registers the credential helper sets an extraHeader after it")
        for d in live:
            print(f"         {d}")
    else:
        print("  ok   no job that registers the credential helper sets an extraHeader after it")

    injected = copy.deepcopy(workflows)
    jobs = 0
    for wf in injected.values():
        for job in (wf.get("jobs") or {}).values():
            steps = job.get("steps") or []
            for i, step in enumerate(steps):
                if registers_helper(step):
                    steps.insert(i + 1, {
                        "name": "inject a header",
                        "env": {"GIT_CONFIG_KEY_0": "http.https://github.com/metacraft-labs/.extraHeader"},
                        "run": "true",
                    })
                    jobs += 1
                    break
    caught = len(header_defects(injected))
    if jobs == 0:
        failures += 1
        print("  FAIL no job registers the credential helper: the header check proves nothing")
    elif caught != jobs:
        failures += 1
        print(f"  FAIL with a header step injected into {jobs} helper job(s), the checker named {caught}")
    else:
        print(f"  ok   negative control: a header step injected into each of {jobs} helper job(s) is named")

    if failures:
        sys.exit(1)
    print("all checks passed")


if __name__ == "__main__":
    main()
