## The web story host's playback chrome: the bar a playback story of the
## Agent Harbor section shows under it (`stories/agent_harbor_playback.nim`),
## with play / pause, step, the previous and next named moment, rewind, and
## a readout of the moment and the time the playback is at.
##
## It is the StoryBook host's chrome, not a product view: StoryBook mounts it
## under every playback story (`storybook_components.nim`), fixed along the
## bottom of the canvas (`.ah-playback`, `agent_harbor.styl`), and the story's
## frame is that much shorter (`.ct-storybook-playback`,
## `storybook/stories/lib/surfaces.js`), as the GPUI and terminal story hosts
## draw their bars under the story. The bar redraws when the playback says
## its readout changed (`AhPlayback.changed`).
##
## A press on a button is routed (Input-Routing-And-Keymaps.md §5.1): the bar
## is the `storyPlayback` scope (`data-ct-pane`), each button carries its
## control's operation (`data-ct-operation`, `story-playback.step`, …), and
## the page's one pointer listener (`viewmodel/input/dom_pointer`) resolves
## the press through the pointer keymap — a user's row for the press first —
## and runs the story host's procedure for the operation
## (`storybook_components` registers `performPlaybackOperation`). The bar
## holds no handler of its own.
##
## A renderer-generic IsoNim view, like the Agent Harbor views beside it, so
## the agreement test renders the same bar on IsoNim's `MockRenderer` and
## presses it as the page's listener does (`viewmodel/input/element_press`).

import isonim/core/[signals, computation]
import isonim/dsl/[ui, components]
# Its one-line texts (`data-ah-cut`) are cut in code, by the views' one rule
# for a cut (`ah_cut_text`, CTF-P1c D6).
import ./ah_cut_text

import ../../stories/agent_harbor_playback
from ../keymap/scope_path import StoryPlaybackScope
from ../input/element_press import OperationAttribute

export signals, computation, components, agent_harbor_playback

static:
  # The DSL spells the attribute literally; it is the one the listener reads.
  doAssert OperationAttribute == "data-ct-operation"

const
  AgentHarborPlaybackClass* = "ah-playback"
  PlaybackButtonClass* = "ah-playback-button"

proc appendRendered[R, N](r: R; host, child: N) =
  mixin appendChild
  r.appendChild(host, child)

proc renderPlaybackButton[R](r: R; pb: AhPlayback; control: PlaybackControl): auto =
  ## One control: a button carrying its control's operation, which a press
  ## on it runs through the router (see the header). It holds both its word
  ## and its glyph (`compactControlLabel`); the stylesheet shows the glyph
  ## alone on a bar under `PlaybackCompactBelowPx` (`.ah-playback`'s media
  ## query), and the word stays the button's accessible name. A press on
  ## either reaches the button, whose operation the listener reads.
  mixin setAttribute
  var b: typeof(r.createElement("button"))
  result = ui(r):
    button(ref = b, class = PlaybackButtonClass & " ah-playback-" & $control,
           title = controlTitle(control),
           `data-ct-operation` = operationOf(control)):
      span(class = "ah-playback-word"):
        text pb.controlLabel(control)
      span(class = "ah-playback-glyph"):
        text pb.compactControlLabel(control)
  r.setAttribute(b, "aria-label", pb.controlLabel(control))

proc renderAgentHarborPlaybackBar*[R, N](r: R; pb: AhPlayback): N =
  ## The bar; redrawn whenever `pb.changed` moves.
  mixin clearChildren, setAttribute
  var bar: N
  let host = ui(r):
    tdiv(ref = bar, class = AgentHarborPlaybackClass, role = "toolbar",
         title = "Playback: " & pb.source.scenario.title,
         `data-ct-pane` = StoryPlaybackScope)
  createRenderEffect proc() =
    discard pb.changed.val
    r.clearChildren(bar)
    r.setAttribute(bar, "class", AgentHarborPlaybackClass & " ah-playback-" & pb.stateLabel)
    for control in PlaybackControl:
      r.appendRendered(bar, renderPlaybackButton(r, pb, control))
    # The moment shrinks first and is cut with an ellipsis, so the box the
    # layout check measures (`playback-moment`) is the part drawn.
    let readout = ui(r):
      span(class = "ah-playback-readout"):
        span(`data-ah-cut` = "line", class = "ah-playback-moment"):
          text pb.momentLabel
        span(class = "ah-playback-time"):
          text pb.elapsedLabel
    r.appendRendered(bar, readout)
  host
