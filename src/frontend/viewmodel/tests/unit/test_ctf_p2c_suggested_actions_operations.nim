## CTF-P2c step 3: the suggested-actions block's presses are routed
## operations, the same in every host (study D59; Input-Routing-And-Keymaps.md
## §4 and §5.1), and the web view draws what the viewmodel holds, at the end
## of P2b's timeline (D23, D55).
##
## * **The catalogue holds every operation** the block's elements carry, in
##   the timeline's table (the block lives in its `sessionActivity` scope).
## * **The web view carries them**: on IsoNim's mock renderer each row
##   that can be performed carries `suggested-actions.toggle` and its id,
##   `Approve` and `Dismiss` theirs, a disabled row none; the view installs
##   no press handler of its own.
## * **A press routed as the page's pointer listener routes it** does what
##   the operation says: a row toggles, Approve performs the checked actions,
##   Dismiss dismisses; a toggle with no target is declined.
## * **The slot in the timeline**: with a waiting block, the block follows
##   the timeline's list and is not in it; once decided, the record lines
##   follow the timeline's lines, and the timeline's own lines are the same
##   with the block as without it.
##
## No mocks beyond IsoNim's mock renderer (the view's DOM): the viewmodels
## are the stories' own (`createSuggestedActionsStory`), over the scripted
## performer and action source those stories use.

import std/[sequtils, strutils, tables, unittest]
import isonim/core/owner
import isonim/testing/mock_dom
import ../../views/isonim_agent_harbor_session_activity_view
import ../../../stories/agent_harbor_suggested_actions_stories
import ../../keymap/[base_keymaps, context_keys, keymap_router, scope_path,
                     editing_keymap, operation_catalogue]
import ../../input/element_press

let router = initKeymapRouter(bkCua, KeyDelivery(frontEnd: feTerminal,
  platform: hostPlatform(), keyProtocol: kpLegacy))
let path = @[element(ekWindow, "window"), pane(SessionActivityScope)]

proc collect(n: MockNode; name: string; into: var seq[MockNode]) =
  if n.attributes.hasKey(name): into.add n
  for ch in n.children: collect(ch, name, into)

proc all(n: MockNode; name: string): seq[MockNode] = collect(n, name, result)

proc attr(n: MockNode; name: string): string = n.attributes.getOrDefault(name, "")

proc handlers(n: MockNode): int =
  result = n.eventListeners.len + n.eventHandlers.len + n.pointerHandlers.len
  for ch in n.children: result += handlers(ch)

proc render(story: SuggestedActionsStory; withTail = true): MockNode =
  renderAgentHarborSessionActivity[MockRenderer, MockNode](MockRenderer(), story.timeline,
    if withTail: story.suggestion else: nil)

proc carrying(root: MockNode; operation: string): seq[MockNode] =
  root.all(OperationAttribute).filterIt(it.attr(OperationAttribute) == operation)

proc press(vm: SuggestedActionsVM; el: MockNode): string =
  ## A press on `el` as the page's pointer listener routes it; the host runs
  ## it on the element's target. Returns the operation run ("" declined).
  let outcome = resolveElementPress(routerResolver(router, SessionFacts()), path,
    ButtonElementKind, el.attr(OperationAttribute), {}, "Click")
  if vm.runSuggestedActionsPress(outcome.operation, el.attr("data-ah-target")):
    outcome.operation
  else: ""

proc withStory(fixture: string; body: proc(story: SuggestedActionsStory)) =
  createRoot proc(disposeRoot: proc()) =
    let story = createSuggestedActionsStory(fixture)
    body(story)
    story.dispose()
    disposeRoot()

suite "the block's presses are catalogued":
  test "every operation is in the timeline's table":
    var catalogued: seq[string]
    for entry in Catalogue:
      if entry.table == SessionActivityTable: catalogued.add entry.name
    for op in SuggestedActionsOperations:
      check op in catalogued

suite "the web view carries the operations and holds no handler":
  test "each performable row, Approve and Dismiss name their operation; a disabled row none":
    withStory("unsupported", proc(story: SuggestedActionsStory) =
      let root = story.render
      check root.handlers == 0
      let toggles = root.carrying(SuggestedToggleOperation)
      check toggles.mapIt(it.attr("data-ah-target")) == @["open-recording", "show-calltrace"]
      let disabled = root.all("data-ah-action-disabled").filterIt(
        it.attr("data-ah-action-disabled") == "true")
      check disabled.len == 1
      check disabled[0].attr(OperationAttribute) == ""
      check root.carrying(SuggestedApproveOperation).len == 1
      check root.carrying(SuggestedDismissOperation).len == 1)

  test "a press on a row toggles it; Approve performs; a toggle with no target is declined":
    withStory("several", proc(story: SuggestedActionsStory) =
      let vm = story.suggestion
      var root = story.render
      check vm.press(root.carrying(SuggestedToggleOperation)[1]) == SuggestedToggleOperation
      check vm.approveLabel == "Approve 2 of 3"
      check not vm.runSuggestedActionsPress(SuggestedToggleOperation, "")
      check not vm.runSuggestedActionsPress("session-activity.toggle", "show-calltrace")
      root = story.render
      check vm.press(root.carrying(SuggestedApproveOperation)[0]) == SuggestedApproveOperation
      check vm.phase == spApproved)

  test "Dismiss dismisses":
    withStory("one", proc(story: SuggestedActionsStory) =
      let root = story.render
      check story.suggestion.press(root.carrying(SuggestedDismissOperation)[0]) ==
            SuggestedDismissOperation
      check story.suggestion.phase == spDismissed)

suite "the slot at the timeline's end":
  test "a waiting block follows the list and is not in it":
    withStory("one", proc(story: SuggestedActionsStory) =
      let root = story.render
      let blocks = root.all("data-ah-suggested")
      check blocks.len == 1
      let lists = root.all("data-ah-lines")
      check lists.len == 1
      check lists[0].all("data-ah-suggested").len == 0)

  test "the record lines follow the timeline's own lines, which do not change":
    withStory("approved", proc(story: SuggestedActionsStory) =
      let without = story.render(withTail = false).all("data-ah-line").mapIt(it.attr("data-ah-line"))
      let lines = story.render.all("data-ah-line")
      let ids = lines.mapIt(it.attr("data-ah-line"))
      check ids[0 ..< without.len] == without
      check ids.len == without.len + 3
      check lines[^3].attr("data-ah-text") == "Approved 2 UI actions"
      check lines[^1].attr("data-ah-level") == "1"
      check ids[^1].startsWith("suggestion:")
      check story.render.all("data-ah-suggested").len == 0)
