## test_plat59_gpui_window.nim — the Video Player's frames as a REAL GPUI window
## showed them.
##
## The record `src/tests/visual/plat59-gpui-window.json` is MEASURED off a real
## window on a headless sway (`ci/test/plat59-gpui-window.sh`), the
## measure-locally-commit-the-measurement arrangement the other window captures
## use: Linux has no off-screen GPUI renderer, so a window is how its pixels are
## read. No mocks: the record's pixels came from a real `gl_scene` recording, a
## real `ct_gfx_player` and the real window.
##
## What this holds: at frame 0, frame 30 and the last frame the window's pixels
## at the centres of the image's quarters are the colours the program drew there
## and the desktop's Video Player showed, the right way up.

import std/[json, os, unittest]

const
  Record = "src/tests/visual/plat59-gpui-window.json"
  Answers = "src/tests/visual/answers/plat59-visual-replay.electron.json"

func quadHex(frame, quadrant: int): string =
  ## `gl_scene.c`'s `color_for_quadrant`.
  const Hex = "0123456789abcdef"
  let seed = frame * 4 + quadrant
  result = "#"
  for v in [(seed * 47 + 100) mod 256, (seed * 73 + 50) mod 256,
            (seed * 113 + 25) mod 256]:
    result.add Hex[v shr 4]
    result.add Hex[v and 15]

proc fromRepo(path: string): JsonNode =
  var dir = getCurrentDir()
  while not fileExists(dir / path) and dir.parentDir != dir:
    dir = dir.parentDir
  if not fileExists(dir / path):
    raise newException(IOError, path & " is missing: run the plat59 window capture")
  parseJson(readFile(dir / path))

suite "the Video Player in a real GPUI window":
  let frames = fromRepo(Record)["frames"]

  test "the record measures the three frames":
    check frames.len == 3
    check frames[0]["frame"].getInt == 0
    check frames[1]["frame"].getInt == 30
    check frames[2]["frame"].getInt == 59

  test "the window's pixels are the program's, the right way up":
    for f in frames:
      let at = f["frame"].getInt
      # The image's quarters: top left is quad 2, top right 3, bottom left 0,
      # bottom right 1.
      var want: seq[string] = @[]
      for q in [2, 3, 0, 1]:
        want.add quadHex(at, q)
      var got: seq[string] = @[]
      for q in f["imageQuads"]:
        got.add q.getStr
      check got == want

  test "the window's pixels are the desktop's":
    let desk = fromRepo(Answers)["frames"]
    check desk.len == frames.len
    for i in 0 ..< frames.len:
      check desk[i]["frame"].getInt == frames[i]["frame"].getInt
      var deskQuads: seq[string] = @[]
      for q in desk[i]["quadColours"]:   # quads 0, 1, 2, 3
        deskQuads.add q.getStr
      let got = frames[i]["imageQuads"]
      check got[0].getStr == deskQuads[2]
      check got[1].getStr == deskQuads[3]
      check got[2].getStr == deskQuads[0]
      check got[3].getStr == deskQuads[1]
