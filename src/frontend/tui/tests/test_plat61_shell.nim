## test_plat61_shell.nim — the Shell pane on the terminal, Tier 1: the
## painter, its hit-testing and the runtime over a REAL shell on a REAL pty,
## running a REAL recorded build.
##
## Spec: `codetracer-pm` `spec/Planned-Features/CodeTracer-Shell.md` §7.
##
## The session is the `calc` fixture (`fixtures/fixture_provider`, recorded by
## `ct record` with the pinned recorder) opened by a real `replay-server`; the
## Shell pane's shell is `bash --norc --noprofile -i` on a pty
## (`common/shell_session`, through the host's `native_shell_host`), with this
## build's `ct` first on its `PATH`. The build it runs (`writeBuild`) writes a
## Python program and records it with `ct record`, whose report line reaches
## the pane through the session's report file. Asserted:
##
##   1. THE SHELL: `:shell` shows the pane, focused; the shell is
##      `CODETRACER_SHELL_COMMAND` (§7.2) — the host's resolution and the
##      running process's argv; it starts at the pane's text area (`stty
##      size` answers it), prints its prompt, and typed keys reach it —
##      `Enter` runs the line;
##   2. THE RECORDED BUILD: the build's output in the pane, the recording's
##      action marked on the lines `ct record` wrote — `●` on the first, `│`
##      on the rest, in the success role — and its words;
##   3. THE SAME ROWS AS THE DESKTOP'S VIEW: the painted rows, gutter first,
##      equal `isonim_shell_view.shellRowsText` over the same model, and the
##      transcript oracle written by hand;
##   4. THE PRESS OPENS THE RECORDING: a press on the action's gutter hands
##      the front-end's opener the recording's folder, which holds the
##      recording the event named; a press on a plain line opens nothing;
##   5. THE KEYS: `Ctrl+C` interrupts the shell's foreground job; after the
##      prefix (`Ctrl+]`) the next key is CodeTracer's (`:` opens the command
##      line, not the shell's);
##   6. THE SCROLLBACK: the wheel scrolls back over output longer than the
##      pane; a key brings the view back to the tail;
##   7. THE SIZE FOLLOWS THE PANE: a resized terminal resizes the shell;
##   8. THE ORDER: the session hands out a writer's output before the event
##      it reported after printing it (`/bin/sh -c`, no pane) — checked
##      FIRST, before the pane opens; see the suite's opening comment.
##
## THE ONE STAND-IN, and why it is not a mock: `TuiApp.recordingOpener` is the
## front-end's "open this recording in a new session tab", which `main.nim`
## implements by spawning another session; this suite drives the runtime
## without `main`, so the hook records the folder it is handed. What it is
## handed — and that the folder is the recording — is the unit under test;
## the tab itself opening is `real_terminal/test_plat61_shell_pty.nim`'s, over
## the shipped binary.

import std/[base64, json, os, osproc, strutils, times, unittest]

import isonim/testing/mock_dom
import codetracer_embed
import views/isonim_shell_view

import ../app/runtime
import ../app/tui_app
import ../app/theme/capabilities
import ../app/theme/roles
import ../app/layout/profile
import ../app/views/shell_session_pane
import ../host/tui_session
import ../../../common/shell_session
import ../../viewmodel/host/native_shell_host
import ./fixtures/fixture_provider

# One line, deliberately: `ci/lib/run-nim-test-lane.sh` reads this spelling
# as the suite's RUNTIME assertion count. Measured: 53 on a green run at
# 2ea21ab5c plus the two §7.2 checks that the pane's shell is
# `CODETRACER_SHELL_COMMAND` (51 before them).
const ExpectedAssertions = 53

var countedAssertions = 0

template ck(condition: untyped) =
  inc countedAssertions
  check condition

const
  Cols = 140
  Rows = 60
  Enter = "\r"
  CtrlC = "\x03"
  Prefix = "\x1d"
  WaitMs = 120_000

proc newRuntime(width = Cols; height = Rows): TuiRuntime =
  let caps = resolveCapabilities(
    initTerminalEnv(term = "xterm-256color", colorterm = "truecolor",
                    lang = "en_US.UTF-8"), initCapabilityFlags())
  result = newTuiRuntime(newTuiApp(), caps, width, height)
  discard result.enableLayoutBinding()
  result.refreshMenuForKeymap()

proc send(s: TuiSession; rt: TuiRuntime; token: string; nowMs = 0'i64) =
  let outcome = rt.handleToken(token, nowMs)
  s.applyOutcome(rt, outcome)

proc typeText(s: TuiSession; rt: TuiRuntime; text: string) =
  for ch in text:
    s.send(rt, $ch)

proc command(s: TuiSession; rt: TuiRuntime; line: string) =
  s.send(rt, ":")
  s.typeText(rt, line)
  s.send(rt, Enter)

proc sgr(code, row, col: int; release = false): string =
  "\x1b[<" & $code & ";" & $(col + 1) & ";" & $(row + 1) &
    (if release: "m" else: "M")

proc vm(s: TuiSession): ShellVM = s.shellVM

proc shows(s: TuiSession; text: string): bool =
  let v = s.vm
  for line in v.firstKeptLine .. v.lastLine:
    if text in v.lineText(line):
      return true

proc pumpUntil(s: TuiSession; rt: TuiRuntime; cond: proc(): bool;
               what: string; ms = WaitMs) =
  ## Pump the shell (the idle tick's call) until `cond`; a timeout fails with
  ## what the pane showed.
  let started = epochTime()
  while not cond():
    if (epochTime() - started) * 1000.0 > float(ms):
      checkpoint("waited " & $ms & " ms for " & what & "; the pane shows:\n" &
                 rt.shellPanePainted().join("\n"))
      fail()
      return
    discard s.pumpShell(rt)
    sleep(20)

proc ctDir(): string =
  let bin = fixture_provider.findCtBinary()
  doAssert bin.len > 0, "`ct` is not built (just build-once)"
  bin.parentDir

proc writeBuild(dir: string): string =
  ## A recorded build: generate the program, record it. Its path.
  createDir(dir)
  result = dir / "build.sh"
  writeFile(result, """#!/bin/sh
cd "$(dirname "$0")"
echo "building prog.py"
printf 'def add(a, b):\n    return a + b\nprint("sum", add(2, 3))\nprint("done")\n' > prog.py
rm -rf rec-build
ct record -o rec-build prog.py
""")
  setFilePermissions(result, {fpUserRead, fpUserWrite, fpUserExec})

proc electronAnswers(): JsonNode =
  ## The REAL desktop's Shell pane running the same build
  ## (`plat61-shell-capture.spec.ts`, `just plat61-capture-electron`).
  let repo = currentSourcePath().parentDir.parentDir.parentDir.parentDir.parentDir
  parseJson(readFile(repo / "src/tests/visual/answers/plat61-shell.electron.json"))

proc normalised(rows: seq[string]): seq[string] =
  ## A recording id is per run: its line reads `recordingId:<id>`.
  for r in rows:
    let at = r.find("recordingId:")
    result.add(if at >= 0: r[0 ..< at] & "recordingId:<id>" else: r)

let fixture = resolveFixture("calc")
if fixture.outcome != foRecorded:
  echo missingPrereqMessage(fixture.spec, fixture.detail)
  quit(1)

# The shell the pane runs, and the `ct` it finds; recordings indexed in a
# scratch home, never the user's.
let scratch = getTempDir() / "plat61-shell-" & $getCurrentProcessId()
createDir(scratch / "ct-home")
writeFile(scratch / "ct-home" / ".codetracer-test-home", "")
putEnv("CODETRACER_HOME", scratch / "ct-home")
# The shell's prompt, fixed by an rc file (as the GPUI and real-terminal
# suites fix it).
writeFile(scratch / "shellrc", "PS1='$ '\n")
let shellCommand = "bash --noprofile --rcfile " & scratch / "shellrc" & " -i"
putEnv("CODETRACER_SHELL_COMMAND", shellCommand)
putEnv("PATH", ctDir() & PathSep & getEnv("PATH"))
let build = writeBuild(scratch / "project")

var opened: seq[string]

proc open(width = Cols; height = Rows): (TuiRuntime, TuiSession) =
  let rt = newRuntime(width, height)
  let s = openTuiSession(fixture.tracePath, viewportHeight = height - 8)
  s.header(rt)
  s.learnExtent()
  rt.app.recordingOpener = proc(path: string): string =
    opened.add path
    ""
  rt.app.shellAct = proc(act: ShellAct): ShellActResult =
    s.shellAct(rt, act)
  s.wireShell(proc(path: string): string = rt.app.recordingOpener(path))
  s.refresh(rt)
  (rt, s)

proc shellArgv(pid: int): seq[string] =
  ## The running shell's argv, as the OS reports it: `/proc/<pid>/cmdline`
  ## (NUL-separated) where there is a `/proc`, else `ps -o args=` (macOS).
  ## Empty when the process is gone or not readable.
  let cmdline = "/proc/" & $pid & "/cmdline"
  if fileExists(cmdline):
    try:
      for word in readFile(cmdline).split('\0'):
        if word.len > 0: result.add word
    except IOError:
      discard
  else:
    let (output, code) = execCmdEx("ps -o args= -p " & $pid)
    if code == 0:
      result = output.strip.splitWhitespace()

proc focusedPane(rt: TuiRuntime): PaneKind =
  let (_, p) = rt.focus.focusedPane()
  p

suite "PLAT-61 the Shell pane on the terminal":
  # FIRST, before the pane's shell exists. This case is the one place the
  # order of a poll's output and events is measured at a fixed moment (one
  # poll, made once both are written), so a session that reorders them
  # (`run-plat61-shell-mutations.py` S1) fails here on every run. The pane
  # cases that follow see the same defect only when one poll happens to
  # carry both the build's last line and `ct record`'s report, which is
  # timing; run after them, the FIRST failure (the one the harness reads)
  # was theirs or this case's depending on that (measured 2026-11-10 at
  # 71d92eb52: S1 died at R1's `lastLine == "done"` check).
  test "an event follows the output its writer printed before it":
    # The session itself (`common/shell_session.poll`), no pane: a writer
    # prints a line and THEN appends its report line; one poll, made once
    # both are written, hands the output out before the event (§7.2).
    var opts = ShellSessionOptions(shell: "/bin/sh", cols: 40, rows: 10)
    opts.args = @["-c", "printf 'printed-before\\n'; " &
      "printf '{\"kind\":\"record\"}\\n' >> \"$CODETRACER_SHELL_REPORT_FILE\"; " &
      "sleep 5"]
    let session = startShellSession(opts)
    let deadline = epochTime() + 10.0
    while epochTime() < deadline and
        (not fileExists(session.reportPath) or getFileSize(session.reportPath) == 0):
      sleep(10)
    sleep(100)  # the line discipline has the printed bytes well before this
    let messages = session.poll(0)
    var outputAt, eventAt = -1
    for i, m in messages:
      if m.hasKey("output") and outputAt < 0 and
          "printed-before" in decode(m["output"].getStr):
        outputAt = i
      if m.hasKey("event") and eventAt < 0:
        eventAt = i
    session.close()
    ck outputAt >= 0
    ck eventAt >= 0
    ck outputAt < eventAt

  let (rt, s) = open()

  test "`:shell` shows the pane, focused, its shell at the pane's size":
    s.command(rt, "shell")
    s.refresh(rt)
    ck rt.focusedPane == paneShell
    # The terminal DRAWS the pane (no report leaf, no reason given).
    ck paneShell in terminalCapability().drawable
    ck terminalCapability().reasons[paneShell] == ""
    let area = rt.shellPaneArea()
    ck area.width > 0
    let (cols, rows) = shellPaneSize(area)
    # §7.2: THE PANE'S SHELL IS `CODETRACER_SHELL_COMMAND`, split on
    # whitespace. Asserted before anything waits on the shell's prompt, so a
    # host that ignores the variable fails HERE, by name, on every machine —
    # not later, at whichever wait the machine's own `$SHELL -i` happens to
    # miss (its prompt is the host's, not the rc file's `$ `).
    # The host's resolution — what it hands the session (`native_shell_host`):
    let words = shellCommand.splitWhitespace()
    let resolved = shellOptionsFromEnv(cols, rows)
    ck resolved.shell == words[0] and resolved.args == words[1 .. ^1]
    # …and the process the pane actually runs: its argv, once it has exec'd
    # (until then the forked child still reports this test's own argv).
    let pid = s.shell.session.pid
    let self = getAppFilename().extractFilename
    s.pumpUntil(rt, proc(): bool =
      let argv = shellArgv(pid)
      argv.len > 0 and argv[0].extractFilename != self, "the shell's exec")
    let argv = shellArgv(pid)
    ck argv.len == words.len and argv[0].extractFilename == words[0] and
       argv[1 .. ^1] == words[1 .. ^1]
    s.pumpUntil(rt, proc(): bool = s.shows("$"), "the prompt")
    ck s.vm.state.val == sssRunning
    ck s.vm.screen.cols == cols and s.vm.screen.rows == rows
    ck rt.app.shellPane.loaded
    ck rt.app.shellPane.words == "running"
    s.typeText(rt, "stty size")
    s.send(rt, Enter)
    s.pumpUntil(rt, proc(): bool = s.shows($rows & " " & $cols),
                "stty size")
    ck s.shows($rows & " " & $cols)

  test "a recorded build: its output and its recording marked":
    # Into the project, then the screen and its scrollback cleared (what
    # `clear` writes), so the build's rows start the pane.
    s.typeText(rt, "cd " & build.parentDir)
    s.send(rt, Enter)
    s.typeText(rt, "printf '\\033[H\\033[2J\\033[3J'")
    s.send(rt, Enter)
    s.pumpUntil(rt, proc(): bool = s.vm.lastLine == s.vm.cursorLine and
                s.vm.lineText(s.vm.cursorLine) == "$" and
                not s.shows("stty"), "the cleared screen")
    s.typeText(rt, "./build.sh")
    s.send(rt, Enter)
    s.pumpUntil(rt, proc(): bool =
      s.vm.recordedActions.len == 1 and s.shows("recordingId:"),
      "the recording")
    s.pumpUntil(rt, proc(): bool = s.vm.lineText(s.vm.cursorLine) == "$",
                "the next prompt")
    let v = s.vm
    ck v.actions.len == 1
    let a = v.actions[0]
    ck a.kind == sakRecord and a.status == sasOk
    ck a.command == "prog.py"
    ck a.traceFolder == scratch / "project" / "rec-build"
    var containers = 0
    for f in walkFiles(a.traceFolder / "*.ct"): inc containers
    ck containers == 1
    ck a.recordingId.len == 36
    ck a.actionSummary == "recorded command: prog.py — recording " &
                          shortId(a.recordingId)
    # The program's lines, marked by `ct record` (its OSC marks); the
    # recording's id it prints afterwards is not the program's.
    ck v.lineText(a.firstLine) == "sum 5"
    ck v.lineText(a.lastLine) == "done"
    ck v.lineText(a.lastLine + 1) == "recordingId:" & a.recordingId
    ck rt.app.shellPane.words == "running — 1 recording"

  test "the painted rows equal the desktop's view and the transcript":
    let painted = rt.shellPanePainted()
    ck painted == shellRowsText(s.vm)
    let oracle = @["  $ ./build.sh", "  building prog.py", "● sum 5",
                   "│ done", "  recordingId:<id>", "  $"]
    ck normalised(painted)[0 ..< oracle.len] == oracle
    # The gutter's role: success, as on the desktop and in GPUI.
    let row = rt.app.shellPane.rows[2]
    ck row.mark == srmStart and row.tone == stOk
    ck rt.app.shellPane.rows[3].mark == srmRange
    ck toneStyle(stOk).role == srChromeSuccess
    # THE DESKTOP'S: the build's lines, from its first through the id after
    # the recording's range — text, mark, tone and gutter — and the words.
    let answers = electronAnswers()
    var mine: seq[string]
    for i in 1 .. 4:
      let r = rt.app.shellPane.rows[i]
      mine.add normalised(@[r.text])[0] & "|" & (case r.mark
        of srmNone: "none"
        of srmStart: "start"
        of srmRange: "range") & "|" & (if r.mark == srmNone: "" else: $r.tone) &
        "|" & (if painted[i].len > 0: painted[i].split(' ')[0].strip else: "")
    var desktop: seq[string]
    for r in answers["rows"]:
      desktop.add r["text"].getStr & "|" & r["mark"].getStr & "|" &
                  r["tone"].getStr & "|" & r["gutter"].getStr
    ck mine == desktop
    ck rt.app.shellPane.words == answers["status"].getStr

  test "a press on the gutter opens the recording; on a plain line, nothing":
    let area = rt.shellPaneArea()
    let geo = shellPaneGeometry(area)
    let first = geo.contentTop
    # The plain line above the action: no opener call.
    s.send(rt, sgr(0, first + 1, geo.gutterCol))
    s.send(rt, sgr(0, first + 1, geo.gutterCol, release = true))
    ck opened.len == 0
    s.send(rt, sgr(0, first + 2, geo.gutterCol))
    s.send(rt, sgr(0, first + 2, geo.gutterCol, release = true))
    ck opened == @[s.vm.actions[0].traceFolder]
    ck s.vm.opened == opened
    ck rt.app.notification.contains("opened recording " &
                                    shortId(s.vm.actions[0].recordingId))
    # The desktop said the same, after the same press.
    ck electronAnswers()["opened"]["note"].getStr.endsWith(
      "opened recording <id>")
    let hit = rt.app.shellPane.shellHitAt(area, first + 3, geo.gutterCol)
    ck hit.kind == shGutter and hit.action == 0
    ck rt.app.shellPane.shellHitAt(area, first + 3, geo.textCol + 2).kind ==
       shText
    ck rt.focusedPane == paneShell

  test "Ctrl+C reaches the shell; after the prefix, `F6` is CodeTracer's":
    # The job announces itself once it IS the foreground job (`running-6`
    # is printed by the subshell, which then becomes the `sleep`; the typed
    # `$((2*3))` is not that text), so `Ctrl+C` cannot arrive while the shell
    # itself still has the terminal.
    s.typeText(rt, "(echo running-$((2*3)); exec sleep 300)")
    s.send(rt, Enter)
    s.pumpUntil(rt, proc(): bool = s.shows("running-6"), "the job running")
    let before = epochTime()
    s.send(rt, CtrlC)
    s.pumpUntil(rt, proc(): bool =
      s.vm.lineText(s.vm.cursorLine) == "$" and
      s.vm.lineText(s.vm.cursorLine - 1).contains("^C"),
      "the interrupted prompt", ms = 60_000)
    # Well inside the 300 s the job would take — a loaded machine can be
    # slow to draw the prompt, so the bound is not tight.
    ck epochTime() - before < 60.0
    s.send(rt, Prefix)
    ck s.vm.prefixArmed
    ck rt.app.notification.contains("Ctrl+]")
    # `F6` would be the shell's while it has the keys; after the prefix it
    # moves the focus to the next pane, as anywhere else.
    s.send(rt, "\x1b[17~")
    ck not s.vm.prefixArmed
    ck rt.focusedPane != paneShell
    # A press on the output gives the shell the keys back.
    let area = rt.shellPaneArea()
    s.send(rt, sgr(0, area.row + 2, area.col + 6))
    s.send(rt, sgr(0, area.row + 2, area.col + 6, release = true))
    ck rt.focusedPane == paneShell

  test "the wheel scrolls the scrollback; a key returns to the tail":
    s.pumpUntil(rt, proc(): bool = s.vm.lineText(s.vm.cursorLine) == "$",
                "a prompt")
    s.typeText(rt, "seq 1 200")
    s.send(rt, Enter)
    s.pumpUntil(rt, proc(): bool = s.vm.lineText(s.vm.cursorLine - 1) == "200" and
                s.vm.lineText(s.vm.cursorLine) == "$", "seq's last line")
    let area = rt.shellPaneArea()
    let tail = rt.app.shellPane.top
    ck s.vm.scrollTop.val == -1
    s.send(rt, sgr(64, area.row + 5, area.col + 10))    # wheel up
    ck rt.app.shellPane.top < tail
    ck s.vm.scrollTop.val >= 0
    s.send(rt, " ")
    ck s.vm.scrollTop.val == -1
    ck rt.app.shellPane.top == tail
    s.send(rt, "\x7f")

  test "a resized terminal resizes the shell":
    rt.resize(Cols - 20, Rows - 10)
    s.refresh(rt)
    let (cols, rows) = shellPaneSize(rt.shellPaneArea())
    ck s.vm.screen.cols == cols and s.vm.screen.rows == rows
    s.typeText(rt, "stty size")
    s.send(rt, Enter)
    s.pumpUntil(rt, proc(): bool = s.shows($rows & " " & $cols),
                "stty size after the resize")
    ck s.shows($rows & " " & $cols)

  test "every assertion ran":
    s.close()
    check countedAssertions == ExpectedAssertions
