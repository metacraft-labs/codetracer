## main.nim — the CodeTracer TUI entrypoint. Wires `host/` to `app/`, and
## nothing else.
##
## ## The shape, and why it is this shape
##
## `src/frontend/tui/` is two layers with one line between them:
##
##   app/    SDK-CONSUMER. Imports `codetracer_embed` and `headless_app` only.
##           Owns views, layout projection, input and every pane.
##           `ci/test/sdk-facade-boundary.sh` covers this directory through the
##           `.sdk-consumer` marker it carries.
##   host/   NATIVE HOST. The only place allowed to reach
##           `backend/stdio_backend` and `viewmodel/headless_session` — process
##           spawning, pty, termios, signals. Explicitly outside the facade,
##           and the boundary script records that exemption by name rather than
##           inferring it from the absence of a marker.
##
## This module is the wiring, so it is the one place both sides are in scope at
## once. It stays small on purpose: everything it does is decide, print or
## exit, and each of those is a host act. The moment a decision here needs
## state it belongs in `app/`, and the moment it needs a file descriptor it
## belongs in `host/`.
##
## ## What CTUI-0 wires
##
## `--help` and `--version`, and an honest refusal for everything else. A trace
## path parses (see `app/cli.nim`) and is reported as not yet openable, naming
## the milestone that opens it. That is deliberate: a binary that accepted a
## trace and drew nothing would be indistinguishable, from the outside, from
## one that opened it and failed.

import std/os

import ./app/cli
import ./app/tui_app
import ./host/native_host

proc run(args: seq[string]): int =
  ## The whole entrypoint, as a function of its arguments, returning the
  ## process's exit status rather than calling `quit`.
  ##
  ## `src/ct/codetracer.nim` exiting 0 on an unhandled exception is the single
  ## highest-value defect in the Silent-Self-Pass audit — it made every gate
  ## that ran `ct` and checked `$?` read crashes as success. So this returns a
  ## status, the wrapper below is the only thing that quits, and the failure
  ## paths are visible in one screen rather than spread across the arms.
  let command = parseTuiCommand(args)
  case command.kind
  of tckHelp:
    echo TuiHelpText
    0
  of tckVersion:
    echo TuiVersionText
    0
  of tckUsageError:
    stderr.writeLine(TuiProgramName & ": " & command.message)
    2
  of tckOpenTrace:
    # PARSED, RESOLVED, AND HONESTLY REFUSED. The path is resolved here rather
    # than merely echoed, so a user who mistyped it learns that now instead of
    # after the interactive loop lands; and the refusal names the milestones
    # that are still open, so the message cannot rot into a permanent "not
    # implemented" nobody dates.
    #
    # CTUI-3 landed the SHELL — `app/views/shell.nim` composes a whole screen
    # for a given size, and `app/layout/project.nim` puts the session's own
    # `LayoutNode` onto Yoga. What is still missing here is the part that turns
    # a screen into a program: a real terminal driver, raw mode, and an input
    # loop. Those are CTUI-9 (keymap and modal state) and CTUI-11 (capability
    # negotiation and the driver), so the message names them rather than
    # claiming a screen does not exist.
    try:
      let folder = resolveTraceFolder(command.tracePath)
      let app = newTuiApp()
      stderr.writeLine(TuiProgramName & ": " & folder & " exists, but opening" &
                       " a trace needs an input loop this milestone does not" &
                       " build yet.")
      stderr.writeLine("  " & app.statusLine())
      stderr.writeLine("  CTUI-0 delivers the build ground and the facade" &
                       " boundary and CTUI-3 the shell and its layout; the" &
                       " terminal driver and the keymap are CTUI-11 and" &
                       " CTUI-9. See codetracer-specs/Front-Ends/" &
                       "CodeTracer-TUI.milestones.org.")
      let replayServer = findReplayServer()
      if replayServer.len == 0:
        stderr.writeLine("  note: " & replayServerRemedy())
      if not stdoutIsTerminal():
        stderr.writeLine("  note: standard output is not a terminal, so even" &
                         " a finished TUI would have nothing to draw on here.")
      app.dispose()
      3
    except TuiHostError as e:
      stderr.writeLine(TuiProgramName & ": " & e.msg)
      2

when isMainModule:
  # The ONLY `quit` in the entrypoint, and it is reached on every path. An
  # unhandled exception must not become exit 0 here: `run` returns a status and
  # anything that escapes it is caught, named on stderr and reported as a
  # failure. stdout is left clean because `--version` is machine-readable.
  var status = 0
  try:
    status = run(commandLineParams())
  except CatchableError as e:
    stderr.writeLine(TuiProgramName & ": " & $e.name & ": " & e.msg)
    status = 1
  quit(status)
