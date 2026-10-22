## test_point_menu_ops.nim — M76 (codetracer#843), the HEADLESS half: the
## program menu's Debug items that are not steps, as the shared table both
## native menus read (`viewmodels/point_menu_ops`), and the store operations
## the tracepoint items perform (`replay_data_store.setTracepointsEnabled`,
## `deleteTracepoint`, `enabledTracepointSpecs`).
##
## The front-end half — the terminal's menu enabling these items, choosing
## them over a real session, Stop ending a real `replay-server` — is
## `src/frontend/tui/tests/test_plat48_top_bar.nim`'s M76 suites; GPUI's menu
## is `src/frontend/gpui/tests/test_plat48_gpui_plan.nim`. This file holds what
## is front-end-independent, per the headless-first policy.
##
## ## ONE STAND-IN, AND WHY
##
## `MockBackendService` is the transport `createReplayDataStore` requires. It
## answers nothing that is asserted: the tracepoint items are STORE writes
## (a post-hoc tracepoint is not on the engine between sweeps), and the one
## thing this file asks of the transport is that it was sent NOTHING — the
## proof that enabling, disabling or deleting a tracepoint makes no request.
## The rows are written by the product's own sweep decoder
## (`applyTracepointResults`), never constructed here.

import std/[strutils, unittest]

import isonim/core/signals

import ../../backend/mock_backend
import ../../store/[replay_data_store, types]
import ../../viewmodels/[point_menu_ops, product_menu]

const ExpectedAssertions = 83

var countedAssertions = 0

template ck(condition: untyped) =
  inc countedAssertions
  check condition

proc newStore(): (ReplayDataStore, MockBackendService) =
  let mock = newMockBackendService(autoRespond = true)
  let store = createReplayDataStore(mock.toBackendService())
  mock.clearReceivedCommands()
  (store, mock)

const
  Main = "/work/calc/main.py"
  Other = "/work/calc/ops.py"

proc sweep(store: ReplayDataStore) =
  ## Three tracepoints as the product's sweep decoder records them: two in
  ## `main.py` (one with hits, one without) and one in another file.
  store.applyTracepointResults(
    @[TracepointSweepSpec(tracepointId: 0, path: Main, line: 31,
                          expression: "log(left)"),
      TracepointSweepSpec(tracepointId: 1, path: Main, line: 41,
                          expression: "log(right)"),
      TracepointSweepSpec(tracepointId: 2, path: Other, line: 7,
                          expression: "log(x)")],
    @[TracepointSweepHit(tracepointId: 0, rrTicks: 33, path: Main, line: 31),
      TracepointSweepHit(tracepointId: 0, rrTicks: 63, path: Main, line: 31),
      TracepointSweepHit(tracepointId: 2, rrTicks: 90, path: Other, line: 7)])
  # And a breakpoint at a tracepoint's line, which no tracepoint item touches.
  store.applyVerifiedBreakpoints(Main, [31])

proc tracepointAt(store: ReplayDataStore; path: string;
                  line: int): (bool, PointListEntry) =
  for r in store.pointList.rows.val:
    if r.kind == PointKindTracepoint and r.path == path and r.line == line:
      return (true, r)
  (false, PointListEntry())

suite "M76: the Debug menu's point items, as one table":

  test "every point item of the product menu's Debug folder has an operation":
    # The table is read against the MENU, not against itself: a Debug item
    # whose action names a breakpoint or tracepoint and has no operation is
    # an item a native menu would draw disabled.
    var debugActions: seq[string] = @[]
    for folder in productMenuTree("ct").children:
      if folder.label == "Debug":
        for it in folder.children:
          debugActions.add it.action
    ck StopMenuAction in debugActions
    var named = 0
    for op in pmoDeleteBreakpoint .. pmoRunAllTracepoints:
      checkpoint($op & " -> " & PointMenuActions[op])
      ck PointMenuActions[op] in debugActions
      ck pointMenuOpOf(PointMenuActions[op]) == op
      inc named
    ck named == 13
    ck pointMenuOpOf("aBreakpoint") == pmoNone       # a step-like toggle, not here
    ck pointMenuOpOf("forwardNext") == pmoNone
    ck pointMenuOpOf("") == pmoNone
    ck pointMenuOpOf(StopMenuAction) == pmoNone

  test "the caret items are exactly the ones that name one point":
    ck actsAtCaret(pmoDeleteBreakpoint) and actsAtCaret(pmoEnableBreakpoint) and
       actsAtCaret(pmoDisableBreakpoint) and actsAtCaret(pmoAddTracepoint) and
       actsAtCaret(pmoDeleteTracepoint) and actsAtCaret(pmoEnableTracepoint) and
       actsAtCaret(pmoDisableTracepoint)
    ck not actsAtCaret(pmoDeleteAllBreakpoints)
    ck not actsAtCaret(pmoEnableAllBreakpoints)
    ck not actsAtCaret(pmoDisableAllBreakpoints)
    ck not actsAtCaret(pmoEnableAllTracepoints)
    ck not actsAtCaret(pmoDisableAllTracepoints)
    ck not actsAtCaret(pmoRunAllTracepoints)

suite "M76: the tracepoint items over the store":

  test "a sweep records each tracepoint's expression, which Run All sends again":
    let (store, mock) = newStore()
    store.sweep()
    ck store.tracepointAt(Main, 31)[1].expression == "log(left)"
    ck store.tracepointAt(Main, 41)[1].expression == "log(right)"
    let specs = store.enabledTracepointSpecs(firstId = 5)
    ck specs.len == 3
    ck specs[0].tracepointId == 5 and specs[2].tracepointId == 7
    ck specs[0].path == Main and specs[0].line == 31 and
       specs[0].expression == "log(left)"
    ck mock.receivedCommands.len == 0

  test "a later sweep at a line with a NEW expression is what Run All sends":
    # The user runs `:tracepoint` again on a line that already has one, with
    # a different expression: the row is the same tracepoint (merged by
    # `(path, line)`), and the next "Run All Tracepoints" must sweep what the
    # user typed LAST, not the first expression.
    let (store, mock) = newStore()
    store.sweep()
    store.applyTracepointResults(
      @[TracepointSweepSpec(tracepointId: 9, path: Main, line: 41,
                            expression: "log(right * 2)")], @[])
    var at41 = 0
    for r in store.pointList.rows.val:
      if r.kind == PointKindTracepoint and r.path == Main and r.line == 41:
        inc at41
    ck at41 == 1
    ck store.tracepointAt(Main, 41)[1].expression == "log(right * 2)"
    var sent = ""
    for s in store.enabledTracepointSpecs(firstId = 0):
      if s.path == Main and s.line == 41: sent = s.expression
    ck sent == "log(right * 2)"
    ck mock.receivedCommands.len == 0

  test "a tracepoint on a line that has a breakpoint is a row of its own":
    # The breakpoint FIRST, then the sweep at its line: the sweep must add a
    # tracepoint row (which the menu's tracepoint items act on and Run All
    # sends again), and leave the breakpoint row a breakpoint — not annotate
    # it as if it were the tracepoint.
    let (store, mock) = newStore()
    store.applyVerifiedBreakpoints(Main, [31])
    store.applyTracepointResults(
      @[TracepointSweepSpec(tracepointId: 0, path: Main, line: 31,
                            expression: "log(left)")],
      @[TracepointSweepHit(tracepointId: 0, rrTicks: 33, path: Main, line: 31)])
    ck store.tracepointAt(Main, 31)[0]
    ck store.tracepointAt(Main, 31)[1].expression == "log(left)"
    var bp: seq[PointListEntry] = @[]
    for r in store.pointList.rows.val:
      if r.kind == PointKindBreakpoint: bp.add r
    ck bp.len == 1
    ck bp[0].line == 31 and bp[0].expression == "" and
       not bp[0].resolution.startsWith("swept")
    ck store.enabledTracepointSpecs(firstId = 0).len == 1
    ck store.deleteTracepoint(Main, 31)
    var bpAfter = 0
    for r in store.pointList.rows.val:
      if r.kind == PointKindBreakpoint and r.line == 31: inc bpAfter
    ck bpAfter == 1
    ck mock.receivedCommands.len == 0

  test "disable / enable at a line touch that row only; the All forms every row":
    let (store, mock) = newStore()
    store.sweep()
    ck store.setTracepointsEnabled(Main, 41, enabled = false) == 1
    ck not store.tracepointAt(Main, 41)[1].enabled
    ck store.tracepointAt(Main, 31)[1].enabled
    ck store.tracepointAt(Other, 7)[1].enabled
    # Disabling what is disabled changes nothing, and says so.
    ck store.setTracepointsEnabled(Main, 41, enabled = false) == 0
    # A line with no tracepoint (the breakpoint's file, another line).
    ck store.setTracepointsEnabled(Main, 40, enabled = false) == 0
    # A disabled tracepoint is not swept again.
    let specs = store.enabledTracepointSpecs(firstId = 0)
    ck specs.len == 2
    for s in specs:
      ck s.line != 41
    ck store.setTracepointsEnabled(Main, 41, enabled = true) == 1
    ck store.setTracepointsEnabled("", 0, enabled = false, every = true) == 3
    ck store.enabledTracepointSpecs(firstId = 0).len == 0
    ck store.setTracepointsEnabled("", 0, enabled = true, every = true) == 3
    # The breakpoint at line 31 is not a tracepoint and kept its state.
    var bp = 0
    for r in store.pointList.rows.val:
      if r.kind == PointKindBreakpoint:
        inc bp
        ck r.enabled
    ck bp == 1
    ck mock.receivedCommands.len == 0

  test "delete takes the row and its hits, and nothing else":
    let (store, mock) = newStore()
    store.sweep()
    ck store.pointList.tracepointHits.val.len == 3
    ck store.deleteTracepoint(Main, 31)
    ck not store.tracepointAt(Main, 31)[0]
    ck store.tracepointAt(Main, 41)[0]
    ck store.tracepointAt(Other, 7)[0]
    # Its two hits are gone; the other file's hit stays.
    ck store.pointList.tracepointHits.val.len == 1
    ck store.pointList.tracepointHits.val[0].path == Other
    # The breakpoint on the same line is not a tracepoint.
    var bp = 0
    for r in store.pointList.rows.val:
      if r.kind == PointKindBreakpoint and r.line == 31: inc bp
    ck bp == 1
    ck not store.deleteTracepoint(Main, 31)
    ck mock.receivedCommands.len == 0

suite "M76 point menu ops: assertion count":
  test "every assertion ran":
    echo "CHECKS: " & $countedAssertions
    check countedAssertions == ExpectedAssertions
