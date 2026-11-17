## CTF-P2b: the terminal's session activity timeline
## (`tui/agent_harbor/ah_tui_session_activity.nim`), drawn onto a canvas and
## read back, before its stories mount it.
##
## * **What it draws is the viewmodel's**: every line `SessionTimelineVM`
##   publishes, in order, with its facts (`lineFacts`), and each group's
##   counts.
## * **Cardless**: every cell of a
##   timeline line is on the panel's ground, and no line row holds a box
##   drawing glyph (a rule, a frame); only the focus bar `▎` marks a line.
## * **A press opens a line through the viewmodel**: the press runs the
##   target, the viewmodel opens the line, and the next drawing shows it open.
## * **A path is cut in its middle** (D6, amended for paths) by `elidePath`,
##   through the same trim, and nothing it draws dangles around its "…".
## * **The chrome**: the `Running: <command>` strip only while the running
##   line is out of view; the unseen chip, whose press jumps to the end; a
##   detail's Copy; the load states.
##
## No test doubles: the viewmodels read the seam's own `TimelineDataSource`,
## `PendingDataSource` and `FailingDataSource`, over invented events.

import std/[json, sequtils, strutils, unicode, unittest]

import isonim/core/owner
import nim_agents_isonim_viewmodels/agent_harbor/[data_source, session_events]

import ../agent_harbor/ah_tui_session_activity
import ../../styles/generated/design_tokens
from ../../viewmodel/views/agent_harbor_words import danglesAroundEllipsis,
  pathCutCandidates

const
  Session = "5ca1ab1e-0e11-4e00-8000-00000000e011"
  Ellipsis = "\xE2\x80\xA6"
  LongPath = "src/upload/transport/retry/backoff/client.py"

proc stamp(seconds: int; body: JsonNode): JsonNode =
  result = body.copy
  result["timestamp"] = %(int64(seconds) * 1_000_000)

proc basics(): seq[JsonNode] =
  @[stamp(1, statusEvent("running")),
    stamp(2, userInput("Add jitter to the upload client.")),
    stamp(3, fileRead("src/upload/retry/client.py")),
    stamp(4, fileRead("src/upload/config.py")),
    stamp(5, commandCall("c1", "pytest -q")),
    stamp(6, toolResult("c1", "runCmd", 1, "1 failed")),
    stamp(7, commandCall("c2", "pytest -q tests/integration --slow"))]

proc sourceWith(events: openArray[JsonNode]): TimelineDataSource =
  newTimelineDataSource(@[(Session, @events)], label = "test timeline")

proc draw(vm: SessionTimelineVM; cols, rows: int; mode = dmDark;
          press: ActivityPress = nil): AhCanvas =
  result = newAhCanvas(cols, rows, ahPalette(mode))
  result.drawSessionActivity(vm, 0, 0, cols, rows, press)

proc lineNodes(c: AhCanvas): seq[AhNode] = c.root.all("line")

proc isBoxDrawing(r: Rune): bool = r.int >= 0x2500 and r.int <= 0x257F

suite "the terminal timeline draws what the viewmodel publishes":
  test "every line, in order, with its facts and counts":
    createRoot proc(disposeRoot: proc()) =
      let vm = newSessionTimelineVM(sourceWith(basics()), Session)
      vm.load()
      let c = vm.draw(95, 40)
      let surface = c.root.first("surface")
      check surface.attr("surface") == "agent-harbor-session-activity"
      check surface.attr("state") == "ready"
      check surface.attr("status") == vm.statusLabel
      let nodes = c.lineNodes
      check nodes.mapIt(it.attr("line")) == vm.lines.mapIt(it.id)
      check nodes.mapIt(it.attr("text")) == vm.lines.mapIt(it.text)
      for n in nodes:
        if n.attr("line-kind") == "group":
          let line = vm.lines.filterIt(it.id == n.attr("line"))[0]
          check n.attr("count") == $line.count
          check n.attr("failed") == $line.failed
          check n.attr("running") == $line.running
      vm.dispose()
      disposeRoot()

  test "a pause in the session is a quiet gap line":
    createRoot proc(disposeRoot: proc()) =
      let vm = newSessionTimelineVM(sourceWith(basics() &
        @[stamp(700, agentReply("The slow tests pass."))]), Session)
      vm.load()
      let gaps = vm.lines.filterIt(it.kind == tlkGap)
      check gaps.len == 1
      let c = vm.draw(95, 40)
      let drawn = c.lineNodes.filterIt(it.attr("line-kind") == "gap")
      check drawn.mapIt(it.attr("line")) == gaps.mapIt(it.id)
      check drawn.len == 1 and drawn[0].attr("role") == "quiet"
      check drawn.len == 1 and
        gaps[0].text in cellsText(c.grid, drawn[0].row, 0, c.cols)
      vm.dispose()
      disposeRoot()

suite "cardless: the panel's ground under every line, no rule, no frame":
  test "in both modes, at the panel and sidebar sizes, every line open":
    for mode in [dmDark, dmLight]:
      for (cols, rows) in [(95, 40), (45, 56)]:
        createRoot proc(disposeRoot: proc()) =
          let vm = newSessionTimelineVM(sourceWith(basics()), Session)
          vm.load()
          vm.expandAll()
          for line in vm.lines:
            if line.expandable and not line.expanded: vm.toggle(line.id)
          vm.setFocus(vm.lines[1].id)
          let c = vm.draw(cols, rows, mode)
          var offGround, rules = 0
          for n in c.lineNodes:
            for r in n.row ..< n.row + n.height:
              for k in 0 ..< c.cols:
                if c.bgAt(r, k) != c.tone.body: inc offGround
                if c.grid.runeAt(r, k).runeAt(0).isBoxDrawing: inc rules
          check offGround == 0
          check rules == 0
          # The focus bar is the one mark, in the action ink, in the first cell.
          let focused = c.lineNodes.filterIt(it.attr("focused") == "true")
          check focused.len == 1
          check c.grid.runeAt(focused[0].row, 0) == FocusBar
          vm.dispose()
          disposeRoot()

suite "a press opens a line through the viewmodel":
  test "the press opens the group, and the next drawing shows it open":
    createRoot proc(disposeRoot: proc()) =
      let vm = newSessionTimelineVM(sourceWith(basics()), Session)
      vm.load()
      var c = vm.draw(95, 40)
      let group = c.lineNodes.filterIt(it.attr("line-kind") == "group")[0]
      let id = group.attr("line")
      check group.attr("expanded") == "false"
      check c.press(group.row, 4)
      check vm.isExpanded(id)
      c = vm.draw(95, 40)
      let again = c.lineNodes.filterIt(it.attr("line") == id)[0]
      check again.attr("expanded") == "true"
      check again.attr("focused") == "true"
      check c.lineNodes.len == vm.lines.len
      vm.dispose()
      disposeRoot()

suite "a path is cut in its middle":
  test "elidePath keeps the first segment and the file name":
    check elidePath(LongPath, 100) == LongPath
    check elidePath(LongPath, 43) == "src/" & Ellipsis & "/transport/retry/backoff/client.py"
    check elidePath(LongPath, 30) == "src/" & Ellipsis & "/retry/backoff/client.py"
    check elidePath(LongPath, 23) == "src/" & Ellipsis & "/backoff/client.py"
    check elidePath(LongPath, 22) == "src/" & Ellipsis & "/client.py"
    check elidePath(LongPath, 15) == "src/" & Ellipsis & "/client.py"
    check elidePath(LongPath, 11) == Ellipsis & "/client.py"
    check elidePath(LongPath, 8) == elide(LongPath, 8)
    for cells in 1 .. 60:
      let shown = elidePath(LongPath, cells)
      check widthOf(shown) <= cells
      check not danglesAroundEllipsis(shown)

  test "a line that names a long file draws its path cut in its middle":
    createRoot proc(disposeRoot: proc()) =
      let vm = newSessionTimelineVM(sourceWith([stamp(1, userInput("Go.")),
        stamp(2, fileRead(LongPath))]), Session)
      vm.load()
      let c = vm.draw(30, 20)
      let shown = c.root.first("path-shown").attr("path-shown")
      check shown in pathCutCandidates(LongPath)
      check shown.startsWith("src/" & Ellipsis)
      check shown.endsWith("/client.py")
      check not danglesAroundEllipsis(shown)
      vm.dispose()
      disposeRoot()

suite "the chrome":
  test "the running strip shows only while the running line is out of view":
    createRoot proc(disposeRoot: proc()) =
      var events = @[stamp(1, statusEvent("running")), stamp(2, userInput("Go."))]
      for i in 0 ..< 30:
        events.add stamp(3 + 2 * i, userInput("Step " & $i & "."))
        events.add stamp(4 + 2 * i, agentReply("Done with step " & $i & "."))
      events.add stamp(70, commandCall("c1", "pytest -q"))
      events.add stamp(71, commandCall("c2", "pytest -q tests/integration --slow"))
      let vm = newSessionTimelineVM(sourceWith(events), Session)
      vm.load()
      # Following: the end is drawn, the running line with it.
      var c = vm.draw(95, 20)
      check c.root.first("running-strip").isNil
      # Reading the start: the running line is out of view.
      vm.setFollow(false)
      vm.readAt(vm.lines[0].id)
      c = vm.draw(95, 20)
      let strip = c.root.first("running-strip")
      check not strip.isNil
      check strip.attr("running-strip") == "Running: pytest -q tests/integration --slow"
      check c.lineNodes[0].attr("line") == vm.lines[0].id
      vm.dispose()
      disposeRoot()

  test "the unseen chip, whose press jumps to the end":
    createRoot proc(disposeRoot: proc()) =
      let source = sourceWith(basics())
      let vm = newSessionTimelineVM(source, Session)
      vm.load()
      check vm.draw(95, 40).root.first("unseen").isNil
      vm.setFollow(false)
      discard source.sendFrame(FleetFrame(kind: ffEvent, sessionId: Session,
                                  event: stamp(8, fileRead("README.md")), ordinal: 8))
      let c = vm.draw(95, 40)
      let chip = c.root.first("unseen")
      check chip.attr("unseen") == "1"
      check c.press(chip.row, chip.col + 1)
      check vm.follow.val
      check vm.unseen.val == 0
      vm.dispose()
      disposeRoot()

  test "a detail's Copy copies its text":
    createRoot proc(disposeRoot: proc()) =
      let vm = newSessionTimelineVM(sourceWith(basics()), Session)
      vm.load()
      vm.toggle("group:" & vm.items[3].id)
      vm.toggle(vm.items[3].id)
      var copied, pressed: seq[string]
      let route = proc(operation, target: string) =
        pressed.add operation
        discard vm.runActivityPress(operation, target, proc(text: string) = copied.add text)
      let c = vm.draw(95, 40, press = route)
      let action = c.root.first("copy-action")
      check not action.isNil
      check c.press(action.row, action.col)
      check pressed == @[ActivityCopyOperation]
      check copied.len == 1
      check copied[0] in vm.lines.mapIt(it.copyText)
      check action.attr("operation") == ActivityCopyOperation
      vm.dispose()
      disposeRoot()

  test "the load states":
    createRoot proc(disposeRoot: proc()) =
      let loading = newSessionTimelineVM(newPendingDataSource(), Session)
      loading.load()
      check loading.draw(95, 40).root.first("notice").attr("message") == LoadingNotice
      let empty = newSessionTimelineVM(sourceWith([stamp(1, statusEvent("running"))]), Session)
      empty.load()
      check empty.draw(95, 40).root.first("notice").attr("message") == EmptyNotice
      let failing = newSessionTimelineVM(newFailingDataSource("connection refused"), Session)
      failing.load()
      let c = failing.draw(95, 40)
      check c.root.first("notice").attr("notice") == "error"
      check c.root.first("error").attr("error") == "connection refused"
      let unknown = newSessionTimelineVM(sourceWith([]), "5ca1ab1e-0e12-4e00-8000-00000000e012")
      unknown.load()
      let n = unknown.draw(95, 40).root.first("notice")
      check n.attr("notice") == "unresolvable"
      check n.attr("message").startsWith(UnresolvablePrefix)
      for vm in [loading, empty, failing, unknown]: vm.dispose()
      disposeRoot()
