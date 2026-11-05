#!/usr/bin/env python3
"""Exercise the real Problems mutation harness's transcript parser.

Transcripts are parser inputs, not substituted compiler or terminal adapters.
The full mutation run separately verifies L2 against the real terminal suite.
The stream-order case substitutes only compiler-output generation: the actual
Python interpreter runs a temporary file named `c` with the harness's normal
arguments, flushing stderr before stdout. Temporary REPO/NIMCACHE settings
isolate files, and PLAT55_NIM selects that real child. Neither subprocess nor
the capture/parser implementation is mocked; the real PTY proofs use Nim.
"""
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


if __name__ == "__main__":
    unittest.main()
