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
## There is no input loop, no alternate screen and no raw mode. There is no
## input SOURCE yet — `--replay-keys` is CTUI-14's — so a loop here would be a
## loop with nothing to read. One frame, as text, is the smallest honest
## meaning of what §6.2 publishes.

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
                  size: TerminalSize; sink: File = stdout): int =
  ## Open the trace, render ONE settled screen as plain text, and exit.
  ##
  ## It is the answer to a real dead end: before this, `codetracer-tui <trace> |
  ## cat` exited 3 with "standard output is not a terminal, so there is nothing
  ## to draw on", which is true and unhelpful.
  ##
  ## `sink` is a parameter so a suite can read the frame without a pipe.
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
    session = openTuiSession(folder, viewportHeight = max(1, size.rows - 6))
  except CatchableError as e:
    stderr.writeLine(TuiProgramName & ": could not open " & folder & ": " & e.msg)
    return ExitUsage
  defer: session.close()

  session.header(rt)
  session.setViewportHeight(rt.sourcePaneRows())
  session.learnExtent()
  session.refresh(rt)
  app.notification = describe(session)

  # THE SAME COMPOSITE THE TTY PATH DRAWS, read as text instead of as bytes.
  # `plainFrame` is `terminal_driver`'s and shares `degradeRows` + `composite`
  # with `paint`; this file owns no renderer.
  let screen = rt.shellScreenOf()
  sink.writeLine(plainFrame(caps, screen.styledRows, size.cols, size.rows))
  sink.flushFile()
  ExitOk
