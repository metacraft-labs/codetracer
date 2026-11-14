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
## draw their bars under the story. Each button calls the playback's control
## (`agent_harbor_playback.controlAction`); the bar redraws when the playback
## says its readout changed (`AhPlayback.changed`).
##
## A renderer-generic IsoNim view, like the Agent Harbor views beside it, so
## the agreement test drives the same bar with the same clicks on IsoNim's
## `MockRenderer`.

import isonim/core/[signals, computation]
import isonim/dsl/[ui, components]

import ../../stories/agent_harbor_playback

export signals, computation, components, agent_harbor_playback

const
  AgentHarborPlaybackClass* = "ah-playback"
  PlaybackButtonClass* = "ah-playback-button"

proc appendRendered[R, N](r: R; host, child: N) =
  mixin appendChild
  r.appendChild(host, child)

proc renderPlaybackButton[R](r: R; pb: AhPlayback; control: PlaybackControl): auto =
  ## One control, a proc of its own so each closure owns its control.
  ui(r):
    button(class = PlaybackButtonClass & " ah-playback-" & $control,
           title = controlTitle(control),
           onclick = pb.controlAction(control)):
      text pb.controlLabel(control)

proc renderAgentHarborPlaybackBar*[R, N](r: R; pb: AhPlayback): N =
  ## The bar; redrawn whenever `pb.changed` moves.
  mixin clearChildren, setAttribute
  var bar: N
  let host = ui(r):
    tdiv(ref = bar, class = AgentHarborPlaybackClass, role = "toolbar",
         title = "Playback: " & pb.source.scenario.title)
  createRenderEffect proc() =
    discard pb.changed.val
    r.clearChildren(bar)
    r.setAttribute(bar, "class", AgentHarborPlaybackClass & " ah-playback-" & pb.stateLabel)
    for control in PlaybackControl:
      r.appendRendered(bar, renderPlaybackButton(r, pb, control))
    let readout = ui(r):
      span(class = "ah-playback-readout"):
        span(class = "ah-playback-moment"):
          text pb.momentLabel
        span(class = "ah-playback-time"):
          text pb.elapsedLabel
    r.appendRendered(bar, readout)
  host
