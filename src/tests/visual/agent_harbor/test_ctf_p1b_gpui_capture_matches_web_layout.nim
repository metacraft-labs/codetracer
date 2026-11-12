## test_ctf_p1b_gpui_capture_matches_web_layout.nim — CTF-P1b: **every GPUI
## capture of an Agent Harbor story lays its parts out where the web capture
## of the same story does.**
##
## The captures:
##
##   * GPUI: `ci/test/ctf-p1b-gpui-story-capture.sh` (`just
##     ctf-p1b-gpui-captures`) opens the story host `codetracer-gpui-story` on
##     GuiAssert's headless sway, one REAL window per story, theme and size,
##     and leaves `<capture id>.ppm` / `.png` (the frame) and
##     `<capture id>.regions.json` (where GPUI's own layout put each declared
##     region, read back through isonim-gpui's `layout_bounds`) in
##     `build/ctf-p1b/gpui/` (`CTF_P1B_GPUI_OUT` overrides).
##   * Web: `ci/test/ctf-p1b-web-capture.sh` (`just ctf-p1b-web-captures`)
##     shoots the same stories in StoryBook with `capture-storybook.mjs
##     --regions` and records where the browser laid out each region in the
##     committed `src/tests/visual/agent-harbor-web-regions.json` — the same
##     arrangement as PLAT-35's recorded Electron arm, so the comparison runs
##     wherever the GPUI window can be opened, without a browser.
##
## The regions — the view, its frame's title tab, a panel's head and rows,
## the active tab, the `+N` chip, the "+" control, a popup, an open dropdown,
## a loading / empty / error notice — are declared once, for both renderers,
## in `src/tests/visual/agent-harbor-regions.json`.
##
## For each story of the `CodeTracer/Agent Harbor` section (read from its one
## declaration, `stories/codetracer_stories.nim`, so a new story is expected
## on the day it is declared), in both themes, at the laptop (1440×900) and
## sidebar (360×900) sizes, the capture FAILS when:
##
##   * its frame is missing, is not a P6 PPM of the story's viewport, or has
##     no PNG of the same size beside it;
##   * its frame is blank — one colour — or a region's rectangle in the frame
##     is a single colour (a region the layout reports but the window did not
##     draw);
##   * its regions file is missing, or was measured in another viewport;
##   * the web record has no capture of the same id;
##   * a region is drawn on one side and not the other, or any edge of a
##     region (x, y, width, height, in hundredths of the viewport) is more
##     than PLAT-35's `PaneRectangleTolerancePp` from the web's. The
##     comparison IS PLAT-35's: `layout_questions.compareAnswer` over
##     `formatPaneRectangles`, the one comparator its own gate uses, with its
##     tolerance (2, "never raised"). Nothing here loosens it;
##   * a row region (one row of a list: its first, or the last one drawn whole) is a
##     different row on the two sides -- each side reports the row's `index`
##     among the list's visible rows, and they must be equal. Rows drawn a
##     few pixels taller than the web's drift a long list down while its
##     outer box stays put, and the last row in the window is where that shows; by
##     position alone, two different rows that each sit near the bottom of
##     their window could still be within the tolerance of each other;
##   * a `fill` region's background is more than `FillTolerance` per channel
##     from the colour the browser composites behind it;
##   * an edge a region declares in `px` (the single-line tabs, the strip
##     notice, the inbox position, a panel error's reason, the session
##     list's head and summary) is more than `PxTolerance` pixels from the
##     web's. The pane-rectangle comparison above still applies to them;
##     this one only adds the pixel-sized answer it cannot give (two
##     hundredths of the laptop viewport are 29px).
##   * on either side, the initiative bar's `+N` menu (`bar-overflow-menu`)
##     does not hang from its chip (`bar-overflow`): its right edge on the
##     chip's right edge, shifted only as far as it must be to stay inside the
##     viewport on either side, to within `HangTolerancePx`. The
##     pane-rectangle comparison cannot see this: two hundredths of the
##     laptop viewport would let a menu drift 29px off its chip.
##
## The verdicts, each region's rectangle on both sides and its deltas are
## written to `build/ctf-p1b/parity/report.json` and `report.md` (the
## parity-pairs report; `tools/visual-review/parity-pairs.sh --agent-harbor`
## puts the side-by-side images beside it).
##
## Negative controls (the second suite) run the same judge over planted
## copies of one real capture: a blank frame, a missing frame, a missing
## regions file and a region shifted one point beyond the tolerance must each
## fail by name, while the untouched copy and one shifted by exactly the
## tolerance pass — so a judge that cannot fail, or one whose tolerance
## silently became zero, is caught. The same for a row picked at another
## index, for a fill one and two units off (one passes, two fails), and for
## a `px` edge off by `PxTolerance` (passes) and one pixel more (fails),
## and for a `+N` menu moved off its chip (right-aligned under the bar, or
## past the window's left edge where the window should have stopped it).
##
## No mocks: both sides are real captures of real renderers, over the
## committed synthetic fixture set both builds embed.
##
## Trap 13 / §29 (`Verification-Harness-Traps.md`): every helper returns what
## it found; only the test bodies `check`.

import std/[algorithm, json, math, os, sets, strutils, tables, unittest]

import ../../../common/view_vocabulary/layout_questions
import ../../../frontend/stories/codetracer_stories
import ../../../../tools/stories/emit_storybook_stories

const
  SectionTitle = "CodeTracer/Agent Harbor"
  StoryIdPrefix = "codetracer-agent-harbor--"
  ViewPrefix = "agent-harbor-"
  Sizes = [("laptop", 1440, 900), ("sidebar", 360, 900)]
    ## The design brief's laptop and narrow sizes (`capture-storybook.mjs`'s
    ## `laptop` and `sidebar`).
  Themes = ["dark", "light"]
  FillTolerance = 1
    ## Per channel, between the GPUI frame's pixel and the colour the browser
    ## composites: one unit, for the rounding of a translucent fill blended
    ## in GPUI's arithmetic rather than the browser's (the selected
    ## initiative's 28% tint). Every fill measured so far is exact. It is no
    ## wider because the palette holds roles TWO units apart
    ## (`surface/base/card` #262626 against `base/panel` #282828): a
    ## tolerance of 2 or more could not tell those apart.
  MinimumStories = 59
    ## The section's stories at CTF-P2a's landing; a floor, so a declaration
    ## that lost its stories cannot pass by expecting nothing.
  HangTolerancePx = 1.0
    ## Between where the `+N` menu is and where hanging it from its chip
    ## puts it, on one side. The browser measures its chip and places the
    ## menu in fractions of a pixel; GPUI places it where its own Flexbox
    ## shrink in whole pixels (`fitWidths`) says the chip ends, which its
    ## layout can round a pixel the other way (measured: the chip ending at
    ## 982 and the menu at 981 on the laptop `overflow-menu-over-panel`).
  PxTolerance = 2.0
    ## Per edge, in pixels, for the edges a region declares in `px`, ON TOP
    ## of the pane-rectangle comparison (which stays as it is): the browser
    ## lays out in fractions of a pixel and the GPUI views in whole ones, and
    ## the two set a text's width a pixel apart (kerning and rounding). Two
    ## hundredths of the laptop viewport are 29px, wider than any one tab,
    ## line pitch or inset these regions exist to hold.

let repoRoot = currentSourcePath().parentDir.parentDir.parentDir.parentDir.parentDir
let gpuiDir = getEnv("CTF_P1B_GPUI_OUT", repoRoot / "build" / "ctf-p1b" / "gpui")
let webRecordPath = getEnv("CTF_P1B_WEB_RECORD",
                           repoRoot / "src" / "tests" / "visual" / "agent-harbor-web-regions.json")
let reportDir = getEnv("CTF_P1B_REPORT_DIR", repoRoot / "build" / "ctf-p1b" / "parity")
let regionsDeclPath = getEnv("CTF_P1B_REGIONS",
                             repoRoot / "src" / "tests" / "visual" / "agent-harbor-regions.json")

type
  Rect = object
    x, y, w, h: float
    index: int
      ## A row region's position among its list's visible rows on that
      ## side (`"pick"` in the declaration); -1 for any other region.

  RegionSet = OrderedTable[string, Rect]

  Frame = object
    width, height: int
    rgb: string

  Verdict = enum
    vPass = "pass"
    vMissing = "missing"
    vBlank = "blank"
    vNoRegions = "no-regions"
    vNoWeb = "no-web-capture"
    vLayout = "layout"
    vFill = "fill"
    vPixels = "pixels"
    vHang = "hang"

  RegionDelta = object
    name: string
    web, gpui: PaneRect         ## hundredths of the viewport
    webPx, gpuiPx: Rect
    onlyOn: string              ## "web" / "gpui" when the other side has none
    within: bool
    sameRow: bool               ## a row region: both sides picked the same row
    webFill, gpuiFill: string   ## a `fill` region's background, `#rrggbb`
    pxEdges: seq[string]        ## the edges compared in pixels (`px`)

  CaptureJudgement = object
    id: string
    verdict: Verdict
    problems: seq[string]
    regions: seq[RegionDelta]

# ---------------------------------------------------------------------------
# Reading the captures
# ---------------------------------------------------------------------------

proc readPpm(path: string): Frame =
  ## A binary PPM (P6, maxval 255), as GuiAssert writes the compositor's
  ## frame. Raises `ValueError` for anything else.
  let s = readFile(path)
  var i = 0
  var fields: seq[string]
  while fields.len < 4:
    while i < s.len and s[i] in Whitespace: inc i
    if i < s.len and s[i] == '#':
      while i < s.len and s[i] != '\n': inc i
      continue
    let start = i
    while i < s.len and s[i] notin Whitespace: inc i
    if start == i: raise newException(ValueError, path & ": truncated PPM header")
    fields.add s[start ..< i]
  inc i # the single whitespace byte after maxval
  if fields[0] != "P6" or fields[3] != "255":
    raise newException(ValueError, path & ": not a P6 PPM with maxval 255")
  result.width = parseInt(fields[1])
  result.height = parseInt(fields[2])
  if s.len - i != result.width * result.height * 3:
    raise newException(ValueError, path & ": " & $(s.len - i) & " pixel bytes for " &
                       $result.width & "x" & $result.height)
  result.rgb = s[i .. ^1]

proc pngSize(path: string): tuple[w, h: int] =
  ## The PNG's IHDR size (RFC 2083 §4.1.1); (-1, -1) for a file that is not
  ## a PNG.
  let s = readFile(path)
  if s.len < 24 or s[0 ..< 8] != "\x89PNG\r\n\x1A\n" or s[12 ..< 16] != "IHDR":
    return (-1, -1)
  proc be32(o: int): int =
    (ord(s[o]) shl 24) or (ord(s[o + 1]) shl 16) or (ord(s[o + 2]) shl 8) or ord(s[o + 3])
  (be32(16), be32(20))

proc distinctColours(f: Frame; r: Rect; atMost: int): int =
  ## How many colours the frame shows inside `r` (clipped), counting up to
  ## `atMost`.
  let x0 = max(0, int(floor(r.x)))
  let y0 = max(0, int(floor(r.y)))
  let x1 = min(f.width, int(ceil(r.x + r.w)))
  let y1 = min(f.height, int(ceil(r.y + r.h)))
  var seen = initHashSet[int]()
  for y in y0 ..< y1:
    for x in x0 ..< x1:
      let o = (y * f.width + x) * 3
      seen.incl (ord(f.rgb[o]) shl 16) or (ord(f.rgb[o + 1]) shl 8) or ord(f.rgb[o + 2])
      if seen.len >= atMost: return seen.len
  seen.len

proc hexOf(f: Frame; x, y: int): string =
  let o = (y * f.width + x) * 3
  "#" & toHex(ord(f.rgb[o]), 2).toLowerAscii & toHex(ord(f.rgb[o + 1]), 2).toLowerAscii &
    toHex(ord(f.rgb[o + 2]), 2).toLowerAscii

proc fillSample(r: Rect): tuple[x, y: int] =
  ## Where a region's background is read: 4px in from its right edge, half
  ## way down -- inside the element's padding (every `fill` region has at
  ## least 8px of it on the right), clear of its text and of the left-edge
  ## focus bar, and inside its rounded corners.
  (int(floor(r.x + r.w)) - 4, int(floor(r.y + r.h / 2)))

proc channelsApart(a, b: string): int =
  ## The largest per-channel difference of two `#rrggbb` colours.
  for i in 0 .. 2:
    result = max(result, abs(parseHexInt(a[1 + 2 * i .. 2 + 2 * i]) -
                             parseHexInt(b[1 + 2 * i .. 2 + 2 * i])))

proc regionsOf(node: JsonNode): RegionSet =
  for name, r in node.pairs:
    result[name] = Rect(x: r["x"].getFloat, y: r["y"].getFloat,
                        w: r["w"].getFloat, h: r["h"].getFloat,
                        index: r{"index"}.getInt(-1))

proc normalised(r: Rect; name: string; vw, vh: int): PaneRect =
  ## Hundredths of the viewport, rounded as PLAT-35's GPUI answer path rounds
  ## (`gpui_layout_answers.normalise`), from whole pixels.
  proc pct(v: float; whole: int): int =
    (int(round(v)) * 100 + whole div 2) div whole
  PaneRect(pane: name, x: pct(r.x, vw), y: pct(r.y, vh), w: pct(r.w, vw), h: pct(r.h, vh))

# ---------------------------------------------------------------------------
# The judge
# ---------------------------------------------------------------------------

proc compareFills(webNode: JsonNode; gpui: RegionSet; frame: Frame;
                  judgement: var CaptureJudgement) =
  ## Every region the web side recorded a `fill` for, against the GPUI
  ## frame's pixel inside the same region of the GPUI layout.
  for name, w in webNode.pairs:
    if not w.hasKey("fill") or name notin gpui: continue
    let want = w["fill"].getStr
    let (x, y) = fillSample(gpui[name])
    if x < 0 or y < 0 or x >= frame.width or y >= frame.height: continue
    let got = hexOf(frame, x, y)
    for d in judgement.regions.mitems:
      if d.name == name:
        d.webFill = want
        d.gpuiFill = got
    if channelsApart(want, got) > FillTolerance:
      if judgement.verdict == vPass: judgement.verdict = vFill
      judgement.problems.add "region " & name & " is filled " & got & " at (" & $x &
        ", " & $y & "), the web's " & want & " (tolerance " & $FillTolerance & ")"

proc pxEdgesOf(path: string): Table[string, seq[string]] =
  ## Each declared region's `px` edges (`x`, `y`, `w`, `h`), from the one
  ## declaration both capture paths read.
  let doc = parseJson(readFile(path))
  for region in doc["regions"]:
    var edges: seq[string]
    for e in region{"px"}.getElems:
      doAssert e.getStr in ["x", "y", "w", "h"], path & ": region " &
        region["name"].getStr & ": unknown px edge " & e.getStr
      edges.add e.getStr
    if edges.len > 0: result[region["name"].getStr] = edges

let pxEdges = pxEdgesOf(regionsDeclPath)

proc edgeOf(r: Rect; edge: string): float =
  case edge
  of "x": r.x
  of "y": r.y
  of "w": r.w
  else: r.h

proc comparePixels(judgement: var CaptureJudgement) =
  ## The `px` edges of every region both sides drew, to within
  ## `PxTolerance`.
  for d in judgement.regions.mitems:
    if d.onlyOn.len > 0 or d.name notin pxEdges: continue
    d.pxEdges = pxEdges[d.name]
    for edge in d.pxEdges:
      let a = d.webPx.edgeOf(edge)
      let b = d.gpuiPx.edgeOf(edge)
      if abs(a - b) > PxTolerance:
        if judgement.verdict == vPass: judgement.verdict = vPixels
        judgement.problems.add "region " & d.name & ": " & edge & " is " &
          formatFloat(b, ffDecimal, 1) & "px in GPUI, " & formatFloat(a, ffDecimal, 1) &
          "px on the web (tolerance " & $int(PxTolerance) & "px)"

proc menuHangProblems(side: string; regions: RegionSet; vw: int): seq[string] =
  ## The initiative bar's `+N` menu, where one side drew it open, against
  ## the place hanging it from that side's own chip gives it: its right
  ## edge on the chip's, shifted only as far as the viewport requires.
  if "bar-overflow-menu" notin regions: return
  if "bar-overflow" notin regions:
    return @[side & " draws the +N menu with no +N chip"]
  let chip = regions["bar-overflow"]
  let menu = regions["bar-overflow-menu"]
  let want = max(0.0, min(chip.x + chip.w - menu.w, float(vw) - menu.w))
  if abs(menu.x - want) > HangTolerancePx:
    result.add side & " draws the +N menu at x " & formatFloat(menu.x, ffDecimal, 1) &
      " to " & formatFloat(menu.x + menu.w, ffDecimal, 1) & ", not hanging from its chip (" &
      formatFloat(chip.x, ffDecimal, 1) & " to " & formatFloat(chip.x + chip.w, ffDecimal, 1) &
      "): x " & formatFloat(want, ffDecimal, 1) & " in a " & $vw & "px viewport (tolerance " &
      $int(HangTolerancePx) & "px)"

proc compareHangs(web, gpui: RegionSet; vw: int; judgement: var CaptureJudgement) =
  ## The `+N` menu's place on both sides, each against its own chip.
  for problem in menuHangProblems("GPUI", gpui, vw) & menuHangProblems("the web", web, vw):
    if judgement.verdict == vPass: judgement.verdict = vHang
    judgement.problems.add problem

proc compareRegions(web, gpui: RegionSet; vw, vh: int;
                    judgement: var CaptureJudgement) =
  ## PLAT-35's comparator over the two answers; every region's deltas are
  ## kept for the report, whatever the verdict.
  var webRects, gpuiRects: seq[PaneRect]
  var names: seq[string]
  for n in web.keys: names.add n
  for n in gpui.keys:
    if n notin web: names.add n
  names.sort()
  for n in names:
    var d = RegionDelta(name: n)
    if n in web:
      d.webPx = web[n]
      d.web = normalised(web[n], n, vw, vh)
      webRects.add d.web
    if n in gpui:
      d.gpuiPx = gpui[n]
      d.gpui = normalised(gpui[n], n, vw, vh)
      gpuiRects.add d.gpui
    if n notin gpui: d.onlyOn = "web"
    elif n notin web: d.onlyOn = "gpui"
    else:
      d.within = compareAnswer(lqPaneRectangles, formatPaneRectangles(@[d.web]),
                               formatPaneRectangles(@[d.gpui])).verdict in
                 {cvEqual, cvWithinTolerance}
      d.sameRow = web[n].index == gpui[n].index
    judgement.regions.add d
  for d in judgement.regions:
    if d.onlyOn.len == 0 and not d.sameRow:
      judgement.verdict = vLayout
      judgement.problems.add "region " & d.name & " is row " & $d.webPx.index &
        " of its list on the web and row " & $d.gpuiPx.index & " in GPUI"
  let c = compareAnswer(lqPaneRectangles, formatPaneRectangles(webRects),
                        formatPaneRectangles(gpuiRects))
  if c.verdict notin {cvEqual, cvWithinTolerance}:
    judgement.verdict = vLayout
    for d in judgement.regions:
      if d.onlyOn.len > 0:
        judgement.problems.add "region " & d.name & " is drawn only on " & d.onlyOn
      elif not d.within:
        judgement.problems.add "region " & d.name & ": web " &
          formatPaneRectangles(@[d.web]) & " vs gpui " & formatPaneRectangles(@[d.gpui]) &
          " (hundredths of " & $vw & "x" & $vh & "; tolerance " &
          $PaneRectangleTolerancePp & ")"
    if judgement.problems.len == 0:
      judgement.problems.add c.detail

proc judgeCapture(id: string; dir: string; webCapture: JsonNode;
                  vw, vh: int): CaptureJudgement =
  ## Everything this suite asserts about ONE capture, as a verdict and the
  ## reasons for it. The real run and the negative controls both call this.
  result = CaptureJudgement(id: id, verdict: vPass)
  let ppm = dir / (id & ".ppm")
  let png = dir / (id & ".png")
  let regionsPath = dir / (id & ".regions.json")
  if not fileExists(ppm) or not fileExists(png):
    result.verdict = vMissing
    result.problems.add "no frame (" & (if fileExists(ppm): png else: ppm) & ")"
    return
  var frame: Frame
  try:
    frame = readPpm(ppm)
  except ValueError as e:
    result.verdict = vMissing
    result.problems.add e.msg
    return
  if frame.width != vw or frame.height != vh:
    result.verdict = vMissing
    result.problems.add "the frame is " & $frame.width & "x" & $frame.height &
                        ", not the story's " & $vw & "x" & $vh
    return
  if pngSize(png) != (vw, vh):
    result.verdict = vMissing
    result.problems.add png & " is not a " & $vw & "x" & $vh & " PNG"
    return
  if distinctColours(frame, Rect(x: 0, y: 0, w: float(vw), h: float(vh)), 2) < 2:
    result.verdict = vBlank
    result.problems.add "the frame is a single colour"
    return
  if not fileExists(regionsPath):
    result.verdict = vNoRegions
    result.problems.add "no regions file " & regionsPath
    return
  let gpuiDoc = parseJson(readFile(regionsPath))
  if gpuiDoc["viewport"]["width"].getInt != vw or gpuiDoc["viewport"]["height"].getInt != vh:
    result.verdict = vNoRegions
    result.problems.add "the regions were measured in another viewport"
    return
  let gpui = regionsOf(gpuiDoc["regions"])
  if gpui.len == 0:
    result.verdict = vNoRegions
    result.problems.add "the window reported no region at all"
    return
  for name, r in gpui:
    # A region laid out wholly past the window (a strip whose lines run
    # below it, as the web page scrolls) has no pixels to be blank.
    if r.x >= float(vw) or r.y >= float(vh) or r.x + r.w <= 0 or r.y + r.h <= 0: continue
    if distinctColours(frame, r, 2) < 2:
      result.verdict = vBlank
      result.problems.add "region " & name & " is a single colour in the frame"
  if result.verdict != vPass: return
  if webCapture.isNil:
    result.verdict = vNoWeb
    result.problems.add "the web record has no capture " & id
    return
  compareRegions(regionsOf(webCapture["regions"]), gpui, vw, vh, result)
  comparePixels(result)
  compareFills(webCapture["regions"], gpui, frame, result)
  compareHangs(regionsOf(webCapture["regions"]), gpui, vw, result)

# ---------------------------------------------------------------------------
# The expected captures
# ---------------------------------------------------------------------------

type Expected = object
  id: string
  width, height: int

proc agentHarborSection(): CodeTracerStorySection =
  for s in codeTracerStorySections():
    if s.title == SectionTitle: return s

proc expectedCaptures(section: CodeTracerStorySection): seq[Expected] =
  for story in section.stories:
    let sid = storybookId(section, story)
    doAssert sid.startsWith(StoryIdPrefix), sid
    let view = ViewPrefix & sid[StoryIdPrefix.len .. ^1]
    for (size, w, h) in Sizes:
      for theme in Themes:
        result.add Expected(id: view & "-" & size & "-" & theme, width: w, height: h)

proc loadWebRecord(): JsonNode =
  if not fileExists(webRecordPath): return newJObject()
  parseJson(readFile(webRecordPath)){"captures"}

# ---------------------------------------------------------------------------
# The report
# ---------------------------------------------------------------------------

proc toJson(d: RegionDelta): JsonNode =
  result = %*{"region": d.name, "within": d.within}
  if d.onlyOn.len > 0: result["onlyOn"] = %d.onlyOn
  if d.onlyOn != "gpui":
    result["web"] = %*{"pp": [d.web.x, d.web.y, d.web.w, d.web.h],
                       "px": [d.webPx.x, d.webPx.y, d.webPx.w, d.webPx.h]}
  if d.onlyOn != "web":
    result["gpui"] = %*{"pp": [d.gpui.x, d.gpui.y, d.gpui.w, d.gpui.h],
                        "px": [d.gpuiPx.x, d.gpuiPx.y, d.gpuiPx.w, d.gpuiPx.h]}
  if d.webFill.len > 0:
    result["fill"] = %*{"web": d.webFill, "gpui": d.gpuiFill}
  if d.pxEdges.len > 0:
    result["pxEdges"] = %d.pxEdges
  if d.webPx.index >= 0 or d.gpuiPx.index >= 0:
    result["index"] = %*{"web": d.webPx.index, "gpui": d.gpuiPx.index}
  if d.onlyOn.len == 0:
    result["deltaPp"] = %[d.gpui.x - d.web.x, d.gpui.y - d.web.y,
                          d.gpui.w - d.web.w, d.gpui.h - d.web.h]

proc writeReport(judgements: seq[CaptureJudgement]) =
  createDir(reportDir)
  var captures = newJArray()
  var md = "# CTF-P1b: GPUI captures against the web layout\n\n" &
           "Tolerance: " & $PaneRectangleTolerancePp &
           " hundredths of the viewport per edge (PLAT-35 `PaneRectangleTolerancePp`), " &
           "and " & $int(PxTolerance) &
           "px on the edges a region declares in `px`.\n\n" &
           "| capture | verdict | regions outside the tolerance |\n|---|---|---|\n"
  var passed = 0
  for j in judgements:
    if j.verdict == vPass: inc passed
    var regions = newJArray()
    for d in j.regions: regions.add toJson(d)
    captures.add %*{"id": j.id, "verdict": $j.verdict, "problems": j.problems,
                    "regions": regions}
    md.add "| " & j.id & " | " & $j.verdict & " | " &
           j.problems.join("; ").replace("|", "\\|") & " |\n"
  writeFile(reportDir / "report.json", pretty(%*{
    "tolerancePp": PaneRectangleTolerancePp, "tolerancePx": PxTolerance,
    # Repository-relative, so a copied report names no machine's paths.
    "gpuiDir": relativePath(gpuiDir, repoRoot),
    "webRecord": relativePath(webRecordPath, repoRoot), "passed": passed, "total": judgements.len,
    "captures": captures}) & "\n")
  writeFile(reportDir / "report.md", md)

# ---------------------------------------------------------------------------
# The suites
# ---------------------------------------------------------------------------

let section = agentHarborSection()

suite "CTF-P1b: the GPUI captures lay the stories out as the web does":
  test "test_ctf_p1b_gpui_capture_matches_web_layout":
    check section.stories.len >= MinimumStories
    let web = loadWebRecord()
    let expected = expectedCaptures(section)
    var judgements: seq[CaptureJudgement]
    for e in expected:
      judgements.add judgeCapture(e.id, gpuiDir, web{e.id}, e.width, e.height)
    writeReport(judgements)
    var failing: seq[string]
    for j in judgements:
      if j.verdict != vPass:
        failing.add j.id & " [" & $j.verdict & "]: " & j.problems.join("; ")
    echo "CTF-P1b layout: ", judgements.len - failing.len, " of ", judgements.len,
         " captures within the tolerance; report in ", reportDir / "report.md"
    for f in failing: echo "  FAIL ", f
    check expected.len == section.stories.len * Sizes.len * Themes.len
    check failing.len == 0

suite "CTF-P1b: the layout judge fails what it must (negative controls)":
  # One real capture, copied into a scratch directory and planted with each
  # defect in turn. Chosen from the expected set so the controls need nothing
  # the real run does not; a missing capture fails the control loudly rather
  # than skipping it.
  let web = loadWebRecord()
  var source: Expected
  for e in expectedCaptures(section):
    if e.id == "agent-harbor-initiative-tabs-popup-laptop-dark": source = e
  let scratch = getTempDir() / "ctf-p1b-layout-controls-" & $getCurrentProcessId()

  proc plant(): string =
    removeDir(scratch)
    createDir(scratch)
    for ext in [".ppm", ".png", ".regions.json"]:
      copyFile(gpuiDir / (source.id & ext), scratch / (source.id & ext))
    scratch

  proc shifted(dir: string; byPp: int) =
    ## Moves the GPUI side's `surface` right by `byPp` hundredths of the
    ## viewport, in pixels, past whatever rounding the web side has.
    let path = dir / (source.id & ".regions.json")
    var doc = parseJson(readFile(path))
    let webX = web{source.id}{"regions"}{"surface"}{"x"}.getFloat
    let pp = normalised(Rect(x: webX), "surface", source.width, source.height).x
    let x = float((pp + byPp) * source.width) / 100.0
    doc["regions"]["surface"]["x"] = %x
    writeFile(path, $doc)

  test "the capture the controls plant into passes untouched":
    check source.id.len > 0
    check fileExists(gpuiDir / (source.id & ".ppm"))
    let j = judgeCapture(source.id, plant(), web{source.id}, source.width, source.height)
    check j.verdict == vPass

  test "a blank capture fails":
    let dir = plant()
    let f = readPpm(dir / (source.id & ".ppm"))
    writeFile(dir / (source.id & ".ppm"), "P6\n" & $f.width & " " & $f.height &
              "\n255\n" & repeat('\x20', f.width * f.height * 3))
    let j = judgeCapture(source.id, dir, web{source.id}, source.width, source.height)
    check j.verdict == vBlank

  test "a missing capture fails":
    let dir = plant()
    removeFile(dir / (source.id & ".ppm"))
    check judgeCapture(source.id, dir, web{source.id}, source.width,
                       source.height).verdict == vMissing
    let dir2 = plant()
    removeFile(dir2 / (source.id & ".png"))
    check judgeCapture(source.id, dir2, web{source.id}, source.width,
                       source.height).verdict == vMissing
    let dir3 = plant()
    removeFile(dir3 / (source.id & ".regions.json"))
    check judgeCapture(source.id, dir3, web{source.id}, source.width,
                       source.height).verdict == vNoRegions
    check judgeCapture(source.id, plant(), nil, source.width,
                       source.height).verdict == vNoWeb

  test "a region shifted beyond the tolerance fails, one shifted by it passes":
    let dir = plant()
    shifted(dir, PaneRectangleTolerancePp + 1)
    let beyond = judgeCapture(source.id, dir, web{source.id}, source.width, source.height)
    check beyond.verdict == vLayout
    check beyond.problems.len > 0 and "region surface" in beyond.problems[0]
    let dir2 = plant()
    shifted(dir2, PaneRectangleTolerancePp)
    check judgeCapture(source.id, dir2, web{source.id}, source.width,
                       source.height).verdict == vPass


  test "a wrong fill behind the active tab fails, and so does a wrong expected one":
    # The GPUI side drawn in another role: the active tab's region painted
    # with the ground colour of the bar around it.
    let dir = plant()
    let path = dir / (source.id & ".ppm")
    var f = readPpm(path)
    let r = regionsOf(parseJson(readFile(dir / (source.id & ".regions.json")))["regions"])["active-tab"]
    let ground = f.rgb[0 .. 2]   # the window's top-left pixel: the bar's ground
    for y in int(r.y) ..< int(r.y + r.h):
      for x in int(r.x) ..< int(r.x + r.w):
        let o = (y * f.width + x) * 3
        if f.rgb[o .. o + 2] != ground and hexOf(f, x, y) == hexOf(f, fillSample(r).x, fillSample(r).y):
          f.rgb[o .. o + 2] = ground
    writeFile(path, "P6\n" & $f.width & " " & $f.height & "\n255\n" & f.rgb)
    let wrong = judgeCapture(source.id, dir, web{source.id}, source.width, source.height)
    check wrong.verdict == vFill
    check wrong.problems.len > 0 and "region active-tab is filled" in wrong.problems[0]
    # The web record naming a different colour: the same capture, untouched,
    # must then fail too (the comparison is not one-sided).
    var other = web{source.id}.copy
    check other{"regions"}{"active-tab"}{"fill"} != nil
    other["regions"]["active-tab"]["fill"] = %"#ff0000"
    check judgeCapture(source.id, plant(), other, source.width, source.height).verdict == vFill

  test "a fill one unit off passes, one exactly two units off fails":
    # The palette holds roles two units apart (`surface/base/card` #262626
    # and `base/panel` #282828), so a fill two off must be told apart from
    # the right one. The expected colour is set from the GPUI frame's own
    # pixel, so this measures the judge, not today's views.
    let dir = plant()
    let f = readPpm(dir / (source.id & ".ppm"))
    let r = regionsOf(parseJson(readFile(dir / (source.id & ".regions.json")))["regions"])["active-tab"]
    let (x, y) = fillSample(r)
    let drawn = hexOf(f, x, y)
    proc offBy(hex: string; units: int): string =
      ## Every channel `units` away, towards whichever end has room.
      result = "#"
      for i in 0 .. 2:
        let c = parseHexInt(hex[1 + 2 * i .. 2 + 2 * i])
        result.add toHex(if c + units <= 255: c + units else: c - units, 2).toLowerAscii
    check channelsApart(drawn, offBy(drawn, 1)) == 1
    check channelsApart(drawn, offBy(drawn, 2)) == 2
    var oneOff = web{source.id}.copy
    oneOff["regions"]["active-tab"]["fill"] = %offBy(drawn, 1)
    check judgeCapture(source.id, dir, oneOff, source.width, source.height).verdict == vPass
    var twoOff = web{source.id}.copy
    twoOff["regions"]["active-tab"]["fill"] = %offBy(drawn, 2)
    let j = judgeCapture(source.id, dir, twoOff, source.width, source.height)
    check j.verdict == vFill
    check j.problems.len > 0 and "region active-tab is filled" in j.problems[0]

  test "a px edge one pixel past the tolerance fails, one at it passes":
    # A region the declaration compares in pixels, its GPUI width set from
    # the web's: off by exactly `PxTolerance` it passes (the pane rectangle
    # moves by under a hundredth), one pixel more fails by name.
    proc widened(by: float): CaptureJudgement =
      let dir = plant()
      let path = dir / (source.id & ".regions.json")
      var doc = parseJson(readFile(path))
      check doc{"regions"}{"inbox-position"} != nil
      check "inbox-position" in pxEdges and "w" in pxEdges["inbox-position"]
      if doc{"regions"}{"inbox-position"}.isNil: return CaptureJudgement(verdict: vMissing)
      let webW = web{source.id}{"regions"}{"inbox-position"}{"w"}.getFloat
      doc["regions"]["inbox-position"]["w"] = %(webW + by)
      writeFile(path, $doc)
      judgeCapture(source.id, dir, web{source.id}, source.width, source.height)
    check widened(PxTolerance).verdict == vPass
    let beyond = widened(PxTolerance + 1)
    check beyond.verdict == vPixels
    var named = false
    for problem in beyond.problems:
      if "region inbox-position: w is" in problem: named = true
    check named

  test "a row region that is another row on the GPUI side fails":
    # The popup's last session line, reported one row further down: the
    # same list, a different row, whatever its position.
    let dir = plant()
    let path = dir / (source.id & ".regions.json")
    var doc = parseJson(readFile(path))
    check doc{"regions"}{"session-line-last"} != nil
    check web{source.id}{"regions"}{"session-line-last"}{"index"} != nil
    doc["regions"]["session-line-last"]["index"] =
      %(doc["regions"]["session-line-last"]["index"].getInt + 1)
    writeFile(path, $doc)
    let j = judgeCapture(source.id, dir, web{source.id}, source.width, source.height)
    check j.verdict == vLayout
    var named = false
    for problem in j.problems:
      if "region session-line-last is row" in problem: named = true
    check named

  # The `+N` menu's hang, on a capture of each kind: hanging from its chip
  # (the laptop menu over a panel) and stopped by the window's left edge
  # (the narrow bar's menu near it). Each is moved where a view that did not
  # hang it would draw it: right-aligned under the bar, as the strip's menu
  # is, and hung from the chip with the window's edge ignored.
  proc plantOf(id: string): string =
    removeDir(scratch)
    createDir(scratch)
    for ext in [".ppm", ".png", ".regions.json"]:
      copyFile(gpuiDir / (id & ext), scratch / (id & ext))
    scratch

  proc movedMenu(id: string; vw: int; toX: proc(chip, menu: Rect): float): CaptureJudgement =
    let dir = plantOf(id)
    let path = dir / (id & ".regions.json")
    var doc = parseJson(readFile(path))
    let regions = regionsOf(doc["regions"])
    check "bar-overflow-menu" in regions and "bar-overflow" in regions
    if "bar-overflow-menu" notin regions or "bar-overflow" notin regions:
      return CaptureJudgement(verdict: vMissing)
    doc["regions"]["bar-overflow-menu"]["x"] = %toX(regions["bar-overflow"],
                                                    regions["bar-overflow-menu"])
    writeFile(path, $doc)
    judgeCapture(id, dir, web{id}, vw, 900)

  proc namesHang(j: CaptureJudgement): bool =
    for problem in j.problems:
      if "GPUI draws the +N menu" in problem and "not hanging from its chip" in problem:
        return true

  const Hung = "agent-harbor-initiative-tabs-overflow-menu-over-panel-laptop-dark"
  const Stopped = "agent-harbor-initiative-tabs-overflow-menu-near-left-sidebar-dark"

  test "the +N menu's captures the controls plant into pass untouched":
    check judgeCapture(Hung, plantOf(Hung), web{Hung}, 1440, 900).verdict == vPass
    check judgeCapture(Stopped, plantOf(Stopped), web{Stopped}, 360, 900).verdict == vPass

  test "a +N menu right-aligned under the bar, not hung from its chip, fails":
    # Asked of the hang check itself: moved that far, the region lies over
    # nothing but the panel's ground in the frame, and the judge stops at
    # that (a blank region) before it reaches the hang.
    let regions = regionsOf(parseJson(readFile(plantOf(Hung) / (Hung & ".regions.json")))["regions"])
    check "bar-overflow-menu" in regions and "bar-overflow" in regions
    if "bar-overflow-menu" in regions:
      var moved = regions
      moved["bar-overflow-menu"].x = 1440.0 - 12.0 - moved["bar-overflow-menu"].w
      check menuHangProblems("GPUI", regions, 1440).len == 0
      let problems = menuHangProblems("GPUI", moved, 1440)
      check problems.len == 1 and "not hanging from its chip" in problems.join(" ")
    check movedMenu(Hung, 1440, proc(chip, menu: Rect): float =
      1440.0 - 12.0 - menu.w).verdict != vPass

  test "a +N menu one pixel past the tolerance off its chip fails, one at it passes":
    let at = movedMenu(Hung, 1440, proc(chip, menu: Rect): float =
      chip.x + chip.w - menu.w + HangTolerancePx)
    check at.verdict == vPass
    let beyond = movedMenu(Hung, 1440, proc(chip, menu: Rect): float =
      chip.x + chip.w - menu.w + HangTolerancePx + 1.0)
    check beyond.verdict == vHang
    check namesHang(beyond)

  test "a +N menu hung past the window's left edge, not stopped by it, fails":
    let j = movedMenu(Stopped, 360, proc(chip, menu: Rect): float = chip.x + chip.w - menu.w)
    check j.verdict != vPass
    check namesHang(j)
    removeDir(scratch)
