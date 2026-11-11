#!/usr/bin/env python3
"""PLAT-61 — the mutation harness for the Shell pane on every front-end
(codetracer-pm `spec/Planned-Features/CodeTracer-Shell.md` §7): the shared
model (`shell_vm` — its keys, prefix, actions, marks, rows, words and press),
the live emulator (`terminal_output_model` — ONCLR off, kept lines, `ED 3`,
the OSC strings, the resize), the session (`common/shell_session` — its
environment and its ordering rule), `ct record`'s report and action marks,
`ct shell-session`, the native host, the terminal's painter, runtime, host
and loop, the GPUI leaf and window, the vocabulary view, and the desktop's
view, pane, key router and main-process relay.

Each arm plants ONE defect; REBUILDS the shipped `codetracer-tui` /
`codetracer-gpui` / `ct` and the desktop when the defect is compiled into
what an arm is graded through; runs the suites that must catch it; and
requires RED — with the failure the first run recorded
(`plat61-shell-mutation-because.json`, derived with `--derive`).

The discipline is PLAT-58's harness's (`run-plat58-requests-mutations.py`),
clause for clause: committed control digests over subjects AND suites (§16c),
a needle scan that gates re-recording (§39a), `because` derived from a run,
rc 124 is a hang (§1), per-arm restore verification, and
`ci/lib/harness_guard.py`'s argument rule before anything is touched.

The builds run `$PLAT61_BUILD_TUI` / `$PLAT61_BUILD_GPUI` /
`$PLAT61_BUILD_DESKTOP` when set, else `just build-tui` / `just build-gpui` /
`just build-once` (which also builds `ct`, whose `ct record` and
`ct shell-session` the suites run). The desktop's arms are graded by the
Electron capture (`scripts/plat61-capture-electron.sh`, or
`$PLAT61_DESKTOP_TEST`; a DISPLAY or Xvfb is needed), whose answers file is
restored after every run. The Nim suites run a real `replay-server`
(`REPLAY_SERVER_BIN`) on the `calc` fixture and a real bash on a real pty.

Usage:
    run-plat61-shell-mutations.py [--only V1,T1] [--derive]
    run-plat61-shell-mutations.py --needle-scan
    run-plat61-shell-mutations.py --record-control-hashes
"""
import argparse
import hashlib
import json
import os
import re
import shutil
import signal
import subprocess
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[4]
HERE = Path(__file__).resolve().parent
CONTROL = HERE / "plat61-shell-mutation-control.sha256"
BECAUSE = HERE / "plat61-shell-mutation-because.json"
NIMCACHE = Path(os.environ.get("CT_NIM_CACHE_ROOT",
                               os.environ.get("TMPDIR", "/tmp"))) / \
    "plat61-mutations"
BIN = REPO / "build/bin/codetracer-tui"
GPUI_BIN = REPO / "build/bin/codetracer-gpui"
TIMEOUT = 3600

# Subjects.
VM = "src/frontend/viewmodel/viewmodels/shell_vm.nim"
EMU = "src/frontend/viewmodel/viewmodels/terminal_output_model.nim"
SESSION = "src/common/shell_session.nim"
INDEX_DB = "src/common/trace_index.nim"
RECORD = "src/ct/db_backend_record.nim"
TRACE_SHELL = "src/ct/trace/shell.nim"
CT_SESSION = "src/ct/shell_session_command.nim"
HOST = "src/frontend/viewmodel/host/native_shell_host.nim"
TUI_PANE = "src/frontend/tui/app/views/shell_session_pane.nim"
RUNTIME = "src/frontend/tui/app/runtime.nim"
PROFILE = "src/frontend/tui/app/layout/profile.nim"
TUI_SESSION = "src/frontend/tui/host/tui_session.nim"
TUI_MAIN = "src/frontend/tui/main.nim"
GPUI_LEAF = "src/frontend/gpui/shell_leaf.nim"
GPUI_MAIN = "src/frontend/gpui/main.nim"
VOCAB = "src/frontend/view_vocabulary/pane_views.nim"
DESKTOP_VIEW = "src/frontend/viewmodel/views/isonim_shell_view.nim"
DESKTOP_PANE = "src/frontend/ui/shell.nim"
KEY_ROUTER = "src/frontend/ui/key_router.nim"
RELAY = "src/frontend/index/shell_sessions.nim"

# Suites and consumed capture inputs.
VMU = "src/frontend/viewmodel/tests/unit/test_plat61_shell.nim"
TBL = "src/frontend/tui/tests/test_plat61_shell.nim"
COVER = "src/frontend/tui/tests/test_plat41_pane_coverage.nim"
PTY = "src/frontend/tui/tests/real_terminal/test_plat61_shell_pty.nim"
PLAN = "src/frontend/gpui/tests/test_plat61_gpui_shell.nim"
SPEC = "src/tests/gui/tests/shell/plat61-shell-capture.spec.ts"
ANSWERS = "src/tests/visual/answers/plat61-shell.electron.json"
CAPTURE = "scripts/plat61-capture-electron.sh"

SUBJECTS = [VM, EMU, SESSION, INDEX_DB, RECORD, TRACE_SHELL, CT_SESSION, HOST,
            TUI_PANE, RUNTIME, PROFILE, TUI_SESSION, TUI_MAIN, GPUI_LEAF,
            GPUI_MAIN, VOCAB, DESKTOP_VIEW, DESKTOP_PANE, KEY_ROUTER, RELAY]
SUITES = [VMU, TBL, COVER, PTY, PLAN, SPEC, ANSWERS, CAPTURE]

# (id, [(subject, find, replace), ...], [(suite, filter), ...], what it breaks)
ARMS = [
    # ---- the shared model ------------------------------------------------------
    ("V1", [(VM, '  of "Enter", "Return": result = "\\r"',
             '  of "Enter", "Return": result = "\\n"')],
     [(VMU, None)],
     "§7.5: Enter sends LF, not CR as xterm does"),
    ("V2", [(VM, '  elif app: "\\eO" & final', '  elif false: "\\eO" & final')],
     [(VMU, None)],
     "§7.5: the cursor keys ignore DECCKM's application mode"),
    ("V3", [(VM, "  if k.isPrefix:\n    vm.prefixArmed = true",
             "  if false:\n    vm.prefixArmed = true")],
     [(VMU, None), (TBL, None)],
     "§7.5: the prefix never arms; CodeTracer's keys are unreachable"),
    ("V4", [(VM, "      return ShellKeyRoute(kind: skrShell, bytes: ShellPrefixByte)",
             "      return ShellKeyRoute(kind: skrApp)")],
     [(VMU, None)],
     "§7.5: the prefix twice does not send Ctrl+] to the shell"),
    ("V5", [(VM, "      of 'a'..'z': t = $chr(ord(c) - ord('a') + 1)",
             "      of 'a'..'z': discard")],
     [(VMU, None), (TBL, None)],
     "§7.5: Ctrl+letter sends the letter (Ctrl+C does not interrupt)"),
    ("V6", [(VM, "    a.firstLine = line", "    a.firstLine = line + 1")],
     [(VMU, None), (TBL, None), (PLAN, None)],
     "§7.4: an action starts one line below its mark"),
    ("V7", [(VM, "  if col == 0 and last > first:\n    dec last",
             "  if false:\n    dec last")],
     [(VMU, None), (TBL, None), (PLAN, None)],
     "§7.4: a settled action takes in the fresh line after its output"),
    ("V8", [(VM, "    if parseActionMark(o.payload, o.line, o.col, m):",
             "    if false and parseActionMark(o.payload, o.line, o.col, m):")],
     [(VMU, None), (TBL, None)],
     "§7.4: the output's action marks are ignored"),
    ("V9", [(VM, "    (a.firstLine, max(a.firstLine, vm.cursorLine))",
             "    (a.firstLine, a.firstLine)")],
     [(VMU, None)],
     "§7.1: a running action does not follow the cursor"),
    ("V10", [(VM, "  if a.kind == sakRecord and a.status == sasOk and",
              "  if a.kind == sakRecord and a.status == sasWorking and")],
     [(VMU, None), (TBL, None), (PLAN, None)],
     "§7.6: a press on a settled recording does not open it"),
    ("V11", [(VM, '  of sasOk: (if ascii: "*" else: "●")',
              '  of sasOk: (if ascii: "*" else: "*")')],
     [(VMU, None), (PLAN, None)],
     "§7.5: a recording's glyph is not the model's"),
    ("V12", [(VM, '      "recorded command: " & a.command & " — recording " & shortId(a.recordingId)',
              '      "recorded command: " & a.command')],
     [(VMU, None), (TBL, None)],
     "§7.1: a recording's words do not name it"),
    ("V13", [(VM, '    if n == 0: "running"', '    if true: "running"')],
     [(VMU, None), (TBL, None), (PLAN, None)],
     "§7.1: the state words do not count the recordings"),
    ("V14", [(VM, "  if vm.scrollTop.val != -1:\n    vm.scrollTop.val = -1",
              "  if false:\n    vm.scrollTop.val = -1")],
     [(VMU, None), (TBL, None)],
     "§7.5: typing does not return the view to the tail"),
    ("V15", [(VM, "  if vm.scrollTop.val < 0: maxTop", "  if vm.scrollTop.val < 0: 0")],
     [(VMU, None), (TBL, None)],
     "§7.5: the view does not follow the tail"),
    ("V16", [(VM, "  let why = vm.host.start(max(1, cols), max(1, rows))",
              "  let why = vm.host.start(80, 24)")],
     [(VMU, None), (TBL, None)],
     "§7.2: the shell does not start at the pane's size"),
    ("V17", [(VM, "    vm.host.resize(cols, rows)", "    discard")],
     [(VMU, None), (TBL, None)],
     "§7.2: the shell is not resized with the pane"),
    ("V18", [(VM, "       vm.state.val == sssRunning: vm.screen.col",
              "       true: vm.screen.col")],
     [(VMU, None)],
     "§7.5: an exited shell still draws its cursor"),
    ("V19", [(VM, '                                         ("OkStatus", sasOk),',
              '                                         ("OkStatus", sasWorking),')],
     [(VMU, None), (TBL, None), (PLAN, None)],
     "§7.3: an OkStatus report is read as still working"),
    # ---- the live emulator ---------------------------------------------------------
    ("E1", [(EMU, "    if s.onlcr:\n      s.col = 0", "    if true:\n      s.col = 0")],
     [(VMU, None)],
     "§7.1: a live line feed returns the carriage (ONLCR applied twice)"),
    ("E2", [(EMU, "  for r in 0 ..< n:\n    s.scrollback.add s.primary[r * s.cols ..< (r + 1) * s.cols]",
             "  for r in 0 ..< 0:\n    s.scrollback.add s.primary[r * s.cols ..< (r + 1) * s.cols]")],
     [(VMU, None), (TBL, None)],
     "§7.1: lines that scroll off the top are not kept"),
    ("E3", [(EMU, "      s.scrollback.setLen(0)", "      discard")],
     [(VMU, None)],
     "§7.1: ED 3 does not drop the kept lines"),
    ("E4", [(EMU, "      if c == '\\x07':\n        result.add AnsiToken(kind: atEsc, ch: ']', text: sc.osc)",
             "      if c == '\\x07':\n        discard")],
     [(VMU, None), (TBL, None)],
     "§7.4: a BEL-ended OSC string (the action mark) is never surfaced"),
    ("E5", [(EMU, "  let drop = max(0, s.row - (rows - 1))", "  let drop = 0")],
     [(VMU, None)],
     "§7.1: a shorter screen loses the cursor's row"),
    # ---- the session ------------------------------------------------------------------
    ("S1", [(SESSION, "  let alive = s.drainOutput(if lines.len > 0: 0 else: timeoutMs, result)\n  addEvents(lines, result)",
             "  addEvents(lines, result)\n  let alive = s.drainOutput(if lines.len > 0: 0 else: timeoutMs, result)")],
     [(TBL, None)],
     "§7.2: an event overtakes the output written before it"),
    ("S2", [(SESSION, '  env.add ("CODETRACER_SHELL_REPORT_FILE", report)',
             '  discard report')],
     [(TBL, None), (PLAN, None)],
     "§7.2: the shell's commands have no report channel"),
    ("S3", [(SESSION, "    s.pty.setWindowSize(max(1, cols), max(1, rows))", "    discard")],
     [(TBL, None)],
     "§7.2: a resize never reaches the pty"),
    # ---- ct record / ct shell-session -----------------------------------------------
    ("R1", [(RECORD, '        markShellTerminal(actionId, "ok")', '        discard')],
     [(TBL, None)],
     "§7.4: no mark ends a recording's lines (the id line is taken in)"),
    ("R2", [(RECORD, '  let command = (@[program] & recordArgs).join(" ")',
             '  let command = args.join(" ")')],
     [(TBL, None), (PLAN, None)],
     "§7.3: the command is named by the recorder's options"),
    ("R3", [(INDEX_DB, "    appendReportLine(reportFile, $sessionEventJson(event))",
             "    discard reportFile")],
     [(TBL, None), (PLAN, None)],
     "§7.3: `ct record` writes nothing on the report file"),
    ("R4", [(INDEX_DB, '        "outputFolder": event.trace.outputFolder,',
             '        "outputFolder": "",')],
     [(TBL, None), (PLAN, None)],
     "§7.3: a recording's report does not say where it is"),
    ("R5", [(TRACE_SHELL, "  if sessionId == -1 or not fileExists(sessionLogPath):",
             "  if sessionId == -1:"),
            (TRACE_SHELL, "  except CatchableError:\n    NO_LINE",
             "  except ValueError:\n    NO_LINE")],
     [(TBL, None)],
     "§7.4: `ct record` in a session fails on the line file the pane never writes"),
    ("C1", [(CT_SESSION, '          session.sendInput(decode(msg["input"].getStr))',
             '          session.sendInput(msg["input"].getStr)')],
     [(SPEC, None)],
     "§7.2: the desktop's typed keys reach the shell still base64"),
    # ---- the native host and the terminal ------------------------------------------------
    ("N1", [(HOST, "    openFolder(a.traceFolder)", "    openFolder(a.recordingId)")],
     [(TBL, None), (PLAN, None)],
     "§7.6: the terminal and the window open the recording's id as a folder"),
    ("N2", [(HOST, "  result.shellCommandFromEnv()", "  discard")],
     [(TBL, None)],
     "§7.2: CODETRACER_SHELL_COMMAND is ignored"),
    ("T1", [(TUI_PANE, "    of stOk: grShellOk", "    of stOk: grShellError")],
     [(TBL, None)],
     "§7.5: a recording's gutter shows the failure glyph"),
    ("T2", [(TUI_PANE, "  of stOk: CellStyle(role: srChromeSuccess)",
             "  of stOk: CellStyle(role: srChromeError)")],
     [(TBL, None)],
     "§7.5: a recording's gutter is in the error colour"),
    ("T3", [(TUI_PANE, "  if col < geo.textCol and r.mark != srmNone:",
             "  if col < geo.gutterCol and r.mark != srmNone:")],
     [(TBL, None), (PTY, None)],
     "§7.6: a press on the gutter is read as a press on the text"),
    ("T4", [(RUNTIME, "  had and focused == paneShell and rt.app.shellPane.loaded and",
             "  false and focused == paneShell and rt.app.shellPane.loaded and")],
     [(TBL, None), (PTY, None)],
     "§7.5: the focused shell gets no keys"),
    ("T5", [(RUNTIME, "  not rt.actOnShell(act, outcome).toApp",
             "  discard rt.actOnShell(act, outcome)\n  true")],
     [(TBL, None)],
     "§7.5: after the prefix the key is swallowed, not CodeTracer's"),
    ("T6", [(TUI_SESSION, "    vm.scrollShell(act.delta, vm.screen.rows)",
             "    vm.scrollShell(-act.delta, vm.screen.rows)")],
     [(TBL, None)],
     "§7.5: the wheel scrolls the wrong way"),
    ("T7", [(TUI_SESSION, "    if vm.state.val == sssIdle:\n      vm.startShell(cols, rows)",
             "    if vm.state.val == sssIdle:\n      vm.startShell(cols + 7, rows)")],
     [(TBL, None)],
     "§7.2: the terminal's shell does not start at the pane's size"),
    ("T8", [(PROFILE, "     paneShell,", "     ")],
     [(TBL, None), (PTY, None)],
     "the terminal draws the Shell pane as a report leaf again"),
    ("T9", [(TUI_MAIN, "  app.shellAct = proc(act: ShellAct): ShellActResult =\n    session.shellAct(rt, act)",
             "  app.shellAct = proc(act: ShellAct): ShellActResult =\n    ShellActResult()")],
     [(PTY, None)],
     "the shipped terminal does not hand the pane's acts to its host"),
    ("T10", [(TUI_MAIN, "      let shellChanged = session.pumpShell(rt)",
              "      let shellChanged = false")],
     [(PTY, None)],
     "the shipped terminal never pumps the pane's shell"),
    ("T11", [(RUNTIME, '    if words.len == 1 and words[0] == "shell":',
              '    if words.len == 1 and words[0] == "shells":')],
     [(TBL, None), (PTY, None)],
     "§7.5: `:shell` does not show the pane"),
    # ---- the GPUI window ------------------------------------------------------------------
    ("G1", [(GPUI_LEAF, "    DesignTokenHex[dtColorsUiTextSuccessPrimary][dmDark],",
             "    DesignTokenHex[dtColorsUiTextWarningPrimary][dmDark],")],
     [(PLAN, None)],
     "§7.5: the window's recording gutter is not the desktop's colour"),
    ("G2", [(GPUI_MAIN, "  if vm.isNil or gFocusPane != $paneShell or vm.state.val != sssRunning:",
             "  if true:")],
     [(PLAN, None)],
     "§7.5: the window's focused shell gets no keys"),
    ("G3", [(GPUI_MAIN, "    let note = vm.activateAction(hit.action)",
             "    let note = \"\"")],
     [(PLAN, None)],
     "§7.6: a press on the window's gutter opens nothing"),
    ("G4", [(GPUI_MAIN, "      vm.startShell(lay.cols, lay.rows)", "      discard")],
     [(PLAN, None)],
     "§7.2: the window never starts the pane's shell"),
    ("VC1", [(VOCAB, "  if vm.state.val == sssIdle and vm.revision.val == 0:",
              "  if vm.state.val == sssIdle:")],
     [(COVER, None)],
     "§7.5: the vocabulary calls a shell with output not started"),
    # ---- the desktop -------------------------------------------------------------------------
    ("D1", [(DESKTOP_VIEW, "  of srmRange: actionBar()", '  of srmRange: " "')],
     [(SPEC, None)],
     "§7.5: the desktop draws no bar on a recording's later lines"),
    ("D2", [(DESKTOP_PANE, "    vm.startShell(cols, rows)", "    discard")],
     [(SPEC, None)],
     "§7.7: the desktop never starts the pane's shell"),
    ("D3", [(KEY_ROUTER, "  if not paneKeyOwner.isNil and paneKeyOwner(ev):\n    return",
             "  if false:\n    return")],
     [(SPEC, None)],
     "§7.5: the desktop's router takes the shell's keys"),
    ("D4", [(RELAY, "        sendMessage(id, cstring(line))", "        discard line")],
     [(SPEC, None)],
     "§7.2: the main process relays nothing the shell wrote"),
    ("D5", [(DESKTOP_PANE, '    data.ipc.send "CODETRACER::open-trace-in-tab", js{traceId: traceId}',
             '    discard traceId')],
     [(SPEC, None)],
     "§7.6: a press on the desktop's gutter opens no tab"),
    ("D6", [(DESKTOP_VIEW, '        r.addEventListener(gutter, "click", activateOnClick(vm, row.action))',
             '        discard')],
     [(SPEC, None)],
     "§7.6: the desktop's gutter hears no press"),
]

DECLARED_SURVIVORS = {"T7"}
  # T7 — the terminal starting its shell 7 columns wider than the pane: the
  # same refresh's next pass (and every later one) resizes the pty to the
  # pane before the shell has drawn a line (`tui_session.refreshShell`), so no
  # suite can see a frame at the wrong width. Kept as an arm so a change that
  # stops the resize turns it RED (MISDIRECTED).

IN_BINARY = {VM, EMU, SESSION, HOST, TUI_PANE, RUNTIME, PROFILE,
             TUI_SESSION, TUI_MAIN, VOCAB}
  # Subjects compiled into `codetracer-tui`.
IN_GPUI = {VM, EMU, SESSION, HOST, GPUI_LEAF, GPUI_MAIN, VOCAB}
  # Subjects compiled into `codetracer-gpui`.
IN_CT = {SESSION, INDEX_DB, RECORD, TRACE_SHELL, CT_SESSION}
  # Subjects compiled into `ct` / `db-backend-record` (`just build-once`),
  # which every suite's shell runs.
PTY_SUITES = {PTY}
GPUI_SUITES = {PLAN}
RUST_SUITES = set()
DESKTOP_SUITES = {SPEC}
IN_DESKTOP = {VM, EMU, DESKTOP_VIEW, DESKTOP_PANE, KEY_ROUTER, RELAY}
  # Subjects compiled into the desktop's bundle and main process.


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
        f.write("# Control digests for run-plat61-shell-mutations.py — the\n"
                "# subjects, suites and capture inputs the arms are graded by (§16c).\n"
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
    recorded = set()
    for line in CONTROL.read_text().splitlines():
        if not line or line.startswith("#"):
            continue
        digest, rel = line.split("  ", 1)
        recorded.add(rel)
        if sha(rel) != digest:
            print(f"CONTROL DIGEST MOVED: {rel}")
            ok = False
    for rel in set(SUBJECTS + SUITES) - recorded:
        print(f"CONTROL DIGEST ABSENT: {rel}")
        ok = False
    return ok


def run_group(argv, **kw):
    """`subprocess.run(argv, timeout=TIMEOUT, **kw)` in a session of its own,
    whose whole process group is killed when the run ends. A suite outlives
    its own runner otherwise: on a timeout `subprocess.run` kills only the
    process it started (`nim c -r`, `bash`), and the compiled suite and the
    `codetracer-gpui` it drives stay behind, hung, for as long as the host is
    up (three of them, 11-15 hours old, measured 2026-11-10). Raises
    `subprocess.TimeoutExpired` as `subprocess.run` does."""
    proc = subprocess.Popen(argv, start_new_session=True, **kw)
    try:
        out, err = proc.communicate(timeout=TIMEOUT)
    except BaseException:
        try:
            os.killpg(proc.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        proc.communicate()
        raise
    # A suite that exits leaves nothing running either: anything it left
    # in its group would hold the next arm's pty, port or window.
    try:
        os.killpg(proc.pid, signal.SIGKILL)
    except ProcessLookupError:
        pass
    return subprocess.CompletedProcess(argv, proc.returncode, out, err)


def build_with(env_var, recipe):
    cmd = os.environ.get(env_var)
    argv = ["bash", "-c", cmd] if cmd else ["just", recipe]
    p = subprocess.run(argv, cwd=REPO, capture_output=True, text=True,
                       timeout=TIMEOUT)
    if p.returncode != 0:
        print((p.stdout + p.stderr)[-2000:])
    return p.returncode == 0


def build_binary():
    return build_with("PLAT61_BUILD_TUI", "build-tui")


def build_gpui():
    return build_with("PLAT61_BUILD_GPUI", "build-gpui")


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


def run_rust(suite):
    """The engine's suite: GREEN on rc 0, else RED on its first panic."""
    cmd = os.environ.get("PLAT61_CARGO_TEST")
    argv = ["bash", "-c", cmd] if cmd else \
        ["cargo", "test", "--test", Path(suite).stem]
    cwd = REPO if cmd else REPO / "src/db-backend"
    try:
        p = run_group(argv, cwd=cwd, stdout=subprocess.PIPE,
                      stderr=subprocess.PIPE, text=True)
    except subprocess.TimeoutExpired:
        return "HUNG", []
    out = (p.stdout or "") + (p.stderr or "")
    if p.returncode == 0:
        return ("GREEN", []) if " passed" in out else ("RAN-NOTHING", [])
    if "error[" in out and "test result" not in out:
        return "DID-NOT-COMPILE", []
    first = [ln.strip() for ln in out.splitlines()
             if "panicked at" in ln or ln.strip().startswith("ct/seek")][:1]
    first = [re.sub(r":\d+:\d+:", "", f) for f in first]
    # Rust's panic line names the OS thread id (`thread 'name' (1234)
    # panicked`), which differs on every run; drop it as plat70f's does.
    first = [re.sub(r"^thread '([^']*)' \(\d+\) ", r"thread '\1' ", f)
             for f in first]
    return "RED", first


def run_spec(suite):
    """The Electron capture: GREEN on rc 0, else RED on its first expectation.
    It rewrites the answers file the native suites read, so the file is put
    back whatever the run did."""
    cmd = os.environ.get("PLAT61_DESKTOP_TEST")
    argv = ["bash", "-c", cmd] if cmd else \
        ["bash", CAPTURE]
    saved = path_of(ANSWERS).read_bytes()
    try:
        p = run_group(argv, cwd=REPO, stdout=subprocess.PIPE,
                      stderr=subprocess.PIPE, text=True)
    except subprocess.TimeoutExpired:
        return "HUNG", []
    finally:
        path_of(ANSWERS).write_bytes(saved)
    out = (p.stdout or "") + (p.stderr or "")
    if p.returncode == 0:
        return ("GREEN", []) if " passed" in out else ("RAN-NOTHING", [])
    plain = re.sub(r"\x1b\[[0-9;]*m", "", out)
    first = [ln.strip() for ln in plain.splitlines()
             if ln.strip().startswith(("Error:", "Expected:", "Received:"))][:2]
    return "RED", [" / ".join(first)] if first else []


def build_desktop():
    return build_with("PLAT61_BUILD_DESKTOP", "build-once")


def output_order_failures(out):
    """Keep the first concrete failure before its later assertion-count fallout.

    The GPUI child reports its failed action before the suite raises a wrapper
    exception containing temporary paths. Preserve that child's stable reason.
    """
    markers = ("Check failed: ", "Unhandled exception: ",
               "codetracer-gpui: --window-ops: ")
    failures = []
    for line in out.splitlines():
        # TBL's fail()+return reports its wait checkpoint before later checks.
        soft_wait = re.match(
            r"^\s*(waited [0-9]+ ms for \S(?:.*?\S)?); the pane shows:\s*$", line)
        if soft_wait:
            failures.append(soft_wait.group(1))
            continue
        hits = [(line.find(marker), marker) for marker in markers if marker in line]
        if hits:
            at, marker = min(hits)
            failures.append(portable_cause(line[at + len(marker):].strip()))
    return failures


def run_suite(suite, test_filter):
    if suite in RUST_SUITES:
        return run_rust(suite)
    if suite in DESKTOP_SUITES:
        return run_spec(suite)
    NIMCACHE.mkdir(parents=True, exist_ok=True)
    stem = Path(suite).stem
    env = dict(os.environ, CODETRACER_REPO_ROOT=str(REPO))
    cmd = ["nim", "c", "-r", "--hints:off", "--warnings:off",
           f"--nimcache:{NIMCACHE}/{stem}",
           f"-o:{NIMCACHE}/{stem}.out"] + suite_flags(suite) + [suite]
    if test_filter:
        cmd.append(test_filter)
    try:
        p = run_group(cmd, cwd=REPO, stdout=subprocess.PIPE,
                      stderr=subprocess.STDOUT, text=True, env=env)
    except subprocess.TimeoutExpired:
        return "HUNG", []
    out = (p.stdout or "") + (p.stderr or "")
    if p.returncode == 124:
        return "HUNG", []
    failures = output_order_failures(out)
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
    try:
        because = json.loads(BECAUSE.read_text()) if BECAUSE.exists() else {}
    except (OSError, ValueError) as error:
        print(f"CAUSE MAP INVALID: {error}")
        return 3
    if not isinstance(because, dict):
        print("CAUSE MAP INVALID: expected an object of measured failure strings")
        return 3
    missing = [arm[0] for arm in selected if arm[0] not in DECLARED_SURVIVORS and
               (not isinstance(because.get(arm[0]), str) or not because[arm[0]].strip())]
    if missing and not a.derive:
        print(f"CAUSE PINS MISSING OR INVALID: {', '.join(missing)}; derive real failures first")
        return 3
    needs_binary = any(s in PTY_SUITES for arm in selected for s, _ in arm[2])
    needs_gpui = any(s in GPUI_SUITES for arm in selected for s, _ in arm[2])
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
    needs_desktop = any(s in DESKTOP_SUITES for arm in selected
                        for s, _ in arm[2])
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
    digests = {rel: sha(rel) for rel in SUBJECTS}
    derived, bad = {}, []
    for arm_id, edits, suites, what in selected:
        files = sorted({rel for rel, _, _ in edits})
        backups = {}
        dirty = set()
        for rel in files:
            path = path_of(rel)
            backups[rel] = path.with_name(path.name + ".plat61bak")
            shutil.copy2(path, backups[rel])
        try:
            for rel, find, replace in edits:
                path = path_of(rel)
                path.write_text(path.read_text().replace(find, replace, 1))
            built = True
            # What this arm builds from the mutated tree, rebuilt from the
            # restored one below — so no later arm is graded through it.
            if any(r in IN_CT for r in files) or (
                    any(s in DESKTOP_SUITES for s, _ in suites) and
                    any(r in IN_DESKTOP for r in files)):
                dirty.add("desktop")
                built = build_desktop()
            if built and any(s in PTY_SUITES for s, _ in suites) and \
                    any(r in IN_BINARY for r in files):
                dirty.add("tui")
                built = build_binary()
            if built and any(s in GPUI_SUITES for s, _ in suites) and \
                    any(r in IN_GPUI for r in files):
                dirty.add("gpui")
                built = build_gpui()
            verdict, first = grade(suites) if built else ("DID-NOT-COMPILE", "")
        finally:
            for rel in files:
                shutil.move(backups[rel], path_of(rel))
                if sha(rel) != digests[rel]:
                    print(f"ABORT: restore of {rel} failed after {arm_id}.")
                    return 1
            for art in sorted(dirty):
                ok_build = {"desktop": build_desktop, "tui": build_binary,
                            "gpui": build_gpui}[art]()
                if not ok_build:
                    print(f"ABORT: the {art} build from the restored tree "
                          f"failed after {arm_id}.")
                    return 1
        derived[arm_id] = first
        if arm_id in DECLARED_SURVIVORS:
            ok = verdict == "GREEN"
            mark = "SURVIVED (declared)" if ok else f"MISDIRECTED ({verdict})"
        elif verdict == "RED":
            want = because.get(arm_id)
            ok = a.derive or want == first
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
