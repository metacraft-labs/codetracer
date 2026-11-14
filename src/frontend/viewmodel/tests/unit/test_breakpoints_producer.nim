## test_breakpoints_producer.nim
##
## `sdk/breakpoints` is the one producer of breakpoints for every front-end:
## the terminal and GPUI plan with it and send synchronously
## (`HeadlessDebugSession`), the desktop and the web plan with it and send
## through the session store's backend (`requestBreakpoints`). This suite
## holds the planners and the store side to the rules the gutter, the menus
## and the program menu rely on.
##
## The backend is a `MockBackendService` standing in for the DAP transport
## only: what is asserted is the request the engine would receive and the
## rows the store holds before and after its answer.

import std/[json, options, unittest]

import isonim/core/[signals, async_compat]

import backend/[backend_service, mock_backend]
import store/[replay_data_store, types]
import sdk/breakpoints

proc rowsOf(store: ReplayDataStore; path: string): seq[PointListEntry] =
  for r in store.pointList.rows.val:
    if r.kind == PointKindBreakpoint and r.path == path:
      result.add r

proc answer(lines: openArray[int]; verified = true): JsonNode =
  var bps = newJArray()
  for l in lines:
    bps.add %*{"verified": verified, "line": l}
  %*{"type": "response", "command": "setBreakpoints", "success": true,
     "body": {"breakpoints": bps}}

suite "planning a breakpoint change":

  test "a toggle adds a whole-line breakpoint, and removes one armed or not":
    let held = @[BreakpointSpec(line: 3, enabled: true),
                 BreakpointSpec(line: 7, enabled: false)]
    let added = plannedToggle(held, 5)
    check added.len == 3
    check breakpointAt(added, 5).get.enabled
    check breakpointAt(added, 5).get.column == 0
    check plannedToggle(held, 3).len == 1
    check breakpointAt(plannedToggle(held, 7), 7).isNone   # disabled removed

  test "an anchored breakpoint replaces the line's and carries its condition":
    let held = @[BreakpointSpec(line: 4, enabled: true)]
    let plan = plannedAnchored(held, 4, 9, condition = "i > 2")
    check plan.len == 1
    check plan[0].column == 9
    check plan[0].condition == "i > 2"

  test "a condition goes on the breakpoint it names, and needs one":
    let held = @[BreakpointSpec(line: 2, enabled: true),
                 BreakpointSpec(line: 5, column: 7, enabled: false)]
    check plannedCondition(held, 9, 0, "x > 1").isNone
    # the line breakpoint, whichever column the menu was opened at
    let onLine = plannedCondition(held, 2, 4, "x > 1").get
    check breakpointAt(onLine, 2).get.condition == "x > 1"
    check breakpointAt(onLine, 2).get.column == 0
    check breakpointAt(onLine, 5).get.condition == ""
    # a column breakpoint keeps its column and its disarmed state
    let atColumn = plannedCondition(held, 5, 7, "i > 1").get
    check breakpointAt(atColumn, 5).get.column == 7
    check breakpointAt(atColumn, 5).get.condition == "i > 1"
    check not breakpointAt(atColumn, 5).get.enabled
    # "" clears it
    let cleared = plannedCondition(atColumn, 5, 7, "").get
    check breakpointAt(cleared, 5).get.condition == ""

  test "enabling needs a breakpoint on the line":
    let held = @[BreakpointSpec(line: 2, enabled: true)]
    check plannedEnabled(held, 9, false).isNone
    let plan = plannedEnabled(held, 2, false)
    check plan.isSome and not plan.get[0].enabled

  test "the request carries the armed ones only, with column, condition and message":
    let plan = @[
      BreakpointSpec(line: 1, enabled: true),
      BreakpointSpec(line: 2, column: 5, condition: "x == 1", enabled: true),
      BreakpointSpec(line: 3, column: 7, logMessage: "hit", enabled: true),
      BreakpointSpec(line: 4, enabled: false)]
    let args = setBreakpointsArgs("/src/main.nim", plan)
    check args["source"]["path"].getStr == "/src/main.nim"
    check args["source"]["name"].getStr == "main.nim"
    let bps = args["breakpoints"].getElems
    check bps.len == 3
    check not bps[0].hasKey("column")
    check bps[1]["column"].getInt == 5
    check bps[1]["condition"].getStr == "x == 1"
    check bps[2]["logMessage"].getStr == "hit"

  test "the answer keeps what the engine bound, and the disabled ones":
    let plan = @[BreakpointSpec(line: 10, enabled: true),
                 BreakpointSpec(line: 12, column: 3, enabled: true),
                 BreakpointSpec(line: 20, enabled: false)]
    let body = %*{"breakpoints": [
      {"verified": true, "line": 11},
      {"verified": false, "line": 12}]}
    let held = answeredBreakpoints(plan, body)
    check held.len == 2
    check breakpointAt(held, 11).get.enabled       # bound to the next line
    check breakpointAt(held, 12).isNone            # not verified: not held
    check breakpointAt(held, 20).isSome            # disabled: kept

suite "the store's breakpoints, through the session backend":

  test "the set is held at once, then replaced by what the engine verified":
    let mock = newMockBackendService()
    mock.deferResponses = true
    let store = createReplayDataStore(mock.toBackendService())
    store.toggleBreakpoint("/src/a.nim", 4)
    let held = store.rowsOf("/src/a.nim")
    check held.len == 1
    check held.len == 1 and held[0].resolution == "requested"
    check mock.findCommand("setBreakpoints").isSome
    mock.settleDeferred(answer([5]))
    let bound = store.rowsOf("/src/a.nim")
    check bound.len == 1
    check bound.len == 1 and bound[0].line == 5
    check bound.len == 1 and bound[0].resolution == "verified"

  test "an answer to a superseded request does not replace the newer set":
    # Delete a line's breakpoint, then anchor a new one on it before the
    # engine answers the delete: the delete's answer arrives first and must
    # not remove the breakpoint held since.
    let mock = newMockBackendService()
    mock.deferResponses = true
    let store = createReplayDataStore(mock.toBackendService())
    store.applyVerifiedBreakpoints("/src/g.nim", @[2])
    check store.deleteBreakpoint("/src/g.nim", 2)
    store.setAnchoredBreakpoint("/src/g.nim", 2, 3, condition = "i > 1")
    check mock.pendingDeferredCount == 2
    mock.settleDeferred(answer([]))          # the delete's answer
    var rows = store.rowsOf("/src/g.nim")
    check rows.len == 1 and rows[0].column == 3 and rows[0].condition == "i > 1"
    mock.settleDeferred(answer([2]))         # the anchored one's answer
    rows = store.rowsOf("/src/g.nim")
    check rows.len == 1 and rows[0].column == 3 and
      rows[0].condition == "i > 1" and rows[0].resolution == "verified"

  test "a refused request leaves the requested set standing":
    let mock = newMockBackendService()
    mock.expect("setBreakpoints", %*{"type": "response",
      "command": "setBreakpoints", "success": false})
    let store = createReplayDataStore(mock.toBackendService())
    store.toggleBreakpoint("/src/b.nim", 8)
    drainPlatformCallbacks()
    let rows = store.rowsOf("/src/b.nim")
    check rows.len == 1 and rows[0].line == 8

  test "disabling keeps the row, dimmed, and sends none for it":
    let mock = newMockBackendService(autoRespond = true)
    let store = createReplayDataStore(mock.toBackendService())
    store.applyVerifiedBreakpoints("/src/c.nim", @[6])
    mock.clearReceivedCommands()
    check store.setBreakpointEnabled("/src/c.nim", 6, false)
    let sent = mock.findCommand("setBreakpoints")
    check sent.isSome and sent.get.args["breakpoints"].len == 0
    let rows = store.rowsOf("/src/c.nim")
    check rows.len == 1 and not rows[0].enabled
    check not store.setBreakpointEnabled("/src/c.nim", 99, true)

  test "a column logpoint keeps its message on the row":
    let mock = newMockBackendService()
    mock.expect("setBreakpoints", answer([3]))
    let store = createReplayDataStore(mock.toBackendService())
    store.setAnchoredBreakpoint("/src/d.nim", 3, 4, logMessage = "x={x}")
    drainPlatformCallbacks()
    let rows = store.rowsOf("/src/d.nim")
    check rows.len == 1 and rows[0].logMessage == "x={x}" and rows[0].column == 4

  test "a condition is sent with its breakpoint and stays on the row":
    let mock = newMockBackendService()
    mock.expect("setBreakpoints", answer([6]))
    mock.expect("setBreakpoints", answer([6]))
    let store = createReplayDataStore(mock.toBackendService())
    store.toggleBreakpoint("/src/g.nim", 6)
    drainPlatformCallbacks()
    check store.setBreakpointCondition("/src/g.nim", 6, 0, "n mod 3 == 0")
    drainPlatformCallbacks()
    var sent: JsonNode = nil
    for c in mock.receivedCommands:
      if c.command == "setBreakpoints": sent = c.args
    check sent["breakpoints"][0]["condition"].getStr == "n mod 3 == 0"
    let rows = store.rowsOf("/src/g.nim")
    check rows.len == 1 and rows[0].condition == "n mod 3 == 0"
    check not store.setBreakpointCondition("/src/g.nim", 7, 0, "x")

  test "resending sends every file's set again":
    let mock = newMockBackendService(autoRespond = true)
    let store = createReplayDataStore(mock.toBackendService())
    store.applyVerifiedBreakpoints("/src/e.nim", @[1])
    store.applyVerifiedBreakpoints("/src/f.nim", @[2])
    mock.clearReceivedCommands()
    store.resendBreakpoints()
    var paths: seq[string] = @[]
    for c in mock.receivedCommands:
      if c.command == "setBreakpoints":
        paths.add c.args["source"]["path"].getStr
    check paths == @["/src/e.nim", "/src/f.nim"]
