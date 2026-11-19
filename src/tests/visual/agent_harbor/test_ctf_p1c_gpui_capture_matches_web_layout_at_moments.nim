## test_ctf_p1c_gpui_capture_matches_web_layout_at_moments.nim — CTF-P1c:
## **at every named moment of a playback story, the GPUI capture lays the
## story out where the web capture of the same story at the same moment
## does.**
##
## The captures, one per playback story, named moment, theme and size:
##
##   * GPUI: `ci/test/ctf-p1b-gpui-story-capture.sh` with
##     `CTF_P1B_MOMENTS=1` (`just ctf-p1b-gpui-captures` takes it, then runs
##     this lane) opens the story host `codetracer-gpui-story --moment=<name>`
##     on GuiAssert's headless sway, one REAL window per capture, paused at
##     that moment, and leaves `<capture id>.{ppm,png,regions.json}` in
##     `build/ctf-p1c/gpui/` (`CTF_P1C_GPUI_OUT` overrides);
##   * Web: `ci/test/ctf-p1b-web-capture.sh --moments` (`just
##     ctf-p1c-web-captures`) opens the same story in StoryBook at the same
##     moment (the `moment` global) and records where the browser laid out
##     each region in the committed
##     `src/tests/visual/agent-harbor-web-regions-at-moments.json`
##     (`CTF_P1C_WEB_RECORD` overrides).
##
## The capture id is `agent-harbor-<story>-at-<moment>-<size>-<theme>`. The
## playback stories and their moments are read from their one declaration
## (`stories/codetracer_stories.nim`, and each story's scenario through
## `stories/agent_harbor_playback.nim`), so a story or moment added there is
## expected here on the day it is declared.
##
## THE CHECK IS CTF-P1b's, NOT A COPY OF IT: each capture is judged by
## `ctf_layout_judge.judgeCapture`, the judge
## `test_ctf_p1b_gpui_capture_matches_web_layout.nim` runs over the first
## frames, with its tolerances unchanged (pane rectangles within
## `PaneRectangleTolerancePp` hundredths of the viewport, fills within
## `FillTolerance`, `px` edges within `PxTolerance` pixels, each `+N` menu
## within `HangTolerancePx` of its chip) and its failures (a missing, blank or
## wrongly sized frame, missing regions, NO WEB CAPTURE OF THE SAME ID, a
## region off or drawn on one side only, a different row, a wrong fill). The
## CTF-P1b test's header says why each of those is what it is.
##
## On top of the judge, the record itself must match the declaration: an
## entry naming a story or moment that no longer exists fails, so a record
## left over from a renamed moment cannot pass by being ignored.
##
## Verdicts, regions and deltas go to `build/ctf-p1c/parity/report.{json,md}`
## (`CTF_P1C_REPORT_DIR` overrides); `tools/visual-review/parity-pairs.sh
## --agent-harbor-moments` puts the side-by-side images beside it.
##
## Negative control (the second suite), over the real captures: the moments
## must be told apart. Each moment's GPUI capture is judged against the web
## record of the moment BEFORE it (a GPUI capture taken one event later than
## the web's); at least one such pair must fail on a region, or a check that
## cannot see a story move would pass every moment. The CTF-P1b test's own
## controls (blank, missing, shifted, wrong fill, `px`, row, hang) exercise
## the same judge.
##
## A fourth suite pins the plan's tolerances in absolute numbers (an edge
## 2px off passes and 3px fails, a region 1 hundredth off passes and 3
## fail, a fill 1 unit off passes and 2 fail), so a tolerance raised in the
## judge, which moves the CTF-P1b controls with it, fails here.
##
## A third suite plants one real capture's GPUI answer whether a line of
## text is cut (the active tab's title, the playback bar's moment) against
## the web's: one side cut fails the judge's `elision` rule, so does a moment
## cut anywhere or a side that gives no answer, and a title cut on both
## sides passes.
##
## No mocks: both sides are real captures of real renderers, over the
## committed synthetic playback scenarios both builds embed.
##
## Trap 13 / §29 (`Verification-Harness-Traps.md`): every helper returns what
## it found; only the test bodies `check`.

import std/[json, os, sets, strutils, tables, unittest]

import ./ctf_layout_judge
from ../../../frontend/stories/agent_harbor_playback import isPlaybackFixture,
  storyMomentNames

const
  MinimumPlaybackStories = 6
    ## The section's playback stories at CTF-P1c step 4's landing; a floor,
    ## so a declaration that lost them cannot pass by expecting nothing.
  MomentSeparator = "-at-"
    ## Between the story's view name and the moment in a capture id
    ## (`capture-storybook.mjs --moments`, `ctf_p1b_gpui_story_capture.nim`).

let gpuiDir = getEnv("CTF_P1C_GPUI_OUT", repoRoot / "build" / "ctf-p1c" / "gpui")
let webRecordPath = getEnv("CTF_P1C_WEB_RECORD", repoRoot / "src" / "tests" / "visual" /
                           "agent-harbor-web-regions-at-moments.json")
let reportDir = getEnv("CTF_P1C_REPORT_DIR", repoRoot / "build" / "ctf-p1c" / "parity")

type MomentCapture = object
  ## One expected capture: the judge's `Expected`, and the story and moment
  ## it shows.
  expected: Expected
  storyId, moment: string

proc momentCaptures(section: CodeTracerStorySection): seq[seq[MomentCapture]] =
  ## For each playback story, size and theme, its captures in the order of
  ## the story's moments (so the one before a capture is the moment before
  ## it on the story's list).
  for story in section.stories:
    if not isPlaybackFixture(story.fixture): continue
    let sid = storybookId(section, story)
    doAssert sid.startsWith(StoryIdPrefix), sid
    let view = ViewPrefix & sid[StoryIdPrefix.len .. ^1]
    let moments = storyMomentNames(story.surface, story.fixture)
    for (size, w, h) in sizesOf(story):
      for theme in Themes:
        var run: seq[MomentCapture]
        for moment in moments:
          run.add MomentCapture(storyId: sid, moment: moment,
            expected: Expected(id: view & MomentSeparator & moment & "-" & size & "-" & theme,
                               width: w, height: h))
        result.add run

proc playbackStoryCount(section: CodeTracerStorySection): int =
  for story in section.stories:
    if isPlaybackFixture(story.fixture): inc result

proc momentCaptureCount(section: CodeTracerStorySection): int =
  ## Every moment of every playback story, at each of its sizes, in each theme.
  for story in section.stories:
    if isPlaybackFixture(story.fixture):
      result += storyMomentNames(story.surface, story.fixture).len *
                sizesOf(story).len * Themes.len

let section = agentHarborSection()
let runs = momentCaptures(section)

suite "CTF-P1c: at each named moment the GPUI captures lay the stories out as the web does":
  test "test_ctf_p1c_gpui_capture_matches_web_layout_at_moments":
    check playbackStoryCount(section) >= MinimumPlaybackStories
    for story in section.stories:
      if isPlaybackFixture(story.fixture):
        check storyMomentNames(story.surface, story.fixture).len > 0
    let web = loadWebRecord(webRecordPath)
    var judgements: seq[CaptureJudgement]
    var expectedIds: HashSet[string]
    for run in runs:
      for c in run:
        expectedIds.incl c.expected.id
        judgements.add judgeCapture(c.expected.id, gpuiDir, web{c.expected.id},
                                    c.expected.width, c.expected.height)
    writeReport(judgements, "CTF-P1c: GPUI captures against the web layout at each " &
                "named moment of the playback stories", reportDir, gpuiDir, webRecordPath)
    var failing: seq[string]
    for j in judgements:
      if j.verdict != vPass:
        failing.add j.id & " [" & $j.verdict & "]: " & j.problems.join("; ")
    # The record holds no capture the declaration does not expect: a story
    # or moment renamed or removed must be re-taken, not left behind.
    var stale: seq[string]
    for id, _ in web.pairs:
      if id notin expectedIds: stale.add id
    echo "CTF-P1c layout at moments: ", judgements.len - failing.len, " of ", judgements.len,
         " captures within the tolerance; report in ", reportDir / "report.md"
    for f in failing: echo "  FAIL ", f
    for s in stale: echo "  STALE web record entry ", s, " (no playback story at that moment)"
    check judgements.len == momentCaptureCount(section)
    check failing.len == 0
    check stale.len == 0

suite "CTF-P1c: the layout check tells the moments apart (negative control)":
  test "a GPUI capture one moment later than the web's fails on a region":
    # Every moment after the first, its GPUI capture against the web record
    # of the moment before it: the playback stories change their layout
    # between moments (a tab appears, a row moves group, a notice turns
    # into a list), so some of these must fail as a layout or fill change.
    # Only a capture that passes against its own moment counts, so the
    # failure is the moment's, not a capture already failing above.
    let web = loadWebRecord(webRecordPath)
    var told: seq[string]
    var compared = 0
    for run in runs:
      for i in 1 ..< run.len:
        let later = run[i].expected
        let own = judgeCapture(later.id, gpuiDir, web{later.id}, later.width, later.height)
        if own.verdict != vPass: continue
        inc compared
        let earlier = run[i - 1].expected.id
        let j = judgeCapture(later.id, gpuiDir, web{earlier}, later.width, later.height)
        if j.verdict in {vLayout, vFill, vPixels, vHang, vCut}:
          told.add later.id & " against " & earlier & " [" & $j.verdict & "]: " &
                   (if j.problems.len > 0: j.problems[0] else: "")
    echo "  ", told.len, " of ", compared, " captures fail against the moment before them"
    for t in told[0 ..< min(told.len, 5)]: echo "    ", t
    check compared > 0
    check told.len > 0

suite "CTF-P1c: the layout check sees a line of text cut on one side (negative controls)":
  # One real capture of the initiative bar at a moment, copied into a
  # scratch directory and planted: its GPUI side's answer whether the active
  # tab's title and the bar's moment are cut, set against the web's. The
  # boxes are untouched, so only the elision check can fail them.
  let web = loadWebRecord(webRecordPath)
  var source: Expected
  for run in runs:
    for c in run:
      if c.expected.id == "agent-harbor-initiative-tabs-playback-at-recording-fails-laptop-dark":
        source = c.expected
  let scratch = getTempDir() / "ctf-p1c-elision-controls-" & $getCurrentProcessId()

  proc planted(edit: proc(regions: JsonNode)): CaptureJudgement =
    removeDir(scratch)
    createDir(scratch)
    for ext in [".ppm", ".png", ".regions.json"]:
      copyFile(gpuiDir / (source.id & ext), scratch / (source.id & ext))
    let path = scratch / (source.id & ".regions.json")
    var doc = parseJson(readFile(path))
    edit(doc["regions"])
    writeFile(path, $doc)
    judgeCapture(source.id, scratch, web{source.id}, source.width, source.height)

  test "the capture the controls plant into passes untouched, and answers both":
    check source.id.len > 0
    check web{source.id}{"regions"}{"bar-active-tab-label"}{"cut"} != nil
    check web{source.id}{"regions"}{"playback-moment"}{"cut"} != nil
    check planted(proc(r: JsonNode) = discard).verdict == vPass

  test "a title cut in GPUI and whole on the web fails, naming the region":
    let j = planted(proc(r: JsonNode) =
      r["bar-active-tab-label"]["cut"] = %(not web{source.id}["regions"]["bar-active-tab-label"]["cut"].getBool))
    check j.verdict == vCut
    check "region bar-active-tab-label: its text is cut" in j.problems.join(" ")

  test "a moment cut in GPUI fails, and so does a side that gives no answer":
    let cut = planted(proc(r: JsonNode) = r["playback-moment"]["cut"] = %true)
    check cut.verdict == vCut
    check "region playback-moment: its text is cut on GPUI, and must not be" in cut.problems.join(" ")
    let silent = planted(proc(r: JsonNode) = r["playback-moment"].delete("cut"))
    check silent.verdict == vCut
    check "GPUI gave no answer whether its text is cut" in silent.problems.join(" ")

  test "a title cut on both sides passes the `same` rule":
    var both = web{source.id}.copy
    both["regions"]["bar-active-tab-label"]["cut"] = %true
    check elisionProblems(both["regions"], both["regions"]).len == 0
    var moment = web{source.id}.copy
    moment["regions"]["playback-moment"]["cut"] = %true
    check elisionProblems(moment["regions"], moment["regions"]).len == 1
    removeDir(scratch)

suite "CTF-P1c: the tolerances are the plan's, in absolute numbers (negative controls)":
  # The CTF-P1b controls plant offsets relative to the judge's own constants
  # (`PxTolerance + 1`), so a constant doubled moves its controls with it and
  # every real capture still passes. These plant the plan's numbers (pane 2
  # hundredths, fill 1, 2px edges): an offset just inside each passes, one
  # just past it fails, whatever the constants say.
  let web = loadWebRecord(webRecordPath)
  const Id = "agent-harbor-initiative-tabs-playback-at-recording-fails-laptop-dark"
  let scratch = getTempDir() / "ctf-p1c-tolerance-controls-" & $getCurrentProcessId()

  proc gpuiMoved(region, edge: string; by: float): CaptureJudgement =
    removeDir(scratch)
    createDir(scratch)
    for ext in [".ppm", ".png", ".regions.json"]:
      copyFile(gpuiDir / (Id & ext), scratch / (Id & ext))
    let path = scratch / (Id & ".regions.json")
    var doc = parseJson(readFile(path))
    doc["regions"][region][edge] = %(web{Id}{"regions"}{region}{edge}.getFloat + by)
    writeFile(path, $doc)
    judgeCapture(Id, scratch, web{Id}, 1440, 900)

  test "a px edge 2px off passes, 3px off fails":
    check web{Id}{"regions"}{"bar-active-tab"} != nil
    check gpuiMoved("bar-active-tab", "w", 2.0).verdict == vPass
    let j = gpuiMoved("bar-active-tab", "w", 3.0)
    check j.verdict == vPixels
    check "region bar-active-tab: w is" in j.problems.join(" ")

  test "a region 1 hundredth off passes, 3 hundredths off fails":
    # `surface` declares no `px` edge and no fill: only the pane comparison
    # sees it.
    check gpuiMoved("surface", "x", 14.4).verdict == vPass
    let j = gpuiMoved("surface", "x", 43.2)
    check j.verdict == vLayout
    check "region surface" in j.problems.join(" ")

  test "a fill 1 unit off passes, 2 units off fails":
    let f = readPpm(gpuiDir / (Id & ".ppm"))
    let r = regionsOf(parseJson(readFile(gpuiDir / (Id & ".regions.json")))["regions"])["active-tab"]
    let (x, y) = fillSample(r)
    let drawn = hexOf(f, x, y)
    proc offBy(units: int): string =
      result = "#"
      for i in 0 .. 2:
        let c = parseHexInt(drawn[1 + 2 * i .. 2 + 2 * i])
        result.add toHex(if c + units <= 255: c + units else: c - units, 2).toLowerAscii
    var one = web{Id}.copy
    one["regions"]["active-tab"]["fill"] = %offBy(1)
    check judgeCapture(Id, gpuiDir, one, 1440, 900).verdict == vPass
    var two = web{Id}.copy
    two["regions"]["active-tab"]["fill"] = %offBy(2)
    check judgeCapture(Id, gpuiDir, two, 1440, 900).verdict == vFill
    removeDir(scratch)
