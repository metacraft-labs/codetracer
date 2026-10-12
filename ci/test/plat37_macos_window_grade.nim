## plat37_macos_window_grade.nim — grade one captured macOS window frame.
##
## ## It reuses the oracle; it does not re-implement one
##
## Every predicate here comes from `src/tests/visual/screen_oracle/`:
## `readFrame`, which calls `locateGrid`, `identifyPane`, `identifyByStripAbove`,
## `readProgramState`, `readEventLog`, `readEditor` and `readGutterDigits`, and
## answers in `screen_reading`'s tri-state `ScreenReading[T]` — `read`, `empty`
## or a NAMED `srUnreadable`. PLAT-39 wrote all of it; this module chooses the
## OCR engine, hands over a frame, and writes down what came back.
##
## The one thing it adds is the assertion the macOS window needed and the
## Wayland lanes never did:
##
## ## `rendersText` — the assertion the font-kit bug would have caught
##
## `isonim-gpui` `b0ea5fc` enables `gpui_platform/font-kit` in the
## `gpui-backend` feature. Before it, `gpui_macos` installs a text system that
## *renders nothing*: the window paints its pane grounds and not one glyph on
## them. Measured on this host, 2026-10-12, same binary, same scenario, same
## 1440x929-point window, same capture route, differing only in the shim:
##
##   * windowed shim built from `76b2a2c`'s `Cargo.toml` (65,120,504 bytes):
##     Apple Vision recognised **0** strings.
##   * windowed shim built from `b0ea5fc`'s (66,282,184 bytes): **115**.
##
## That is the red control for this assertion, and it is why `rendersText` is
## graded from a WHOLE-FRAME reading rather than from the oracle's per-pane
## answers. A frame with no glyphs still has a grid, still has pane cells, and
## `locateGrid` still succeeds on it — so every geometric predicate in the
## oracle passes on a window that draws no text at all. Only something that
## counts glyphs can fail on it.
##
## `isFlat` is the second half and catches the complementary failure: a frame
## of one solid colour, which has no text AND no grid, and which a word count
## alone would report the same way as a broken OCR run.
##
## ## Why `obAppleVision`
##
## `tesseract` is not reachable from where this lane runs — not on the ambient
## PATH, and `codetracer`'s own `flake.nix` and `repro.nim` declare none.
## (GuiAssert's flake *does* carry `tesseract 5.5.1`, but that is a different
## dev shell and it has no codetracer sources in it.) Apple Vision needs no
## package on any PATH: it is `VNRecognizeTextRequest` through GuiAssert's
## bundled Swift helper, which `swiftc` compiles on demand. `setOracleOcrBackend` is what repoints the
## oracle at it; see `vision_producer`'s own note for the two things that
## differ per backend (the scratch container, and `upscale`).
##
## **A READING IS ONLY COMPARABLE WITH ONE TAKEN ON THE SAME ENGINE**, so the
## record names the backend. It is not interchangeable with PLAT-39's recorded
## tesseract answers and nothing here pretends otherwise.
##
## ## The frame this grades is in POINTS
##
## The captured PNG is in DEVICE pixels — 2x on this display. The oracle's
## constants are 1x (`TitleStripHeight`, the 8-pixel run floor that excludes a
## rule from a highlighted row, the ~22-pixel text row). So the lane downscales
## the capture to its POINT extent and grades that, and the record says which
## file it read. The device-pixel PNG is the artefact of record and is kept.

when defined(js):
  {.error: "plat37_macos_window_grade is native-only.".}

import std/[json, os, sequtils, strutils]

import gui_assert/image_math
import gui_assert/ocr

import ../../src/tests/visual/screen_oracle/vision_producer
import ../../src/tests/visual/screen_oracle/screen_reading

const
  MinGlyphStrings* = 8
    ## How many recognised strings a frame must hold to count as *rendering
    ## text*. Chosen against the measured extremes rather than split between
    ## them: the no-font-kit control read **0** and the font-kit frame read
    ## **115**. Eight is an order of magnitude clear of the floor and an order
    ## of magnitude under the real reading, so neither a single spurious
    ## recognition nor the loss of most of a pane moves the verdict.
  MinDistinctLevels* = 3
    ## Gray levels a frame must hold to be more than a flat fill. The same
    ## two-state reasoning `pixel_capture.captureIsBlank` uses, in the gray
    ## domain: a solid ground has one level, a ground with a border has two.

type
  Config = object
    framePath: string
    recordPath: string
    scratch: string
    view, scenario: string
    expectText: bool

const Usage = """
plat37_macos_window_grade — grade one captured macOS window frame

  plat37_macos_window_grade --frame=<png> --record=<json> \
      --view=<name> --scenario=<id> [--scratch=<dir>] [--expect-blank]

`--expect-blank` INVERTS the verdict and is the RED CONTROL: it passes only
when the frame renders no text, so the grader has a case it can fail on.
"""

proc parseConfig(args: seq[string]): Config =
  result = Config(expectText: true)
  for arg in args:
    if arg.startsWith("--frame="): result.framePath = arg["--frame=".len .. ^1]
    elif arg.startsWith("--record="):
      result.recordPath = arg["--record=".len .. ^1]
    elif arg.startsWith("--scratch="):
      result.scratch = arg["--scratch=".len .. ^1]
    elif arg.startsWith("--view="): result.view = arg["--view=".len .. ^1]
    elif arg.startsWith("--scenario="):
      result.scenario = arg["--scenario=".len .. ^1]
    elif arg == "--expect-blank": result.expectText = false
    else: quit("unknown argument '" & arg & "'\n" & Usage, 2)
  if result.framePath.len == 0 or result.recordPath.len == 0:
    quit("--frame and --record are required\n" & Usage, 2)
  if result.scratch.len == 0:
    result.scratch = result.framePath.parentDir / "scratch"

proc readingJson[T](r: ScreenReading[T]): JsonNode =
  ## The tri-state, carried rather than flattened. `LAW-R1`'s whole point is
  ## that a failure to read is an ANSWER and has to survive into the record.
  case r.kind
  of srRead: %*{"state": "read"}
  of srEmpty: %*{"state": "empty"}
  of srUnreadable: %*{"state": "unreadable", "reason": $r.reason,
                      "detail": r.detail}

proc main() =
  let cfg = parseConfig(commandLineParams())
  # THE ENGINE IS SELECTED BEFORE ANYTHING IS READ, and named in the record.
  setOracleOcrBackend(obAppleVision)

  var node = %*{
    "grader": "plat37-macos-window-grade",
    "view": cfg.view,
    "scenario": cfg.scenario,
    "framePath": cfg.framePath,
    "ocrBackend": $oracleOcrBackend(),
    "expect": (if cfg.expectText: "text" else: "blank"),
  }
  let recDir = cfg.recordPath.parentDir
  if recDir.len > 0: createDir(recDir)

  proc finish(ok: bool, problems: seq[string]) =
    node["problems"] = %problems
    node["verdict"] = %(if ok: "OK" else: "BAD")
    writeFile(cfg.recordPath, node.pretty & "\n")
    if ok:
      echo "  OK (", cfg.view, ")"
      quit(0)
    echo "  BAD (", cfg.view, "): ", problems.join("; ")
    quit(1)

  if not fileExists(cfg.framePath):
    finish(false, @["no frame at " & cfg.framePath])

  # --- the frame's own census, before any grammar ---------------------------
  var img: GrayImage
  try:
    img = decodeGray(cfg.framePath)
  except CatchableError as e:
    finish(false, @["the frame did not decode: " & e.msg.splitLines()[0]])
  var levels: array[256, bool]
  var distinct0 = 0
  var nonZero = 0
  for c in img.pixels:
    let v = ord(c)
    if v != 0: inc nonZero
    if not levels[v]:
      levels[v] = true
      inc distinct0
  node["frame"] = %*{
    "width": img.width, "height": img.height,
    "nonZeroPixels": nonZero,
    "distinctGrayLevels": distinct0,
    "isFlat": distinct0 < MinDistinctLevels,
  }

  # --- `rendersText`, the whole-frame glyph count ---------------------------
  var words: seq[OcrWord] = @[]
  var ocrError = ""
  try:
    words = runOcrWithBackend(cfg.framePath, obAppleVision, initOcrOptions())
  except CatchableError as e:
    ocrError = e.msg.splitLines()[0]
  node["text"] = %*{
    "recognizedStrings": words.len,
    "floor": MinGlyphStrings,
    "rendersText": words.len >= MinGlyphStrings,
    "sample": words[0 ..< min(12, words.len)].mapIt(it.text),
    "error": ocrError,
  }

  # --- the oracle --------------------------------------------------------
  let reading = readFrame(cfg.framePath, cfg.scratch)
  var paneIds: seq[string] = @[]
  for p in reading.panes: paneIds.add $p.id
  node["oracle"] = %*{
    "panes": paneIds,
    "paneCount": reading.panes.len,
    "programState": readingJson(reading.programState),
    "eventLog": readingJson(reading.eventLog),
    "editor": readingJson(reading.editor),
  }
  if reading.editor.isRead:
    node["oracle"]["highlightedLineNumber"] =
      %reading.editor.value.higlitedLineNumber

  # --- the verdict ---------------------------------------------------------
  var problems: seq[string] = @[]
  if ocrError.len > 0:
    problems.add "the OCR backend failed: " & ocrError
  let rendersText = words.len >= MinGlyphStrings
  if cfg.expectText:
    if node["frame"]["isFlat"].getBool:
      problems.add "the frame is a flat fill (" & $distinct0 &
                   " gray level(s)): the window painted nothing"
    if not rendersText:
      problems.add "the window rendered NO TEXT (" & $words.len &
                   " recognised string(s), floor " & $MinGlyphStrings &
                   "). On macOS this is the `gpui_platform/font-kit` " &
                   "feature missing from `gpui-backend`: the window paints " &
                   "its pane grounds and no glyph on them. Check that " &
                   "codetracer's flake.lock pins isonim-gpui at b0ea5fc or " &
                   "later AND that the staged windowed shim was built from it."
    if reading.panes.len == 0:
      problems.add "the oracle located no pane in the frame"
  else:
    # THE RED CONTROL, and it is a real one: this arm has been made to fail.
    # A grader whose negative case cannot be run is a grader with one branch.
    if rendersText:
      problems.add "--expect-blank, and the frame renders text (" &
                   $words.len & " recognised string(s)): the control did " &
                   "not control anything"
  finish(problems.len == 0, problems)

when isMainModule:
  main()
