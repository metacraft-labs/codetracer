## CTF-P2c step 5: the process switcher's presses and keys are routed
## operations, the same in every host (study D82; Input-Routing-And-Keymaps.md
## §4 and §5.1), and the web view draws what the viewmodel holds.
##
## * **The catalogue and the keymap**: every operation is catalogued in its
##   table; `Ctrl+Alt+PageDown` / `Ctrl+Alt+PageUp` resolve to the next and
##   previous process at the window's scope under every base (CUA, Emacs,
##   Vim, Kakoune), and do not shadow `Ctrl+PageDown` / `Ctrl+PageUp` (the
##   session tabs); the digits pick a process while the switcher has the
##   focus, and only there.
## * **The keys reach the router** from each host's decoder: the terminal's
##   byte decoder reads `CSI 6;7~` / `CSI 5;7~` as the chords
##   (`key_names.keyName`, the story host's and the production terminal's
##   decoder), and GPUI's keystroke decoder spells them the same
##   (`gpui_keys.canonicalKeyOfGpui`; GPUI's host routes every key through
##   the one router, `test_plat48_gpui_top_bar`).
## * **The words name the bound keys** (`processChord`), so the tab's tooltip
##   cannot name a key that does something else.
## * **The web view** on IsoNim's mock renderer: the recording's tab, active,
##   with the switcher's buttons for its processes inside it (drawn by the
##   recording switcher's own view), the plain tab beside it, the facts the
##   play checks read; it installs no handler of its own (the switcher's
##   buttons' handlers are that view's, the press seam); the ringed button
##   carries the switcher's ring class.
##
## No mocks beyond IsoNim's mock renderer: the viewmodels are the stories'
## own (`createProcessSwitcherStoryVM`).

import std/[os, sequtils, strutils, tables, unittest]
import isonim/core/owner
import isonim/testing/mock_dom
import ../../views/isonim_agent_harbor_process_switcher_view
import ../../../stories/agent_harbor_process_switcher_stories
import ../../keymap/[base_keymaps, context_keys, keymap_router, scope_path,
                     editing_keymap, operation_catalogue]
import ../../input/element_press
import ../../../gpui/app/gpui_keys
import ../../../../common/key_names

let switcherPath = @[element(ekWindow, "window"), pane(ProcessSwitcherScope)]
let windowPath = @[element(ekWindow, "window")]

type Routed = tuple[operation, argument: string]

proc key(path: seq[ScopeElement]; name: string; base = bkCua): Routed =
  var r = initKeymapRouter(base, KeyDelivery(frontEnd: feTerminal,
    platform: hostPlatform(), keyProtocol: kpLegacy))
  let res = r.route(SessionFacts(), path, nmNormal, name, 0)
  if res.kind == erOperation: (res.operation, res.argument) else: ("", "")

proc collect(n: MockNode; name: string; into: var seq[MockNode]) =
  if n.attributes.hasKey(name): into.add n
  for ch in n.children: collect(ch, name, into)

proc all(n: MockNode; name: string): seq[MockNode] = collect(n, name, result)

proc attr(n: MockNode; name: string): string = n.attributes.getOrDefault(name, "")

proc hasClass(n: MockNode; c: string): bool =
  c in n.attributes.getOrDefault("class", "").split(' ')

proc findClass(n: MockNode; c: string; into: var seq[MockNode]) =
  if n.hasClass(c): into.add n
  for ch in n.children: findClass(ch, c, into)

proc byClass(n: MockNode; c: string): seq[MockNode] = findClass(n, c, result)

proc ownHandlers(n: MockNode): int =
  ## The handlers outside the recording switcher it draws (that view's own,
  ## the press seam).
  if n.hasClass("ah-rec-switch"): return 0
  result = n.eventListeners.len + n.eventHandlers.len + n.pointerHandlers.len
  for ch in n.children: result += ownHandlers(ch)

proc textOf(n: MockNode): string =
  result = n.text
  for ch in n.children: result.add textOf(ch)

proc render(vm: ProcessSwitcherVM; slots = ProcessSlots;
            press: ProcessPress = nil): MockNode =
  renderAgentHarborProcessSwitcher[MockRenderer, MockNode](MockRenderer(), vm,
    OtherTabTitle, slots, processChord(ProcessNextOperation),
    processChord(ProcessPreviousOperation), press)

proc withVM(fixture: string; body: proc(vm: ProcessSwitcherVM)) =
  createRoot proc(disposeRoot: proc()) =
    let vm = createProcessSwitcherStoryVM(fixture)
    body(vm)
    vm.dispose()
    disposeRoot()

suite "the operations are catalogued and bound under every base":
  test "every operation is catalogued in its table":
    var table = initTable[string, string]()
    for entry in Catalogue: table[entry.name] = entry.table
    check table.getOrDefault(ProcessNextOperation) == GlobalTable
    check table.getOrDefault(ProcessPreviousOperation) == GlobalTable
    check table.getOrDefault(ProcessSelectOperation) == ProcessSwitcherTable
    check "process-switcher.follow-correlation" notin table
    for op in ProcessSwitcherOperations: check op in table

  test "Ctrl+Alt+PageDown / PageUp step the processes at the window's scope":
    for base in [bkCua, bkEmacs, bkVim, bkKakoune]:
      check key(windowPath, "Ctrl+Alt+PageDown", base).operation == ProcessNextOperation
      check key(windowPath, "Ctrl+Alt+PageUp", base).operation == ProcessPreviousOperation
      check key(switcherPath, "Ctrl+Alt+PageDown", base).operation == ProcessNextOperation
    # The session tabs keep Ctrl+PageDown / Ctrl+PageUp (CUA).
    check key(windowPath, "Ctrl+PageDown").operation == "session-tabs.next"
    check key(windowPath, "Ctrl+PageUp").operation == "session-tabs.previous"

  test "the digits pick a process while the switcher has the focus, and only there":
    for base in [bkCua, bkEmacs, bkVim, bkKakoune]:
      for n in 1 .. 9:
        check key(switcherPath, $n, base) == (ProcessSelectOperation, $n)
      check key(windowPath, "2", base).operation != ProcessSelectOperation

  test "the words name the keys the keymap binds":
    check processChord(ProcessNextOperation) == "Ctrl+Alt+PageDown"
    check processChord(ProcessPreviousOperation) == "Ctrl+Alt+PageUp"
    check processChord(ProcessSelectOperation) == ""   # its rows carry a number

suite "the keys reach the router from each host's decoder":
  test "the terminal's byte decoder reads CSI 6;7~ and CSI 5;7~":
    check keyName("\e[6;7~") == "Ctrl+Alt+PageDown"
    check keyName("\e[5;7~") == "Ctrl+Alt+PageUp"
    check keyName("2") == "2"

  test "GPUI's keystroke decoder spells the same chords":
    check canonicalKeyOfGpui("pagedown", ["control", "alt"]) == "Ctrl+Alt+PageDown"
    check canonicalKeyOfGpui("pageup", ["control", "alt"]) == "Ctrl+Alt+PageUp"

suite "a key does what its row says":
  test "next, previous and a number move the active process":
    withVM("three", proc(vm: ProcessSwitcherVM) =
      let k = key(windowPath, "Ctrl+Alt+PageDown")
      check vm.runProcessSwitcherOperation(k.operation, k.argument)
      check vm.activeNumber == 2
      let n = key(switcherPath, "3")
      check vm.runProcessSwitcherOperation(n.operation, n.argument)
      check vm.activeNumber == 3
      let p = key(windowPath, "Ctrl+Alt+PageUp")
      check vm.runProcessSwitcherOperation(p.operation, p.argument)
      check vm.activeNumber == 2
      check not vm.runProcessSwitcherOperation(ProcessSelectOperation, "x")
      check not vm.runProcessSwitcherOperation("control-center.next"))

  test "following the marker by its number clears the ring":
    withVM("correlation", proc(vm: ProcessSwitcherVM) =
      let n = key(switcherPath, "2")
      check vm.runProcessSwitcherOperation(n.operation, n.argument)
      check vm.ringedNumber == 0)

suite "the web view":
  test "the recording's tab holds the switcher; the plain tab follows":
    withVM("three", proc(vm: ProcessSwitcherVM) =
      let root = vm.render
      check root.attr("data-ah-surface") == ProcessSwitcherSurface
      check root.ownHandlers == 0
      let tabs = root.byClass("session-tab")
      check tabs.len == 2
      check tabs[0].hasClass("active") and tabs[0].hasClass(ProcessSwitcherTabClass)
      check tabs[0].textOf.startsWith(EnvelopeFlowTitle)
      check tabs[1].textOf == OtherTabTitle
      check tabs[0].attr("data-ah-processes") == "3"
      check tabs[0].attr("data-ah-process-active") == "1"
      check tabs[0].attr("title").endsWith(
        "Ctrl+Alt+PageDown / Ctrl+Alt+PageUp to move between them")
      let host = tabs[0].byClass("ah-ps-processes")
      check host.len == 1 and host[0].attr("data-ct-pane") == ProcessSwitcherScope
      let buttons = tabs[0].byClass("ah-rec-button")
      check buttons.len == 3
      check buttons[0].hasClass("ah-rec-active")
      check buttons[1].attr("title") == "backend \xC2\xB7 pid 4182 \xC2\xB7 /srv/envelope/bin/backend")

  test "the ringed process is a fact on the tab and in its button's tooltip":
    withVM("correlation", proc(vm: ProcessSwitcherVM) =
      let tab = vm.render.byClass(ProcessSwitcherTabClass)[0]
      check tab.attr("data-ah-process-ringed") == "2"
      check tab.attr("data-ah-process-ringed-hidden") == "false"
      let b = tab.byClass("ah-rec-button")
      check b[1].attr("title").endsWith(CorrelationWords)
      check b[1].hasClass("ah-rec-ringed")
      check b.countIt(it.hasClass("ah-rec-ringed")) == 1)

  test "behind +N, the chip carries the ring":
    withVM("many", proc(vm: ProcessSwitcherVM) =
      check vm.markCorrelation("envelope-worker-6", "x")
      let tab = vm.render.byClass(ProcessSwitcherTabClass)[0]
      check tab.attr("data-ah-process-ringed-hidden") == "true"
      check tab.byClass("ah-rec-more")[0].hasClass("ah-rec-ringed")
      check tab.byClass("ah-rec-button").allIt(not it.hasClass("ah-rec-ringed")))

  test "many: five buttons and +3 in the error severity":
    withVM("many", proc(vm: ProcessSwitcherVM) =
      let tab = vm.render.byClass(ProcessSwitcherTabClass)[0]
      check tab.byClass("ah-rec-button").len == 5
      let more = tab.byClass("ah-rec-more")
      check more.len == 1
      check more[0].textOf == "+3"
      check more[0].hasClass("ah-att-failed"))

  test "loading and missing take their states":
    withVM("loading-and-missing", proc(vm: ProcessSwitcherVM) =
      let b = vm.render.byClass("ah-rec-button")
      check b[1].hasClass("ah-rec-loading")
      check b[2].hasClass("ah-rec-missing"))

  test "a press on a button is routed and selects its process; the view redraws":
    withVM("three", proc(vm: ProcessSwitcherVM) =
      let resolve = routerResolver(initKeymapRouter(bkCua, KeyDelivery(frontEnd: feTerminal,
        platform: hostPlatform(), keyProtocol: kpLegacy)), SessionFacts())
      var routed: seq[string]
      let root = vm.render(press = proc(operation, target: string) =
        let outcome = resolveElementPress(resolve, switcherPath, ButtonElementKind,
                                          operation, {}, "Click")
        routed.add outcome.operation
        discard vm.runProcessSwitcherPress(outcome.operation, target))
      let b = root.byClass("ah-rec-button")[2]
      b.fireEvent("click")
      check routed == @[ProcessSelectOperation]
      check vm.activeNumber == 3
      check root.byClass(ProcessSwitcherTabClass)[0].attr("data-ah-process-active") == "3")

  test "the source draws the switcher with the recording switcher's own view":
    # Read when the suite compiles: `readFile` has no file system under
    # `nim js` ("fopen is not defined" under node).
    const source = staticRead(currentSourcePath().parentDir / ".." / ".." / "views" /
                              "isonim_agent_harbor_process_switcher_view.nim")
    check "renderRecordingSwitcher[R, N](r, buttons" in source
    check "SEAM(press)" in source
