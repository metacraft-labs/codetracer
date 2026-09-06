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
## ## CTUI-11: THIS IS THE MILESTONE THAT MADE THE BINARY RUN
##
## Until now every pane in this front-end was exercised only through the
## in-process harness and the snapshot apps: `main.nim` parsed `--help`,
## `--version` and a trace path, and then reported — honestly, and by name —
## that opening a trace needed a terminal driver nobody had built. CTUI-11 built
## it (`host/terminal_driver.nim`), and this is the wiring.
##
## ## THE ORDER OF THE FIRST FRAME, WHICH IS THE MILESTONE'S OWN CONTRACT
##
## CTUI-11 requires that capabilities resolve BEFORE the first paint, and it
## puts a published gate on cold start with probing enabled. Both are properties
## of the sequence below, so the sequence is written out rather than left to be
## read out of the code:
##
##   1. parse `argv`                    — `app/cli.parseTuiCommand`, no I/O
##   2. negotiate the terminal          — `host/capabilities`, seven `getEnv`s
##                                        and one `isatty`, no child process
##   3. claim the tty                   — raw mode, alt screen, mouse
##   4. **paint frame 0**               — the shell, saying which trace is
##                                        being opened
##   5. spawn `replay-server`, DAP      — seconds, on a cold page cache
##   6. paint frame 1                   — the debugger
##
## Steps 1-4 are what "cold start" measures, and putting step 5 AFTER the first
## frame is not a trick to make a number look good: a user who typed a command
## should see their terminal change immediately, and a front-end that showed
## nothing until the engine had answered would be indistinguishable, for that
## whole second, from one that had hung. It is also what makes "resolved before
## first paint" observable rather than asserted — the driver cannot be
## constructed without a `TerminalCapabilities`, and the paint is a method on
## the driver.

import std/os

import ./app/cli
import ./app/runtime
import ./app/tui_app
import ./host/capabilities
import ./host/native_host
import ./host/terminal_driver
import ./host/tui_session

const
  ExitOk* = 0
  ExitUnhandled* = 1
  ExitUsage* = 2
  ExitNoTerminal* = 3
    ## There is a trace and there is no screen to draw it on. Distinguishable
    ## from a usage error on purpose: `codetracer-tui trace | cat` is a correct
    ## command line and an impossible request, and reporting it as a bad
    ## argument would send the user looking at their arguments.

  IdlePollMs = 200
    ## How long the loop blocks when nothing is happening.
    ##
    ## A CEILING ON LATENCY FOR NOTHING, and it is not a poll interval: input
    ## and SIGWINCH both wake the `select` immediately, so this only bounds how
    ## long the process sleeps between two events it does not have. It exists so
    ## a partially framed escape sequence — an `ESC` with nothing after it — is
    ## not held forever.

proc paint(driver: TerminalDriver; rt: TuiRuntime) =
  ## One frame of `rt` onto `driver`.
  ##
  ## The cursor is CTUI-9's: `modal_state.cursorControlBytes` says what shape
  ## and visibility the current mode has, and it goes in the PROLOGUE because it
  ## does not move the cursor. §3.3.6's prompt DOES move it, so it goes in the
  ## epilogue — `docs/tui-testing.md` records why those two are different hooks
  ## and what it costs a reader of the frame barrier.
  let screen = rt.shellScreenOf()
  var epilogue = ""
  let (prompting, row, col) = rt.promptCursor()
  if prompting:
    epilogue = "\x1b[" & $(row + 1) & ";" & $(col + 1) & "H" & ShowCursorBytes
  driver.paint(screen.styledRows,
               prologue = cursorControlBytes(rt.modal.mode),
               epilogue = epilogue)

proc interactive(command: TuiCommand): int =
  ## Open a trace and run the loop until the user quits or the terminal goes
  ## away. Returns the process's exit status; nothing here calls `quit`.
  let caps = negotiateCapabilities(command.flags)
  if not stdoutIsTerminal():
    stderr.writeLine(TuiProgramName & ": standard output is not a terminal," &
                     " so there is nothing to draw on.")
    stderr.writeLine("  negotiated: " & describe(caps))
    stderr.writeLine("  run it in a terminal, or wait for --serve (CTUI-13)" &
                     " and --headless (CTUI-12).")
    return ExitNoTerminal

  let folder = resolveTraceFolder(command.tracePath)
  # BEFORE THE TERMINAL IS CLAIMED, and that order is the whole point. CTUI-11
  # measured what the other order costs: pointed at a directory that is not a
  # recording, the binary claimed the alternate screen, painted "opening …",
  # and then hung inside the DAP handshake — `replay-server` exits 2 on a folder
  # it cannot open and writes no DAP at all. The input loop had not started, so
  # no key could end it. Both checks below are `stat`s and both refuse on the
  # ORDINARY screen.
  let problem = traceFolderProblem(folder)
  if problem.len > 0:
    stderr.writeLine(TuiProgramName & ": " & folder & ": " & problem)
    return ExitUsage
  let replayServer = findReplayServer()
  if replayServer.len == 0:
    stderr.writeLine(TuiProgramName & ": " & replayServerRemedy())
    return ExitUsage

  let driver = newTerminalDriver(caps)
  driver.start()
  # FROM HERE THE TERMINAL IS OURS AND MUST BE GIVEN BACK ON EVERY PATH,
  # including an exception. `nim-termctl`'s signal handlers and `atexit` hook
  # cover a kill and a crash; this covers a normal return and a raise.
  defer: driver.stop()

  var size = driver.size()
  let app = newTuiApp()
  app.notification = "opening " & folder & " …"
  let rt = newTuiRuntime(app, caps, size.cols, size.rows)
  # FRAME 0, BEFORE THE ENGINE. See this module's header on why the order is
  # this way round.
  paint(driver, rt)

  var session: TuiSession = nil
  try:
    session = openTuiSession(folder, viewportHeight = max(1, size.rows - 6))
  except CatchableError as e:
    driver.stop()
    stderr.writeLine(TuiProgramName & ": could not open " & folder & ": " &
                     e.msg)
    return ExitUsage
  defer: session.close()

  session.header(rt)
  session.setViewportHeight(rt.sourcePaneRows())
  session.learnExtent()
  session.refresh(rt)
  app.notification = describe(session)
  paint(driver, rt)

  var running = true
  while running:
    let ev = driver.nextEvent(IdlePollMs)
    case ev.kind
    of dekEof:
      # The terminal closed its end. Not an error and not a quit key: the user
      # is gone, and the only correct thing left is to give the tty back.
      running = false
    of dekIdle:
      discard
    of dekResize:
      size = ev.size
      rt.resize(size.cols, size.rows)
      # THE SOURCE WINDOW FOLLOWS THE PANE, not the terminal. A reflow that
      # changed the profile changed the editor's rectangle, and a `SourceVM`
      # still holding the old height would scroll the execution line off the
      # pane — see `runtime.sourcePaneRows`.
      session.setViewportHeight(rt.sourcePaneRows())
      session.refresh(rt)
      paint(driver, rt)
    of dekToken:
      let outcome = rt.handleToken(ev.token, nowMs())
      if outcome.quit:
        running = false
      else:
        if outcome.awaitsMove:
          session.pumpMove()
          session.refresh(rt)
        if outcome.repaint:
          paint(driver, rt)
  ExitOk

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
    ExitOk
  of tckVersion:
    echo TuiVersionText
    ExitOk
  of tckUsageError:
    stderr.writeLine(TuiProgramName & ": " & command.message)
    ExitUsage
  of tckOpenTrace:
    try:
      interactive(command)
    except TuiHostError as e:
      stderr.writeLine(TuiProgramName & ": " & e.msg)
      ExitUsage

when isMainModule:
  # The ONLY `quit` in the entrypoint, and it is reached on every path. An
  # unhandled exception must not become exit 0 here: `run` returns a status and
  # anything that escapes it is caught, named on stderr and reported as a
  # failure. stdout is left clean because `--version` is machine-readable.
  var status = ExitOk
  try:
    status = run(commandLineParams())
  except CatchableError as e:
    stderr.writeLine(TuiProgramName & ": " & $e.name & ": " & e.msg)
    status = ExitUnhandled
  quit(status)
