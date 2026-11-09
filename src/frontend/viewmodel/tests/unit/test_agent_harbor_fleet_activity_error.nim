## The web fleet view colours an error-level activity line red only on a row
## with no failure line.
##
## A failed session's row carries a red failure line (`FleetRow.failureText`);
## an error-level activity line under it stays in the caption role, so one
## fault is not shown twice in red. An error-level activity line on a row
## with no failure line is the only red line of its row and keeps the error
## colour. The rule is `agent_harbor_words.activityLineIsError`, shared by
## the web, GPUI and terminal views; the web view states it as the
## `ah-fleet-activity-error` class, and the stylesheet's rule for that class
## (after `.ah-fleet-activity-line`, which it must override) draws it red.
## The stylesheet half is held by the StoryBook play check of
## `agent-harbor-fleet-failed` (`storybook/stories/lib/plays.js`), which runs
## in a browser; this suite holds the view half.
##
## The story data has no error-level activity outside a failed session, so
## the second case is made from it: the embedded synthetic fleet
## (`newFixtureDataSource`, no mock), with ONE failed session given the
## running status, served through the production `SnapshotDataSource` seam.
## Its error-level log line is then an activity line on a row with no
## failure line. The mock renderer is the one both `vm-unit` lanes drive.

import std/[unittest, tables, strutils]

import isonim/core/owner
import nim_agents/agent_harbor/fleet_records
import nim_agents_isonim_viewmodels/agent_harbor/[data_source, fixture_source]
import isonim/testing/mock_dom

import ../../views/isonim_agent_harbor_fleet_view

const ExpectedAssertions = 12
var countedAssertions = 0
template ck(cond: untyped) =
  inc countedAssertions
  check cond

const ErrorClass = "ah-fleet-activity-error"

proc classOf(node: MockNode): string =
  if node.attributes.hasKey("class"): node.attributes["class"] else: ""

proc hasClassToken(node: MockNode; token: string): bool =
  for part in node.classOf.split(' '):
    if part == token: return true

proc collect(node: MockNode; token: string; into: var seq[MockNode]) =
  if node.hasClassToken(token): into.add node
  for child in node.children: collect(child, token, into)

proc all(node: MockNode; token: string): seq[MockNode] = collect(node, token, result)

proc fixtureSnapshot(): FleetSnapshot =
  var got: ref FleetSnapshot
  newFixtureDataSource().loadFleet proc(answer: DataResult[FleetSnapshot]) =
    doAssert answer.ok, answer.error
    got = new FleetSnapshot
    got[] = answer.value
  doAssert not got.isNil, "the fixture source answers synchronously"
  got[]

proc withRunningFailure(snapshot: FleetSnapshot): (FleetSnapshot, string) =
  ## The snapshot with its first failed session that logged an error-level
  ## line given the running status, and that session's id.
  result[0] = snapshot
  for s in result[0].sessions.mitems:
    if s.status == fsFailed:
      for a in s.recent:
        if a.level == "error":
          s.status = fsRunning
          s.rawStatus = "running"
          result[1] = s.id
          return
  doAssert false, "the fixture holds a failed session with an error-level line"

proc mountFleet(snapshot: FleetSnapshot): (FleetSnapshotVM, MockNode) =
  var panel: MockNode
  var vm: FleetSnapshotVM
  createRoot proc(dispose: proc()) =
    vm = newFleetSnapshotVM(newSnapshotDataSource(snapshot))
    vm.load()
    panel = renderAgentHarborFleetPanel[MockRenderer, MockNode](MockRenderer(), vm)
  (vm, panel)

suite "the shared rule":
  test "red only where the row has no failure line":
    let error = FleetRow(activity: @["x", "y"], activityLevels: @["error", "info"])
    ck activityLineIsError(error, 0)
    ck not activityLineIsError(error, 1)
    ck not activityLineIsError(error, 2)
    var failed = error
    failed.failureText = "build failed"
    ck not activityLineIsError(failed, 0)

suite "the web fleet view sets the error class by the rule":
  test "under a failure line no activity line carries it":
    let (vm, panel) = mountFleet(fixtureSnapshot())
    var underFailure, errorLevel = 0
    for row in vm.rows:
      if row.failureText.len == 0: continue
      for i in 0 ..< row.activityLevels.len:
        if row.activityLevels[i] == "error": inc errorLevel
      inc underFailure
    # The story data does hold error-level lines under failure lines, so a
    # view that set the class from the level alone would fail here.
    ck underFailure > 0
    ck errorLevel > 0
    ck panel.all(ErrorClass).len == 0

  test "on a row with no failure line an error-level line carries it":
    let (snapshot, id) = withRunningFailure(fixtureSnapshot())
    let (vm, panel) = mountFleet(snapshot)
    var row: FleetRow
    for r in vm.rows:
      if r.id == id: row = r
    ck row.id == id
    ck row.failureText.len == 0
    ck "error" in row.activityLevels
    let marked = panel.all(ErrorClass)
    ck marked.len >= 1
    var shownErrors = 0
    let shown = if row.expanded: row.activity.len else: min(1, row.activity.len)
    for i in 0 ..< shown:
      if activityLineIsError(row, i): inc shownErrors
    ck marked.len == shownErrors

suite "assertion count":
  test "every assertion ran":
    check countedAssertions == ExpectedAssertions
