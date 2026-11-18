## CTF-P2b: the GPUI session activity timeline
## (`gpui/agent_harbor/ah_session_activity.nim`), drawn into a real
## isonim-gpui shadow tree (the shim loaded in process; no window) and read
## back through its `data-ah-*` facts, before its stories mount it.
##
## * **What it draws is the viewmodel's**: every line, in order, with its
##   facts, each group's counts; the tree builds a valid render plan.
## * **A press is routed**: a line that opens carries
##   `session-activity.toggle` and its id; a press on it reports both to the
##   host's route, which runs it on the viewmodel; the next drawing shows the
##   line open.
## * **Cuts follow the views' one rule** (D6): every text the timeline lets
##   isonim-gpui cut is handed `CutSeparators` (the half that needs no
##   window: the drawn cuts are judged on the story window's capture), and a
##   file path is handed the middle cut, its segments split at `/`.
## * **The chrome**: the running strip only while the running line is out
##   of view, the unseen chip (a press jumps to the end), a detail's Copy,
##   the connection badge and the load states.
##
## No test doubles: the viewmodels read the seam's own sources, over invented
## events; the renderer is isonim-gpui's own.
##
## Trap 13 / §29 (`Verification-Harness-Traps.md`): every helper that calls
## `check` is a template; the procs only collect.

import std/[json, sequtils, strutils, unittest]

import isonim/core/owner
import isonim_gpui/renderer
from isonim_gpui/bindings import gpui_reset_tree
import nim_agents_isonim_viewmodels/agent_harbor/[data_source, session_events]

import ../agent_harbor/ah_session_activity
from ../../viewmodel/views/agent_harbor_words import CutSeparators, PathSeparator
from ../../viewmodel/input/element_press import OperationAttribute

const
  Session = "5ca1ab1e-0e21-4e00-8000-00000000e021"

let r = GpuiRenderer()

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

proc collect(node: GpuiElement; name: string; into: var seq[GpuiElement]) =
  if node.isNil: return
  if getAttribute(node, name).len > 0: into.add node
  for i in 0 ..< childCount(node): collect(nthChild(node, i), name, into)

proc all(root: GpuiElement; fact: string): seq[GpuiElement] =
  collect(root, "data-ah-" & fact, result)

proc attr(e: GpuiElement; name: string): string = getAttribute(e, "data-ah-" & name)

proc first(root: GpuiElement; fact: string): GpuiElement =
  let found = root.all(fact)
  if found.len > 0: found[0] else: nil

var copied, pressed: seq[string]

proc drawn(vm: SessionTimelineVM; w = 760; h = 640): GpuiElement =
  ## Drawn with a host's press route: the operation the pressed element
  ## carries, on its target, run on the viewmodel.
  gpui_reset_tree()
  result = r.createElement("div")
  let target = vm
  r.drawSessionActivity(result, vm, ahPalette(dmDark), w, h,
    proc(operation, on: string) =
      pressed.add operation
      discard target.runActivityPress(operation, on, proc(text: string) = copied.add text))

suite "the GPUI timeline draws what the viewmodel publishes":
  test "every line, in order, with its facts and counts":
    createRoot proc(disposeRoot: proc()) =
      let vm = newSessionTimelineVM(sourceWith(basics()), Session)
      vm.load()
      let root = vm.drawn
      check root.attr("surface") == "agent-harbor-session-activity"
      check root.attr("state") == "ready"
      check root.attr("session-status") == vm.statusLabel
      let lines = root.all("line")
      check lines.mapIt(it.attr("line")) == vm.lines.mapIt(it.id)
      check lines.mapIt(it.attr("text")) == vm.lines.mapIt(it.text)
      for e in lines:
        if e.attr("line-kind") == "group":
          let line = vm.lines.filterIt(it.id == e.attr("line"))[0]
          check e.attr("count") == $line.count
          check e.attr("failed") == $line.failed
          check e.attr("running") == $line.running
      check r.verifyRenderPlan(root)
      vm.dispose()
      disposeRoot()

  test "a pause in the session is a quiet gap line":
    createRoot proc(disposeRoot: proc()) =
      let vm = newSessionTimelineVM(sourceWith(basics() &
        @[stamp(700, agentReply("The slow tests pass."))]), Session)
      vm.load()
      let gaps = vm.lines.filterIt(it.kind == tlkGap)
      check gaps.len == 1
      let drawn = vm.drawn.all("line").filterIt(it.attr("line-kind") == "gap")
      check drawn.mapIt(it.attr("line")) == gaps.mapIt(it.id)
      check drawn.len == 1 and drawn[0].attr("role") == "quiet"
      check drawn.len == 1 and drawn[0].attr("text") == gaps[0].text
      vm.dispose()
      disposeRoot()

  test "a press opens a line through the viewmodel":
    createRoot proc(disposeRoot: proc()) =
      let vm = newSessionTimelineVM(sourceWith(basics()), Session)
      vm.load()
      var root = vm.drawn
      let group = root.all("line").filterIt(it.attr("line-kind") == "group")[0]
      let id = group.attr("line")
      check group.attr("expanded") == "false"
      check getAttribute(group, OperationAttribute) == ActivityToggleOperation
      check getAttribute(group, PressTargetAttribute) == id
      pressed = @[]
      fireEvent(group, "mousedown")
      check pressed == @[ActivityToggleOperation]
      check vm.isExpanded(id)
      root = vm.drawn
      let again = root.all("line").filterIt(it.attr("line") == id)[0]
      check again.attr("expanded") == "true"
      check again.attr("focused") == "true"
      check root.all("line").len == vm.lines.len
      vm.dispose()
      disposeRoot()

suite "cuts follow the views' one rule":
  test "every cut text is handed the separators; a path the middle cut":
    createRoot proc(disposeRoot: proc()) =
      let vm = newSessionTimelineVM(sourceWith(basics()), Session)
      vm.load()
      vm.expandAll()
      let root = vm.drawn(360, 900)
      var trims: seq[GpuiElement]
      collect(root, EllipsisTrimAttribute, trims)
      check trims.len >= vm.lines.filterIt(not it.isProse).len
      for e in trims:
        check getAttribute(e, EllipsisTrimAttribute) == CutSeparators.join("")
      let paths = root.all("path-shown")
      check paths.mapIt(it.attr("path-shown")) ==
        @["src/upload/retry/client.py", "src/upload/config.py"]
      check getAttribute(paths[0], EllipsisAtAttribute) == "middle"
      check getAttribute(paths[0], EllipsisSegmentsAttribute) == $PathSeparator
      check getAttribute(paths[0], EllipsisTrimAttribute) == CutSeparators.join("")
      vm.dispose()
      disposeRoot()

suite "the chrome":
  test "the running strip only while the running line is out of view":
    createRoot proc(disposeRoot: proc()) =
      var events = @[stamp(1, statusEvent("running")), stamp(2, userInput("Go."))]
      for i in 0 ..< 40:
        events.add stamp(3 + 2 * i, userInput("Step " & $i & "."))
        events.add stamp(4 + 2 * i, agentReply("Done with step " & $i & "."))
      events.add stamp(90, commandCall("c1", "pytest -q"))
      events.add stamp(91, commandCall("c2", "pytest -q tests/integration --slow"))
      let vm = newSessionTimelineVM(sourceWith(events), Session)
      vm.load()
      check vm.drawn(760, 640).first("running-strip").isNil
      vm.setFollow(false)
      vm.readAt(vm.lines[0].id)
      let root = vm.drawn(760, 640)
      let strip = root.first("running-strip")
      check not strip.isNil
      check strip.attr("running-strip") == "Running: pytest -q tests/integration --slow"
      check root.all("line")[0].attr("line") == vm.lines[0].id
      vm.dispose()
      disposeRoot()

  test "the unseen chip, a detail's Copy, the badge":
    createRoot proc(disposeRoot: proc()) =
      let source = sourceWith(basics())
      let vm = newSessionTimelineVM(source, Session)
      vm.load()
      check vm.drawn.first("unseen").isNil
      vm.setFollow(false)
      discard source.sendFrame(FleetFrame(kind: ffEvent, sessionId: Session,
                                  event: stamp(8, fileRead("README.md")), ordinal: 8))
      let chip = vm.drawn.first("unseen")
      check chip.attr("unseen") == "1"
      fireEvent(chip, "mousedown")
      check vm.follow.val
      vm.toggle("group:" & vm.items[3].id)
      vm.toggle(vm.items[3].id)
      copied = @[]
      let root = vm.drawn
      let action = root.first("copy-action")
      check not action.isNil
      fireEvent(action, "mousedown")
      check copied.len == 1
      vm.connection.val = "Connected"
      check vm.drawn.first("badge").attr("badge") == "Connected"
      vm.dispose()
      disposeRoot()

  test "the load states":
    createRoot proc(disposeRoot: proc()) =
      let loading = newSessionTimelineVM(newPendingDataSource(), Session)
      loading.load()
      check loading.drawn.first("notice").attr("notice") == "loading"
      let empty = newSessionTimelineVM(sourceWith([stamp(1, statusEvent("running"))]), Session)
      empty.load()
      check empty.drawn.first("notice").attr("notice") == "empty"
      let failing = newSessionTimelineVM(newFailingDataSource("connection refused"), Session)
      failing.load()
      let root = failing.drawn
      check root.first("notice").attr("notice") == "error"
      check root.first("error").attr("error") == "connection refused"
      let unknown = newSessionTimelineVM(sourceWith([]), "5ca1ab1e-0e22-4e00-8000-00000000e022")
      unknown.load()
      check unknown.drawn.first("notice").attr("notice") == "unresolvable"
      for vm in [loading, empty, failing, unknown]: vm.dispose()
      disposeRoot()
