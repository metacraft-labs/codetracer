## dom_results_presses.nim — a DOM story host's procedures for the omnibox's
## result commands' presses and keys
## (`viewmodel/views/isonim_agent_harbor_results_view`): what StoryBook
## registers (`storybook_components.mountAgentHarborResultsStory`).
##
## Input-Routing-And-Keymaps.md §4 and §5.1, as the composer's
## (`dom_composer_presses`): the results' elements carry their operations
## (`results.open`, `results.more`, `results.all`,
## `agent_harbor_results_words`) and hold no handler. The page's one pointer
## listener resolves a press on one through the pointer keymap and, with no
## row of the user's, runs the procedure registered here for the operation
## the element carries, on the element's target (`data-ah-target`). A key
## pressed while the focus is in the results (`data-ct-pane="results"`) is
## named by the desktop's one decoder and resolved by the base keymap's
## router in the results' scope; the operation it resolves to runs on the
## results on the page (`runResultsOperation`).
##
## Refuses to own: what an operation does (`agent_harbor_results_words`) and
## which operation a press or a key runs (the router).

when not defined(js):
  {.error: "stories/dom_results_presses is a DOM front-end's (JS).".}

import std/jsffi

import nim_agents_isonim_viewmodels/agent_harbor/result_commands_vm
import ../viewmodel/views/agent_harbor_results_words
import ../viewmodel/input/[dom_pointer, dom_pane_presses]
import ../viewmodel/keymap/[base_keymaps, context_keys, keymap_router, scope_path,
                            editing_keymap]
import ../../common/key_event_names

var shownResults: proc(): ResultCommandsVM
  ## The results on the page when a press or a key comes (nil: none).
var keysInstalled = false

proc registerResultsPresses*(shown: proc(): ResultCommandsVM) =
  ## Register a procedure for every operation a press on the results
  ## carries, acting on the results `shown` answers when the press comes
  ## (nil: none is on the page, and the press is inert). The last
  ## registration wins.
  shownResults = shown
  for each in ResultsPressOperations:
    closureScope:
      let operation = each
      registerElementOperation(operation, proc(p: ElementPress): bool =
        let vm = if shownResults.isNil: nil else: shownResults()
        if vm.isNil: return false
        vm.runResultsPress(operation, attributeOf(p.element, ResultsTargetAttribute)))

proc inResults(target: JsObject): bool {.importjs:
  "(function (t) { return !!t && typeof t.closest === 'function' && !!t.closest('[data-ct-pane=\"results\"]'); })(#)".}

proc onResultsKey(ev: JsObject) =
  ## A key while the focus is in the results: resolved in their scope by
  ## the base keymap; a results operation runs and the event stops there.
  let vm = if shownResults.isNil: nil else: shownResults()
  if vm.isNil or not inResults(ev.target): return
  let name = canonicalKeyOfDom($ev.key.to(cstring), $ev.code.to(cstring),
                               ev.ctrlKey.to(bool), ev.shiftKey.to(bool),
                               ev.altKey.to(bool), ev.metaKey.to(bool))
  if name.len == 0: return
  var router = initKeymapRouter(bkCua, KeyDelivery(frontEnd: feWeb,
    platform: hostPlatform(), keyProtocol: kpNative))
  let res = router.route(SessionFacts(), @[element(ekWindow, "window"), pane(ResultsScope)],
                         nmNormal, name, 0)
  if res.kind != erOperation or res.operation notin ResultsOperations: return
  if vm.runResultsOperation(res.operation):
    discard ev.preventDefault()
    discard ev.stopPropagation()

proc routeResultsPresses*(shown: proc(): ResultCommandsVM) =
  ## `registerResultsPresses`, the base keymap's pointer rows for a page
  ## with no keymap of its own, and the results' key listener, installed
  ## once per window.
  registerResultsPresses(shown)
  installBaseElementRouting()
  if not keysInstalled:
    keysInstalled = true
    {.emit: ["window.addEventListener('keydown', ", onResultsKey, ", true);"].}
