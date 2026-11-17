## story_playback_bar_dom_test.nim
##
## The web story host's playback bar (`isonim_agent_harbor_playback_view`,
## mounted as StoryBook mounts it) in a real DOM, held to
## Input-Routing-And-Keymaps.md §5.1: its buttons hold no handler; a press on
## one goes through the page's one pointer listener
## (`viewmodel/input/dom_pointer`) and the router, and runs the operation the
## button carries, performed by StoryBook's procedure
## (`stories/dom_playback_presses.routePlaybackPresses`, what
## `storybook_components.mountPlaybackChrome` calls).
##
## The presses are real `MouseEvent`s dispatched on the buttons, as
## StoryBook's play check presses them (`element.click()`). The router is the
## shipped one over the shipped CUA base keymap; a user's row is parsed by the
## shipped parser.
##
## THE CONTROLS. Before the page routes its presses, a click on Step moves
## nothing: the bar's buttons hold no handler (before they were routed, their
## `onclick` stepped the playback here). And a user's row for a press on a
## playback button takes it over, so Step moves nothing: a button that ran
## its control itself would still step.
##
## Doubles: IsoNim's `TestClock` instead of the page's real clock, so the
## playback moves only when a control moves it. The playback, its scenario,
## the view, the listener, the router and the keymaps are the product's.
##
## Lane: `renderer-dom` (`nim js -d:ctRenderer`, run by `jsdom-run.mjs`).
## Without `-d:nodejs` `std/unittest` cannot set the exit status, so this
## suite sets it.

import std/[jsffi, unittest]

import isonim/core/owner
import isonim/web/[web_renderer, dom_api]

import ../stories/[agent_harbor_playback, dom_playback_presses]
import ../viewmodel/views/isonim_agent_harbor_playback_view
import ../viewmodel/input/[dom_pointer, element_press]
import ../viewmodel/keymap/[base_keymaps, context_keys, editing_keymap,
                            keymap_router, user_keymap]
import ../viewmodel/viewmodels/product_mode
from ../../common/key_names import kpNative

const Web = KeyDelivery(frontEnd: feWeb, platform: pkLinux, keyProtocol: kpNative)

proc documentBody(): Node {.importjs: "(document.body)@".}
proc query(selector: cstring): JsObject {.importjs: "document.querySelector(#)".}
proc click(el: JsObject; ctrl = false) {.importjs: """
  #.dispatchEvent(new window.MouseEvent('click', { bubbles: true,
    cancelable: true, button: 0, ctrlKey: # }))""".}

var failed = 0
template ck(cond: untyped) =
  ## Evaluates `cond` once: a press is an action, not only a value.
  let ok = cond
  if not ok:
    inc failed
  check ok

proc button(control: PlaybackControl): JsObject =
  query(cstring(".ah-playback .ah-playback-" & $control))

proc routeWith(router: KeymapRouter) =
  installDomPointerRouting(routerResolver(router, SessionFacts(product: pmDebug)))

suite "the web story host's playback bar is routed":
  test "a press on a playback button runs its operation through the router":
    createRoot proc(disposeRoot: proc()) =
      let pb = newAhPlayback("agent-harbor-fleet", "playback-front-ends",
                             newTestClock())
      let bar = renderAgentHarborPlaybackBar[WebRenderer, Element](WebRenderer(), pb)
      discard appendChild(documentBody(), Node(bar))
      ck $button(pcStep).getAttribute(cstring(OperationAttribute)).to(cstring) ==
        operationOf(pcStep)
      # CONTROL: with nothing routing the page's presses, Step moves nothing.
      button(pcStep).click()
      ck pb.source.position == 0
      # StoryBook's wiring: the base keymap's rows, its procedures.
      routePlaybackPresses(proc(): AhPlayback = pb)
      button(pcStep).click()
      let afterStep = pb.source.position
      ck afterStep > 0
      # A modified press with no row of its own is the plain press.
      button(pcStep).click(ctrl = true)
      ck pb.source.position > afterStep
      button(pcRewind).click()
      ck pb.source.position == 0
      # CONTROL: a user's row for the press takes it over.
      let rebound = initKeymapRouter(bkCua, Web, user = parseUserKeymap(
        """[ { "key": "click", "command": "debugger.continue",
               "when": "paneKind == storyPlayback && elementKind == button" } ]"""))
      ck rebound.errors.len == 0
      routeWith(rebound)
      button(pcStep).click()
      ck pb.source.position == 0
      # The base again: Step steps.
      routeWith(initKeymapRouter(bkCua, Web))
      button(pcStep).click()
      ck pb.source.position > 0
      pb.dispose()
      disposeRoot()

if failed > 0:
  {.emit: "process.exitCode = 1;".}
