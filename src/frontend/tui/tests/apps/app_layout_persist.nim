## app_layout_persist.nim — PLAT-6 snapshot app: the WHOLE FRONT-END with the
## layout binding opted in **and its arrangement saved and restored**, driven by
## real SGR-1006 mouse bytes.
##
## ## WHY A THIRD TIER-2 APP
##
## `app_layout_mouse.nim` proves a mouse drag rearranges a real terminal. This
## one proves the arrangement is still there **in a second process**, which is
## the only way to test persistence at all: the subject is what one process
## wrote and a different process read, and no amount of driving one process can
## observe that.
##
## It differs from the mouse app in exactly two calls, and they are the two
## `main.nim` makes:
##
##   * `host/layout_store.restoreLayoutForSession(rt, folder)` before the first
##     frame, right after `enableLayoutBinding`;
##   * `host/layout_store.persistLayoutForSession(rt)` after the input loop
##     returns, before the process exits.
##
## Nothing here decides anything about where the document goes, what an
## unreadable one means, or whether there is anything to write —
## `app/layout/persistence.nim` decides all three and `host/layout_store.nim`
## performs them, and this app calls the same two routines a shipped binary
## calls. A test app that reimplemented either would be testing itself.
##
## ## THE TWO ENVIRONMENT VARIABLES, AND WHY THEY ARE ENVIRONMENT VARIABLES
##
##   * `CODETRACER_TUI_LAYOUT_TRACE` stands in for `main.nim`'s trace folder.
##     The layout store never opens it — it only keys the document by its
##     canonical path — so a directory is a faithful stand-in for a recording
##     here, and everything that DOES read a recording (`traceFolderProblem`,
##     `openTuiSession`) runs before this in the real binary.
##   * `CODETRACER_TUI_LAYOUT_BINDING` stands in for `--layout-binding`. Set,
##     this app is the bound child; unset, it is the same child minus one call,
##     which is what makes the OFF arm a comparison of one difference rather
##     than of two programs.
##
## `CODETRACER_TUI_LAYOUT_DIR` is read by `host/layout_store.nim` itself and is
## not this module's business; the suite sets all three on the child.
##
## Environment variables rather than flags because `testing/test_app_runtime
## .parseTestAppArgs` owns `argv` for every app in this directory and a fourth
## private flag there would be a change to a shared harness for one app's sake.
##
## ## THE BARRIER, AND WHY IT IS `step + 1`
##
## `app_layout_mouse.nim`'s header states this in full and it is the same rule:
## `runSnapshotApp` increments its step counter on any input that asked for a
## repaint, `runtime.routeMouseReport` asks for one on every report the binding
## was offered, and parking the cursor at `(0, step + 1)` gives every report its
## OWN barrier. `step + 1` and not `step`, because a freshly spawned terminal's
## cursor is ALREADY at `(0, 0)` and a parent waiting there would be satisfied
## before the child had written a byte.
##
## **AND THAT IS ALSO THE BARRIER FOR A RELAUNCH.** The second process's first
## frame parks at `(0, 1)`, which the second pty's cursor was not at a moment
## earlier — so "the second process is ready" is a position rather than a sleep
## or a screen predicate. "The screen has content" would not do: the previous
## process's screen is gone, but a blank frame and a restored frame both take
## time to arrive and only one of them is the subject.
##
## ## THERE IS NO DEBUGGER HERE, AND THAT COSTS THIS APP NOTHING
##
## `TuiRuntime.dispatcher` is a `Dispatcher` with no ViewModels, which
## `app/commands/interpreter.nim` documents as "not wired" and answers
## `drUnavailable` BY NAME. A layout gesture and a layout document need no
## debugger at all.
##
## ## No mocks
##
## The runtime, the binding, the SGR-1006 decoder, the layout model, the JSON
## document and the filesystem are all the product's own. The trace folder is a
## real directory and the state root is a real directory; nothing is stubbed.

import std/os

import isonim_tui

import ../../app/runtime
import ../../host/layout_store
import ./app_layout_gestures as gestureApp

const
  Cols* = gestureApp.Cols
  Rows* = gestureApp.Rows
    ## 80x24, the Compact profile — the one arrangement with a bare pane that
    ## has its own title row (so a press picks it up) beside a tab stack.

  TraceEnvVar* = "CODETRACER_TUI_LAYOUT_TRACE"
  BindingEnvVar* = "CODETRACER_TUI_LAYOUT_BINDING"

var
  current: TuiRuntime = nil
  currentStep = 0

proc ensureRuntime(cols, rows: int) =
  if current.isNil:
    if getEnv(BindingEnvVar).len > 0:
      # THE TWO CALLS `main.nim` MAKES UNDER `--layout-binding`, in the same
      # order: enable the binding, then adopt this recording's document. The
      # message is put on the status line exactly as `main.nim` puts it there,
      # which is what makes "the user is told" observable on a real terminal.
      current = gestureApp.newBoundRuntime(cols, rows)
      let restored = restoreLayoutForSession(current, getEnv(TraceEnvVar))
      if restored.message.len > 0:
        current.app.notification = restored.message
    else:
      # THE OFF ARM. The same call with the same argument, and it opens
      # nothing: `restoreLayoutForSession` refuses on `layoutBindingEnabled`
      # before it computes a path, so no file and no `stat` reaches the state
      # directory. Making the call anyway is deliberate — a child that skipped
      # it would prove that this app does not persist, rather than that the
      # PRODUCT does not persist without the flag.
      current = gestureApp.newUnboundRuntime(cols, rows)
      discard restoreLayoutForSession(current, getEnv(TraceEnvVar))
  elif current.width != cols or current.height != rows:
    current.resize(cols, rows)

proc buildTree*(r: TerminalRenderer; cols, rows, step: int): TerminalNode =
  ## The step is remembered for the epilogue and is NOT an input to the tree:
  ## what changes this screen is `handleInput`, which is where the real bytes
  ## arrive, and — on the first frame — the document this session restored.
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
  # module for `cursorParkColumn` does not carry an unused runtime with it.
  import ../../testing/test_app_runtime

  let status = snapshotAppMain(
    proc(r: TerminalRenderer; cols, rows, step: int): TerminalNode =
      buildTree(r, cols, rows, step),
    commandLineParams(),
    input = handleInput,
    prologue = framePrologue,
    epilogue = frameEpilogue)
  # THE SAVE, AFTER THE LOOP AND BEFORE THE PROCESS ENDS — `main.nim`'s own
  # placement, and the reason it is not a `defer` there either: the arrangement
  # is written once per session rather than once per gesture, because a drag is
  # a press and a release and writing through on each would put two file writes
  # inside one pointer movement for a document nobody reads until the next
  # launch.
  #
  # A failure is named on stderr rather than swallowed, so a suite that finds no
  # document can tell "nothing was written" from "the write failed and nobody
  # said so".
  if not current.isNil:
    let saved = persistLayoutForSession(current)
    if saved.outcome == lpoFailed:
      stderr.writeLine("app_layout_persist: " & saved.message)
  quit(status)
