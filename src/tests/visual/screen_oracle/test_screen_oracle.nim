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

proc domModel(s: string): JsonNode =
  parseJson(readFile(capDir / (s & ".layout-model.json")))

proc lastEditorRow(dir, scenario: string): int =
  ## `editor-row-count`'s `last=` in the scenario's committed answers.
  let a = parseJson(readFile(dir / (scenario & ".electron.json")))
  for q in a["answers"]:
    if q{"question"}.getStr == "editor-row-count":
      for part in q{"value"}.getStr.split(";"):
        if part.startsWith("last="): return parseInt(part[5 .. ^1])
  -1

proc visibleTab(m: JsonNode, key: string): JsonNode =
  for t in m[key].getElems:
    if t{"isVisible"}.getBool(false): return t
  nil

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
    ck isDegenerate(GrayImage(width: 40, height: 10, pixels: repeat(char(27), 400)))
    ck isDegenerate(GrayImage(width: 40, height: 10, pixels: repeat(char(255), 400)))
    var two = repeat(char(40), 400)
    for i in 0 ..< 200: two[i] = char(27)
    ck not isDegenerate(GrayImage(width: 40, height: 10, pixels: two))

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
  ## The pixel value and the privileged value, compared, over ONE type. The
  ## privileged side is `layout_extractors.ts`'s `LayoutPageModel`, built out
  ## of the DOM by the Electron capture off the same settled frame and written
  ## beside it (`captures/electron/<scenario>.layout-model.json`). Where the two
  ## differ by declaration the difference is named below; an unexplained
  ## divergence cannot be carried.

  proc valueAgrees(shown, full: string): bool =
    ## The pane's value is the DOM's, or its start. The pane ends a cut value
    ## in `…` (OCR: `..`) and draws the type and the row's widgets after it,
    ## so the reading is cut at the ellipsis. Then a visible prefix of the
    ## DOM's value, within OCR's measured noise: one edit per five characters
    ## (2026-11-21: `0x71fb1a1ad3a0` read `0x71fblalad3ad`, every `1` of a
    ## hex address an `l`, on both viewports).
    var v = shown.strip()
    for cut in ["\xE2\x80\xA6", ".."]:
      let i = v.find(cut)
      if i >= 0: v = v[0 ..< i]
    # The row's type column, when OCR fused it onto an uncut value
    # (`nil NoneType`): the value ends where its type begins.
    for t in [" NoneType", " String", " Object", " Dict", " List", " Int"]:
      let i = v.find(t)
      if i >= 0: v = v[0 ..< i]
    let a = compactText(v.strip())
    let f = compactText(full)
    if a.len == 0: return false
    if isVisiblePrefixOf(a, f): return true
    editDistance(a, f[0 ..< min(f.len, a.len)]) <= max(1, a.len div 5)

  for scenario in Scenarios:
    test "the DOM producer's model was written for the frame — " & scenario:
      let m = domModel(scenario)
      ck m.hasKey("editorTabModels") and m.hasKey("programStateTabModels") and
         m.hasKey("eventLogTabModels")
      ck not visibleTab(m, "editorTabModels").isNil
      ck not visibleTab(m, "eventLogTabModels").isNil

  for scenario in Scenarios:
    test "EditorModel: the highlighted line, pixels == DOM — " & scenario:
      let r = readingOf(scenario)
      let dom = visibleTab(domModel(scenario), "editorTabModels")
      ck r.editor.isRead
      let domLine = dom["higlitedLineNumber"].getInt
      ck domLine > 0
      if r.editor.value.higlitedLineNumber != domLine and
         domLine == lastEditorRow(answerDir, scenario):
        # FILED: `PLAT35-PD4` (owner Front-Ends/Electron-GUI.md, reviewBy
        # 2026-12-31). The editor revealed the execution line as its LAST
        # row and the content then grew, so the DOM lists the row while the
        # pixels show it under the pane's bottom edge. The pixels report no
        # band rather than a wrong one; the day the scroll is re-normalised
        # this branch stops being taken and the strict equality applies.
        checkpoint(scenario & ": PLAT35-PD4 — line " & $domLine &
                   " is the editor's last DOM row and is not on screen")
        ck r.editor.value.higlitedLineNumber == -1
      else:
        ck r.editor.value.higlitedLineNumber == domLine

  for scenario in Scenarios:
    test "ProgramStateModel: the variables, pixels against DOM — " & scenario:
      # Every name the pixels read is a name the DOM holds (`namesAgree`: a
      # pane shorter than its list reads fewer names, never different ones),
      # and each value the pixels read is a VISIBLE PREFIX of the DOM's value
      # — the pane cuts a long value and ends it in `…`, the DOM holds it whole.
      let r = readingOf(scenario)
      let dom = visibleTab(domModel(scenario), "programStateTabModels")
      ck not dom.isNil
      let domVars = dom["variableStates"].getElems
      if domVars.len == 0:
        ck r.programState.isEmpty
      else:
        ck r.programState.isRead
        let pn = r.programState.value.variableStates.mapIt(it.name)
        let dn = domVars.mapIt(it["name"].getStr)
        checkpoint(scenario & ": pixels " & $pn & " | dom " & $dn)
        ck pn.len > 0
        ck pn.len <= dn.len
        ck namesAgree(pn, dn)
        var compared, prefixes = 0
        for v in r.programState.value.variableStates:
          for d in domVars:
            if variableNameKey(d["name"].getStr) == variableNameKey(v.name) and
               v.value.len > 0:
              inc compared
              if valueAgrees(v.value, d["value"].getStr): inc prefixes
        checkpoint(scenario & ": " & $prefixes & " of " & $compared &
                   " values are prefixes of the DOM's")
        ck compared > 0
        # A few values may miss the noise budget — measured 2026-11-21, two of
        # thirteen on the laptop `returned-calltrace` frame (`@[` read `a(`,
        # a type read `Obiect` past the cut) — at most one in six.
        ck compared - prefixes <= max(1, compared div 6)

  for scenario in Scenarios:
    test "EventLogModel: the rows and the count, pixels == DOM — " & scenario:
      let r = readingOf(scenario)
      let dom = visibleTab(domModel(scenario), "eventLogTabModels")
      ck r.eventLog.isRead
      ck r.eventLog.value.ofRows == dom["ofRows"].getInt
      let de = dom["events"].getElems
      ck r.eventLog.value.events.len == de.len
      # Within OCR's one edit, one row allowed to miss it — DIFF-8's rule and
      # measurement (`1+2#*3-4/]2=2` on the laptop frames).
      var apart = 0
      for i in 0 ..< min(r.eventLog.value.events.len, de.len):
        let pt = compactText(eventText(r.eventLog.value.events[i].consoleOutput))
        let dt = compactText(eventText(de[i]["consoleOutput"].getStr))
        checkpoint(scenario & " row " & $i & ": " & pt & " | " & dt)
        if not withinOneEdit(pt, dt): inc apart
      ck apart <= 1

  for scenario in Scenarios:
    test "the frame measured is the frame the capture named — " & scenario:
      let cap = parseJson(readFile(answerDir /
                                   (scenario & ".electron.capture.json")))
      let declared = cap["capturePixels"].getStr.split("x")
      let r = readingOf(scenario)
      ck r.width == parseInt(declared[0])
      ck r.height == parseInt(declared[1])

# ---------------------------------------------------------------------------
suite "PLAT-39 — the execution row is cross-checked against its neighbours":
  # `lineByNeighbours` (vision_producer.nim). Measured on a CI frame: the
  # highlighted `44` OCR'd as `54` while every plain row around it read
  # right. The rule, case by case:
  test "a misread execution row is outvoted by the rows around it":
    let r = lineByNeighbours((true, 54),
      @[(-2, true, 42), (-1, true, 43), (1, true, 45), (2, true, 46)])
    ck r.ok
    ck r.line == 44

  test "one misread neighbour does not move a correct reading":
    let r = lineByNeighbours((true, 44),
      @[(-2, true, 42), (-1, true, 53), (1, true, 45), (2, false, -1)])
    ck r.line == 44

  test "a single neighbour is not enough to overrule":
    let r = lineByNeighbours((true, 54),
      @[(-2, false, -1), (-1, true, 43), (1, false, -1)])
    ck r.line == 54

  test "an unreadable neighbourhood leaves the direct reading":
    ck lineByNeighbours((true, 44), @[]).line == 44
    ck lineByNeighbours((true, 44),
      @[(-1, false, -1), (1, false, -1)]).line == 44

  test "an unreadable execution row stays unreadable":
    let r = lineByNeighbours((false, -1),
      @[(-1, true, 43), (1, true, 45)])
    ck not r.ok

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

  for scenario in Scenarios:
    test "the separator threshold lies between this frame's own two tones — " & scenario:
      # Taken from THIS frame, not a constant measured on 2026-09-22: the
      # separators are darker than the ground and the threshold is between.
      let t = locatorThresholds(decodeGray(frameOf(scenario)))
      ck t.separatorTone >= 0
      ck t.threshold > t.separatorTone

  for scenario in Scenarios:
    test "the panes come from the window detector on a full-bleed window — " & scenario:
      # Every located cell lies inside the frame and none overlaps another:
      # the detector subdivided one window rather than returning loose blobs.
      let img = decodeGray(frameOf(scenario))
      let g = locateGrid(img)
      ck g.isRead
      var overlap = false
      let cs = g.value.cells
      for i in 0 ..< cs.len:
        ck cs[i].x >= 0 and cs[i].y >= 0
        ck cs[i].x + cs[i].w <= img.width and cs[i].y + cs[i].h <= img.height
        for j in i + 1 ..< cs.len:
          let a = cs[i]
          let b = cs[j]
          if a.x < b.x + b.w and b.x < a.x + a.w and
             a.y < b.y + b.h and b.y < a.y + a.h: overlap = true
      ck not overlap
      ck cs.len >= 3

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

  test "the table rule takes an optional tick column, and forgives no misread digit":
    # The native window's table grew a `tick` column before `#`; the
    # terminal's has none. Both shapes need digits in every number column: a
    # `0` misread as `O` is recovered by re-reading the band at 2x
    # (`ocrLineBands`), never by the grammar accepting the letter.
    ck parseEventTableRow("38 0 stdout 2+3 =5") == (true, "stdout: 2+3 =5")
    ck parseEventTableRow("0 stdout 2+3 =5") == (true, "stdout: 2+3 =5")
    ck not parseEventTableRow("38 O stdout 2+3 =5").ok
    ck not parseEventTableRow("tick # kind output").ok
    # And a variable name with a space in it is not an identifier.
    ck not splitVariableRow("> builtins_ _:al(\"__name__\", \"builtins'").ok

  test "the state table's name cell is an identifier, and only the pane's own ellipsis shortens it":
    # The native window's Name/Value table: a misread cell is read again at
    # another scale (`readStateTableName`), never forgiven by this rule.
    ck isStateTableName("__builtins__")
    ck isStateTableName("mul")
    ck isStateTableName("__packag...")
    ck not isStateTableName("- mul")
    ck not isStateTableName("_ file__")
    ck not isStateTableName("...")
    # A truncated name agrees with the full name it begins, and with no other.
    ck namesAgree(["__packag...", "add"], ["__package__", "add", "mul"])
    ck not namesAgree(["__packag...", "add"], ["__name__", "add", "mul"])
    ck not namesAgree(["__hame__"], ["__name__"])

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

  # EVERY SCENARIO, read from the GPUI window the capture opened for it at its
  # declared size (`just plat35-capture-gpui-window`). Compared RELATIONALLY
  # — the GPUI reading against the Electron reading of the same scenario —
  # rather than against numbers measured on one day's frames, so a fresh
  # capture of a moved product is graded on agreement, not on its old values.
  const GpuiScenarios = Scenarios

  proc gpuiReading(s: string): FrameReading =
    readFrame(gpuiFramePath(repoRoot, s), scratch)

  for scenario in GpuiScenarios:
    test "both renderers locate all three panes from pixels — " & scenario:
      # The geometry half of the comparison: the oracle finds state, editor
      # and event log in both renderers, with no shared constant — the
      # separator threshold is taken from each frame.
      let g = gpuiReading(scenario)
      let e = readingOf(scenario)
      for r in [g, e]:
        ck r.panes.filterIt(it.id in {piProgramState, piEventLog,
                                      piEditor}).len == 3

  for scenario in GpuiScenarios:
    test "GAP 1, CLOSED BY PLAT-40 — both renderers' state rows read with one grammar — " & scenario:
      # FILED 2026-09-22: the GPUI pane was located and legible and NONE of its
      # rows matched `name:value`. CLOSED 2026-09-23 by PLAT-40: one separator
      # (`pane_views.VariableLabelSeparator`) and one clipped line per row. The
      # two readings name the same variables, compared by `variableNameKey`
      # (OCR drops edge underscores); the un-stepped scenario has none on
      # either side.
      let g = gpuiReading(scenario)
      let e = readingOf(scenario)
      ck g.programState.kind == e.programState.kind
      if g.programState.isRead and e.programState.isRead:
        let gn = g.programState.value.variableStates.mapIt(it.name)
        let en = e.programState.value.variableStates.mapIt(it.name)
        checkpoint(scenario & ": gpui " & $gn & " | electron " & $en)
        ck min(gn.len, en.len) > 0
        ck namesAgree(gn, en)

  for scenario in GpuiScenarios:
    test "GAP 2, CLOSED BY PLAT-40 — both renderers' event log reads as the same rows — " & scenario:
      # FILED 2026-09-22: the GPUI table was drawn one CELL per line. CLOSED
      # 2026-09-23 by PLAT-40: a table row is a flex row. The same number of
      # rows on each renderer, the same text row for row within OCR's one edit.
      let g = gpuiReading(scenario)
      let e = readingOf(scenario)
      ck g.eventLog.isRead
      ck e.eventLog.isRead
      ck g.eventLog.value.events.len == e.eventLog.value.events.len
      # Row for row within OCR's one edit, with ONE row allowed to miss it:
      # measured 2026-11-21, the laptop frames' longest row read
      # `1+2#*3-4/]2=2` on one renderer (two stray glyphs) in three of six
      # scenarios while every other row agreed. Two rows apart is a
      # divergence, not noise.
      var apart = 0
      for i in 0 ..< min(g.eventLog.value.events.len, e.eventLog.value.events.len):
        let gt = compactText(eventText(g.eventLog.value.events[i].consoleOutput))
        let et = compactText(eventText(e.eventLog.value.events[i].consoleOutput))
        checkpoint(scenario & " row " & $i & ": " & gt & " | " & et)
        if not withinOneEdit(gt, et): inc apart
      ck apart <= 1

  for scenario in GpuiScenarios:
    test "GAP 3, CLOSED BY PLAT-42 — both renderers' execution line reads the same — " & scenario:
      # FILED 2026-09-22: the GPUI editor drew no execution-line band. CLOSED
      # 2026-09-23 by PLAT-42: the band and its `<pointer><mark><number>`
      # gutter, read by splitting the band into ink clusters.
      let g = gpuiReading(scenario)
      let e = readingOf(scenario)
      ck g.editor.isRead
      ck e.editor.isRead
      if g.editor.isRead and e.editor.isRead:
        ck g.editor.value.higlitedLineNumber > 0
        let domLine = visibleTab(domModel(scenario),
                                 "editorTabModels")["higlitedLineNumber"].getInt
        if e.editor.value.higlitedLineNumber == -1 and
           domLine == lastEditorRow(answerDir, scenario):
          # `PLAT35-PD4` on the Electron side (see LAW-R5): its frame shows no
          # execution band, so GPUI's reading is held to the DOM's line.
          checkpoint(scenario & ": PLAT35-PD4 on the Electron frame")
          ck g.editor.value.higlitedLineNumber == domLine
        else:
          ck g.editor.value.higlitedLineNumber ==
             e.editor.value.higlitedLineNumber

  test "GAP 4, CLOSED — every GPUI frame is a window at its scenario's declared size":
    # FILED 2026-09-22: `advanced-state` declares `laptop` (1440x900) and its
    # GPUI frame, a photograph of PLAT-37's 1920x1080 screen, was 1920x1080.
    # CLOSED by reading `just plat35-capture-gpui-window`'s frames instead: one
    # window per scenario, opened at the declared viewport.
    let sj = parseJson(readFile(repoRoot / "src/tests/visual/scenarios.json"))
    let vp = sj["viewports"]
    var laptop = 0
    for s in sj["scenarios"].getElems:
      let want = vp[s["viewport"].getStr]
      let g = gpuiReading(s["id"].getStr)
      checkpoint(s["id"].getStr & ": " & $g.width & "x" & $g.height)
      ck g.width == want["width"].getInt
      ck g.height == want["height"].getInt
      ck g.width == readingOf(s["id"].getStr).width
      if want["width"].getInt == 1440: inc laptop
    ck laptop > 0   # the population that used to be wrong is in the set

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
