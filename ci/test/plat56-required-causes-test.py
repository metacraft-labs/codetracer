"""Default grading must require measured causes before doing any work.

A temporary REPO contains real source/control/cause files. A bounded fixture
arm catalog avoids running the UI product; needle validation is substituted
because this tests orchestration, while real control parsing/hashing and
source restoration remain active. Baseline/grade spies return declared fixture
results and expose whether grading ran before missing metadata was rejected.
Reference-input cases bound the source/reference catalog and needle check,
while exercising the real control writer, parser and hashes on actual files.
Ordering cases isolate compiler-output generation with a real Python child
named `c`; only REPO/NIMCACHE and PLAT56_NIM settings are substituted, never
subprocess or the parser. Desktop lifecycle cases similarly use a real child
as the Playwright-output boundary with a bounded answer-path catalog, not as
evidence about UI rendering; full
derivation uses actual Electron assertions. All file writes are temporary.
"""
import contextlib
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import sys
import tempfile
import shlex
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location(
    "plat56_required_causes", ROOT / "src/frontend/tui/tests/run-plat56-build-output-mutations.py")
harness = importlib.util.module_from_spec(spec)
spec.loader.exec_module(harness)


class RequiredCauses(unittest.TestCase):
    def run_fixture(self, content=None, survivor=False, derive=False, grade_result=None):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / "subject.nim").write_text("original")
            (root / "suite.nim").write_text("fixture suite")
            control = root / "control"
            control.write_text("".join(
                f"{hashlib.sha256((root / p).read_bytes()).hexdigest()}  {p}\n"
                for p in ["subject.nim", "suite.nim"]))
            because = root / "because.json"
            if content is not None:
                because.write_text(content)
            name = "Z1" if survivor else "FIXTURE"
            arm = (name, [("subject.nim", "original", "changed")],
                   [("suite.nim", None)], "bounded fixture")
            previous = Path.cwd()
            try:
                with patch.multiple(harness, REPO=root, CONTROL=control, BECAUSE=because,
                                    SUBJECTS=["subject.nim"], SUITES=["suite.nim"], ARMS=[arm],
                                    DESKTOP_ANSWERS={},
                                    PTY_SUITES=set(), GPUI_SUITES=set(), DESKTOP_SUITES=set()):
                    with patch.object(sys, "argv", ["fixture"] + (["--derive"] if derive else [])), \
                            patch.object(harness, "needle_scan", return_value=True), \
                            patch.object(harness, "run_suite", return_value=("GREEN", [])) as baseline, \
                            patch.object(harness, "grade", return_value=grade_result or (("GREEN", "") if survivor else ("RED", "fixture failure"))) as grade:
                        output = io.StringIO()
                        with contextlib.redirect_stdout(output):
                            rc = harness.main()
                        self.assertEqual((root / "subject.nim").read_text(), "original")
                        self.last_cause_text = because.read_text() if because.exists() else None
                        try:
                            self.last_causes = json.loads(self.last_cause_text) if self.last_cause_text is not None else None
                        except ValueError:
                            self.last_causes = None
                        return rc, baseline.call_count, grade.call_count, output.getvalue()
            finally:
                os.chdir(previous)

    def assert_refused(self, content):
        rc, baseline, grade, output = self.run_fixture(content)
        self.assertEqual(rc, 3, output)
        self.assertEqual((baseline, grade), (0, 0), output)
        self.assertIn("CAUSE", output)
        self.assertEqual(self.last_cause_text, content)

    def test_missing_file_refused(self):
        self.assert_refused(None)

    def test_empty_map_refused(self):
        self.assert_refused("{}")

    def test_empty_cause_refused(self):
        self.assert_refused(json.dumps({"FIXTURE": ""}))

    def test_nonstring_cause_refused(self):
        self.assert_refused(json.dumps({"FIXTURE": 7}))

    def test_malformed_json_refused(self):
        self.assert_refused("{")

    def test_nonobject_map_refused(self):
        self.assert_refused("[]")

    def test_valid_measured_cause_allows_real_restore(self):
        rc, baseline, grade, _ = self.run_fixture(json.dumps({"FIXTURE": "fixture failure"}))
        self.assertEqual((rc, baseline, grade), (0, 1, 1))

    def test_declared_survivor_needs_no_invented_failure(self):
        rc, baseline, grade, _ = self.run_fixture(survivor=True)
        self.assertEqual((rc, baseline, grade), (0, 1, 1))

    def test_empty_derive_failure_does_not_replace_measured_pin(self):
        measured = {"FIXTURE": "fixture failure"}
        rc, _, _, _ = self.run_fixture(json.dumps(measured), derive=True, grade_result=("RED", ""))
        self.assertEqual(rc, 1)
        self.assertEqual(self.last_causes, measured)


class CaptureBoundaries(unittest.TestCase):
    def test_same_channel_exception_before_count(self):
        self.check_order("stdout")

    def test_stderr_exception_before_stdout_count(self):
        self.check_order("stderr")

    def check_order(self, first_stream):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / "c").write_text(
                "import sys\n"
                f"sys.{first_stream}.write(\"Unhandled exception: never showed 'opened src/main.c:5:17'; screen: frame\\n\")\n"
                f"sys.{first_stream}.flush()\n"
                "sys.stdout.write('Check failed: countedAssertions == ExpectedAssertions\\n')\n"
                "sys.stdout.flush()\n"
                "sys.exit(1)\n")
            with patch.object(harness, "REPO", root), \
                    patch.object(harness, "NIMCACHE", root / "cache"), \
                    patch.dict(os.environ, {"PLAT56_NIM": sys.executable}):
                result = harness.run_suite("stream-fixture.nim", None)
            self.assertEqual(result, ("RED", ["never showed 'opened src/main.c:5:17'",
                                              "countedAssertions == ExpectedAssertions"]))

    def test_desktop_answer_restored_after_success(self):
        self.check_desktop(0)

    def test_desktop_answer_restored_after_failure(self):
        self.check_desktop(1)

    def test_absent_desktop_entry_remains_absent(self):
        self.check_desktop(0, absent=True)

    def test_typed_desktop_timeout_is_a_concrete_cause(self):
        self.check_desktop(1, timeout=True)

    def check_desktop(self, rc, absent=False, timeout=False):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            rel = "answer.json"
            answer = root / rel
            entry = b'{"entry": true}\n'
            if not absent:
                answer.write_bytes(entry)
            child = root / "capture.py"
            failure = "TimeoutError: locator.click: Timeout 30000ms exceeded." if timeout else "Error: real child failure"
            child.write_text("from pathlib import Path\nimport sys\n"
                             f"Path({str(answer)!r}).write_bytes(b'live answer')\n"
                             f"print({'1 passed' if rc == 0 else failure!r})\n"
                             f"sys.exit({rc})\n")
            with patch.object(harness, "REPO", root), \
                    patch.object(harness, "NIMCACHE", root / "cache"), \
                    patch.object(harness, "DESKTOP_ANSWERS", {harness.SPEC: rel}, create=True), \
                    patch.dict(os.environ, {"PLAT56_DESKTOP_TEST": shlex.join([sys.executable, str(child)])}):
                result = harness.run_spec(harness.SPEC)
            self.assertEqual(result[0], "GREEN" if rc == 0 else "RED")
            if rc:
                self.assertEqual(result[1], [failure])
            archives = list((root / "cache").glob("desktop-answer-*/answer.json"))
            self.assertEqual(len(archives), 1)
            self.assertEqual(archives[0].read_bytes(), b"live answer")
            manifest = json.loads((archives[0].parent / "manifest.json").read_text())
            self.assertEqual(manifest["sha256"], hashlib.sha256(b"live answer").hexdigest())
            if absent:
                self.assertFalse(answer.exists())
            else:
                self.assertEqual(answer.read_bytes(), entry)


class ReferenceInputs(unittest.TestCase):
    def test_reference_omission_recording_and_changes(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            files = ["subject.nim", "suite.nim", "left.json", "right.json"]
            for name in files:
                (root / name).write_text(name)
            control = root / "control"
            control.write_text("".join(
                f"{hashlib.sha256((root / p).read_bytes()).hexdigest()}  {p}\n"
                for p in files[:2]))
            with patch.object(harness, "REPO", root), \
                    patch.object(harness, "CONTROL", control), \
                    patch.object(harness, "SUBJECTS", files[:1]), \
                    patch.object(harness, "SUITES", files[1:2]), \
                    patch.object(harness, "DESKTOP_ANSWERS", {"left": files[2], "right": files[3]}, create=True), \
                    patch.object(harness, "needle_scan", return_value=True):
                output = io.StringIO()
                with contextlib.redirect_stdout(output):
                    self.assertFalse(harness.controls_match())
                    self.assertEqual(harness.record_controls(), 0)
                    self.assertTrue(harness.controls_match())
                    recorded = {line.split("  ", 1)[1] for line in control.read_text().splitlines()
                                if line and not line.startswith("#")}
                    self.assertEqual(recorded, set(files))
                    for name in files[2:]:
                        (root / name).write_text("changed reference")
                        self.assertFalse(harness.controls_match())
                        (root / name).write_text(name)
                        self.assertTrue(harness.controls_match())


if __name__ == "__main__":
    unittest.main()
