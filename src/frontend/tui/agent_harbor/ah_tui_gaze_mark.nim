## tui/agent_harbor/ah_tui_gaze_mark.nim — CTF-P2c step 4. The terminal's
## status line gaze mark, over `GazeStatusVM` (nim-agents-isonim-viewmodels),
## drawn as the web's `isonim_agent_harbor_gaze_mark_view` draws it, from the
## same words (`agent_harbor_gaze_words`): while gaze is tracked `◉ Gaze` in
## the caption role; while paused `⊘ Gaze paused` (the eye struck through);
## when off, nothing.
##
## The story draws it where the web story does: on the window's last row,
## the status line (the panel's ground, the language and the encoding at its
## start), at the end of the line, a cell in from the edge. A press on it is
## routed: it carries `gaze.toggle-pause` and reports the press to the
## host's `GazePress`. A terminal maps gaze to cells only when the provider
## can (Eye-Tracking-Context "Privacy and control"); the mark is the same.
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
                    items: string; press: GazePress = nil) =
  ## The story's window: an empty working area over the status line, the
  ## mark at the line's end.
  var facts = @[("surface", GazeSurface)]
  facts.add vm.markFacts
  let host = c.node(nil, row, col, width, height, facts)
  # The working area above it: the web story's canvas role.
  c.area("window", row, col, width, height - 1, tokenHexOf(dtColorsUiSurfaceBaseCanvas, c.p.mode))
  let line = row + height - 1
  c.area("status-line", line, col, width, 1, c.tone.body)
  let status = c.node(host, line, col, width, 1, [("status-line", "")])
  discard c.text(status, line, col + 1, max(1, width - 2), items, c.p.textCaption)
  let shown = vm.markText
  if shown.len == 0: return
  let w = widthOf(shown)
  let at = col + max(1, width - 1 - w)
  discard c.put(line, at, shown, c.p.textCaption)
  let mark = c.node(status, line, at, w, 1,
                    [("gaze-mark", $vm.state.val), ("tooltip", vm.tooltip),
                     ("accessible-name", vm.text), ("operation", GazeTogglePauseOperation)])
  let route = press
  let click = proc() =
    if route != nil: route(GazeTogglePauseOperation)
  c.target(mark.row, mark.col, w, 1, click)
