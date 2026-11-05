#!/usr/bin/env python3
"""Exercise the real Problems mutation harness's transcript parser.

Transcripts are parser inputs, not substituted compiler or terminal adapters.
The full mutation run separately verifies L2 against the real terminal suite.
Reference/lifecycle cases use temporary REPO/NIMCACHE paths and a bounded file
catalog to isolate real files. Needle scanning is replaced only for that tiny
catalog; the real writer, SHA reader and controls guard remain in use. A real
Python child selected through PLAT55_DESKTOP_TEST substitutes Playwright output
only at the orchestration boundary, writing its live answer before returning;
full default G/P suites retain the real product oracle. A capture wrapper raises
a deterministic exception after that real child, and one archive mkdir failure
models a portable OS error without relying on host permissions. The bounded
main test supplies one real subject/suite, skips unrelated needle validation,
and uses run_suite/grade spies solely to prove baseline drift prevents mutation;
it never supplies a product verdict or substitutes hashing/file restoration.
The stream-order case substitutes only compiler-output generation: the actual
Python interpreter runs a temporary file named `c` with the harness's normal
arguments, flushing stderr before stdout. Temporary REPO/NIMCACHE settings
isolate files, and PLAT55_NIM selects that real child. The child launch and transcript parser execute unchanged; the real PTY
proofs use Nim.
"""
import contextlib
import hashlib
import io
import json
import os
import shlex
import importlib.util
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

REPO = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location(
    "plat55_problems_mutations",
    REPO / "src/frontend/tui/tests/run-plat55-problems-mutations.py")
HARNESS = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = HARNESS
SPEC.loader.exec_module(HARNESS)


class BecauseAssertions(unittest.TestCase):
    def test_earlier_exception_precedes_later_count_check(self):
        self.assertEqual(HARNESS.output_order_failures(
            "Unhandled exception: never showed 'Total: 3'; screen: old frame\n"
            "[FAILED] terminal draws the report\n"
            "Check failed: countedAssertions == ExpectedAssertions\n"),
            ["never showed 'Total: 3'", "countedAssertions == ExpectedAssertions"])

    def test_earlier_check_precedes_later_exception(self):
        self.assertEqual(HARNESS.output_order_failures(
            "test.nim(20, 7): Check failed: screen.listRows > 0\n"
            "Unhandled exception: never showed 'Total: 3'; screen: old frame\n"),
            ["screen.listRows > 0", "never showed 'Total: 3'"])

    def test_status_snapshot_is_removed_but_exception_type_is_kept(self):
        self.assertEqual(HARNESS.output_order_failures(
            "Unhandled exception: never showed 'Total: 3'; status: "
            "exited, screen: old frame [AssertionDefect]\n"),
            ["never showed 'Total: 3' [AssertionDefect]"])

    def test_unrelated_output_does_not_create_a_cause(self):
        self.assertEqual(HARNESS.output_order_failures(
            "[Suite] Problems\n[OK] displays report\n"), [])

    def test_real_child_stderr_failure_precedes_stdout_count(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / "c").write_text(
                "import sys\n"
                "sys.stderr.write(\"Unhandled exception: never showed 'Total: 3'; screen: frame\\n\")\n"
                "sys.stderr.flush()\n"
                "sys.stdout.write('Check failed: countedAssertions == ExpectedAssertions\\n')\n"
                "sys.stdout.flush()\n"
                "sys.exit(1)\n")
            with patch.object(HARNESS, "REPO", root), \
                    patch.object(HARNESS, "NIMCACHE", root / "cache"), \
                    patch.dict("os.environ", {"PLAT55_NIM": sys.executable}):
                verdict, failures = HARNESS.run_suite("stream-fixture.nim", None)
            self.assertEqual(verdict, "RED")
            self.assertEqual(failures, ["never showed 'Total: 3'",
                                        "countedAssertions == ExpectedAssertions"])


class ReferenceLifecycle(unittest.TestCase):
    def test_required_reference_is_recorded_and_changes_refuse(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            for name in ["subject.nim", "suite.nim", "answer.json"]:
                (root / name).write_text(name)
            control = root / "control"
            control.write_text("".join(
                f"{hashlib.sha256((root / name).read_bytes()).hexdigest()}  {name}\n"
                for name in ["subject.nim", "suite.nim"]))
            with patch.object(HARNESS, "REPO", root), \
                    patch.object(HARNESS, "CONTROL", control), \
                    patch.object(HARNESS, "SUBJECTS", ["subject.nim"]), \
                    patch.object(HARNESS, "SUITES", ["suite.nim"]), \
                    patch.object(HARNESS, "DESKTOP_ANSWERS", {"fixture": "answer.json"}, create=True), \
                    patch.object(HARNESS, "needle_scan", return_value=True), \
                    contextlib.redirect_stdout(io.StringIO()):
                self.assertFalse(HARNESS.controls_match())
                self.assertEqual(HARNESS.record_controls(), 0)
                self.assertEqual(len([x for x in control.read_text().splitlines()
                                      if x and not x.startswith("#")]), 3)
                self.assertTrue(HARNESS.controls_match())
                (root / "answer.json").write_text("changed")
                self.assertFalse(HARNESS.controls_match())

    def check_capture(self, rc=0, absent=False, capture_error=False, archive_error=False):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            answer = root / "answer.json"
            entry = b'{"entry": true}\n'
            if not absent:
                answer.write_bytes(entry)
            child = root / "capture.py"
            child.write_text("from pathlib import Path\nimport sys\n"
                             f"Path({str(answer)!r}).write_bytes(b'live answer')\n"
                             f"print({'1 passed' if rc == 0 else 'Error: child failure'!r})\n"
                             f"sys.exit({rc})\n")
            actual_capture = getattr(HARNESS, "run_spec_capture", HARNESS.run_spec)
            def after_capture(suite):
                result = actual_capture(suite)
                if capture_error:
                    raise RuntimeError("after real child")
                return result
            actual_mkdir = Path.mkdir
            def archive_mkdir(path, *args, **kwargs):
                if path == root / "cache":
                    raise OSError("archive unavailable")
                return actual_mkdir(path, *args, **kwargs)
            with patch.object(HARNESS, "REPO", root), \
                    patch.object(HARNESS, "NIMCACHE", root / "cache"), \
                    patch.object(HARNESS, "DESKTOP_ANSWERS", {HARNESS.SPEC: "answer.json"}, create=True), \
                    patch.dict(os.environ, {"PLAT55_DESKTOP_TEST": shlex.join([sys.executable, str(child)])}), \
                    patch.object(HARNESS, "run_spec_capture", side_effect=after_capture, create=True), \
                    patch.object(Path, "mkdir", archive_mkdir if archive_error else actual_mkdir):
                if capture_error or archive_error:
                    with self.assertRaises(RuntimeError if capture_error else OSError):
                        HARNESS.run_spec(HARNESS.SPEC)
                else:
                    verdict = HARNESS.run_spec(HARNESS.SPEC)
                    self.assertEqual(verdict, ("GREEN", []) if rc == 0 else ("RED", ["Error: child failure"]))
            self.assertEqual(answer.read_bytes() if answer.exists() else None,
                             None if absent else entry)
            if not archive_error:
                archives = list((root / "cache").glob("desktop-answer-*/answer.json"))
                self.assertEqual(len(archives), 1)
                self.assertEqual(archives[0].read_bytes(), b"live answer")
                manifest = json.loads((archives[0].parent / "manifest.json").read_text())
                self.assertEqual(manifest["sha256"], hashlib.sha256(b"live answer").hexdigest())

    def test_success_restores_entry(self):
        self.check_capture()

    def test_red_restores_entry(self):
        self.check_capture(rc=1)

    def test_absent_entry_stays_absent(self):
        self.check_capture(absent=True)

    def test_capture_exception_restores_entry(self):
        self.check_capture(capture_error=True)

    def test_archive_failure_restores_entry(self):
        self.check_capture(archive_error=True)

    def test_baseline_drift_refuses_before_mutation(self):
        old_cwd = Path.cwd()
        try:
            with tempfile.TemporaryDirectory() as tmp:
                root = Path(tmp)
                (root / "subject.nim").write_text("healthy\n")
                (root / "suite.nim").write_text("suite\n")
                (root / "answer.json").write_text("entry\n")
                arms = [("FIXTURE", [("subject.nim", "healthy\n", "fault\n")],
                         [("suite.nim", None)], "bounded orchestration")]
                def baseline(*args):
                    (root / "answer.json").write_text("drift\n")
                    return "GREEN", []
                with patch.object(HARNESS, "REPO", root), \
                        patch.object(HARNESS, "CONTROL", root / "control"), \
                        patch.object(HARNESS, "SUBJECTS", ["subject.nim"]), \
                        patch.object(HARNESS, "SUITES", ["suite.nim"]), \
                        patch.object(HARNESS, "DESKTOP_ANSWERS", {"fixture": "answer.json"}, create=True), \
                        patch.object(HARNESS, "ARMS", arms), \
                        patch.object(HARNESS, "needle_scan", return_value=True), \
                        patch.object(HARNESS, "run_suite", side_effect=baseline), \
                        patch.object(HARNESS, "grade", return_value=("RED", "bounded cause")) as grade, \
                        patch.object(sys, "argv", ["harness"]), \
                        contextlib.redirect_stdout(io.StringIO()):
                    self.assertEqual(HARNESS.record_controls(), 0)
                    self.assertEqual(HARNESS.main(), 1)
                    grade.assert_not_called()
                self.assertEqual((root / "subject.nim").read_text(), "healthy\n")
        finally:
            os.chdir(old_cwd)


if __name__ == "__main__":
    unittest.main()
