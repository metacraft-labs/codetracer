## ct/shell_session_command.nim — `ct shell-session`: a CodeTracer shell
## session on stdio, for a front-end that cannot open a pseudo-terminal itself.
##
## Spec: `codetracer-pm` `spec/Planned-Features/CodeTracer-Shell.md` §7.2.
##
## The desktop's main process runs JavaScript; a pty needs a native process.
## So for each Shell pane it runs this command, which holds the session
## (`common/shell_session.nim`, the code the terminal and the GPUI window run
## in-process) and speaks the session wire as JSON lines:
##
##   stdout: `{"output": <base64>}`, `{"event": <SessionEvent>}`,
##           `{"exit": <code>}` — then the command exits;
##   stdin:  `{"input": <base64>}`, `{"resize": {"cols": C, "rows": R}}`,
##           `{"close": true}`; end of input closes the session too.
##
## Usage: `ct shell-session [--cols N] [--rows N] [--cwd DIR] [--shell PROG]
## [-- ARGS...]`; without `--shell`, `CODETRACER_SHELL_COMMAND`, else `$SHELL`.
## Internal: dispatched ahead of the option parser (`codetracer.nim`), like
## `ct-complete`, and not listed in `ct --help`.

import std/[base64, json, os, strutils]

import ../common/shell_session

when defined(posix):
  import std/posix

proc emit(msgs: seq[JsonNode]) =
  for m in msgs:
    stdout.write($m & "\n")
  if msgs.len > 0:
    stdout.flushFile()

proc runShellSessionCommand*(args: seq[string]): int =
  var opts = ShellSessionOptions(cols: 80, rows: 24, ctBinDir: getAppDir())
  opts.shellCommandFromEnv()   # `--shell` / `--` below override it
  var i = 0
  while i < args.len:
    let a = args[i]
    template value(): string =
      inc i
      (if i < args.len: args[i] else: "")
    case a
    of "--cols": opts.cols = parseInt(value())
    of "--rows": opts.rows = parseInt(value())
    of "--cwd": opts.cwd = value()
    of "--shell":
      opts.shell = value()
      opts.args = @[]
    of "--":
      opts.args = args[i + 1 .. ^1]
      break
    else:
      stderr.writeLine("ct shell-session: unknown option " & a)
      return 2
    inc i
  when not defined(posix):
    emit(@[%*{"failed": "the shell pane needs a POSIX terminal on this platform"}])
    return 1
  else:
    var session: ShellSession
    try:
      session = startShellSession(opts)
    except CatchableError as e:
      emit(@[%*{"failed": "could not start the shell: " & e.msg}])
      return 1
    # Input arrives on stdin while output is polled: stdin is read without
    # blocking, between polls.
    let fl = fcntl(0, F_GETFL)
    discard fcntl(0, F_SETFL, fl or O_NONBLOCK)
    var pending = ""
    var buf = newString(65536)
    var inputOpen = true
    while not session.finished:
      emit(session.poll(20))
      if not inputOpen:
        continue
      while true:
        let n = posix.read(0, addr buf[0], buf.len)
        if n > 0:
          pending.add buf[0 ..< n]
          continue
        if n == 0:
          inputOpen = false
        break
      while true:
        let nl = pending.find('\n')
        if nl < 0: break
        let line = pending[0 ..< nl].strip
        pending = pending[nl + 1 .. ^1]
        if line.len == 0: continue
        var msg: JsonNode
        try:
          msg = parseJson(line)
        except CatchableError:
          continue
        if msg.hasKey("input"):
          session.sendInput(decode(msg["input"].getStr))
        elif msg.hasKey("resize"):
          session.resize(msg["resize"]{"cols"}.getInt(80),
                         msg["resize"]{"rows"}.getInt(24))
        elif msg.hasKey("close"):
          inputOpen = false
      if not inputOpen:
        # The front-end closed the pane (or went away): end the shell, and
        # still report what it left and its exit.
        session.close()
        emit(@[%*{"exit": 0}])
        break
    session.close()
    0
