## test_plat49_panes_models.nim — PLAT-49 part B, the shared half: what the
## user's 2026-10-01 findings 7, 8, 9, 11 and 14 put into the ViewModels and
## the layout model, so every front-end renders the same logical content its
## own way.
##
##   * finding 8 — a call-trace row as DATA (`calltrace_vm.CallRow`): callee,
##     arguments with values, return value, toggle state, flags, and its
##     breakdown into typed parts (`callRowSegments`), the desktop's row;
##   * finding 14 — the event log's columns (`event_log_vm.EventLogColumns`):
##     the desktop's set and order, location hidden by default, show / hide /
##     reorder;
##   * finding 11 — GoldenLayout's drop-zone proportions
##     (`golden_layout_hit.glStackSegmentAt`, PLAT-51's port) and its root
##     side bands;
##   * finding 9 — a docked pane docked OPEN (`cmdOpenDocked` /
##     `cmdCloseDocked`, one at a time, not persisted) and the desktop's hover
##     timing (`auto_hide_hover`): a preview after the delay, a dismissal after
##     the pointer leaves, a click ends both;
##   * finding 7 — a session tab's agent indicator, label and tooltip
##     (`session_tabs`).
##
## Every subject is pure (values in, values out), on both backends (vm-unit
## and vm-unit-js). No mocks.

import std/[json, options, strutils, unittest]

import ../../viewmodels/calltrace_vm
import ../../viewmodels/event_log_vm
import ../../viewmodels/[omnibar_vm, omnibar_sources]
import ../../store/types
from ../../store/replay_data_store import callArgsOf, callReturnTextOf
import headless_app/layout_model
import headless_app/layout_interaction
import headless_app/auto_hide_hover
from headless_app/session_tabs import SessionTabAgent, agentOf, tabLabelOf,
  agentTooltipText, agentProgressText, progressPercent, NewSessionTabGlyph,
  NewSessionTabTitle
import headless_app/footer_info

# One line, deliberately: `ci/lib/run-nim-test-lane.sh` reads this spelling
# as the suite's RUNTIME assertion count.
const ExpectedAssertions = 217

var countedAssertions = 0

template ck(condition: untyped) =
  inc countedAssertions
  check condition

func line(index: int64; name: string; depth: int; children = false;
          expanded = false; key = ""): CallLine =
  CallLine(index: index, name: name, depth: depth, hasChildren: children,
           isExpanded: expanded, callKey: key)

suite "PLAT-49 part B: a call-trace row is data the desktop's row is drawn from":

  test "callee, arguments with values, return value, toggle, flags":
    let r = callRowOf(line(3, "apply_op", 3, children = true, expanded = true),
                      @[CallArg(name: "symbol", text: "\"+\""),
                        CallArg(name: "left", text: "2"),
                        CallArg(name: ReturnArgName, text: "5")],
                      selected = some(3'i64))
    ck r.callee == "apply_op"
    ck r.depth == 3
    ck r.args.len == 2
    ck r.args[0].name == "symbol" and r.args[0].value == "\"+\""
    ck r.args[1].name == "left" and r.args[1].value == "2"
    ck r.hasReturn and r.returnValue == "5"
    ck r.toggle == crtExpanded
    ck crfSelected in r.flags
    let leaf = callRowOf(line(4, "add", 4), @[])
    ck leaf.toggle == crtLeaf
    ck not leaf.hasReturn
    ck crfSelected notin leaf.flags
    let hidden = callRowOf(line(5, "evaluate", 2, children = true), @[])
    ck hidden.toggle == crtCollapsed
    let shown = CallLine(index: 6, name: "raw", displayName: "pretty")
    ck callRowOf(shown, @[]).callee == "pretty"

  test "the parts in the desktop's order, each of its kind":
    let r = callRowOf(line(3, "apply_op", 1, children = true, expanded = true),
                      @[CallArg(name: "left", text: "2"),
                        CallArg(name: "right", text: "3"),
                        CallArg(name: ReturnArgName, text: "5")])
    var kinds: seq[CallSegmentKind] = @[]
    for s in r.callRowSegments():
      kinds.add s.kind
    ck kinds == @[csIndent, csToggle, csPunct, csCallee, csIndex, csPunct,
                  csArgName, csPunct, csArgValue, csPunct, csArgName, csPunct,
                  csArgValue, csPunct, csReturnArrow, csReturnValue]
    ck r.callRowText() == "apply_op #3(left=2, right=3) => 5"
    # A call with no arguments still draws its parentheses, as `.call-args`
    # does; with no return, no arrow.
    ck callRowOf(line(0, "<__main__>", 0), @[]).callRowText() ==
       "<__main__> #0()"
    # The indent is the depth's.
    ck r.callRowSegments()[0].text.len == CallRowIndentCells

  test "the wire's arguments and return values decode to the row's parts":
    # One call as `ct/load-calltrace-section` sends it (the shape the real
    # engine answered on `calc`, `evaluate #2`).
    let call = %*{"args": [{"name": "expression", "text": "",
                            "value": {"kind": 9, "text": "2 + 3",
                                      "typ": {"kind": 16, "langType": "String",
                                              "labels": [], "memberTypes": []},
                                      "elements": []}}],
                  "returnValue": {"kind": 7, "i": "5",
                                  "typ": {"kind": 16, "langType": "Int",
                                          "labels": [], "memberTypes": []},
                                  "elements": []}}
    let a = callArgsOf(call)
    ck a.len == 2
    ck a[0].name == "expression"
    ck a[0].text.contains("2 + 3")
    ck a[1].name == ReturnArgName and a[1].text == "5"
    # A call that returned none (`TypeKind.None`) shows no return.
    let none = %*{"args": [], "returnValue": {"kind": 30, "typ": {"kind": 16,
                  "langType": "NoneType", "labels": [], "memberTypes": []},
                  "elements": []}}
    ck callReturnTextOf(none) == ""
    ck callArgsOf(none).len == 0

suite "PLAT-49 part B: the event log's columns are the ViewModel's":

  test "the desktop's set, its order, location hidden by default":
    let c = defaultEventLogColumns()
    ck c.order == @[elcTick, elcIndex, elcLocation, elcKind, elcOutput]
    ck c.visibleColumns == @[elcTick, elcIndex, elcKind, elcOutput]
    ck not c.isVisible(elcLocation)
    ck eventLogColumnTitle(elcTick) == "tick"
    ck eventLogColumnTitle(elcIndex) == "#"
    ck eventLogColumnTitle(elcOutput) == "output"

  test "show, hide, and the last visible column stays":
    var c = defaultEventLogColumns()
    ck c.showColumn(elcLocation)
    ck c.visibleColumns == @[elcTick, elcIndex, elcLocation, elcKind, elcOutput]
    ck not c.showColumn(elcLocation)
    ck c.hideColumn(elcTick)
    ck c.hideColumn(elcIndex)
    ck c.hideColumn(elcLocation)
    ck c.hideColumn(elcKind)
    ck c.visibleColumns == @[elcOutput]
    ck not c.hideColumn(elcOutput)
    ck c.visibleColumns == @[elcOutput]
    ck c.toggleColumn(elcKind)
    ck c.visibleColumns == @[elcKind, elcOutput]

  test "reorder along the visible order; hidden columns keep their places":
    var c = defaultEventLogColumns()
    ck c.moveColumn(elcOutput, -1)
    ck c.visibleColumns == @[elcTick, elcIndex, elcOutput, elcKind]
    ck c.order[2] == elcLocation
    ck not c.moveColumn(elcTick, -1)
    ck not c.moveColumn(elcLocation, 1)
    ck c.moveColumn(elcTick, 3)
    ck c.visibleColumns == @[elcIndex, elcOutput, elcKind, elcTick]
    let (ok, col) = parseEventLogColumn("file")
    ck ok and col == elcLocation
    ck parseEventLogColumn("#")[1] == elcIndex
    ck not parseEventLogColumn("nope")[0]

  test "the omnibar's column commands: show / hide and move, every column":
    let cmds = eventLogColumnCommands()
    ck cmds.len == 3 * (ord(EventLogColumn.high) + 1)
    var targets: seq[string] = @[]
    for c in cmds:
      ck c.kind == omCommand
      ck c.label.startsWith("Event Log › ")
      targets.add c.target
    ck (EventLogColumnCommandPrefix & "toggle:location") in targets
    ck (EventLogColumnCommandPrefix & "left:output") in targets
    let parsed = parseEventLogColumnCommand(EventLogColumnCommandPrefix &
                                            "right:#")
    ck parsed.ok and parsed.verb == "right" and parsed.column == elcIndex
    ck not parseEventLogColumnCommand("eventLogColumn:drop:tick").ok
    ck not parseEventLogColumnCommand("aEventLog").ok
    # In the index every front-end's omnibar searches.
    var inIndex = 0
    for e in omnibarIndexOf(nil, nil, nil):
      if e.target.startsWith(EventLogColumnCommandPrefix): inc inIndex
    ck inIndex == cmds.len

suite "PLAT-49 part B: GoldenLayout's drop zones":

  test "a quarter on each side, the SMALLER centre joins (PLAT-51)":
    # PLAT-49's quarters, restated through the shared port of GoldenLayout's
    # hit-testing (`golden_layout_hit`): a 100 x 40 body, judged at each
    # unit's centre; the middle that joins is the centred THIRD.
    let st = GlStack(element: glRect(0, -3, 100, 43),
                     header: glRect(0, -3, 100, 3),
                     content: glRect(0, 0, 100, 40),
                     tabs: @[glRect(0, -3, 10, 3)])
    proc at(x, y: int): GlSegment =
      glStackSegmentAt(st, x.float + 0.5, y.float + 0.5, NativeCentreShare)
    ck at(0, 20) == segLeft
    ck at(24, 20) == segLeft
    ck at(25, 20) == segBottom       # PLAT-49 joined here; GoldenLayout splits
    ck at(34, 20) == segCentre
    ck at(99, 20) == segRight
    ck at(75, 20) == segRight
    ck at(65, 20) == segCentre
    ck at(50, 0) == segTop
    ck at(50, 12) == segTop
    ck at(50, 13) == segCentre
    ck at(50, 39) == segBottom
    ck at(50, 27) == segBottom
    ck at(50, 26) == segCentre
    # The left and right zones run the body's full height (GoldenLayout's).
    ck at(5, 0) == segLeft
    ck at(95, 39) == segRight
    ck GlEdgeShare == 0.25

  test "a tab's left half inserts before it, its right half after it":
    # `Stack._highlightHeaderDropZone`, through the port: two 10-wide tabs.
    let st = GlStack(element: glRect(0, -3, 100, 43),
                     header: glRect(0, -3, 100, 3),
                     content: glRect(0, 0, 100, 40),
                     tabs: @[glRect(0, -3, 10, 3), glRect(10, -3, 10, 3)])
    ck glHeaderIndexAt(st, 0.5, -1, 0) == 0
    ck glHeaderIndexAt(st, 4.5, -1, 0) == 0
    ck glHeaderIndexAt(st, 5.5, -1, 0) == 1
    ck glHeaderIndexAt(st, 9.5, -1, 0) == 1
    ck glHeaderIndexAt(st, 14.0, -1, 0) == 1
    ck glHeaderIndexAt(st, 16.0, -1, 0) == 2
    # Past the last tab: the end of the strip.
    ck glHeaderIndexAt(st, 60.0, -1, 0) == 2

suite "PLAT-49 part B: GoldenLayout's ground drop splits the whole layout":

  test "the band is GoldenLayout's 50 px, in any front-end's unit":
    ck GlSideAreaPx == 50
    let sides = glSideAreas(glRect(0, 0, 800, 600))
    ck sides.len == 4 and sides[1].side == gsLeft
    ck sides[1].rect.x2 == 50.0
    ck rootZoneOf(leLeft) == dzRootLeft and rootZoneOf(leBottom) == dzRootBottom
    # `getArea`: the smaller surface wins; a tie keeps the earlier area.
    let geom = GlGeometry(ground: glRect(0, 0, 800, 600), stacks: @[GlStack(
      element: glRect(0, 0, 800, 600), header: glRect(0, 0, 800, 30),
      content: glRect(0, 30, 800, 570), tabs: @[glRect(0, 0, 80, 30)])])
    let areas = glItemAreas(geom)
    ck areas[glAreaAt(areas, 10, 300)].kind == gakSide

  test "the root is wrapped half and half when it runs the other way":
    # editor | (state over calltrace), a ROW: a drop on the bottom band.
    let l = initLayout(row([pane(paneEditor),
                            column([pane(paneState), pane(paneCalltrace)])]))
    let o = l.apply(cmdSplitRootMove(paneState, saColumn, ssAfter))
    ck o.kind == loApplied
    let t = o.layout.tree
    ck t.kind == lnColumn and t.children.len == 2
    ck t.children[1].kind == lnPane and t.children[1].pane == paneState
    ck t.children[0].kind == lnRow
    ck effectiveWeight(t.children[0]) == effectiveWeight(t.children[1])
    ck not t.children[0].contains(paneState)
    # Before: the top band puts it first.
    let top = l.apply(cmdSplitRootMove(paneCalltrace, saColumn, ssBefore))
    ck top.kind == loApplied and top.layout.tree.children[0].pane == paneCalltrace

  test "the root joins at that end when it already runs that way":
    let l = initLayout(row([pane(paneEditor, weight = 2.0),
                            pane(paneState, weight = 1.0),
                            pane(paneCalltrace, weight = 1.0)]))
    let o = l.apply(cmdSplitRootMove(paneEditor, saRow, ssAfter))
    ck o.kind == loApplied
    let t = o.layout.tree
    ck t.kind == lnRow and t.children.len == 3
    ck t.children[^1].pane == paneEditor
    # The end sibling gave the newcomer HALF of its share (after the detach
    # renormalised the survivors: state 2, calltrace 2 -> 1 and 1).
    ck t.children[0].pane == paneState and t.children[1].pane == paneCalltrace
    ck abs(t.children[1].weight - t.children[2].weight) < 1e-9
    ck abs(t.children[0].weight - 2.0 * t.children[1].weight) < 1e-9

  test "a docked pane drops onto the band too; a drop target, a command":
    var l = initLayout(row([pane(paneEditor), pane(paneState),
                            pane(paneEventLog)]))
    l = l.apply(cmdDock(paneEventLog, leBottom)).layout
    let o = l.apply(cmdSplitRootMove(paneEventLog, saColumn, ssAfter))
    ck o.kind == loApplied
    ck o.layout.dockedIndex(paneEventLog) < 0
    ck o.layout.tree.kind == lnColumn
    ck o.layout.tree.children[1].pane == paneEventLog
    for (zone, edge, axis, side) in [(dzRootLeft, leLeft, saRow, ssBefore),
                                     (dzRootRight, leRight, saRow, ssAfter),
                                     (dzRootTop, leTop, saColumn, ssBefore),
                                     (dzRootBottom, leBottom, saColumn, ssAfter)]:
      let p = LayoutPointer(path: "", zone: zone)
      let targets = dropTargetsFor(l, paneState, p)
      ck targets.len == 1
      ck targets[0].kind == dtSplitRoot and targets[0].edge == edge
      ck targets[0].region.kind == drRootBand and targets[0].region.side == edge
      let hit = hoveredTarget(l, paneState, p)
      ck hit.isSome and hit.get == targets[0]
      let cmd = commandFor(l, paneState, targets[0])
      ck cmd.isSome and cmd.get.splitRoot and cmd.get.splitAxis == axis and
         cmd.get.splitSide == side and cmd.get.splitNewPane == paneState
      var drag = beginDragTab(l, paneState).get.hoverAt(l, p)
      let ind = dropIndicationOf(drag)
      ck ind.kind == diRootBand and ind.side == edge
    # The only pane of the tree cannot leave it.
    let lone = initLayout(pane(paneEditor))
    ck lone.apply(cmdSplitRootMove(paneEditor, saRow, ssAfter)).kind != loApplied

suite "PLAT-49 part B: a docked pane docks OPEN on a click":

  proc footer(): Layout =
    var l = initLayout(row([pane(paneEditor), pane(paneBuildOutput),
                            pane(paneEventLog)]))
    for i, p in [paneBuildOutput, paneEventLog]:
      let o = l.apply(cmdDock(p, leBottom, i))
      doAssert o.kind == loApplied, $o.kind
      l = o.layout
    l

  test "open, one at a time, close; never persisted":
    let l = footer()
    ck l.openDocked.isNone
    let opened = l.apply(cmdOpenDocked(paneBuildOutput))
    ck opened.kind == loApplied
    let a = opened.layout
    ck a.openDocked.isSome and a.openDocked.get.pane == paneBuildOutput
    # Still docked: its label stays on the strip; the tree is unchanged.
    ck a.dockedIndex(paneBuildOutput) >= 0
    ck not a.tree.contains(paneBuildOutput)
    let b = a.apply(cmdOpenDocked(paneEventLog)).layout
    ck b.openDocked.get.pane == paneEventLog
    var openCount = 0
    for d in b.docked:
      if d.open: inc openCount
    ck openCount == 1
    ck b.apply(cmdOpenDocked(paneEventLog)).kind == loNoOp
    let c = b.apply(cmdCloseDocked(paneEventLog)).layout
    ck c.openDocked.isNone
    ck c.apply(cmdCloseDocked(paneEventLog)).kind == loNoOp
    ck l.apply(cmdOpenDocked(paneState)).kind == loRefused
    # NOT PERSISTED, as the desktop's `dockedVisible` is not.
    ck not ($saveLayout(b)).contains("\"open\"")

suite "PLAT-49 part B: the desktop's auto-hide hover timing":

  test "a preview after the delay; leaving closes it after the grace":
    var h = initAutoHideHover()
    let label = some(paneBuildOutput)
    ck h.pointerAt(label, false, false, 1000).cue == ahcNone
    ck h.tick(1000 + HoverPreviewDelayMs - 1).cue == ahcNone
    let shown = h.tick(1000 + HoverPreviewDelayMs)
    ck shown.cue == ahcPreview and shown.pane == paneBuildOutput
    # Into the overlay: still shown.
    ck h.pointerAt(none(PaneKind), true, false, 1400).cue == ahcNone
    ck h.tick(5000).cue == ahcNone
    # Out of the zone: closes after the grace, not before.
    ck h.pointerAt(none(PaneKind), false, false, 6000).cue == ahcNone
    ck h.tick(6000 + LeaveDismissDelayMs - 1).cue == ahcNone
    let gone = h.tick(6000 + LeaveDismissDelayMs)
    ck gone.cue == ahcDismiss and gone.pane == paneBuildOutput
    ck HoverPreviewDelayMs == 300 and LeaveDismissDelayMs == 300

  test "leaving before the delay cancels; coming back cancels a dismissal":
    var h = initAutoHideHover()
    discard h.pointerAt(some(paneBuildOutput), false, false, 0)
    discard h.pointerAt(none(PaneKind), false, false, 100)
    ck h.tick(1000).cue == ahcNone
    ck h.nextDueMs < 0
    discard h.pointerAt(some(paneBuildOutput), false, false, 2000)
    ck h.tick(2300).cue == ahcPreview
    discard h.pointerAt(none(PaneKind), false, false, 2400)
    ck h.nextDueMs == 2400 + LeaveDismissDelayMs
    discard h.pointerAt(some(paneBuildOutput), false, false, 2500)
    ck h.tick(3000).cue == ahcNone

  test "a click ends the preview; an open pane's label previews nothing":
    var h = initAutoHideHover()
    discard h.pointerAt(some(paneBuildOutput), false, false, 0)
    discard h.tick(300)
    h.clicked()
    ck h.previewing.isNone and h.nextDueMs < 0
    # The pointer still on that label: no new preview until it leaves.
    discard h.pointerAt(some(paneBuildOutput), false, true, 400)
    ck h.tick(2000).cue == ahcNone
    var o = initAutoHideHover()
    discard o.pointerAt(some(paneEventLog), false, true, 0)
    ck o.tick(1000).cue == ahcNone

suite "PLAT-49 part B: a session tab's agent indicator, label and tooltip":

  test "an agent working in the session: its progress on the tab":
    let state = AgentSessionsState(activeTabId: "t1", sessions: @[
      AgentServiceSessionEntry(tabId: "t1", title: "Implement parser",
                               lifecycle: aslRunning, milestonesCompleted: 13,
                               milestonesTotal: 24)])
    let a = agentOf(state)
    ck a.present and a.running
    ck a.completed == 13 and a.total == 24
    ck a.progressPercent == 54
    ck agentProgressText(a) == "13/24 milestones (54%)"
    ck tabLabelOf("calc", a) == "calc 13/24"
    ck agentTooltipText("calc", a) ==
       "calc — agent working: Implement parser — 13/24 milestones (54%)"

  test "no agent, a finished one: the title alone, the state said":
    let none = agentOf(AgentSessionsState())
    ck not none.present
    ck tabLabelOf("calc", none) == "calc"
    ck agentTooltipText("calc", none) == "calc"
    let done = agentOf(AgentSessionsState(sessions: @[
      AgentServiceSessionEntry(tabId: "x", title: "Fix", lifecycle: aslCompleted,
                               milestonesCompleted: 3, milestonesTotal: 3)]))
    ck done.present and not done.running
    ck tabLabelOf("calc", done) == "calc"
    ck agentTooltipText("calc", done).contains("agent completed: Fix")

suite "PLAT-49 part B review: a new session tab's recording, chosen in the omnibar":

  test "`:open ` is the recording mode; a typed path is offered first":
    ck OpenRecordingQuery == ":open "
    ck classifyOmnibarQuery(":open ").mode == omRecording
    ck classifyOmnibarQuery(":open calc").mode == omRecording
    ck classifyOmnibarQuery(":open calc").needle == "calc"
    # Not a prefix of another word, and not on the desktop (its "+" opens a
    # welcome screen): there it stays a command.
    ck classifyOmnibarQuery(":opentab").mode == omCommand
    ck desktopKindOf(omRecording) == omCommand
    let index = @[
      OmnibarEntry(kind: omRecording, label: "calc-2f0", detail: "/r",
                   target: "/r/calc-2f0"),
      OmnibarEntry(kind: omRecording, label: "call_pages-d67", detail: "/r",
                   target: "/r/call_pages-d67"),
      OmnibarEntry(kind: omFile, label: "calc.py", detail: "", target: "x")]
    let all = rankOmnibar(index, omRecording, "")
    ck all.len == 2
    let pages = rankOmnibar(index, omRecording, "pages")
    ck pages.len == 1 and pages[0].entry.target == "/r/call_pages-d67"
    let typed = rankOmnibar(index, omRecording, "/home/u/rec")
    ck typed.len >= 1
    ck typed[0].entry.kind == omRecording and typed[0].entry.target == "/home/u/rec"
    ck typed[0].entry.label == "Open /home/u/rec in a new tab"
    var vm = newOmnibarVM()
    vm.setIndex(index)
    vm.open(OpenRecordingQuery)
    ck vm.mode == omRecording and vm.results.len == 2
    let chosen = vm.accept()
    ck chosen.ok and chosen.entry.kind == omRecording
    ck NewSessionTabGlyph == "+" and NewSessionTabTitle == "New tab"

suite "PLAT-49 part B review: the status bar's file info":

  test "the language and the encoding, as the desktop's":
    ck footerFileInfoParts("calc/main.py") == @["Python", "UTF-8"]
    ck footerFileInfoText("/a/b/main.rs") == "Rust | UTF-8"
    ck footerFileInfoText("") == ""
    ck footerFileInfoParts("noext") == @["unknown", "UTF-8"]

suite "assertion count":
  test "assertion count":
    echo "CHECKS: ", countedAssertions
    check countedAssertions == ExpectedAssertions
