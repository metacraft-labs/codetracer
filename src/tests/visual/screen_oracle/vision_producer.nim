## PLAT-39 — the pixel producer: a frame in, domain models out.
##
## **THE SECOND PRODUCER FOR TYPES THE DOM PRODUCER ALSO BUILDS.** Everything
## here starts from an image file and ends at `domain_models`. There is no
## selector, no attribute, no `pane-rectangles` answer, and no import from
## `viewmodel/` or from the page objects — `ci/test/plat39-oracle-independence.sh`
## asserts that mechanically, in both polarities, with a derived subject set.
##
## **WHY THAT INDEPENDENCE IS THE POINT.** `Verification-Harness-Traps.md` §30a
## is this campaign's most persistent defect: a differential measures only what
## its two sides compute *differently*, so everything shared is invisible.
## `DIFF-4` ran 82 cells green against a disabled feature because both arms
## called `applyResolution`; PLAT-33's `G4` made a convergence oracle call the
## merge function it was checking and all 102 cases stayed green. A reading
## taken from pixels shares no code path with the ViewModel, so it cannot be
## accidentally re-derived from its own subject.
##
## **AND IT IS THE INSTRUMENT THAT WOULD HAVE CAUGHT THE CAMPAIGN'S WORST
## FAILURE**: fifteen `[OK]`s against a binary with no renderer compiled in.
## Every one of those assertions read a shadow tree, and a shadow tree is
## equally happy whether or not anything reaches a display. A model parsed from
## pixels comes back `srUnreadable`.

import std/[algorithm, os, osproc, sequtils, strutils, tables]
import gui_assert/image_math
import gui_assert/ocr
import ./screen_reading
import ./domain_models
import ./pane_grammar
import ./region_locator

type
  PaneId* = enum
    piUnknown = "unknown"
    piProgramState = "state"
    piEventLog = "eventLog"
    piEditor = "editor"
    piCalltrace = "calltrace"
      ## PLAT-40. Claimed by `KnownPaneTitles` before PLAT-40 as `piOther`, so
      ## that it could WIN against the three panes PLAT-39 read; it is read now.
    piPointList = "pointList"
      ## PLAT-40. The breakpoint and tracepoint list.
    piDebugControls = "debugControls"
    piFlow = "flow"
    piTimeline = "timeline"
    piSearch = "search"
    piScratchpad = "scratchpad"
    piShell = "shell"
    piFileTree = "fileTree"
    piBuildOutput = "buildOutput"
      ## PLAT-41. The eight panes that had no view, read off the native
      ## window where a layout places them.
    piOther = "other"

  LocatedPane* = object
    id*: PaneId
    rect*: Rect
    titleText*: string

  FrameReading* = object
    ## Everything one frame yielded, including the panes that could not be
    ## read. `LAW-R1` asserts read + empty + unreadable == panes declared
    ## present, so the failures have to be CARRIED rather than dropped.
    framePath*: string
    width*, height*: int
    panes*: seq[LocatedPane]
    programState*: ScreenReading[ProgramStateModel]
    eventLog*: ScreenReading[EventLogModel]
    editor*: ScreenReading[EditorModel]

const
  PaneTitleKeywords*: array[4, tuple[id: PaneId, words: seq[string]]] = [
    (piProgramState, @["STATE"]),
    # PLAT-40. The desktop titles the breakpoint list's TAB `POINT LIST`, the
    # native window titles its pane `Breakpoints`; neither is near enough to
    # the other for the nearest-neighbour classifier, so both are keywords.
    (piPointList, @["POINT LIST", "BREAKPOINTS"]),
    (piEventLog, @["EVENT", "EVENTLOG"]),
    (piEditor, @[".PY", ".PYTHON", "MAIN.PY", "CALC/MAIN.PY", "EDITOR"])]
    ## Titles as the TITLE STRIP renders them, uppercased before matching.
    ##
    ## **THE TWO FRONT-ENDS TITLE THE EDITOR DIFFERENTLY, AND BOTH SPELLINGS
    ## ARE HERE BECAUSE THE READER MUST BE RENDERER-AGNOSTIC.** Electron titles
    ## the pane with the open FILE NAME — `calc/main.py` — so it is matched on
    ## the extension; there is no fixed word to match and a reader that
    ## expected "EDITOR" would find no editor in any Electron frame. The GPUI
    ## front-end titles the same pane `Editor`. A reader that knew only one
    ## spelling would report `urRegionNotLocated` on the other renderer, and
    ## `DIFF-8` would then be comparing a reading against a failure to read.

  GpuiCaptureDir* = "src/tests/visual/captures/gpui"
    ## Frames from the GPUI front-end, captured by PLAT-37's windowed lane on a
    ## real Wayland compositor and committed as fixtures, exactly as PLAT-35
    ## commits the Electron ones. `DIFF-8` reads both directories.

proc cropGray*(img: GrayImage, r: Rect): GrayImage =
  ## In-memory crop. No subprocess: the frame is already decoded, and shelling
  ## out to ffmpeg once per region would dominate the cost of reading a frame.
  let x0 = clamp(r.x, 0, max(0, img.width - 1))
  let y0 = clamp(r.y, 0, max(0, img.height - 1))
  let w = clamp(r.w, 0, img.width - x0)
  let h = clamp(r.h, 0, img.height - y0)
  result = GrayImage(width: w, height: h, pixels: newString(w * h))
  for row in 0 ..< h:
    let src = (y0 + row) * img.width + x0
    let dst = row * w
    if w > 0:
      copyMem(addr result.pixels[dst], unsafeAddr img.pixels[src], w)

proc writePgm*(img: GrayImage, path: string) =
  ## A binary PGM (P5), which tesseract reads through leptonica. Verified
  ## 2026-09-22 against tesseract 5.5.1: a hand-written P5 crop OCRs correctly.
  var f = open(path, fmWrite)
  defer: f.close()
  f.write("P5\n" & $img.width & " " & $img.height & "\n255\n")
  if img.pixels.len > 0:
    discard f.writeBuffer(unsafeAddr img.pixels[0], img.pixels.len)

const
  TitleRetryExtraPx* = 14
    ## How much taller the retried title strip is. The native window's title
    ## glyphs end 44 px below the cell's top edge (measured on PLAT-40's
    ## frame), 14 px past `TitleStripHeight`.
  BandInkDelta = 40
    ## A pixel is INK when its gray level is this far from the region's
    ## median — the region's background, since text covers a minority of it.
  BandMinInkPixels = 2
    ## A pixel row with fewer ink pixels than this is blank.
  BandSliverPx = 3
    ## An ink run this short is a stroke (an underscore), not a line.
  BandSliverGapPx = 4
    ## How far below the line before it a sliver may start and still be its.

proc ocrRegion*(img: GrayImage, r: Rect, scratch: string,
                psm = 6, upscale = 1.0): seq[OcrWord] =
  ## OCR one region. Returns every word, INCLUDING low-confidence ones — see
  ## `pane_grammar.OcrConfidenceFloor` for why the floor is applied to the
  ## region rather than to each word.
  let sub = cropGray(img, r)
  if sub.width <= 0 or sub.height <= 0: return @[]
  let path = scratch / ("region_" & $r.x & "_" & $r.y & "_" &
                        $r.w & "x" & $r.h & ".pgm")
  writePgm(sub, path)
  try:
    result = runOcrEx(path, initOcrOptions(psm = psm, upscale = upscale))
  except CatchableError:
    result = @[]
  finally:
    removeFile(path)

proc lineBands*(img: GrayImage, r: Rect): seq[Rect] =
  ## The region's TEXT LINES, found by ink projection rather than by the OCR
  ## engine: each maximal run of pixel rows carrying ink, padded by two rows.
  let sub = cropGray(img, r)
  if sub.width <= 0 or sub.height <= 0: return @[]
  var levels = newSeq[int](sub.pixels.len)
  for i, c in sub.pixels: levels[i] = ord(c)
  levels.sort()
  let bg = levels[levels.len div 2]
  var start = -1
  for y in 0 .. sub.height:
    var ink = 0
    if y < sub.height:
      for x in 0 ..< sub.width:
        if abs(ord(sub.pixels[y * sub.width + x]) - bg) > BandInkDelta: inc ink
    if y < sub.height and ink >= BandMinInkPixels:
      if start < 0: start = y
    elif start >= 0:
      let top = max(0, start - 2)
      let bottom = min(sub.height, y + 2)
      let band = Rect(x: r.x, y: r.y + top, w: r.w, h: bottom - top)
      # A SLIVER IS PART OF THE LINE ABOVE IT. An underscore is drawn below
      # the baseline with a blank row between it and the letters, so a line
      # of `__cached__` split into the letters and a band of strokes, and OCR
      # read the letters as `cached` (measured on the native window's state
      # pane). A band no taller than `BandSliverPx` within `BandSliverGapPx`
      # of the one before is merged into it.
      if result.len > 0 and y - start <= BandSliverPx and
         band.y - (result[^1].y + result[^1].h) <= BandSliverGapPx:
        result[^1].h = band.y + band.h - result[^1].y
      else:
        result.add band
      start = -1

proc ocrLineBands*(img: GrayImage, r: Rect, scratch: string): seq[string] =
  ## Each of `lineBands` OCR'd as ONE line (`psm 7`). The fallback for a
  ## region the engine's own line grouping mis-segments: measured on PLAT-40's
  ## native-window event log, whose narrow, aligned columns tesseract grouped
  ## COLUMN by column in every page-segmentation mode — `# 0 2 3 4 1 kind
  ## stdout stdout …` — while each row read alone is exact.
  for band in lineBands(img, r):
    let words = ocrRegion(img, band, scratch, psm = 7)
    let line = words.mapIt(it.text).join(" ").strip()
    if line.len > 0: result.add line

func regionIsLegible*(words: openArray[OcrWord]): bool =
  ## The region-level confidence test. See `OcrConfidenceFloor`.
  if words.len < MinRegionWords: return false
  words.anyIt(it.confidence >= OcrConfidenceFloor)

func linesOf*(words: openArray[OcrWord]): seq[string] =
  ## Regroup words into lines using tesseract's own numbering, rather than by
  ## clustering y-coordinates — the engine's line breaks are the ones that
  ## produced the boxes, and a second, worse line-breaker here could disagree
  ## with them.
  ##
  ## **THE KEY IS (blockNum, lineNum) AND NOT lineNum ALONE.** Measured:
  ## tesseract's `line_num` restarts within each block, so grouping on it by
  ## itself merges words from unrelated parts of a pane. That is not a
  ## hypothetical — it produced a variable row whose value read
  ## `nil 44 def div(left, NoneType right): B`, which is one variable's value
  ## interleaved with the current-line header from a different block. The rows
  ## are sorted by their top edge so the output order is the reading order
  ## rather than tesseract's internal block order.
  var byLine = initOrderedTable[(int, int), seq[OcrWord]]()
  for w in words:
    if w.text.strip().len == 0: continue
    byLine.mgetOrPut((w.blockNum, w.lineNum), @[]).add w
  var rows: seq[tuple[top: int, text: string]] = @[]
  for _, ws in byLine:
    var s = @ws
    s.sort(proc (a, b: OcrWord): int = cmp(a.bbox[0], b.bbox[0]))
    var top = high(int)
    for w in s: top = min(top, w.bbox[1])
    rows.add (top, s.mapIt(it.text).join(" "))
  rows.sort(proc (a, b: auto): int = cmp(a.top, b.top))
  rows.mapIt(it.text)

func editDistance*(a, b: string): int =
  ## Plain Levenshtein. Small strings only — pane titles.
  var prev = newSeq[int](b.len + 1)
  var cur = newSeq[int](b.len + 1)
  for j in 0 .. b.len: prev[j] = j
  for i in 1 .. a.len:
    cur[0] = i
    for j in 1 .. b.len:
      let cost = if a[i - 1] == b[j - 1]: 0 else: 1
      cur[j] = min(min(cur[j - 1] + 1, prev[j] + 1), prev[j - 1] + cost)
    prev = cur
  prev[b.len]

const
  TitleMatchTolerance* = 1
    ## **A NEAREST-NEIGHBOUR CLASSIFIER OVER A CLOSED SET, NOT A LOOSENED
    ## COMPARISON — and the difference is asserted, not asserted-to-be.**
    ##
    ## Measured 2026-09-22. The GPUI front-end's pane titles do not OCR
    ## exactly, at any setting tried: `State` reads as `Gtate` or `Ctate`,
    ## `Debug Controls` as `DNebua Controle` or `Debiia Controls`, `Event Log`
    ## as `Event | o0`. Every combination of upscale (1x, 2x, 3x), inversion
    ## (auto / always / never) and contrast was tried and NONE returns `State`.
    ## This is a property of that renderer's thin antialiased text on a very
    ## dark background, and no amount of tuning removes it.
    ##
    ## Substring matching therefore cannot identify a GPUI pane, and the
    ## tempting repair — drop to matching two or three characters — is the
    ## dishonest one, because it makes every class overlap every other.
    ##
    ## What makes a tolerance sound is that the CLASSES ARE FARTHER APART THAN
    ## THE TOLERANCE, and both halves of that are measured rather than claimed:
    ##
    ##   closest pair of known titles : 4  (`Files`/`Tests`, `State`/`Tests`)
    ##   largest OCR error to cover   : 1  (`Gtate`->`State`, `Ctate`->`State`)
    ##
    ## So 1 separates them with the class gap at four times the tolerance. **An
    ## earlier draft of this constant said 2 and asserted the closest pair was
    ## 5; both were wrong, and the suite's own soundness case caught it** —
    ## 2 x 2 is exactly 4, so a tolerance of 2 could in principle reach halfway
    ## to a neighbouring class. The numbers above are the measured ones.
    ##
    ## The two larger errors measured — `Debiia Controls` for `Debug Controls`
    ## and `Event | o0` for `Event Log`, both distance 3 — are deliberately NOT
    ## covered by this fallback and do not need to be: those panes are
    ## identified by the exact keyword stage above, which `Event | o0` passes
    ## on `EVENT`. Widening the tolerance to swallow them would push it past
    ## the class separation and make the classifier unsound, to fix something
    ## that is not broken.
    ##
    ## `test_screen_oracle.nim` asserts the pairwise separation over the full
    ## set in both directions, so adding a title that collides with an existing
    ## one fails the build rather than silently making the classifier
    ## ambiguous.
    ##
    ## Exact matching is still preferred and tried first; this is the fallback.

  KnownPaneTitles*: array[15, tuple[id: PaneId, title: string]] = [
    (piProgramState, "State"),
    (piEventLog, "Event Log"),
    (piEditor, "Editor"),
    (piDebugControls, "Debug Controls"),
    (piCalltrace, "Call Trace"),
    (piPointList, "Breakpoints"),
    (piFileTree, "Files"),
    (piOther, "Tests"),
    (piOther, "Constraints"),
    (piScratchpad, "Scratchpad"),
    (piFlow, "Flow"),
    (piTimeline, "Timeline"),
    (piSearch, "Search"),
    (piShell, "Shell"),
    (piBuildOutput, "Build")]
    ## The closed set the classifier chooses from. `piOther` entries are here
    ## precisely so they can WIN: a title that is really `Call Trace` must be
    ## claimed by a class rather than falling to the nearest of the three we
    ## care about. Without them, `Call Trace` would be classified as whichever
    ## of State/Editor/Event Log it happened to be least unlike.

func classifyTitle*(title: string): PaneId =
  ## **THE NEAREST-NEIGHBOUR DECISION, AS ONE PURE FUNCTION.**
  ##
  ## Extracted from `identifyPane` because the suite could not otherwise SEE
  ## this decision. The soundness case used to assert a property of the
  ## CONSTANT — `closest > 2 * TitleMatchTolerance` — while the classification
  ## happened at a comparison site elsewhere. Those are two copies of one
  ## predicate (`Verification-Harness-Traps.md` §30), and the mutation harness
  ## proved it: arm `TITLE-a` widened the comparison to `<= 6`, leaving the
  ## constant at 1, and **the suite stayed green** because the assertion was
  ## reading the copy the arm had not touched. That is §36 — a published
  ## killing mutation is a claim about the ASSERTION, and this one was too weak
  ## to observe its own killer.
  ##
  ## One function, one tolerance, and the suite now grades the thing that
  ## actually classifies rather than the number it is supposed to classify by.
  let tokens = title.splitWhitespace()
  if tokens.len == 0: return piUnknown
  var bestId = piOther
  var bestDist = high(int)
  var runnerUp = high(int)
  for (id, known) in KnownPaneTitles:
    # Try the leading 1 and 2 tokens, since "Call Trace" and "Event Log" are
    # two words while "State" is one.
    for take in 1 .. min(2, tokens.len):
      let candidate = tokens[0 ..< take].join(" ")
      let d = editDistance(candidate.toLowerAscii, known.toLowerAscii)
      if d < bestDist:
        runnerUp = bestDist
        bestDist = d
        bestId = id
      elif d < runnerUp:
        runnerUp = d
  if bestDist <= TitleMatchTolerance and bestDist < runnerUp:
    return bestId
  piOther

proc identifyPane*(img: GrayImage, cell: Rect, scratch: string): LocatedPane =
  ## Identify a cell by OCRing its title strip alone.
  ##
  ## Two stages: an exact keyword match, which is what the Electron titles
  ## satisfy, and a nearest-neighbour fallback over `KnownPaneTitles` for
  ## renderers whose titles do not OCR cleanly. See `TitleMatchTolerance`.
  let words = ocrRegion(img, titleStrip(cell), scratch, psm = 7)
  let title = words.mapIt(it.text).join(" ").strip()
  let upper = title.toUpperAscii
  result = LocatedPane(id: piOther, rect: cell, titleText: title)
  if title.len == 0:
    result.id = piUnknown
    return
  for (id, keys) in PaneTitleKeywords:
    for k in keys:
      if upper.contains(k):
        result.id = id
        return
  result.id = classifyTitle(title)
  # **A TITLE NO CLASS CLAIMS IS READ AGAIN, FROM A TALLER STRIP.** Measured
  # on PLAT-40's native-window frame: that front-end draws its titles lower
  # in the cell than the desktop, so `TitleStripHeight` (the desktop's
  # measurement) cuts their descenders and `Breakpoints` OCRs as
  # `Rreaknointe` — three edits from anything, at any upscale — while a strip
  # `TitleRetryExtraPx` taller reads it exactly. Only a title that classified
  # as NOTHING is retried, and the retry's answer is taken only when it names
  # a pane, so a title that is genuinely another pane keeps its answer.
  if result.id == piOther:
    let strip = titleStrip(cell)
    let taller = Rect(x: strip.x, y: strip.y, w: strip.w,
                      h: min(strip.h + TitleRetryExtraPx, cell.h))
    let big = ocrRegion(img, taller, scratch, psm = 7)
    let retitled = big.mapIt(it.text).join(" ").strip()
    let again = classifyTitle(retitled)
    if again != piOther and again != piUnknown:
      result.id = again
      result.titleText = retitled

# ---------------------------------------------------------------------------
# The three readers
# ---------------------------------------------------------------------------

func isStateChrome(u: string): bool =
  ## A state-pane line that is chrome rather than a row: the tab strip, the
  ## watch box, and the pane's own name where a front-end repeats it (the
  ## native window draws `State` above its tabs).
  u.startsWith("LOCALS") or u.startsWith("GLOBALS") or
    u.startsWith("WATCHES") or u.contains("ENTER A WATCH") or u == "STATE"

proc readProgramState*(img: GrayImage, cell: Rect,
                       scratch: string): ScreenReading[ProgramStateModel] =
  let words = ocrRegion(img, bodyBelowTitle(cell), scratch)
  if words.len == 0:
    return unreadable[ProgramStateModel](urNoWordAboveFloor,
      "state pane located at " & $cell & " but OCR returned no words")
  if not regionIsLegible(words):
    return unreadable[ProgramStateModel](urNoWordAboveFloor,
      "no word in the state pane reached confidence " & $OcrConfidenceFloor)
  var model = ProgramStateModel(isVisible: true, watchExpression: "")
  var matched = 0
  var considered = 0
  let allText = linesOf(words).join(" ").toUpperAscii
  # **THE ENGINE'S LINES FIRST, THE BANDS WHEN THEY FAIL THE GRAMMAR** — the
  # event log's rule (`readEventLog`), for the same measured reason: on the
  # native window's state pane the engine fused every row into three lines.
  var lines = linesOf(words)
  block retry:
    var parsed, unparsed = 0
    for line in lines:
      let t = line.strip()
      if t.len == 0 or isStateChrome(t.toUpperAscii): continue
      if splitVariableRow(t).ok and t.count(':') <= 2: inc parsed
      else: inc unparsed
    if unparsed == 0: break retry
    let banded = ocrLineBands(img, bodyBelowTitle(cell), scratch)
    var bandParsed = 0
    for line in banded:
      if splitVariableRow(line).ok: inc bandParsed
    if bandParsed > parsed: lines = banded
  # **THE PRODUCT'S OWN EMPTY MESSAGE IS THE BEST POSSIBLE `srEmpty` SIGNAL.**
  #
  # `entry-shell` stops before the first statement and the pane draws *"No
  # local variables are present in the current point of execution."* That is
  # the application stating emptiness, which is a far stronger warrant than
  # inferring it from a row count — and PLAT-23 measured why inference is
  # dangerous here: its pane census moved from `locals=0` to `locals=8` on one
  # step, so "no rows parsed" and "genuinely nothing" had been the same answer.
  # Matching the message keeps those two apart at the source.
  if allText.contains("NO LOCAL VARIABLES ARE PRESENT"):
    return empty[ProgramStateModel]()
  for line in lines:
    let s = line.strip()
    if s.len == 0: continue
    # The tab row and the watch-expression placeholder are chrome, not rows.
    let u = s.toUpperAscii
    if isStateChrome(u):
      continue
    inc considered
    let parsed = splitVariableRow(s)
    if parsed.ok:
      inc matched
      model.variableStates.add VariableStateModel(
        name: parsed.name, valueType: parsed.valueType, value: parsed.value)
  if considered == 0:
    # Located, legible, and nothing that even looked like a row. A program
    # stopped before its first statement genuinely has no locals, and that is
    # `srEmpty` — the one case where emptiness is a real answer.
    return empty[ProgramStateModel]()
  if matched == 0:
    return unreadable[ProgramStateModel](urGrammarMismatch,
      "state pane had " & $considered & " candidate rows and none matched " &
      ProgramStateGrammar.shape)
  read(model)

proc readEventLog*(img: GrayImage, cell: Rect,
                   scratch: string): ScreenReading[EventLogModel] =
  let words = ocrRegion(img, bodyBelowTitle(cell), scratch)
  if words.len == 0:
    return unreadable[EventLogModel](urNoWordAboveFloor,
      "event log located at " & $cell & " but OCR returned no words")
  if not regionIsLegible(words):
    return unreadable[EventLogModel](urNoWordAboveFloor,
      "no word in the event log reached confidence " & $OcrConfidenceFloor)
  var model = EventLogModel(isVisible: true, searchString: "", ofRows: 0)
  var sawFooter = false
  var candidateRows = 0
  # **THE ENGINE'S LINES FIRST, THE BANDS WHEN THEY FAIL THE GRAMMAR.** A line
  # the rules could not parse is the signal that the engine grouped the
  # region wrongly (`ocrLineBands`); the bands are read only then, and taken
  # only when they parse MORE rows, so a region the engine read correctly is
  # never re-read.
  var lines = linesOf(words)
  block retry:
    var parsed, unparsed = 0
    for line in lines:
      let s = line.strip()
      if s.len == 0: continue
      # FUSION IS TESTED BEFORE THE CHROME FILTER: measured on the desktop's
      # event log once it gained a header row, the engine fused the search
      # box, the header and five rows into ONE line, and a filter that ran
      # first dropped the whole line as "the search box" — no retry, two rows.
      if eventRowsFused(s):
        inc unparsed
        continue
      if s.toUpperAscii.contains("FIND EVENT"): continue
      if parseEventRow(s).ok or parseEventTableRow(s).ok: inc parsed
      elif not parseFooterTotal(s).ok and
           s.splitWhitespace() != @["#", "kind", "value"]: inc unparsed
    if unparsed == 0: break retry
    let banded = ocrLineBands(img, bodyBelowTitle(cell), scratch)
    var bandParsed = 0
    for line in banded:
      if (parseEventRow(line).ok and not eventRowsFused(line)) or
         parseEventTableRow(line).ok: inc bandParsed
    if bandParsed > parsed: lines = banded
  for line in lines:
    let s = line.strip()
    if s.len == 0: continue
    # **THE ROW RULE IS TRIED BEFORE THE CHROME FILTER, NOT AFTER.**
    #
    # Measured: on the 1920x1080 frames the reader returned 5 events where the
    # footer said 6 and the 1440x900 frames returned 6. The missing row was not
    # missing — OCR had fused it onto the same line as the search box, and the
    # chrome filter dropped the whole line before the row rule ever saw it. A
    # filter that runs first can therefore delete real data, so anything that
    # satisfies the published row grammar is taken as a row no matter what else
    # shares its line.
    let row = parseEventRow(s)
    if row.ok:
      inc candidateRows
      model.events.add EventDataModel(consoleOutput: row.consoleOutput)
      continue
    # PLAT-40: the vocabulary's table row, which the terminal and the native
    # window draw. Tried second, so the desktop's rule keeps first claim.
    let tableRow = parseEventTableRow(s)
    if tableRow.ok:
      inc candidateRows
      model.events.add EventDataModel(consoleOutput: tableRow.consoleOutput)
      continue
    # The table's own header row is chrome.
    if s.splitWhitespace() == @["#", "kind", "value"]: continue
    let footer = parseFooterTotal(s)
    if footer.ok:
      model.ofRows = footer.total
      sawFooter = true
      continue
    if s.toUpperAscii.contains("FIND EVENT"): continue  # the search box
    inc candidateRows
  if model.events.len == 0 and not sawFooter and candidateRows == 0:
    return empty[EventLogModel]()
  if model.events.len == 0 and candidateRows > 0:
    return unreadable[EventLogModel](urGrammarMismatch,
      "event log had " & $candidateRows & " candidate rows and none matched " &
      EventLogGrammar.shape)
  read(model)

proc readCalltrace*(img: GrayImage, cell: Rect,
                    scratch: string): ScreenReading[CalltraceModel] =
  ## PLAT-40. `CalltraceGrammar` over the pane's body.
  let words = ocrRegion(img, bodyBelowTitle(cell), scratch)
  if words.len == 0:
    return unreadable[CalltraceModel](urNoWordAboveFloor,
      "call trace located at " & $cell & " but OCR returned no words")
  if not regionIsLegible(words):
    return unreadable[CalltraceModel](urNoWordAboveFloor,
      "no word in the call trace reached confidence " & $OcrConfidenceFloor)
  var model = CalltraceModel(isVisible: true)
  var considered = 0
  for line in linesOf(words):
    let s = line.strip()
    if s.len == 0: continue
    let u = s.toUpperAscii
    # The product's own empty message, and its search box, are chrome.
    if u.contains("NO CALL TRACE") or u.contains("SEARCH"): continue
    inc considered
    let row = parseCallRow(s)
    if row.ok: model.calls.add CallRowModel(name: row.name)
  if model.calls.len == 0:
    if considered == 0: return empty[CalltraceModel]()
    return unreadable[CalltraceModel](urGrammarMismatch,
      "call trace had " & $considered & " candidate rows and none matched " &
      CalltraceGrammar.shape)
  read(model)

proc readPointList*(img: GrayImage, cell: Rect,
                    scratch: string): ScreenReading[PointListModel] =
  ## PLAT-40. `PointListGrammar` over the pane's body.
  let words = ocrRegion(img, bodyBelowTitle(cell), scratch)
  if words.len == 0:
    return unreadable[PointListModel](urNoWordAboveFloor,
      "point list located at " & $cell & " but OCR returned no words")
  if not regionIsLegible(words):
    return unreadable[PointListModel](urNoWordAboveFloor,
      "no word in the point list reached confidence " & $OcrConfidenceFloor)
  var model = PointListModel(isVisible: true)
  var considered = 0
  for line in linesOf(words):
    let s = line.strip()
    if s.len == 0: continue
    let u = s.toUpperAscii
    # The product's own empty messages are the `srEmpty` signal, stated by the
    # application rather than inferred from a row count (PLAT-39's rule).
    if u.contains("NO BREAKPOINTS OR TRACEPOINTS") or
       u.contains("NO TRACEPOINT COLLECTIONS"):
      return empty[PointListModel]()
    if u == "POINTS" or u.startsWith("SELECTED"): continue
    inc considered
    let row = parsePointRow(s)
    if row.ok:
      model.points.add PointRowModel(kind: row.kind, fileName: row.fileName,
                                     lineNumber: row.lineNumber)
  if model.points.len == 0:
    if considered == 0: return empty[PointListModel]()
    return unreadable[PointListModel](urGrammarMismatch,
      "point list had " & $considered & " candidate rows and none matched " &
      PointListGrammar.shape)
  read(model)

const
  MinGutterGapPx = 14
    ## A run of background at least this wide separates two ink CLUSTERS in
    ## the band. Wider than one character cell of either front-end's gutter
    ## face (~9 px), so a number is never split across clusters.
  MaxGutterClusters = 3
    ## Electron's gutter is two clusters (the arrow, ~30 px left of the
    ## number, then the number); GPUI's is one (`▶ 44`). A third covers a
    ## mark drawn in its own lane.

proc inkClusters*(img: GrayImage; cell: Rect; band: GutterRun): seq[(int, int)] =
  ## The band's ink, left to right, as `[first, last]` column spans separated
  ## by at least `MinGutterGapPx` of the band's own background.
  let x0 = cell.x + 2
  let x1 = min(img.width, cell.x + cell.w div 2)
  if x1 <= x0 or band.last < band.first: return
  var hist: array[256, int]
  for y in band.first .. band.last:
    for x in x0 ..< x1:
      inc hist[int(img.pixels[y * img.width + x])]
  var bg = 0
  for v in 1 .. 255:
    if hist[v] > hist[bg]: bg = v
  proc inkAt(x: int): bool =
    for y in band.first .. band.last:
      if abs(int(img.pixels[y * img.width + x]) - bg) > 40: return true
    false
  var start = -1
  var lastInk = -1
  for x in x0 ..< x1:
    if inkAt(x):
      if start < 0: start = x
      elif x - lastInk > MinGutterGapPx:
        result.add (start, lastInk)
        start = x
      lastInk = x
  if start >= 0: result.add (start, lastInk)

proc readGutterDigits*(img: GrayImage; cell: Rect; band: GutterRun;
                       scratch: string):
    tuple[ok: bool, line: int, text: string, right: int] =
  ## The gutter number of the row in `band` — the execution row's, when the
  ## editor reader calls it; any row's, for a record that reads rows — and the
  ## x the gutter cell it read ends at.
  ##
  ## PLAT-42, 2026-09-23. The crop was a fixed `cell.w div 6` — Electron's
  ## gutter on Electron's panes. GPUI's editor pane is 276 px wide at
  ## 1440x900, so the crop was 46 px: it cut `113` to `1]`, and — worse — cut
  ## `44` to `4`, a WRONG reading the grammar accepts. (Read at 1x: a 2x
  ## upscale was tried and read `» 110` as `p» 110`, which the grammar
  ## rightly rejects.) So the gutter is read
  ## by whole ink clusters: the shortest prefix of the band's clusters (up to
  ## `MaxGutterClusters`) that parses as `EditorGrammar`. A cluster is bounded
  ## by a gap wider than a character, so no prefix can end mid-number. When no
  ## prefix parses the reading is unreadable — see the note at the end.
  let clusters = inkClusters(img, cell, band)
  # THREE READINGS, TRIED IN ORDER, each measured, each asked only when the
  # ones before it read nothing the grammar accepts:
  #   1. a 2 px margin at 1x — reads Electron's 22 px band and nearly every
  #      GPUI row;
  #   2. a third of the band's height at 1x — GPUI's last visible row,
  #      clipped to 18 px by the pane's edge, read `-'1"1'0` with 2 px and
  #      `» 110` with this;
  #   3. the 2 px margin at 2x — the same clipped row at another stop read
  #      `b.'l.'i'i` both ways at 1x and `» 113` at 2x.
  # The order is part of the rule: the proportional margin tried FIRST read
  # Electron's `44` as `4`, and 2x tried first read `» 110` as `p» 110`.
  let pad = 2
  let tall = max(pad, (band.last - band.first + 1) div 3)
  for (margin, upscale) in [(pad, 1.0), (tall, 1.0), (pad, 2.0)]:
    for k in 1 .. min(MaxGutterClusters, clusters.len):
      let crop = Rect(x: cell.x, y: band.first - margin,
                      w: clusters[k - 1][1] - cell.x + 3,
                      h: band.last - band.first + 1 + 2 * margin)
      let words = ocrRegion(img, crop, scratch, psm = 7, upscale = upscale)
      if words.len == 0: continue
      let text = words.mapIt(it.text).join(" ")
      let parsed = parseGutterDigits(text)
      if parsed.ok: return (true, parsed.line, text, crop.x + crop.w)
  # NO FIXED-WIDTH FALLBACK. It existed until the cluster rule was verified
  # on PLAT-39's own Electron corpus (all six read through clusters, the
  # record unchanged), and it was measured to be dangerous: on a GPUI frame
  # whose clusters did not parse it cropped `44` to `4` and returned a WRONG
  # line the grammar accepts. A band nothing reads is unreadable, by name.
  var shown = ""
  if clusters.len > 0:
    let crop = Rect(x: cell.x, y: band.first - pad,
                    w: clusters[min(MaxGutterClusters, clusters.len) - 1][1] -
                       cell.x + 3,
                    h: band.last - band.first + 1 + 2 * pad)
    shown = ocrRegion(img, crop, scratch, psm = 7).mapIt(it.text).join(" ")
  (false, -1, shown, -1)

proc readEditor*(img: GrayImage, cell: Rect,
                 scratch: string): ScreenReading[EditorModel] =
  ## **THE HIGHLIGHTED ROW IS FOUND GEOMETRICALLY, THEN ITS GUTTER IS OCR'd.**
  ##
  ## Measured 2026-09-22: OCRing the editor pane as text does not reliably
  ## recover line numbers — a gutter-plus-code strip returned line 44 as `42`
  ## and lost most other numbers. But the execution line has a distinct
  ## background, and that is a clean pixel signal: in `stepped-editor`'s editor
  ## cell the row medians are 40 for 946 rows and 51/64 for exactly one
  ## contiguous run of 22. Locating first and reading a digits-only cell second
  ## is what makes this field recoverable at all.
  let body = bodyBelowTitle(cell)
  let rm = rowMedians(img, cell.x + 2, cell.x + cell.w - 2)
  if rm.len == 0:
    return unreadable[EditorModel](urRegionNotLocated, "no rows in editor cell")
  # The pane's own background is its most common row median.
  var hist = initCountTable[int]()
  for y in body.y ..< min(body.y + body.h, rm.len):
    hist.inc rm[y]
  if hist.len == 0:
    return unreadable[EditorModel](urRegionNotLocated, "editor body is empty")
  let base = hist.largest.key
  var runs: seq[GutterRun] = @[]
  var y = body.y
  while y < min(body.y + body.h, rm.len):
    if rm[y] != base:
      var j = y
      while j < min(body.y + body.h, rm.len) and rm[j] != base: inc j
      if j - y >= 8:  # a highlighted text row is ~22 px; 8 excludes rules/borders
        runs.add GutterRun(first: y, last: j - 1)
      y = j
    else:
      inc y
  var model = EditorModel(isVisible: true, higlitedLineNumber: -1)
  if runs.len == 0:
    # No execution line drawn. The pane IS visible and readable; the DOM
    # producer reports -1 for exactly this state, so this is `read`, not
    # `empty` and not `unreadable`.
    return read(model)
  # The widest run is the execution line; a selection or hover band is thinner.
  var best = runs[0]
  for r in runs:
    if r.last - r.first > best.last - best.first: best = r
  let parsed = readGutterDigits(img, cell, best, scratch)
  if parsed.text.len == 0:
    return unreadable[EditorModel](urNoWordAboveFloor,
      "highlighted row located at y=" & $best.first & " but its gutter OCR'd empty")
  if not parsed.ok:
    return unreadable[EditorModel](urGrammarMismatch,
      "gutter cell read as " & parsed.text.escape & ", which is not " &
      EditorGrammar.shape)
  model.higlitedLineNumber = parsed.line
  read(model)

# ---------------------------------------------------------------------------
# The frame-level entry point
# ---------------------------------------------------------------------------

proc readFrame*(framePath: string, scratch: string): FrameReading =
  ## Read one frame into the three declared models.
  ##
  ## Every failure mode returns a typed `srUnreadable`; none of them returns an
  ## empty model. That is the difference this milestone exists to make.
  result.framePath = framePath
  if not fileExists(framePath):
    let why = "no file at " & framePath
    result.programState = unreadable[ProgramStateModel](urFrameMissing, why)
    result.eventLog = unreadable[EventLogModel](urFrameMissing, why)
    result.editor = unreadable[EditorModel](urFrameMissing, why)
    return

  var img: GrayImage
  try:
    img = decodeGray(framePath)
  except CatchableError as e:
    let why = "decode failed: " & e.msg
    result.programState = unreadable[ProgramStateModel](urFrameMissing, why)
    result.eventLog = unreadable[EventLogModel](urFrameMissing, why)
    result.editor = unreadable[EditorModel](urFrameMissing, why)
    return
  result.width = img.width
  result.height = img.height

  let grid = locateGrid(img)
  if grid.isUnreadable:
    result.programState = unreadable[ProgramStateModel](grid.reason, grid.detail)
    result.eventLog = unreadable[EventLogModel](grid.reason, grid.detail)
    result.editor = unreadable[EditorModel](grid.reason, grid.detail)
    return

  createDir(scratch)
  for cell in grid.value.cells:
    result.panes.add identifyPane(img, cell, scratch)

  var stateCell, logCell, edCell = Rect(x: -1, y: -1, w: 0, h: 0)
  for p in result.panes:
    case p.id
    of piProgramState: (if stateCell.x < 0: stateCell = p.rect)
    of piEventLog: (if logCell.x < 0: logCell = p.rect)
    of piEditor: (if edCell.x < 0: edCell = p.rect)
    else: discard

  result.programState =
    if stateCell.x < 0:
      unreadable[ProgramStateModel](urRegionNotLocated,
        "no cell's title strip identified a state pane")
    else: readProgramState(img, stateCell, scratch)

  result.eventLog =
    if logCell.x < 0:
      unreadable[EventLogModel](urRegionNotLocated,
        "no cell's title strip identified an event log pane")
    else: readEventLog(img, logCell, scratch)

  result.editor =
    if edCell.x < 0:
      unreadable[EditorModel](urRegionNotLocated,
        "no cell's title strip identified an editor pane")
    else: readEditor(img, edCell, scratch)

proc detectElementsIsUnavailable*(): tuple[unavailable: bool, why: string] =
  ## **`ocr.detectElements` IS NOT USED, AND THE READER SAYS SO BY NAME.**
  ##
  ## Measured rather than assumed: its only non-trivial backend, `ebOmniParser`,
  ## ALWAYS raises `OcrBackendUnavailable` because no weights are bundled. This
  ## proc calls it and reports the refusal, so "we did not use the element
  ## detector" is a checked statement rather than a claim in a comment — and if
  ## weights are ever bundled, this goes green and the milestone's reasoning
  ## has to be revisited rather than silently staying stale.
  try:
    discard detectElements("/nonexistent-frame-for-availability-probe.png",
                           ebOmniParser)
    (false, "detectElements did not raise: the element detector is now available")
  except CatchableError as e:
    (true, e.msg)

# ---------------------------------------------------------------------------
# PLAT-40 — the three producer-fed panes, read off one frame
# ---------------------------------------------------------------------------

type
  ProducerPanesReading* = object
    ## What one frame yielded for the three panes PLAT-40 feeds. A separate
    ## entry point from `readFrame` so PLAT-39's three-model reading, and the
    ## tallies asserted over it, are unchanged by the two models added here.
    framePath*: string
    width*, height*: int
    panes*: seq[LocatedPane]
    calltrace*: ScreenReading[CalltraceModel]
    eventLog*: ScreenReading[EventLogModel]
    pointList*: ScreenReading[PointListModel]

proc readProducerPanes*(framePath: string, scratch: string): ProducerPanesReading =
  result.framePath = framePath
  template allUnreadable(reason: UnreadableReason; why: string) =
    result.calltrace = unreadable[CalltraceModel](reason, why)
    result.eventLog = unreadable[EventLogModel](reason, why)
    result.pointList = unreadable[PointListModel](reason, why)
  if not fileExists(framePath):
    allUnreadable(urFrameMissing, "no file at " & framePath)
    return
  var img: GrayImage
  try:
    img = decodeGray(framePath)
  except CatchableError as e:
    allUnreadable(urFrameMissing, "decode failed: " & e.msg)
    return
  result.width = img.width
  result.height = img.height
  let grid = locateGrid(img)
  if grid.isUnreadable:
    allUnreadable(grid.reason, grid.detail)
    return
  createDir(scratch)
  for cell in grid.value.cells:
    result.panes.add identifyPane(img, cell, scratch)
  var ctCell, logCell, plCell = Rect(x: -1, y: -1, w: 0, h: 0)
  for p in result.panes:
    case p.id
    of piCalltrace: (if ctCell.x < 0: ctCell = p.rect)
    of piEventLog: (if logCell.x < 0: logCell = p.rect)
    of piPointList: (if plCell.x < 0: plCell = p.rect)
    else: discard
  result.calltrace =
    if ctCell.x < 0:
      unreadable[CalltraceModel](urRegionNotLocated,
        "no cell's title strip identified a call trace")
    else: readCalltrace(img, ctCell, scratch)
  result.eventLog =
    if logCell.x < 0:
      unreadable[EventLogModel](urRegionNotLocated,
        "no cell's title strip identified an event log pane")
    else: readEventLog(img, logCell, scratch)
  result.pointList =
    if plCell.x < 0:
      unreadable[PointListModel](urRegionNotLocated,
        "no cell's title strip identified a point list")
    else: readPointList(img, plCell, scratch)

# ---------------------------------------------------------------------------
# PLAT-41 — the eight newly expressed panes, read off one frame
# ---------------------------------------------------------------------------

type
  QuietPane* = object
    ## A pane whose TRUE answer on an unexercised session is its own empty
    ## message — search before anyone searches, the scratchpad before anyone
    ## pins, the shell before anyone types, and the build pane in replay.
    pane*: PaneId
    reading*: ScreenReading[seq[string]]
      ## `srEmpty` when the body holds only the pane's chrome and its empty
      ## message; `srRead` with the other lines when it holds more.

  NewPanesReading* = object
    framePath*: string
    width*, height*: int
    panes*: seq[LocatedPane]
    transport*: ScreenReading[TransportModel]
    flow*: ScreenReading[FlowPaneModel]
    timeline*: ScreenReading[TimelineModel]
    fileTree*: ScreenReading[FileTreeModel]
    quiet*: seq[QuietPane]

const
  QuietPanes* = [piSearch, piScratchpad, piShell, piBuildOutput]
  QuietChrome* = ["SEARCH", "SHELL"]
    ## An Input's own label, which each of those panes draws above its
    ## (empty) body.

proc bodyLines(img: GrayImage; cell: Rect; scratch: string): seq[string] =
  ## A pane body's lines, by the engine; by ink bands when the engine returns
  ## nothing legible (a pane of short labels OCRs poorly as one block).
  let words = ocrRegion(img, bodyBelowTitle(cell), scratch)
  if regionIsLegible(words):
    result = linesOf(words)
  if result.len == 0:
    result = ocrLineBands(img, bodyBelowTitle(cell), scratch)

proc readTransport*(img: GrayImage; cell: Rect; scratch: string):
    ScreenReading[TransportModel] =
  var model = TransportModel(isVisible: true)
  var lines = bodyLines(img, cell, scratch)
  # A label per LINE: the engine can fuse two short buttons into one line,
  # so a line that is no label is retried as bands before it counts.
  var unmatched = 0
  for l in lines:
    if not parseTransportLabel(l).ok: inc unmatched
  if unmatched > 0:
    let banded = ocrLineBands(img, bodyBelowTitle(cell), scratch)
    var bandHits = 0
    for l in banded:
      if parseTransportLabel(l).ok: inc bandHits
    if bandHits > lines.len - unmatched: lines = banded
  for l in lines:
    let t = parseTransportLabel(l)
    if t.ok and t.label notin model.actions: model.actions.add t.label
  if model.actions.len == 0:
    if lines.len == 0: return empty[TransportModel]()
    return unreadable[TransportModel](urGrammarMismatch,
      $lines.len & " lines and none named a control: " & TransportGrammar.shape)
  read(model)

proc readTimeline*(img: GrayImage; cell: Rect; scratch: string):
    ScreenReading[TimelineModel] =
  let lines = bodyLines(img, cell, scratch)
  for l in lines:
    let t = parseTimelinePosition(l)
    if t.ok:
      return read(TimelineModel(isVisible: true, currentTick: t.current,
                                lastTick: t.last))
  if lines.len == 0: return empty[TimelineModel]()
  unreadable[TimelineModel](urGrammarMismatch,
    $lines.len & " lines and none matched " & TimelineGrammar.shape)

proc readFlowPane*(img: GrayImage; cell: Rect; scratch: string):
    ScreenReading[FlowPaneModel] =
  var lines = bodyLines(img, cell, scratch)
  var model = FlowPaneModel(isVisible: true)
  var parsed = 0
  for l in lines:
    if parseFlowRow(l).ok: inc parsed
  if parsed < lines.len:
    let banded = ocrLineBands(img, bodyBelowTitle(cell), scratch)
    var bandParsed = 0
    for l in banded:
      if parseFlowRow(l).ok: inc bandParsed
    if bandParsed > parsed: lines = banded
  for l in lines:
    if l.toUpperAscii.contains("NO FLOW STEPS"): return empty[FlowPaneModel]()
    let r = parseFlowRow(l)
    if r.ok:
      model.rows.add FlowRowModel(location: r.location, expression: r.expression)
  if model.rows.len == 0:
    if lines.len == 0: return empty[FlowPaneModel]()
    return unreadable[FlowPaneModel](urGrammarMismatch,
      $lines.len & " lines and none matched " & FlowRowGrammar.shape)
  read(model)

proc readFileTree*(img: GrayImage; cell: Rect; scratch: string):
    ScreenReading[FileTreeModel] =
  let lines = bodyLines(img, cell, scratch)
  var model = FileTreeModel(isVisible: true)
  for l in lines:
    let t = l.strip(chars = Whitespace + {'>', 'v', '|', '-'})
    if t.len == 0: continue
    if t.toUpperAscii.contains("NO SOURCE FILES"): return empty[FileTreeModel]()
    model.entries.add t
  if model.entries.len == 0: return empty[FileTreeModel]()
  read(model)

proc readQuietPane*(img: GrayImage; cell: Rect; scratch: string):
    ScreenReading[seq[string]] =
  var rest: seq[string] = @[]
  for l in bodyLines(img, cell, scratch):
    let u = l.strip().toUpperAscii
    if u.len == 0 or u in QuietChrome: continue
    if QuietMessages.anyIt(it.toUpperAscii.contains(u)): continue
    rest.add l.strip()
  if rest.len == 0: empty[seq[string]]() else: read(rest)

proc readNewPanes*(framePath: string; scratch: string): NewPanesReading =
  result.framePath = framePath
  template allUnreadable(reason: UnreadableReason; why: string) =
    result.transport = unreadable[TransportModel](reason, why)
    result.flow = unreadable[FlowPaneModel](reason, why)
    result.timeline = unreadable[TimelineModel](reason, why)
    result.fileTree = unreadable[FileTreeModel](reason, why)
    for p in QuietPanes:
      result.quiet.add QuietPane(pane: p,
                                 reading: unreadable[seq[string]](reason, why))
  if not fileExists(framePath):
    allUnreadable(urFrameMissing, "no file at " & framePath)
    return
  var img: GrayImage
  try:
    img = decodeGray(framePath)
  except CatchableError as e:
    allUnreadable(urFrameMissing, "decode failed: " & e.msg)
    return
  result.width = img.width
  result.height = img.height
  let grid = locateGrid(img)
  if grid.isUnreadable:
    allUnreadable(grid.reason, grid.detail)
    return
  createDir(scratch)
  var cells = initTable[PaneId, Rect]()
  for cell in grid.value.cells:
    let p = identifyPane(img, cell, scratch)
    result.panes.add p
    if p.id notin cells: cells[p.id] = cell
  template located(id: PaneId; T: typedesc; body: untyped): untyped =
    if id notin cells:
      unreadable[T](urRegionNotLocated,
                    "no cell's title strip identified a " & $id & " pane")
    else:
      let cell {.inject.} = cells[id]
      body
  result.transport = located(piDebugControls, TransportModel,
                             readTransport(img, cell, scratch))
  result.flow = located(piFlow, FlowPaneModel, readFlowPane(img, cell, scratch))
  result.timeline = located(piTimeline, TimelineModel,
                            readTimeline(img, cell, scratch))
  result.fileTree = located(piFileTree, FileTreeModel,
                            readFileTree(img, cell, scratch))
  for p in QuietPanes:
    result.quiet.add QuietPane(pane: p, reading: located(p, seq[string],
                               readQuietPane(img, cell, scratch)))
