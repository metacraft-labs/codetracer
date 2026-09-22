## plat37_vision.nim — the VISION tier's measurements, in one place.
##
## ## Why this is a module and not two copies
##
## PLAT-37 has two readers of the same frames: the GATE
## (`test_gpui_window_frame.nim`), which asserts, and the THRESHOLD PROBE
## (`ci/test/plat37_threshold_probe.nim`), which sweeps candidate values so
## the rejected ones are a runnable program rather than a table in a comment
## ([[Verification-Harness-Traps §36b]]). If each computed its own SSIM, its
## own edge-change ratio and its own OCR normalisation, the probe would be
## measuring a slightly different quantity from the one the gate asserts —
## §30's *two copies of one predicate*, which is the shape where the control
## agrees with itself while the rule is broken. **One predicate, one function,
## rule and probe both calling it.**
##
## ## What the vision tier may and may not claim
##
## PLAT-37's instrument contract puts exactly ONE claim on this tier:
## **there is a window and its pixels are not the pixels of a blank screen**,
## plus the OCR join. Everything structural — which panes exist, in what
## order, at what bounds, carrying what text — belongs to INTROSPECTION, is
## exact, needs no baseline and cannot drift. A GuiAssert assertion that a
## pane exists is strictly weaker than the introspection assertion beside it
## and must never be written as though it were the stronger one.
##
## ## The four GuiAssert entry points, and why only four
##
## `decodeGray`, `computeSsim`, `edgeChangeRatio`, `runOcr`. Each is PURE OVER
## A FILE — it takes a path, shells out to `ffprobe`/`ffmpeg`/`tesseract`, and
## returns a value — so the cross-repo edge this milestone declares is four
## function calls wide and carries no state, no driver and no lifecycle.
##
## Three GuiAssert helpers are DELIBERATELY NOT REACHED FOR, measured
## 2026-09-21 and named here so a later pass does not reach for them on the
## strength of their names:
##
##   * `ocr.detectElements(_, ebOmniParser)` **always raises**
##     `OcrBackendUnavailable` — it is a documented stub with no bundled
##     weights.
##   * `window_layout` and `input` are **macOS-only** (AppleScript /
##     `osascript` / CGEvent) and deliver neither focus nor keystrokes under
##     Wayland.
##   * `gui_assert.waitForText` **returns `false` on timeout rather than
##     raising**, which is the Silent-Self-Pass shape. Nothing here calls it;
##     `ocrHits` below is a pure count over a string this module already has.
##
## `capture.recordScreen` is also not used, and the rejection is measured
## rather than stylistic: that path records VIDEO (`wf-recorder` on Wayland,
## stopped by SIGINT) and would need `video_analysis.extractFrameTo` to get a
## frame back, at the cost of an encode — and `capture.validateOutput` checks
## only that the file exists and is non-empty, so a truncated container
## passes. The frames here come from `grim -t ppm`, which is the wlroots
## `zwlr_screencopy_manager_v1` path `isonim-gpui` already proved at 9 runs
## of 9, and `decodeGray` reads a PPM because it hands the path to `ffmpeg`
## with no explicit demuxer.

import std/[algorithm, json, os, sets, strutils, tables]

import gui_assert/image_math
import gui_assert/ocr

type
  VisionMetrics* = object
    ## One frame, measured against the blank control captured beside it.
    frameWidth*, frameHeight*: int
    blankWidth*, blankHeight*: int
    ssimVsBlank*: float
      ## `computeSsim(frame, blank)`. 1.0 is "identical". A painted window
      ## scores far below that; a window that opened and painted nothing
      ## scores 1.0, which is the state this whole tier exists to see.
    edgeChangeRatioVsBlank*: float
      ## `edgeChangeRatio(blank, frame)`. SSIM alone can be moved by a
      ## uniform luminance shift — a frame that is merely a different shade
      ## of nothing — so the second metric asks whether the frame has
      ## STRUCTURE. A flat fill scores near zero on it and low on SSIM at the
      ## same time, and only the pair can tell that from a drawn screen.
    nonBlackFraction*: float
      ## Computed here rather than through GuiAssert, from the decoded
      ## greyscale: the fraction of pixels above `NearBlackLevel`. It is the
      ## cheapest thing that can distinguish "a frame arrived" from "a frame
      ## of the compositor's background arrived", and it is reported on every
      ## row so a green run says what it measured.

  OcrJoin* = object
    ## The join between what introspection says is on screen and what the
    ## pixels can be read to say.
    k*: int          ## how many strings were taken from the plan
    hits*: int       ## how many of them are legible in the frame
    needles*: seq[string]
    found*: seq[string]

const
  NearBlackLevel* = 24'u8
    ## A greyscale byte at or below this is "the background". Headless sway's
    ## output is solid #000000, so a blank frame is 17 non-NUL BYTES in a
    ## 6.2 MB PPM — three orders of magnitude below anything drawn. The
    ## margin is enormous on purpose: this is a SYNCHRONISATION-grade
    ## quantity, not a threshold anybody tuned.

  MinNeedleLength* = 8
    ## Shorter strings are not worth asking OCR about: `#`, `0`, `kind` and
    ## `value` appear in the event-log header and would be found by accident
    ## in any text at all, which is a join that cannot fail.

  MaxNeedleLength* = 24
    ## **AND A CEILING, WHICH THE FIRST VERSION OF THIS MODULE DID NOT HAVE,
    ## AND THE MEASUREMENT THAT PUT IT HERE.** `planNeedles` took the K
    ## LONGEST strings, on the reasoning that *"a long string is the one OCR
    ## can be wrong about in the most ways and still be recognisable"*. Run
    ## against the real corpus that produced **hits of 0 or 1 out of K=10 on
    ## every one of the six scenarios** — a join that is red everywhere and
    ## therefore measures nothing.
    ##
    ## The reason is arithmetic rather than mysterious. The longest text nodes
    ## this front-end draws are whole source lines and docstring paragraphs,
    ## 58-63 characters once normalised. A needle is matched as a CONTIGUOUS
    ## substring, so it survives only if tesseract reads every one of those
    ## characters correctly; one misread glyph in sixty kills the whole
    ## needle, and the panes clip, so many of those strings are not even
    ## fully on screen to be read.
    ##
    ## The window is chosen by the sweep in `ci/test/plat37_threshold_probe.nim`
    ## and its rejected values are that program's output, never a table in a
    ## comment (§36b). The trade-off the sweep prices is two-sided in both
    ## directions: SHORTER needles are more legible and therefore easier to
    ## find at home, and also easier to find on ANOTHER scenario's frame,
    ## which is the negative control. A window admitted only because it made
    ## the numerator large would be a widening that empties the claim (§6a).

  MaxNeedles* = 10
    ## `K`'s ceiling. The join's denominator is asserted non-zero by the gate
    ## — a join whose K is zero is satisfied by ANY frame, which is §4
    ## arriving through an empty numerator.

func ocrNormalise*(s: string): string =
  ## Lower-case, alphanumerics only.
  ##
  ## **THE COMPARISON IS NORMALISED BECAUSE OCR IS LOSSY, AND THE
  ## NORMALISATION IS THE WEAKEST THING THAT STILL DISCRIMINATES.** Measured
  ## on a real capture of this front-end: tesseract reads `"""calc — the
  ## small, fast,` as `""calc — the small, fast,` and `CTUI-1's ``calc``
  ## fixture.` as `CTUI-L's ““calc™ fixture.` — so punctuation, quoting and
  ## the occasional glyph are unreliable while the LETTERS are not. Dropping
  ## case and non-alphanumerics keeps the letters and throws away exactly the
  ## classes that moved.
  ##
  ## It is a widening, and a widening can empty a claim (§6a), so the gate
  ## pairs it with a negative control: another scenario's needles scored
  ## against this frame must score LOWER than its own. A normalisation loose
  ## enough to match anything fails there.
  result = newStringOfCap(s.len)
  for c in s:
    if c in {'a' .. 'z', '0' .. '9'}: result.add c
    elif c in {'A' .. 'Z'}: result.add char(ord(c) + 32)

proc collectPlanText(node: JsonNode; into: var seq[string]) =
  if node.isNil or node.kind != JObject: return
  let t = node{"text"}
  if not t.isNil and t.kind == JString and t.getStr.len > 0:
    into.add t.getStr
  let kids = node{"children"}
  if not kids.isNil and kids.kind == JArray:
    for kid in kids:
      collectPlanText(kid, into)

proc planNeedles*(planJson: string; minLen = MinNeedleLength;
                  maxLen = MaxNeedleLength; k = MaxNeedles): seq[string] =
  ## The K longest DISTINCT normalised strings the render plan carries, WITHIN
  ## a length window.
  ##
  ## The window's bounds are arguments so the threshold probe can sweep them
  ## over the same corpus this returns for the gate — one function, two
  ## callers, rather than a sweep over a re-implementation of the selection
  ## it is choosing parameters for (§30).
  ##
  ## **THE NEEDLES COME FROM THE PLAN AND NOT FROM A LIST.** The plan is the
  ## introspection tier's own answer about what this window was built to
  ## draw, written by the same process in the same run
  ## (`codetracer-gpui --plan-out`), so the join is between two readings of
  ## ONE tree. A hand-written list of expected strings would be a fixture,
  ## and a fixture is satisfied by a front-end that draws the fixture.
  ##
  ## Longest first, because a long string is the one OCR can be wrong about
  ## in the most ways and still be recognisable, and because the short ones
  ## are the ones that match by accident.
  var raw: seq[string] = @[]
  collectPlanText(parseJson(planJson), raw)
  var seen = initHashSet[string]()
  var cand: seq[string] = @[]
  for s in raw:
    let n = ocrNormalise(s)
    if n.len < minLen or n.len > maxLen: continue
    if n in seen: continue
    seen.incl n
    cand.add n
  # Longest first WITHIN the window, and then a tie-break on the string
  # itself. The tie-break is not cosmetic: many of this front-end's text
  # nodes normalise to the same length, `sort` is not required to be stable
  # for equal keys, and a needle SET that depended on the sort's tie order
  # would make the committed record — and every mutation arm graded against
  # it — depend on the standard library's implementation detail.
  cand.sort(proc (a, b: string): int =
    result = cmp(b.len, a.len)
    if result == 0: result = cmp(a, b))
  result = cand[0 ..< min(cand.len, k)]

proc planNodeTexts*(planJson: string): seq[string] =
  ## Every text node the plan carries, normalised. The raw material both
  ## needle selectors work from.
  var raw: seq[string] = @[]
  collectPlanText(parseJson(planJson), raw)
  result = @[]
  for s in raw:
    let n = ocrNormalise(s)
    if n.len > 0: result.add n

proc distinctiveNeedles*(planJson: string; otherPlans: openArray[string];
                         minLen = MinNeedleLength; maxLen = MaxNeedleLength;
                         k = MaxNeedles): seq[string] =
  ## The K longest normalised strings THIS plan carries that no OTHER
  ## scenario's plan carries.
  ##
  ## ## Why the plain "longest strings" selector could not work, measured
  ##
  ## `planNeedles` takes the longest strings in the window and the join then
  ## scores them against this frame and, as a negative control, against every
  ## other scenario's frame. Swept over the real six-scenario corpus
  ## (`ci/test/plat37_threshold_probe.nim`), **every length window was
  ## REJECTED**, and not for a tuning reason: in each of them at least one
  ## scenario scored no better at home than away. The per-window rows are in
  ## that probe's output; `[8,24]` gave, per scenario, `own/K:away` of
  ## `3/10:3 3/10:3 5/10:5 3/10:2 5/10:6 3/10:3`.
  ##
  ## The cause is the corpus, not the metric, and it is
  ## [[Verification-Harness-Traps §34]] arriving inside the OCR join. All six
  ## scenarios open the SAME recording and draw the SAME source into the same
  ## editor; they differ in where the debugger is stopped, which locals are
  ## live and what the event log holds. The longest text nodes are therefore
  ## the same source lines in all six, so a needle drawn from them is on every
  ## frame by construction, and the cross-scenario control is comparing a
  ## string against itself.
  ##
  ## ## What this selector claims instead, and why K is a population assertion
  ##
  ## A needle here is a string the introspection tier says is on THIS screen
  ## and on NO OTHER scenario's. The join then says: *the strings that make
  ## this scenario different are legible in this scenario's frame, and are not
  ## legible in the others*. That is a claim about this window's contents
  ## rather than about text the six screens share.
  ##
  ## **AND IT MAKES `K > 0` A POPULATION ASSERTION RATHER THAN A FORMALITY.**
  ## If two scenarios painted the same thing, their distinctive sets would be
  ## EMPTY and the gate's `k >= minK` would go red by name — which is exactly
  ## the failure §34 describes and which no cardinality check over the
  ## scenario FILE can see, because the file would still declare six.
  let mine = planNodeTexts(planJson)
  var others: seq[string] = @[]
  for plan in otherPlans:
    for n in planNodeTexts(plan): others.add n
  var seen = initHashSet[string]()
  var cand: seq[string] = @[]
  for n in mine:
    if n.len < minLen or n.len > maxLen: continue
    if n in seen: continue
    seen.incl n
    # SUBSTRING, and in ONE DIRECTION ONLY: `n` is shared when it appears
    # INSIDE some other scenario's node. Equality would be too weak — a line
    # another scenario draws with one extra word around it is still that
    # scenario's text, and OCR cannot tell the two apart.
    #
    # **THE OTHER DIRECTION WAS TRIED AND IT EMPTIED THE SET.** Rejecting `n`
    # when some other node is a substring of IT looks symmetric and is not:
    # every scenario draws the pane headings, so six-character nodes like
    # `locals` and `state` are in every plan, and any longer string containing
    # one of them was disqualified. Measured on the real corpus, that left
    # **K = 0 for five of six scenarios** — a join satisfied by any frame,
    # which is §4 arriving through the selector rather than through the
    # threshold. A shorter shared node inside a longer string does not make
    # the longer string shared; it makes it longer.
    var shared = false
    for o in others:
      if n in o:
        shared = true
        break
    if shared: continue
    cand.add n
  cand.sort(proc (a, b: string): int =
    result = cmp(b.len, a.len)
    if result == 0: result = cmp(a, b))
  result = cand[0 ..< min(cand.len, k)]

proc ocrHits*(needles: seq[string]; ocrText: string): OcrJoin =
  ## How many needles are legible in the OCR of a frame.
  ##
  ## Substring, over the normalised forms of both sides. NOT equality: OCR
  ## splits and merges tokens, so a needle that survives as a run inside a
  ## longer read is a needle that was legible.
  let hay = ocrNormalise(ocrText)
  result = OcrJoin(k: needles.len, hits: 0, needles: needles, found: @[])
  for n in needles:
    if n.len > 0 and hay.contains(n):
      inc result.hits
      result.found.add n

proc nonBlackFraction*(img: GrayImage): float =
  if img.pixels.len == 0: return 0.0
  var lit = 0
  for ch in img.pixels:
    if uint8(ch) > NearBlackLevel: inc lit
  lit.float / img.pixels.len.float

proc measureFrame*(framePath, blankPath: string): VisionMetrics =
  ## Decode both, and compute the three numbers.
  ##
  ## **BOTH, ALWAYS.** There is no arm that measures a frame without its
  ## control: a similarity threshold with no blank beside it is a number
  ## nobody can falsify (§7b), and the cheapest way to end up with one is an
  ## `if fileExists(blank)`. A missing control raises here, and the caller
  ## turns that into a named failure rather than a skipped row.
  let frame = decodeGray(framePath)
  let blank = decodeGray(blankPath)
  VisionMetrics(
    frameWidth: frame.width, frameHeight: frame.height,
    blankWidth: blank.width, blankHeight: blank.height,
    ssimVsBlank: computeSsim(frame, blank),
    edgeChangeRatioVsBlank: edgeChangeRatio(blank, frame),
    nonBlackFraction: nonBlackFraction(frame))

proc frameOcrText*(framePath: string): string =
  ## `concatenatedText(runOcr(frame))`, unchanged. Kept here so both readers
  ## spell the OCR call the same way and any future option (a psm, an
  ## invert) lands in one place.
  concatenatedText(runOcr(framePath))

# ---------------------------------------------------------------------------
# The manifest, read once
# ---------------------------------------------------------------------------

type
  FrameRun* = object
    scenario*, config*, productMode*, ops*, outcome*: string
    frame*, blank*, plan*, runLog*, captureLog*: string
    binaryRc*, captureRc*, elapsedMs*, quitAfterMs*: int

proc toRun*(j: JsonNode): FrameRun =
  FrameRun(
    scenario: j{"scenario"}.getStr,
    config: j{"config"}.getStr,
    productMode: j{"productMode"}.getStr,
    ops: j{"ops"}.getStr,
    outcome: j{"outcome"}.getStr,
    frame: j{"frame"}.getStr,
    blank: j{"blank"}.getStr,
    plan: j{"plan"}.getStr,
    runLog: j{"runLog"}.getStr,
    captureLog: j{"captureLog"}.getStr,
    binaryRc: j{"binaryRc"}.getInt,
    captureRc: j{"captureRc"}.getInt,
    elapsedMs: j{"elapsedMs"}.getInt,
    quitAfterMs: j{"quitAfterMs"}.getInt)

proc runsByScenario*(manifest: JsonNode; config: string): Table[string, FrameRun] =
  result = initTable[string, FrameRun]()
  let arr = manifest{"runs"}{config}
  if arr.isNil or arr.kind != JArray: return
  for entry in arr:
    let r = toRun(entry)
    result[r.scenario] = r

proc modesByScenario*(manifest: JsonNode; config: string): Table[string, FrameRun] =
  result = initTable[string, FrameRun]()
  let arr = manifest{"productModes"}{config}
  if arr.isNil or arr.kind != JArray: return
  for entry in arr:
    let r = toRun(entry)
    result[r.scenario] = r

proc runsInOrder*(manifest: JsonNode; section, config: string): seq[FrameRun] =
  ## The runs in the order the LANE wrote them, which is the order
  ## `scenarios.json` declares.
  ##
  ## **ORDER, NOT A `Table`, AND THE REASON IS NOT TIDINESS.** The record this
  ## builds is committed and is a mutation subject; an arm that targets the
  ## FIRST occurrence of a repeated key needs the first occurrence to be the
  ## same row on every machine. A `Table` iterates in hash order — stable for
  ## one Nim version and one key set, and silently different across either —
  ## so a record keyed off one would make an arm land on a scenario nobody
  ## chose, and the harness would report a killer case that has nothing to do
  ## with the arm.
  result = @[]
  let arr = manifest{section}{config}
  if arr.isNil or arr.kind != JArray: return
  for entry in arr:
    result.add toRun(entry)

# ---------------------------------------------------------------------------
# THE MEASURING PASS — ONE IMPLEMENTATION, TWO CALLERS
# ---------------------------------------------------------------------------
#
# `ci/test/plat37_measure.nim` calls this to WRITE
# `src/tests/visual/plat37-measurements.json`, and
# `test_gpui_window_frame.nim` calls it to RE-MEASURE when the frames are
# still on disk. If each had its own loop the recorded numbers and the live
# numbers would be two computations of one quantity, which is §30's two-copies
# defect in the shape that passes: the gate would agree with itself about a
# frame neither had measured the same way.
#
# **IT IS PURE OVER THE MANIFEST AND THE FILES THE MANIFEST NAMES.** It opens
# no window, starts no compositor and runs no binary; everything it needs was
# produced by `ci/test/plat37-window-frame.sh`, which is why the gate can run
# it in a process with no display at all.

const
  UnmeasuredF* = -1.0
    ## The value every metric carries on a run that produced no frame. A
    ## SENTINEL and not a zero: a featureless run scores no SSIM at all, and
    ## `0.0` would read as "maximally unlike the blank control", which is the
    ## direction of a PASS. Every consumer tests `measured` first.
  UnmeasuredI* = -1

proc measureRun*(run: FrameRun; ocrCache: var Table[string, string]): JsonNode =
  ## Every number PLAT-37's vision tier can be asked about ONE run.
  ##
  ## The OCR text is cached by frame path because the cross-scenario negative
  ## control scores each scenario's needles against every other scenario's
  ## frame — that is O(n²) comparisons over O(n) OCR runs, and tesseract on a
  ## 1920x1080 frame is seconds rather than milliseconds. The cache makes the
  ## control affordable; it changes no value.
  result = %*{
    "scenario": run.scenario,
    "config": run.config,
    "productMode": run.productMode,
    "ops": run.ops,
    "outcome": run.outcome,
    "binaryRc": run.binaryRc,
    "captureRc": run.captureRc,
    "elapsedMs": run.elapsedMs,
    "quitAfterMs": run.quitAfterMs,
    "hasFrame": run.frame.len > 0 and fileExists(run.frame),
    "hasBlank": run.blank.len > 0 and fileExists(run.blank),
    "hasPlan": run.plan.len > 0 and fileExists(run.plan),
    "measured": false,
    "ssimVsBlank": UnmeasuredF,
    "edgeChangeRatioVsBlank": UnmeasuredF,
    "nonBlackFraction": UnmeasuredF,
    # THE CONTROL, SCORED THROUGH THE SAME FUNCTION as the frame. The blank
    # against itself is SSIM 1.0 and edge-change 0.0 BY CONSTRUCTION, and
    # that construction is what every threshold below has to fail on. A
    # control computed a second way would be a second predicate.
    "blankSelfSsim": UnmeasuredF,
    "blankSelfEdgeChangeRatio": UnmeasuredF,
    "blankNonBlackFraction": UnmeasuredF,
    "ocrK": UnmeasuredI,
    "ocrHits": UnmeasuredI,
    "ocrHitsOnBlank": UnmeasuredI,
    "needles": newJArray(),
    "found": newJArray(),
  }
  if result["hasFrame"].getBool and result["hasBlank"].getBool:
    let m = measureFrame(run.frame, run.blank)
    let control = measureFrame(run.blank, run.blank)
    result["measured"] = %true
    result["frameWidth"] = %m.frameWidth
    result["frameHeight"] = %m.frameHeight
    result["blankWidth"] = %m.blankWidth
    result["blankHeight"] = %m.blankHeight
    result["ssimVsBlank"] = %m.ssimVsBlank
    result["edgeChangeRatioVsBlank"] = %m.edgeChangeRatioVsBlank
    result["nonBlackFraction"] = %m.nonBlackFraction
    result["blankSelfSsim"] = %control.ssimVsBlank
    result["blankSelfEdgeChangeRatio"] = %control.edgeChangeRatioVsBlank
    result["blankNonBlackFraction"] = %control.nonBlackFraction
  # **THE NEEDLES COME FROM THE PLAN, SO THEY ARE COMPUTED WHENEVER THERE IS A
  # PLAN — INCLUDING FOR A RUN THAT PRODUCED NO FRAME.** They were computed
  # only alongside the OCR at first, and that made the featureless arm's
  # needle list EMPTY, which broke the tree half of `DIFF-6`: the gate asserts
  # that the featureless build's plan carries the SAME strings as the windowed
  # one, and an empty list would have read as "the featureless build built
  # nothing" — the very explanation for "no frame" that `DIFF-6` has to rule
  # out. `ocrK` and `ocrHits` stay at their sentinels when there is no frame,
  # because a join with no picture is not a join that scored zero.
  if result["hasPlan"].getBool:
    let needles = planNeedles(readFile(run.plan))
    result["needles"] = %needles
    if result["hasFrame"].getBool:
      if run.frame notin ocrCache:
        ocrCache[run.frame] = frameOcrText(run.frame)
      let join = ocrHits(needles, ocrCache[run.frame])
      result["ocrK"] = %join.k
      result["ocrHits"] = %join.hits
      result["found"] = %join.found
    if result["hasFrame"].getBool and result["hasBlank"].getBool:
      # THE JOIN'S FIRST NEGATIVE CONTROL: the same needles against the blank
      # frame captured beside this one. It must score zero, and a join that
      # scored the same on a blank screen would be a join about the OCR
      # normalisation rather than about the window.
      if run.blank notin ocrCache:
        ocrCache[run.blank] = frameOcrText(run.blank)
      result["ocrHitsOnBlank"] = %ocrHits(needles, ocrCache[run.blank]).hits

proc measureCorpus*(manifest: JsonNode): JsonNode =
  ## The whole corpus: both configurations, both product modes, plus the
  ## cross-scenario negative control.
  var ocrCache = initTable[string, string]()
  result = %*{"runs": newJObject(), "productModes": newJObject()}
  for config in ["windowed", "featureless"]:
    var perConfig = newJObject()
    for run in runsInOrder(manifest, "runs", config):
      perConfig[run.scenario] = measureRun(run, ocrCache)
    result["runs"][config] = perConfig
    var perMode = newJObject()
    for run in runsInOrder(manifest, "productModes", config):
      perMode[run.scenario] = measureRun(run, ocrCache)
    result["productModes"][config] = perMode

  # ---------------------------------------------------------------------
  # THE JOIN'S SECOND NEGATIVE CONTROL — and WHICH frame plays it, measured
  # ---------------------------------------------------------------------
  #
  # PLAT-37 publishes it as *"another scenario's frame scores lower than its
  # own"*. **THAT CONTROL CANNOT HOLD ON THIS CORPUS, AND THE REASON IS THE
  # CORPUS.** Swept over the real capture
  # (`ci/test/plat37_threshold_probe.nim`), every needle-length window has at
  # least one scenario scoring no better at home than away; at the committed
  # window the per-scenario `own : away` pairs are `3:3 3:3 5:5 3:2 5:6 3:3`.
  # All six scenarios open the SAME recording and draw the SAME source into
  # the same editor, differing in where the debugger stopped, which locals are
  # live and what the event log holds — so the strings OCR can actually read
  # are very largely shared. Measured directly: `distinctiveNeedles` finds
  # text that NO other scenario draws for only three of the six, and none at
  # all for `stepped-editor` and `breakpoint-editor`, which differ by a gutter
  # MARK rather than by text.
  #
  # That is [[Verification-Harness-Traps §34]] — the population, not the
  # property — and §36 is the rule for what to do about it: *read every
  # published control against the implementation before trusting it; if the
  # answer is "it cannot land", the repair is to the ASSERTION or to the
  # DESIGN, never to the measurement.*
  #
  # So the control's PURPOSE — catching a normalisation loose enough to match
  # anything — is served by two controls that CAN land, and both are kept:
  #
  #   the BLANK frame       (`ocrHitsOnBlank`, computed per run above): zero.
  #   the EDIT-MODE frame   (`ocrHitsOnEditMode`, below): the same binary, the
  #                         same compositor, the same run, the same pane
  #                         chrome — and `ct edit --ui=gpui src/frontend/gpui`
  #                         opens this front-end's own working tree instead of
  #                         the `calc` recording, so it is the one screen in
  #                         the corpus drawing OTHER TEXT. Measured: **zero
  #                         hits for every one of the six**, a margin of 3 to
  #                         5 against their own scores.
  #
  # And the cross-scenario number is still COMPUTED AND RECORDED — it is the
  # evidence for the paragraph above, and a figure nothing re-takes is free to
  # be wrong (§36b). It is recorded rather than gated because gating it would
  # be gating a property of the corpus this milestone does not own; the corpus
  # is PLAT-35's and the finding is filed against it.
  let windowed = runsByScenario(manifest, "windowed")

  var editText = ""
  var editFrame = ""
  for run in runsInOrder(manifest, "productModes", "windowed"):
    if run.outcome == "captured" and run.frame.len > 0:
      editFrame = run.frame
      if run.frame notin ocrCache:
        ocrCache[run.frame] = frameOcrText(run.frame)
      editText = ocrCache[run.frame]

  for id, run in windowed:
    if run.outcome != "captured": continue
    let entry = result["runs"]["windowed"]{id}
    if entry.isNil or not entry{"measured"}.getBool: continue
    var needles: seq[string] = @[]
    for n in entry{"needles"}: needles.add n.getStr
    var best = UnmeasuredI
    var scored = 0
    for otherId, otherRun in windowed:
      if otherId == id or otherRun.outcome != "captured": continue
      if otherRun.frame notin ocrCache:
        ocrCache[otherRun.frame] = frameOcrText(otherRun.frame)
      let h = ocrHits(needles, ocrCache[otherRun.frame]).hits
      if h > best: best = h
      inc scored
    entry["ocrBestOnAnotherFrame"] = %best
    # PRINTED AND ASSERTED: a "best over the other frames" computed over ZERO
    # other frames is `-1` and would compare LESS THAN this scenario's own
    # hits for free. The gate reads this count and refuses a control with an
    # empty population (§34).
    entry["ocrFramesScoredAgainst"] = %scored

    # THE CONTROL THE GATE ACTUALLY ASSERTS.
    entry["ocrHitsOnEditMode"] =
      %(if editText.len == 0: UnmeasuredI
        else: ocrHits(needles, editText).hits)
    entry["editModeFrame"] = %editFrame

    # AND THE POPULATION FIGURE ITSELF: how many strings this scenario draws
    # that NO other scenario draws. It is what turns "the six scenarios paint
    # the same thing" from an impression into a number, and the gate asserts
    # the corpus-level shape of it rather than a per-scenario floor, because
    # two of the six differ by a gutter mark rather than by text and that is
    # by construction rather than by defect.
    var otherPlans: seq[string] = @[]
    for otherId, otherRun in windowed:
      if otherId == id or otherRun.outcome != "captured": continue
      if otherRun.plan.len > 0 and fileExists(otherRun.plan):
        otherPlans.add readFile(otherRun.plan)
    entry["distinctiveNeedleCount"] =
      %distinctiveNeedles(readFile(run.plan), otherPlans,
                          MinNeedleLength, 1000, 1000).len

const CarriedManifestKeys* = ["shims", "pixelPaths", "headlessProbe",
                              "configurations", "expectedScenarios",
                              "operationKinds", "only", "host"]
  ## The manifest readings the gate asks about WITHOUT needing a frame: the
  ## shims' `ldd` closures and symbol sets, the two labelled pixel paths, the
  ## `gpui-headless` probe's answer and the four compositor configurations.
  ## They are carried into the record verbatim so the recorded and the live
  ## corpus have the same shape and the gate has ONE reader.

proc corpusRecord*(manifest: JsonNode): JsonNode =
  ## `measureCorpus` plus the manifest readings that need no frame.
  ##
  ## Called by `ci/test/plat37_measure.nim` to write the committed record and
  ## by `test_gpui_window_frame.nim` to build the live one, so the two cannot
  ## be different shapes — which is the failure where the gate asserts over a
  ## field the recorder never wrote and the check is true for free (§4).
  result = measureCorpus(manifest)
  for key in CarriedManifestKeys:
    let value = manifest{key}
    if not value.isNil:
      result[key] = value
