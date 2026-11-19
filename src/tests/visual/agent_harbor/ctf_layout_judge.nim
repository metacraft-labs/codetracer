## ctf_layout_judge.nim — CTF-P1b's layout judge: **does a GPUI capture of
## an Agent Harbor story lay its parts out where the web capture of the same
## story does?** One judge, read by every test that compares the two
## renderers' captures:
##
##   * `test_ctf_p1b_gpui_capture_matches_web_layout.nim` (CTF-P1b): every
##     story at its first frame, against `agent-harbor-web-regions.json`;
##   * `test_ctf_p1c_gpui_capture_matches_web_layout_at_moments.nim`
##     (CTF-P1c): every playback story at each named moment of its scenario,
##     against `agent-harbor-web-regions-at-moments.json`.
##
## What it asserts, and why each tolerance is what it is, is written out in
## the CTF-P1b test's header and beside each constant below; the tolerances
## are this module's, so no test can hold the captures to another. Not a
## `test_*` file: it runs only as part of the tests that import it.
##
## Added with CTF-P1c: a region the declaration marks `elision` is a line of
## text, and each side reports whether its words are cut (`cut`). Under
## `same` the two must agree; under `never` neither may be cut; a side that
## draws the region and does not answer fails (verdict `cut`). The boxes
## cannot show this: GPUI cut the initiative bar's active title
## ("Telemetry upload retri…") in a box 0.2px narrower than the web's, which
## drew it whole, well within every tolerance above. No tolerance changed.
##
## Added with CTF-P1c round 3 (D6): the GPUI window lists every text it
## drew cut (`drawnCuts`, isonim-gpui's `drawnText`), and none may keep a
## space or a separator before its "…" (`danglesBeforeEllipsis`, the views'
## one rule for a cut); a regions file without the list fails too (verdict
## `cut`), so the check cannot pass by being skipped. The web's cut texts
## are held to the same rule by the StoryBook render check.
##
## Trap 13 / §29 (`Verification-Harness-Traps.md`): every helper returns what
## it found; only the test bodies `check`.

import std/[algorithm, json, math, os, sets, strutils, tables]

import ../../../common/view_vocabulary/layout_questions
import ../../../frontend/stories/codetracer_stories
import ../../../../tools/stories/emit_storybook_stories
from ../../../frontend/viewmodel/views/agent_harbor_words import danglesBeforeEllipsis

export layout_questions, codetracer_stories, emit_storybook_stories

const
  SectionTitle* = "CodeTracer/Agent Harbor"
  StoryIdPrefix* = "codetracer-agent-harbor--"
  ViewPrefix* = "agent-harbor-"
  Sizes* = [("laptop", 1440, 900), ("sidebar", 360, 900)]
    ## The design brief's laptop and narrow sizes (`capture-storybook.mjs`'s
    ## `laptop` and `sidebar`).
  PanelSize* = ("panel", 760, 640)
    ## The brief's `panel` size, at which the session activity timeline's
    ## stories are also captured (the timeline is a panel; `sizesOf`).
  Themes* = ["dark", "light"]
  FillTolerance* = 1
    ## Per channel, between the GPUI frame's pixel and the colour the browser
    ## composites: one unit, for the rounding of a translucent fill blended
    ## in GPUI's arithmetic rather than the browser's (the selected
    ## initiative's 28% tint). Every fill measured so far is exact. It is no
    ## wider because the palette holds roles TWO units apart
    ## (`surface/base/card` #262626 against `base/panel` #282828): a
    ## tolerance of 2 or more could not tell those apart.
  MinimumStories* = 59
    ## The section's stories at CTF-P2a's landing; a floor, so a declaration
    ## that lost its stories cannot pass by expecting nothing.
  HangTolerancePx* = 1.0
    ## Between where the `+N` menu is and where hanging it from its chip
    ## puts it, on one side. The browser measures its chip and places the
    ## menu in fractions of a pixel; GPUI places it where its own Flexbox
    ## shrink in whole pixels (`fitWidths`) says the chip ends, which its
    ## layout can round a pixel the other way (measured: the chip ending at
    ## 982 and the menu at 981 on the laptop `overflow-menu-over-panel`).
  HungMenus* = [("bar-overflow-menu", "bar-overflow", "the +N menu"),
               ("strip-overflow-menu", "strip-overflow", "the session strip's +N menu")]
    ## Each `+N` menu that hangs from its chip: its region, its chip's
    ## region, and how a problem names it.
  PxTolerance* = 2.0
    ## Per edge, in pixels, for the edges a region declares in `px`, ON TOP
    ## of the pane-rectangle comparison (which stays as it is): the browser
    ## lays out in fractions of a pixel and the GPUI views in whole ones, and
    ## the two set a text's width a pixel apart (kerning and rounding). Two
    ## hundredths of the laptop viewport are 29px, wider than any one tab,
    ## line pitch or inset these regions exist to hold.

let repoRoot* = currentSourcePath().parentDir.parentDir.parentDir.parentDir.parentDir
let regionsDeclPath* = getEnv("CTF_P1B_REGIONS",
                              repoRoot / "src" / "tests" / "visual" / "agent-harbor-regions.json")
  ## The one region declaration both capture paths, and every judgement
  ## here, read.

type
  Rect* = object
    x*, y*, w*, h*: float
    index*: int
      ## A row region's position among its list's visible rows on that
      ## side (`"pick"` in the declaration); -1 for any other region.

  RegionSet* = OrderedTable[string, Rect]

  Frame* = object
    width*, height*: int
    rgb*: string

  Verdict* = enum
    vPass = "pass"
    vMissing = "missing"
    vBlank = "blank"
    vNoRegions = "no-regions"
    vNoWeb = "no-web-capture"
    vLayout = "layout"
    vFill = "fill"
    vPixels = "pixels"
    vHang = "hang"
    vCut = "cut"

  RegionDelta* = object
    name*: string
    web*, gpui*: PaneRect       ## hundredths of the viewport
    webPx*, gpuiPx*: Rect
    onlyOn*: string             ## "web" / "gpui" when the other side has none
    within*: bool
    sameRow*: bool              ## a row region: both sides picked the same row
    webFill*, gpuiFill*: string ## a `fill` region's background, `#rrggbb`
    pxEdges*: seq[string]       ## the edges compared in pixels (`px`)

  CaptureJudgement* = object
    id*: string
    verdict*: Verdict
    problems*: seq[string]
    regions*: seq[RegionDelta]

# ---------------------------------------------------------------------------
# Reading the captures
# ---------------------------------------------------------------------------

proc readPpm*(path: string): Frame =
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

proc pngSize*(path: string): tuple[w, h: int] =
  ## The PNG's IHDR size (RFC 2083 §4.1.1); (-1, -1) for a file that is not
  ## a PNG.
  let s = readFile(path)
  if s.len < 24 or s[0 ..< 8] != "\x89PNG\r\n\x1A\n" or s[12 ..< 16] != "IHDR":
    return (-1, -1)
  proc be32(o: int): int =
    (ord(s[o]) shl 24) or (ord(s[o + 1]) shl 16) or (ord(s[o + 2]) shl 8) or ord(s[o + 3])
  (be32(16), be32(20))

proc distinctColours*(f: Frame; r: Rect; atMost: int): int =
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

proc hexOf*(f: Frame; x, y: int): string =
  let o = (y * f.width + x) * 3
  "#" & toHex(ord(f.rgb[o]), 2).toLowerAscii & toHex(ord(f.rgb[o + 1]), 2).toLowerAscii &
    toHex(ord(f.rgb[o + 2]), 2).toLowerAscii

proc fillSample*(r: Rect): tuple[x, y: int] =
  ## Where a region's background is read: 4px in from its right edge, half
  ## way down -- inside the element's padding (every `fill` region has at
  ## least 8px of it on the right), clear of its text and of the left-edge
  ## focus bar, and inside its rounded corners.
  (int(floor(r.x + r.w)) - 4, int(floor(r.y + r.h / 2)))

proc channelsApart*(a, b: string): int =
  ## The largest per-channel difference of two `#rrggbb` colours.
  for i in 0 .. 2:
    result = max(result, abs(parseHexInt(a[1 + 2 * i .. 2 + 2 * i]) -
                             parseHexInt(b[1 + 2 * i .. 2 + 2 * i])))

proc regionsOf*(node: JsonNode): RegionSet =
  for name, r in node.pairs:
    result[name] = Rect(x: r["x"].getFloat, y: r["y"].getFloat,
                        w: r["w"].getFloat, h: r["h"].getFloat,
                        index: r{"index"}.getInt(-1))

proc normalised*(r: Rect; name: string; vw, vh: int): PaneRect =
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

proc pxEdgesOf*(path: string): Table[string, seq[string]] =
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

let pxEdges* = pxEdgesOf(regionsDeclPath)

proc elisionOf*(path: string): Table[string, string] =
  ## Each declared region's `elision` rule: `same` (its text cut on both
  ## sides or on neither) or `never` (cut on neither).
  let doc = parseJson(readFile(path))
  for region in doc["regions"]:
    let rule = region{"elision"}.getStr
    if rule.len > 0:
      doAssert rule in ["same", "never"], path & ": region " &
        region["name"].getStr & ": unknown elision " & rule
      result[region["name"].getStr] = rule

let elisionRules* = elisionOf(regionsDeclPath)

proc elisionProblems*(web, gpui: JsonNode): seq[string] =
  ## A declared `elision` region drawn on both sides: whether its text is cut
  ## (`cut`, each side's own answer) against its rule. A box can be within
  ## every tolerance of the web's and still cut its words where the web's does
  ## not: GPUI elides a title 0.2px short of its words. A side that draws the
  ## region and gives no answer fails too, so the check cannot pass by being
  ## skipped.
  for name, rule in elisionRules:
    let w = web{name}
    let g = gpui{name}
    if w.isNil or g.isNil: continue
    if w{"cut"}.isNil or g{"cut"}.isNil:
      result.add "region " & name & ": " &
        (if w{"cut"}.isNil: "the web" else: "GPUI") & " gave no answer whether its text is cut"
      continue
    let (wc, gc) = (w["cut"].getBool, g["cut"].getBool)
    if rule == "never" and (wc or gc):
      result.add "region " & name & ": its text is cut on " &
        (if wc and gc: "both sides" elif wc: "the web" else: "GPUI") & ", and must not be"
    elif rule == "same" and wc != gc:
      result.add "region " & name & ": its text is cut " &
        (if wc: "on the web and whole in GPUI" else: "in GPUI and whole on the web")

proc compareElision(web, gpui: JsonNode; judgement: var CaptureJudgement) =
  for problem in elisionProblems(web, gpui):
    if judgement.verdict == vPass: judgement.verdict = vCut
    judgement.problems.add problem

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

proc menuHangProblems*(side: string; regions: RegionSet; vw: int): seq[string] =
  ## Each `+N` menu (`HungMenus`), where one side drew it open, against the
  ## place hanging it from that side's own chip gives it: its right edge on
  ## the chip's, shifted only as far as the viewport requires.
  for (menuRegion, chipRegion, what) in HungMenus:
    if menuRegion notin regions: continue
    if chipRegion notin regions:
      result.add side & " draws " & what & " with no +N chip"
      continue
    let chip = regions[chipRegion]
    let menu = regions[menuRegion]
    let want = max(0.0, min(chip.x + chip.w - menu.w, float(vw) - menu.w))
    if abs(menu.x - want) > HangTolerancePx:
      result.add side & " draws " & what & " at x " & formatFloat(menu.x, ffDecimal, 1) &
        " to " & formatFloat(menu.x + menu.w, ffDecimal, 1) & ", not hanging from its chip (" &
        formatFloat(chip.x, ffDecimal, 1) & " to " & formatFloat(chip.x + chip.w, ffDecimal, 1) &
        "): x " & formatFloat(want, ffDecimal, 1) & " in a " & $vw & "px viewport (tolerance " &
        $int(HangTolerancePx) & "px)"

proc compareHangs(web, gpui: RegionSet; vw: int; judgement: var CaptureJudgement) =
  ## Each `+N` menu's place on both sides, each against its own chip.
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

proc drawnCutProblems*(gpuiDoc: JsonNode): seq[string] =
  ## The GPUI window's cut texts (`drawnCuts`) against the views' rule: no
  ## space or separator before the "…". A regions file that does not list
  ## them fails, so the check cannot pass by being skipped.
  let cuts = gpuiDoc{"drawnCuts"}
  if cuts.isNil or cuts.kind != JArray:
    return @["the GPUI regions file does not list the texts it drew cut (drawnCuts)"]
  for cut in cuts:
    if danglesBeforeEllipsis(cut.getStr):
      result.add "GPUI draws the cut text '" & cut.getStr &
                 "' with a space or a separator before its \"…\""

proc cutTopLineProblems*(side: string; regions: RegionSet): seq[string] =
  ## A list drawn from its first line (the session activity timeline's
  ## static stories open at the top of their list) cuts no line at its top
  ## edge: the first line drawn wholly inside it (`timeline-line-first`,
  ## counted `within` the list) starts on the list's top edge. A line the
  ## edge cuts in half is not counted, so the first whole one starts lower.
  if "timeline" notin regions or "timeline-line-first" notin regions: return
  let list = regions["timeline"]
  let first = regions["timeline-line-first"]
  if first.y > list.y + 0.5:
    result.add side & ": the list's top edge (y " & $list.y & ") cuts a line; its first " &
               "whole line starts at y " & $first.y

proc judgeCapture*(id: string; dir: string; webCapture: JsonNode;
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
  compareElision(webCapture["regions"], gpuiDoc["regions"], result)
  for problem in drawnCutProblems(gpuiDoc):
    if result.verdict == vPass: result.verdict = vCut
    result.problems.add problem

# ---------------------------------------------------------------------------
# The expected captures
# ---------------------------------------------------------------------------

type Expected* = object
  id*: string
  width*, height*: int

proc agentHarborSection*(): CodeTracerStorySection =
  for s in codeTracerStorySections():
    if s.title == SectionTitle: return s

proc sizesOf*(story: CodeTracerStory): seq[(string, int, int)] =
  ## The sizes a story is captured at: laptop and sidebar, and panel for the
  ## session activity timeline.
  result = @Sizes
  if story.surface == "agent-harbor-session-activity": result.add PanelSize

proc expectedCaptures*(section: CodeTracerStorySection): seq[Expected] =
  for story in section.stories:
    let sid = storybookId(section, story)
    doAssert sid.startsWith(StoryIdPrefix), sid
    let view = ViewPrefix & sid[StoryIdPrefix.len .. ^1]
    for (size, w, h) in sizesOf(story):
      for theme in Themes:
        result.add Expected(id: view & "-" & size & "-" & theme, width: w, height: h)

proc loadWebRecord*(webRecordPath: string): JsonNode =
  ## The `captures` of a web record (`ci/test/ctf-p1b-web-capture.sh`); an
  ## empty object when there is no record, so every capture judged against
  ## it is `vNoWeb`.
  if not fileExists(webRecordPath): return newJObject()
  parseJson(readFile(webRecordPath)){"captures"}

# ---------------------------------------------------------------------------
# The report
# ---------------------------------------------------------------------------

proc toJson*(d: RegionDelta): JsonNode =
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

proc writeReport*(judgements: seq[CaptureJudgement]; title, reportDir, gpuiDir,
                  webRecordPath: string) =
  ## `report.json` and `report.md` (headed `title`) in `reportDir`: every
  ## capture's verdict, problems and region deltas.
  createDir(reportDir)
  var captures = newJArray()
  var md = "# " & title & "\n\n" &
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
