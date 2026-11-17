## dom_playback_presses.nim — a DOM story host's procedures for a press on its
## playback bar (`viewmodel/views/isonim_agent_harbor_playback_view`): what
## StoryBook registers (`storybook_components.mountPlaybackChrome`).
##
## Input-Routing-And-Keymaps.md §5.1: the bar's buttons carry their controls'
## operations (`story-playback.step`, …) and hold no handler. The page's one
## pointer listener (`viewmodel/input/dom_pointer`) resolves a press on one
## through the pointer keymap — a user's row first — and, with no row, runs
## the procedure registered here for the operation the button carries.
##
## Refuses to own: what a control does (`agent_harbor_playback.applyControl`)
## and which operation a press runs (the router).

when not defined(js):
  {.error: "stories/dom_playback_presses is a DOM front-end's (JS).".}

import ./agent_harbor_playback
import ../viewmodel/input/[dom_pointer, dom_pane_presses]

proc registerPlaybackPresses*(shown: proc(): AhPlayback) =
  ## Register a procedure for every control's operation, acting on the
  ## playback `shown` answers when the press comes (nil: none is on the
  ## page, and the press is inert). The last registration wins, so a host
  ## that mounts story after story may register on every mount.
  for control in PlaybackControl:
    closureScope:
      let operation = operationOf(control)
      registerElementOperation(operation, proc(p: ElementPress): bool =
        performPlaybackOperation(shown(), operation))

proc routePlaybackPresses*(shown: proc(): AhPlayback) =
  ## `registerPlaybackPresses`, and the base keymap's pointer rows for a page
  ## with no keymap of its own (`installBaseElementRouting`; a page whose
  ## presses are routed already keeps its router).
  registerPlaybackPresses(shown)
  installBaseElementRouting()
