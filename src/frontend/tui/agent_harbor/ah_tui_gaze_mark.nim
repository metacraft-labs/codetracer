## tui/agent_harbor/ah_tui_gaze_mark.nim — CTF-P2c step 4. The terminal's
## status line gaze mark, over `GazeStatusVM` (nim-agents-isonim-viewmodels),
## drawn as the web's `isonim_agent_harbor_gaze_mark_view` draws it, from the
## same words (`agent_harbor_gaze_words`): while gaze is tracked `◉ Gaze` in
## the status line's ink (`statusLineInks`); while paused `⊘ Gaze paused`
## (the eye struck through); when off, nothing.
##
## The story draws it where the web story does: on the window's last row,
## the status line (on `statusLineInks`' ground, the language and the
## encoding at its start), at the end of the line, a cell in from the edge,
## under the control center as L7 shows it. A press on it is routed: it
## carries `gaze.toggle-pause` and reports the press to the host's
## `GazePress`. A terminal maps gaze to cells only when the provider can
## (Eye-Tracking-Context "Privacy and control"); the mark is the same.
##
## Facts: `markFacts` on the story's root, `gaze-mark` on the mark.

import ../../viewmodel/views/agent_harbor_gaze_words
import ./ah_tui_canvas

export agent_harbor_gaze_words

type
  GazePress* = proc(operation: string)
    ## A host's route for a press on the mark: the operation it carries.

proc markText*(vm: GazeStatusVM): string =
  ## What the mark draws: the glyph and the words; "" when off.
  if not vm.shown: "" else: vm.glyphOf & " " & vm.text

proc drawGazeStory*(c: var AhCanvas; vm: GazeStatusVM; row, col, width, height: int;
                    items: string; press: GazePress = nil;
                    above: proc(c: var AhCanvas) = nil) =
  ## The story's window: the working area over the status line, the mark at
  ## the line's end. `above` draws the working area (the control center as
  ## L7 shows it, manager note 167), after the story's node, so the story's
  ## node stays the view's root, and before the line, so nothing it draws
  ## past its foot covers the line; nil: an empty working area on the web
  ## story's canvas role. The line is on `statusLineInks`' ground, one no
  ## area of the control center above it takes, in its ink.
  var facts = @[("surface", GazeSurface)]
  facts.add vm.markFacts
  let host = c.node(nil, row, col, width, height, facts)
  if above.isNil:
    c.area("window", row, col, width, height - 1,
           tokenHexOf(dtColorsUiSurfaceBaseCanvas, c.p.mode))
  else:
    above(c)
  let line = row + height - 1
  let (lineGround, lineInk) = statusLineInks(c)
  c.area("status-line", line, col, width, 1, lineGround)
  let status = c.node(host, line, col, width, 1, [("status-line", "true")])
  discard c.text(status, line, col + 1, max(1, width - 2), items, lineInk)
  let shown = vm.markText
  if shown.len == 0: return
  let w = widthOf(shown)
  let at = col + max(1, width - 1 - w)
  discard c.put(line, at, shown, lineInk)
  let mark = c.node(status, line, at, w, 1,
                    [("gaze-mark", $vm.state.val), ("tooltip", vm.tooltip),
                     ("accessible-name", vm.text), ("operation", GazeTogglePauseOperation)])
  let route = press
  let click = proc() =
    if route != nil: route(GazeTogglePauseOperation)
  c.target(mark.row, mark.col, w, 1, click)
