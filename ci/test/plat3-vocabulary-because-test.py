#!/usr/bin/env python3
"""Keep PLAT-3's failure attribution stable without weakening its assertion.

These exercise the real transcript parser. The full mutation harness separately
runs each killer and its behaviour-preserving control against the real compiler.
The grade contract substitutes only the compiler transcript boundary to vary a
gensym counter deterministically; subject patching/restoration uses real files.
"""
import importlib.util
from pathlib import Path
import sys
import unittest
import contextlib
import io
import tempfile
from unittest.mock import patch

REPO = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location(
    "plat3_vocabulary_mutations",
    REPO / "src/frontend/tui/tests/run-plat3-vocabulary-mutations.py")
HARNESS = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = HARNESS
SPEC.loader.exec_module(HARNESS)


class BecauseAssertions(unittest.TestCase):
    def check_text(self, assertion):
        return HARNESS.first_check([
            "test_view_vocabulary_cross_medium.nim(209, 8): Check failed: "
            + assertion])

    def test_compiler_counter_does_not_change_the_assertion(self):
        self.assertEqual(self.check_text('tf`gensym356 == "0"'),
                         self.check_text('tf`gensym364 == "0"'))
        self.assertEqual(self.check_text('tf`gensym364 == "0"'),
                         'Check failed: tf`gensym == "0"')

    def test_different_assertions_remain_different(self):
        original = self.check_text('tf`gensym356 == "0"')
        for assertion in ('wf`gensym364 == "0"', 'tf`gensym364 == "1"',
                          'tf`gensym364 != "0"', 'tf`gensym364 == MarkdownSource'):
            with self.subTest(assertion=assertion):
                self.assertNotEqual(original, self.check_text(assertion))

    def test_quoted_text_and_ordinary_digits_are_preserved(self):
        for assertion in ('text == "tf`gensym356"',
                          r'text == "escaped\" tf`gensym356"',
                          "letter == '`'", 'gensym356 == 1206',
                          'tf`gensym356extra == 0'):
            with self.subTest(assertion=assertion):
                self.assertEqual(self.check_text(assertion),
                                 'Check failed: ' + assertion)

    def test_multiple_generated_identifiers_keep_their_names(self):
        self.assertEqual(self.check_text('tf`gensym12 == wf`gensym99'),
                         'Check failed: tf`gensym == wf`gensym')

    def grade_transcript(self, assertion):
        with tempfile.TemporaryDirectory(prefix="plat3-because-") as scratch:
            root = Path(scratch)
            (root / "subject.nim").write_text("original\n")
            arm = HARNESS.Arm("T1", "subject.nim", "original", "mutated",
                              "suite.nim", "killer", "original", "control", "")
            failed = "Check failed: " + assertion + "\n[FAILED] killer\n"
            with patch.object(HARNESS, "REPO", root), \
                    patch.object(HARNESS, "load_because", return_value={
                        "T1": 'Check failed: tf`gensym == "0"'}), \
                    patch.object(HARNESS, "run_suite", side_effect=[
                        (1, failed), (0, "[OK] killer\n")]) as run_suite, \
                    contextlib.redirect_stdout(io.StringIO()) as output:
                rc = HARNESS.grade([arm])
            self.assertEqual((root / "subject.nim").read_text(), "original\n")
            return rc, output.getvalue(), run_suite.call_count

    def test_grade_matches_counter_drift_and_runs_control(self):
        rc, output, calls = self.grade_transcript('tf`gensym364 == "0"')
        self.assertEqual(rc, 0, output)
        self.assertIn("1 of 1 KILLED", output)
        self.assertEqual(calls, 2)

    def test_grade_rejects_a_different_assertion(self):
        for assertion in ('wf`gensym364 == "0"', 'tf`gensym364 == "1"',
                          'tf`gensym364 != "0"',
                          'text == "tf`gensym364 == \\"0\\""'):
            with self.subTest(assertion=assertion):
                rc, output, calls = self.grade_transcript(assertion)
                self.assertEqual(rc, 1, output)
                self.assertIn("MIS-ATTRIBUTED", output)
                self.assertEqual(calls, 1)


if __name__ == "__main__":
    unittest.main()
