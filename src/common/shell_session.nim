## common/shell_session.nim — a CodeTracer shell session: a real shell on a
## pseudo-terminal, and the session's event channel.
##
## Spec: `codetracer-pm` `spec/Planned-Features/CodeTracer-Shell.md` §7.2.
##
## The process side of the Shell pane. The terminal and the GPUI window run it
## in-process; the desktop runs it behind its main process as
## `ct shell-session` (`ct/shell_session_command.nim`), which speaks the same
## wire on its stdio. Either way the pane's model (`viewmodels/shell_vm.nim`)
## receives the same messages in the same order:
##
##   `{"output": <base64>}`   bytes the shell wrote to its terminal
##   `{"event": <SessionEvent>}` a command's report (§2.3)
##   `{"exit": <code>}`      the shell exited
##
## ## The ordering rule (§7.4)
##
## The model stamps an action's output lines when its event ARRIVES, so an
## event must never overtake the output written before it. `ct record` reports
## by appending a line to the session's report file AFTER the recorded program
## has written its output and exited; so when `poll` sees a new line on the
## report file, it first drains every byte the pty holds, and only then
## delivers the event. Everything the command wrote is then ahead of its event.
##
## ## The environment (§2.1)
##
## The shell inherits the front-end's environment, plus
##   `CODETRACER_SHELL_ID`, `CODETRACER_SESSION_ID` — this session's id;
##   `CODETRACER_SHELL_REPORT_FILE` — the event channel, a JSON-lines file in a
##     private directory this session removes when it closes;
##   `CODETRACER_SHELL_BASH_LOG_FILE` — the line file `ct record` reads (§2.5;
##     the pane does not need it, see §7.4, and `ct record` reads a missing one
##     as "no line");
##   `TERM` — `xterm-256color`, what the panes' emulator understands;
##   `PATH` — the directory of the `ct` the front-end runs, first, so a `ct
##     record` typed in the shell is this CodeTracer's.

import std/[base64, json, options, os, strutils, times]

import nim_pty

type
  ShellSessionOptions* = object
    shell*: string
      ## The program to run; empty: `$SHELL`, else `bash`, else `sh`.
    args*: seq[string]
      ## Its arguments (empty: `-i`, an interactive shell).
    cwd*: string
      ## Where it starts; empty: the front-end's current directory.
    ctBinDir*: string
      ## Put first on the shell's `PATH` when not empty.
    extraEnv*: seq[(string, string)]
      ## More variables, applied last.
    cols*, rows*: int

  ShellSession* = ref object
    pty: PtySession
    id*: int
    dir*: string
      ## The session's private directory (the report file lives here).
    reportPath*: string
    reportOffset: int
    reportPartial: string
    finished*: bool
      ## The exit message has been delivered.

var sessionCounter = 0

proc shellCommandFromEnv*(opts: var ShellSessionOptions) =
  ## `CODETRACER_SHELL_COMMAND`, when set, is the shell and its arguments
  ## (split on whitespace) — a test's `bash --noprofile --rcfile … -i`, a
  ## user's `zsh -l`. Every front-end's session reads it the same way.
  let command = getEnv("CODETRACER_SHELL_COMMAND").strip
  if command.len == 0:
    return
  let words = command.splitWhitespace()
  opts.shell = words[0]
  opts.args = words[1 .. ^1]
  if opts.args.len == 0:
    opts.args = @["-i"]

proc resolveShell(opts: ShellSessionOptions): string =
  var name = opts.shell
  if name.len == 0:
    name = getEnv("SHELL")
  if name.len == 0:
    name = "bash"
  if name.isAbsolute:
    return name
  result = findExe(name)
  if result.len == 0:
    result = findExe("sh")

proc startShellSession*(opts: ShellSessionOptions): ShellSession =
  ## Spawn the shell. Raises `PtyError` / `OSError` when it cannot start.
  let program = resolveShell(opts)
  if program.len == 0:
    raise newException(OSError, "no shell to run: neither $SHELL, bash nor sh was found")
  inc sessionCounter
  let id = getCurrentProcessId() * 1000 + sessionCounter
  let dir = getTempDir() / ("codetracer-shell-" & $id)
  createDir(dir)
  let report = dir / "events.jsonl"
  writeFile(report, "")
  var env: seq[(string, string)] = @[]
  var path = getEnv("PATH")
  if opts.ctBinDir.len > 0:
    path = opts.ctBinDir & PathSep & path
  for k, v in envPairs():
    if k in ["PATH", "TERM", "CODETRACER_SHELL_ID", "CODETRACER_SESSION_ID",
             "CODETRACER_SHELL_REPORT_FILE", "CODETRACER_SHELL_BASH_LOG_FILE",
             "CODETRACER_SHELL_SOCKET", "CODETRACER_SHELL_ADDRESS",
             "CODETRACER_RECORDING",
             # The front-end's own test marker: it makes `ct record` print a
             # line for a UI test's harness, which the user's shell is not.
             "CODETRACER_IN_UI_TEST"]:
      continue
    env.add (k, v)
  env.add ("PATH", path)
  env.add ("TERM", "xterm-256color")
  env.add ("CODETRACER_SHELL_ID", $id)
  env.add ("CODETRACER_SESSION_ID", $id)
  env.add ("CODETRACER_SHELL_REPORT_FILE", report)
  env.add ("CODETRACER_SHELL_BASH_LOG_FILE", dir / "line")
  for (k, v) in opts.extraEnv:
    var replaced = false
    for e in env.mitems:
      if e[0] == k:
        e[1] = v
        replaced = true
    if not replaced:
      env.add (k, v)
  let args = (if opts.args.len == 0: @["-i"] else: opts.args)
  result = ShellSession(id: id, dir: dir, reportPath: report)
  result.pty = spawnPty(program, args, env,
                        SpawnOptions(cols: max(1, opts.cols),
                                     rows: max(1, opts.rows),
                                     cwd: opts.cwd))

proc drainOutput(s: ShellSession; firstWaitMs: int; into: var seq[JsonNode]): bool =
  ## Read what the pty holds — waiting up to `firstWaitMs` for the first byte,
  ## then taking only what is already there. False at end of file.
  var buf = newSeq[byte](16384)
  var wait = firstWaitMs
  var got = ""
  result = true
  while true:
    let n = s.pty.read(buf, initDuration(milliseconds = wait))
    if n > 0:
      let start = got.len
      got.setLen(start + n)
      copyMem(addr got[start], addr buf[0], n)
      wait = 0
      continue
    if n == 0:
      result = false
    break
  if got.len > 0:
    into.add %*{"output": encode(got)}

proc newReportLines(s: ShellSession): seq[string] =
  ## Whole lines appended to the report file since the last call.
  var f: File
  if not open(f, s.reportPath, fmRead):
    return
  defer: f.close()
  let size = int(f.getFileSize)
  if size <= s.reportOffset:
    return
  f.setFilePos(s.reportOffset)
  var chunk = newString(size - s.reportOffset)
  let n = f.readBuffer(addr chunk[0], chunk.len)
  chunk.setLen(n)
  s.reportOffset += n
  s.reportPartial.add chunk
  while true:
    let nl = s.reportPartial.find('\n')
    if nl < 0: break
    let line = s.reportPartial[0 ..< nl].strip
    s.reportPartial = s.reportPartial[nl + 1 .. ^1]
    if line.len > 0:
      result.add line

proc addEvents(lines: seq[string]; into: var seq[JsonNode]) =
  for line in lines:
    try:
      into.add %*{"event": parseJson(line)}
    except CatchableError:
      discard  # a line a writer left half-written is skipped, not fatal

proc poll*(s: ShellSession; timeoutMs = 0): seq[JsonNode] =
  ## The messages since the last poll, in order, waiting up to `timeoutMs`
  ## for output when there is no event.
  ##
  ## THE ORDERING RULE (§7.2): an event follows the output written before
  ## it. A writer prints, then appends its report line, so the report lines
  ## are taken FIRST and the pty drained AFTER: everything printed before
  ## those lines is in the pty by then and goes out ahead of them. (Drained
  ## first, output printed between the drain and the read would trail an
  ## event written after it.)
  if s.finished:
    return
  var lines = s.newReportLines()
  let alive = s.drainOutput(if lines.len > 0: 0 else: timeoutMs, result)
  addEvents(lines, result)
  if not alive or not s.pty.isAlive:
    # The shell is gone: what it left, then its exit.
    lines = s.newReportLines()
    discard s.drainOutput(0, result)
    addEvents(lines, result)
    let code = s.pty.waitExitCode()
    result.add %*{"exit": code}
    s.finished = true

proc sendInput*(s: ShellSession; data: string) =
  if s.finished or data.len == 0:
    return
  try:
    s.pty.write(data.toOpenArrayByte(0, data.high))
  except CatchableError:
    discard  # the shell has gone; `poll` reports its exit

proc resize*(s: ShellSession; cols, rows: int) =
  if s.finished:
    return
  try:
    s.pty.setWindowSize(max(1, cols), max(1, rows))
  except CatchableError:
    discard

proc close*(s: ShellSession) =
  ## Stop the shell (SIGHUP, as a closed terminal does) and remove the
  ## session's directory.
  if s.isNil:
    return
  s.pty.close()
  s.finished = true
  try:
    removeDir(s.dir)
  except CatchableError:
    discard

proc pid*(s: ShellSession): int = int(s.pty.pid)
