## viewmodels/point_menu_ops.nim — the program menu's Debug items that are
## not steps: Stop, and the breakpoint and tracepoint items, as ONE table the
## native front ends share (M76, codetracer#843).
##
## ## Why a table, and why here
##
## The product menu (`product_menu.nim`) names each item by the desktop's
## `ClientAction`, and the desktop performs them in `ui_js.nim`'s action
## table: `aDeleteBreakpoint` → `removeBreakpointAtPosition`, …,
## `aCollectEnabledTracepointResults` → `ui/trace.runTracepoints`. The
## terminal and the GPUI window draw the same menu and decide, item by item,
## whether they perform it. Until this module each of them answered that from
## its own static list, and neither list named these items, although both
## front ends already performed every one of them from the editor's context
## menu — so the menu drew them disabled (codetracer#843).
##
## The answer to "does this front end perform the item" and the dispatch of the
## item are read from the same value here (`pointMenuOpOf`), so a front end
## cannot enable an item it then fails to run: its `menuActionAvailable` and
## its `runMenuAction` both ask this one function.
##
## Owns: the action → operation table, and which operations act at the
## editor's caret line (the desktop's `pointsOperationsSetup`: the active
## editor's file, the Monaco cursor's line).
##
## Refuses to own: performing them. The store writes are
## `replay_data_store`'s (`setTracepointsEnabled`, `deleteTracepoint`,
## `enabledTracepointSpecs`), the engine requests are `headless_session`'s,
## and the native hosts' one performer over both is
## `tui/host/session_driver.performPointMenuOp`.
##
## Pure; compiles on C, JS and wasm32.

type
  PointMenuOp* = enum
    ## One Debug-menu point item, by what it does.
    pmoNone
    pmoDeleteBreakpoint       ## the breakpoint at the caret's line
    pmoDeleteAllBreakpoints   ## every breakpoint, every file
    pmoEnableBreakpoint       ## the breakpoint at the caret's line
    pmoEnableAllBreakpoints   ## every breakpoint
    pmoDisableBreakpoint      ## the breakpoint at the caret's line
    pmoDisableAllBreakpoints  ## every breakpoint
    pmoAddTracepoint
      ## The tracepoint editor, opened on the caret's line — the FRONT END's
      ## to open (the terminal's command line, GPUI's omnibar); its Enter
      ## sweeps.
    pmoDeleteTracepoint       ## the tracepoint at the caret's line
    pmoEnableTracepoint       ## the tracepoint at the caret's line
    pmoEnableAllTracepoints   ## every tracepoint
    pmoDisableTracepoint      ## the tracepoint at the caret's line
    pmoDisableAllTracepoints  ## every tracepoint
    pmoRunAllTracepoints
      ## Every ENABLED tracepoint swept over the recording again.

const
  StopMenuAction* = "stop"
    ## The Debug menu's *Stop* (`product_menu`'s `item("Stop", "stop")`),
    ## which ends the debugging session
    ## (Debugger-Controls.md § "Ending a session from inside it").

  PointMenuActions*: array[pmoDeleteBreakpoint .. pmoRunAllTracepoints,
                           string] = [
    "aDeleteBreakpoint", "aDeleteAllBreakpoints", "aEnableBreakpoint",
    "aEnableAllBreakpoint", "aDisableBreakpoint", "aDisableAllBreakpoints",
    "aTracepoint", "aDeleteTracepoint", "aEnableTracepoint",
    "aEnableAllTracepoints", "aDisableTracepoint", "aDisableAllTracepoints",
    "aCollectEnabledTracepointResults"]
    ## Each operation's `ClientAction`, spelled as the product menu spells it
    ## (`aEnableAllBreakpoint` is singular there and on the desktop).

func pointMenuOpOf*(action: string): PointMenuOp =
  ## The operation a menu item's `ClientAction` is, or `pmoNone`.
  for op, name in PointMenuActions:
    if name == action:
      return op
  pmoNone

func actsAtCaret*(op: PointMenuOp): bool =
  ## Whether `op` acts on one point — the one on the editor caret's line —
  ## rather than on every point.
  op in {pmoDeleteBreakpoint, pmoEnableBreakpoint, pmoDisableBreakpoint,
         pmoAddTracepoint, pmoDeleteTracepoint, pmoEnableTracepoint,
         pmoDisableTracepoint}
