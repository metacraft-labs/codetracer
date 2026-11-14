## gpui/agent_harbor/ah_playback_bar.nim — CTF-P1c. The GPUI story host's
## playback chrome: the bar under a playback story of the Agent Harbor
## section (`stories/agent_harbor_playback.nim`), as the web story host draws
## it (`viewmodel/views/isonim_agent_harbor_playback_view.nim`,
## `.ah-playback` in `agent_harbor.styl`): play / pause, step, the previous
## and next named moment and rewind, then the moment and the time the
## playback is at. 28px high (the web's 1.75rem), along the window's bottom;
## the story above it is that much shorter.
##
## It is the story host's tooling, not a product view. The bar redraws when
## the playback says its readout changed (`AhPlayback.changed`).
##
## A press on a button is ROUTED (Input-Routing-And-Keymaps.md §5.1): each
## button carries its control's operation (`data-ct-operation`,
## `story-playback.step`, …), and its one pointer listener is the hit test
## (§5.3 — GPUI's shim delivers a press to the element under the pointer, as
## `gpui/window_clicks.nim`'s rows are pressed): it names the button's
## operation and the modifiers held, and hands them to the story host's
## `PlaybackPress`, which resolves the press through its router — a user's
## row for the press first, else the operation the button carries
## (`viewmodel/input/element_press`) — and performs it. Nothing here decides
## what a press does.
##
## Facts (`data-ah-*`) for a reader of the render plan: `playback` (the
## playback's state: playing, paused, ended) on the bar, `playback-control`
## and `button` (its word) on each button, `playback-moment` and
## `playback-time` on the readout.

import isonim/core/computation

import ../../stories/agent_harbor_playback
import ../../viewmodel/input/element_press
import ../app/gpui_keys
import ../../../common/key_names
import ./ah_theme

export agent_harbor_playback

type
  PlaybackPress* = proc(operation: string; mods: KeyModifiers)
    ## The story host's route for a press on a bar's button: `operation` is
    ## the one the button carries, `mods` the modifiers held.

const
  PlaybackBarPx* = 28
    ## The bar's height: `.ah-playback`'s 1.75rem.

proc modifiersOf(ev: GpuiEvent): KeyModifiers =
  ## The modifiers a press was made with, as the keymap spells them.
  var names: seq[string] = @[]
  if gmControl in ev.modifiers: names.add "control"
  if gmShift in ev.modifiers: names.add "shift"
  if gmAlt in ev.modifiers: names.add "alt"
  if gmPlatform in ev.modifiers: names.add "platform"
  keyModifiersOfGpui(names)

proc listenForPress(r: GpuiRenderer; button: GpuiElement; operation: string;
                    press: PlaybackPress) =
  ## The button's hit test: a primary press on it is handed to `press` with
  ## the operation the button carries. A proc of its own so each closure owns
  ## its operation.
  r.addEventListener(button, "mousedown", proc(ev: GpuiEvent) =
    press(operation, modifiersOf(ev)))

proc drawPlaybackBar*(r: GpuiRenderer; host: GpuiElement; pb: AhPlayback;
                      p: AhPalette; widthPx: int; press: PlaybackPress) =
  ## The bar as the playback is now, into `host` (cleared first); a press on
  ## a button goes to `press`.
  r.clearChildren(host)
  let bar = r.box(pairs = [("width", $widthPx & "px"), ("height", $PlaybackBarPx & "px"),
                           ("flex-shrink", "0"), ("items", "center"), ("gap", "4px"),
                           ("padding-left", "8px"), ("padding-right", "8px"),
                           ("overflow", "hidden"), ("background", p.ground),
                           ("border-top-width", "1px"), ("border-color", p.borderPrimary)])
  r.tag(bar, "playback", pb.stateLabel)
  for control in PlaybackControl:
    let b = r.box(pairs = [("height", "20px"), ("items", "center"), ("justify", "center"),
                           ("padding-left", "8px"), ("padding-right", "8px"),
                           ("flex-shrink", "0"), ("rounded", $ControlRadiusPx & "px"),
                           ("border-width", "1px"), ("border-color", p.borderPrimary),
                           ("background", p.secondary),
                           ("cursor", "pointer")])
    let label = pb.controlLabel(control)
    r.appendChild(b, r.text(label, CaptionPx, p.textLabel, shrink = false))
    r.tag(b, "playback-control", $control)
    r.tag(b, "button", label)
    r.setAttribute(b, OperationAttribute, operationOf(control))
    if press != nil:
      r.listenForPress(b, operationOf(control), press)
    r.appendChild(bar, b)
  let readout = r.box(pairs = [("flex-grow", "1"), ("min-width", "0px"), ("gap", "8px"),
                               ("padding-left", "8px"), ("overflow", "hidden"),
                               ("items", "center")])
  let moment = r.text(pb.momentLabel, CaptionPx, p.textBody)
  r.tag(moment, "playback-moment", pb.momentLabel)
  r.appendChild(readout, moment)
  let time = r.text(pb.elapsedLabel, CaptionPx, p.textCaption, shrink = false,
                    tabular = true)
  r.tag(time, "playback-time", pb.elapsedLabel)
  r.appendChild(readout, time)
  r.appendChild(bar, readout)
  r.appendChild(host, bar)

proc mountPlaybackBar*(r: GpuiRenderer; host: GpuiElement; pb: AhPlayback;
                       p: AhPalette; widthPx: int; press: PlaybackPress) =
  ## Draws the bar and redraws it whenever the playback's readout changes.
  createRenderEffect proc() =
    discard pb.changed.val
    drawPlaybackBar(r, host, pb, p, widthPx, press)
