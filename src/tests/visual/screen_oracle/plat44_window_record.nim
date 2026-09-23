## PLAT-44 — the typed byte, READ OFF THE SCREEN through PLAT-39's reader.
##
## `ci/test/plat44-edit-window.sh` opens `codetracer-gpui --edit` in a real
## window on a headless compositor, types Shift+q with `wtype`, and grabs three
## frames with `grim`: a BLANK control before the window exists, the window
## BEFORE the key, and AFTER it. This program reads those frames with PLAT-39's
## pixel producer — `locateGrid` to find the panes, `identifyPane` to find the
## editor by its title strip, `ocrRegion` over the editor's body — and writes
## `src/tests/visual/plat44-edit-window.json`, which the portable suite
## `src/frontend/gpui/tests/test_plat44_edit_window.nim` asserts over.
##
## THE ONE ASSERTION THIS MAKES POSSIBLE is PLAT-44's "the model changed" vs
## "the user can see that it changed": the typed `Q` must be legible in the
## AFTER frame and not in the BEFORE frame, and the BLANK frame must not be
## readable as an editor at all.
##
## It REFUSES to write a record from an absent run or absent frames: a record
## of `urFrameMissing` would have the shape of an answer.
##
## Run: `just plat44-window-record` (needs `tesseract`; see PLAT-39).

import std/[json, os, strutils, times, nativesockets]

import ./screen_reading
import ./vision_producer
import ./region_locator
import gui_assert/image_math

const
  RunDir = "build/plat44"
  Out = "src/tests/visual/plat44-edit-window.json"

type
  FrameText = object
    frame: string
    located: bool
      ## Whether PLAT-39's locator found an editor pane at all.
    reason: string
      ## When not located: the typed reason, as the reader reports it.
    text: string
      ## Every OCR'd word of the editor body, space-joined, in reading order.

proc readEditorText(path, scratch: string): FrameText =
  result.frame = path.extractFilename
  if not fileExists(path):
    result.reason = "no file at " & path
    return
  let img = decodeGray(path)
  let grid = locateGrid(img)
  if grid.isUnreadable:
    result.reason = $grid.reason & ": " & grid.detail
    return
  createDir(scratch)
  for cell in grid.value.cells:
    let pane = identifyPane(img, cell, scratch)
    if pane.id == piEditor:
      result.located = true
      var words: seq[string] = @[]
      for w in ocrRegion(img, pane.rect, scratch):
        words.add w.text
      result.text = words.join(" ")
      return
  result.reason = "no cell's title strip identified an editor pane"

proc main() =
  let root = getCurrentDir()
  let resultPath = root / RunDir / "result.json"
  if not fileExists(resultPath):
    quit("PLAT-44: refusing to record — no window run at " & resultPath &
         " (`just plat44-edit-window` first)", 1)
  let run = parseJson(readFile(resultPath))
  for n in ["blank", "before", "after"]:
    if not fileExists(root / RunDir / (n & ".ppm")):
      quit("PLAT-44: refusing to record — frame " & n & " is missing", 1)
  let scratch = getTempDir() / "plat44-ocr"
  var frames = newJObject()
  for n in ["blank", "before", "after"]:
    let t = readEditorText(root / RunDir / (n & ".ppm"), scratch)
    frames[n] = %*{"located": t.located, "reason": t.reason, "text": t.text}
  let record = %*{
    "_comment": [
      "PLAT-44 — the window run's result and its three frames read through",
      "PLAT-39's pixel reader. Regenerate: `just plat44-edit-window` then",
      "`just plat44-window-record`. Asserted by test_plat44_edit_window.nim."],
    "takenAt": now().utc.format("yyyy-MM-dd'T'HH:mm:ss'Z'"),
    "host": getHostname(),
    "run": run,
    "frames": frames,
  }
  writeFile(root / Out, record.pretty & "\n")
  echo "wrote ", Out
  for n in ["blank", "before", "after"]:
    echo "  ", n, ": located=", frames[n]["located"].getBool, " text=",
      frames[n]["text"].getStr[0 ..< min(80, frames[n]["text"].getStr.len)]

main()
