## CTF-P2b: the session activity timeline's web view, the rules every host's
## timeline shares, the cut of a file path, the timeline's keys, and the
## comparison of the timeline with today's Agent Activity cards.
##
## * **The path cut** (CTF-P1c D6, amended for paths): the shared
##   `pathCutCandidates` keep a path's first segment and its file name,
##   dropping the segments between one at a time; `cutPath` draws the first
##   that fits and falls back to the end cut; the trim applies on both sides
##   of the "…" (`danglesAroundEllipsis` reads the drawn text itself).
## * **The keys** are keymap rows: the router resolves `Right`, `Left`,
##   `Enter`, `+`, `-`, `Down` and `Up` in the timeline's scope to the
##   timeline's operations, and `runActivityOperation` moves the viewmodel.
## * **The web view** (`renderAgentHarborSessionActivity`) on the mock
##   renderer draws every line the viewmodel publishes, with its facts, in
##   order; a press on a line, routed as the page's pointer listener routes
##   it (the operation it carries, through the pointer keymap), opens it
##   through the viewmodel, and the view holds no handler; a line that
##   names a file marks its path for the middle cut; a detail carries Copy;
##   the running strip names the line that shows the running command; the
##   unseen chip, the filter row, the badge and every load state.
## * **Cardless**, the web's half that does not need a browser: no rule
##   of `agent_harbor_activity.styl` that styles a line or a part sets a
##   border, an outline or a background, except the focused line's inset bar
##   (`box-shadow`), which is not a fill. The rendered lines carry no inline
##   style but their indent.
## * **The comparison**: the cards are fed the very events the
##   timeline's source holds, through `agent_service.applyEvents`; a
##   timeline over other events is reported.
##
## The viewmodels read the seam's own `TimelineDataSource`,
## `PendingDataSource` and `FailingDataSource`; the renderer is IsoNim's mock
## renderer, which both `vm-unit` lanes drive. Every event is invented.
##
## One mock, justified: the comparison's store (`ReplayDataStore`) needs a
## backend to exist, and the comparison never asks it anything -- the cards
## read only the store's agent sessions, which `agent_service.applyEvents`
## writes. `MockBackendService` stands for the recording a story of an Agent
## Harbor session does not have; a real backend would need a recording.

import std/[json, sequtils, strutils, tables, unicode, unittest]

import isonim/core/owner
import isonim/testing/mock_dom
import nim_agents_isonim_viewmodels/agent_harbor/[data_source, session_events]

import ../../views/isonim_agent_harbor_session_activity_view
import ../../views/agent_harbor_words
import ../../views/ah_cut_text
import ../../agent_harbor_activity_cards
import ../../store/replay_data_store
import ../../backend/mock_backend
import ../../keymap/[base_keymaps, context_keys, keymap_router, scope_path,
                     editing_keymap]
import ../../input/element_press
import ../../../../common/key_names

const
  Session = "5ca1ab1e-0e01-4e00-8000-00000000e001"
  Ellipsis = "\xE2\x80\xA6"

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

proc attr(n: MockNode; name: string): string =
  n.attributes.getOrDefault("data-ah-" & name, "")

proc collect(n: MockNode; name: string; into: var seq[MockNode]) =
  if n.attributes.hasKey("data-ah-" & name): into.add n
  for ch in n.children: collect(ch, name, into)

proc all(n: MockNode; name: string): seq[MockNode] = collect(n, name, result)

proc first(n: MockNode; name: string): MockNode =
  let found = n.all(name)
  if found.len > 0: found[0] else: nil

proc textOf(n: MockNode): string =
  if n.kind == mnkText: return n.text
  for ch in n.children: result.add textOf(ch)

proc classOf(n: MockNode): string = n.attributes.getOrDefault("class", "")

proc render(vm: SessionTimelineVM): MockNode =
  renderAgentHarborSessionActivity[MockRenderer, MockNode](MockRenderer(), vm)

let pointerRouter = initKeymapRouter(bkCua, KeyDelivery(frontEnd: feTerminal,
  platform: hostPlatform(), keyProtocol: kpLegacy))
var copied: seq[string]
  ## What the host's clipboard received.

proc press(vm: SessionTimelineVM; el: MockNode): string =
  ## A press on `el` as the page's pointer listener routes it: the pointer
  ## keymap's row, else the operation it carries; the host runs it on the
  ## element's target. Returns the operation run.
  let outcome = resolveElementPress(routerResolver(pointerRouter, SessionFacts()),
    @[element(ekWindow, "window"), pane(SessionActivityScope)], ButtonElementKind,
    el.attributes.getOrDefault(OperationAttribute, ""), {}, "Click")
  discard vm.runActivityPress(outcome.operation,
    el.attributes.getOrDefault(PressTargetAttribute, ""),
    proc(text: string) = copied.add text)
  outcome.operation

proc noHandlers(n: MockNode): int =
  ## Listeners the view installed itself (none: presses are routed).
  result = n.eventListeners.len + n.eventHandlers.len + n.pointerHandlers.len
  for ch in n.children: result += noHandlers(ch)

suite "the path cut (D6, amended for paths)":
  test "a path keeps its first segment and its file name":
    check pathCutCandidates("src/upload/retry/client.py") ==
      @["src/" & Ellipsis & "/retry/client.py", "src/" & Ellipsis & "/client.py",
        Ellipsis & "/client.py"]
    check pathCutCandidates("src/client.py") == @[Ellipsis & "/client.py"]
    check pathCutCandidates("client.py").len == 0
    check pathCutCandidates("/client.py").len == 0
    check pathCutCandidates("src/lib/").len == 0
    check pathCutCandidates("/srv/a/b.py")[0] == "/srv/" & Ellipsis & "/b.py"

  test "the host draws the first cut that fits, else the end cut":
    let path = "src/upload/retry/client.py"
    proc within(n: int): proc(t: string): bool =
      result = proc(t: string): bool = t.runeLen <= n
    let endCut = proc(): string = "END"
    check cutPath(path, within(100), endCut) == path
    check cutPath(path, within(path.runeLen - 1), endCut) == "src/" & Ellipsis & "/retry/client.py"
    check cutPath(path, within(15), endCut) == "src/" & Ellipsis & "/client.py"
    check cutPath(path, within(11), endCut) == Ellipsis & "/client.py"
    check cutPath(path, within(10), endCut) == "END"

  test "the trim applies on both sides of the ellipsis":
    check trimAfterEllipsis(" \xC2\xB7 b") == "b"
    check trimAfterEllipsis("/b") == "/b"
    check danglesAroundEllipsis("a " & Ellipsis & "b")
    check danglesAroundEllipsis("a" & Ellipsis & " b")
    check danglesAroundEllipsis("a" & Ellipsis & "\xC2\xB7 b")
    check not danglesAroundEllipsis("src/" & Ellipsis & "/client.py")
    # An end cut is held to the end rule only.
    check danglesAroundEllipsis("Fix the flaky " & Ellipsis)
    check not danglesAroundEllipsis("Loading" & Ellipsis & " done" & Ellipsis)

suite "the keys are keymap rows":
  test "each key resolves to the timeline's operation in its scope":
    let router = initKeymapRouter(bkCua, KeyDelivery(frontEnd: feTerminal,
      platform: hostPlatform(), keyProtocol: kpLegacy))
    let path = @[element(ekWindow, "window"), pane(SessionActivityScope)]
    for (op, key) in [(ActivityOpenOperation, "Right"), (ActivityCloseOperation, "Left"),
                      (ActivityStepInOperation, "Enter"),
                      (ActivityExpandAllOperation, "+"), (ActivityCollapseAllOperation, "-"),
                      (ActivityFocusNextOperation, "Down"),
                      (ActivityFocusPreviousOperation, "Up")]:
      check router.chordFor(op, SessionFacts(), path, nmNormal) == key

  test "the operations move the viewmodel":
    createRoot proc(disposeRoot: proc()) =
      let vm = newSessionTimelineVM(sourceWith(basics()), Session)
      vm.load()
      check vm.runActivityOperation(ActivityFocusNextOperation)
      check vm.runActivityOperation(ActivityFocusNextOperation)
      check vm.focus.val == "group:" & vm.items[1].id
      check vm.runActivityOperation(ActivityOpenOperation)
      check vm.isExpanded("group:" & vm.items[1].id)
      check vm.runActivityOperation(ActivityCloseOperation)
      check not vm.isExpanded("group:" & vm.items[1].id)
      check vm.runActivityOperation(ActivityStepInOperation)
      check vm.focus.val == vm.items[1].id
      check vm.runActivityOperation(ActivityCloseOperation)
      check vm.focus.val == "group:" & vm.items[1].id
      check vm.runActivityOperation(ActivityExpandAllOperation)
      check vm.expandedIds.len == 2
      check vm.runActivityOperation(ActivityCollapseAllOperation)
      check vm.expandedIds.len == 0
      check vm.runActivityOperation(ActivityFocusPreviousOperation)
      check not vm.runActivityOperation("story-playback.play")
      vm.dispose()
      disposeRoot()

suite "the web view draws what the viewmodel publishes":
  test "every line, in order, with its facts":
    createRoot proc(disposeRoot: proc()) =
      let vm = newSessionTimelineVM(sourceWith(basics()), Session)
      vm.load()
      let panel = vm.render
      check panel.attr("surface") == "agent-harbor-session-activity"
      check panel.attr("state") == "ready"
      check panel.attr("status") == vm.statusLabel
      let drawn = panel.all("line")
      check drawn.mapIt(it.attr("line")) == vm.lines.mapIt(it.id)
      check drawn.mapIt(it.attr("text")) == vm.lines.mapIt(it.text)
      check drawn.mapIt(it.attr("role")) == vm.lines.mapIt(it.textRole)
      for d in drawn:
        if d.attr("line-kind") == "group":
          let line = vm.lines.filterIt(it.id == d.attr("line"))[0]
          check d.attr("count") == $line.count
          check d.attr("failed") == $line.failed
          check d.attr("running") == $line.running
      # Cardless: a line's only inline style is its indent.
      for d in drawn:
        check d.attributes.getOrDefault("style", "").startsWith("--ah-indent:")
        check d.styles.len == 0
      vm.dispose()
      disposeRoot()

  test "a pause in the session is a quiet gap line":
    createRoot proc(disposeRoot: proc()) =
      let vm = newSessionTimelineVM(sourceWith(basics() &
        @[stamp(700, agentReply("The slow tests pass."))]), Session)
      vm.load()
      let gaps = vm.lines.filterIt(it.kind == tlkGap)
      check gaps.len == 1
      let drawn = vm.render.all("line").filterIt(it.attr("line-kind") == "gap")
      check drawn.mapIt(it.attr("line")) == gaps.mapIt(it.id)
      check drawn.len == 1 and drawn[0].attr("role") == "quiet"
      check drawn.len == 1 and drawn[0].textOf == gaps[0].text
      vm.dispose()
      disposeRoot()

  test "a press on a line opens it through the viewmodel, and the view redraws":
    createRoot proc(disposeRoot: proc()) =
      let vm = newSessionTimelineVM(sourceWith(basics()), Session)
      vm.load()
      let panel = vm.render
      let group = panel.all("line").filterIt(it.attr("line-kind") == "group")[0]
      let id = group.attr("line")
      check group.attr("expanded") == "false"
      let toggle = group.children.filterIt(it.classOf == "ah-activity-toggle")[0]
      check toggle.attributes.getOrDefault(PressTargetAttribute) == id
      check panel.noHandlers == 0
      check vm.press(toggle) == ActivityToggleOperation
      check vm.isExpanded(id)
      check vm.focus.val == id
      let again = panel.all("line").filterIt(it.attr("line") == id)[0]
      check again.attr("expanded") == "true"
      check again.attr("focused") == "true"
      check "ah-activity-focused" in again.classOf
      check panel.all("line").len == vm.lines.len
      vm.dispose()
      disposeRoot()

  test "a path is marked for the middle cut; its words are not":
    createRoot proc(disposeRoot: proc()) =
      let vm = newSessionTimelineVM(sourceWith([stamp(1, userInput("Go.")),
        stamp(2, fileRead("src/upload/retry/client.py"))]), Session)
      vm.load()
      let panel = vm.render
      let paths = panel.all("path-shown")
      check paths.len == 1
      check paths[0].attributes.getOrDefault(CutTextAttribute) == CutPathValue
      check paths[0].textOf == "src/upload/retry/client.py"
      let line = panel.all("line").filterIt(it.attr("path").len > 0)[0]
      let words = line.all("path-shown")[0].parent.children[0]
      check words.textOf == "Read"
      check not words.attributes.hasKey(CutTextAttribute)
      vm.dispose()
      disposeRoot()

  test "a detail carries Copy, which copies its text":
    createRoot proc(disposeRoot: proc()) =
      let vm = newSessionTimelineVM(sourceWith(basics()), Session)
      vm.load()
      copied = @[]
      let panel = vm.render
      let item = vm.items[3]   # the failed command
      vm.toggle("group:" & vm.items[3].id)
      vm.toggle(item.id)
      let details = panel.all("copy")
      check details.len > 0
      for d in details:
        check d.all("copy-action").len == 1
      let first = details[0]
      check vm.press(first.all("copy-action")[0]) == ActivityCopyOperation
      check copied == @[first.attr("copy")]
      vm.dispose()
      disposeRoot()

  test "the running strip names the line that shows the running command":
    createRoot proc(disposeRoot: proc()) =
      let vm = newSessionTimelineVM(sourceWith(basics()), Session)
      vm.load()
      let panel = vm.render
      let strip = panel.first("running-strip")
      check not strip.isNil
      check strip.attr("running-strip") == "Running: pytest -q tests/integration --slow"
      let group = vm.lines.filterIt(it.kind == tlkGroup and it.running > 0)[0]
      check strip.attr("running-for") == group.id
      # Open, the item's own line shows it.
      vm.toggle(group.id)
      check panel.first("running-strip").attr("running-for") == vm.runningLine.id
      vm.dispose()
      disposeRoot()

  test "the unseen chip, the filter row and the connection badge":
    createRoot proc(disposeRoot: proc()) =
      let source = sourceWith(basics())
      let vm = newSessionTimelineVM(source, Session)
      vm.load()
      let panel = vm.render
      check panel.first("unseen").isNil
      vm.setFollow(false)
      discard source.sendFrame(FleetFrame(kind: ffEvent, sessionId: Session,
                                  event: stamp(8, fileRead("README.md")), ordinal: 8))
      check vm.unseen.val == 1
      let chip = panel.first("unseen")
      check not chip.isNil
      check chip.textOf == "1 new \xC2\xB7 Jump to latest"
      check vm.press(chip) == ActivityJumpOperation
      check vm.follow.val
      check panel.first("unseen").isNil
      vm.setFilter("pytest")
      check panel.first("filter").attr("filter") == "pytest"
      check panel.first("filter").textOf.contains(vm.filterCountText)
      vm.setFilter("")
      check panel.first("filter").isNil
      vm.connection.val = "Reconnecting"
      check panel.first("badge").attr("badge") == "Reconnecting"
      vm.dispose()
      disposeRoot()

  test "every load state: loading, empty, error with Retry, cannot be loaded":
    createRoot proc(disposeRoot: proc()) =
      let loading = newSessionTimelineVM(newPendingDataSource(), Session)
      loading.load()
      check loading.render.first("notice").textOf == LoadingNotice
      let empty = newSessionTimelineVM(sourceWith([stamp(1, statusEvent("running"))]), Session)
      empty.load()
      check empty.render.first("notice").textOf == EmptyNotice
      let failing = newSessionTimelineVM(newFailingDataSource("connection refused"), Session)
      failing.load()
      let errorBlock = failing.render.first("notice")
      check errorBlock.attr("notice") == "error"
      check errorBlock.textOf.contains(ErrorTitle)
      check errorBlock.first("error").attr("error") == "connection refused"
      let unknown = newSessionTimelineVM(sourceWith([]), "5ca1ab1e-0e02-4e00-8000-00000000e002")
      unknown.load()
      let n = unknown.render.first("notice")
      check n.attr("notice") == "unresolvable"
      check n.textOf.startsWith(UnresolvablePrefix)
      for vm in [loading, empty, failing, unknown]: vm.dispose()
      disposeRoot()

suite "cardless: the stylesheet frames no event":
  test "no rule that styles a line or a part sets a border, outline or background":
    # Read at compile time, so the check runs on every backend (the JS one
    # has no file system).
    const stylText = staticRead("../../../styles/components/agent_harbor_activity.styl")
    # A `let`, not the const: a for-loop over a const string is re-evaluated
    # per iteration on the JS backend (quadratic; ci/lint's js-const-iteration
    # guard).
    let styl = stylText
    var selector = ""
    var problems: seq[string]
    var lineRules = 0
    for raw in styl.splitLines:
      if raw.strip.len == 0 or raw.strip.startsWith("//"): continue
      if not raw.startsWith(" "):
        selector = raw.strip
        if "ah-activity-line" in selector or "ah-activity-role-" in selector or
            "ah-activity-part" in selector or "ah-activity-focused" in selector or
            "ah-activity-turn" in selector or "ah-activity-detail" in selector or
            "ah-activity-trace" in selector:
          inc lineRules
        continue
      let decl = raw.strip
      let framesLine = "ah-activity-line" in selector or "ah-activity-role-" in selector or
        "ah-activity-part" in selector or "ah-activity-focused" in selector or
        "ah-activity-turn" in selector or "ah-activity-detail" in selector or
        "ah-activity-trace" in selector or "ah-activity-text" in selector
      if not framesLine: continue
      for prop in ["border", "outline", "background"]:
        if decl.startsWith(prop) and ':' in decl:
          let value = decl.split(':', 1)[1].strip
          if value notin ["0", "none", "transparent"]:
            problems.add selector & " { " & decl & " }"
      if decl.startsWith("box-shadow") and "inset" notin decl:
        problems.add selector & " { " & decl & " }"
    check lineRules >= 10
    check problems.len == 0
    if problems.len > 0: echo problems.join("\n")

suite "the timeline against today's cards":
  test "the cards are fed the events the timeline's source holds":
    createRoot proc(disposeRoot: proc()) =
      let events = basics()
      let store = createReplayDataStore(newMockBackendService().toBackendService())
      let pair = newActivityAgainstCards(store, Session, events)
      let source = pair.timelineSource
      let vm = newSessionTimelineVM(source, Session)
      vm.load()
      check pair.entry.sessionId == Session
      check pair.entry.events.len == events.len
      check pair.againstCardsProblems(vm, source).len == 0
      # The cards' panel shows the session's messages.
      check pair.cards.sessionKey.val == pair.tabId
      # A timeline over other events, or of another session, is reported.
      let other = sourceWith(events[0 .. ^2])
      let shorter = newSessionTimelineVM(other, Session)
      check pair.againstCardsProblems(shorter, other).len == 1
      let elsewhere = newSessionTimelineVM(source, "5ca1ab1e-0e03-4e00-8000-00000000e003")
      check pair.againstCardsProblems(elsewhere, source).len == 2
      for v in [vm, shorter, elsewhere]: v.dispose()
      store.dispose()
      disposeRoot()
