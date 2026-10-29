#!/usr/bin/env python3
"""The mutation harness for build tasks, the task picker and the `:build`
commands, the Build Output pane's reveal and dismissal, a build's
diagnostics in the editor, and the desktop's build runner and Stop
(codetracer-pm `spec/Planned-Features/Build-Output-Pane.md` §3.2, §3.6,
§3.8, §3.9, §3.11, §3.12, §4.2, §5.2) on every front-end: the shared model
(`build_tasks`, `build_auto_reveal`, `editor_diagnostics`, the omnibox's
task mode, `BuildVM`'s matcher), the terminal's runtime, host source, Edit
pane and runner wiring, the GPUI window and its editor rows, and the
desktop's main-process runner, BUILD component, palette and wiring.

Each arm plants ONE defect; REBUILDS the shipped `codetracer-tui` /
`codetracer-gpui` / desktop when the defect is compiled into a binary an arm
is graded through; runs the suites that must catch it; and requires RED —
with the failure the first run recorded (`build-residuals-mutation-
because.json`, derived with `--derive`).

The discipline is `run-plat56-build-output-mutations.py`'s, clause for
clause (committed control digests over subjects AND suites, a needle scan
that gates re-recording, `because` derived from a run, rc 124 a hang,
per-arm restore verification, one declared behaviour-preserving survivor,
`ci/lib/harness_guard.py`'s argument rule), and it reads the same
environment: `$PLAT56_BUILD_TUI` / `$PLAT56_BUILD_GPUI` /
`$PLAT56_BUILD_DESKTOP` (else `just build-tui` / `just build-gpui` /
`just build-once`), `$PLAT56_NIM` (else `nim`), `$PLAT56_DESKTOP_TEST` (the
spec's path appended; else `npx playwright test`, which needs a DISPLAY).
The suites build the PLAT-56 project with the real `gcc`.

Usage:
    run-build-residuals-mutations.py [--only A1,T1] [--derive]
    run-build-residuals-mutations.py --needle-scan
    run-build-residuals-mutations.py --record-control-hashes
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
CONTROL = HERE / "build-residuals-mutation-control.sha256"
BECAUSE = HERE / "build-residuals-mutation-because.json"
NIMCACHE = Path(os.environ.get("CT_NIM_CACHE_ROOT",
                               os.environ.get("TMPDIR", "/tmp"))) / \
    "build-residuals-mutations"
BIN = REPO / "build/bin/codetracer-tui"
GPUI_BIN = REPO / "build/bin/codetracer-gpui"
TIMEOUT = 3600

# Subjects.
TASKS = "src/frontend/viewmodel/viewmodels/build_tasks.nim"
REVEAL = "src/frontend/viewmodel/viewmodels/build_auto_reveal.nim"
DIAG = "src/frontend/viewmodel/viewmodels/editor_diagnostics.nim"
VM = "src/frontend/viewmodel/viewmodels/build_vm.nim"
OMNI = "src/frontend/viewmodel/viewmodels/omnibar_vm.nim"
RUNTIME = "src/frontend/tui/app/runtime.nim"
SOURCE = "src/frontend/tui/host/build_output_source.nim"
READER = "src/frontend/tui/host/build_problems.nim"
EDIT_PANE = "src/frontend/tui/app/views/edit_pane.nim"
GPUI_MAIN = "src/frontend/gpui/main.nim"
GPUI_LEAVES = "src/frontend/gpui/app/leaves.nim"
RUNNER = "src/frontend/index/build_runner.nim"
DESKTOP_BUILD = "src/frontend/ui/build.nim"
DESKTOP_PALETTE = "src/frontend/ui/command.nim"
DESKTOP_UI = "src/frontend/ui_js.nim"

# Suites.
VMU = "src/frontend/viewmodel/tests/unit/test_build_tasks_reveal_diagnostics.nim"
TBL = "src/frontend/tui/tests/test_build_tasks_tui.nim"
PTY = "src/frontend/tui/tests/real_terminal/test_build_tasks_pty.nim"
PLAN = "src/frontend/gpui/tests/test_build_tasks_gpui_plan.nim"
SPEC = "src/tests/gui/tests/build/build-tasks.spec.ts"
FIXTURE = "src/frontend/viewmodel/tests/unit/build_fixtures/plat56_c_build.nim"

SUBJECTS = [TASKS, REVEAL, DIAG, VM, OMNI, RUNTIME, SOURCE, READER, EDIT_PANE,
            GPUI_MAIN, GPUI_LEAVES, RUNNER, DESKTOP_BUILD, DESKTOP_PALETTE,
            DESKTOP_UI]
SUITES = [VMU, TBL, PTY, PLAN, SPEC, FIXTURE]

TBL_PICKER = "*::Ctrl+Shift+B: the picker, the default first; Enter builds it"
TBL_CMDS = "*::the omnibox commands: a task, the default, unknown, none, stop, history, clear"
TBL_REVEAL = "*::the reveal: docked Build Output shown by a build, put away after a clean one"
TBL_EDIT = "*::the Edit pane: underlined spans, gutter icons, the hover; cleared by a new build"

# (id, [(subject, find, replace), ...], [(suite, filter), ...], what it breaks)
ARMS = [
    # ---- the shared model ----------------------------------------------------
    ("A1", [(TASKS, '    of "", "tasks": BuildVerb(kind: bvkPick)',
             '    of "": BuildVerb(kind: bvkPick)')],
     [(VMU, None)],
     "§3.12: `:build: tasks` runs a task called tasks"),
    ("A2", [(TASKS, "      cur.cwd = value", "      discard")],
     [(VMU, None)],
     "§3.6: a task's cwd is ignored"),
    ("A3", [(TASKS, "    if t.isDefault:\n      return (true, t)",
             "    if false:\n      return (true, t)")],
     [(VMU, None), (TBL, TBL_PICKER)],
     "§3.6: `default: true` does not make the default task"),
    ("A4", [(TASKS, "    if d.found and t.name == d.task.name:",
             "    if false and t.name == d.task.name:")],
     [(VMU, None), (TBL, TBL_PICKER)],
     "§3.11: the picker lists the default task twice"),
    ("A5", [(REVEAL, "  of bsRunning:\n    if isNew and a.setting.autoReveal:",
             "  of bsRunning:\n    if false:")],
     [(VMU, None), (TBL, TBL_REVEAL)],
     "§3.8: a build starting does not reveal the pane"),
    ("A6", [(REVEAL, "    if a.setting.autoDismissOnSuccess and errors == 0 and warnings == 0 and",
             "    if a.setting.autoDismissOnSuccess and errors == 0 and")],
     [(VMU, None), (TBL, TBL_REVEAL)],
     "§3.8: a success with warnings puts the pane away"),
    ("A7", [(REVEAL, "  a.pinned = true", "  discard")],
     [(VMU, None), (TBL, TBL_REVEAL)],
     "§3.8: a touch does not pin the revealed pane"),
    ("A8", [(REVEAL, "  of bsFailed:\n    a.dismissAtMs = 0.0\n    if a.setting.autoReveal:",
             "  of bsFailed:\n    a.dismissAtMs = 0.0\n    if false:")],
     [(VMU, None), (TBL, TBL_REVEAL)],
     "§3.8: a failed build reveals nothing"),
    ("A9", [(DIAG, "  if runes[a].isWordRune:", "  if false:")],
     [(VMU, None), (TBL, TBL_EDIT)],
     "§3.9: a squiggle covers one character, not the word"),
    ("A10", [(DIAG, "    if not sameFile(p.path, workingDirectory, filePath, projectDir):",
              "    if false:")],
     [(VMU, None), (TBL, TBL_EDIT)],
     "§3.9: every file shows every file's diagnostics"),
    ("A11", [(DIAG, "    if d.line == line and rank(d.severity) > rank(result):",
              "    if d.line == line and rank(d.severity) >= 0:")],
     [(VMU, None), (TBL, TBL_EDIT)],
     "§3.9: the gutter shows the last diagnostic, not the most severe"),
    ("A12", [(VM, "  if vm.diagnosticsOff:", "  if false:")],
     [(VMU, None), (TBL, TBL_CMDS)],
     "§3.6: `problemMatcher: none` still makes Problems rows"),
    ("A13", [(OMNI, "  if lower.startsWith(BuildTaskPrefix):", "  if false:")],
     [(VMU, None), (TBL, TBL_PICKER)],
     "§3.11: `:build: ` is not the task picker"),
    # ---- the terminal --------------------------------------------------------
    ("T1", [(RUNTIME, '  of "build.run":', '  of "build.run-disabled":')],
     [(TBL, TBL_PICKER), (PTY, None)],
     "§3.11: Ctrl+Shift+B opens nothing"),
    ("T2", [(RUNTIME, "  if mode == omBuildTask:", "  if false:")],
     [(TBL, TBL_PICKER)],
     "§3.11: the picker's choice is not run"),
    ("T3", [(RUNTIME, "    if parseBuildVerb(text).kind in {bvkRunTask, bvkPick, bvkStop, bvkClear,",
             "    if parseBuildVerb(text).kind in {bvkPick, bvkStop, bvkClear,")],
     [(TBL, TBL_CMDS)],
     "§3.12: `:build: <task>` typed runs nothing"),
    ("T4", [(SOURCE, "  if s.reveal.due(now) == brsDismiss:", "  if false:")],
     [(TBL, TBL_REVEAL)],
     "§3.8: the terminal never puts the pane away"),
    ("T5", [(SOURCE, "    s.reveal.interact()", "    discard")],
     [(TBL, TBL_REVEAL)],
     "§3.8: the terminal's wheel does not pin the pane"),
    ("T6", [(SOURCE, "    rt.app.buildDiagnostics = s.problems.problems.vm.problems.val",
             "    discard")],
     [(TBL, TBL_EDIT), (PTY, None)],
     "§3.9: the Edit pane is handed no diagnostics"),
    ("T7", [(EDIT_PANE, "                          o.underline = true",
             "                          discard")],
     [(TBL, TBL_EDIT), (PTY, None)],
     "§3.9: the span is not underlined"),
    ("T8", [(EDIT_PANE, "      if pointerCol < area.col + gw:", "      if false:")],
     [(TBL, TBL_EDIT), (PTY, None)],
     "§3.9: the gutter shows no diagnostic icon"),
    ("T9", [(RUNTIME, "      if over.text.len > 0:", "      if false:")],
     [(TBL, TBL_EDIT), (PTY, None)],
     "§3.9: the pointer's hover says nothing"),
    ("T10", [(READER, "                       problemMatcher = session.problemMatcher)",
              '                       problemMatcher = "")')],
     [(TBL, TBL_CMDS)],
     "§3.6: the terminal ignores a task's problem matcher"),
    ("T11", [(RUNTIME, "      rt.revealProblemsPane()", "      discard")],
     [(TBL, TBL_REVEAL)],
     "§3.8: a failed build does not reveal Problems where Build Output is docked"),
    # ---- the GPUI window -----------------------------------------------------
    ("G1", [(GPUI_MAIN, '  of "build.run":', '  of "build.run-disabled":')],
     [(PLAN, None)],
     "§3.11: GPUI's Ctrl+Shift+B opens nothing"),
    ("G2", [(GPUI_MAIN, "  if res.kind == erOperation and res.operation in EditWindowRoutedOperations:",
             "  if false:")],
     [(PLAN, None)],
     "the Edit window's keys never reach the window"),
    ("G3", [(GPUI_MAIN, "  if not gProblems.isNil and gEditorSurface.path.len > 0:",
             "  if false:")],
     [(PLAN, None)],
     "§3.9: GPUI's editor is handed no diagnostics"),
    ("G4", [(GPUI_MAIN, "    if d.line == line and col - 1 >= d.fromColumn and col - 1 < d.toColumn:",
             "    if false:")],
     [(PLAN, None)],
     "§3.9: GPUI's hover says nothing"),
    ("G5", [(GPUI_MAIN, "  if gBuildReveal.due(now) == brsDismiss and",
             "  if false and")],
     [(PLAN, None)],
     "§3.8: GPUI never puts the pane away"),
    ("G6", [(GPUI_MAIN, "       layout.dockedIndex(paneProblems) >= 0:", "       false:")],
     [(PLAN, None)],
     "§3.8: GPUI's failed build reveals no Problems"),
    ("G7", [(GPUI_LEAVES, '      r.setStyle(band, "background", colourOf(d.severity))',
             "      discard")],
     [(PLAN, None)],
     "§3.9: GPUI's squiggle has no colour"),
    ("G8", [(GPUI_LEAVES, "        r.appendChild(lane, r.createTextNode(gutterIcon(diagnostics, row.line)))",
             "        discard")],
     [(PLAN, None)],
     "§3.9: GPUI's gutter draws no diagnostic icon"),
    ("G9", [(GPUI_MAIN, "  drawOmnibarResults(r)", "  discard")],
     [(PLAN, None)],
     "§3.11: the Edit window's picker lists nothing"),
    # ---- the desktop ---------------------------------------------------------
    ("D1", [(RUNNER, "      send('CODETRACER::build-code', {code: exit, cancelled: !!g.cancelled,",
             "      send('CODETRACER::build-code', {code: exit, cancelled: false,")],
     [(SPEC, None)],
     "§3.2: a stopped desktop build is reported failed"),
    ("D2", [(DESKTOP_BUILD, '  data.ipc.send cstring"CODETRACER::build-cancel", js{}',
             "  discard")],
     [(SPEC, None)],
     "§3.2: the desktop's Stop stops nothing"),
    ("D3", [(DESKTOP_BUILD, "    setBuildModelMarkers(monacoEditor, cstring(BuildDiagnosticsOwner), markers)",
             "    discard")],
     [(SPEC, None)],
     "§3.9: Monaco shows no squiggle"),
    ("D4", [(DESKTOP_BUILD, "    buildMarkDecorations[name] = buildDeltaDecorations(monacoEditor, old, glyphs)",
             "    discard")],
     [(SPEC, None)],
     "§3.9: Monaco's gutter shows no diagnostic icon"),
    ("D5", [(DESKTOP_PALETTE, "    self.results = buildTaskResults($value)",
             "    self.results = @[]")],
     [(SPEC, None)],
     "§3.11: the desktop's picker lists no task"),
    ("D6", [(DESKTOP_BUILD, "    elif buildReveal.pending:", "    elif false:")],
     [(SPEC, None)],
     "§3.8: the desktop never puts the panel away"),
    ("D7", [(DESKTOP_UI, '    discard build.runDesktopBuildLine(":build:"),',
             '    discard build.runDesktopBuildLine(":build: history"),')],
     [(SPEC, None)],
     "§3.11: the desktop's Ctrl+Shift+B opens no picker"),
    ("D8", [(DESKTOP_UI, "        vm.cancelBuildProc = proc() = discard build.stopDesktopBuild()",
             "        discard")],
     [(SPEC, None)],
     "§3.2: the BUILD panel's ■ reaches no runner"),
    # ---- the declared survivor ----------------------------------------------
    ("Z1", [(TASKS, "## Pure Nim: no filesystem, no process. C and JavaScript backends.",
             "## Pure Nim: no filesystem, no process. C and JavaScript backends. ")],
     [(VMU, None)],
     "behaviour-preserving: the DECLARED SURVIVOR (a comment's trailing space)"),
]

DECLARED_SURVIVORS = {"Z1"}

IN_BINARY = {TASKS, REVEAL, DIAG, VM, OMNI, RUNTIME, SOURCE, READER, EDIT_PANE}
IN_GPUI = {TASKS, REVEAL, DIAG, VM, OMNI, READER, GPUI_MAIN, GPUI_LEAVES}
IN_DESKTOP = {TASKS, REVEAL, DIAG, VM, OMNI, RUNNER, DESKTOP_BUILD,
              DESKTOP_PALETTE, DESKTOP_UI}
PTY_SUITES = {PTY}
GPUI_SUITES = {PLAN}
DESKTOP_SUITES = {SPEC}


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
        f.write("# Control digests for run-build-residuals-mutations.py —\n"
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
            backups[rel] = path.with_name(path.name + ".residualsbak")
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
