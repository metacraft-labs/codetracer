## main.nim — the `codetracer-gpui` entrypoint. PLAT-20.
##
## ## The shape, and why it is the terminal front-end's shape
##
## `src/frontend/gpui/` is two layers with one line between them, copied
## deliberately from `src/frontend/tui/`:
##
##   app/    SDK-CONSUMER. Carries a `.sdk-consumer` marker. The shell
##           (`shell.nim`), the dock binding (`dock_projection.nim`) and the
##           leaves (`leaves.nim`). Only `leaves.nim` imports GPUI.
##   host/   NATIVE HOST. Exempt on purpose, and the only place allowed to
##           spawn `replay-server`.
##
## This module is the wiring, so it is the one place both sides are in scope at
## once. It stays small: everything it does is decide, open, draw or exit.
##
## ## WHAT THIS BINARY DOES TODAY, SAID PLAINLY
##
## PLAT-20 is *the shell*: "a GPUI window that hosts the renderer-free shell —
## the same `HeadlessApp` the terminal front-end drives — with the layout
## supplied by PLAT-4's model." The debugger SURFACES are PLAT-21 and the
## editing surface is PLAT-22, so a leaf here draws its pane's identity and
## state and not a call trace.
##
## Two boundaries a reader must take before believing more than that:
##
##   1. **There is no gpui-kit `DockArea` behind this window.** gpui-kit is not
##      a dependency of this workspace; three independent blockers were
##      measured and are recorded in PLAT-20's status block. The arrangement
##      this binary draws is read out of the same projected document a
##      `DockArea` would be handed (`leaves.gpuiKitDockAvailable` is the
##      constant that says so), and the container is a flex `div`.
##   2. **Whether a GPU window actually appears depends on how
##      `isonim-gpui`'s Rust shim was built.** Without `--features
##      gpui-backend` the shim is a shadow-tree implementation and
##      `createWindow` opens nothing — isonim-gpui's own `Cargo.toml` says so.
##      `--report-plan` therefore exists: it prints what GPUI *would* execute,
##      which is the verification tier PLAT-19 established, and it is what the
##      integration tests read.

when defined(js):
  {.error: "src/frontend/gpui is native-only: it opens a window.".}

import std/[os, strutils]

import isonim_gpui/renderer
import isonim_gpui/window

import ./app/shell
import ./app/leaves
import ./host/gpui_host

const GpuiHelpText = """
codetracer-gpui — CodeTracer's GPUI front-end (PLAT-20: the shell)

USAGE:
  codetracer-gpui [options] <trace-folder>

  Normally reached as `ct replay --ui=gpui <trace-folder>`; `ct` resolves
  `--ui` and execs this binary, and the launcher never learns about the flag.

OPTIONS:
  --report-plan     Build the window's render plan, print it, and exit 0
                    without entering an event loop. What GPUI would execute.
  --width=<px>      Window width  (default 1440)
  --height=<px>     Window height (default 900)
  --version         Print the version and exit
  --help            Print this and exit

NOT YET, AND REFUSED RATHER THAN IGNORED:
  the debugger panes are PLAT-21 and the editing surface is PLAT-22, so a
  leaf here names its pane and its state. `--headless` belongs to the
  terminal front-end and `ct` refuses it with `--ui=gpui` before this binary
  is reached.
"""

type
  GpuiCommandKind = enum
    gckOpen
    gckHelp
    gckVersion
    gckUsageError

  GpuiCommand = object
    kind: GpuiCommandKind
    traceFolder: string
    reportPlan: bool
    width: int
    height: int
    message: string

func parseGpuiCommand*(argv: openArray[string]): GpuiCommand =
  ## argv -> a decision. No I/O, so the whole of it is assertable without a
  ## process — `app/cli.parseTuiCommand`'s own split, one binary over.
  result = GpuiCommand(kind: gckOpen, width: DefaultGpuiViewport.width,
                       height: DefaultGpuiViewport.height)
  var positional: seq[string] = @[]
  for arg in argv:
    if arg == "--help" or arg == "-h":
      return GpuiCommand(kind: gckHelp)
    elif arg == "--version":
      return GpuiCommand(kind: gckVersion)
    elif arg == "--report-plan":
      result.reportPlan = true
    elif arg.startsWith("--width="):
      try: result.width = parseInt(arg["--width=".len .. ^1])
      except ValueError:
        return GpuiCommand(kind: gckUsageError,
          message: "codetracer-gpui: --width needs an integer")
    elif arg.startsWith("--height="):
      try: result.height = parseInt(arg["--height=".len .. ^1])
      except ValueError:
        return GpuiCommand(kind: gckUsageError,
          message: "codetracer-gpui: --height needs an integer")
    elif arg == "--headless":
      # `ct` already refuses this combination (ui-selection.md §8). Refusing it
      # HERE TOO is deliberate: a user who runs the component directly gets the
      # same answer, and §8's rule does not depend on which door they used.
      return GpuiCommand(kind: gckUsageError,
        message: "codetracer-gpui: '--headless' renders one settled screen in" &
                 " the terminal front-end; the spelling is" &
                 " 'ct replay --ui=tui --headless <trace>'")
    elif arg.startsWith("-"):
      return GpuiCommand(kind: gckUsageError,
        message: "codetracer-gpui: unknown option '" & arg & "'")
    else:
      positional.add arg
  if positional.len == 0:
    return GpuiCommand(kind: gckUsageError,
      message: "codetracer-gpui: name a recording folder" &
               " (ct replay --ui=gpui <trace-folder>)")
  if positional.len > 1:
    return GpuiCommand(kind: gckUsageError,
      message: "codetracer-gpui: one recording at a time; got " &
               $positional.len)
  result.traceFolder = positional[0]

proc runOpen(cmd: GpuiCommand): int =
  ## Open the recording, build the shell, draw the leaves.
  let session = openGpuiTrace(cmd.traceFolder)
  var shell = newGpuiShell(DockViewport(width: cmd.width, height: cmd.height,
                                        dockExtent: DefaultGpuiViewport.dockExtent))
  # `toBackendService` is the adapter `headless_session` itself uses to inject
  # the stdio transport as the SDK's `BackendService` (spec §3.1). The shell
  # takes its backend BY INJECTION and never constructs one — that is
  # `HeadlessApp.openSession`'s own rule — so the host owns the process and the
  # shell owns nothing that can spawn.
  let slot = shell.app.openSession(session.backend.toBackendService(),
                                   title = cmd.traceFolder)
  let windowId = WindowId(0)
  let opened = shell.openWindowForSession(windowId, slot.id)
  if opened.kind == wsRefused:
    stderr.writeLine("codetracer-gpui: could not open a window: " &
                     $opened.problem.kind)
    return 1

  var r: GpuiRenderer
  let leafSet = shell.leavesFor(windowId)
  let drawn = renderLeaves(r, leafSet)

  if cmd.reportPlan:
    # No window and no event loop: print what GPUI would execute and stop.
    # `verifyRenderPlan` is asserted rather than assumed, because a plan that
    # cannot be built is a defect this binary must not exit 0 over.
    if not leafPlanIsValid(r, drawn):
      stderr.writeLine("codetracer-gpui: the render plan did not verify")
      return 1
    echo leafPlanJson(r, drawn)
    return 0

  let win = createWindow("CodeTracer — " & cmd.traceFolder,
                         float(cmd.width), float(cmd.height))
  if not win.show():
    stderr.writeLine("codetracer-gpui: the window would not open")
    return 1
  requestRepaint()
  # PLAT-20 ends here, and saying so is the point: entering an event loop that
  # dispatches input into `shell.applyIn` is the same `LayoutCommand` algebra
  # the terminal already routes, and wiring it is PLAT-21's, whose panes are
  # what there would be to interact with. A loop that spun over leaves drawing
  # their own names would be a demo.
  win.destroy()
  0

proc main() =
  let cmd = parseGpuiCommand(commandLineParams())
  case cmd.kind
  of gckHelp:
    echo GpuiHelpText
    quit(0)
  of gckVersion:
    echo "codetracer-gpui " & gpuiFrontEndVersion()
    quit(0)
  of gckUsageError:
    stderr.writeLine(cmd.message)
    quit(2)
  of gckOpen:
    try:
      quit(runOpen(cmd))
    except CatchableError as e:
      stderr.writeLine("codetracer-gpui: " & e.msg.splitLines()[0])
      quit(1)

when isMainModule:
  main()
