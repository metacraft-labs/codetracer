## fixtures/visual_fixture.nim — PLAT-59. THE VISUAL RECORDING the Visual
## Replay suites open on the terminal and in the GPUI window, and what they
## need beside it.
##
## A REAL recording: `gl_scene` (codetracer-native-test-programs) recorded by
## `ct-mcr` and its gfx stream extracted, as
## `scripts/record-visual-replay-fixture.sh` does — 60 frames of 256x256, four
## quads (one draw call each) per frame, every quad's colour a function of
## (frame, quadrant) that `quadColour` below states, so a frame, a draw call
## and a picked pixel's history are each checked against the PROGRAM, not
## against what the panes happened to show.
##
## Where it is: committed, in the `examples/recordings` submodule
## (codetracer-example-recordings) at `VisualFixtureCommitted`, so every host
## and CI job opens the same recording, pinned by this checkout's gitlink, and
## an answer captured from it (`src/tests/visual/answers/plat59-*.json`) holds
## on all of them. A recording made on the host would differ: its GEIDs count
## every call the process made, and those depend on the host's libraries.
## Opening a recording writes beside it (`ct` rewrites `trace.ct` and
## `paths.json` when it imports one), so the suites open a scratch copy, made
## once per process; the committed files are never changed.
##
## The player is found as `ct gfx-replay` finds it (`CODETRACER_CT_GFX_PLAYER_CMD`,
## beside `ct`, on PATH). Either missing is a LOUD, COUNTED skip with
## `fixture_provider`'s prefix — never a silent pass.

import std/[exitprocs, os, osproc, strutils]

from ../../../../ct/gfx_replay import findCtGfxPlayerBinary
import ./fixture_provider

const
  VisualFixtureCommitted* = "examples/recordings/mcr/linux-x86_64/visual-gl-scene"
  GlSceneFrames* = 60
  GlSceneDrawsPerFrame* = 4
  GlSceneSize* = 256

proc repoRootOf(): string =
  var dir = currentSourcePath().parentDir
  while not fileExists(dir / "justfile") and dir.parentDir != dir:
    dir = dir.parentDir
  dir

proc visualFixtureSource*(): string =
  ## The committed recording's folder, or "" when the submodule is not
  ## checked out.
  let dir = repoRootOf() / VisualFixtureCommitted
  if fileExists(dir / "gfx_stream" / "gfx_frames.idx"): dir else: ""

proc visualFixtureCommit*(): string =
  ## The codetracer-example-recordings commit this checkout pins (the
  ## `examples/recordings` gitlink): the recording an answer captured from
  ## the committed fixture names in its `fixture.commit`.
  let (output, code) = execCmdEx("git -C " & quoteShell(repoRootOf()) &
    " rev-parse HEAD:examples/recordings")
  if code == 0: output.strip else: ""

var scratchCopy {.threadvar.}: string

proc visualFixtureFolder*(): string =
  ## A scratch copy of the committed recording, made once per process, or ""
  ## when there is none to copy.
  if scratchCopy.len > 0 and dirExists(scratchCopy):
    return scratchCopy
  let source = visualFixtureSource()
  if source.len == 0:
    return ""
  let dest = getTempDir() / ("ct-visual-gl-scene-" & $getCurrentProcessId())
  removeDir(dest)
  copyDir(source, dest)
  scratchCopy = dest
  addExitProc(proc () = removeDir(dest))
  dest

proc visualFixtureSkip*(): string =
  ## Why the Visual Replay suites cannot run here ("" when they can): the
  ## recording or the player missing, in `fixture_provider`'s words.
  if visualFixtureSource().len == 0:
    return MissingPrereqSkipPrefix & " the visual recording (gl_scene) is " &
      "not here: it is committed at " & VisualFixtureCommitted &
      "; check the submodule out (`git submodule update --init " &
      "examples/recordings`)"
  if findCtGfxPlayerBinary().len == 0:
    return MissingPrereqSkipPrefix & " the visual replay player " &
      "(ct_gfx_player) is not installed: build codetracer-visual-replay and " &
      "set CODETRACER_CT_GFX_PLAYER_CMD"
  ""

func quadColour*(frame, quadrant: int): tuple[r, g, b: int] =
  ## `gl_scene.c`'s `color_for_quadrant`: the colour quad `quadrant` is drawn
  ## in at frame `frame`.
  let seed = frame * 4 + quadrant
  ((seed * 47 + 100) mod 256, (seed * 73 + 50) mod 256,
   (seed * 113 + 25) mod 256)

func quadrantAt*(x, y: int): int =
  ## The quad under pixel `(x, y)` of the IMAGE (top row first): quadrant 0
  ## is the bottom-left in GL's NDC, so the image's top half holds 2 and 3.
  let right = x >= GlSceneSize div 2
  let top = y < GlSceneSize div 2
  (if top: 2 else: 0) + (if right: 1 else: 0)

func pixelOf*(rgba: string; width, x, y: int): tuple[r, g, b: int] =
  let i = (y * width + x) * 4
  (ord(rgba[i]), ord(rgba[i + 1]), ord(rgba[i + 2]))
