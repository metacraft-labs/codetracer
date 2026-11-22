## dom_gaze_presses.nim — a DOM story host's procedures for the gaze mark's
## press and the pause key (`viewmodel/views/isonim_agent_harbor_gaze_mark_view`):
## what StoryBook registers (`storybook_components.mountAgentHarborStatusGaze`).
##
## Input-Routing-And-Keymaps.md §4 and §5.1: the mark carries
## `gaze.toggle-pause` and holds no handler; the page's one pointer listener
## resolves a press on it and runs the procedure registered here. The pause
## key is a window-level row (`overlay_rows`: `Ctrl+Alt+Y` in the global
## table), resolved at the window's scope by the base keymap wherever the
## focus is, and run on the mark on the page.
##
## Refuses to own: what the operation does (`agent_harbor_gaze_words`) and
## which operation a press or a key runs (the router).

when not defined(js):
  {.error: "stories/dom_gaze_presses is a DOM front-end's (JS).".}

import std/jsffi

import ../viewmodel/views/agent_harbor_gaze_words
import ../viewmodel/input/[dom_pointer, dom_pane_presses]
import ../viewmodel/keymap/[base_keymaps, context_keys, keymap_router, scope_path,
                            editing_keymap]
import ../../common/key_event_names

var shownMark: proc(): GazeStatusVM
  ## The mark on the page when a press or a key comes (nil: none).
var keysInstalled = false

proc registerGazePresses*(shown: proc(): GazeStatusVM) =
  ## Register the procedure a press on the mark runs, on the mark `shown`
  ## answers when the press comes (nil: none, and the press is inert).
  shownMark = shown
  registerElementOperation(GazeTogglePauseOperation, proc(p: ElementPress): bool =
    let vm = if shownMark.isNil: nil else: shownMark()
    if vm.isNil: return false
    vm.runGazeOperation(GazeTogglePauseOperation))

proc onGazeKey(ev: JsObject) =
  let vm = if shownMark.isNil: nil else: shownMark()
  if vm.isNil: return
  let name = canonicalKeyOfDom($ev.key.to(cstring), $ev.code.to(cstring),
                               ev.ctrlKey.to(bool), ev.shiftKey.to(bool),
                               ev.altKey.to(bool), ev.metaKey.to(bool))
  if name.len == 0: return
  var router = initKeymapRouter(bkCua, KeyDelivery(frontEnd: feWeb,
    platform: hostPlatform(), keyProtocol: kpNative))
  let res = router.route(SessionFacts(), @[element(ekWindow, "window")], nmNormal, name, 0)
  if res.kind != erOperation or res.operation notin GazeOperations: return
  if vm.runGazeOperation(res.operation):
    discard ev.preventDefault()
    discard ev.stopPropagation()

proc routeGazePresses*(shown: proc(): GazeStatusVM) =
  ## `registerGazePresses`, the base keymap's pointer rows, and the pause
  ## key's listener, installed once per window.
  registerGazePresses(shown)
  installBaseElementRouting()
  if not keysInstalled:
    keysInstalled = true
    {.emit: ["window.addEventListener('keydown', ", onGazeKey, ", true);"].}
