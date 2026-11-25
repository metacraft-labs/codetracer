## CTF-P2c step 4: the control center's and the gaze mark's presses and keys
## are routed operations, the same in every host (study D64-D70;
## Input-Routing-And-Keymaps.md §4 and §5.1), and the web views draw what
## the viewmodels hold.
##
## * **The catalogue and the keymap**: every operation the control center
##   and the mark carry is catalogued; `Down` / `Up` / `Enter` resolve in the
##   `controlCenter` scope; the pause key `Ctrl+Alt+Y` resolves to
##   `gaze.toggle-pause` under every base, and `Ctrl+Alt+G` (the chorded
##   stepping set's Continue, study D65) does not.
## * **The web view carries them** on IsoNim's mock renderer and installs no
##   press handler: the mode and `For` toggles, each waiting row with its
##   session, the send button; the launch column is the composer's scope.
## * **It composes the Initiatives panel**, the panel's own view, and the
##   composer's own form, never a copy of either.
## * **A press routed as the page's pointer listener routes it** does what
##   the operation says, and a key does what its row says.
## * **The gaze mark**: off draws nothing; the tooltip names the key the
##   keymap binds (`gazePauseChord`); a press pauses.
##
## No mocks beyond IsoNim's mock renderer (the views' DOM): the viewmodels are
## the stories' own (`createControlCenterStoryVM`, `createGazeStoryVM`), over
## the scripted router and action source those stories use.

import std/[os, sequtils, strutils, tables, unittest]
import isonim/core/owner
import isonim/testing/mock_dom
import ../../views/[isonim_agent_harbor_control_center_view,
                    isonim_agent_harbor_gaze_mark_view]
import ../../../stories/[agent_harbor_control_center_stories, agent_harbor_gaze_stories,
                         layout_story_data]
import ../../keymap/[base_keymaps, context_keys, keymap_router, scope_path,
                     editing_keymap, operation_catalogue]
import ../../input/element_press

let router = initKeymapRouter(bkCua, KeyDelivery(frontEnd: feTerminal,
  platform: hostPlatform(), keyProtocol: kpLegacy))
let centerPath = @[element(ekWindow, "window"), pane(ControlCenterScope)]
let windowPath = @[element(ekWindow, "window")]

proc collect(n: MockNode; name: string; into: var seq[MockNode]) =
  if n.attributes.hasKey(name): into.add n
  for ch in n.children: collect(ch, name, into)

proc all(n: MockNode; name: string): seq[MockNode] = collect(n, name, result)

proc attr(n: MockNode; name: string): string = n.attributes.getOrDefault(name, "")

proc handlers(n: MockNode): int =
  result = n.eventListeners.len + n.eventHandlers.len + n.pointerHandlers.len
  for ch in n.children: result += handlers(ch)

proc ownHandlers(n: MockNode): int =
  ## The handlers outside the Initiatives panel it draws (that panel's own
  ## view, whose presses are its own and not this step's).
  if n.attributes.getOrDefault("class", "").contains("ah-cc-initiatives"): return 0
  result = n.eventListeners.len + n.eventHandlers.len + n.pointerHandlers.len
  for ch in n.children: result += ownHandlers(ch)

proc carrying(root: MockNode; operation: string): seq[MockNode] =
  root.all(OperationAttribute).filterIt(it.attr(OperationAttribute) == operation)

proc render(vm: ControlCenterVM): MockNode =
  renderAgentHarborControlCenter[MockRenderer, MockNode](MockRenderer(), vm)

proc press(vm: ControlCenterVM; el: MockNode): string =
  ## A press on `el` as the page's pointer listener routes it; the host runs
  ## it on the element's target. Returns the operation run ("" declined).
  let outcome = resolveElementPress(routerResolver(router, SessionFacts()), centerPath,
    ButtonElementKind, el.attr(OperationAttribute), {}, "Click")
  if vm.runControlCenterPress(outcome.operation, el.attr("data-ah-target")):
    outcome.operation
  else: ""

proc key(path: seq[ScopeElement]; name: string; base = bkCua): string =
  var r = initKeymapRouter(base, KeyDelivery(frontEnd: feTerminal,
    platform: hostPlatform(), keyProtocol: kpLegacy))
  let res = r.route(SessionFacts(), path, nmNormal, name, 0)
  if res.kind == erOperation: res.operation else: ""

proc withCenter(fixture: string; body: proc(vm: ControlCenterVM)) =
  createRoot proc(disposeRoot: proc()) =
    let vm = createControlCenterStoryVM(fixture)
    body(vm)
    vm.dispose()
    disposeRoot()

proc openCenter(fixture: string): (ControlCenterVM, MockNode, proc()) =
  ## The story's viewmodel and its web view, inside a reactive root kept
  ## open until the returned proc closes it, so a test checks them in its
  ## own body.
  var vm: ControlCenterVM
  var root: MockNode
  var disposeRoot: proc()
  createRoot proc(dispose: proc()) =
    disposeRoot = dispose
    vm = createControlCenterStoryVM(fixture)
    root = vm.render
  let center = vm
  (vm, root, proc() =
    center.dispose()
    disposeRoot())

suite "the control center's and the mark's operations are catalogued and bound":
  test "every operation is catalogued in its table":
    var center, global: seq[string]
    for entry in Catalogue:
      if entry.table == ControlCenterTable: center.add entry.name
      if entry.table == GlobalTable: global.add entry.name
    for op in ControlCenterOperations: check op in center
    for op in ControlCenterPressOperations: check op in center
    check GazeTogglePauseOperation in global

  test "Down, Up and Enter walk and open the waiting sessions":
    check key(centerPath, "Down") == ControlCenterNextOperation
    check key(centerPath, "Up") == ControlCenterPreviousOperation
    check key(centerPath, "Enter") == ControlCenterOpenOperation

  test "the pause key is Ctrl+Alt+Y under every base, and Ctrl+Alt+G is not it":
    for base in [bkCua, bkEmacs, bkVim, bkKakoune]:
      check key(windowPath, "Ctrl+Alt+y", base) == GazeTogglePauseOperation
      check key(windowPath, "Ctrl+Alt+g", base) != GazeTogglePauseOperation
    check gazePauseChord() == "Ctrl+Alt+Y"

suite "the web view carries the operations and holds no handler":
  test "the toggles, the waiting rows and the send button name their operation":
    withCenter("populated", proc(vm: ControlCenterVM) =
      let root = vm.render
      check root.ownHandlers == 0
      check root.attr("data-ct-pane") == ControlCenterScope
      check root.all("data-ct-pane").anyIt(it.attr("data-ct-pane") == "composer")
      check root.carrying(ControlCenterNewTaskOperation).len == 1
      check root.carrying(ControlCenterNewInitiativeOperation).len == 1
      let fors = root.carrying(ControlCenterLaunchForOperation)
      check fors.len == 5                          # no initiative, and four
      check fors[0].attr("data-ah-target") == ""
      let rows = root.carrying(ControlCenterOpenSessionOperation)
      check rows.mapIt(it.attr("data-ah-target")) ==
        vm.waiting.mapIt(it.item.id)
      check rows.len == 3
      check root.carrying(ComposerSendOperation).len == 1)

  test "it draws the Initiatives panel and the composer's own form":
    withCenter("populated", proc(vm: ControlCenterVM) =
      let root = vm.render
      var panels: seq[MockNode]
      proc find(n: MockNode) =
        if n.attributes.getOrDefault("class", "").contains("agent-harbor-initiatives"):
          panels.add n
        for ch in n.children: find(ch)
      find(root)
      check panels.len == 1
      check root.all("data-ah-field").anyIt(it.attr("data-ah-field") == "Repository"))
    # And the source composes them: the panel's and the composer's renderers,
    # not a copy of either. Read when the suite compiles: `readFile` has no
    # file system under `nim js` ("fopen is not defined" under node).
    const source = staticRead(currentSourcePath().parentDir / ".." / ".." / "views" /
                              "isonim_agent_harbor_control_center_view.nim")
    check "renderAgentHarborInitiativesPanel[R, N](r, vm.initiatives)" in source
    check "renderLaunchForm(r, c, form, locked)" in source
    check "renderInitiativeForm(r, c, form, locked)" in source

  test "a press does what its operation says":
    withCenter("populated", proc(vm: ControlCenterVM) =
      var root = vm.render
      check vm.press(root.carrying(ControlCenterNewInitiativeOperation)[0]) ==
        ControlCenterNewInitiativeOperation
      check vm.mode == lmInitiative
      root = vm.render
      let shield = root.carrying(ControlCenterLaunchForOperation).filterIt(
        it.attr("data-ah-target") == ShieldInitiative)
      check vm.press(shield[0]) == ControlCenterLaunchForOperation
      check vm.launchForTitle == "Shield model hardening"
      root = vm.render
      let row = root.carrying(ControlCenterOpenSessionOperation)[0]
      check vm.press(row) == ControlCenterOpenSessionOperation
      check vm.requestedSession.val == row.attr("data-ah-target")
      check not vm.runControlCenterPress(ControlCenterOpenSessionOperation, "")
      check not vm.runControlCenterPress("results.open", ""))

  test "a key does what its row says":
    withCenter("populated", proc(vm: ControlCenterVM) =
      check vm.runControlCenterOperation(key(centerPath, "Down"))
      check vm.focused.val == vm.waiting[0].item.id
      check vm.runControlCenterOperation(key(centerPath, "Enter"))
      check vm.requestedSession.val == vm.waiting[0].item.id
      check vm.render.all("data-ah-waiting-focused").filterIt(
        it.attr("data-ah-waiting-focused") == "true").len == 1)

  test "an empty fleet says so; the launched story shows the notice":
    withCenter("empty", proc(vm: ControlCenterVM) =
      let root = vm.render
      check root.attr("data-ah-cc-empty") == "true"
      check root.all("data-ah-waiting-session").len == 0)
    withCenter("launched", proc(vm: ControlCenterVM) =
      let root = vm.render
      check root.attr("data-ah-cc-notice").startsWith("Started on hub-a")
      check root.attr("data-ah-cc-launch-for") == "Shield model hardening"
      check root.all("class").filterIt(it.attr("class").startsWith("ah-cc-notice-line"))
        .mapIt(it.attr("class")) == @["ah-cc-notice-line ah-role-body"])

  test "launching: the form locked, Launch busy, Launching... in the body role":
    # The checks run in the test's own body, not in a closure, so a failed
    # one fails the test (Verification-Harness-Traps: `check` in a proc).
    let (vm, root, close) = openCenter("launching")
    check root.attr("data-ah-cc-launching") == "true"
    check root.all("data-ah-locked").mapIt(it.attr("data-ah-locked")) == @["true"]
    check root.all("data-ah-field").anyIt(it.attr("data-ah-field") == "Repository")
    check root.all("aria-readonly").filterIt(it.attr("aria-label") == "Instruction")
      .mapIt(it.attr("aria-readonly")) == @["true"]
    # Every toggle of the column is disabled: the mode, For and the form's.
    # The toggles themselves (`ah-composer-toggle`, ` active` when chosen),
    # not their rows (`ah-composer-toggles`).
    let toggles = root.all("class").filterIt(
      it.attr("class").split(' ')[0] == "ah-composer-toggle")
    check toggles.len > 0
    check toggles.allIt(it.attr("disabled") == "true")
    let send = root.carrying(ComposerSendOperation)
    check send.len == 1
    check send[0].attr("disabled") == "true"
    check send[0].attr("aria-busy") == "true"
    let notices = root.all("class").filterIt(it.attr("class").startsWith("ah-cc-notice-line"))
    check notices.mapIt(it.attr("class")) == @["ah-cc-notice-line ah-role-body"]
    check root.attr("data-ah-cc-notice") == "Launching\xE2\x80\xA6"
    # A routed press on For while it waits changes nothing.
    for t in root.carrying(ControlCenterLaunchForOperation): discard vm.press(t)
    check vm.launchForTitle == "Shield model hardening"
    close()

  test "launch failed: Could not launch in the error role, the instruction kept":
    let (vm, root, close) = openCenter("launch-failed")
    check root.attr("data-ah-cc-launching") == "false"
    check root.attr("data-ah-cc-notice") == "Could not launch: " & LaunchFailure
    let notices = root.all("class").filterIt(it.attr("class").startsWith("ah-cc-notice-line"))
    check notices.mapIt(it.attr("class")) == @["ah-cc-notice-line ah-role-error"]
    check vm.composer.text == EmptyShieldTask
    check root.carrying(ComposerSendOperation)[0].attr("disabled") == ""
    close()

suite "the gaze mark":
  test "off draws no mark; tracking names the key; a press pauses":
    createRoot proc(disposeRoot: proc()) =
      let off = createGazeStoryVM("off", gazePauseChord())
      let offRoot = renderAgentHarborGazeMark[MockRenderer, MockNode](MockRenderer(), off)
      check offRoot.carrying(GazeTogglePauseOperation).len == 0
      check offRoot.attr("data-ah-gaze") == "off"
      let vm = createGazeStoryVM("tracking", gazePauseChord())
      let root = renderAgentHarborGazeMark[MockRenderer, MockNode](MockRenderer(), vm)
      check root.handlers == 0
      let mark = root.carrying(GazeTogglePauseOperation)
      check mark.len == 1
      check mark[0].attr("title").endsWith("Ctrl+Alt+Y pauses it.")
      let outcome = resolveElementPress(routerResolver(router, SessionFacts()), windowPath,
        ButtonElementKind, mark[0].attr(OperationAttribute), {}, "Click")
      check vm.runGazeOperation(outcome.operation)
      check vm.state.val == gsPaused
      check root.carrying(GazeTogglePauseOperation)[0].attr("title")
        .endsWith("Ctrl+Alt+Y resumes it.")
      check vm.runGazeOperation(key(windowPath, "Ctrl+Alt+y"))
      check vm.state.val == gsTracking
      check not off.runGazeOperation(GazeTogglePauseOperation)
      off.dispose()
      vm.dispose()
      disposeRoot()
