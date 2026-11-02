#!/usr/bin/env python3
"""PLAT-56 — the mutation harness for the Build Output pane on every front-end
(codetracer-pm `spec/Planned-Features/Build-Output-Pane.md` §3.13, §3.5,
§3.7, §3.10; `Edit-Mode-Toolbar.md` §11.2): the shared model (the reader,
the chunk rule, the words), the `BuildVM` (a build's lifecycle, the history),
the first `next error` landing on the highlight (`errors_vm`), the native
reader and runner, the terminal's host source, painter, status line, runtime
and loop, the GPUI leaf and window, the vocabulary view, and the desktop's
Build component, Problems wiring, view and status bar.

Each arm plants ONE defect; REBUILDS the shipped `codetracer-tui` /
`codetracer-gpui` / desktop when the defect is compiled into a binary an arm
is graded through; runs the suites that must catch it; and requires RED —
with the failure the first run recorded (`plat56-build-output-mutation-
because.json`, derived with `--derive`).

The discipline is PLAT-55's harness's (`run-plat55-problems-mutations.py`),
clause for clause: committed control digests over subjects AND suites (§16c),
a needle scan that gates re-recording (§39a), `because` derived from a run,
rc 124 is a hang (§1), per-arm restore verification, one declared
behaviour-preserving survivor, and `ci/lib/harness_guard.py`'s argument rule
before anything is touched.

The builds run `$PLAT56_BUILD_TUI` / `$PLAT56_BUILD_GPUI` /
`$PLAT56_BUILD_DESKTOP` when set, else `just build-tui` / `just build-gpui` /
`just build-once`; the suites compile with `$PLAT56_NIM` when set, else
`nim`. The desktop arms are graded by the Electron capture specs, run by
`$PLAT56_DESKTOP_TEST` (the spec's path appended) when set, else `npx
playwright test` in `src/tests/gui` (a DISPLAY is needed). The suites build
the real PLAT-56 project with the real `gcc` (and the PLAT-55 crate with the
real `nargo`), which must be on PATH, as the lanes require.

Usage:
    run-plat56-build-output-mutations.py [--only M1,T1] [--derive]
    run-plat56-build-output-mutations.py --needle-scan
    run-plat56-build-output-mutations.py --record-control-hashes
"""
import argparse
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[4]
HERE = Path(__file__).resolve().parent
CONTROL = HERE / "plat56-build-output-mutation-control.sha256"
BECAUSE = HERE / "plat56-build-output-mutation-because.json"
NIMCACHE = Path(os.environ.get("CT_NIM_CACHE_ROOT",
                               os.environ.get("TMPDIR", "/tmp"))) / \
    "plat56-mutations"
BIN = REPO / "build/bin/codetracer-tui"
GPUI_BIN = REPO / "build/bin/codetracer-gpui"
TIMEOUT = 3600

# Subjects.
MODEL = "src/frontend/viewmodel/viewmodels/build_output_model.nim"
VM = "src/frontend/viewmodel/viewmodels/build_vm.nim"
ERRORS = "src/frontend/viewmodel/viewmodels/errors_vm.nim"
READER = "src/frontend/tui/host/build_problems.nim"
RUNNER = "src/frontend/tui/host/build_runner.nim"
SOURCE = "src/frontend/tui/host/build_output_source.nim"
TUI_PANE = "src/frontend/tui/app/views/build_output.nim"
STATUS = "src/frontend/tui/app/views/status_bar.nim"
RUNTIME = "src/frontend/tui/app/runtime.nim"
TUI_MAIN = "src/frontend/tui/main.nim"
GPUI_LEAF = "src/frontend/gpui/build_output_leaf.nim"
GPUI_MAIN = "src/frontend/gpui/main.nim"
VOCAB = "src/frontend/view_vocabulary/pane_views.nim"
DESKTOP_BUILD = "src/frontend/ui/build.nim"
DESKTOP_ERRORS = "src/frontend/ui/errors.nim"
DESKTOP_STATUS = "src/frontend/ui/status.nim"
DESKTOP_VIEW = "src/frontend/viewmodel/views/isonim_build_view.nim"

# Suites.
VMU = "src/frontend/viewmodel/tests/unit/test_plat56_build_output.nim"
TBL = "src/frontend/tui/tests/test_plat56_build_output.nim"
RUNNER_SUITE = "src/frontend/tui/tests/test_build_runner_process.nim"
PTY = "src/frontend/tui/tests/real_terminal/test_plat56_build_output_pty.nim"
PLAN = "src/frontend/gpui/tests/test_plat56_gpui_plan.nim"
PLAN55 = "src/frontend/gpui/tests/test_plat55_gpui_plan.nim"
SPEC = "src/tests/gui/tests/build/plat56-build-output-capture.spec.ts"
SPEC55 = "src/tests/gui/tests/problems-pane/plat55-problems-capture.spec.ts"
FIXTURE = "src/frontend/viewmodel/tests/unit/build_fixtures/plat56_c_build.nim"

SUBJECTS = [MODEL, VM, ERRORS, READER, RUNNER, SOURCE, TUI_PANE, STATUS,
            RUNTIME, TUI_MAIN, GPUI_LEAF, GPUI_MAIN, VOCAB, DESKTOP_BUILD,
            DESKTOP_ERRORS, DESKTOP_STATUS, DESKTOP_VIEW]
SUITES = [VMU, TBL, RUNNER_SUITE, PTY, PLAN, PLAN55, SPEC, SPEC55, FIXTURE]

TBL_REAL = "*::a real failing build, then a passing one: lines, verdicts, history"
TBL_PAINT = "*::every width: the verdict, the controls, the colours, the hit-tests"
TBL_STATUS = "*::the status line's indicator reveals Build Output"
TBL_STATUSLINE = "*::the indicator has its place after the mode indicators"
PLAN_LINES = "*::a real failing build: the desktop's lines, verdict and indicator"
PLAN_PRESS = "*::a press on a located line opens its file at its line"
PLAN_HISTORY = "*::a passing build after it; the history; the indicator reveals"
PLAN55_NEXT = "*::a press on a row opens its file at its line; next error; the keys"

# (id, [(subject, find, replace), ...], [(suite, filter), ...], what it breaks)
ARMS = [
    # ---- the shared model ----------------------------------------------------
    ("M1", [(MODEL, "        r.attrs.applySgr(t)", "        discard")],
     [(VMU, None), (TBL, TBL_REAL), (PLAN, PLAN_LINES)],
     "§3.5: the compiler's colours are dropped"),
    ("M2", [(MODEL, "        add(result, r.attrs, spaces(TermTabStop - (col mod TermTabStop)), col)",
             "        discard")],
     [(VMU, None)],
     "§3.5: a tab is dropped rather than expanded"),
    ("M3", [(MODEL, "      if result.fed.scanned.found: severityOf(result.fed.scanned.severity)",
             "      if false: severityOf(result.fed.scanned.severity)")],
     [(VMU, None), (TBL, TBL_REAL), (PLAN, PLAN_LINES)],
     "§3.13: a located line loses its severity's colour"),
    ("M4", [(MODEL, "    result.line.locationCol = max(0, loc.col)",
             "    result.line.locationCol = 0")],
     [(VMU, None), (TBL, TBL_REAL), (PLAN, PLAN_PRESS)],
     "K35: a located line opens without its column"),
    ("M5", [(MODEL, '  if data.endsWith("\\n"):', "  if false:")],
     [(VMU, None)],
     "§3.13: a write ending in a newline ends with a phantom empty line"),
    ("M6", [(MODEL, '  of bsFailed: s.nounOf & " failed (exit code " & $s.code & ")"',
             '  of bsFailed: s.nounOf & " failed"')],
     [(VMU, None), (TBL, TBL_REAL), (PLAN, PLAN_LINES)],
     "§3.13: the failed verdict does not name the exit code"),
    ("M7", [(MODEL, '    if counts.len > 0: noun & " failed: " & counts',
             '    if false: noun & " failed: " & counts')],
     [(VMU, None), (TBL, TBL_REAL), (PLAN, PLAN_LINES)],
     "§3.10: the status bar does not count the errors and warnings"),
    ("M8", [(MODEL, '    label.add ", " & formatBuildDuration(e.endMs - e.startMs)',
             "    discard")],
     [(VMU, None)],
     "§3.7: a history entry does not say how long its build ran"),
    # ---- the BuildVM ---------------------------------------------------------
    ("V1", [(VM, "  h.insert(entryOf(cur), 0)", "  h.add(entryOf(cur))")],
     [(VMU, None)],
     "§3.7: the history is oldest first"),
    ("V2", [(VM, "  if h.len > BuildHistoryMax:", "  if false:")],
     [(VMU, None)],
     "§3.7: the history is not bounded"),
    ("V3", [(VM, "      elif cancelled.val:", "      elif false:")],
     [(VMU, None)],
     "a cancelled build is reported as failed"),
    ("V4", [(VM, "      elif output.val.len == 0 and command.val.len == 0:",
             "      elif output.val.len == 0:")],
     [(VMU, None)],
     "a build that failed in silence is shown as idle"),
    ("V5", [(VM, "    rows.add result.fed.row", "    discard")],
     [(VMU, None)],
     "§3.10: the build's diagnostics are not counted"),
    # ---- the first next error -----------------------------------------------
    ("E1", [(ERRORS, "  let landing = vm.landOnHighlight and step == ensNext and current >= 0",
             "  let landing = false")],
     [(VMU, None), (PLAN55, PLAN55_NEXT)],
     "EMT-D21: the first next error skips the highlighted error"),
    ("E2", [(ERRORS, "  vm.landOnHighlight = true", "  vm.landOnHighlight = false")],
     [(VMU, None), (PLAN55, PLAN55_NEXT)],
     "EMT-D21: the highlight is not where next error lands"),
    # ---- the native reader and runner ---------------------------------------
    ("H1", [(READER, "                                    isStdout = not session.isStderr(i))",
             "                                    isStdout = true)")],
     [(TBL, TBL_REAL), (PLAN, PLAN_LINES)],
     "§3.13: stderr is drawn as stdout"),
    ("H2", [(READER, "      discard p.feed.addRow(read.fed)", "      discard")],
     [(TBL, TBL_REAL)],
     "the build's diagnostics never reach the Problems pane"),
    ("N1", [(RUNNER, "    result.streams[i] = BuildStream(fd: fd, stderr: i == 1)",
             "    result.streams[i] = BuildStream(fd: fd, stderr: false)")],
     [(RUNNER_SUITE, None), (TBL, TBL_REAL)],
     "§3.13: the runner tags stderr lines as stdout"),
    ("N2", [(RUNNER, "        st.pending.setLen(st.pending.len - 1)\n      rb.session.appendLine(st.pending, stderr = st.stderr)",
             "        st.pending.setLen(st.pending.len - 1)\n      rb.session.appendLine(st.pending.strip(leading = false), stderr = st.stderr)")],
     [(TBL, TBL_REAL)],
     "§3.13: a line's trailing spaces are dropped (the desktop keeps them)"),
    # ---- the terminal's host source, painter, status line, runtime, loop ----
    ("S1", [(SOURCE, '  if text.len == 0: "" else: vm.statusIcon & " " & text',
             '  if text.len == 0: "" else: text')],
     [(TBL, TBL_REAL), (PTY, None)],
     "§3.10: the status line's indicator has no icon"),
    ("S2", [(SOURCE, "                                           line.locationCol)",
             "                                           0)")],
     [(TBL, TBL_REAL)],
     "K35: a line opens with the caret not at its column"),
    ("S3", [(SOURCE, "    vm.showBuild(index - 1)", "    vm.showBuild(index)")],
     [(TBL, TBL_REAL)],
     "§3.7: the picker shows the wrong build"),
    ("S4", [(SOURCE, "        result = s.rerun(shown.command,",
             "        result = s.rerun(vm.command.val,")],
     [(TBL, TBL_REAL)],
     "Run builds the current command, not the shown one"),
    ("T1", [(TUI_PANE, "    result.fg = termHex(fg)", "    discard")],
     [(TBL, TBL_PAINT), (PTY, None)],
     "§3.5: the terminal does not draw the compiler's colours"),
    ("T2", [(TUI_PANE, "  else: BuildStderrStyle", "  else: BuildOutputStyle")],
     [(TBL, None)],
     "§3.13: stderr is not drawn in the error colour, italic"),
    ("T3", [(TUI_PANE, "        return BuildPaneTarget(kind: btControl, control: c.control, index: -1)",
             "        return BuildPaneTarget(kind: btControl, control: bcRun, index: -1)")],
     [(TBL, None)],
     "a press on a control is read as Run"),
    ("T4", [(TUI_PANE, "    result.trackCol = area.col + area.width - ScrubberTrackCells",
             "    result.trackCol = -1")],
     [(TBL, TBL_PAINT)],
     "the output's scrollbar is not drawn"),
    ("T5", [(TUI_PANE, "    return BuildPaneTarget(kind: btHistoryItem, index: row - screen.menuTop)",
             "    return BuildPaneTarget(kind: btHistoryItem, index: 0)")],
     [(TBL, None)],
     "§3.7: a press on a history entry shows the current build"),
    ("B1", [(STATUS, '             (if m.build.len > 0: "  " & m.build else: "")',
             '             (if false: "  " & m.build else: "")')],
     [(TBL, TBL_STATUSLINE), (TBL, TBL_REAL), (PTY, None)],
     "§3.10: the status line has no build indicator"),
    ("R1", [(RUNTIME, "      rt.buildCommand(bpcOpen, t.index, outcome)", "      discard")],
     [(TBL, TBL_REAL), (PTY, None)],
     "K35: a press on a located line opens nothing"),
    ("R2", [(RUNTIME, "            rt.revealBuildPane()", "            discard")],
     [(TBL, TBL_STATUS)],
     "§3.10: the status line's indicator, pressed, reveals nothing"),
    ("L1", [(TUI_MAIN, "      let testsChanged = tests.tick(rt)\n      let problemsTicked = problems.tick(rt, nowMonoMs())\n      let problemsChanged = buildOut.tick(rt) or problemsTicked",
             "      let testsChanged = tests.tick(rt)\n      let problemsTicked = problems.tick(rt, nowMonoMs())\n      let problemsChanged = problemsTicked")],
     [(PTY, None)],
     "the Edit loop never draws the build's output"),
    # ---- the GPUI leaf and window -------------------------------------------
    ("G1", [(GPUI_LEAF, "    of blsError: BuildErrorColour", "    of blsError: BuildTextColour")],
     [(PLAN, PLAN_LINES)],
     "§3.13: a located error line is not in the desktop's error colour"),
    ("G2", [(GPUI_LEAF, "             GBuildHit(kind: gbhLine, index: i)",
             "             GBuildHit(kind: gbhLine, index: 0)")],
     [(PLAN, PLAN_PRESS)],
     "K35: a press on a GPUI line opens another line's location"),
    ("G3", [(GPUI_MAIN, "  let changed = gProblems.follow(gBuild.session, nowMonoMs())",
             "  let changed = false")],
     [(PLAN, PLAN_LINES)],
     "the GPUI window does not draw its build as it runs"),
    ("G4", [(GPUI_MAIN, '    r.setAttribute(b, "data-ct-footer-build", words)', "    discard")],
     [(PLAN, PLAN_LINES)],
     "§3.10: the GPUI footer has no build indicator"),
    ("G5", [(GPUI_MAIN, "    vm.showBuild(hit.index - 1)", "    vm.showBuild(hit.index)")],
     [(PLAN, PLAN_HISTORY)],
     "§3.7: the GPUI picker shows the wrong build"),
    ("P1", [(VOCAB, "                           disabled: not line.located)",
             "                           disabled: false)")],
     [(TBL, TBL_REAL)],
     "the vocabulary's view offers lines that name no location"),
    # ---- the desktop ---------------------------------------------------------
    ("D1", [(DESKTOP_BUILD, "    errors.highlightFirstBuildErrorIn(self.errorsVMOf())",
             "    errors.highlightFirstBuildError()")],
     [(SPEC55, None)],
     "EMT-D21: the desktop's failed build highlights no row"),
    ("D2", [(DESKTOP_ERRORS, "    discard data.openLocation(cstring(desktopResolvedPath(path)), line, col)",
             "    discard data.openLocation(cstring(path), line, col)")],
     [(SPEC55, None)],
     "EMT-A36: a desktop Problems row with a relative path opens nothing"),
    ("D3", [(DESKTOP_VIEW, '      r.setAttribute(span, "style", css)', "      discard")],
     [(SPEC, None)],
     "§3.5: the desktop does not draw the compiler's colours"),
    ("D4", [(DESKTOP_STATUS, "      build: statusBuildModel())", "      build: StatusBuildModel())")],
     [(SPEC, None)],
     "§3.10: the desktop's status bar has no build indicator"),
    ("D5", [(DESKTOP_BUILD, "    else: vm.feedOutput(buildLine, stdout)",
             "    else: orphanReader.read(buildLine, stdout)")],
     [(SPEC, None)],
     "the desktop's BUILD panel draws no line"),
    # ---- the declared survivor ----------------------------------------------
    ("Z1", [(RUNNER, "    ## syscalls per tick, small enough that the buffer is not a pane's worth",
             "    ## syscalls per tick, small enough that the buffer is not a pane's worth ")],
     [(RUNNER_SUITE, None)],
     "behaviour-preserving: the DECLARED SURVIVOR (a comment's trailing space)"),
]

DECLARED_SURVIVORS = {"Z1"}

IN_BINARY = {MODEL, VM, ERRORS, READER, RUNNER, SOURCE, TUI_PANE, STATUS,
             RUNTIME, TUI_MAIN, VOCAB}
IN_GPUI = {MODEL, VM, ERRORS, READER, RUNNER, GPUI_LEAF, GPUI_MAIN, VOCAB}
IN_DESKTOP = {MODEL, VM, ERRORS, DESKTOP_BUILD, DESKTOP_ERRORS,
              DESKTOP_STATUS, DESKTOP_VIEW}
PTY_SUITES = {PTY}
GPUI_SUITES = {PLAN, PLAN55}
DESKTOP_SUITES = {SPEC, SPEC55}


def path_of(rel):
    return REPO / rel


def sha_path(p):
    return hashlib.sha256(Path(p).read_bytes()).hexdigest()


def sha(rel):
    return sha_path(path_of(rel))


def lane_flags(lane):
    return subprocess.run(
        ["bash", "-c", ". ci/lib/test-lane-files.sh >/dev/null 2>&1 && "
                       f"test_lane_extra_flags {lane}"],
        cwd=REPO, capture_output=True, text=True, check=True).stdout.split()


def suite_flags(suite):
    if suite == PTY:
        return lane_flags("tui-real-terminal")
    if suite.startswith("src/frontend/tui/"):
        return lane_flags("tui")
    if suite.startswith("src/frontend/gpui/"):
        return lane_flags("gpui-shell") + ["--path:src/frontend/viewmodel"]
    return ["--path:src/frontend/viewmodel"]


def needle_scan():
    ok = True
    for arm_id, edits, *_ in ARMS:
        for rel, find, _ in edits:
            text = path_of(rel).read_text()
            n = text.count(find)
            if n != 1:
                print(f"  NEEDLE FAIL {arm_id}: {n} occurrence(s) in {rel}")
                ok = False
                continue
            end = text.index(find) + len(find)
            if end < len(text) and text[end] not in "\r\n":
                print(f"  NEEDLE FAIL {arm_id}: does not end at a line end")
                ok = False
    print(f"needle scan: {len(ARMS)} arm(s), "
          f"{'every find occurs exactly once' if ok else 'FAILED'}")
    return ok


def record_controls():
    if not needle_scan():
        print("REFUSED: re-recording now would certify an unaimed arm (§39a).")
        return 1
    with open(CONTROL, "w") as f:
        f.write("# Control digests for run-plat56-build-output-mutations.py —\n"
                "# the subjects AND the suites the arms are graded by (§16c).\n"
                "# Refreshed with --record-control-hashes, gated by the\n"
                "# needle scan (§39a).\n")
        for rel in SUBJECTS + SUITES:
            f.write(f"{sha(rel)}  {rel}\n")
    print(f"recorded {len(SUBJECTS) + len(SUITES)} control digests")
    return 0


def controls_match():
    if not CONTROL.exists():
        print("NO CONTROL DIGESTS — run --record-control-hashes first.")
        return False
    ok = True
    for line in CONTROL.read_text().splitlines():
        if not line or line.startswith("#"):
            continue
        digest, rel = line.split("  ", 1)
        if sha(rel) != digest:
            print(f"CONTROL DIGEST MOVED: {rel}")
            ok = False
    return ok


def build_with(env_var, recipe):
    cmd = os.environ.get(env_var)
    argv = ["bash", "-c", cmd] if cmd else ["just", recipe]
    p = subprocess.run(argv, cwd=REPO, capture_output=True, text=True,
                       timeout=TIMEOUT)
    if p.returncode != 0:
        print((p.stdout + p.stderr)[-2000:])
    return p.returncode == 0


def build_binary():
    return build_with("PLAT56_BUILD_TUI", "build-tui")


def build_gpui():
    return build_with("PLAT56_BUILD_GPUI", "build-gpui")


def build_desktop():
    return build_with("PLAT56_BUILD_DESKTOP", "build-once")


def portable_cause(line):
    """A pty suite's wait names its condition and then snapshots the screen;
    the recorded cause keeps the condition and drops the snapshot."""
    head, sep, _rest = line.partition("; screen:")
    if sep:
        return head
    head, sep, rest = line.partition("; status:")
    if not sep:
        return line
    tail = re.search(r" \[\w+\]$", rest)
    return head + (tail.group(0) if tail else "")


def run_spec(suite):
    """The Electron spec: GREEN on rc 0, else RED on its first expectation."""
    cmd = os.environ.get("PLAT56_DESKTOP_TEST")
    spec = suite.split("src/tests/gui/", 1)[1]
    argv = ["bash", "-c", cmd + " " + spec] if cmd else \
        ["npx", "playwright", "test", spec, "--reporter=line"]
    cwd = REPO if cmd else REPO / "src/tests/gui"
    try:
        p = subprocess.run(argv, cwd=cwd, capture_output=True, text=True,
                           timeout=TIMEOUT)
    except subprocess.TimeoutExpired:
        return "HUNG", []
    out = (p.stdout or "") + (p.stderr or "")
    if p.returncode == 0:
        return ("GREEN", []) if " passed" in out else ("RAN-NOTHING", [])
    plain = re.sub(r"\x1b\[[0-9;]*m", "", out)
    first = [ln.strip() for ln in plain.splitlines()
             if ln.strip().startswith("Error:")][:1]
    return "RED", first


def run_suite(suite, test_filter):
    if suite in DESKTOP_SUITES:
        return run_spec(suite)
    NIMCACHE.mkdir(parents=True, exist_ok=True)
    stem = Path(suite).stem
    env = dict(os.environ, CODETRACER_REPO_ROOT=str(REPO))
    cmd = [os.environ.get("PLAT56_NIM", "nim"), "c", "-r", "--hints:off",
           "--warnings:off",
           f"--nimcache:{NIMCACHE}/{stem}",
           f"-o:{NIMCACHE}/{stem}.out"] + suite_flags(suite) + [suite]
    if test_filter:
        cmd.append(test_filter)
    try:
        p = subprocess.run(cmd, cwd=REPO, capture_output=True, text=True,
                           timeout=TIMEOUT, env=env)
    except subprocess.TimeoutExpired:
        return "HUNG", []
    out = (p.stdout or "") + (p.stderr or "")
    if p.returncode == 124:
        return "HUNG", []
    failures = [portable_cause(ln.strip().split("Check failed: ", 1)[1])
                for ln in out.splitlines() if "Check failed: " in ln]
    if p.returncode == 0:
        ran = out.count("[OK]")
        return ("GREEN", failures) if ran > 0 else ("RAN-NOTHING", [])
    if not failures and "Error:" in out and "[FAILED]" not in out:
        return "DID-NOT-COMPILE", failures
    if not failures:
        failures = [portable_cause(ln.strip()) for ln in out.splitlines()
                    if "[FAILED]" in ln or "Unhandled exception" in ln][:1]
    return "RED", failures


def grade(suites):
    first, verdict = "", "GREEN"
    for s, flt in suites:
        v, f = run_suite(s, flt)
        if v in ("HUNG", "DID-NOT-COMPILE", "RAN-NOTHING"):
            return v, ""
        if v == "RED":
            verdict = "RED"
            if not first and f:
                first = f[0]
    return verdict, first


sys.path.insert(0, str(REPO / "ci" / "lib"))
from harness_guard import refuse_undeclared_arms  # noqa: E402


def main():
    # AN UNDECLARED ARM ID, OR AN EMPTY `--only=`, IS REFUSED before anything
    # is touched (`ci/lib/harness_guard.py`).
    refused = refuse_undeclared_arms(sys.argv[1:], globals())
    if refused:
        return refused
    ap = argparse.ArgumentParser()
    ap.add_argument("--only", default="")
    ap.add_argument("--needle-scan", action="store_true")
    ap.add_argument("--derive", action="store_true")
    ap.add_argument("--record-control-hashes", action="store_true")
    a = ap.parse_args()
    os.chdir(REPO)
    if a.needle_scan:
        return 0 if needle_scan() else 1
    if a.record_control_hashes:
        return record_controls()
    if not needle_scan() or not controls_match():
        print("the tree is not at the control bytes; nothing was mutated.")
        return 3
    only = set(filter(None, a.only.split(",")))
    selected = [arm for arm in ARMS if not only or arm[0] in only]
    needs_binary = any(s in PTY_SUITES for arm in selected for s, _ in arm[2])
    needs_gpui = any(s in GPUI_SUITES for arm in selected for s, _ in arm[2])
    needs_desktop = any(s in DESKTOP_SUITES for arm in selected
                        for s, _ in arm[2])
    binary_digest = gpui_digest = None
    if needs_binary:
        if not build_binary():
            print("ABORT: the unmutated binary does not build.")
            return 1
        binary_digest = sha_path(BIN)
    if needs_gpui:
        if not build_gpui():
            print("ABORT: the unmutated GPUI binary does not build.")
            return 1
        gpui_digest = sha_path(GPUI_BIN)
    if needs_desktop and not build_desktop():
        print("ABORT: the unmutated desktop does not build.")
        return 1
    graded = sorted({(s, flt or "") for arm in selected for s, flt in arm[2]})
    for s, flt in graded:
        v, f = run_suite(s, flt or None)
        if v != "GREEN":
            print(f"ABORT: the baseline of {s} is {v}: {f[:1]}")
            return 1
    print(f"baseline GREEN ({len(graded)} suite run(s))")
    because = json.loads(BECAUSE.read_text()) if BECAUSE.exists() else {}
    digests = {rel: sha(rel) for rel in SUBJECTS}
    derived, bad = {}, []
    for arm_id, edits, suites, what in selected:
        files = sorted({rel for rel, _, _ in edits})
        backups = {}
        for rel in files:
            path = path_of(rel)
            backups[rel] = path.with_name(path.name + ".plat56bak")
            shutil.copy2(path, backups[rel])
        try:
            for rel, find, replace in edits:
                path = path_of(rel)
                path.write_text(path.read_text().replace(find, replace, 1))
            built = True
            if any(s in PTY_SUITES for s, _ in suites) and \
                    any(r in IN_BINARY for r in files):
                built = build_binary()
            if built and any(s in GPUI_SUITES for s, _ in suites) and \
                    any(r in IN_GPUI for r in files):
                built = build_gpui()
            if built and any(s in DESKTOP_SUITES for s, _ in suites) and \
                    any(r in IN_DESKTOP for r in files):
                built = build_desktop()
            verdict, first = grade(suites) if built else ("DID-NOT-COMPILE", "")
        finally:
            for rel in files:
                shutil.move(backups[rel], path_of(rel))
                if sha(rel) != digests[rel]:
                    print(f"ABORT: restore of {rel} failed after {arm_id}.")
                    return 1
        derived[arm_id] = first
        if arm_id in DECLARED_SURVIVORS:
            ok = verdict == "GREEN"
            mark = "SURVIVED (declared)" if ok else f"MISDIRECTED ({verdict})"
        elif verdict == "RED":
            want = because.get(arm_id)
            ok = a.derive or want is None or want == first
            mark = "KILLED" if ok else f"KILLED BY THE WRONG CHECK: {first!r}"
        else:
            ok = False
            mark = verdict if verdict != "GREEN" else "SURVIVED — NOT ENFORCED"
        print(f"  {arm_id:<4} {mark:<30} {what}", flush=True)
        if a.derive or not ok:
            print(f"       because: {first!r}")
        if not ok:
            bad.append(arm_id)
    if a.derive:
        merged = dict(because)
        merged.update({k: v for k, v in derived.items()
                       if k not in DECLARED_SURVIVORS})
        BECAUSE.write_text(json.dumps(merged, indent=2, sort_keys=True) + "\n")
        print(f"derived {len(derived)} because line(s)")
    if binary_digest is not None:
        if not build_binary() or sha_path(BIN) != binary_digest:
            print("FAIL: the binary rebuilt from the restored tree differs "
                  "from the one the run started with.")
            return 1
    if gpui_digest is not None:
        if not build_gpui() or sha_path(GPUI_BIN) != gpui_digest:
            print("FAIL: the GPUI binary rebuilt from the restored tree "
                  "differs from the one the run started with.")
            return 1
    if needs_desktop and not build_desktop():
        print("FAIL: the desktop does not rebuild from the restored tree.")
        return 1
    for rel in SUBJECTS:
        if sha(rel) != digests[rel]:
            print(f"FAIL: {rel} does not match its digest at exit.")
            return 1
    print(f"RESULT: {len(bad)} arm(s) not as required: {', '.join(bad) or '-'}")
    return 0 if not bad else 1


if __name__ == "__main__":
    sys.exit(main())
