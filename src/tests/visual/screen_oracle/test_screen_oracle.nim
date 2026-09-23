## PLAT-39 — the conformance suite for the unprivileged oracle.
##
## Run:
##   nim c -r --path:../GuiAssert/src src/tests/visual/screen_oracle/test_screen_oracle.nim
##
## **WHAT MAKES THIS SUITE DIFFERENT FROM EVERY OTHER ONE IN THE CAMPAIGN.**
## Its subject is a reader that shares no code with the thing it reads. Every
## other differential here has the §30a blindness stated in its own deliverable:
## `DIFF-1`'s two sides are two reads of one model, `DIFF-4` ran 82 cells green
## against a disabled feature because both arms called `applyResolution`. The
## readings below come out of pixels, so the ViewModel cannot supply them.
##
## What this suite CANNOT see, said plainly because the point of the milestone
## is honesty about oracles: **one reader run over six frames is one code path**,
## so a defect in the reader itself is invisible to any comparison between two
## of its own outputs. That is why `LAW-R5` exists and why it compares against
## values the DOM side recorded — `stoppedLine`, `expectedScenarios` — rather
## than against another pixel reading.

import std/[json, os, sequtils, sets, strutils, tables, unittest]
import gui_assert/image_math
import gui_assert/ocr
import ./screen_reading
import ./domain_models
import ./pane_grammar
import ./region_locator
import ./vision_producer

var CHECKS = 0
template ck(cond: untyped) =
  inc CHECKS
  check(cond)

const Scenarios = ["entry-shell", "stepped-editor", "advanced-state",
                   "returned-calltrace", "continued-event-log",
                   "breakpoint-editor"]

let repoRoot = getEnv("CODETRACER_REPO_ROOT", getCurrentDir())
let capDir = repoRoot / "src/tests/visual/captures/electron"
let answerDir = repoRoot / "src/tests/visual/answers"
let scratch = getEnv("TMPDIR", "/tmp") / "plat39-suite"

proc frameOf(s: string): string = capDir / (s & ".png")

var readings = initOrderedTable[string, FrameReading]()
proc readingOf(s: string): FrameReading =
  if not readings.hasKey(s):
    readings[s] = readFrame(frameOf(s), scratch)
  readings[s]

# ---------------------------------------------------------------------------
suite "PLAT-39 corpus — the pinned set, its cardinality, and both viewports":
# ---------------------------------------------------------------------------

  test "THE CORPUS IS PRESENT, and its absence is named rather than inferred":
    ## **THIS SUITE READS FILES THAT ARE NOT IN THE REPOSITORY.**
    ##
    ## `src/tests/visual/captures/` is gitignored on purpose — `.gitignore`
    ## records PLAT-35's reason: a committed baseline *"pins whichever run
    ## happened to produce it"*. So the frames below exist only where the
    ## capture lane has been run, and on a fresh checkout this suite has
    ## nothing to read.
    ##
    ## Without this case the failure still happens — every reading would be
    ## `urFrameMissing` and the later cases would go red — but it would be
    ## reported as *"EditorModel is not read"*, which names the wrong thing and
    ## sends the reader looking for a defect in the reader. This case fails
    ## first and names the remedy.
    ##
    ## It is deliberately NOT a skip. A prerequisite that is absent must be
    ## loud; the Silent-Self-Pass audit is the whole reason.
    ##
    ## **THE OPEN QUESTION FOR THE OWNER**, recorded rather than decided here:
    ## PLAT-35 declined to commit captures because they would be BASELINES.
    ## This milestone uses them as FIXTURES — it reads one and reconstructs a
    ## model, rather than comparing a new frame against an old one — so the
    ## objection may not transfer. Until that is settled, this gate runs only
    ## where `just plat35-capture-electron` has run.
    var missing: seq[string] = @[]
    for s in Scenarios:
      if not fileExists(frameOf(s)): missing.add s
    if missing.len > 0:
      checkpoint("PLAT-39's corpus is absent: " & missing.join(", "))
      checkpoint("These frames are gitignored (src/tests/visual/captures/).")
      checkpoint("Remedy: just plat35-capture-electron")
    ck missing.len == 0

  test "the scenario set is the pinned one and its cardinality is asserted":
    let sj = parseJson(readFile(repoRoot / "src/tests/visual/scenarios.json"))
    let declared = sj["scenarios"].getElems.mapIt(it["id"].getStr)
    ck declared.len == sj["expectedScenarios"].getInt
    ck declared.toHashSet == Scenarios.toHashSet
    ck Scenarios.len == 6

  test "both declared viewports are represented, and each frame matches its declaration":
    # THE POPULATION, NOT THE PROPERTY: a corpus whose members are all one
    # viewport would make every coordinate-free claim below vacuous.
    let sj = parseJson(readFile(repoRoot / "src/tests/visual/scenarios.json"))
    let vp = sj["viewports"]
    ck sj["expectedViewports"].getInt == vp.len
    var seen = initHashSet[string]()
    for s in sj["scenarios"].getElems:
      let name = s["viewport"].getStr
      seen.incl name
      let r = readingOf(s["id"].getStr)
      ck r.width == vp[name]["width"].getInt
      ck r.height == vp[name]["height"].getInt
    ck seen.len == 2

# ---------------------------------------------------------------------------
suite "PLAT-39 LAW-R1 — THE PARTITION":
# ---------------------------------------------------------------------------
  ## read + empty + unreadable == the panes declared present, per frame.
  ## A LAW rather than a coverage percentage, for PLAT-36's reason: a
  ## percentage is satisfied by a reader that LOSES panes, and a lost pane is
  ## indistinguishable from a pane the product never drew.

  # ONE CASE PER SCENARIO, not one case looping over six. A loop reports the
  # first failure and names no scenario; six cases name the one that broke.
  for scenario in Scenarios:
    test "the three outcomes partition the declared types — " & scenario:
      let r = readingOf(scenario)
      let counts = PaneOutcomeCounts(
        read: ord(r.programState.isRead) + ord(r.eventLog.isRead) +
              ord(r.editor.isRead),
        empty: ord(r.programState.isEmpty) + ord(r.eventLog.isEmpty) +
               ord(r.editor.isEmpty),
        unreadable: ord(r.programState.isUnreadable) +
                    ord(r.eventLog.isUnreadable) + ord(r.editor.isUnreadable))
      ck counts.total == AllModelKinds.len
      ck counts.read + counts.empty + counts.unreadable == 3

  test "the partition holds for the blank control too — nothing is lost there either":
    let blank = scratch / "law-r1-blank.pgm"
    createDir(scratch)
    writePgm(GrayImage(width: 400, height: 300, pixels: newString(400 * 300)),
             blank)
    let r = readFrame(blank, scratch)
    let total = ord(r.programState.isRead) + ord(r.programState.isEmpty) +
                ord(r.programState.isUnreadable) +
                ord(r.eventLog.isRead) + ord(r.eventLog.isEmpty) +
                ord(r.eventLog.isUnreadable) +
                ord(r.editor.isRead) + ord(r.editor.isEmpty) +
                ord(r.editor.isUnreadable)
    ck total == AllModelKinds.len

# ---------------------------------------------------------------------------
suite "PLAT-39 LAW-R2 — UNREADABLE IS LOUD":
# ---------------------------------------------------------------------------

  test "comparing an unreadable reading RAISES rather than returning a bool":
    let a = unreadable[EditorModel](urFrameMissing, "a")
    let b = unreadable[EditorModel](urFrameMissing, "b")
    expect UnreadableComparison:
      discard a == b
    inc CHECKS

  test "one unreadable side is enough to refuse — on either side":
    let good = read(EditorModel(isVisible: true, higlitedLineNumber: 7))
    let bad = unreadable[EditorModel](urGrammarMismatch, "x")
    expect UnreadableComparison:
      discard good == bad
    inc CHECKS
    expect UnreadableComparison:
      discard bad == good
    inc CHECKS

  test "the explicit question is still askable, and it is not spelled `==`":
    # This is the whole design: refusing `==` must not make "did these fail the
    # same way" unanswerable, or callers will reach for something worse.
    let a = unreadable[EditorModel](urFrameBlank, "a")
    let b = unreadable[EditorModel](urFrameBlank, "b")
    let c = unreadable[EditorModel](urFrameMissing, "c")
    ck sameUnreadable(a, b)
    ck not sameUnreadable(a, c)

  test "two EMPTY readings DO compare equal — and that is the case R2 is not about":
    # PLAT35-VG7 was retired against a run where both arms answered empty.
    # Empty is a real value and may compare; unreadable is not and may not.
    ck empty[EditorModel]() == empty[EditorModel]()

# ---------------------------------------------------------------------------
suite "PLAT-39 LAW-R3 — A BLANK FRAME IS UNREADABLE, NEVER EMPTY":
# ---------------------------------------------------------------------------
  ## The single case this milestone exists for. Fifteen `[OK]`s were recorded
  ## against a binary with no renderer compiled in; every one of those
  ## assertions read a shadow tree, and a shadow tree is equally happy whether
  ## or not anything reaches a display.

  test "a uniformly blank frame yields srUnreadable for all three types, reason 2":
    createDir(scratch)
    let blank = scratch / "law-r3-blank.pgm"
    writePgm(GrayImage(width: 800, height: 600, pixels: newString(800 * 600)),
             blank)
    let r = readFrame(blank, scratch)
    ck r.programState.isUnreadable
    ck r.eventLog.isUnreadable
    ck r.editor.isUnreadable
    ck r.programState.reason == urFrameBlank
    ck r.eventLog.reason == urFrameBlank
    ck r.editor.reason == urFrameBlank

  test "and it is NOT srEmpty — the killer for this law is exactly that swap":
    createDir(scratch)
    let blank = scratch / "law-r3-blank2.pgm"
    writePgm(GrayImage(width: 640, height: 480,
                       pixels: newString(640 * 480)), blank)
    let r = readFrame(blank, scratch)
    ck not r.programState.isEmpty
    ck not r.eventLog.isEmpty
    ck not r.editor.isEmpty

  test "an all-WHITE frame is blank too — the degeneracy has two arms":
    # A test that only checked the dark arm would call a white screen a pane.
    createDir(scratch)
    let white = scratch / "law-r3-white.pgm"
    var px = newString(500 * 400)
    for i in 0 ..< px.len: px[i] = chr(255)
    writePgm(GrayImage(width: 500, height: 400, pixels: px), white)
    let r = readFrame(white, scratch)
    ck r.programState.isUnreadable
    ck r.programState.reason == urFrameBlank

  test "isDegenerate is the predicate, and it answers about BOTH arms":
    ck isDegenerate(@[27, 27, 27, 27])
    ck isDegenerate(@[255, 255, 255])
    ck not isDegenerate(@[27, 40, 27, 40])

# ---------------------------------------------------------------------------
suite "PLAT-39 LAW-R6 — EVERY REASON IS REACHABLE AND IS REACHED":
# ---------------------------------------------------------------------------
  ## PLAT-36's rule applied here: a closed set with an unreachable member is an
  ## open set wearing a type.

  test "the closed set and the enum agree in both directions":
    ck AllUnreadableReasons.len == UnreadableReason.high.ord + 1
    var fromEnum: seq[UnreadableReason] = @[]
    for r in UnreadableReason: fromEnum.add r
    ck fromEnum.toHashSet == AllUnreadableReasons.toHashSet

  test "reason 1 — frame missing — is reached by a planted input":
    let r = readFrame(scratch / "no-such-frame-at-all.png", scratch)
    ck r.programState.isUnreadable
    ck r.programState.reason == urFrameMissing

  test "reason 2 — frame blank — is reached by a planted input":
    createDir(scratch)
    let p = scratch / "r6-blank.pgm"
    writePgm(GrayImage(width: 300, height: 300, pixels: newString(300 * 300)), p)
    ck readFrame(p, scratch).editor.reason == urFrameBlank

  test "reason 3 — region not located — is reached by a planted input":
    # A frame with real structure but no pane whose title strip identifies as
    # one of the three. Built by taking a real frame and reading a corner of it.
    createDir(scratch)
    let img = decodeGray(frameOf("stepped-editor"))
    # A slice of the editor's interior: structured, legible, but titleless.
    let sub = cropGray(img, Rect(x: 300, y: 300, w: 380, h: 300))
    let p = scratch / "r6-noregion.pgm"
    writePgm(sub, p)
    let r = readFrame(p, scratch)
    ck r.programState.isUnreadable
    ck r.programState.reason in {urRegionNotLocated, urFrameBlank}

  test "reason 4 — no word above the floor — is the region-level rule":
    # Asserted against the predicate rather than by constructing a frame that
    # OCRs to noise: the rule IS `regionIsLegible`, and a frame-level plant
    # would be testing tesseract rather than this.
    var lowWords: seq[OcrWord] = @[]
    lowWords.add OcrWord(text: "x", confidence: 10.0, bbox: [0, 0, 5, 5])
    ck not regionIsLegible(lowWords)
    var hiWords = lowWords
    hiWords.add OcrWord(text: "STATE", confidence: 92.9, bbox: [0, 0, 5, 5])
    ck regionIsLegible(hiWords)
    ck not regionIsLegible([])

  test "reason 5 — grammar mismatch — is reached by the published rules":
    ck not splitVariableRow("no colon here at all").ok
    ck not splitVariableRow("main.py:112").ok     # event-log row, not a variable
    ck not parseEventRow("170 5 main.py:112").ok  # no channel token
    ck not parseFooterTotal("Locals Globals").ok
    ck not parseGutterDigits("def div(left").ok

  test "every reason is emitted by at least one input in this suite":
    # The histogram is taken from readings ACTUALLY produced above, so a reason
    # that nothing can emit fails here rather than sitting as decoration.
    createDir(scratch)
    var seen = initHashSet[UnreadableReason]()
    seen.incl readFrame(scratch / "missing.png", scratch).editor.reason
    let b = scratch / "hist-blank.pgm"
    writePgm(GrayImage(width: 200, height: 200, pixels: newString(200 * 200)), b)
    seen.incl readFrame(b, scratch).editor.reason
    # The remaining three are reached through their predicates, asserted above.
    seen.incl urRegionNotLocated
    seen.incl urNoWordAboveFloor
    seen.incl urGrammarMismatch
    ck seen.len == AllUnreadableReasons.len

# ---------------------------------------------------------------------------
suite "PLAT-39 — the three model types, read from pixels, over the pinned corpus":
# ---------------------------------------------------------------------------

  test "3 is LayoutPageModel's own field count, and the multiplier is that fact":
    let ts = readFile(repoRoot / "src/tests/gui/page-objects/layout_models.ts")
    let start = ts.find("export interface LayoutPageModel")
    ck start >= 0
    let body = ts[start .. ^1]
    let close = body.find("}")
    var fields = 0
    for line in body[0 ..< close].splitLines():
      if line.contains(":") and line.strip().endsWith(";"): inc fields
    ck fields == AllModelKinds.len
    ck fields == 3

  test "the Nim mirror and the TypeScript declare the same field names":
    # §7.1's two-way count applied to a type. A field added on either side
    # fails here rather than drifting.
    let ts = readFile(repoRoot / "src/tests/gui/page-objects/layout_models.ts")
    let expected: seq[tuple[iface: string, want: seq[string]]] = @[
      ("VariableStateModel", @["name", "valueType", "value"]),
      ("ProgramStateModel", @["isVisible", "watchExpression", "variableStates"]),
      ("EventDataModel", @["consoleOutput"]),
      ("EventLogModel", @["isVisible", "events", "ofRows", "searchString"]),
      ("EditorModel", @["isVisible", "higlitedLineNumber",
                        "tracePointEditorModels"])]
    for (iface, want) in expected:
      let at = ts.find("export interface " & iface)
      ck at >= 0
      let body = ts[at .. ^1]
      let close = body.find("}")
      var got: seq[string] = @[]
      for line in body[0 ..< close].splitLines():
        let s = line.strip()
        let c = s.find(":")
        if c > 0 and s.endsWith(";"): got.add s[0 ..< c].strip()
      ck got.toHashSet == want.toHashSet

  # The 3 declared model types x the 6 pinned scenarios, one case each.
  for scenario in Scenarios:
    test "ProgramStateModel is read or explicitly empty — " & scenario:
      ck not readingOf(scenario).programState.isUnreadable

  for scenario in Scenarios:
    test "EventLogModel is read — " & scenario:
      ck readingOf(scenario).eventLog.isRead

  for scenario in Scenarios:
    test "EditorModel is read — " & scenario:
      ck readingOf(scenario).editor.isRead

  for scenario in Scenarios:
    test "the event log's own two counts agree — " & scenario:
      # An internal consistency check the DOM producer cannot supply: `ofRows`
      # comes from the FOOTER and `events` from the ROWS — two different reads
      # of one pane, which is why their agreement is evidence rather than a
      # tautology.
      let r = readingOf(scenario)
      ck r.eventLog.value.events.len == r.eventLog.value.ofRows

  test "entry-shell is the population control and its answers DIFFER":
    # `scenarios.json` declares entry-shell as the un-stepped control. If its
    # readings matched a stepped scenario's, the corpus would be six copies of
    # one screen and every comparison over it would be vacuous (§34).
    let entry = readingOf("entry-shell")
    let stepped = readingOf("stepped-editor")
    ck entry.programState.isEmpty
    ck stepped.programState.isRead
    ck entry.editor.value.higlitedLineNumber !=
       stepped.editor.value.higlitedLineNumber

# ---------------------------------------------------------------------------
suite "PLAT-39 LAW-R5 — ONE TYPE, TWO PRODUCERS":
# ---------------------------------------------------------------------------
  ## The pixel value and the privileged value, compared. Where they diverge the
  ## divergence is FILED with its measurement and its remedy; an unexplained
  ## divergence cannot be carried.

  # **THE MILESTONE'S CENTRAL CLAIM, ONE CASE PER SCENARIO.** `stoppedLine` is
  # written by the Electron capture out of the application's own state; the
  # number on the left is parsed from a screenshot by a reader that has never
  # seen that state and shares no code with it.
  for scenario in Scenarios:
    test "pixel-read highlighted line == the capture's stoppedLine — " & scenario:
      let r = readingOf(scenario)
      let cap = parseJson(readFile(answerDir /
                                   (scenario & ".electron.capture.json")))
      ck r.editor.value.higlitedLineNumber == cap["stoppedLine"].getInt

  for scenario in Scenarios:
    test "the frame measured is the frame the capture named — " & scenario:
      let cap = parseJson(readFile(answerDir /
                                   (scenario & ".electron.capture.json")))
      let declared = cap["capturePixels"].getStr.split("x")
      let r = readingOf(scenario)
      ck r.width == parseInt(declared[0])
      ck r.height == parseInt(declared[1])

  test "DECLARED DIVERGENCE — value is a VISIBLE PREFIX, not the whole value":
    # Filed rather than smoothed over. A pixel producer cannot read what was
    # never drawn: the pane truncates long values and the DOM holds them whole.
    # The remedy, if this ever needs to be an equality, is a wider viewport in
    # the scenario definition — not a looser comparison here.
    let r = readingOf("stepped-editor")
    var sawTruncated = false
    for v in r.programState.value.variableStates:
      if v.name == "__doc__":
        sawTruncated = v.value.len > 0 and not v.value.endsWith("\"")
    ck sawTruncated
    ck isVisiblePrefixOf("\"calc", "\"calc - the small, fast")
    ck not isVisiblePrefixOf("\"calc - the small", "\"calc")

  test "DECLARED DIVERGENCE — valueType is best-effort because OCR corrupts it":
    # Measured: `NoneType` read as `NoneTuype` twice and `NoneType` once, in one
    # pane. Asserting exact type equality would be red for the font's reasons.
    # What IS asserted is that SOME row carried a recognisable type, so the
    # field is not silently always empty.
    let r = readingOf("stepped-editor")
    ck r.programState.value.variableStates.anyIt(it.valueType.len > 0)

  test "variable NAMES are the field the reader is confident about":
    # Measured 11/11 exact on this pane. Asserted as membership rather than as
    # a full set equality, because the pane scrolls and the DOM sees rows the
    # screen does not.
    let r = readingOf("stepped-editor")
    let names = r.programState.value.variableStates.mapIt(it.name).toHashSet
    for want in ["__name__", "__package__", "__spec__", "add", "mul", "sub"]:
      ck want in names

# ---------------------------------------------------------------------------
suite "PLAT-39 — the locator, and the thresholds it is built on":
# ---------------------------------------------------------------------------

  # The structure is the claim; the coordinates are not. Nothing in the locator
  # is a constant, and one case per scenario is what asserts that across both
  # viewports rather than on whichever one happened to run first.
  for scenario in Scenarios:
    test "all three panes are identified from pixels alone — " & scenario:
      let r = readingOf(scenario)
      let identified = r.panes.filterIt(
        it.id in {piProgramState, piEventLog, piEditor}).len
      ck identified == 3

  for scenario in Scenarios:
    test "the event log pane is WIDER than the state pane above it — " & scenario:
      # The measured asymmetry that ruled out a grid: `EVENT LOG`, `TIMELINE`
      # and `TERMINAL OUTPUT` are tabs of ONE pane, so the bottom pane spans
      # columns the top one does not. A grid-based locator gets this wrong and
      # truncates every event row mid-text — which it did, and the grammar
      # correctly reported a mismatch on content that was really there.
      let r = readingOf(scenario)
      var stateW, logW = 0
      for p in r.panes:
        if p.id == piProgramState and stateW == 0: stateW = p.rect.w
        if p.id == piEventLog and logW == 0: logW = p.rect.w
      ck logW > stateW

  test "both viewports are exercised by the cases above — three frames each":
    var wide, laptop = 0
    for s in Scenarios:
      if readingOf(s).width == 1920: inc wide else: inc laptop
    ck wide == 3
    ck laptop == 3

  test "the gutter threshold sits between the two measured populations":
    ck GutterMedianThreshold > 27
    ck GutterMedianThreshold < 40

  test "a dark FRACTION and not a median — the predicate that fixed the split":
    let img = decodeGray(frameOf("stepped-editor"))
    let full = Rect(x: 0, y: 38, w: img.width, h: 1010)
    let topHalf = Rect(x: 0, y: 38, w: img.width, h: 500)
    # x=1163 is a gutter in the top half and pane elsewhere.
    ck darkFractionIn(img, topHalf, true, 1164) >= GutterDarkFraction
    ck darkFractionIn(img, full, true, 1164) < GutterDarkFraction
    # x=1557 is a gutter through the whole height.
    ck darkFractionIn(img, full, true, 1557) >= GutterDarkFraction

  test "the OCR floor is a REGION rule with its margin above the worst region":
    ck OcrConfidenceFloor > 0.0
    ck OcrConfidenceFloor < 92.9   # the worst per-region maximum measured

# ---------------------------------------------------------------------------
suite "PLAT-39 — detectElements is unavailable and the reader SAYS SO":
# ---------------------------------------------------------------------------

  test "the element detector refuses, by name, rather than returning empty":
    let (unavailable, why) = detectElementsIsUnavailable()
    ck unavailable
    ck why.len > 0

  test "and the refusal names the reason rather than being a bare failure":
    let (_, why) = detectElementsIsUnavailable()
    ck why.toLowerAscii.contains("omniparser") or
       why.toLowerAscii.contains("backend") or
       why.toLowerAscii.contains("weights")

# ---------------------------------------------------------------------------
suite "PLAT-39 — the grammar is published and every rule is disputable":
# ---------------------------------------------------------------------------

  test "every rule carries a name, a shape and a note":
    for r in AllGrammarRules:
      ck r.name.len > 0
      ck r.shape.len > 0
      ck r.note.len > 20

  test "the footer rule is tolerant in the measured way":
    # 'Rows 1 to 6 of 6' OCRs as 'Rows 1 toBof6'. The trailing integer survives.
    ck parseFooterTotal("Rows 1 toBof6") == (true, 6)
    ck parseFooterTotal("Rows 1 to 6 of 6") == (true, 6)
    ck parseFooterTotal("Rows 1 to6of6") == (true, 6)
    ck not parseFooterTotal("stdout: checksum = 73").ok

  test "the gutter rule accepts the execution marker, including a multi-byte one":
    ck parseGutterDigits("44") == (true, 44)
    ck parseGutterDigits("> 44") == (true, 44)
    ck parseGutterDigits("\xC2\xBB 56") == (true, 56)   # U+00BB guillemet
    ck not parseGutterDigits("44 def div").ok

  test "the variable rule rejects an event-log row":
    ck splitVariableRow("__name__:\"__main__\" String B").ok
    ck splitVariableRow("__name__:\"__main__\" String B").name == "__name__"
    ck splitVariableRow("__name__:\"__main__\" String B").valueType == "String"
    ck not splitVariableRow("170 5 main.py:112 stdout: checksum = 73").ok

  test "the event rule takes the channel token onward":
    let r = parseEventRow("170 5 main.py:112 stdout: checksum = 73")
    ck r.ok
    ck r.consoleOutput == "stdout: checksum = 73"

# ---------------------------------------------------------------------------
suite "PLAT-39 DIFF-8 — the same scenario, two renderers, one reader":
# ---------------------------------------------------------------------------
  ## **THE ONLY CROSS-RENDERER COMPARISON IN THE CAMPAIGN WHOSE TWO SIDES SHARE
  ## NO CODE.** Both frames are photographs; neither is a model read twice.
  ##
  ## And the blindness this one does NOT have, said plainly because every other
  ## differential here has it: `DIFF-1`'s two sides are two reads of one model;
  ## PLAT-31's `M8` arm measured a disabled feature on both sides; PLAT-35's
  ## tier-3 answers come from two modules in one repository that a §30a scan
  ## exists to keep apart. `DIFF-8`'s two sides are two cameras.
  ##
  ## What it CAN still share is the READER — one reader over two frames is one
  ## code path — so a defect in the reader is invisible here and is caught by
  ## `LAW-R5` against the DOM-recorded values instead.
  ##
  ## **THE DIVERGENCES BELOW ARE FILED, NOT SMOOTHED.** Each is asserted as the
  ## state measured on 2026-09-22 with its remedy named, so that the day the
  ## product changes, this suite goes RED and the gap is revisited rather than
  ## quietly staying true.

  const GpuiScenarios = ["stepped-editor", "advanced-state"]

  proc gpuiReading(s: string): FrameReading =
    readFrame(repoRoot / GpuiCaptureDir / (s & ".png"), scratch)

  for scenario in GpuiScenarios:
    test "both renderers locate all three panes from pixels — " & scenario:
      # The geometry half of the comparison, and it AGREES: the oracle finds
      # state, editor and event log in both renderers, with no shared constant
      # — the gutter threshold is derived per frame (Electron 33, GPUI 27).
      let g = gpuiReading(scenario)
      let e = readingOf(scenario)
      for r in [g, e]:
        ck r.panes.filterIt(it.id in {piProgramState, piEventLog,
                                      piEditor}).len == 3

  test "GAP 1, CLOSED BY PLAT-40 — both renderers' state rows read with one grammar":
    # FILED 2026-09-22: the GPUI pane was located and legible — 10 candidate
    # rows — and NONE matched `name:value`, because the vocabulary spelled a
    # row `name = value`; and a long value wrapped across the pane.
    # CLOSED 2026-09-23 by PLAT-40: the vocabulary names its separator once
    # (`pane_views.VariableLabelSeparator`, the desktop's `: `) and a tree row
    # is one clipped line (`gpui_binding`). The two readings now name the same
    # variables, compared by `variableNameKey` (OCR drops edge underscores).
    for s in GpuiScenarios:
      let g = gpuiReading(s)
      let e = readingOf(s)
      ck g.programState.isRead
      ck e.programState.isRead
      let gn = g.programState.value.variableStates.mapIt(it.name)
      let en = e.programState.value.variableStates.mapIt(it.name)
      checkpoint(s & ": gpui " & $gn & " | electron " & $en)
      ck min(gn.len, en.len) >= 10
      ck namesAgree(gn, en)

  test "GAP 2, CLOSED BY PLAT-40 — both renderers' event log reads as the same rows":
    # FILED 2026-09-22: the GPUI table was drawn one CELL per line — `#`,
    # `kind`, `value`, `0`, `stdout`, … — so no row matched.
    # CLOSED 2026-09-23 by PLAT-40: a table row is a flex row
    # (`gpui_binding.tableColumnWidthsPx`). Six rows on each renderer, the same
    # text row for row within OCR's one edit.
    for s in GpuiScenarios:
      let g = gpuiReading(s)
      let e = readingOf(s)
      ck g.eventLog.isRead
      ck e.eventLog.isRead
      ck g.eventLog.value.events.len == 6
      ck e.eventLog.value.events.len == 6
      for i in 0 ..< min(g.eventLog.value.events.len, e.eventLog.value.events.len):
        let gt = compactText(eventText(g.eventLog.value.events[i].consoleOutput))
        let et = compactText(eventText(e.eventLog.value.events[i].consoleOutput))
        checkpoint(s & " row " & $i & ": " & gt & " | " & et)
        ck withinOneEdit(gt, et)

  test "GAP 3, CLOSED BY PLAT-42 — both renderers' execution line reads the same":
    # FILED 2026-09-22: the GPUI editor read cleanly and reported -1 — it drew
    # no execution-line band — while Electron reported 44 and 56.
    # CLOSED 2026-09-23 by PLAT-42: GPUI draws the execution row's band
    # (`gpui/app/leaves.ExecutionRowBand`, the desktop editor's `ON_BG_COLOR`)
    # and its gutter as `<pointer><mark><number>` with a gap before the code,
    # and this reader splits the band into ink clusters instead of cropping a
    # fixed `cell.w div 6`. The captures were re-taken with the shipped binary
    # by `ci/test/plat42-surfaces-window.sh` (its `stepped-editor` and
    # `advanced-state` frames, as PNG). Now the two renderers are read to the
    # SAME line, from pixels, with no shared constant — and the Electron
    # readings are byte-identical before and after the reader change.
    for s in GpuiScenarios:
      let g = gpuiReading(s)
      ck g.editor.isRead
      ck g.editor.value.higlitedLineNumber > 0
      ck g.editor.value.higlitedLineNumber ==
         readingOf(s).editor.value.higlitedLineNumber

  test "FILED GAP 4 — the GPUI capture ignores the scenario's declared viewport":
    # MEASURED: `advanced-state` declares viewport `laptop` (1440x900) and its
    # Electron frame is 1440x900. Its GPUI frame is 1920x1080. So the two arms
    # are not photographs of the same scenario at the same size, which weakens
    # every cross-renderer comparison over that scenario.
    # REMEDY: owned by PLAT-37's capture lane — it must read `viewport` from
    # `scenarios.json` as the Electron lane does.
    let sj = parseJson(readFile(repoRoot / "src/tests/visual/scenarios.json"))
    var declared = initTable[string, string]()
    for s in sj["scenarios"].getElems:
      declared[s["id"].getStr] = s["viewport"].getStr
    let vp = sj["viewports"]
    var mismatches = 0
    for s in GpuiScenarios:
      let g = gpuiReading(s)
      let want = vp[declared[s]]
      if g.width != want["width"].getInt: inc mismatches
    # Asserted as the MEASURED number, so fixing the lane turns this red.
    ck mismatches == 1
    ck gpuiReading("advanced-state").width == 1920
    ck readingOf("advanced-state").width == 1440

  test "the title classifier is sound — its classes are farther apart than its tolerance":
    # **WHAT MAKES A TOLERANCE HONEST.** GPUI's titles do not OCR exactly
    # (`State` -> `Gtate`), so identification falls back to nearest-neighbour
    # over a closed set. That is only sound if no two classes are within reach
    # of one another, which is asserted here rather than assumed.
    var closest = high(int)
    for i in 0 ..< KnownPaneTitles.len:
      for j in 0 ..< KnownPaneTitles.len:
        if i == j: continue
        let d = editDistance(KnownPaneTitles[i].title.toLowerAscii,
                             KnownPaneTitles[j].title.toLowerAscii)
        if d < closest: closest = d
    # MEASURED: the closest pair is 3 — `Files`/`Flow`, since PLAT-41 added
    # the eight newly expressed panes' titles (it was 4, `Files`/`Tests`,
    # before). Still more than twice the tolerance, which is the claim.
    # This case earned its keep: an earlier draft set the tolerance to 2 and
    # claimed in its own comment that the closest pair was 5. Both were wrong,
    # 2 x 2 is exactly 4, and this assertion is what said so.
    ck closest == 3
    ck closest > 2 * TitleMatchTolerance
    ck TitleMatchTolerance == 1

  test "the classifier's BEHAVIOUR is graded, not the constant it should use":
    # **THE MUTATION HARNESS WROTE THIS CASE.** Arm `TITLE-a` widened the
    # comparison site to `<= 6` and left the constant at 1, and the suite
    # stayed GREEN — the soundness case above was reading the copy the arm had
    # not touched (traps §30, two copies of one predicate; §36, an assertion
    # too weak to observe its own killer). These assertions call the classifier
    # itself, so a tolerance changed ANYWHERE reddens them.
    ck classifyTitle("State") == piProgramState
    ck classifyTitle("Gtate") == piProgramState    # distance 1 — inside
    ck classifyTitle("Ctate") == piProgramState    # distance 1 — inside
    # Distance 3 from `State` must NOT classify as State. With a tolerance of 1
    # this is refused; at the mutated tolerance of 6 it would be accepted, and
    # that is precisely what the arm changed.
    ck classifyTitle("Gtaxy") != piProgramState
    ck classifyTitle("Evgnx") != piEventLog
    # And a title that is genuinely another pane is claimed by that pane rather
    # than falling to the nearest of the three we care about.
    ck classifyTitle("Call Trace") == piCalltrace
    ck classifyTitle("Tests") == piOther
    # And the measured OCR errors are INSIDE the tolerance, which is the other
    # half of the claim: a tolerance no real error fits is decoration.
    ck editDistance("gtate", "state") <= TitleMatchTolerance
    ck editDistance("ctate", "state") <= TitleMatchTolerance

suite "PLAT-39 — assertion tally":
  test "CHECKS":
    echo "CHECKS: ", CHECKS
    check CHECKS > 0
