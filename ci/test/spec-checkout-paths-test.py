#!/usr/bin/env python3
"""Exercise the three spec-reading scripts in isolated workspace layouts.

The real scripts and assertion lint run against real files. The Rust population
only supplies the baseline's census floors; its real canary still has to catch
an assertion-less test. No mutation arm or build runs in the user's checkout.
"""

import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest


REPO = Path(__file__).resolve().parents[2]
BASELINE = Path("ci/test/test-assertion-baseline.sh")
UNIT = Path("src/frontend/viewmodel/tests/unit")
HARNESSES = {
    "plat33": (UNIT / "run-plat33-collab-mutations.py",
               "spec/Architecture/Editor-ViewModel.md"),
    "plat68": (UNIT / "run-plat68-keymaps-mutations.py",
               "spec/GUI/CUA-Keymap.md"),
}


class SpecCheckoutPaths(unittest.TestCase):
    def setUp(self):
        self.scratch = tempfile.TemporaryDirectory(prefix="spec-checkout-paths-")
        self.addCleanup(self.scratch.cleanup)
        self.workspace = Path(self.scratch.name)
        self.repo = self.workspace / "codetracer"
        self.specs = self.workspace / "codetracer-pm"
        self.env = dict(os.environ)
        self.env.pop("CT_SPECS_DIR", None)
        self.env["PYTHONDONTWRITEBYTECODE"] = "1"
        self.env["CODETRACER_HOME"] = str(self.workspace / "state")
        for rel in (BASELINE, Path("tools/check-test-assertions.sh"),
                    Path("ci/lib/harness_guard.py"),
                    UNIT / "plat33-collab-mutation-control.sha256",
                    *(value[0] for value in HARNESSES.values())):
            target = self.repo / rel
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(REPO / rel, target)

    def run_command(self, *command):
        return subprocess.run(command, cwd=self.repo, env=self.env,
                              text=True, stdout=subprocess.PIPE,
                              stderr=subprocess.STDOUT, check=False)

    def write(self, path, text):
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text)
        return path

    def prepare_baseline(self, specs):
        target = specs / "tools/check-test-assertions.sh"
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(self.repo / "tools/check-test-assertions.sh", target)
        # The actual lint must read at least 300 files, 200 carrying tests,
        # and 1200 tests. Real Rust source keeps these assertions meaningful.
        population = "\n".join(
            f"#[test]\nfn case_{i}() {{ assert_eq!(1 + 1, 2); }}"
            for i in range(4))
        for index in range(300):
            self.write(self.repo / "src" / f"population_{index}.rs", population)
        (self.repo / "tests").mkdir()
        return target

    def baseline(self):
        return self.run_command("bash", str(BASELINE))

    def test_baseline_default_and_empty_override_compare_canonical_copy(self):
        self.prepare_baseline(self.specs)
        for override in (None, ""):
            with self.subTest(override=override):
                if override is not None:
                    self.env["CT_SPECS_DIR"] = override
                result = self.baseline()
                self.assertEqual(result.returncode, 0, result.stdout)
                self.assertIn("all 8 assertions passed", result.stdout)
                self.assertIn("byte-identical to codetracer-pm", result.stdout)

    def test_baseline_detects_drift_in_default_checkout(self):
        canonical = self.prepare_baseline(self.specs)
        canonical.write_text(canonical.read_text() + "\n# drift\n")
        result = self.baseline()
        self.assertEqual(result.returncode, 1, result.stdout)
        self.assertIn("FAIL vendored copy is byte-identical", result.stdout)

    def test_baseline_missing_canonical_file_fails_by_name(self):
        canonical = self.prepare_baseline(self.specs)
        canonical.unlink()
        result = self.baseline()
        self.assertEqual(result.returncode, 1, result.stdout)
        self.assertIn(str(self.repo / "../codetracer-pm" /
                          "tools/check-test-assertions.sh"), result.stdout)
        self.assertNotIn("not evaluated here", result.stdout)

    def test_baseline_override_with_spaces_is_used_and_required(self):
        override = self.workspace / "custom specs"
        canonical = self.prepare_baseline(override)
        self.env["CT_SPECS_DIR"] = str(override)
        result = self.baseline()
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertIn("byte-identical to codetracer-pm", result.stdout)
        canonical.write_text(canonical.read_text() + "\n# override drift\n")
        result = self.baseline()
        self.assertEqual(result.returncode, 1, result.stdout)
        self.assertIn("FAIL vendored copy is byte-identical", result.stdout)
        canonical.unlink()
        result = self.baseline()
        self.assertEqual(result.returncode, 1, result.stdout)
        self.assertIn(str(canonical), result.stdout)

    def probe_harness(self, harness, document):
        # Import the unmodified harness, then exercise its own resolver and
        # digest reader. runpy avoids executing main(), which mutates sources.
        probe = """
import json, runpy, sys
from pathlib import Path
module = runpy.run_path(sys.argv[1])
if sys.argv[2] == 'plat33':
    inputs = [p for p in module['READ_ONLY_INPUTS'] if p.endswith(sys.argv[3])]
    if len(inputs) != 1:
        raise AssertionError(inputs)
    expected = '../codetracer-pm/' + sys.argv[3]
    if inputs[0] != expected:
        raise AssertionError(inputs)
    recorded = Path(module['CONTROL_HASHES']).read_text().splitlines()
    if not any(line.endswith('  ' + expected) for line in recorded):
        raise AssertionError('canonical spec input has no recorded control digest')
    path = module['resolve_input'](inputs[0])
    digest = module['digest'](inputs[0])
else:
    path = module['path_of']('specs:' + sys.argv[3])
    digest = module['sha']('specs:' + sys.argv[3])
print(json.dumps({'path': str(path.resolve()), 'digest': digest}))
"""
        return self.run_command(sys.executable, "-c", probe,
                                str(HARNESSES[harness][0]), harness, document)

    def test_harness_defaults_overrides_missing_files_and_document_drift(self):
        for name, (_, document) in HARNESSES.items():
            for override in (None, "", str(self.workspace / "custom specs")):
                with self.subTest(harness=name, override=override):
                    if override is None:
                        self.env.pop("CT_SPECS_DIR", None)
                    else:
                        self.env["CT_SPECS_DIR"] = override
                    specs = Path(override) if override else self.specs
                    canonical = self.write(specs / document, "canonical oracle\n")
                    # A stale checkout must never win over the canonical one.
                    self.write(self.workspace / "codetracer-specs" / document,
                               "retired oracle\n")
                    for content in ("canonical oracle\n", "changed oracle\n"):
                        canonical.write_text(content)
                        result = self.probe_harness(name, document)
                        self.assertEqual(result.returncode, 0, result.stdout)
                        actual = json.loads(result.stdout)
                        self.assertEqual(actual["path"], str(canonical))
                        self.assertEqual(actual["digest"], hashlib.sha256(
                            content.encode()).hexdigest())
                    canonical.unlink()
                    result = self.probe_harness(name, document)
                    self.assertNotEqual(result.returncode, 0, result.stdout)
                    self.assertIn(document, result.stdout)
                    self.assertIn(str(specs) if override else
                                  f"codetracer-pm/{document}", result.stdout)

    def test_baseline_lane_provisions_its_required_spec_checkout(self):
        bash_lane = (REPO / "ci/lint/bash.sh").read_text()
        nim_lane = (REPO / "ci/lint/nim.sh").read_text()
        command = "bash ci/test/test-assertion-baseline.sh"
        self.assertNotIn(command, bash_lane)
        self.assertIn(command, nim_lane)
        self.assertIn("python3 ci/test/spec-checkout-paths-test.py", bash_lane)
        workflow = (REPO / ".github/workflows/codetracer.yml").read_text()
        nim_job = workflow.split("\n  lint-nim:\n", 1)[1].split(
            "\n  lint-nix:\n", 1)[0]
        clone, run = nim_job.split("- name: Clone codetracer-pm sibling", 1)[1].split(
            "- run:", 1)
        self.assertIn("repo: metacraft-labs/codetracer-pm", clone)
        self.assertIn("ref: latest", clone)
        self.assertIn("path: ${{ github.workspace }}/../codetracer-pm", clone)
        self.assertIn("gh-token: ${{ steps.ci_token.outputs.token }}", clone)
        self.assertIn("ci/lint/nim.sh", run)


class LaneSpecCheckoutResolution(unittest.TestCase):
    """`ci/lib/spec-checkout.sh`, the lane runner's resolver, and the runner's
    refusal, in scratch workspaces: real git repositories, real files, the
    unmodified scripts. Nothing is mocked."""

    RESOLVER = REPO / "ci/lib/spec-checkout.sh"

    def setUp(self):
        self.scratch = tempfile.TemporaryDirectory(prefix="lane-spec-checkout-")
        self.addCleanup(self.scratch.cleanup)
        self.ws = Path(self.scratch.name) / "ws"
        self.repo = self.ws / "codetracer"
        self.repo.mkdir(parents=True)
        self.git(self.repo, "init", "-q")
        self.env = dict(os.environ)
        self.env.pop("CT_SPECS_DIR", None)
        self.env["TMPDIR"] = str(Path(self.scratch.name) / "tmp")
        Path(self.env["TMPDIR"]).mkdir()

    def git(self, cwd, *args):
        subprocess.run(["git", "-c", "user.name=t", "-c", "user.email=t@t",
                        *args], cwd=cwd, check=True, stdout=subprocess.DEVNULL,
                       stderr=subprocess.DEVNULL)

    def specs_at(self, path, marker):
        (path / "spec").mkdir(parents=True)
        (path / "spec" / "marker").write_text(marker)
        return path

    def resolve(self):
        return subprocess.run(
            ["bash", "-c", 'source "$1"; ct_resolve_specs_dir "$2"', "_",
             str(self.RESOLVER), str(self.repo)],
            env=self.env, text=True, capture_output=True, check=False)

    def manifest(self, path, branch="latest"):
        (self.ws / "repos").mkdir(exist_ok=True)
        (self.ws / "repos" / "codetracer-specs.toml").write_text(
            '[repo]\nname = "codetracer-specs"\npath = "%s"\nbranch = "%s"\n'
            % (path, branch))

    def test_override_is_used_and_never_fallen_through(self):
        self.specs_at(self.ws / "codetracer-pm", "sibling")
        override = self.specs_at(Path(self.scratch.name) / "my specs", "override")
        self.env["CT_SPECS_DIR"] = str(override)
        result = self.resolve()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), str(override))
        self.env["CT_SPECS_DIR"] = str(Path(self.scratch.name) / "absent")
        result = self.resolve()
        self.assertEqual(result.returncode, 1)
        self.assertEqual(result.stdout, "")
        self.assertIn("absent", result.stderr)

    def test_published_sibling_wins_over_manifest_and_retired_name(self):
        self.specs_at(self.ws / "codetracer-specs", "retired")
        self.manifest("codetracer-specs")
        pm = self.specs_at(self.ws / "codetracer-pm", "published")
        result = self.resolve()
        self.assertEqual(result.stdout.strip(), str(pm))

    def test_manifest_path_is_followed(self):
        declared = self.specs_at(self.ws / "elsewhere" / "pm", "declared")
        self.manifest("elsewhere/pm")
        result = self.resolve()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), str(declared))

    def test_manifest_checkout_on_an_old_branch_reads_the_declared_branch(self):
        upstream = self.ws / "upstream"
        self.specs_at(upstream, "latest's oracle")
        self.git(upstream, "init", "-q", "-b", "latest")
        self.git(upstream, "add", "-A")
        self.git(upstream, "commit", "-q", "-m", "pm layout")
        shared = self.ws / "codetracer-specs"
        self.git(self.ws, "clone", "-q", str(upstream), str(shared))
        self.git(shared, "checkout", "-q", "-b", "working")
        self.git(shared, "rm", "-q", "-r", "spec")
        (shared / "Architecture").mkdir()
        (shared / "Architecture" / "old.md").write_text("old layout\n")
        self.git(shared, "add", "-A")
        self.git(shared, "commit", "-q", "-m", "old layout")
        self.manifest("codetracer-specs")
        head = subprocess.run(["git", "rev-parse", "HEAD"], cwd=shared,
                              text=True, capture_output=True).stdout
        result = self.resolve()
        self.assertEqual(result.returncode, 0, result.stderr)
        snap = Path(result.stdout.strip())
        self.assertEqual((snap / "spec" / "marker").read_text(),
                         "latest's oracle")
        self.assertIn("origin/latest", result.stderr)
        # The shared checkout was not moved.
        self.assertEqual(subprocess.run(["git", "rev-parse", "HEAD"], cwd=shared,
                                        text=True, capture_output=True).stdout,
                         head)
        self.assertFalse((shared / "spec").exists())

    def test_nothing_found_names_every_place_tried(self):
        self.manifest("codetracer-specs")
        result = self.resolve()
        self.assertEqual(result.returncode, 1)
        for name in ("codetracer-pm", "codetracer-specs"):
            self.assertIn(str(self.ws / name), result.stderr)

    def test_lane_with_spec_readers_stops_before_compiling(self):
        for rel in ("ci/lib/run-nim-test-lane.sh", "ci/lib/test-lane-files.sh",
                    "ci/lib/test-lane-report.sh", "ci/lib/spec-checkout.sh"):
            target = self.repo / rel
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(REPO / rel, target)
        reader = UNIT / "test_plat68_cua_oracle.nim"
        self.assertIn("spec_documents", (REPO / reader).read_text())
        (self.repo / reader).parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(REPO / reader, self.repo / reader)
        result = subprocess.run(
            ["bash", "ci/lib/run-nim-test-lane.sh", "vm-unit"], cwd=self.repo,
            env=self.env, text=True, stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT, check=False)
        self.assertEqual(result.returncode, 2, result.stdout)
        self.assertIn("suite: " + str(reader), result.stdout)
        self.assertIn("tried: " + str(self.ws / "codetracer-pm"), result.stdout)
        self.assertNotIn("=== vm-unit", result.stdout)


if __name__ == "__main__":
    unittest.main(verbosity=2)
