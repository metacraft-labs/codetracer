## tui/agent_harbor/ah_tui_playback_bar.nim — CTF-P1c. The terminal story
## host's playback chrome: the last row under a playback story of the Agent
## Harbor section (`stories/agent_harbor_playback.nim`), as the web and GPUI
## story hosts draw their bars under one (`isonim_agent_harbor_playback_view`,
## `gpui/agent_harbor/ah_playback_bar.nim`): play / pause, step, the previous
## and next named moment and rewind, then the moment and the time the
## playback is at.
##
## It is the story host's tooling, not a product view. The story host redraws
## the screen when the playback says its readout changed
## (`AhPlayback.changed`).
##
## Input is ROUTED (Input-Routing-And-Keymaps.md §4, §5.1): a button's target
## is the hit test — it hands the operation the button carries
## (`story-playback.step`, …) to the story host's `PlaybackPress`, which
## resolves the press through its router — and the keys for the controls
## (space, `n`, `[`, `]`, `0`) are keymap rows (`overlay_rows`, the
## `pane:storyPlayback` table), resolved by the story host's router too.
##
## On a narrow terminal (under `WideBarCols`, the shared
## `PlaybackCompactBelowPx` at 8px a cell) the buttons are drawn as one glyph
## each (`compactControlLabel`, the web's and GPUI's glyphs), one cell apart,
## so the readout keeps room for the moment: at the sidebar's 45 cells the
## glyphs with a cell of padding each left the longest moments 16 cells.
##
## The readout is one group, as on the web and in GPUI: the moment, then
## its time two cells after it, not the time pinned to the bar's far end.
## The bar sits on its own ground (`AhTone.playbackBar`), a step off the
## window's and the panels', where the web and GPUI draw a hairline above
## it: the terminal tells areas apart by their grounds, not by rules.
##
## Facts (`AhNode`): `playback` (the playback's state: playing, paused,
## ended) on the bar, `playback-control`, `button` (what it draws),
## `accessible-name` (its word), `tooltip` and `key` on each button, `playback-moment` and `playback-time` on the readout.

import ../../stories/agent_harbor_playback
import ../../viewmodel/keymap/[base_keymaps, context_keys, editing_keymap,
                               keymap_router, scope_path]
import ../../../common/key_names
import ./ah_tui_canvas

export agent_harbor_playback

const
  WideBarCols* = PlaybackCompactBelowPx div 8
    ## From this width (90 cells) the buttons carry their words.
  ReadoutGap* = 2
    ## Between the moment and its time: the web's readout gap (0.75rem) in
    ## cells, as between a session title and what follows it.

type
  PlaybackPress* = proc(operation: string)
    ## The story host's route for a press on a bar's button: `operation` is
    ## the one the button carries.

proc pressOf(press: PlaybackPress; operation: string): proc() =
  ## A button's target: the hit test, handing the press to the router. A
  ## proc of its own so each closure owns its operation.
  result = proc() =
    if press != nil: press(operation)

type
  PlaybackKeyOf* = proc(operation: string): string
    ## The key the story host's router resolves to `operation`, as the
    ## terminal reads it (`" "` for Space); "" when no key reaches it.

let baseRouter = initKeymapRouter(bkCua, KeyDelivery(frontEnd: feTerminal,
  platform: hostPlatform(), keyProtocol: kpLegacy))
  ## The base keymap's rows, for a bar drawn with no host router.

proc keyTokenOf*(chord: string): string =
  ## A displayed chord as the terminal reads the key: `Space` is a space.
  if chord == "Space": " " else: chord

proc routerKeyOf*(router: KeymapRouter): PlaybackKeyOf =
  ## The keys `router` resolves in the playback chrome's scope (IR-3: the
  ## key shown is the one that runs the control).
  let r = router
  result = proc(operation: string): string =
    keyTokenOf(r.chordFor(operation, SessionFacts(),
      @[element(ekWindow, "window"), pane(StoryPlaybackScope)], nmNormal))

let baseKeyOf: PlaybackKeyOf = routerKeyOf(baseRouter)

proc drawPlaybackBar*(c: var AhCanvas; pb: AhPlayback; row: int;
                      press: PlaybackPress = nil; keyOf: PlaybackKeyOf = nil) =
  ## The bar on `row`, the canvas's width; a press on a button goes to
  ## `press`. Each button carries the key `keyOf` names for its control
  ## (the base keymap's when nil).
  # On its own ground, a step off both the window's and a panel's: the
  # story above it ends where that ground starts (the web's hairline).
  c.area("playback-bar", row, 0, c.cols, 1, c.tone.playbackBar)
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
    let key = (if keyOf.isNil: baseKeyOf else: keyOf)(operationOf(control))
    discard c.node(bar, row, col + (if wide: 1 else: 0), widthOf(label), 1,
                   [("playback-control", $control), ("button", label),
                    ("accessible-name", pb.controlLabel(control)),
                    ("tooltip", controlTitle(control)),
                    ("key", key)])
    c.target(row, col, w, 1, pressOf(press, operationOf(control)))
    col += w + 1
  col += 1
  if col < c.cols:
    # The readout: the moment, cut first when the bar is short, and its
    # time `ReadoutGap` cells after it; the time is never cut.
    let time = pb.elapsedLabel
    let timeW = widthOf(time)
    let momentRoom = c.cols - 1 - col - ReadoutGap - timeW
    var timeAt = col
    if momentRoom > 0 and pb.momentLabel.len > 0:
      let shownW = min(widthOf(pb.momentLabel), momentRoom)
      timeAt = col + shownW + ReadoutGap
      discard c.text(bar, row, col, shownW, pb.momentLabel, c.p.textBody,
                     fact = "playback-moment", before = timeAt)
    if timeAt + timeW <= c.cols:
      discard c.text(bar, row, timeAt, timeW, time, c.p.textCaption,
                     fact = "playback-time")
