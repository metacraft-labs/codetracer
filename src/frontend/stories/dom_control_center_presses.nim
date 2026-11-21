## dom_control_center_presses.nim — a DOM story host's procedures for the
## control center's presses and keys
## (`viewmodel/views/isonim_agent_harbor_control_center_view`): what
## StoryBook registers (`storybook_components.mountAgentHarborControlCenter`).
##
## Input-Routing-And-Keymaps.md §4 and §5.1, as the composer's
## (`dom_composer_presses`): the control center's elements carry their
## operations (`control-center.new-task`, `-new-initiative`, `-launch-for`,
## `-open-session`, `agent_harbor_control_center_words`) and hold no
## handler. The page's one pointer listener resolves a press on one through
## the pointer keymap and, with no row of the user's, runs the procedure
## registered here on the element's target (`data-ah-target`). A key while
## the focus is in the control center, outside its launch form (the
## composer's scope, whose keys are the composer's), is resolved in the
## `controlCenter` scope by the base keymap (`Down` / `Up` / `Enter`) and
## run on the control center on the page.
##
## Refuses to own: what an operation does
## (`agent_harbor_control_center_words`) and which operation a press runs
## (the router).

when not defined(js):
  {.error: "stories/dom_control_center_presses is a DOM front-end's (JS).".}

import std/jsffi

import ../viewmodel/views/agent_harbor_control_center_words
import ../viewmodel/input/[dom_pointer, dom_pane_presses]
import ../viewmodel/keymap/[base_keymaps, context_keys, keymap_router, scope_path,
                            editing_keymap]
import ../../common/key_event_names

var shownCenter: proc(): ControlCenterVM
  ## The control center on the page when a press or a key comes (nil: none).
var keysInstalled = false

proc registerControlCenterPresses*(shown: proc(): ControlCenterVM) =
  ## Register a procedure for every operation a press on the control center
  ## carries, acting on the control center `shown` answers when the press
  ## comes (nil: none is on the page, and the press is inert). The last
  ## registration wins.
  shownCenter = shown
  for each in ControlCenterPressOperations:
    closureScope:
      let operation = each
      registerElementOperation(operation, proc(p: ElementPress): bool =
        let vm = if shownCenter.isNil: nil else: shownCenter()
        if vm.isNil: return false
        vm.runControlCenterPress(operation,
                                 attributeOf(p.element, ComposerTargetAttribute)))

proc inCenterOutsideForm(target: JsObject): bool {.importjs: """
  (function (t) {
    return !!t && typeof t.closest === 'function' &&
      !!t.closest('[data-ct-pane="controlCenter"]') && !t.closest('[data-ct-pane="composer"]');
  })(#)""".}

proc onControlCenterKey(ev: JsObject) =
  let vm = if shownCenter.isNil: nil else: shownCenter()
  if vm.isNil or not inCenterOutsideForm(ev.target): return
  let name = canonicalKeyOfDom($ev.key.to(cstring), $ev.code.to(cstring),
                               ev.ctrlKey.to(bool), ev.shiftKey.to(bool),
                               ev.altKey.to(bool), ev.metaKey.to(bool))
  if name.len == 0: return
  var router = initKeymapRouter(bkCua, KeyDelivery(frontEnd: feWeb,
    platform: hostPlatform(), keyProtocol: kpNative))
  let res = router.route(SessionFacts(),
                         @[element(ekWindow, "window"), pane(ControlCenterScope)],
                         nmNormal, name, 0)
  if res.kind != erOperation or res.operation notin ControlCenterOperations: return
  if vm.runControlCenterOperation(res.operation):
    discard ev.preventDefault()
    discard ev.stopPropagation()

proc routeControlCenterPresses*(shown: proc(): ControlCenterVM) =
  ## `registerControlCenterPresses`, the base keymap's pointer rows for a
  ## page with no keymap of its own, and the control center's key listener,
  ## installed once per window.
  registerControlCenterPresses(shown)
  installBaseElementRouting()
  if not keysInstalled:
    keysInstalled = true
    {.emit: ["window.addEventListener('keydown', ", onControlCenterKey, ", true);"].}
