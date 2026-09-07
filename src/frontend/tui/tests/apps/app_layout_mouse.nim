## app_layout_mouse.nim — PLAT-6 snapshot app: the WHOLE FRONT-END with the
## layout binding opted in, driven by real SGR-1006 MOUSE BYTES.
##
## ## WHY THIS IS NOT `apps/app_layout_gestures.nim`
##
## That app hosts the same `TuiRuntime` and drives it with real KEY bytes, and
## its barrier is the `:` prompt: typing `:` moves the cursor off the
## bottom-right cell and `Enter` puts it back, so every step of a typed command
## is a position the cursor was not at a moment earlier.
##
## **A mouse report opens no prompt, so that barrier does not exist for it.**
## With no prompt open `runtime.promptCursor` answers `(false, …)`, the epilogue
## is empty and the cursor rests where `dual_snap.waitForCompleteFrame` looks —
## which is ALREADY TRUE from the previous frame. A parent that waited there
## after sending a press would be satisfied by the frame BEFORE the press and
## would read the pre-gesture screen against the post-gesture model. That is
## codetracer-specs/Testing/Verification-Harness-Traps.md §3 arriving through a
## barrier rather than through a timeout, and it is the reason this app exists
## as its own binary rather than as two more sends into the gesture app: the fix
## is a `FrameEpilogue`, and installing one in `app_layout_gestures.nim` would
## take away the barrier its own suite depends on.
##
## ## THE BARRIER, AND WHY IT IS `step + 1`
##
## `testing/test_app_runtime.runSnapshotApp` increments its step counter on any
## input that asked for a repaint, and `runtime.routeMouseReport` asks for one
## on every report the binding was offered — `LayoutAction.message` is never
## empty, so the status line has always changed. So the step counter counts the
## mouse reports this child has acted on, and parking the cursor at
## `(0, step + 1)` gives every report its OWN barrier.
##
## `step + 1` rather than `step`, for `app_layout_transients.cursorParkColumn`'s
## reason and it is worth restating: a freshly spawned terminal's cursor is
## ALREADY at `(0, 0)`, so a parent waiting for `(0, 0)` would be satisfied
## before the child had written a byte and would snapshot a blank screen.
##
## ## THERE IS NO DEBUGGER HERE, AND THAT COSTS THIS APP NOTHING
##
## `TuiRuntime.dispatcher` is a `Dispatcher` with no ViewModels, which
## `app/commands/interpreter.nim` documents as "not wired" and answers
## `drUnavailable` BY NAME. The layout gestures act on a `Layout` and need no
## debugger at all, which is why they are a separate surface in the first place.
##
## ## No mocks
##
## The runtime, the binding, the layout model and the SGR-1006 decoder are all
## the product's own, constructed through `app_layout_gestures.newBoundRuntime`
## — the same two calls `main.nim` makes under `--layout-binding` — so the two
## Tier-2 apps cannot disagree about what "with the binding on" means.

import isonim_tui

import ../../app/runtime
import ./app_layout_gestures as gestureApp

const
  Cols* = gestureApp.Cols
  Rows* = gestureApp.Rows
    ## 80x24, which selects the Compact profile: the one arrangement that has a
    ## bare pane with its own title row (draggable) AND a tab stack (clickable
    ## and scrollable) on the same screen.

var
  current: TuiRuntime = nil
  currentStep = 0

proc ensureRuntime(cols, rows: int) =
  if current.isNil:
    current = gestureApp.newBoundRuntime(cols, rows)
  elif current.width != cols or current.height != rows:
    current.resize(cols, rows)

proc buildTree*(r: TerminalRenderer; cols, rows, step: int): TerminalNode =
  ## The step is remembered for the epilogue and is NOT an input to the tree:
  ## what changes this screen is `handleInput`, which is where the real bytes
  ## arrive.
  currentStep = step
  ensureRuntime(cols, rows)
  styledRowsTree(r, current.shellScreenOf().styledRows)

proc buildTree*(r: TerminalRenderer; cols, rows: int): TerminalNode =
  buildTree(r, cols, rows, 0)

proc handleInput*(token: string): bool =
  ## CHILD-SIDE ONLY: nothing in a test process may call this, or the
  ## in-process runtime the suite builds would stop being a fresh one.
  if current.isNil:
    return false
  current.handleToken(token, 0'i64).repaint

proc cursorParkColumn*(step, cols: int): int =
  ## Where the epilogue parks the cursor after the frame for `step`. See this
  ## module's header on why the off-by-one IS the barrier.
  min(max(0, step) + 1, max(0, cols - 1))

proc framePrologue*(cols, rows: int): string =
  ## CTUI-9's cursor SHAPE and visibility for the current mode. Before the
  ## frame; it moves nothing.
  discard cols
  discard rows
  if current.isNil: "" else: cursorControlBytes(current.modal.mode)

proc frameEpilogue*(cols, rows: int): string =
  ## `CSI 1 ; <col+1> H` — 1-based, per
  ## <https://invisible-island.net/xterm/ctlseqs/ctlseqs.html>, "Cursor
  ## Position".
  discard rows
  "\x1b[1;" & $(cursorParkColumn(currentStep, cols) + 1) & "H"

when isMainModule:
  # Imported HERE rather than at the top so a test that merely imports this
  # module for `buildTree` does not carry an unused `std/os` with it.
  import std/os
  import ../../testing/test_app_runtime
  quit(snapshotAppMain(
    proc(r: TerminalRenderer; cols, rows, step: int): TerminalNode =
      buildTree(r, cols, rows, step),
    commandLineParams(),
    input = handleInput,
    prologue = framePrologue,
    epilogue = frameEpilogue))
