## headless.nim — `--headless`, §6.2's "run headlessly without opening a
## terminal window (for CI)".
##
## Open a trace, render ONE settled §3.1 screen as plain text, and exit 0.
##
## ## Why this is a `host/` module and not part of `main.nim`
##
## It opens a trace, resolves capabilities and starts a replay server — every
## one of which is a host concern — and it has to be callable from a test
## without going through `quit`. `main.nim` keeps its rule of wiring `host/` to
## `app/` and nothing else.
##
## ## Where the rendering happens
##
## Nowhere in this file. `host/terminal_driver.plainFrame` turns a pane tree
## into text, sharing `degradeRows` and `composite` with the tty path, so
## `--headless` and a real terminal cannot be shown different screens. This
## module owns no renderer, and that is deliberate rather than incidental.
##
## ## Scope
##
## There is no input loop, no alternate screen and no raw mode. One frame, as
## text, is the smallest honest meaning of what §6.2 publishes: "run headlessly
## without opening a terminal window (for CI)".
##
## CTUI-14 built `--replay-keys`, and this module deliberately did NOT grow a
## loop to consume it. The two flags answer different questions and combining
## them would answer neither well: `--headless` renders ONE SETTLED SCREEN as
## plain text for a CI job to `grep`, and a replayed session's interest is in
## the frames BETWEEN its keys, which plain text at the end throws away.
## `tests/real_terminal/test_real_high_latency.nim` is what a replayed session
## is for, and it reads the frames off the pty.
##
## THAT DECISION IS NOW ENFORCED AT THE PARSER rather than left as a comment.
## `--headless --record-keys=f` and `--headless --replay-keys=f` are usage
## errors naming the conflict (`app/cli.parseTuiCommand`); before that they
## parsed, arrived here, and were silently dropped — a flag that parses and
## then does nothing, which is the exact failure mode `app/cli.PlannedOptions`
## is written against.
##
## ## `--goto` IS HONOURED HERE, and it is the opposite case
##
## It is a startup navigation applied once before the first debugger frame, and
## the single frame this mode renders IS that frame. Ignoring it would have
## made `codetracer-tui --headless --goto=200 <trace>` silently render tick 0,
## which is a wrong answer rather than a missing one. `runHeadless` dispatches
## the same `kaSeekToTick` through `tui_session.seekToStartupTick` that the tty
## path and `:goto` both use, so the three cannot diverge.

when defined(js):
  {.error: "src/frontend/tui/host is native-only: it owns the tty.".}

import std/posix

import ../app/cli
import ../app/runtime
import ../app/theme/capabilities as app_capabilities
import ../app/tui_app
import ./capabilities
import ./native_host
import ./resize
import ./terminal_driver
import ./tui_session

proc headlessGeometry*(): TerminalSize =
  ## The screen `--headless` renders onto.
  ##
  ## A tty's real size when there is one — `codetracer-tui --headless t | cat`
  ## still has a terminal on fd 2 in the ordinary case, but fd 1 is what a
  ## frame is measured against — then `COLUMNS`/`LINES`, then the fallback.
  ## Deterministic in CI, where neither is set, which is the point of the mode.
  if isatty(STDOUT_FILENO) == 1:
    terminalSizeOf(STDOUT_FILENO)
  else:
    sizeFromEnv()

proc runHeadless*(traceFolder: string; flags: app_capabilities.CapabilityFlags;
                  size: TerminalSize; sink: File = stdout;
                  gotoTick: int64 = NoGotoTick): int =
  ## Open the trace, render ONE settled screen as plain text, and exit.
  ##
  ## It is the answer to a real dead end: before this, `codetracer-tui <trace> |
  ## cat` exited 3 with "standard output is not a terminal, so there is nothing
  ## to draw on", which is true and unhelpful.
  ##
  ## `sink` is a parameter so a suite can read the frame without a pipe.
  ##
  ## `gotoTick` is §6.2's `--goto`, defaulted to `NoGotoTick` so the ordinary
  ## call is unchanged. See this module's header for why this flag is honoured
  ## here while `--record-keys` / `--replay-keys` are refused at the parser.
  let folder = resolveTraceFolder(traceFolder)
  let problem = traceFolderProblem(folder)
  if problem.len > 0:
    stderr.writeLine(TuiProgramName & ": " & folder & ": " & problem)
    return ExitUsage
  if findReplayServer().len == 0:
    stderr.writeLine(TuiProgramName & ": " & replayServerRemedy())
    return ExitUsage

  let caps = resolveCapabilities(readTerminalEnv(STDOUT_FILENO), flags)
  let app = newTuiApp()
  let rt = newTuiRuntime(app, caps, size.cols, size.rows)

  var session: TuiSession = nil
  try:
    # THE CLOCK, WHICH THIS PATH DID NOT HAVE. CTUI-14 bounded the tty
    # handshake and left `--headless` on the default unbounded `DapReadBound`,
    # so an engine that answered `launch` and then went quiet blocked this
    # function forever — in CI, as a job that never finishes and says nothing,
    # which is the same defect as a frozen screen with the terminal taken away.
    #
    # The clock only, not the escape hatch: `interruptFd` watches the terminal
    # driver's input fd, and this mode has no terminal and no user at it. The
    # budget is the same `CODETRACER_TUI_HANDSHAKE_MS`-overridable one the tty
    # path uses, so a slow recording is given the same room in both.
    session = openTuiSession(folder, viewportHeight = max(1, size.rows - 6),
                             bound = DapReadBound(
                               timeoutMs: handshakeBudgetMs(),
                               interruptFd: -1))
  except DapLaunchRefusedError as e:
    # The same named refusal the tty path reports, with the same code: a
    # `--headless` run is read by a script, and a script that cannot tell a
    # bad path from a recording this build will never read has to guess which
    # of the two to retry. See `cli.ExitUnreadableRecording`.
    stderr.writeLine(TuiProgramName & ": cannot open " & folder & ": " & e.msg)
    return ExitUnreadableRecording
  except DapStalledError as e:
    # The tty path's distinction, kept here: an engine that went quiet is not a
    # usage error, and a CI log that said `ExitUsage` would send the next
    # reader to the command line for a folder that named itself correctly.
    stderr.writeLine(TuiProgramName & ": " & folder &
                     ": the replay engine stopped answering (" & e.msg & ")")
    return ExitEngineStalled
  except CatchableError as e:
    stderr.writeLine(TuiProgramName & ": could not open " & folder & ": " & e.msg)
    return ExitUsage
  defer: session.close()

  # The recording's own sources reach the Files pane through
  # `session.refresh` (PLAT-47) — the one path the tty loop takes too. PLAT-45
  # filled the pane HERE only, so `--headless` showed files the interactive
  # terminal never did.
  session.header(rt)
  session.setViewportHeight(rt.sourcePaneRows())
  session.learnExtent()
  session.refresh(rt)
  app.notification = describe(session)

  # §6.2's `--goto=<tick>`, AFTER `learnExtent` and BEFORE the one frame this
  # mode renders — the same order `main.nim`'s tty path uses, and for the same
  # reason: the clamp is against the recording's own bounds, which `learnExtent`
  # has just supplied. The dispatcher's detail line replaces the diagnostic on
  # the status row, so a clamped seek says so on the frame a CI job reads.
  if gotoTick != NoGotoTick:
    app.notification = session.seekToStartupTick(rt, gotoTick)

  # THE SAME COMPOSITE THE TTY PATH DRAWS, read as text instead of as bytes.
  # `plainFrame` is `terminal_driver`'s and shares `degradeRows` + `composite`
  # with `paint`; this file owns no renderer.
  let screen = rt.shellScreenOf()
  sink.writeLine(plainFrame(caps, screen.styledRows, size.cols, size.rows))
  sink.flushFile()
  ExitOk
