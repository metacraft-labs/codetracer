## dom_process_switcher_presses.nim — a DOM story host's procedures for a
## multi-process recording's process switcher
## (`viewmodel/views/isonim_agent_harbor_process_switcher_view`): what
## StoryBook registers (`storybook_components.mountAgentHarborProcessSwitcher`).
##
## Input-Routing-And-Keymaps.md §4 and §5.1: a press on a process's button
## is resolved in the `processSwitcher` scope by the base keymap's pointer
## rows (a primary press runs the operation the button carries,
## `process-switcher.select`, with the process as the target) and run on the
## switcher on the page. The keys are the base keymap's rows: the next and
## previous process (`Ctrl+Alt+PageDown` / `Ctrl+Alt+PageUp`) at the
## window's scope wherever the focus is, and the digits in the
## `processSwitcher` scope while the focus is inside the switcher.
##
## SEAM(press): the press arrives through the recording switcher's
## `onSelect` (its buttons carry no `data-ct-operation`, P1d site 19), so this module
## hands the view a `ProcessPress` that routes it, rather than registering
## an element operation the page's listener would find.
##
## Refuses to own: what an operation does
## (`agent_harbor_process_switcher_words`) and which operation a press or a
## key runs (the router).

when not defined(js):
  {.error: "stories/dom_process_switcher_presses is a DOM front-end's (JS).".}

import std/jsffi

import ../viewmodel/views/isonim_agent_harbor_process_switcher_view
import ../viewmodel/input/element_press
import ../viewmodel/keymap/[base_keymaps, context_keys, keymap_router, scope_path,
                            editing_keymap]
import ../../common/key_event_names

var shownSwitcher: proc(): ProcessSwitcherVM
  ## The switcher on the page when a press or a key comes (nil: none).
var keysInstalled = false

proc webRouter(): KeymapRouter =
  initKeymapRouter(bkCua, KeyDelivery(frontEnd: feWeb, platform: hostPlatform(),
                                      keyProtocol: kpNative))

let SwitcherPath = @[element(ekWindow, "window"), pane(ProcessSwitcherScope)]
let WindowPath = @[element(ekWindow, "window")]

proc processSwitcherPress*(): ProcessPress =
  ## The route for a press on a process's button: resolved in the
  ## `processSwitcher` scope, and run on the switcher on the page.
  let resolve = routerResolver(webRouter(), SessionFacts())
  result = proc(operation, target: string) =
    let vm = if shownSwitcher.isNil: nil else: shownSwitcher()
    if vm.isNil: return
    let outcome = resolveElementPress(resolve, SwitcherPath, ButtonElementKind,
                                      operation, {}, "Click")
    discard vm.runProcessSwitcherPress(outcome.operation, target)

proc inSwitcher(target: JsObject): bool {.importjs: """
  (function (t) {
    return !!t && typeof t.closest === 'function' &&
      !!t.closest('[data-ct-pane="processSwitcher"]');
  })(#)""".}

proc onProcessSwitcherKey(ev: JsObject) =
  let vm = if shownSwitcher.isNil: nil else: shownSwitcher()
  if vm.isNil: return
  let name = canonicalKeyOfDom($ev.key.to(cstring), $ev.code.to(cstring),
                               ev.ctrlKey.to(bool), ev.shiftKey.to(bool),
                               ev.altKey.to(bool), ev.metaKey.to(bool))
  if name.len == 0: return
  var router = webRouter()
  let path = if inSwitcher(ev.target): SwitcherPath else: WindowPath
  let res = router.route(SessionFacts(), path, nmNormal, name, 0)
  if res.kind != erOperation or res.operation notin ProcessSwitcherOperations: return
  if vm.runProcessSwitcherOperation(res.operation, res.argument):
    discard ev.preventDefault()
    discard ev.stopPropagation()

proc routeProcessSwitcherPresses*(shown: proc(): ProcessSwitcherVM) =
  ## Remembers the switcher on the page and installs the key listener once
  ## per window.
  shownSwitcher = shown
  if not keysInstalled:
    keysInstalled = true
    {.emit: ["window.addEventListener('keydown', ", onProcessSwitcherKey, ", true);"].}
