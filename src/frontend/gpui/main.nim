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
##      a dependency of this workspace; TWO independent blockers were measured
##      and are recorded in PLAT-20's status block. (It was three until
##      2026-09-16, when the toolchain blocker was falsified by compiling
##      gpui-kit with a stable rustc already in this host's store; the package
##      split is what remains.) The arrangement
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
      ## The recording, in `pmDebug`. In `pmEdit` this is the PROJECT root, and
      ## the field is shared deliberately: `ct` passes one positional and the
      ## mode is what says which it is, exactly as `codetracer-tui` parses
      ## `--edit` into `tckEditProject`.
    product: ProductMode
      ## **PLAT-16's dimension, carried into a second front-end.**
      ##
      ## `ProductMode` and NOT a fourth `GpuiCommandKind`, which is the whole
      ## deliverable: edit mode is a PRODUCT mode and `UiMode`/front-end is a
      ## different axis, so a front-end that expressed it as one more command
      ## shape would be the two-dimensions-into-one collapse PLAT-16's own risk
      ## note is written against. `parseGpuiCommand` sets it; every path below
      ## reads it.
    reportPlan: bool
    width: int
    height: int
    message: string

func parseGpuiCommand*(argv: openArray[string]): GpuiCommand =
  ## argv -> a decision. No I/O, so the whole of it is assertable without a
  ## process — `app/cli.parseTuiCommand`'s own split, one binary over.
  result = GpuiCommand(kind: gckOpen, product: pmDebug,
                       width: DefaultGpuiViewport.width,
                       height: DefaultGpuiViewport.height)
  var positional: seq[string] = @[]
  for arg in argv:
    if arg == "--help" or arg == "-h":
      return GpuiCommand(kind: gckHelp)
    elif arg == "--version":
      return GpuiCommand(kind: gckVersion)
    elif arg == "--edit":
      # PLAT-22. THE SAME SPELLING `codetracer-tui` TAKES, and the same reason:
      # `ct edit <project>`'s positional survives `translateArgs` untouched, so
      # the whole translation for that command is prepending the flag that says
      # the positional is a PROJECT rather than a recording. Without it this
      # binary would resolve the folder as a trace and refuse it for having no
      # `trace.json`, which is a true diagnosis of the wrong question.
      result.product = pmEdit
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
  # THE TWO MESSAGES NAME THE TWO MODES SEPARATELY, because a user who typed
  # `ct edit --ui=gpui` and is told to "name a recording folder" has been sent
  # to the wrong documentation. Same defect `--id`'s per-front-end message
  # exists against, one dimension over.
  if positional.len == 0:
    return GpuiCommand(kind: gckUsageError,
      message:
        if result.product == pmEdit:
          "codetracer-gpui: name a project directory" &
          " (ct edit --ui=gpui <project>)"
        else:
          "codetracer-gpui: name a recording folder" &
          " (ct replay --ui=gpui <trace-folder>)")
  if positional.len > 1:
    return GpuiCommand(kind: gckUsageError,
      message: (if result.product == pmEdit: "codetracer-gpui: one project at" &
                  " a time; got " else: "codetracer-gpui: one recording at a" &
                  " time; got ") & $positional.len)
  result.traceFolder = positional[0]

proc editSurfaceFor(cmd: GpuiCommand): EditorSurface =
  ## PLAT-22. **Edit mode's surface: the WORKING TREE, and no recording.**
  ##
  ## `product_mode.sourceContractFor(pmEdit)` is what decides this, and it is
  ## read rather than re-implemented — *"this is a core question, not a terminal
  ## one, and the answer applies to every front-end"*. It says the origin is the
  ## working tree, the model is a text buffer and NOT `SourceVM` (§2.1: *"Edit
  ## mode does not use `SourceVM`"*), so nothing here opens a recording, spawns
  ## a `replay-server` or constructs a source window.
  ##
  ## **THIS FRONT-END CANNOT YET MUTATE, AND IT SAYS SO RATHER THAN PRETENDING
  ## EITHER WAY.** PLAT-16's editing substrate is `isonim-tui`'s
  ## `TextAreaWidget` — grapheme-aware columns, undo coalescing, a delta stack,
  ## all covered by that repository's own suites — and it is a TERMINAL widget:
  ## the `gpui-shell` lane links no `isonim_tui` at all, deliberately, and
  ## `test_gpui_shell_split.nim` asserts that it does not. So `mutableHere` is
  ## `false`, `editorSurfaceForProject` carries the disagreement between the
  ## contract and the medium as a REPORT naming both, and the milestone's status
  ## marks this deliverable partial for exactly that reason. A front-end that
  ## answered `mutable = true` over a buffer nobody can type into would be the
  ## worse of the two failures available here.
  let problem = editProjectProblem(cmd.traceFolder)
  if problem.len > 0:
    return EditorSurface(medium: GpuiMedium, productMode: pmEdit,
                         report: problem)
  let listing = listProjectFiles(cmd.traceFolder)
  if listing.files.len == 0:
    # A project with no files is a REAL state and is reported as itself. The
    # `scanned` count is what tells it from a listing that read nothing:
    # zero files out of zero entries is an empty project, zero files out of
    # many is a defect in the walk (Verification-Harness-Traps §4).
    return EditorSurface(medium: GpuiMedium, productMode: pmEdit,
                         report: "no source files under " & cmd.traceFolder &
                                 " (" & $listing.scanned & " entries scanned)")
  let relative = listing.files[0]
  editorSurfaceForProject(
    path = relative,
    text = readProjectFile(cmd.traceFolder, relative),
    medium = GpuiMedium,
    mutableHere = false,
    viewportHeight = editorRowsForViewport(cmd.height))

proc runEdit(cmd: GpuiCommand): int =
  ## `ct edit --ui=gpui <project>`, end to end, with NO recording open.
  var shell = newGpuiShell(DockViewport(width: cmd.width, height: cmd.height,
                                        dockExtent: DefaultGpuiViewport.dockExtent))
  let surface = editSurfaceFor(cmd)
  # `openWindow` and not `openWindowForSession`: there is no session. That is a
  # real product state rather than a test affordance — `shell.openWindow`'s own
  # header says so — and it is exactly the state edit mode is in, because edit
  # mode's subject is the working tree and a `HeadlessSessionSlot` is a replay
  # session.
  let windowId = WindowId(0)
  let opened = shell.openWindow(windowId, initLayout(defaultReplayLayout()))
  if opened.kind == wsRefused:
    stderr.writeLine("codetracer-gpui: could not open a window: " &
                     $opened.problem.kind)
    return 1
  var r: GpuiRenderer
  let leafSet = shell.leavesFor(windowId)
  let drawn = renderLeaves(r, leafSet, surface)
  if cmd.reportPlan:
    if not leafPlanIsValid(r, drawn):
      stderr.writeLine("codetracer-gpui: the render plan did not verify")
      return 1
    echo leafPlanJson(r, drawn)
    return 0
  let win = createWindow("CodeTracer — " & cmd.traceFolder & " [EDIT]",
                         float(cmd.width), float(cmd.height))
  if not win.show():
    stderr.writeLine("codetracer-gpui: the window would not open")
    return 1
  requestRepaint()
  win.destroy()
  0

proc runOpen(cmd: GpuiCommand): int =
  ## Open the recording, build the shell, draw the leaves.
  if cmd.product == pmEdit:
    return runEdit(cmd)
  let session = openGpuiTrace(cmd.traceFolder)
  var shell = newGpuiShell(DockViewport(width: cmd.width, height: cmd.height,
                                        dockExtent: DefaultGpuiViewport.dockExtent))
  # `toBackendService` is the adapter `headless_session` itself uses to inject
  # the stdio transport as the SDK's `BackendService` (spec §3.1). The shell
  # takes its backend BY INJECTION and never constructs one — that is
  # `HeadlessApp.openSession`'s own rule — so the host owns the process and the
  # shell owns nothing that can spawn.
  #
  # `adopt = session.sdk` IS THE WHOLE OF WHY THE PANES DRAW ANYTHING. Without
  # it `openSession` builds a SECOND `DebuggerSession` over the same transport,
  # in `dspCreated`, with nil panel ViewModels and an empty store — so
  # `leavesFor` reports every pane as not launched while this process holds a
  # live debugger. Measured on the shipped binary against `calc` before the
  # repair: five leaves, five `— waiting for the session to launch`, rc 0.
  # `headless_app.openSession`'s own doc comment carries the finding.
  let slot = shell.app.openSession(session.backend.toBackendService(),
                                   title = cmd.traceFolder,
                                   adopt = session.sdk)
  let windowId = WindowId(0)
  let opened = shell.openWindowForSession(windowId, slot.id)
  if opened.kind == wsRefused:
    stderr.writeLine("codetracer-gpui: could not open a window: " &
                     $opened.problem.kind)
    return 1

  # PLAT-22. THE PRODUCT MODE DECIDES WHICH PANE IS IN FRONT, and it does it
  # through `headless_app.activatePane` — which, measured on 2026-09-16, had
  # FIVE call sites and every one of them in `test_headless_app_entrypoint.nim`.
  # PLAT-14's own audit recorded that as *"no production caller in this
  # repository"*, PLAT-20 recorded it again, and this is the first route that
  # genuinely needs it: `ct --ui=gpui edit .` arrives with the editor as the
  # thing the user asked for, and a front-end that opened on the debug-controls
  # pane would be answering a different request.
  #
  # It is called for BOTH modes, not only for edit, so the call is on the
  # ordinary path rather than behind a flag nobody sets — a production caller
  # that only one command word reaches is one command word away from being no
  # production caller again.
  discard slot.activatePane(
    if cmd.product == pmEdit: paneEditor else: paneDebugControls)

  # The source window. PLAT-22: the editor is wired to the same `SourceVM` the
  # terminal's editor uses, and the host is what fills it — see
  # `gpui_host.newGpuiSourceService`. `editorRowsForViewport` is derived from
  # the window height rather than chosen, so a taller window holds more lines
  # and `followExecutionPointer` scrolls the window the editor actually draws.
  let sourceService = newGpuiSourceService(session, cmd.traceFolder,
                                           editorRowsForViewport(cmd.height))
  sourceService.serveWindow()

  # THE VALUES IN SCOPE AT THE STOP, requested here because nothing else does.
  #
  # `StateVM.currentVariables` is filled by `ct/load-locals`, and the terminal's
  # `tui_session.refresh` is the only thing in this repository that asks for it.
  # Without this call the state pane renders "locals — no variables at this
  # position" and the editor shows no inline value, on every session, for ever —
  # which is the same "the mechanism works and nothing feeds it" shape as the
  # dock reader, `gpuiRowBudget` and `activatePane`. Measured on `calc` before
  # the call was added.
  #
  # TOTAL, like the terminal's: `requestAndLoadLocals` raises when the engine
  # declines, and a front-end that let that escape would drop a window over a
  # pane that would merely have been empty.
  try:
    session.requestAndLoadLocals()
  except CatchableError:
    discard
  let surface = editorSurfaceFor(
    source = sourceService.vm,
    editor = session.session.editorVM,
    state = session.session.stateVM,
    flow = session.session.flowVM,
    availability = sourceService.availability(),
    budget = gpuiRowBudget(),
    medium = GpuiMedium)

  var r: GpuiRenderer
  let leafSet = shell.leavesFor(windowId)
  let drawn = renderLeaves(r, leafSet, surface)

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
