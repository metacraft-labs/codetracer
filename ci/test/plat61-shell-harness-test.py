#!/usr/bin/env python3
"""Check the Shell capture launcher's status and mutation-input boundaries.

Temporary directories isolate actual files and child processes. The launcher
runs unchanged real Bash. A dirname function forwards the real utility except
for one deliberately failed CT path lookup: this deterministic exit7 models
command-substitution failure without unreliable host permission tricks. Tiny
ct/just executables stand in only for recording and UI launch, so the test can
observe PATH/exit/dispatch without fabricating a recording or a product oracle.
The separate run_spec dispatch fixture is a real Bash child with a known
transcript; it checks selection/restoration only, while full57 grades use the
real capture. Controller fixtures bound SUBJECTS/SUITES/ARMS to real temporary
files and replace build_binary with a stopping spy, proving rejection before
build without compiling Nim or inventing baseline/mutant verdicts. Hashing,
control writing, needle scanning, argument parsing and subprocesses stay real.
The full-input writer case reads the real production files and redirects only
CONTROL to a temporary file, so this observation cannot certify the landing
manifest before a complete grade. Stream-order cases replace only compiler-output
production with a real Python child behind a temporary nim executable: real
subprocess capture and the real collector must preserve its flushed OS writes.
The full four-fault proof separately compiles/runs actual GPUI and PTY suites;
these boundary fixtures neither simulate those products nor replace their oracle.
Soft-wait cases use the actual TBL checkpoint grammar; generic budget text is
parser input only and must not manufacture a product failure.
"""
import contextlib
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import shutil
import shlex
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

REPO = Path(__file__).resolve().parents[2]
RUNNER = REPO / "src/frontend/tui/tests/run-plat61-shell-mutations.py"
SPEC = importlib.util.spec_from_file_location("plat61_owner_unit", RUNNER)
H = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = H
SPEC.loader.exec_module(H)
BASH = shutil.which("bash")
DIRNAME = shutil.which("dirname")


class CapturePath(unittest.TestCase):
    def check_launcher(self, fail=False):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            tools = root / "tools"
            tools.mkdir()
            ct = tools / "ct"
            ct.write_text(f"#!{BASH}\nset -eu\nprintf 'called\\n' >>\"$TEST_CT_LOG\"\nmkdir -p \"$3\"\n")
            just = tools / "just"
            just.write_text(f"#!{BASH}\nset -eu\nprintf '%s' \"$PATH\" >\"$TEST_PATH_LOG\"\nprintf '%s' \"$*\" >\"$TEST_JUST_LOG\"\n")
            ct.chmod(0o755)
            just.chmod(0o755)
            path = str(tools) + os.pathsep + os.environ["PATH"]
            env = dict(os.environ, PATH=path, CT_BIN=str(ct), DISPLAY=":provided",
                       TEST_CT=str(ct), TEST_REAL_DIRNAME=DIRNAME,
                       TEST_CT_LOG=str(root / "ct.log"),
                       TEST_PATH_LOG=str(root / "path.log"),
                       TEST_JUST_LOG=str(root / "just.log"))
            env["TEST_FAIL_DIRNAME"] = "1" if fail else "0"
            driver = ('dirname() { if [[ "$TEST_FAIL_DIRNAME" == 1 && "$1" == "$TEST_CT" ]]; '
                      'then return 7; fi; "$TEST_REAL_DIRNAME" "$@"; }; '
                      'export -f dirname; exec "$1" "$2"')
            p = subprocess.run([BASH, "-c", driver, "launcher-proof", BASH,
                                str(REPO / "scripts/plat61-capture-electron.sh")],
                               env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            self.assertEqual((root / "ct.log").read_text(), "called\n")
            if fail:
                self.assertEqual(p.returncode, 7, p.stderr.decode())
                self.assertFalse((root / "just.log").exists())
            else:
                self.assertEqual(p.returncode, 0, p.stderr.decode())
                self.assertEqual((root / "path.log").read_text(), str(tools) + os.pathsep + path)
                self.assertEqual((root / "just.log").read_text(),
                                 "test-e2e tests/shell/plat61-shell-capture.spec.ts")

    def test_real_dirname_preserves_healthy_path(self):
        self.check_launcher()

    def test_failed_path_lookup_stops_before_ui_launch(self):
        self.check_launcher(fail=True)


class ControllerInputs(unittest.TestCase):
    @contextlib.contextmanager
    def fixture(self, cause=None, survivor=False):
        old_cwd = Path.cwd()
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            files = ["subject.nim", "suite.nim", "capture.sh"]
            for name in files:
                (root / name).write_text("healthy\n" if name == files[0] else name + "\n")
            control = root / "control"
            control.write_text("".join(f"{hashlib.sha256((root / f).read_bytes()).hexdigest()}  {f}\n"
                                       for f in files[:2]))
            because = root / "because.json"
            if cause is not None:
                because.write_text(cause)
            arms = [("FIXTURE", [(files[0], "healthy\n", "fault\n")],
                     [(files[1], None)], "bounded guard test")]
            try:
                with patch.object(H, "REPO", root), patch.object(H, "CONTROL", control), \
                        patch.object(H, "BECAUSE", because), patch.object(H, "ARMS", arms), \
                        patch.object(H, "SUBJECTS", files[:1]), \
                        patch.object(H, "SUITES", files[1:]), \
                        patch.object(H, "CAPTURE", files[2], create=True), \
                        patch.object(H, "PTY_SUITES", {files[1]}), \
                        patch.object(H, "DECLARED_SURVIVORS", {"FIXTURE"} if survivor else set()), \
                        patch.object(sys, "argv", ["harness", "--only=FIXTURE"]), \
                        contextlib.redirect_stdout(io.StringIO()):
                    yield root, control
            finally:
                os.chdir(old_cwd)

    def test_actual_writer_seals_all_28_real_inputs(self):
        with tempfile.TemporaryDirectory() as tmp:
            control = Path(tmp) / "observed-control"
            with patch.object(H, "CONTROL", control), contextlib.redirect_stdout(io.StringIO()):
                self.assertEqual(H.record_controls(), 0)
                self.assertTrue(H.controls_match())
            rows = {line.split("  ", 1)[1]: line.split("  ", 1)[0]
                    for line in control.read_text().splitlines()
                    if line and not line.startswith("#")}
            self.assertEqual(len(rows), 28)
            rel = "scripts/plat61-capture-electron.sh"
            self.assertEqual(rows[rel], hashlib.sha256((REPO / rel).read_bytes()).hexdigest())

    def test_actual_capture_wrapper_is_a_declared_input(self):
        self.assertIn("scripts/plat61-capture-electron.sh", H.SUITES)

    def test_missing_consumed_wrapper_row_refuses(self):
        with self.fixture() as (_, control):
            self.assertFalse(H.controls_match())

    def test_real_writer_includes_wrapper_and_changed_bytes_refuse(self):
        with self.fixture() as (root, control):
            self.assertEqual(H.record_controls(), 0)
            rows = [x for x in control.read_text().splitlines() if x and not x.startswith("#")]
            self.assertEqual(len(rows), 3)
            self.assertTrue(H.controls_match())
            (root / "capture.sh").write_text("changed\n")
            self.assertFalse(H.controls_match())

    def test_selected_fault_requires_nonempty_measured_cause_before_build(self):
        for cause in [None, "{}", '{"FIXTURE": null}', '{"FIXTURE": " "}',
                      '{"FIXTURE": 1}', "[]", "{malformed"]:
            with self.subTest(cause=cause), self.fixture(cause) as (_, _control):
                self.assertEqual(H.record_controls(), 0)
                with patch.object(H, "build_binary", return_value=False) as build:
                    self.assertEqual(H.main(), 3)
                    build.assert_not_called()

    def test_valid_cause_reaches_real_build_boundary(self):
        with self.fixture('{"FIXTURE": "measured failure"}') as (_, _control):
            self.assertEqual(H.record_controls(), 0)
            with patch.object(H, "build_binary", return_value=False) as build:
                self.assertEqual(H.main(), 1)
                build.assert_called_once_with()

    def test_declared_survivor_needs_no_fault_cause(self):
        with self.fixture(survivor=True) as (_, _control):
            self.assertEqual(H.record_controls(), 0)
            with patch.object(H, "build_binary", return_value=False) as build:
                self.assertEqual(H.main(), 1)
                build.assert_called_once_with()

    def test_capture_constant_dispatches_real_child_and_restores_reference(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            answer = root / "answer.json"
            answer.write_bytes(b"entry")
            wrapper = root / "capture.sh"
            wrapper.write_text("printf live >answer.json\nprintf '1 passed\\n'\n")
            with patch.object(H, "REPO", root), patch.object(H, "CAPTURE", wrapper.name, create=True), \
                    patch.object(H, "ANSWERS", answer.name), patch.dict(os.environ):
                os.environ.pop("PLAT61_DESKTOP_TEST", None)
                self.assertEqual(H.run_spec(H.SPEC), ("GREEN", []))
            self.assertEqual(answer.read_bytes(), b"entry")


class FirstSemanticFailure(unittest.TestCase):
    def child_failures(self, writes):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            child = root / "compiler-output.py"
            body = "import sys\n"
            for stream, text in writes:
                body += f"sys.{stream}.write({text!r})\nsys.{stream}.flush()\n"
            child.write_text(body + "sys.exit(1)\n")
            tool = root / "nim"
            tool.write_text(f"#!{BASH}\nexec {shlex.quote(sys.executable)} {shlex.quote(str(child))} \"$@\"\n")
            tool.chmod(0o755)
            with patch.object(H, "REPO", root), patch.object(H, "NIMCACHE", root / "cache"), \
                    patch.dict(os.environ, {"PATH": str(root) + os.pathsep + os.environ["PATH"]}):
                verdict, failures = H.run_suite("stream-fixture.nim", None)
            self.assertEqual(verdict, "RED")
            return failures

    def test_real_child_exception_precedes_consequential_counter(self):
        failures = self.child_failures([
            ("stderr", "Unhandled exception: the recorded build never appeared; screen: frame\n"),
            ("stdout", "Check failed: countedAssertions == ExpectedAssertions\n")])
        self.assertEqual(failures[0], "the recorded build never appeared")
        self.assertIn("countedAssertions == ExpectedAssertions", failures)

    def test_real_child_native_checkpoint_precedes_volatile_wrapper_and_counter(self):
        failures = self.child_failures([
            ("stderr", "codetracer-gpui: --window-ops: the shell did not show 'built-42' in 60000 ms\n"),
            ("stdout", "Unhandled exception: the window plan run failed (type:/volatile/project/build.sh) [IOError]\n"),
            ("stdout", "Check failed: CHECKS == ExpectedAssertions\n")])
        self.assertEqual(failures[0], "the shell did not show 'built-42' in 60000 ms")
        self.assertIn("CHECKS == ExpectedAssertions", failures)

    def test_real_child_earlier_soft_wait_precedes_later_assertion_and_counter(self):
        failures = self.child_failures([
            ("stderr", "    waited 120000 ms for the cleared screen; the pane shows:\nframe\n"),
            ("stdout", "Check failed: normalised(painted)[0 ..< oracle.len] == oracle\n"),
            ("stdout", "Check failed: countedAssertions == ExpectedAssertions\n")])
        self.assertEqual(failures[0], "waited 120000 ms for the cleared screen")
        self.assertIn("normalised(painted)[0 ..< oracle.len] == oracle", failures)
        self.assertIn("countedAssertions == ExpectedAssertions", failures)

    def test_real_child_earlier_assertion_precedes_later_soft_wait(self):
        failures = self.child_failures([
            ("stdout", "Check failed: shellRows > 0\n"),
            ("stderr", "    waited 120000 ms for the cleared screen; the pane shows:\nframe\n")])
        self.assertEqual(failures[0], "shellRows > 0")

    def test_generic_harness_budget_is_not_a_semantic_cause(self):
        self.assertEqual(H.output_order_failures(
            "TIMEOUT after 3600 seconds\nwaited 3600000 ms for process exit\n"), [])

    def test_real_child_earlier_assertion_retains_priority(self):
        failures = self.child_failures([
            ("stdout", "Check failed: shellRows > 0\n"),
            ("stderr", "Unhandled exception: the recorded build never appeared; screen: frame\n")])
        self.assertEqual(failures[0], "shellRows > 0")


if __name__ == "__main__":
    unittest.main()
