## dom_composer_presses.nim — a DOM story host's procedures for the omnibox
## composer's presses and keys (`viewmodel/views/isonim_agent_harbor_composer_view`):
## what StoryBook registers (`storybook_components.mountAgentHarborComposerStory`).
##
## Input-Routing-And-Keymaps.md §4 and §5.1: the composer's elements carry
## their operations (`composer.cite`, `composer.send`, …,
## `agent_harbor_composer_words`) and hold no handler. The page's one pointer
## listener (`viewmodel/input/dom_pointer`) resolves a press on one through
## the pointer keymap — a user's row first — and, with no row, runs the
## procedure registered here for the operation the element carries, on the
## element's target (`data-ah-target`). A key pressed while the focus is in
## the composer (`data-ct-pane="composer"`) is named by the desktop's one
## decoder (`key_event_names.canonicalKeyOfDom`) and resolved by the base
## keymap's router in the composer's scope; the operation it resolves to runs
## on the composer on the page (`runComposerOperation`).
##
## Refuses to own: what an operation does (`agent_harbor_composer_words`)
## and which operation a press or a key runs (the router).

when not defined(js):
  {.error: "stories/dom_composer_presses is a DOM front-end's (JS).".}

import std/jsffi

import nim_agents_isonim_viewmodels/agent_harbor/omnibox_composer_vm
import ../viewmodel/views/agent_harbor_composer_words
import ../viewmodel/input/[dom_pointer, dom_pane_presses]
import ../viewmodel/keymap/[base_keymaps, context_keys, keymap_router, scope_path,
                            editing_keymap]
import ../../common/key_event_names

var shownComposer: proc(): OmniboxComposerVM
  ## The composer on the page when a press or a key comes (nil: none).
var keysInstalled = false

proc registerComposerPresses*(shown: proc(): OmniboxComposerVM) =
  ## Register a procedure for every operation a press on the composer
  ## carries, acting on the composer `shown` answers when the press comes
  ## (nil: none is on the page, and the press is inert). The last
  ## registration wins, so a host that mounts story after story may
  ## register on every mount.
  shownComposer = shown
  for each in ComposerPressOperations:
    closureScope:
      let operation = each
      registerElementOperation(operation, proc(p: ElementPress): bool =
        let vm = if shownComposer.isNil: nil else: shownComposer()
        if vm.isNil: return false
        vm.runComposerPress(operation, attributeOf(p.element, ComposerTargetAttribute)))

proc inComposer(target: JsObject): bool {.importjs:
  "(function (t) { return !!t && typeof t.closest === 'function' && !!t.closest('[data-ct-pane=\"composer\"]'); })(#)".}

proc onComposerKey(ev: JsObject) =
  ## A key while the focus is in the composer: resolved in its scope by the
  ## base keymap; a composer operation runs and the event stops there.
  let vm = if shownComposer.isNil: nil else: shownComposer()
  if vm.isNil or not inComposer(ev.target): return
  let name = canonicalKeyOfDom($ev.key.to(cstring), $ev.code.to(cstring),
                               ev.ctrlKey.to(bool), ev.shiftKey.to(bool),
                               ev.altKey.to(bool), ev.metaKey.to(bool))
  if name.len == 0: return
  var router = initKeymapRouter(bkCua, KeyDelivery(frontEnd: feWeb,
    platform: hostPlatform(), keyProtocol: kpNative))
  let res = router.route(SessionFacts(), @[element(ekWindow, "window"), pane(ComposerScope)],
                         nmNormal, name, 0)
  if res.kind != erOperation or res.operation notin ComposerOperations: return
  if vm.runComposerOperation(res.operation):
    discard ev.preventDefault()
    discard ev.stopPropagation()

proc routeComposerPresses*(shown: proc(): OmniboxComposerVM) =
  ## `registerComposerPresses`, the base keymap's pointer rows for a page
  ## with no keymap of its own (`installBaseElementRouting`), and the
  ## composer's key listener, installed once per window.
  registerComposerPresses(shown)
  installBaseElementRouting()
  if not keysInstalled:
    keysInstalled = true
    {.emit: ["window.addEventListener('keydown', ", onComposerKey, ", true);"].}
