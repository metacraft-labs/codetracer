"""Exercise the capture transaction with real files and child processes.

Capture cases substitute only the reader: its compiler/rendering is outside
this file lifecycle contract, and it observes actual child-written bytes. The
main-ordering case uses a bounded fixture arm catalog, bypasses its needle scan,
and observes that grading is never called; control parsing and file hashes are
real. Full PLAT54 window arms still use the real capture and reader.
"""
import hashlib
import contextlib
import importlib.util
import io
import json
import os
from pathlib import Path
import shlex
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
RUNNER = ROOT / "src/frontend/tui/tests/run-plat54-agent-activity-mutations.py"
spec = importlib.util.spec_from_file_location("plat54_window_transaction", RUNNER)
harness = importlib.util.module_from_spec(spec)
spec.loader.exec_module(harness)


class WindowTransaction(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        self.report = self.root / harness.RECORD47
        self.report.parent.mkdir(parents=True)
        self.entry = b'{"armed": true, "version": 6}\n'
        self.live = b'{"captured": true, "version": 8}\n'
        self.report.write_bytes(self.entry)
        self.reader_calls = []
        self.repo = patch.object(harness, "REPO", self.root)
        self.cache = patch.object(harness, "NIMCACHE", self.root / "cache")
        self.repo.start()
        self.cache.start()

    def tearDown(self):
        self.cache.stop()
        self.repo.stop()
        self.tmp.cleanup()

    def capture(self, rc=0):
        code = ("from pathlib import Path; import sys; "
                f"Path({str(self.report)!r}).write_bytes({self.live!r}); "
                f"sys.exit({rc})")
        return shlex.join([sys.executable, "-c", code])

    def read(self, suite, selected):
        self.reader_calls.append((suite, selected))
        self.assertEqual(self.report.read_bytes(), self.live)
        return "RED", ["real reader verdict"]

    def run_capture(self, reader=None, rc=0):
        with patch.dict(os.environ, {"PLAT54_WINDOW_CAPTURE": self.capture(rc)}):
            with patch.object(harness, "run_suite", reader or self.read):
                return harness.run_window(harness.WINDOW, "selected case")

    def test_reader_observes_live_bytes_then_entry_is_restored(self):
        self.assertEqual(self.run_capture(), ("RED", ["real reader verdict"]))
        self.assertEqual(self.reader_calls, [(harness.WIN47, "selected case")])
        self.assertEqual(self.report.read_bytes(), self.entry)
        archives = list((self.root / "cache").glob("window-report-*/report.json"))
        self.assertEqual(len(archives), 1)
        self.assertEqual(archives[0].read_bytes(), self.live)
        manifest = json.loads((archives[0].parent / "manifest.json").read_text())
        self.assertEqual(manifest["sha256"], hashlib.sha256(self.live).hexdigest())

    def test_failed_capture_restores_entry_without_reading(self):
        self.assertEqual(self.run_capture(rc=9), ("DID-NOT-COMPILE", []))
        self.assertEqual(self.reader_calls, [])
        self.assertEqual(self.report.read_bytes(), self.entry)

    def test_reader_exception_restores_entry(self):
        def broken_reader(suite, selected):
            self.read(suite, selected)
            raise RuntimeError("reader failed")
        with self.assertRaisesRegex(RuntimeError, "reader failed"):
            self.run_capture(broken_reader)
        self.assertEqual(self.report.read_bytes(), self.entry)

    def test_absent_entry_is_absent_after_capture(self):
        self.report.unlink()
        self.run_capture()
        self.assertFalse(self.report.exists())

    def test_archive_failure_still_restores_entry(self):
        (self.root / "cache").write_text("not a directory")
        with self.assertRaises(FileExistsError):
            self.run_capture()
        self.assertEqual(self.report.read_bytes(), self.entry)

    def test_archive_read_failure_still_restores_entry(self):
        # Inject one file-read failure after the real reader saw live bytes;
        # the following read verifies restoration through the real filesystem.
        read_bytes = Path.read_bytes
        reads = 0
        def fail_archive_read(path):
            nonlocal reads
            if path == self.report:
                reads += 1
                if reads == 3:
                    raise OSError("archive read failed")
            return read_bytes(path)
        with patch.object(Path, "read_bytes", fail_archive_read):
            with self.assertRaisesRegex(OSError, "archive read failed"):
                self.run_capture()
        self.assertEqual(self.report.read_bytes(), self.entry)

    def test_baseline_input_drift_is_refused_before_mutation(self):
        # A one-arm temporary workspace bounds this orchestration test. The
        # real control parser/hashes and main ordering remain in use; only the
        # baseline reader changes an actual controlled file behind the guard.
        suite = "baseline.nim"
        (self.root / suite).write_text("fixture suite")
        control = self.root / "control.sha256"
        control.write_text("".join(
            f"{hashlib.sha256((self.root / rel).read_bytes()).hexdigest()}  {rel}\n"
            for rel in [harness.RECORD47, suite]))
        def changed_baseline(_suite, _filter):
            self.report.write_bytes(self.live)
            return "GREEN", []
        arm = ("FIXTURE", [(harness.RECORD47, "armed", "changed")],
               [(suite, None)], "transaction fixture")
        previous = Path.cwd()
        try:
            with patch.multiple(harness, SUBJECTS=[harness.RECORD47], SUITES=[suite],
                                ARMS=[arm], CONTROL=control, BECAUSE=self.root / "because.json",
                                PTY_SUITES=set(), GPUI_SUITES=set(),
                                DESKTOP_SUITES=set(), WINDOW_SUITES=set()):
                with patch.object(sys, "argv", [str(RUNNER)]), \
                        patch.object(harness, "needle_scan", return_value=True), \
                        patch.object(harness, "run_suite", side_effect=changed_baseline), \
                        patch.object(harness, "grade", return_value=("RED", "fixture")) as grade:
                    output = io.StringIO()
                    with contextlib.redirect_stdout(output):
                        result = harness.main()
                    self.assertEqual(result, 1)
                    self.assertIn("baseline changed controlled inputs", output.getvalue())
                    grade.assert_not_called()
        finally:
            os.chdir(previous)


if __name__ == "__main__":
    unittest.main()
