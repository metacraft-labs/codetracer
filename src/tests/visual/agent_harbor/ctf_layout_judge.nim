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
## Added with the control center's narrow-window layout (a provisional
## design decision): THE ONE ACCEPTED DIFFERENCE,
## the sidebar fold. At the 360×900 sidebar size GPUI's control center folds
## the launch form to its one-line summary, because a GPUI window
## cannot scroll; the web keeps the whole form and lets the tab scroll. The
## judge allows exactly that fold (`launchFoldOf`, `foldedWebRegions`), and
## only where all of these hold: the capture is a control-center story or
## playback moment, it is at the sidebar size, and GPUI's own capture
## records the summary it drew (the `cc-form-summary` region, which the web
## never draws). The fold is then itself checked, on the regions and on the
## frame, and the web record is judged as it would be with the form folded:
## the launch column shorter by the height the fold frees, everything from
## the send line down moved up by that height, and the overview filling the
## tab's rest under the folded column (taller by at most that height). Every
## other check runs unchanged on that. The one region the record cannot place
## in the folded layout -- a list's last whole row, once the fold has brought
## rows into the window that the web's did not hold whole -- is left out by
## name, and only then (`foldedWebRegions`). Anywhere else a drawn summary
## is a region drawn only in GPUI, and a capture without one is judged as
## before.
##
## Trap 13 / §29 (`Verification-Harness-Traps.md`): every helper returns what
## it found; only the test bodies `check`.

import std/[algorithm, json, math, os, sequtils, sets, strutils, tables]

import ../../../common/view_vocabulary/layout_questions
import ../../../frontend/stories/codetracer_stories
import ../../../../tools/stories/emit_storybook_stories
from ../../../frontend/viewmodel/views/agent_harbor_words import danglesBeforeEllipsis
import ./ctf_held_expectation

export layout_questions, codetracer_stories, emit_storybook_stories, ctf_held_expectation

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
  FoldStoryPrefixes* = [ViewPrefix & "control-center", ViewPrefix & "status-gaze"]
    ## The captures the sidebar fold may apply to: the control center's
    ## stories and its playback story's moments, and the gaze stories, which
    ## draw the same control center over the status line.
  FoldViewport* = (360, 900)
    ## The one size it applies at: the brief's sidebar (`Sizes`). GPUI folds
    ## at the 760×640 panel size too, where no control-center story is
    ## captured; a fold anywhere else is judged as any other region.
  FoldSummaryRegion* = "cc-form-summary"
    ## The fact the fold is keyed on: the summary line GPUI draws in place of
    ## the form (`ah_control_center.launchColumn`, `data-ah-form-summary`).
    ## The web never draws one, so it is in GPUI's capture only when GPUI
    ## folded.
  FoldPartGapPx* = 8.0
    ## Between the launch column's parts (`ah_control_center.PartGapPx`):
    ## the send line starts this far under the summary, as it does under the
    ## whole form.
  FoldHostRegions* = ["surface", "playback-readout", "playback-moment", "gaze-mark"]
    ## Regions the fold never moves although the web lays them out under the
    ## send line: the story's window (`surface`), and the playback bar and
    ## the status line's gaze mark the story host draws under the tab,
    ## outside the control center.
  FoldFillRegions* = ["rows", "notice"]
    ## The parts of the overview that take what is left of it (the web's
    ## one column: the Initiatives panel's list, and the panel's loading or
    ## error notice in its place), so they grow as the overview does.
  FoldCentredRegions* = ["error-reason"]
    ## Drawn centred in a `FoldFillRegions` part (the error notice's
    ## reason): it moves down by half of what that part grows.
  FoldEdgeProbeInsetPx* = 4
    ## Where the frame is read for the launch column's foot: this far in
    ## from the column's right edge, inside its 8px side padding (`PadXPx`),
    ## so on the column's own ground and never on a field, a toggle or text.

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
    value*: string
      ## A `gpuiOnly` fact's `value` (`"gpuiValue"`): a count GPUI drew.
    count*: int
      ## A `gpuiOnly` fact's `count` (`"gpuiCount"`): how many matches GPUI
      ## laid out; -1 where not reported.

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
    vFold = "fold"
      ## GPUI's capture says it folded the launch form at the sidebar
      ## size, and the fold is not the accepted one (`launchFoldOf`).

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
    foldPx*: float
      ## The height the sidebar fold freed, in pixels, where the judge
      ## allowed it (`launchFoldOf`); 0 where it did not apply.
    heldShiftPx*: float
      ## Where the judge allowed the held overview (`heldOverviewOf`): how
      ## much higher GPUI drew the Initiatives panel than the folded web
      ## layout, for the waiting rows it counted instead of drawing.
    foldExempt*: seq[string]
      ## The regions the fold left out of the comparison, each with why
      ## (`foldedWebRegions`).

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
                        index: r{"index"}.getInt(-1), value: r{"value"}.getStr,
                        count: r{"count"}.getInt(-1))

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

proc lastWholeOf*(path: string): seq[string] =
  ## The declared regions picked as the last row drawn whole
  ## (`"pick": "last-whole"`).
  let doc = parseJson(readFile(path))
  for region in doc["regions"]:
    if region{"pick"}.getStr == "last-whole": result.add region["name"].getStr

let lastWholeRegions* = lastWholeOf(regionsDeclPath)

proc gpuiOnlyOf*(path: string): seq[string] =
  ## The declared regions that are facts of GPUI's drawing only
  ## (`"gpuiOnly": true`): read by the held overview's checks, never
  ## compared as regions, never held to the blank-region check.
  let doc = parseJson(readFile(path))
  for region in doc["regions"]:
    if region{"gpuiOnly"}.getBool: result.add region["name"].getStr

let gpuiOnlyRegions* = gpuiOnlyOf(regionsDeclPath)

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

# ---------------------------------------------------------------------------
# The sidebar fold
# ---------------------------------------------------------------------------

type LaunchFold* = object
  ## What the judge found of GPUI's folded launch form in one capture.
  applies*: bool
    ## The capture is one the fold may apply to, and GPUI recorded it.
  freedPx*: float
    ## The height the fold frees: how far above the web's send line GPUI
    ## drew its own (the parts above the form are the same in both forms,
    ## and the summary is shorter than the form by this much).
  problems*: seq[string]
    ## Each way the fold GPUI recorded is not the accepted one.

proc foldMayApply*(id: string; vw, vh: int): bool =
  ## Whether a capture is one the sidebar fold may apply to: a control-center
  ## story or playback moment, at the sidebar size. It never says GPUI
  ## folded; only GPUI's capture can (`launchFoldOf`).
  (vw, vh) == FoldViewport and
    (id.startsWith(FoldStoryPrefixes[0]) or id.startsWith(FoldStoryPrefixes[1]))

proc launchFoldOf*(id: string; web, gpui: RegionSet; frame: Frame;
                   vw, vh: int): LaunchFold =
  ## The sidebar fold in one capture, or `applies = false` where it does not
  ## apply: not a control-center capture, not the sidebar size, or no summary
  ## in GPUI's capture (its fact, `FoldSummaryRegion`). Where it applies, the
  ## fold must be the one GPUI's folded form draws, on the regions and in the
  ## frame:
  ##
  ##   * the summary lies inside the launch column, and the send line
  ##     (`composer-send`) starts `FoldPartGapPx` under it -- the summary
  ##     took the form's place, and nothing else moved in between;
  ##   * the fold frees height (the send line is above the web's);
  ##   * the launch column is shorter than the web's by exactly that height
  ##     (to `PxTolerance`): what follows the send line -- the answer, the
  ##     recent launches -- takes the same height on both sides, so the
  ##     column shrank to what the folded form needs, and no more;
  ##   * in the FRAME, the column's own ground ends where its region does:
  ##     read `FoldEdgeProbeInsetPx` in from its right edge, inside its side
  ##     padding, the pixel 2px above its foot and the pixel 2px below it
  ##     (in the 4px gap to the overview, the window's canvas) differ. A
  ##     GPUI that recorded the fold but drew the whole form draws the
  ##     column's ground on past that foot.
  ##
  ## The pixels are read at the column's foot rather than at the summary
  ## because the foot is what the fold moves: wherever the summary's box is
  ## said to be, the whole form also draws text there, so text in the box
  ## shows nothing; the column's ground running past the foot the regions
  ## give is the whole form, whatever the regions say.
  if not foldMayApply(id, vw, vh) or FoldSummaryRegion notin gpui: return
  result.applies = true
  for (side, regions, names) in [("the web", web, @["cc-launch", "composer-send"]),
                                 ("GPUI", gpui, @["cc-launch", "composer-send"])]:
    for n in names:
      if n notin regions:
        result.problems.add "the fold: " & side & " draws no " & n
  if result.problems.len > 0: return
  let summary = gpui[FoldSummaryRegion]
  let launch = gpui["cc-launch"]
  let send = gpui["composer-send"]
  let webLaunch = web["cc-launch"]
  let webSend = web["composer-send"]
  proc f1(v: float): string = formatFloat(v, ffDecimal, 1)
  if summary.x < launch.x - 0.5 or summary.y < launch.y - 0.5 or
     summary.x + summary.w > launch.x + launch.w + 0.5 or
     summary.y + summary.h > launch.y + launch.h + 0.5:
    result.problems.add "the fold: GPUI draws the summary (y " & f1(summary.y) & ", " &
      f1(summary.h) & "px) outside the launch column (y " & f1(launch.y) & ", " & f1(launch.h) & "px)"
  let sendWant = summary.y + summary.h + FoldPartGapPx
  if abs(send.y - sendWant) > PxTolerance:
    result.problems.add "the fold: GPUI's send line starts at y " & f1(send.y) &
      ", not " & f1(FoldPartGapPx) & "px under the summary (y " & f1(sendWant) &
      "; tolerance " & $int(PxTolerance) & "px)"
  result.freedPx = webSend.y - send.y
  if result.freedPx <= PxTolerance:
    result.problems.add "the fold: GPUI's send line is at y " & f1(send.y) & ", the web's at " &
      f1(webSend.y) & ": the summary frees no height, so the form was not folded"
  let launchWant = webLaunch.h - result.freedPx
  if abs(launch.h - launchWant) > PxTolerance:
    result.problems.add "the fold: GPUI's launch column is " & f1(launch.h) &
      "px tall, not the folded form's " & f1(launchWant) & "px (the web's " & f1(webLaunch.h) &
      "px less the " & f1(result.freedPx) & "px the fold frees; tolerance " &
      $int(PxTolerance) & "px)"
  let px = int(floor(launch.x + launch.w)) - FoldEdgeProbeInsetPx
  let foot = int(round(launch.y + launch.h))
  if px < 0 or px >= frame.width or foot - 2 < 0 or foot + 2 >= frame.height:
    result.problems.add "the fold: the launch column's foot (y " & $foot & ") is outside the frame"
  elif hexOf(frame, px, foot - 2) == hexOf(frame, px, foot + 2):
    result.problems.add "the fold: in the frame the launch column's ground (" &
      hexOf(frame, px, foot - 2) & ") runs on past its foot at y " & $foot &
      " (read at x " & $px & ", 2px above and below): the frame draws the whole form"

type FoldedWeb* = object
  regions*: JsonNode
    ## The web record's regions as the web would lay them out with the form
    ## folded (`foldedWebRegions`).
  exempt*: seq[tuple[region, why: string]]
    ## Each region left out of the comparison on both sides, and why.

proc foldedWebRegions*(web: JsonNode; gpui: RegionSet; fold: LaunchFold;
                       vh: int): FoldedWeb =
  ## The web record's regions as the web's own one-column layout would place
  ## them with the form folded, for the judge's usual checks:
  ##
  ##   * the launch column `fold.freedPx` (D) shorter;
  ##   * every region from the web's send line down -- `composer-send`, the
  ##     answer, the recent launches, the overview and everything in it --
  ##     D higher, except the story host's (`FoldHostRegions`);
  ##   * the overview, which fills the rest of the tab and is never shorter
  ##     than its content (the web's one column: `flex: 1 0 auto`), as tall
  ##     as the tab's rest under the folded column or its own height,
  ##     whichever is more: it grows by G, at most D, and G is D exactly
  ##     where the overview already filled the tab's rest (a notice) and
  ##     less where its content ran past the window;
  ##   * the regions that fill the overview grow with it (`FoldFillRegions`),
  ##     and one centred in such a region moves down by half of that
  ##     (`FoldCentredRegions`).
  ##
  ## Their x, widths and other heights, their fills and cut answers stay as
  ## the web recorded them.
  ##
  ## One thing the record cannot say: which row of a list is the last one
  ## drawn whole (`pick: "last-whole"`) once the fold has brought rows into
  ## the window that the web's window did not hold whole. The web recorded
  ## only rows whole inside its own window. Such a region is left out of the
  ## comparison on both sides, by name (`exempt`), and only when GPUI's row
  ## is one the web's window could not have held whole: its foot, D lower,
  ## past the web's window foot. Any other `last-whole` region is compared
  ## as usual, its row included.
  result.regions = web.copy
  let d = fold.freedPx
  let foldLine = web["composer-send"]["y"].getFloat - 0.5
  var tabFoot = float(vh)
  if web.hasKey("surface"):
    tabFoot = web["surface"]["y"].getFloat + web["surface"]["h"].getFloat
  var grow = 0.0
  if web.hasKey("cc-overview"):
    let o = web["cc-overview"]
    let folded = max(o["h"].getFloat, tabFoot - (o["y"].getFloat - d))
    grow = min(d, folded - o["h"].getFloat)
  for name, r in result.regions.mpairs:
    if name in FoldHostRegions: continue
    if name == "cc-launch":
      r["h"] = %(r["h"].getFloat - d)
      continue
    if r["y"].getFloat < foldLine: continue
    r["y"] = %(r["y"].getFloat - d)
    if name == "cc-overview" or name in FoldFillRegions:
      r["h"] = %(r["h"].getFloat + grow)
    elif name in FoldCentredRegions:
      r["y"] = %(r["y"].getFloat + grow / 2)
  for name in lastWholeRegions:
    if name notin gpui: continue
    let g = gpui[name]
    if g.y + g.h + d <= float(vh) + 0.5: continue
    let w = result.regions{name}
    if not w.isNil and w{"index"}.getInt(-1) == g.index: continue
    result.exempt.add (name, "GPUI's row " & $g.index & " ends at y " &
      formatFloat(g.y + g.h, ffDecimal, 1) & ", below the web's window foot without the fold: " &
      "the web record cannot say which row is the last whole one once the fold brings it into view")
    if not w.isNil: result.regions.delete(name)


# ---------------------------------------------------------------------------
# The held overview
# ---------------------------------------------------------------------------

const
  HeldCountRegions* = ["cc-waiting-more", "cc-initiatives-more"]
    ## The facts the held overview is keyed on: the `+N more` lines GPUI
    ## draws where its window cannot show a list's rows (the waiting list,
    ## the Initiatives panel). GPUI draws one only where it held the
    ## overview to the window; the web, whose tab scrolls, never does.
  HeldGapPx* = 4.0
    ## Between the waiting list and the Initiatives panel: the web's
    ## `.ah-cc-overview` gap (`AH_CC_GAP`, 0.25rem), GPUI's `ColumnGapPx`.
  HeldListPadPx* = 4.0
    ## Under the waiting list's last line: the web's `.ah-cc-waiting-rows`
    ## padding (0.25rem), GPUI's `ListPadPx`.
  HeldPanelRows* = ["initiative-row-first", "initiative-row-last"]
    ## The Initiatives panel's row regions: a web region inside one of
    ## these that GPUI counted instead of drawing is left out (`heldWebRegions`).

type HeldOverview* = object
  ## What the judge found of GPUI's held overview in one folded capture.
  applies*: bool
    ## The fold applied and GPUI recorded a `+N more` line.
  visibleFoot*: float
    ## Where GPUI's overview stops being shown: its top and the height the
    ## window shows of it (`cc-overview-held`).
  shiftPx*: float
    ## How much higher than the folded web layout GPUI drew the Initiatives
    ## panel: the waiting rows it counted on its `+N more` line instead.
  waitingHidden*, initiativesHidden*: int
  problems*: seq[string]

proc heldCountOf(facts: RegionSet; name: string): int =
  ## A `+N more` line's N; 0 where GPUI drew none.
  if name notin facts: return 0
  try: parseInt(facts[name].value) except ValueError: -1

proc heldListProblems(what: string; facts: RegionSet; frame: Frame;
                      listName, rowsName, moreName: string;
                      foot: float): (int, seq[string]) =
  ## One list of the held overview: the rows GPUI drew (`rowsName`'s count)
  ## and the N of its `+N more` line (`moreName`) add up to the list's total
  ## (`listName`'s value), and a `+N more` line is drawn, inside the
  ## window's shown part, wherever rows were left out.
  if listName notin facts: return (0, @[])
  var problems: seq[string]
  var total = -1
  try: total = parseInt(facts[listName].value) except ValueError: discard
  let drawn = if rowsName in facts: max(0, facts[rowsName].count) else: 0
  let hidden = heldCountOf(facts, moreName)
  if total < 0 or hidden < 0:
    problems.add "the held overview: GPUI gave no count for " & what
  elif drawn + hidden != total:
    problems.add "the held overview: " & what & " draws " & $drawn & " of its " & $total &
      " rows and counts " & (if moreName in facts: "+" & $hidden & " more" else: "no `+N more` line") &
      ": " & $(total - drawn) & " are not drawn"
  if moreName in facts:
    let m = facts[moreName]
    if m.y + m.h > foot + 0.5:
      problems.add "the held overview: " & what & "'s `+N more` line ends at y " &
        formatFloat(m.y + m.h, ffDecimal, 1) & ", below the window's foot (" &
        formatFloat(foot, ffDecimal, 1) & ")"
    elif distinctColours(frame, m, 2) < 2:
      problems.add "the held overview: " & what & "'s `+N more` line is a single colour in the frame"
  (hidden, problems)

proc heldOverviewOf*(web, gpui, facts: RegionSet; frame: Frame; vw, vh: int;
                     expect: HeldExpectation): HeldOverview =
  ## The held overview in a capture whose fold the judge allowed (`web` is
  ## the web record as laid out folded), or `applies = false` where GPUI
  ## drew no `+N more` line (`HeldCountRegions`). Where it applies, GPUI's
  ## overview must be the accepted one, on its facts and in the frame:
  ##
  ##   * the overview is shown down to the window's foot and no further: the
  ##     part the window shows of it (`cc-overview-held`) ends where GPUI's
  ##     one-column control center ends (`cc-root`), inside the window;
  ##   * each list's rows drawn and its `+N more` count add up to its total,
  ##     and the `+N more` line is drawn (not a single colour), inside the
  ##     shown part, wherever rows were left out;
  ##   * in the FRAME, the waiting list's ground ends at its foot: read
  ##     `FoldEdgeProbeInsetPx` in from the window's right edge, the pixel
  ##     2px above the waiting list's foot and the one 2px below it (in the
  ##     4px gap to the Initiatives panel) differ. An overview that records
  ##     the counts but draws the whole waiting list draws its rows on past
  ##     that foot;
  ##   * the Initiatives panel is where what GPUI drew above it puts it, not
  ##     where it happens to be: the waiting rows drawn sit one under the
  ##     other from the first, each as tall as the view draws that row of the
  ##     story's data (`expect`, `ctf_held_expectation`, never the capture),
  ##     the last drawn one at the index the count says; the `+N more` line
  ##     starts under it; the waiting list ends `HeldListPadPx` under its
  ##     last line; the panel's box starts `HeldGapPx` under that; its head
  ##     band at the box's top and as tall as the view draws it for the
  ##     story's data at this width (`expect`); its list under the head; each
  ##     to `PxTolerance`. Every link is checked and no link's size comes
  ##     from the capture, so a panel drawn higher or lower -- regions, facts
  ##     and frame moved together, a link stretched to absorb it -- fails;
  ##   * so anchored, the panel is drawn higher than the folded web layout by
  ##     `shiftPx`: the web's waiting list (every row) less GPUI's (the rows
  ##     drawn and the `+N more` line), measured from the web record against
  ##     that chain, never lower, and not higher at all where no waiting row
  ##     was counted.
  if not HeldCountRegions.anyIt(it in facts): return
  result.applies = true
  for n in ["cc-root", "cc-overview-held"]:
    if n notin facts: result.problems.add "the held overview: GPUI records no " & n
  if "cc-overview" notin gpui: result.problems.add "the held overview: GPUI draws no cc-overview"
  if result.problems.len > 0: return
  proc f1(v: float): string = formatFloat(v, ffDecimal, 1)
  let o = gpui["cc-overview"]
  var shown = -1.0
  try: shown = parseFloat(facts["cc-overview-held"].value) except ValueError: discard
  let root = facts["cc-root"]
  let rootFoot = root.y + root.h
  result.visibleFoot = o.y + shown
  if shown < 0:
    result.problems.add "the held overview: GPUI gave no shown height for its overview"
    return
  if rootFoot > float(vh) + 0.5 or abs(result.visibleFoot - rootFoot) > PxTolerance:
    result.problems.add "the held overview: GPUI shows its overview down to y " &
      f1(result.visibleFoot) & ", not to the control center's foot at y " & f1(rootFoot) &
      " inside the " & $vh & "px window"
  let (wh, wp) = heldListProblems("the waiting list", facts, frame, "cc-waiting-list",
                                  "cc-waiting-rows", "cc-waiting-more", result.visibleFoot)
  let (ih, ip) = heldListProblems("the Initiatives panel", facts, frame, "cc-initiatives-list",
                                  "cc-initiative-rows", "cc-initiatives-more", result.visibleFoot)
  result.waitingHidden = wh
  result.initiativesHidden = ih
  result.problems.add wp & ip
  if "cc-waiting-list" in facts:
    let wl = facts["cc-waiting-list"]
    let px = vw - FoldEdgeProbeInsetPx
    let foot = int(round(wl.y + wl.h))
    if float(foot) > result.visibleFoot + 0.5:
      result.problems.add "the held overview: the waiting list ends at y " & $foot &
        ", below the window's shown part (y " & f1(result.visibleFoot) & ")"
    elif foot - 2 >= 0 and foot + 2 < frame.height and
         hexOf(frame, px, foot - 2) == hexOf(frame, px, foot + 2):
      result.problems.add "the held overview: in the frame the waiting list's ground (" &
        hexOf(frame, px, foot - 2) & ") runs on past its foot at y " & $foot &
        " (read at x " & $px & ", 2px above and below): the frame draws the whole list"
  # Where the Initiatives panel is: anchored to what GPUI drew above it,
  # never to the panel itself. The waiting rows drawn sit one under the
  # other from the first (which the web record holds), each as tall as the
  # view draws that row of the story's data (`expect`, not the capture); the
  # `+N more` line starts under the last of them; the waiting list ends
  # `HeldListPadPx` under its last line; the panel's box starts `HeldGapPx`
  # under that; its head band at the box's top, as tall as the view draws
  # it for the story's data at this width (`expect`); its list (`rows`)
  # under the head. A panel drawn higher or lower than that chain puts --
  # regions, facts and frame moved together -- breaks the first link it
  # moves away from, and no link's size can be stretched to absorb it.
  proc near(a, b: float): bool = abs(a - b) <= PxTolerance
  if not expect.known:
    result.problems.add "the held overview: no view expectation for this story, so the " &
      "Initiatives panel's place cannot be checked"
    return
  if "cc-waiting-list" in facts:
    let wl = facts["cc-waiting-list"]
    let waitFoot = wl.y + wl.h
    let drawn = if "cc-waiting-rows" in facts: max(0, facts["cc-waiting-rows"].count) else: 0
    var lastLine = -1.0
    if drawn > 0:
      if "cc-waiting-row-first" notin gpui or "cc-waiting-row-last-drawn" notin facts:
        result.problems.add "the held overview: GPUI records no first or last drawn waiting row"
        return
      if drawn > expect.waitingRowPx.len:
        result.problems.add "the held overview: GPUI draws " & $drawn & " waiting rows of the " &
          $expect.waitingRowPx.len & " the story has"
        return
      let first = gpui["cc-waiting-row-first"]
      let last = facts["cc-waiting-row-last-drawn"]
      var want = first.y
      for i in 0 ..< drawn - 1: want += float(expect.waitingRowPx[i])
      if last.index != drawn - 1:
        result.problems.add "the held overview: the last waiting row drawn is row " & $last.index &
          ", not row " & $(drawn - 1) & " of the " & $drawn & " GPUI says it drew"
      if not near(first.h, float(expect.waitingRowPx[0])):
        result.problems.add "the held overview: the first waiting row is " & f1(first.h) &
          "px tall, not the " & $expect.waitingRowPx[0] & "px the view draws it"
      if not near(last.y, want) or not near(last.h, float(expect.waitingRowPx[drawn - 1])):
        result.problems.add "the held overview: the last waiting row drawn is at y " & f1(last.y) &
          ", " & f1(last.h) & "px tall, not at y " & f1(want) & ", " &
          $expect.waitingRowPx[drawn - 1] & "px: the rows above it as the view draws them"
      lastLine = last.y + last.h
    if "cc-waiting-more" in facts:
      let m = facts["cc-waiting-more"]
      if lastLine >= 0 and not near(m.y, lastLine):
        result.problems.add "the held overview: the waiting list's `+N more` line starts at y " &
          f1(m.y) & ", not under its last drawn row (which ends at y " & f1(lastLine) & ")"
      # Its height is the view's fixed line, not the capture's: a taller
      # line would carry the waiting list's foot, and the panel under it,
      # lower while every other link held.
      if not near(m.h, float(expect.morePx)):
        result.problems.add "the held overview: the waiting list's `+N more` line is " &
          f1(m.h) & "px tall, not the " & $expect.morePx & "px the view draws it"
      lastLine = m.y + m.h
    if lastLine >= 0 and not near(waitFoot, lastLine + HeldListPadPx):
      result.problems.add "the held overview: the waiting list ends at y " & f1(waitFoot) &
        ", not " & f1(HeldListPadPx) & "px under its last line (y " & f1(lastLine) & ")"
    if "cc-initiatives-panel" notin facts or "cc-initiatives-head" notin facts or
       "rows" notin gpui:
      result.problems.add "the held overview: GPUI records no Initiatives panel box, head or list"
    else:
      let panel = facts["cc-initiatives-panel"]
      let head = facts["cc-initiatives-head"]
      let list = gpui["rows"]
      if not near(panel.y, waitFoot + HeldGapPx):
        result.problems.add "the held overview: the Initiatives panel starts at y " & f1(panel.y) &
          ", not " & f1(HeldGapPx) & "px under the waiting list's foot (y " & f1(waitFoot) &
          "): it is drawn " & f1(panel.y - waitFoot - HeldGapPx) & "px off the waiting rows it follows"
      if not near(head.y, panel.y):
        result.problems.add "the held overview: the Initiatives panel's head starts at y " &
          f1(head.y) & ", not at the panel's top (y " & f1(panel.y) & ")"
      if not near(head.h, float(expect.headPx)):
        result.problems.add "the held overview: the Initiatives panel's head is " & f1(head.h) &
          "px tall, not the " & $expect.headPx & "px the view draws it for this story at " &
          $vw & "px"
      if not near(list.y, head.y + head.h):
        result.problems.add "the held overview: the Initiatives panel's list starts at y " &
          f1(list.y) & ", not under its head (y " & f1(head.y + head.h) & ")"
  if "rows" in web and "rows" in gpui and "cc-overview" in web:
    # With the panel anchored, this is the web's waiting list (its head,
    # every row, its padding) less GPUI's (its head, the rows drawn, the
    # `+N more` line, its padding): the rows counted instead of drawn, less
    # the line that counts them. It is measured from the web record against
    # that anchored GPUI layout, so moving the panel cannot change it.
    result.shiftPx = (web["rows"].y - web["cc-overview"].y) - (gpui["rows"].y - o.y)
    if result.shiftPx < -PxTolerance or (wh == 0 and abs(result.shiftPx) > PxTolerance):
      result.problems.add "the held overview: GPUI draws the Initiatives panel " &
        f1(-result.shiftPx) & "px lower than the folded web layout, with " & $wh &
        " waiting rows counted"

proc heldWebRegions*(web: JsonNode; gpui: RegionSet; held: HeldOverview):
    tuple[regions: JsonNode; gpui: RegionSet; exempt: seq[tuple[region, why: string]]] =
  ## The folded web record's regions as the web would lay them out with the
  ## overview held to the window as GPUI holds it, and GPUI's regions as the
  ## window shows them:
  ##
  ##   * every region of the Initiatives panel (from the panel's list down,
  ##     but the story host's) `held.shiftPx` higher: the waiting rows GPUI
  ##     counted instead of drawing;
  ##   * the overview and the parts that fill it (`FoldFillRegions`) ending
  ##     at the window's shown foot on both sides: the web's runs on to its
  ##     content under its scrolling tab, and past that foot nothing of
  ##     GPUI's is shown;
  ##   * a web region of the panel that GPUI does not draw, inside a web
  ##     initiative row that does not fit whole above the shown foot, is
  ##     left out by name: GPUI counted that row on the panel's `+N more`
  ##     line (checked by `heldOverviewOf`) instead of drawing it.
  result.regions = web.copy
  result.gpui = gpui
  let v = held.visibleFoot
  let s = held.shiftPx
  if web.hasKey("rows"):
    let panelLine = web["rows"]["y"].getFloat - 0.5
    for name, r in result.regions.pairs:
      if name in FoldHostRegions: continue
      if r["y"].getFloat >= panelLine: r["y"] = %(r["y"].getFloat - s)
  for name in @["cc-overview"] & @FoldFillRegions:
    if result.regions.hasKey(name):
      let r = result.regions[name]
      r["h"] = %max(0.0, v - r["y"].getFloat)
    if name in result.gpui:
      result.gpui[name].h = min(result.gpui[name].h, max(0.0, v - result.gpui[name].y))
  var counted: seq[Rect]
  for name in HeldPanelRows:
    if result.regions.hasKey(name) and name notin gpui:
      let r = result.regions[name]
      let row = Rect(x: r["x"].getFloat, y: r["y"].getFloat, w: r["w"].getFloat, h: r["h"].getFloat)
      if row.y + row.h > v + 0.5: counted.add row
  if held.initiativesHidden <= 0 or counted.len == 0: return
  var gone: seq[string]
  for name, r in result.regions.pairs:
    if name in gpui or name in FoldHostRegions: continue
    let y = r["y"].getFloat
    for row in counted:
      if y >= row.y - 0.5 and y + r["h"].getFloat <= row.y + row.h + 0.5:
        gone.add name
        result.exempt.add (name, "inside an initiative the web draws from y " &
          formatFloat(row.y, ffDecimal, 1) & " to " & formatFloat(row.y + row.h, ffDecimal, 1) &
          ", which does not fit whole above the window's shown foot (y " &
          formatFloat(v, ffDecimal, 1) & "): GPUI counts it on the Initiatives panel's `+N more` line")
        break
  for name in gone: result.regions.delete(name)

var heldExpectations: Table[string, HeldExpectation]
  ## `heldExpectationOfCapture`'s answers, one per story and width.

proc heldExpectationOfCapture*(id: string; vw: int): HeldExpectation =
  ## The view's heights for the story a capture shows (`ctf_held_expectation`),
  ## found by the capture id's story part, as `expectedCaptures` names it.
  for section in codeTracerStorySections():
    if section.title != SectionTitle: continue
    for story in section.stories:
      let sid = storybookId(section, story)
      if not sid.startsWith(StoryIdPrefix): continue
      let name = ViewPrefix & sid[StoryIdPrefix.len .. ^1]
      if not id.startsWith(name & "-"): continue
      # The longest story name wins (`control-center-launched` over
      # `control-center`): a size follows the name directly.
      let rest = id[name.len + 1 .. ^1]
      if not (rest.startsWith("sidebar-") or rest.startsWith("laptop-") or
              rest.startsWith("panel-")): continue
      let key = story.surface & "/" & story.fixture & "/" & $vw
      if key notin heldExpectations:
        heldExpectations[key] = heldExpectationOf(story.surface, story.fixture, vw)
      return heldExpectations[key]

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
  # GPUI's facts (`gpuiOnly` regions: its counts and boxes for the held
  # overview) are kept apart: never compared, never held to the blank check.
  var gpui, facts: RegionSet
  for name, r in regionsOf(gpuiDoc["regions"]):
    if name in gpuiOnlyRegions: facts[name] = r
    else: gpui[name] = r
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
  # The sidebar fold: where GPUI's capture records it, the fold is
  # checked, and the web record is judged as laid out with the form folded;
  # the summary itself, the fold's fact, is compared by nothing else. A fold
  # that is not the accepted one is no allowance: the capture is judged as any other,
  # its summary a region drawn only in GPUI, and fails as `vFold`.
  var webRegions = webCapture["regions"]
  var gpuiRegions = gpui
  let fold = launchFoldOf(id, regionsOf(webRegions), gpui, frame, vw, vh)
  var held: HeldOverview
  if fold.applies and fold.problems.len == 0:
    result.foldPx = fold.freedPx
    let folded = foldedWebRegions(webRegions, gpui, fold, vh)
    webRegions = folded.regions
    gpuiRegions.del FoldSummaryRegion
    for (region, why) in folded.exempt:
      gpuiRegions.del region
      result.foldExempt.add region & ": " & why
    held = heldOverviewOf(regionsOf(webRegions), gpuiRegions, facts, frame, vw, vh,
                          heldExpectationOfCapture(id, vw))
    if held.applies and held.problems.len == 0:
      result.heldShiftPx = held.shiftPx
      let h = heldWebRegions(webRegions, gpuiRegions, held)
      webRegions = h.regions
      gpuiRegions = h.gpui
      for (region, why) in h.exempt:
        gpuiRegions.del region
        result.foldExempt.add region & ": " & why
  compareRegions(regionsOf(webRegions), gpuiRegions, vw, vh, result)
  comparePixels(result)
  compareFills(webRegions, gpuiRegions, frame, result)
  compareHangs(regionsOf(webRegions), gpuiRegions, vw, result)
  compareElision(webRegions, gpuiDoc["regions"], result)
  for problem in drawnCutProblems(gpuiDoc):
    if result.verdict == vPass: result.verdict = vCut
    result.problems.add problem
  if fold.applies and fold.problems.len > 0:
    result.verdict = vFold
    result.problems = fold.problems & result.problems
  elif held.applies and held.problems.len > 0:
    result.verdict = vFold
    result.problems = held.problems & result.problems

# ---------------------------------------------------------------------------
# The sidebar fold's falsifying controls (shared by the CTF-P1b and CTF-P1c
# tests, which run them over their own captures)
# ---------------------------------------------------------------------------

type FoldPlant* = enum
  ## A defect planted into a copy of one real capture of a folded control
  ## center, for the fold's falsifying controls.
  fpUntouched        ## nothing: the copy must pass, the fold allowed
  fpUnrelatedMoved   ## the launch column's head, which the fold does not
                     ## move, 20px to the right
  fpLaunchShorter    ## the launch column 20px shorter than the folded form's
  fpLaunchTaller     ## ... and 20px taller
  fpBelowNotMoved    ## the fact kept, the overview and all in it drawn
                     ## 30px lower than the fold puts it (frame and regions
                     ## alike): moved up, but not by the height it frees
  fpSendNotMoved     ## the send line and what follows it in the column
                     ## drawn 12px lower (frame and regions), off the summary
  fpRowNotMoved      ## only the first waiting row 20px lower
  fpNoFact           ## the summary gone from GPUI's capture: no fold fact
  fpGroundRunsOn     ## the frame: the launch column's ground painted on
                     ## 60px past its foot, as the whole form would draw it
  fpHeldOverflow     ## the held overview shown 40px past
                     ## the control center's foot: overflowing the window
  fpHeldNoMore       ## the waiting list's `+N more` line gone
  fpHeldWrongCount   ## the Initiatives panel's `+N more` one higher
  fpHeldListRunsOn   ## the frame: the waiting list's ground painted on 40px
                     ## past its foot, as the whole list would draw it
  fpHeldPanelLower   ## the Initiatives panel drawn 40px lower (regions,
                     ## facts and frame together), still inside the window
  fpHeldPanelHigher  ## the Initiatives panel drawn 12px higher, over the
                     ## waiting list's `+N more` line (regions, facts, frame)
  fpHeldHeadTaller   ## the Initiatives panel's head 40px taller and its list
                     ## 40px lower (regions, facts, frame): every link holds
  fpHeldRowsStretched ## two waiting rows claimed (the count 2, `+N more` one
                     ## fewer, the last drawn row 40px tall under the first),
                     ## the `+N more` line and all under it 40px lower
  fpHeldMoreTaller   ## the waiting list's `+N more` line 40px taller, the
                     ## waiting list with it and all under it 40px lower
                     ## (regions, facts, frame): every other link holds
  fpHeldTwoRows      ## two waiting rows drawn, planted as the view draws them:
                     ## the second as tall as the view draws it, the `+N more`
                     ## line and all under it that much lower (must pass)

proc copyCapture*(srcDir, scratch, id: string): string =
  ## A fresh copy of one capture's frame, image and regions in `scratch`.
  removeDir(scratch)
  createDir(scratch)
  for ext in [".ppm", ".png", ".regions.json"]:
    copyFile(srcDir / (id & ext), scratch / (id & ext))
  scratch

proc shiftedBelow(regions: JsonNode; fromY, by: float; toY = Inf) =
  ## Every region at or under `fromY` (and above `toY`), but the story
  ## host's and the launch column, `by` lower.
  for name, r in regions.pairs:
    let y = r["y"].getFloat
    if name notin FoldHostRegions and name != "cc-launch" and y >= fromY - 0.5 and y < toY:
      r["y"] = %(y + by)

proc drawnLower(f: var Frame; fromY, toY, by, groundY: int) =
  ## The frame's rows `fromY ..< toY` drawn `by` rows lower, the rows they
  ## leave filled with the ground of row `groundY` (read at the window's
  ## right edge, inside every column's side padding): a GPUI that drew that
  ## band lower, so its regions and its pixels still agree.
  let row = f.width * 3
  let o = groundY * row + (f.width - FoldEdgeProbeInsetPx) * 3
  let fill = f.rgb[o ..< o + 3]
  for y in countdown(toY - 1, fromY + by):
    f.rgb[y * row ..< (y + 1) * row] = f.rgb[(y - by) * row ..< (y - by + 1) * row]
  for y in fromY ..< min(toY, fromY + by):
    for x in 0 ..< f.width:
      f.rgb[y * row + x * 3 ..< y * row + x * 3 + 3] = fill

proc drawnHigher(f: var Frame; fromY, toY, by: int) =
  ## The frame's rows `fromY ..< toY` drawn `by` rows higher (over the rows
  ## above `fromY`), the rows they leave at the band's foot filled with the
  ## ground of the band's last row (read as `drawnLower` reads it).
  let row = f.width * 3
  for y in fromY - by ..< toY - by:
    f.rgb[y * row ..< (y + 1) * row] = f.rgb[(y + by) * row ..< (y + by + 1) * row]
  let o = (toY - 1) * row + (f.width - FoldEdgeProbeInsetPx) * 3
  let fill = f.rgb[o ..< o + 3]
  for y in toY - by ..< toY:
    for x in 0 ..< f.width:
      f.rgb[y * row + x * 3 ..< y * row + x * 3 + 3] = fill

proc writePpm(f: Frame; path: string) =
  writeFile(path, "P6\n" & $f.width & " " & $f.height & "\n255\n" & f.rgb)

proc plantedFold*(srcDir, scratch, id: string; web: JsonNode; vw, vh: int;
                  plant: FoldPlant): CaptureJudgement =
  ## One real capture of a folded control center, copied into `scratch`
  ## with `plant`, and judged. A capture without the regions the plant needs
  ## is judged untouched, so the control that expects a failure fails.
  let dir = copyCapture(srcDir, scratch, id)
  let path = dir / (id & ".regions.json")
  var doc = parseJson(readFile(path))
  let r = doc["regions"]
  case plant
  of fpUntouched: discard
  of fpUnrelatedMoved:
    if r.hasKey("head"): r["head"]["x"] = %(r["head"]["x"].getFloat + 20)
  of fpLaunchShorter, fpLaunchTaller:
    if r.hasKey("cc-launch"):
      r["cc-launch"]["h"] = %(r["cc-launch"]["h"].getFloat +
                              (if plant == fpLaunchShorter: -20.0 else: 20.0))
  of fpBelowNotMoved, fpSendNotMoved:
    # The band moved lower in the frame and in the regions together, so the
    # capture still agrees with itself and no region lands on bare ground;
    # only the fold's geometry can tell. The tab's foot (`surface`) bounds
    # it: the playback bar under the tab stays where it is.
    if r.hasKey("cc-launch") and r.hasKey("composer-send") and r.hasKey("surface"):
      let l = regionsOf(r)["cc-launch"]
      let foot = int(round(l.y + l.h))
      let tabFoot = int(round(r["surface"]["y"].getFloat + r["surface"]["h"].getFloat))
      # Under the column the band leaves the window's canvas (the gap's,
      # 2px under the foot); above the send line, the column's ground.
      let (fromY, toY, by, groundY) =
        if plant == fpBelowNotMoved: (foot, tabFoot, 30, foot + 2)
        else:
          let sendY = int(round(r["composer-send"]["y"].getFloat))
          (sendY, foot - 8, 12, sendY - 2)
      var f = readPpm(dir / (id & ".ppm"))
      f.drawnLower(fromY, toY, by, groundY)
      f.writePpm(dir / (id & ".ppm"))
      r.shiftedBelow(float(fromY), float(by), float(toY))
  of fpRowNotMoved:
    if r.hasKey("cc-waiting-row-first"):
      r["cc-waiting-row-first"]["y"] = %(r["cc-waiting-row-first"]["y"].getFloat + 20)
  of fpNoFact:
    r.delete(FoldSummaryRegion)
  of fpHeldOverflow:
    if r.hasKey("cc-overview-held"):
      r["cc-overview-held"]["value"] = %($(parseFloat(r["cc-overview-held"]["value"].getStr) + 40))
  of fpHeldNoMore:
    if r.hasKey("cc-waiting-more"): r.delete("cc-waiting-more")
  of fpHeldWrongCount:
    if r.hasKey("cc-initiatives-more"):
      r["cc-initiatives-more"]["value"] = %($(parseInt(r["cc-initiatives-more"]["value"].getStr) + 1))
  of fpHeldPanelLower, fpHeldPanelHigher:
    # The whole panel moved, from the gap under the waiting list to the
    # control center's foot: its regions, its facts and its pixels alike,
    # so only where it sits can tell.
    if r.hasKey("cc-waiting-list") and r.hasKey("cc-root"):
      let wl = regionsOf(r)["cc-waiting-list"]
      let panelTop = int(round(wl.y + wl.h)) + int(HeldGapPx)
      let rootFoot = int(round(r["cc-root"]["y"].getFloat + r["cc-root"]["h"].getFloat))
      let by = if plant == fpHeldPanelLower: 40 else: -12
      var f = readPpm(dir / (id & ".ppm"))
      if by > 0: f.drawnLower(panelTop, rootFoot, by, panelTop - 2)
      else: f.drawnHigher(panelTop, rootFoot, -by)
      f.writePpm(dir / (id & ".ppm"))
      for name, v in r.pairs:
        if name in FoldHostRegions or name in ["cc-overview", "cc-overview-held", "cc-root",
                                               "cc-waiting-list"]: continue
        if v["y"].getFloat >= float(panelTop) - 0.5: v["y"] = %(v["y"].getFloat + float(by))
  of fpHeldHeadTaller, fpHeldRowsStretched, fpHeldTwoRows:
    # A band of the overview moved lower in the frame and in the regions
    # and facts alike (`shiftedBelow` keeps the root, the overview and its
    # shown height), and the part above it made to account for the move.
    if r.hasKey("cc-root") and r.hasKey("rows") and r.hasKey("cc-waiting-more") and
       r.hasKey("cc-waiting-row-first"):
      let rootFoot = int(round(r["cc-root"]["y"].getFloat + r["cc-root"]["h"].getFloat))
      let first = regionsOf(r)["cc-waiting-row-first"]
      var fromY, by: int
      case plant
      of fpHeldHeadTaller:
        fromY = int(round(r["rows"]["y"].getFloat))
        by = 40
      else:
        let expect = heldExpectationOfCapture(id, vw)
        fromY = int(round(r["cc-waiting-more"]["y"].getFloat))
        by = if plant == fpHeldTwoRows and expect.waitingRowPx.len > 1: expect.waitingRowPx[1]
             else: 40
      var f = readPpm(dir / (id & ".ppm"))
      f.drawnLower(fromY, rootFoot, by, fromY - 2)
      f.writePpm(dir / (id & ".ppm"))
      for name, v in r.pairs:
        if name in FoldHostRegions or name in ["cc-overview", "cc-overview-held", "cc-root",
            "cc-waiting-list", "cc-initiatives-panel", "cc-initiatives-head",
            "cc-waiting-row-last-drawn"]: continue
        if v["y"].getFloat >= float(fromY) - 0.5: v["y"] = %(v["y"].getFloat + float(by))
      if plant == fpHeldHeadTaller:
        for name in ["cc-initiatives-panel", "cc-initiatives-head"]:
          if r.hasKey(name) and r[name]["y"].getFloat >= float(fromY) - 0.5:
            r[name]["y"] = %(r[name]["y"].getFloat + float(by))
        r["cc-initiatives-head"]["h"] = %(r["cc-initiatives-head"]["h"].getFloat + float(by))
      else:
        # The waiting list taller by the second row, its panel under it, the
        # count and the last drawn row saying two rows were drawn.
        for name in ["cc-initiatives-panel", "cc-initiatives-head"]:
          if r.hasKey(name): r[name]["y"] = %(r[name]["y"].getFloat + float(by))
        r["cc-waiting-list"]["h"] = %(r["cc-waiting-list"]["h"].getFloat + float(by))
        r["cc-waiting-rows"]["count"] = %2
        r["cc-waiting-more"]["value"] = %($(parseInt(r["cc-waiting-more"]["value"].getStr) - 1))
        r["cc-waiting-row-last-drawn"] = %*{"x": first.x, "y": first.y + first.h,
                                            "w": first.w, "h": float(by), "index": 1}
  of fpHeldMoreTaller:
    # Everything under the `+N more` line drawn 40px lower in the frame and
    # in the regions and facts alike; the line and the waiting list made
    # that much taller to account for it.
    if r.hasKey("cc-root") and r.hasKey("cc-waiting-more") and r.hasKey("cc-waiting-list"):
      let rootFoot = int(round(r["cc-root"]["y"].getFloat + r["cc-root"]["h"].getFloat))
      let m = regionsOf(r)["cc-waiting-more"]
      let fromY = int(round(m.y + m.h))
      let by = 40
      var f = readPpm(dir / (id & ".ppm"))
      f.drawnLower(fromY, rootFoot, by, fromY - 2)
      f.writePpm(dir / (id & ".ppm"))
      for name, v in r.pairs:
        if name in FoldHostRegions or name in ["cc-overview", "cc-overview-held", "cc-root",
            "cc-waiting-list", "cc-waiting-more"]: continue
        if v["y"].getFloat >= float(fromY) - 0.5: v["y"] = %(v["y"].getFloat + float(by))
      r["cc-waiting-more"]["h"] = %(m.h + float(by))
      r["cc-waiting-list"]["h"] = %(r["cc-waiting-list"]["h"].getFloat + float(by))
  of fpHeldListRunsOn:
    if r.hasKey("cc-waiting-list"):
      var f = readPpm(dir / (id & ".ppm"))
      let l = regionsOf(r)["cc-waiting-list"]
      let foot = int(round(l.y + l.h))
      let o = ((foot - 2) * f.width + f.width - FoldEdgeProbeInsetPx) * 3
      let ground = f.rgb[o ..< o + 3]
      for y in foot ..< min(f.height, foot + 40):
        for x in int(l.x) ..< min(f.width, int(l.x + l.w)):
          f.rgb[(y * f.width + x) * 3 ..< (y * f.width + x) * 3 + 3] = ground
      f.writePpm(dir / (id & ".ppm"))
  of fpGroundRunsOn:
    if r.hasKey("cc-launch"):
      var f = readPpm(dir / (id & ".ppm"))
      let l = regionsOf(r)["cc-launch"]
      let foot = int(round(l.y + l.h))
      # The column's ground, where the judge reads it above the foot.
      let o = ((foot - 2) * f.width + int(floor(l.x + l.w)) - FoldEdgeProbeInsetPx) * 3
      let ground = f.rgb[o ..< o + 3]
      for y in foot ..< min(f.height, foot + 60):
        for x in int(l.x) ..< min(f.width, int(l.x + l.w)):
          f.rgb[(y * f.width + x) * 3 ..< (y * f.width + x) * 3 + 3] = ground
      f.writePpm(dir / (id & ".ppm"))
  writeFile(path, $doc)
  judgeCapture(id, dir, web, vw, vh)

proc plantedFoldOnWholeForm*(srcDir, scratch, id: string; web: JsonNode;
                             vw, vh: int; freedPx: float): CaptureJudgement =
  ## The control the allowance must pass: GPUI records the fold, but draws
  ## the whole form. `id` is a capture that draws the whole form (the empty
  ## fleet's control center keeps it), and its regions are planted to
  ## say what a fold freeing `freedPx` would: the summary right above the
  ## send line, the launch column that much shorter, everything under the
  ## send line that much higher and the overview that much taller. The
  ## regions are then a consistent fold; only the frame shows the whole form.
  let dir = copyCapture(srcDir, scratch, id)
  let path = dir / (id & ".regions.json")
  var doc = parseJson(readFile(path))
  let r = doc["regions"]
  if r.hasKey("cc-launch") and r.hasKey("composer-send"):
    let sendY = r["composer-send"]["y"].getFloat
    r.shiftedBelow(sendY, -freedPx)
    r["cc-launch"]["h"] = %(r["cc-launch"]["h"].getFloat - freedPx)
    if r.hasKey("cc-overview"):
      r["cc-overview"]["h"] = %(r["cc-overview"]["h"].getFloat + freedPx)
    r[FoldSummaryRegion] = %*{"x": 8.0, "y": sendY - freedPx - FoldPartGapPx - 16.0,
                              "w": r["cc-launch"]["w"].getFloat - 16.0, "h": 16.0}
  writeFile(path, $doc)
  judgeCapture(id, dir, web, vw, vh)

proc plantedFoldAt*(srcDir, scratch, id: string; web: JsonNode; vw, vh: int;
                    summary: Rect): CaptureJudgement =
  ## A capture at another size (the laptop) given the fold's fact: the
  ## summary region at `summary`, nothing else changed. The fold does not
  ## apply there, so the summary is a region drawn only in GPUI.
  let dir = copyCapture(srcDir, scratch, id)
  let path = dir / (id & ".regions.json")
  var doc = parseJson(readFile(path))
  doc["regions"][FoldSummaryRegion] = %*{"x": summary.x, "y": summary.y,
                                         "w": summary.w, "h": summary.h}
  writeFile(path, $doc)
  judgeCapture(id, dir, web, vw, vh)

# ---------------------------------------------------------------------------
# The expected captures
# ---------------------------------------------------------------------------

type Expected* = object
  id*: string
  width*, height*: int
  webId*: string
    ## The web capture it is judged against: its own id, but for a story
    ## GPUI draws as another web story draws it (`GpuiDrawsAs`).

const
  GpuiDrawsAs* = [("result-rich-rows", "result-text-fallback")]
    ## Stories GPUI draws as the web draws another story, by view name (the
    ## capture id's story part). GPUI never draws a rich result row's HTML
    ## box: it switches rich rows to their text form when it mounts the
    ## results (`setHtmlEnabled(false)`), as the web does only with rich rows
    ## off (`result-text-fallback`), and its header says so (P2c study D45,
    ## OMNI-AREQ4). Its capture of the rich rows is the web's text form,
    ## line for line, so that is the web capture it is judged against; the
    ## web's boxes have no GPUI drawing to compare.

proc agentHarborSection*(): CodeTracerStorySection =
  for s in codeTracerStorySections():
    if s.title == SectionTitle: return s

proc sizesOf*(story: CodeTracerStory): seq[(string, int, int)] =
  ## The sizes a story is captured at: laptop and sidebar, and panel for the
  ## session activity timeline and the suggested UI actions (the P2c study's
  ## captures list them at `panel`; `ci/test/ctf_p1b_gpui_story_capture.nim`'s
  ## `PanelFamilies` takes the same).
  result = @Sizes
  if story.surface in ["agent-harbor-session-activity", "agent-harbor-suggested-actions"]:
    result.add PanelSize

proc expectedCaptures*(section: CodeTracerStorySection): seq[Expected] =
  for story in section.stories:
    let sid = storybookId(section, story)
    doAssert sid.startsWith(StoryIdPrefix), sid
    let name = sid[StoryIdPrefix.len .. ^1]
    var webName = name
    for (gpui, web) in GpuiDrawsAs:
      if name == gpui: webName = web
    for (size, w, h) in sizesOf(story):
      for theme in Themes:
        let suffix = "-" & size & "-" & theme
        result.add Expected(id: ViewPrefix & name & suffix, width: w, height: h,
                            webId: ViewPrefix & webName & suffix)

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
    var capture = %*{"id": j.id, "verdict": $j.verdict, "problems": j.problems,
                     "regions": regions}
    # The sidebar fold the judge allowed: the web regions in `regions`
    # are then the web record's as laid out with the form folded.
    if j.foldPx > 0: capture["foldPx"] = %j.foldPx
    if j.foldExempt.len > 0: capture["foldExempt"] = %j.foldExempt
    if j.heldShiftPx != 0: capture["heldShiftPx"] = %j.heldShiftPx
    captures.add capture
    md.add "| " & j.id & " | " & $j.verdict & " | " &
           j.problems.join("; ").replace("|", "\\|") & " |\n"
  writeFile(reportDir / "report.json", pretty(%*{
    "tolerancePp": PaneRectangleTolerancePp, "tolerancePx": PxTolerance,
    # Repository-relative, so a copied report names no machine's paths.
    "gpuiDir": relativePath(gpuiDir, repoRoot),
    "webRecord": relativePath(webRecordPath, repoRoot), "passed": passed, "total": judgements.len,
    "captures": captures}) & "\n")
  writeFile(reportDir / "report.md", md)
