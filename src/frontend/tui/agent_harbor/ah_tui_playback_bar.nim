## tui/agent_harbor/ah_tui_playback_bar.nim — CTF-P1c. The terminal story
## host's playback chrome: the last row under a playback story of the Agent
## Harbor section (`stories/agent_harbor_playback.nim`), as the web and GPUI
## story hosts draw their bars under one (`isonim_agent_harbor_playback_view`,
## `gpui/agent_harbor/ah_playback_bar.nim`): play / pause, step, the previous
## and next named moment and rewind, then the moment and the time the
## playback is at.
##
## It is the story host's tooling, not a product view. A click on a button,
## or its key (`PlaybackKeys`: space, `n`, `[`, `]`, `0`), calls the
## playback's control (`applyControl`); the story host redraws the screen
## when the playback says its readout changed (`AhPlayback.changed`).
##
## On a narrow terminal (under `WideBarCols`, the shared
## `PlaybackCompactBelowPx` at 8px a cell) the buttons are drawn as one glyph
## each (`compactControlLabel`, the web's and GPUI's glyphs), one cell apart,
## so the readout keeps room for the moment: at the sidebar's 45 cells the
## glyphs with a cell of padding each left the longest moments 16 cells.
##
## Facts (`AhNode`): `playback` (the playback's state: playing, paused,
## ended) on the bar, `playback-control`, `button` (what it draws),
## `accessible-name` (its word), `tooltip` and `key` on each button, `playback-moment` and `playback-time` on the readout.

import ../../stories/agent_harbor_playback
import ./ah_tui_canvas

export agent_harbor_playback

const
  WideBarCols* = PlaybackCompactBelowPx div 8
    ## From this width (90 cells) the buttons carry their words.
  PlaybackKeys* = [(" ", pcPlay), ("n", pcStep), ("[", pcPrevious), ("]", pcNext),
                   ("0", pcRewind)]
    ## The terminal's key for each control.

proc controlOfKey*(token: string): (bool, PlaybackControl) =
  ## The control a key stands for.
  for (key, control) in PlaybackKeys:
    if token == key: return (true, control)
  (false, pcPlay)

proc drawPlaybackBar*(c: var AhCanvas; pb: AhPlayback; row: int) =
  ## The bar on `row`, the canvas's width.
  # On the window's own ground, as the frame header row is: the bar is part
  # of the window, not an area of its own beside it (the terminal tells
  # areas apart by their grounds, `ah_tui_canvas.nim`), and the story above
  # it keeps its ground.
  c.fill(row, 0, c.cols, 1, c.tone.frame)
  let bar = c.node(nil, row, 0, c.cols, 1, [("playback", pb.stateLabel)])
  let wide = c.cols >= WideBarCols
  var col = 1
  for control in PlaybackControl:
    let label = if wide: pb.controlLabel(control) else: pb.compactControlLabel(control)
    let shown = if wide: " " & label & " " else: label
    let w = widthOf(shown)
    if col + w > c.cols: break
    discard c.put(row, col, shown, c.p.textLabel, bg = c.tone.chip)
    # Its name and what it does, whichever it draws (`accessible-name`: its word;
    # `tooltip`: the control's tooltip, as the web's `title`), and its key.
    var key = ""
    for (k, ctl) in PlaybackKeys:
      if ctl == control: key = k
    discard c.node(bar, row, col + (if wide: 1 else: 0), widthOf(label), 1,
                   [("playback-control", $control), ("button", label),
                    ("accessible-name", pb.controlLabel(control)),
                    ("tooltip", controlTitle(control)),
                    ("key", key)])
    c.target(row, col, w, 1, pb.controlAction(control))
    col += w + 1
  col += 1
  if col < c.cols:
    let time = pb.elapsedLabel
    let timeW = widthOf(time)
    let momentRoom = c.cols - col - timeW - 2
    if momentRoom > 0:
      discard c.text(bar, row, col, momentRoom, pb.momentLabel, c.p.textBody,
                     fact = "playback-moment", before = c.cols - timeW - 1)
    discard c.text(bar, row, c.cols - timeW - 1, timeW, time, c.p.textCaption,
                   fact = "playback-time")
