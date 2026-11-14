## test_story_playback_presses.nim — Input-Routing-And-Keymaps.md §5.1 on the
## story hosts' playback chrome: a press on a playback button is the pointer
## keymap's to decide, and with no row of its own a primary press runs the
## operation the button carries.
##
## The bar is the web story host's (`isonim_agent_harbor_playback_view`, the
## very proc StoryBook mounts), rendered under `MockRenderer`. A press is
## resolved as the page's one pointer listener resolves it
## (`viewmodel/input/element_press.resolveElementPress`, which
## `input/dom_pointer` calls): in the `storyPlayback` scope the bar names,
## on a `button`, carrying the `data-ct-operation` the view drew, through the
## shipped router over the shipped base keymap and a user's
## `keybindings.json` rows. The operation is performed by the story host's
## procedure (`performPlaybackOperation`, what StoryBook registers).
##
## THE CONTROLS. A `click` fired at a button does nothing: the view holds no
## handler of its own (before the bar was routed, its `onclick` stepped the
## playback here). A user's row for the press takes it over, so the playback
## does not move: a view that handled the press itself would still move it.
## And that row loads without an error only because `storyPlayback` is a
## value `paneKind` may hold.
##
## Doubles: IsoNim's `TestClock` instead of the browser's real clock, so the
## playback moves only when a control moves it; `MockRenderer` for the
## browser's DOM, which the C lane cannot load. The playback, its scenario,
## the view, the router and the keymaps are the product's.

import std/[strutils, tables, unittest]

import isonim/core/owner
import isonim/testing/mock_dom

import ../../views/isonim_agent_harbor_playback_view
import ../../input/element_press
import ../../keymap/[context_keys, keymap_router, base_keymaps, scope_path,
                     editing_keymap,
                     user_keymap]
import ../../viewmodels/product_mode
import ../../../../common/key_names

const
  Web = KeyDelivery(frontEnd: feWeb, platform: pkLinux, keyProtocol: kpNative)
  Surface = "agent-harbor-fleet"
  Fixture = "playback-front-ends"

proc byClass(node: MockNode; cls: string; found: var seq[MockNode]) =
  if node.isNil: return
  if cls in node.attributes.getOrDefault("class", "").split(' '):
    found.add node
  for child in node.children:
    byClass(child, cls, found)

proc buttonOf(bar: MockNode; control: PlaybackControl): MockNode =
  var found: seq[MockNode]
  bar.byClass("ah-playback-" & $control, found)
  doAssert found.len == 1, "the bar draws no " & $control & " button"
  found[0]

proc press(router: KeymapRouter; button: MockNode; mods: KeyModifiers = {};
           gesture = "Click"): PressOutcome =
  ## What the page's pointer listener resolves a press on `button` to.
  resolveElementPress(routerResolver(router, SessionFacts(product: pmDebug)),
                      @[element(ekWindow, "window"), pane(StoryPlaybackScope)],
                      ButtonElementKind,
                      button.attributes.getOrDefault(OperationAttribute, ""),
                      mods, gesture)

template withBar(body: untyped) =
  createRoot proc(dispose: proc()) =
    let pb {.inject.} = newAhPlayback(Surface, Fixture, newTestClock())
    let bar {.inject.} = renderAgentHarborPlaybackBar[MockRenderer, MockNode](
      MockRenderer(), pb)
    body
    pb.dispose()
    dispose()

suite "a press on a story host's playback button is routed":

  test "the bar is a scope and each button carries its control's operation":
    withBar:
      check bar.attributes.getOrDefault("data-ct-pane", "") == StoryPlaybackScope
      for control in PlaybackControl:
        check bar.buttonOf(control).attributes.getOrDefault(OperationAttribute, "") ==
          operationOf(control)

  test "CONTROL: the view holds no handler, so a fired click moves nothing":
    withBar:
      check pb.source.position == 0
      fireEvent(bar.buttonOf(pcStep), "click")
      check pb.source.position == 0

  test "a primary press with no row runs the operation the button carries":
    withBar:
      let router = initKeymapRouter(bkCua, Web)
      let outcome = router.press(bar.buttonOf(pcStep))
      check outcome.operation == "story-playback.step"
      check not outcome.byRow
      check pb.performPlaybackOperation(outcome.operation)
      let afterStep = pb.source.position
      check afterStep > 0
      # A modified press with no row of its own is the plain press.
      let ctrl = router.press(bar.buttonOf(pcStep), {kmodCtrl})
      check ctrl.operation == "story-playback.step"
      check pb.performPlaybackOperation(ctrl.operation)
      check pb.source.position > afterStep
      # Rewind, through the same route, back to the first frame.
      check pb.performPlaybackOperation(router.press(bar.buttonOf(pcRewind)).operation)
      check pb.source.position == 0
      # Play, then Pause, by the one button.
      check pb.performPlaybackOperation(router.press(bar.buttonOf(pcPlay)).operation)
      check pb.playing
      check pb.performPlaybackOperation(router.press(bar.buttonOf(pcPlay)).operation)
      check not pb.playing

  test "a double click is not another press, and a context click is the menu's row":
    withBar:
      let router = initKeymapRouter(bkCua, Web)
      check router.press(bar.buttonOf(pcStep), gesture = "DoubleClick").operation == ""
      let context = router.press(bar.buttonOf(pcStep), gesture = "RightClick")
      check context.byRow
      check context.operation == "context-menu.open"
      # The story host performs only the playback's own operations.
      check not pb.performPlaybackOperation(context.operation)
      check pb.source.position == 0

  test "CONTROL: a user's row for the press takes it over":
    withBar:
      let router = initKeymapRouter(bkCua, Web, user = parseUserKeymap(
        """[ { "key": "click", "command": "debugger.continue",
               "when": "paneKind == storyPlayback && elementKind == button" } ]"""))
      # The row loads: `storyPlayback` is a value `paneKind` may hold.
      check router.errors.len == 0
      let outcome = router.press(bar.buttonOf(pcStep))
      check outcome.byRow
      check outcome.operation == "debugger.continue"
      check outcome.resolution.layer.startsWith("user:")
      # Not the playback's: the press is inert in the story host.
      check not pb.performPlaybackOperation(outcome.operation)
      check pb.source.position == 0

  test "each control's operation names it, and no other operation does":
    for control in PlaybackControl:
      check controlOfOperation(operationOf(control)) == (true, control)
    check not controlOfOperation("debugger.continue")[0]
    check not controlOfOperation("story-playback.")[0]
    check not performPlaybackOperation(nil, operationOf(pcStep))
