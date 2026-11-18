#!/usr/bin/env python3
"""Keep release-job credentials out of persistent Git configuration and URLs.

This offline consumer contract reads the actual workflow, including both jobs,
and checks their wiring to the shared setup-nix credential implementation. The
shared action owns functional header scoping and cleanup tests; duplicating its
authentication logic here would give the workflow a second implementation.
Mutation controls run through the same checker and must fail by reason. There
are no mocks: all mutations start from the live workflow's parsed job.
"""

import copy
from pathlib import Path
import re
import unittest

import yaml


WORKFLOW = Path(__file__).resolve().parents[2] / ".github/workflows/codetracer.yml"
TOKEN = "${{ steps.ci_token.outputs.token }}"
SETUP = "metacraft-labs/metacraft-github-actions/setup-nix@"
JOBS = ("push-tag", "create-release")


def auth_errors(job):
    """Check both the unsafe old route and the usable replacement route."""
    errors = []
    steps = job.get("steps", [])
    for step in steps:
        script = "\n".join(line for line in step.get("run", "").splitlines()
                           if not line.lstrip().startswith("#"))
        if "x-access-token:" in script or re.search(r"https://[^\s]+@github\.com", script):
            errors.append("credential-bearing Git URL")
        if TOKEN in script:
            errors.append("installation token interpolated into shell source")

    setups = [step for step in steps if step.get("uses", "").startswith(SETUP)]
    if len(setups) != 1:
        errors.append("missing shared scoped authentication setup")
        return errors
    setup = setups[0]
    if not re.fullmatch(re.escape(SETUP) + r"[0-9a-f]{40}", setup["uses"]):
        errors.append("credential action is not commit-pinned")
    if setup.get("if"):
        errors.append("credential setup is conditional")
    inputs = setup.get("with", {})
    if inputs.get("gh-token") != TOKEN:
        errors.append("missing installation credential")
    if inputs.get("token-owner") != "metacraft-labs" or inputs.get("extra-token-url-prefixes"):
        errors.append("credential scope differs from the owning organization")
    if inputs.get("attic-cache"):
        errors.append("release setup enables cache uploads")
    for key, expected in {
        "trusted-public-keys": "${{ vars.ATTIC_TRUSTED_PUBLIC_KEY }}",
        "attic-token": "${{ secrets.ATTIC_TOKEN }}",
        "substituters": "${{ vars.ATTIC_SUBSTITUTER }}",
    }.items():
        if inputs.get(key) != expected:
            errors.append(f"missing existing cache input {key}")

    checkouts = [step for step in steps if step.get("uses", "").startswith("actions/checkout@")]
    if len(checkouts) != 1:
        errors.append("missing release checkout")
    else:
        checkout = checkouts[0]
        checkout_inputs = checkout.get("with", {})
        if checkout_inputs.get("token") != TOKEN:
            errors.append("checkout lost its installation credential")
        if str(checkout_inputs.get("persist-credentials", True)).lower() != "true":
            errors.append("checkout no longer authenticates the tag push")
        if steps.index(checkout) >= steps.index(setup):
            errors.append("authentication setup precedes checkout")
    return errors


class ReleaseGitAuth(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.jobs = yaml.safe_load(WORKFLOW.read_text())["jobs"]

    def test_release_jobs_use_scoped_job_auth(self):
        for name in JOBS:
            with self.subTest(job=name):
                self.assertIn(name, self.jobs, "the release-job population must not be empty")
                self.assertEqual(auth_errors(self.jobs[name]), [])

    def test_original_global_token_url_is_rejected(self):
        for name in JOBS:
            with self.subTest(job=name):
                job = copy.deepcopy(self.jobs[name])
                job["steps"].append({"run":
                    'git config --global url."https://x-access-token:' + TOKEN +
                    '@github.com/".insteadOf "https://github.com/"'})
                self.assertIn("credential-bearing Git URL", auth_errors(job))

    def test_missing_job_cannot_pass_vacuously(self):
        self.assertIn("missing shared scoped authentication setup", auth_errors({}))

    def test_mutations_of_the_live_auth_wiring_are_rejected(self):
        mutations = (
            ("gh-token", "", "missing installation credential"),
            ("token-owner", "another-org", "credential scope differs from the owning organization"),
            ("extra-token-url-prefixes", "https://github.com/", "credential scope differs from the owning organization"),
            ("attic-cache", "private", "release setup enables cache uploads"),
        )
        for name in JOBS:
            for key, value, error in mutations:
                with self.subTest(job=name, mutation=key):
                    job = copy.deepcopy(self.jobs[name])
                    setups = [step for step in job["steps"] if step.get("uses", "").startswith(SETUP)]
                    self.assertEqual(len(setups), 1, "mutation must target the live setup step")
                    setups[0]["with"][key] = value
                    self.assertIn(error, auth_errors(job))
            with self.subTest(job=name, mutation="persist-credentials"):
                job = copy.deepcopy(self.jobs[name])
                checkout = next(step for step in job["steps"]
                                if step.get("uses", "").startswith("actions/checkout@"))
                checkout["with"]["persist-credentials"] = False
                self.assertIn("checkout no longer authenticates the tag push", auth_errors(job))


if __name__ == "__main__":
    unittest.main(verbosity=2)
