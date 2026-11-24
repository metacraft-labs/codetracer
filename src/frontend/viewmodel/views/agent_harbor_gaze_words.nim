## views/agent_harbor_gaze_words.nim
##
## The words, glyphs and rules the three hosts share for the status line's
## gaze mark (the web's `isonim_agent_harbor_gaze_mark_view`, GPUI's
## `gpui/agent_harbor/ah_gaze_mark`, the terminal's
## `tui/agent_harbor/ah_tui_gaze_mark`), over `GazeStatusVM`
## (nim-agents-isonim-viewmodels).
##
## The mark (Eye-Tracking-Context "Privacy and control"; codetracer-pm
## `design/agent-harbor-front-end/p2c-omnibox-and-control-center-study.md`
## D5, D65-D67): while gaze is tracked, an eye and `Gaze` in the quiet role;
## while paused, the eye struck through and `Gaze paused`; when off, nothing
## at all. Its tooltip names the key that pauses and resumes tracking -- the
## key the base keymap binds to `gaze.toggle-pause` (`gazePauseChord`), so
## the words can never name a key that does something else. A press on the
## mark runs the same operation.

import nim_agents_isonim_viewmodels/agent_harbor/gaze_status_vm
import ../keymap/[base_keymaps, editing_keymap, context_keys]

export gaze_status_vm

const
  GazeSurface* = "agent-harbor-status-gaze"
  GazeTogglePauseOperation* = "gaze.toggle-pause"
  GazeOperations* = [GazeTogglePauseOperation]
  TrackingGlyph* = "\xE2\x97\x89"
    ## ◉ (fisheye): the eye, in GPUI and the terminal (the web draws an eye
    ## in SVG, `GazeEyePath`).
  PausedGlyph* = "\xE2\x8A\x98"
    ## ⊘ (circled slash): the eye struck through.
  GazeEyeSvg* = """<svg viewBox="0 0 16 16" width="14" height="14" aria-hidden="true" """ &
    """fill="none" stroke="currentColor" stroke-width="1"><path d="M1.5 8c1.6-3 4-4.5 6.5-4.5 """ &
    """s4.9 1.5 6.5 4.5c-1.6 3-4 4.5-6.5 4.5S3.1 11 1.5 8z"/><circle cx="8" cy="8" r="2" """ &
    """fill="currentColor" stroke="none"/></svg>"""
    ## The web's eye: an outline and a filled pupil, 1-unit strokes in a
    ## 16-unit box and `currentColor` (the marks' convention,
    ## `edit_toolbar_marks`), so it takes the mark's ink in both themes.
  GazeEyeStruckSvg* = """<svg viewBox="0 0 16 16" width="14" height="14" aria-hidden="true" """ &
    """fill="none" stroke="currentColor" stroke-width="1"><path d="M1.5 8c1.6-3 4-4.5 6.5-4.5 """ &
    """s4.9 1.5 6.5 4.5c-1.6 3-4 4.5-6.5 4.5S3.1 11 1.5 8z"/><circle cx="8" cy="8" r="2" """ &
    """fill="currentColor" stroke="none"/><path d="M2.5 13.5l11-11"/></svg>"""
    ## The eye struck through, while paused.

proc gazePauseChord*(base = bkCua): string =
  ## The key the base keymap binds to the pause (`Ctrl+Alt+Y`), as it spells
  ## it; "" when the base binds none.
  for b in keymapOf(base).keymap.rows:
    if b.operation == GazeTogglePauseOperation:
      return b.spelling
  ""

proc glyphOf*(vm: GazeStatusVM): string =
  ## The terminal's and GPUI's glyph: the eye, or the eye struck through.
  if vm.struck: PausedGlyph else: TrackingGlyph

proc markFacts*(vm: GazeStatusVM): seq[(string, string)] =
  ## The facts the mark carries in every host (`data-ah-*`).
  @[("gaze", $vm.state.val), ("gaze-text", vm.text), ("gaze-struck", $vm.struck),
    ("tooltip", vm.tooltip)]

proc runGazeOperation*(vm: GazeStatusVM; operation: string): bool =
  ## Runs the gaze key's (or a press on the mark's) operation; false for one
  ## that is not the mark's, or a pause that changed nothing (tracking off).
  if vm.isNil: return false
  case operation
  of GazeTogglePauseOperation: vm.togglePause()
  else: false
