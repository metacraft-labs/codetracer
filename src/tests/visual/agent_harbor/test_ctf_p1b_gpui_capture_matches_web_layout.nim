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
##   * the web record has no capture of the same id (or, for a story GPUI
##     draws as the web draws another, of that story's: the rich result
##     rows, which GPUI always draws as their text form, are judged against
##     the web's `result-text-fallback`; `ctf_layout_judge.GpuiDrawsAs`,
##     P2c study D45);
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
##   * on either side, a strip's `+N` menu -- the initiative bar's
##     (`bar-overflow-menu`) or the session strip's (`strip-overflow-menu`) --
##     does not hang from its chip (`bar-overflow`, `strip-overflow`): its
##     right edge on the chip's right edge, shifted only as far as it must be
##     to stay inside the viewport on either side, to within
##     `HangTolerancePx`. The
##     pane-rectangle comparison cannot see this: two hundredths of the
##     laptop viewport would let a menu drift 29px off its chip.
##
## ONE ACCEPTED DIFFERENCE, the sidebar fold. At the 360×900 sidebar size GPUI's control center folds the
## launch form to its summary, because its window cannot scroll; the web
## keeps the whole form and scrolls the tab. Where the capture is a
## control-center story or playback moment, at the sidebar size, and GPUI's
## capture records the summary it drew (`cc-form-summary`), the judge checks
## the fold itself -- the send line right under the summary, the launch
## column shorter than the web's by exactly what the fold frees, and, in the
## frame, the column's ground ending at its foot (verdict `fold`) -- and
## then judges the web record as laid out with the form folded
## (`ctf_layout_judge.launchFoldOf`, `foldedWebRegions`). Nothing else
## changes. The fold's own suite plants each way a fold can be wrong.
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
## and for each `+N` menu moved off its chip (right-aligned under the bar, or
## past the window's left edge where the window should have stopped it),
## and for a cut text the window lists (`drawnCuts`) that keeps a space or
## a separator before its "…", or a regions file that lists none (CTF-P1c
## D6).
##
## No mocks: both sides are real captures of real renderers, over the
## committed synthetic fixture set both builds embed.
##
## Trap 13 / §29 (`Verification-Harness-Traps.md`): every helper returns what
## it found; only the test bodies `check`.

## The judge itself -- the comparisons, the tolerances and the report -- is
## `ctf_layout_judge.nim`, which CTF-P1c's layout test at the playback
## stories' named moments runs too, so the two cannot drift apart.

import std/[json, os, strutils, tables, unittest]

import ./ctf_layout_judge

let gpuiDir = getEnv("CTF_P1B_GPUI_OUT", repoRoot / "build" / "ctf-p1b" / "gpui")
let webRecordPath = getEnv("CTF_P1B_WEB_RECORD",
                           repoRoot / "src" / "tests" / "visual" / "agent-harbor-web-regions.json")
let reportDir = getEnv("CTF_P1B_REPORT_DIR", repoRoot / "build" / "ctf-p1b" / "parity")

proc loadWebRecord(): JsonNode = loadWebRecord(webRecordPath)

proc writeReport(judgements: seq[CaptureJudgement]) =
  writeReport(judgements, "CTF-P1b: GPUI captures against the web layout", reportDir,
              gpuiDir, webRecordPath)

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
      judgements.add judgeCapture(e.id, gpuiDir, web{e.webId}, e.width, e.height)
    writeReport(judgements)
    var failing: seq[string]
    for j in judgements:
      if j.verdict != vPass:
        failing.add j.id & " [" & $j.verdict & "]: " & j.problems.join("; ")
    echo "CTF-P1b layout: ", judgements.len - failing.len, " of ", judgements.len,
         " captures within the tolerance; report in ", reportDir / "report.md"
    for f in failing: echo "  FAIL ", f
    var wanted = 0
    for story in section.stories: wanted += sizesOf(story).len * Themes.len
    check expected.len == wanted
    check failing.len == 0

suite "CTF-P2b: a static timeline story's list cuts no line at its top edge":
  # The session activity timeline's static stories open with the list at its
  # top, so in the browser and in GPUI the first line is whole and starts on
  # the list's top edge (`cutTopLineProblems`). The playback stories follow
  # their session's end and are not held to it.
  test "the first line of every static timeline capture is whole":
    let web = loadWebRecord()
    var problems: seq[string]
    var checked = 0
    for e in expectedCaptures(section):
      if not e.id.startsWith(ViewPrefix & "session-activity") or "-playback-" in e.id: continue
      let webNode = web{e.id}
      if not webNode.isNil:
        for p in cutTopLineProblems("web", regionsOf(webNode["regions"])): problems.add e.id & " " & p
      let path = gpuiDir / (e.id & ".regions.json")
      if fileExists(path):
        for p in cutTopLineProblems("GPUI", regionsOf(parseJson(readFile(path))["regions"])):
          problems.add e.id & " " & p
      inc checked
    for p in problems: echo "  CUT ", p
    check checked >= 19 * 3 * 2
    check problems.len == 0

  test "a line cut by the list's top edge is reported":
    var regions: RegionSet
    regions["timeline"] = Rect(x: 0, y: 72, w: 760, h: 568)
    regions["timeline-line-first"] = Rect(x: 4, y: 72, w: 752, h: 20)
    check cutTopLineProblems("web", regions).len == 0
    regions["timeline-line-first"] = Rect(x: 4, y: 84, w: 752, h: 16)
    check cutTopLineProblems("web", regions).len == 1

suite "CTF-P2c: the judge allows the sidebar fold and nothing else (falsifying controls)":
  # The one accepted difference:
  # at the sidebar size GPUI folds the control center's launch form to its
  # summary and the web scrolls. One real folded capture, copied and
  # planted; each plant must fail by name, the untouched copy pass with the
  # fold allowed. The CTF-P1c test runs the same plants on a playback
  # moment.
  let web = loadWebRecord()
  const
    Folded = "agent-harbor-control-center-playback-sidebar-dark"
      ## A first frame whose fold the judge allows whole: a waiting row, the
      ## Initiatives panel under it, and the story host's playback bar.
    Laptop = "agent-harbor-control-center-playback-laptop-dark"
    WholeForm = "agent-harbor-control-center-empty-sidebar-dark"
      ## An empty fleet keeps the whole form at the sidebar size.
  let scratch = getTempDir() / "ctf-p1b-fold-controls-" & $getCurrentProcessId()

  proc planted(plant: FoldPlant): CaptureJudgement =
    plantedFold(gpuiDir, scratch, Folded, web{Folded}, 360, 900, plant)

  proc says(j: CaptureJudgement; words: string): bool = words in j.problems.join(" ")

  test "the folded capture passes with the fold allowed, and records it":
    check foldMayApply(Folded, 360, 900)
    check not foldMayApply(Laptop, 1440, 900)
    check not foldMayApply("agent-harbor-initiative-tabs-popup-sidebar-dark", 360, 900)
    let j = planted(fpUntouched)
    check j.verdict == vPass
    check j.foldPx > 100.0
    for p in j.problems: checkpoint p

  test "a region the fold does not move, moved 20px, fails":
    let j = planted(fpUnrelatedMoved)
    check j.verdict == vLayout
    check j.says("region head:")

  test "a launch column folded to another height than the folded form's fails":
    for plant in [fpLaunchShorter, fpLaunchTaller]:
      let j = planted(plant)
      check j.verdict == vFold
      check j.says("the fold: GPUI's launch column is")

  test "the fact present and the regions under it not moved up by the height it frees fails":
    let j = planted(fpBelowNotMoved)
    check j.verdict in {vLayout, vPixels}
    check j.says("region cc-overview:")
    let send = planted(fpSendNotMoved)
    check send.verdict == vFold
    check send.says("the fold: GPUI's send line starts at")
    let row = planted(fpRowNotMoved)
    check row.verdict == vPixels
    check row.says("region cc-waiting-row-first: y is")

  test "a fold at the laptop size fails":
    let folded = regionsOf(parseJson(readFile(gpuiDir / (Folded & ".regions.json")))["regions"])
    check FoldSummaryRegion in folded
    if FoldSummaryRegion in folded:
      let j = plantedFoldAt(gpuiDir, scratch, Laptop, web{Laptop}, 1440, 900,
                            folded[FoldSummaryRegion])
      check j.verdict != vPass
      check j.says(FoldSummaryRegion)
      check j.foldPx == 0.0

  test "with no fold fact the capture fails as it did before the allowance":
    let j = planted(fpNoFact)
    check j.verdict == vLayout
    check j.says("region cc-launch:")
    check j.foldPx == 0.0

  test "the fold recorded but the whole form drawn fails, on the frame":
    # The allowance must rest on the pixels, not only on
    # the recorded fact. The regions are planted to be a consistent fold
    # over a capture that draws the whole form; only the frame tells.
    let real = planted(fpUntouched)
    let j = plantedFoldOnWholeForm(gpuiDir, scratch, WholeForm, web{WholeForm}, 360, 900,
                                   real.foldPx)
    check j.verdict == vFold
    check j.says("runs on past its foot")
    let ground = planted(fpGroundRunsOn)
    check ground.verdict == vFold
    check ground.says("runs on past its foot")

  # The held overview: at the sidebar size GPUI also
  # keeps the overview to the window, drawing whole rows and counting the
  # rest on `+N more` lines, where the web's tab scrolls. The populated
  # story holds both lists.
  const Held = "agent-harbor-control-center-sidebar-dark"
  const Gaze = "agent-harbor-status-gaze-off-sidebar-dark"

  proc heldPlanted(plant: FoldPlant; id = Held): CaptureJudgement =
    plantedFold(gpuiDir, scratch, id, web{id}, 360, 900, plant)

  test "the held overview passes with both counts, and records the panel's shift":
    let facts = regionsOf(parseJson(readFile(gpuiDir / (Held & ".regions.json")))["regions"])
    check "cc-waiting-more" in facts and "cc-initiatives-more" in facts
    let j = heldPlanted(fpUntouched)
    check j.verdict == vPass
    check j.heldShiftPx > 0.0
    for p in j.problems: checkpoint p

  test "the held overview shown past the window's foot fails":
    let j = heldPlanted(fpHeldOverflow)
    check j.verdict == vFold
    check j.says("the held overview: GPUI shows its overview down to")

  test "a missing +N more line under the waiting rows fails":
    let j = heldPlanted(fpHeldNoMore)
    check j.verdict == vFold
    check j.says("the held overview: the waiting list draws")

  test "a wrong count on the Initiatives panel's +N more line fails":
    let j = heldPlanted(fpHeldWrongCount)
    check j.verdict == vFold
    check j.says("the held overview: the Initiatives panel draws")

  test "the counts recorded but the whole waiting list drawn fails, on the frame":
    let j = heldPlanted(fpHeldListRunsOn)
    check j.verdict == vFold
    check j.says("the held overview: in the frame the waiting list's ground")

  test "the Initiatives panel drawn 40px lower fails, where it draws initiatives and where it counts them all":
    # Regions, facts and frame moved together, all inside the window: only
    # the panel's anchor to the waiting list it follows can tell. The
    # launched and gaze stories draw no initiative (`+4 more`), so no row
    # region of the panel is compared there at all.
    for id in [Held, "agent-harbor-control-center-launched-sidebar-dark", Gaze]:
      let j = heldPlanted(fpHeldPanelLower, id)
      check j.verdict == vFold
      check j.says("the held overview: the Initiatives panel starts at y")
      checkpoint id

  test "the Initiatives panel drawn 12px higher, over the +N more line, fails on its position":
    let j = heldPlanted(fpHeldPanelHigher)
    check j.verdict == vFold
    check j.says("the held overview: the Initiatives panel starts at y")

  test "the Initiatives panel's head 40px taller, its list 40px lower, fails on the head's height":
    # Every link of the chain holds (the list starts under the taller head);
    # the head's height is the view's for the story's data at this width
    # (`ctf_held_expectation`), not the capture's.
    for id in [Gaze, Held]:
      let j = heldPlanted(fpHeldHeadTaller, id)
      check j.verdict == vFold
      check j.says("the held overview: the Initiatives panel's head is")
      checkpoint id

  test "two waiting rows claimed, the second stretched to absorb a 40px drop, fails":
    let j = heldPlanted(fpHeldRowsStretched, Gaze)
    check j.verdict == vFold
    check j.says("the held overview: the last waiting row drawn is at y")

  test "the waiting list's +N more line 40px taller, all under it 40px lower, fails on its height":
    # Every other link holds (the list ends under the taller line, the
    # panel under the list); the line's height is the view's, not the
    # capture's.
    for id in [Gaze, Held]:
      let j = heldPlanted(fpHeldMoreTaller, id)
      check j.verdict == vFold
      check j.says("the held overview: the waiting list's `+N more` line is")
      checkpoint id

  test "two waiting rows drawn as the view draws them pass":
    # No captured story draws two waiting rows at the sidebar size; this
    # one is planted with the second row as tall as the view draws it, so
    # the multi-row rule is shown to accept a correct layout.
    let expect = heldExpectationOfCapture(Gaze, 360)
    check expect.known and expect.waitingRowPx.len >= 2
    let j = heldPlanted(fpHeldTwoRows, Gaze)
    check j.verdict == vPass
    for p in j.problems: checkpoint p

  test "a gaze story's fold and held overview pass, and a wrong count there fails":
    # The gaze stories draw the same control center over the status line;
    # the status line's gaze mark is the story host's.
    check foldMayApply(Gaze, 360, 900)
    let j = heldPlanted(fpUntouched, Gaze)
    check j.verdict == vPass
    check j.foldPx > 100.0
    for p in j.problems: checkpoint p
    let wrong = heldPlanted(fpHeldWrongCount, Gaze)
    check wrong.verdict == vFold
    check wrong.says("the held overview: the Initiatives panel draws")
    removeDir(scratch)

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

  test "a cut text with a separator before its \"…\" fails, and so does a file that lists none":
    # CTF-P1c D6: the window's cut texts (`drawnCuts`) follow the views'
    # rule. A planted `a ·…` and `a …` fail; `a…` passes; a regions file
    # without the list fails.
    proc withCuts(cuts: JsonNode): CaptureJudgement =
      let dir = plant()
      let path = dir / (source.id & ".regions.json")
      var doc = parseJson(readFile(path))
      if cuts.isNil: doc.delete("drawnCuts")
      else: doc["drawnCuts"] = cuts
      writeFile(path, $doc)
      judgeCapture(source.id, dir, web{source.id}, source.width, source.height)
    check withCuts(%["Route cache\xE2\x80\xA6"]).verdict == vPass
    let dot = withCuts(%["Route cache \xC2\xB7\xE2\x80\xA6"])
    check dot.verdict == vCut
    check "with a space or a separator before its" in dot.problems.join(" ")
    check withCuts(%["Route cache \xE2\x80\xA6"]).verdict == vCut
    let none = withCuts(nil)
    check none.verdict == vCut
    check "does not list the texts it drew cut" in none.problems.join(" ")

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

  # Each `+N` menu's hang, on a capture of each kind: hanging from its chip
  # (the laptop menu over a panel) and stopped by the window's left edge
  # (the narrow bar's menu near it). Each is moved where a view that did not
  # hang it would draw it: right-aligned under the bar, and hung from the
  # chip with the window's edge ignored.
  proc plantOf(id: string): string =
    removeDir(scratch)
    createDir(scratch)
    for ext in [".ppm", ".png", ".regions.json"]:
      copyFile(gpuiDir / (id & ext), scratch / (id & ext))
    scratch

  type HangControl = object
    menu, chip, what: string  ## as `HungMenus` names them
    hung, stopped: string     ## a laptop capture and a sidebar one whose chip
                              ## the window's left edge overrules

  const HangControls = [
    HangControl(menu: "bar-overflow-menu", chip: "bar-overflow", what: "the +N menu",
      hung: "agent-harbor-initiative-tabs-overflow-menu-over-panel-laptop-dark",
      stopped: "agent-harbor-initiative-tabs-overflow-menu-near-left-sidebar-dark"),
    HangControl(menu: "strip-overflow-menu", chip: "strip-overflow",
      what: "the session strip's +N menu",
      hung: "agent-harbor-session-tabs-menu-over-panel-laptop-dark",
      stopped: "agent-harbor-session-tabs-menu-over-panel-sidebar-dark")]

  proc movedMenu(c: HangControl; id: string; vw: int;
                 toX: proc(chip, menu: Rect): float): CaptureJudgement =
    let dir = plantOf(id)
    let path = dir / (id & ".regions.json")
    var doc = parseJson(readFile(path))
    let regions = regionsOf(doc["regions"])
    check c.menu in regions and c.chip in regions
    if c.menu notin regions or c.chip notin regions:
      return CaptureJudgement(verdict: vMissing)
    doc["regions"][c.menu]["x"] = %toX(regions[c.chip], regions[c.menu])
    writeFile(path, $doc)
    judgeCapture(id, dir, web{id}, vw, 900)

  proc namesHang(c: HangControl; j: CaptureJudgement): bool =
    for problem in j.problems:
      if "GPUI draws " & c.what & " at" in problem and "not hanging from its chip" in problem:
        return true

  test "the +N menu's captures the controls plant into pass untouched":
    for c in HangControls:
      check judgeCapture(c.hung, plantOf(c.hung), web{c.hung}, 1440, 900).verdict == vPass
      check judgeCapture(c.stopped, plantOf(c.stopped), web{c.stopped}, 360, 900).verdict == vPass

  test "a +N menu right-aligned under the bar, not hung from its chip, fails":
    # Asked of the hang check itself: moved that far, the region lies over
    # nothing but the panel's ground in the frame, and the judge stops at
    # that (a blank region) before it reaches the hang.
    for c in HangControls:
      let regions = regionsOf(parseJson(readFile(plantOf(c.hung) / (c.hung & ".regions.json")))["regions"])
      check c.menu in regions and c.chip in regions
      if c.menu in regions:
        var moved = regions
        moved[c.menu].x = 1440.0 - 12.0 - moved[c.menu].w
        check menuHangProblems("GPUI", regions, 1440).len == 0
        let problems = menuHangProblems("GPUI", moved, 1440)
        check problems.len == 1 and "GPUI draws " & c.what & " at" in problems.join(" ") and
          "not hanging from its chip" in problems.join(" ")
      check movedMenu(c, c.hung, 1440, proc(chip, menu: Rect): float =
        1440.0 - 12.0 - menu.w).verdict != vPass

  test "a +N menu one pixel past the tolerance off its chip fails, one at it passes":
    for c in HangControls:
      let at = movedMenu(c, c.hung, 1440, proc(chip, menu: Rect): float =
        chip.x + chip.w - menu.w + HangTolerancePx)
      check at.verdict == vPass
      let beyond = movedMenu(c, c.hung, 1440, proc(chip, menu: Rect): float =
        chip.x + chip.w - menu.w + HangTolerancePx + 1.0)
      check beyond.verdict == vHang
      check c.namesHang(beyond)

  test "a +N menu hung past the window's left edge, not stopped by it, fails":
    for c in HangControls:
      let j = movedMenu(c, c.stopped, 360, proc(chip, menu: Rect): float =
        chip.x + chip.w - menu.w)
      check j.verdict != vPass
      check c.namesHang(j)
    removeDir(scratch)
