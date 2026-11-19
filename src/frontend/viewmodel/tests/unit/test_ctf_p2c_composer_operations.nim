## CTF-P2c (P2c-G): the omnibox composer's keys and presses are routed
## operations, the same in every host (study D31; Input-Routing-And-Keymaps.md
## §4 and §5.1).
##
## * **The keys are keymap rows**: the router resolves `Enter`, `Down` and
##   `Up` in the composer's scope to `composer.send`,
##   `composer.next-destination` and `composer.previous-destination`, and
##   `runComposerOperation` moves the viewmodel.
## * **The catalogue holds every operation** the composer's elements carry
##   or its keys run, in the composer's table.
## * **The web view carries them**: on IsoNim's mock renderer every element
##   a press acts on carries its operation (`data-ct-operation`) and its
##   target (`data-ah-target`), the composer is the `composer` scope
##   (`data-ct-pane`), and the view installs no press handler of its own.
## * **A press routed as the page's pointer listener routes it** (the pointer
##   keymap's row, else the operation the element carries) does what the
##   operation says, through the viewmodel: a chip is cited or uncited, `+`
##   opens the add-context menu, `Send to …` sends again, a recent
##   instruction is recalled, the send button sends.
##
## No mocks beyond IsoNim's mock renderer (the view's DOM): the viewmodels
## are the composer stories' own (`createComposerStoryVM`), over the scripted
## router and action source those stories use, which answer every write
## (the prototypes never write to a server).

import std/[sequtils, strutils, tables, unittest]
import isonim/core/owner
import isonim/testing/mock_dom
import ../../views/isonim_agent_harbor_composer_view
import ../../../stories/agent_harbor_composer_stories
import ../../keymap/[base_keymaps, context_keys, keymap_router, scope_path,
                     editing_keymap, operation_catalogue]
import ../../input/element_press
import ../../../../common/key_names

let router = initKeymapRouter(bkCua, KeyDelivery(frontEnd: feTerminal,
  platform: hostPlatform(), keyProtocol: kpLegacy))
let path = @[element(ekWindow, "window"), pane(ComposerScope)]

proc collect(n: MockNode; name: string; into: var seq[MockNode]) =
  if n.attributes.hasKey(name): into.add n
  for ch in n.children: collect(ch, name, into)

proc all(n: MockNode; name: string): seq[MockNode] = collect(n, name, result)

proc attr(n: MockNode; name: string): string = n.attributes.getOrDefault(name, "")

proc handlers(n: MockNode): int =
  ## Listeners the view installed itself.
  result = n.eventListeners.len + n.eventHandlers.len + n.pointerHandlers.len
  for ch in n.children: result += handlers(ch)

proc render(vm: OmniboxComposerVM): MockNode =
  renderAgentHarborComposer[MockRenderer, MockNode](MockRenderer(), vm)

proc press(vm: OmniboxComposerVM; el: MockNode): string =
  ## A press on `el` as the page's pointer listener routes it: the pointer
  ## keymap's row, else the operation it carries; the host runs it on the
  ## element's target. Returns the operation run ("" when it declined).
  let outcome = resolveElementPress(routerResolver(router, SessionFacts()), path,
    ButtonElementKind, el.attr(OperationAttribute), {}, "Click")
  if vm.runComposerPress(outcome.operation, el.attr(ComposerTargetAttribute)):
    outcome.operation
  else: ""

proc withComposer(fixture: string; body: proc(vm: OmniboxComposerVM)) =
  createRoot proc(disposeRoot: proc()) =
    let vm = createComposerStoryVM(fixture)
    body(vm)
    vm.dispose()
    disposeRoot()

suite "the composer's keys are keymap rows":
  test "each key resolves to the composer's operation in its scope":
    for (op, key) in [(ComposerSendOperation, "Enter"), (ComposerNextOperation, "Down"),
                      (ComposerPreviousOperation, "Up")]:
      check router.chordFor(op, SessionFacts(), path, nmNormal) == key

  test "every operation is catalogued in the composer's table":
    var catalogued: seq[string]
    for entry in Catalogue:
      if entry.table == ComposerTable: catalogued.add entry.name
    for op in @ComposerOperations & @ComposerPressOperations:
      check op in catalogued
    check catalogued.len == 9

  test "Down and Up move the destination, Enter sends":
    withComposer("typing", proc(vm: OmniboxComposerVM) =
      let before = vm.draft.chosen
      check vm.runComposerOperation(ComposerNextOperation)
      check vm.draft.chosen != before
      check vm.runComposerOperation(ComposerPreviousOperation)
      check vm.draft.chosen == before
      check vm.runComposerOperation(ComposerSendOperation)
      check vm.phase in {cpSending, cpSent}
      check not vm.runComposerOperation("session-activity.open"))

suite "the web view carries the operations and holds no handler":
  test "every pressable element names its operation and target":
    withComposer("typing", proc(vm: OmniboxComposerVM) =
      let root = vm.render
      check root.all("data-ct-pane").mapIt(it.attr("data-ct-pane")) == @[ComposerScope]
      check root.handlers == 0
      for el in root.all("data-ah-action"):
        let op = operationOfAction(el.attr("data-ah-action"))
        check el.attr(OperationAttribute) == op
      let ops = root.all(OperationAttribute).mapIt(it.attr(OperationAttribute))
      check ComposerCiteOperation in ops
      check ComposerAddContextOperation in ops
      check ComposerSendOperation in ops)

  test "a press on a chip cites or uncites it, through the viewmodel":
    withComposer("typing", proc(vm: OmniboxComposerVM) =
      var root = vm.render
      let chip = root.all(OperationAttribute).filterIt(
        it.attr(OperationAttribute) == ComposerCiteOperation)[0]
      let id = chip.attr(ComposerTargetAttribute)
      let cited = vm.chips.filterIt(it.item.id == id)[0].cited
      check vm.press(chip) == ComposerCiteOperation
      check vm.chips.filterIt(it.item.id == id)[0].cited != cited)

  test "+ opens the add-context menu; the send button sends":
    withComposer("typing", proc(vm: OmniboxComposerVM) =
      let root = vm.render
      let add = root.all(OperationAttribute).filterIt(
        it.attr(OperationAttribute) == ComposerAddContextOperation)[0]
      check vm.press(add) == ComposerAddContextOperation
      check vm.addContextOpen.val
      let send = root.all(OperationAttribute).filterIt(
        it.attr(OperationAttribute) == ComposerSendOperation)[0]
      check vm.press(send) == ComposerSendOperation
      check vm.phase in {cpSending, cpSent})

  test "Send to … sends again, nothing withdrawn":
    withComposer("sent", proc(vm: OmniboxComposerVM) =
      let root = vm.render
      let again = root.all(OperationAttribute).filterIt(
        it.attr(OperationAttribute) == ComposerSendAgainOperation)
      check again.len >= 1
      let before = vm.draft.deliveries.len
      check vm.press(again[0]) == ComposerSendAgainOperation
      check vm.draft.deliveries.len == before + 1)

  test "a recent instruction is recalled into the field":
    withComposer("recent", proc(vm: OmniboxComposerVM) =
      let root = vm.render
      let rows = root.all(OperationAttribute).filterIt(
        it.attr(OperationAttribute) == ComposerRecallOperation)
      check rows.len == vm.recent.len
      let text = vm.recent[0].text
      check vm.press(rows[0]) == ComposerRecallOperation
      check vm.fieldText.startsWith(text.splitLines[0]))

  test "a press with a target it cannot read is declined":
    withComposer("typing", proc(vm: OmniboxComposerVM) =
      check not vm.runComposerPress(ComposerRecallOperation, "not a number")
      check not vm.runComposerPress(ComposerSendAgainOperation, "nowhere")
      check not vm.runComposerPress(ComposerCiteOperation, ""))
