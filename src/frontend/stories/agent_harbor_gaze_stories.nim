## The gaze mark stories' viewmodel constructors.
##
## A story of the `agent-harbor-status-gaze` surface (declared in
## `codetracer_stories.nim`) is a `GazeStatusVM` built by
## `createGazeStoryVM` for the story's fixture, drawn in the status line of
## the window the composer's stories show (the replay stopped at
## `src/shield.nr:7`) by each host's mark view.
##
## No gaze provider is wired into the prototypes: the state is the one the
## fixture names, and the pause key's name is the one the base keymap binds
## (`agent_harbor_gaze_words.gazePauseChord`), passed in by the host so this
## module stays free of the keymap.

import nim_agents_isonim_viewmodels/agent_harbor/gaze_status_vm

export gaze_status_vm

const
  GazeStoryStatusItems* = "Noir \xE2\x94\x82 UTF-8"
    ## What the story's status line shows at its start, as the web story's
    ## (`renderStoryStatusBar`: the language and the encoding, with the
    ## status bar's separator between them; its location is hidden by
    ## design).
  GazeStoryStatusItemsTui* = "Noir  UTF-8"
    ## The same items on a terminal's status line, which separates its items
    ## with spaces, as the terminal's own status bar does: a terminal story
    ## draws no box-drawing glyph (`test_ctf_p1b_tui_no_box_borders_between_areas`).
  gazeFixtures* = ["off", "tracking", "paused"]
    ## Every fixture an `agent-harbor-status-gaze` story may name.

proc createGazeStoryVM*(fixture, chord: string): GazeStatusVM =
  ## The mark in the state the fixture names, its tooltip naming `chord`.
  ## An unknown fixture raises rather than showing some other state.
  let state = case fixture
    of "off": gsOff
    of "tracking": gsTracking
    of "paused": gsPaused
    else:
      raise newException(ValueError, "no gaze story fixture named " & fixture)
  newGazeStatusVM(state, chord)
