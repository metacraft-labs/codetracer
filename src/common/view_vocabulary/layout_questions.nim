## view_vocabulary/layout_questions.nim — PLAT-35. **The shared
## layout-assertion vocabulary: the closed set of questions BOTH front-ends
## answer about ONE scenario, and the canonical form an answer takes.**
##
## ## Why this is a value and never an image
##
## `Testing/Cross-Renderer-Visual-Alignment.md` §2 scopes the cross-renderer
## claim to tier 3 and says why: Chromium rasterises through Skia with its own
## text shaper, hinting and subpixel policy; GPUI shapes text itself and paints
## through `wgpu`. *"Two renderers agreeing on a byte is not a goal that can be
## missed — it is a goal that cannot be reached."* So the alignment claim is
## carried by **assertions over values**, which need no baseline and cannot
## drift, and pixels are left to tier 2 at a threshold on a named view.
##
## ## THE SET IS CLOSED, AND THAT IS WHAT MAKES IT A GATE
##
## §3 of that document publishes **eight** questions in a table. This module
## declares the same eight as an enum whose display strings are the table's own
## canonical keys, and the suite over it
## (`gpui/tests/test_cross_renderer_visual_alignment.nim`) parses the published
## table at run time and compares it against **this enum** in both directions
## with the cardinality asserted on both sides —
## `Editor-Model-Conformance-Suite.md` §7.1. The last part is the one usually
## omitted, and without it the two set differences are both satisfied by two
## empty sets.
##
## **WHAT THAT TWO-WAY COMPARISON IS OVER, SAID EXACTLY.** It is the PARSED
## TABLE against the ENUM IN THIS MODULE. It is **not** the two front-ends'
## answer sets, and three places in this campaign said it was until 2026-09-21.
## The distinction matters because the two claims have different strength: the
## table-against-enum comparison catches a question renamed in the spec and not
## in the code, and nothing else. What guarantees that each FRONT-END emits all
## eight is a different check, in the suite's tier-3 body — `ck gpuiHas` and
## `ck elecHas` per question per scenario, which is forty-eight of each — and
## the reason that is needed separately is that a front-end could emit a
## perfectly-spelled subset and the set comparison above would never look at
## it.
##
## **A front-end that cannot answer a question SAYS SO** — `lqUnanswered` is a
## value, not an omission. `Verification-Harness-Traps` §4 is the reason: a
## scanner that finds nothing satisfies every "must not contain" check written
## over it, and a question quietly dropped from one side's output is that shape
## exactly.
##
## ## WHAT THIS MODULE DELIBERATELY DOES NOT DO
##
## **It does not produce an answer.** Not one line here reads a pane, a row, a
## style or a tree. `Verification-Harness-Traps` §30a is the trap: if one side's
## answer is derived from the other's — or if both are derived from a shared
## producer — then all questions agree and nothing has been compared. Each
## front-end's producer lives with that front-end and reads **its own rendered
## artefact**:
##
##   * the GPUI side in `frontend/view_vocabulary/gpui_layout_answers.nim`,
##     out of the Rust shadow tree across the FFI boundary and out of
##     `projectDock`'s own JSON document;
##   * the Electron side in `src/tests/gui/tools/layout-answers.ts`, out of
##     `getBoundingClientRect`, `getComputedStyle` and the classes the product's
##     own renderer put on the elements.
##
## What IS shared is this vocabulary — the question ids, the canonical spelling
## of an answer, and the token-id and metric-bucket alphabets — and sharing a
## vocabulary is not sharing a producer. `ci/test/plat35-answer-independence.sh`
## is the source scan that keeps it that way: it fails if either producer names
## the other, or if either imports the other's medium.

import std/[algorithm, sets, strutils, tables]

type
  LayoutQuestion* = enum
    ## **The eight questions of `Cross-Renderer-Visual-Alignment.md` §3.**
    ##
    ## The display string is the table's CANONICAL KEY, derived from the row's
    ## first column by the grammar published in §3.1a of that document: take the
    ## text before the first `,` or ` — `, lowercase it, and replace each run of
    ## non-alphanumerics with a single `-`. The derivation is a rule rather than
    ## a transcription so that a row reworded in its explanatory tail does not
    ## silently stop matching, and a row renamed in its SUBJECT does.
    lqPaneRectangles = "pane-rectangles"
    lqPanesPresent = "which-panes-are-present"
    lqEditorRowCount = "editor-row-count"
    lqGutterMarks = "gutter-marks-by-line"
    lqInlineValueRuns = "inline-value-runs-by-line"
    lqTextMetrics = "text-metrics-per-role"
    lqTokenColour = "token-colour-per-role"
    lqFocusOrder = "focus-order"

const
  LayoutQuestionCount* = 8
    ## The cardinality, asserted on BOTH sides of the two-direction set
    ## equality. Declared here so the suite, the gate script and the producers
    ## all read one number.

  Unanswered* = "<unanswered>"
    ## **A front-end that cannot answer a question says so with this.** It is a
    ## value rather than a missing key, because a missing key is the §4 shape:
    ## a comparison over the keys both sides happen to have is satisfied by two
    ## sides that both answer nothing. It is deliberately not the empty string —
    ## an empty answer is a legitimate answer (a pane with no gutter marks) and
    ## must not be confusable with "this front-end has no way to tell you".
    ## The angle brackets make it unproducible by either producer: every
    ## canonical answer spelling below is a `key=value` list over `;`, `,`, `|`
    ## and `/`, and neither `<` nor `>` is in that grammar. It is also plain
    ## ASCII, because the Electron extractor writes the same literal from
    ## TypeScript and a sentinel that needs escaping in one of two languages is
    ## a sentinel the two will eventually spell differently.

type
  CaptureTier* = enum
    ## **EVERY ROW CARRIES ITS TIER.** PLAT-23's rule, applied before the work
    ## rather than after it: a case whose column is a source reading counts
    ## toward a floor only if it is labelled as one, because an unlabelled
    ## source reading presented beside a captured one inflates a floor with
    ## cases that cannot fail in the way the row claims.
    ctCaptured = "captured"
      ## Read off an artefact a shipped binary produced in this run.
    ctSourceReading = "source reading"
      ## Read off the source of the thing that would have produced it. Honest,
      ## weaker, and labelled.

  LayoutAnswer* = object
    ## One front-end's answer to one question about one scenario.
    question*: LayoutQuestion
    value*: string
      ## The canonical form. `Unanswered` when this front-end cannot tell.
    tier*: CaptureTier

  LayoutAnswerSet* = object
    ## Everything one front-end says about one scenario.
    frontEnd*: string          ## "electron" or "gpui" — the ONLY place a
                               ## renderer is named in this campaign's data.
    scenario*: string
    answers*: seq[LayoutAnswer]

  VisualGapId* = enum
    ## A filed, named gap — the `EditorProducerGap` / `GpuiEscape` shape this
    ## campaign already uses. **An unexplained divergence cannot be carried**;
    ## every answered question is either equal or one of these.
    vgGpuiHasNoPixelBackend = "PLAT35-VG1"
    vgElectronEditorIsMonaco = "PLAT35-VG2"
    vgPaneRectangleTolerance = "PLAT35-VG3"
    vgGpuiFocusIsDeclaredNotEnforced = "PLAT35-VG4"
    vgDefaultLayoutsDiffer = "PLAT35-VG5"
    vgBreakpointOffsetResolvesDifferently = "PLAT35-VG6"
    vgGpuiStatePaneHasNoTextRoles = "PLAT35-VG8"
    vgOnlyGpuiDrawsInlineValues = "PLAT35-VG9"
      ## **`PLAT35-VG7` RETIRED, AND THE DIVERGENCE IT NAMED CAME BACK —
      ## BECAUSE IT HAD NEVER GONE.** VG7 said: only one front-end draws an
      ## inline value in any scenario. It was retired on 2026-09-21 against a
      ## run in which BOTH arms answered an empty run set on all six
      ## scenarios, and the retirement case forced it out.
      ##
      ## **THAT RUN WAS THE MINORITY CASE.** Re-measured the same day: six
      ## runs of the same gate binary over the same tree, five of them report
      ## `56:1:mul=<function mul at 0x…>` on `advanced-state`,
      ## `110:2:results=@[]|value=5` on `returned-calltrace` and
      ## `113:1:results=05 07 2a 11 02 (5 bytes)` on `continued-event-log`,
      ## with the Electron arm empty on all six. One run reports empty
      ## everywhere. So the divergence is the NORMAL case and the run VG7 was
      ## retired against was the exception.
      ##
      ## VG7's number is not reused — that rule stands — so this is a new id
      ## for the same divergence, and the history is kept here rather than
      ## deleted, because what it records is how a gap gets retired by
      ## accident: `the GPUI arm's three pane producers all ran` asserts that
      ## none of them RAISED, and in that run none did and the state pane was
      ## empty anyway. Two empty answers compare equal. The suite now asserts
      ## the producers' EFFECT as well — `the GPUI arm's locals producer
      ## LOADED something, not just ran` — so a run like that fails by name
      ## instead of quietly repairing a gap.
      ##
      ## THE INTERMITTENCY ITSELF IS `PLAT35-PD3`, with an owner and a date.
      ## **`PLAT35-VG7` IS RETIRED AND ITS NUMBER IS NOT REUSED.**
      ##
      ## It said: *only one front-end drew an inline value in any scenario —
      ## the GPUI arm reports `56:1:mul=<function mul at 0x…>` on
      ## `advanced-state` and the Electron arm reports an empty run set on all
      ## six.* It was retired on 2026-09-21 against a run in which BOTH arms
      ## answered empty on all six, because `a filed gap is retired when its
      ## divergence is repaired` fails until it goes.
      ##
      ## **THE RETIREMENT WAS WRONG AND THE DIVERGENCE IS BACK AS
      ## `PLAT35-VG9`.** Re-measured the same day over six runs of one gate
      ## binary on one tree: FIVE report the GPUI values above and one reports
      ## empty. The run VG7 was retired against was the minority case. VG7's
      ## NUMBER IS STILL NOT REUSED — that rule stands and this entry stays
      ## retired — but the claim it made is true and is filed again.
      ##
      ## **HOW A GAP GETS RETIRED BY ACCIDENT, kept here because it is the
      ## most useful thing this entry now records.** The hypothesis tested at
      ## the time was that a pane producer had started raising and was being
      ## swallowed; that was FALSE, and it was the right thing to test. What
      ## was NOT tested is the other half: the suite recorded that none of
      ## `requestAndLoadLocals`, `requestAndLoadCalltrace` and
      ## `requestAndLoadEventLog` RAISED, and that was read as "the panes are
      ## filled". A producer that runs and loads nothing empties the pane
      ## exactly as one that raised. Two empty answers compare equal, the
      ## question agreed, and the retirement case then required the gap to go.
      ##
      ## `the GPUI arm's locals producer LOADED something, not just ran` is
      ## the repair, and the intermittency itself is `PLAT35-PD3`, with a
      ## subject, an owner, a review date and a stated consequence in
      ## `productDefectRegister()` below, which the gate grades.
      ##
      ## The consequence for the gate: with `PLAT35-VG9` filed,
      ## `inline-value-runs-by-line`'s six tier-3 cells take the
      ## `residualHolds` branch again and the `gaps.len == 0` branch is once
      ## more unreachable on today's tree. That is a loss and it is the honest
      ## one — the branch was never reached by a comparison of two answers
      ## that both said something; it was reached by two that both said
      ## nothing.

  VisualGap* = object
    id*: VisualGapId
    question*: LayoutQuestion
    subject*: string
      ## Which layer owes the repair: `renderer`, `front-end`, `harness`.
    measurement*: string
      ## What was measured, with the number. Never "differs".
    remedy*: string
      ## What closes it. Never "investigate".

  ProductDefectId* = enum
    ## **DEFECTS IN THE PRODUCT THAT THIS MILESTONE FOUND AND DID NOT FIX.**
    ##
    ## A `VisualGap` is a divergence BETWEEN the two front-ends and is closed by
    ## making them agree. These are not that: each is a single front-end drawing
    ## something wrong, which both front-ends could do identically and which no
    ## alignment gap can express. Filing them here rather than as gaps is the
    ## same distinction `PLAT35-VG7`'s retirement forced — *"a gap is for a
    ## divergence between the two front-ends, and there is no longer one here"*
    ## — and it is what stops that sentence from being where a product
    ## regression goes to be forgotten.
    ##
    ## The record shape is `EditorProducerGap`'s and `VisualGap`'s, reused
    ## rather than re-derived, plus the two fields those two do not carry and
    ## that a defect nobody is fixing this week needs: an **owner** and a
    ## **date**. That pairing is `PLAT15-IMG1`'s, which is this campaign's own
    ## precedent for a residue it assigned rather than described — an owner, a
    ## date, and a consequence stated now rather than decided then.
    pdElectronPanesAmputateText = "PLAT35-PD1"
    pdEventLogDrawsOneRowSixTimes = "PLAT35-PD2"
    pdGpuiDrawsNoInlineValue = "PLAT35-PD3"
    pdEditorScrollNotRenormalised = "PLAT35-PD4"

  ProductDefect* = object
    id*: ProductDefectId
    subject*: string
      ## Which layer owes the repair: `renderer`, `front-end`, `harness`.
    owner*: string
      ## **WHO CARRIES IT, AND WHAT HAPPENS IF NOBODY DOES.** A layer is not an
      ## owner: `front-end` says where the code is and names nobody. This names
      ## the document or milestone that inherits the defect, and says what
      ## happens on `reviewBy` if it has not been taken.
    reviewBy*: string
      ## ISO date. A defect with an owner and no date is a defect with no owner.
    measurement*: string
      ## What was measured, with the number. Never "differs".
    remedy*: string
      ## What closes it. Never "investigate".

proc canonicalQuestionKey*(published: string): string =
  ## **The §3.1a grammar, as ONE function.** Called by the oracle parser and by
  ## nothing else that could disagree with it — `Verification-Harness-Traps`
  ## §30's remedy, one predicate in one place.
  ##
  ## Take the text before the first `,` or ` — `, lowercase, and collapse each
  ## run of non-alphanumerics into a single `-`.
  var head = published.strip()
  let comma = head.find(',')
  let dash = head.find(" — ")
  var cut = -1
  if comma >= 0: cut = comma
  if dash >= 0 and (cut < 0 or dash < cut): cut = dash
  if cut >= 0: head = head[0 ..< cut]
  result = ""
  var pendingSeparator = false
  for ch in head.strip().toLowerAscii():
    if ch in {'a' .. 'z', '0' .. '9'}:
      if pendingSeparator and result.len > 0: result.add '-'
      pendingSeparator = false
      result.add ch
    else:
      pendingSeparator = true

proc questionFromKey*(key: string): (bool, LayoutQuestion) =
  for q in LayoutQuestion:
    if $q == key: return (true, q)
  (false, lqPaneRectangles)

proc answeredQuestions*(s: LayoutAnswerSet): seq[LayoutQuestion] =
  ## The questions this front-end **answered**, which is not the same as the
  ## questions it emitted a row for. A row carrying `Unanswered` is emitted and
  ## is not answered, and that distinction is the whole reason `Unanswered` is
  ## a value.
  ##
  ## **CALLED BY THE SUITE.** These two were dead code from the day they were
  ## written until 2026-09-21 — exported, documented as *"the set side of
  ## §7.1's two-direction count"*, and called by nothing. A helper that
  ## describes a check nobody performs reads, to the next person, as the check
  ## itself; the repair was to perform it. `the two front-ends each emit all
  ## eight questions, per scenario` in
  ## `test_cross_renderer_visual_alignment.nim` is the caller, and it is what
  ## asserts a FRONT-END's cardinality — which the table-against-enum
  ## comparison at the top of this module never did.
  result = @[]
  for a in s.answers:
    if a.value != Unanswered:
      result.add a.question
  result.sort(proc (x, y: LayoutQuestion): int = cmp(ord(x), ord(y)))

proc emittedQuestions*(s: LayoutAnswerSet): seq[LayoutQuestion] =
  ## Every question this front-end emitted a ROW for, answered or not. Sorted
  ## and deduplicated by the caller's set, so a producer that emitted one
  ## question twice and another never cannot pass a count.
  result = @[]
  for a in s.answers: result.add a.question
  result.sort(proc (x, y: LayoutQuestion): int = cmp(ord(x), ord(y)))

proc answerFor*(s: LayoutAnswerSet; q: LayoutQuestion): (bool, LayoutAnswer) =
  for a in s.answers:
    if a.question == q: return (true, a)
  (false, LayoutAnswer(question: q, value: Unanswered, tier: ctSourceReading))

# ---------------------------------------------------------------------------
# The canonical answer spellings
# ---------------------------------------------------------------------------
#
# These are FORMATTERS, not producers: each takes facts a front-end has already
# read off its own artefact and renders them in one agreed spelling. Sharing the
# spelling is what makes two independently-read answers comparable at all;
# sharing a READER would be §30a and is what `plat35-answer-independence.sh`
# refuses.

type
  PaneRect* = object
    ## A pane's rectangle in a NORMALISED coordinate space: hundredths of the
    ## viewport, so a 1920x1080 window and a 120x40 cell grid answer the same
    ## question.
    pane*: string
    x*, y*, w*, h*: int

  TextRole* = enum
    ## The roles whose metrics and token colour are compared. A closed set, for
    ## the same reason `EditorMark` is an enum rather than a string: a typo in a
    ## string degrades into "this role was not found", which is a silent,
    ## plausible-looking agreement.
    trEditorCode = "editor-code"
    trGutterLineNumber = "gutter-line-number"
    trPaneTitle = "pane-title"
    trValueName = "value-name"
    trValueText = "value-text"

  FamilyClass* = enum
    fcMono = "mono"
    fcProportional = "proportional"

  SizeBucket* = enum
    ## Buckets rather than pixels. Two renderers that both draw the editor at
    ## "the body size" agree here and disagree about the pixel, and the pixel is
    ## tier 2's business.
    sbSmall = "sm"
    sbBody = "md"
    sbLarge = "lg"

  WeightBucket* = enum
    wbRegular = "regular"
    wbMedium = "medium"
    wbBold = "bold"

  TextMetric* = object
    role*: TextRole
    family*: FamilyClass
    size*: SizeBucket
    weight*: WeightBucket

const
  DesignTokenAlphabet* = [
    "editor.code.foreground",
    "editor.lineNumber.foreground",
    "editor.executionLine.background",
    "gutter.breakpoint.enabled",
    "gutter.breakpoint.disabled",
    "gutter.tracepoint",
    "pane.title.foreground",
    "value.name.foreground",
    "value.text.foreground",
    "flow.line.taken",
    "flow.line.notTaken"]
    ## **Colour is compared as a TOKEN ID, never as a hex value** — §3.1: a
    ## token comparison is exact and survives rasterisation; a hex comparison
    ## does not, because the two renderers blend and gamma-correct differently.
    ## Where the RENDERED colour genuinely matters, that is tier 2's job, at a
    ## threshold, on a named view.
    ##
    ## This is an ALPHABET, not a mapping. Which role resolves to which token is
    ## each front-end's own rendering decision and is read off its own artefact;
    ## what is shared is only the set of spellings a token id may have, so that
    ## two answers are comparable rather than two dialects.

  PaneRectangleTolerancePp* = 2
    ## **The one question compared with a tolerance, and its history is
    ## recorded beside it** — the methodology's ratchet rule applied to a
    ## tier-3 tolerance rather than to a tier-2 threshold.
    ##
    ## HISTORY: introduced 2026-09-20 at 2 percentage points. It has never been
    ## raised. **A tolerance raised twice is a defect in the PROJECTION, not in
    ## the tolerance**, and the projection is `gpui/app/dock_projection.nim`
    ## against GoldenLayout's own splitter arithmetic.
    ##
    ## Why any tolerance at all, stated rather than assumed: both sides report
    ## hundredths of their own viewport, and a pane boundary that falls between
    ## two device pixels rounds differently in a 1920-wide window than in a
    ## 1440-wide one. Two points is one grid step at the coarsest viewport in
    ## the matrix. Every other question is compared EXACTLY.

proc formatPaneRectangles*(rects: seq[PaneRect]): string =
  ## `pane=x,y,w,h` joined by `;`, sorted by pane id so the answer does not
  ## depend on either renderer's traversal order.
  var sorted = rects
  sorted.sort(proc (a, b: PaneRect): int = cmp(a.pane, b.pane))
  var parts: seq[string] = @[]
  for r in sorted:
    parts.add r.pane & "=" & $r.x & "," & $r.y & "," & $r.w & "," & $r.h
  parts.join(";")

proc parsePaneRectangles*(value: string): seq[PaneRect] =
  result = @[]
  if value.len == 0 or value == Unanswered: return
  for part in value.split(';'):
    let eq = part.find('=')
    if eq < 0: continue
    let nums = part[eq + 1 .. ^1].split(',')
    if nums.len != 4: continue
    try:
      result.add PaneRect(pane: part[0 ..< eq], x: parseInt(nums[0]),
                          y: parseInt(nums[1]), w: parseInt(nums[2]),
                          h: parseInt(nums[3]))
    except ValueError:
      discard

proc formatPanesPresent*(panes: seq[(string, int, int)]): string =
  ## `pane@activeIndex/tabCount`, in the front-end's own document order —
  ## which is the STACKING/TAB ORDER half of the question and is deliberately
  ## NOT sorted.
  var parts: seq[string] = @[]
  for (pane, activeIndex, tabCount) in panes:
    parts.add pane & "@" & $activeIndex & "/" & $tabCount
  parts.join(",")

proc formatEditorRowCount*(rows, firstLine, lastLine: int): string =
  "rows=" & $rows & ";first=" & $firstLine & ";last=" & $lastLine

proc formatGutterMarks*(marks: seq[(int, string)]): string =
  ## `line=mark` sorted by line. The mark alphabet is the closed one
  ## `editor_rows.nim` already publishes, reached through `gutterMarkName`.
  var sorted = marks
  sorted.sort(proc (a, b: (int, string)): int = cmp(a[0], b[0]))
  var parts: seq[string] = @[]
  for (line, mark) in sorted:
    parts.add $line & "=" & mark
  parts.join(";")

proc executionLineIn*(gutterMarks: string): int =
  ## **WHERE A FRONT-END SAYS THE DEBUGGER IS STOPPED**, read back out of the
  ## `gutter-marks-by-line` answer. `-1` when no row carries an execution mark.
  ##
  ## This is the ONE measurement every finding in this milestone rests on —
  ## `PLAT35-VG6` is entirely a claim about two of these numbers — and until
  ## 2026-09-21 nothing read it. The tier-3 cell for `gutter-marks-by-line`
  ## takes the residual branch, and that residual compares only mark KINDS as a
  ## sorted multiset, so a corpus in which both front-ends moved to completely
  ## different lines produced exactly the same verdict as the one the findings
  ## were written from. Re-running the capture against a corpus where four of
  ## six scenarios reached a different program state left the suite green at
  ## 90/309. A number nothing reads is a number nothing can contradict.
  ##
  ## A PARSER RATHER THAN A FIELD, so it works on both arms: the GPUI arm has
  ## no debugger-location JSON to read, and deriving the two sides' figures
  ## from two different sources would make them two facts with one name.
  result = -1
  if gutterMarks.len == 0 or gutterMarks == Unanswered: return
  for part in gutterMarks.split(';'):
    let eq = part.find('=')
    if eq <= 0: continue
    for atom in part[eq + 1 .. ^1].split('+'):
      if atom == "execution":
        try: return parseInt(part[0 ..< eq])
        except ValueError: return -1

proc formatInlineValueRuns*(runs: seq[(int, seq[(string, string)])]): string =
  ## `line:count:name=value|name=value` sorted by line, with the values in the
  ## order the front-end drew them — count, order AND text, which is what §3's
  ## row asks for and what a count alone would not catch.
  var sorted = runs
  sorted.sort(proc (a, b: (int, seq[(string, string)])): int = cmp(a[0], b[0]))
  var parts: seq[string] = @[]
  for (line, values) in sorted:
    var vs: seq[string] = @[]
    for (name, value) in values: vs.add name & "=" & value
    parts.add $line & ":" & $values.len & ":" & vs.join("|")
  parts.join(";")

proc formatTextMetrics*(metrics: seq[TextMetric]): string =
  var sorted = metrics
  sorted.sort(proc (a, b: TextMetric): int = cmp(ord(a.role), ord(b.role)))
  var parts: seq[string] = @[]
  for m in sorted:
    parts.add $m.role & "=" & $m.family & "/" & $m.size & "/" & $m.weight
  parts.join(";")

proc formatTokenColours*(tokens: seq[(TextRole, string)]): string =
  var sorted = tokens
  sorted.sort(proc (a, b: (TextRole, string)): int = cmp(ord(a[0]), ord(b[0])))
  var parts: seq[string] = @[]
  for (role, token) in sorted:
    parts.add $role & "=" & token
  parts.join(";")

proc formatFocusOrder*(order: seq[string]): string =
  order.join(",")

proc tokenIsPublished*(token: string): bool =
  for t in DesignTokenAlphabet:
    if t == token: return true
  false

# ---------------------------------------------------------------------------
# Comparison
# ---------------------------------------------------------------------------

type
  ComparisonVerdict* = enum
    cvEqual
    cvWithinTolerance
    cvDiffers
    cvOneSideSilent
      ## One front-end answered and the other emitted `Unanswered`. **A
      ## failure, never a skipped row** — the gate's own words.
    cvBothSilent

  QuestionComparison* = object
    question*: LayoutQuestion
    verdict*: ComparisonVerdict
    left*, right*: string
    detail*: string

proc rectanglesWithinTolerance(a, b: string): bool =
  let ra = parsePaneRectangles(a)
  let rb = parsePaneRectangles(b)
  if ra.len != rb.len or ra.len == 0: return false
  for i in 0 ..< ra.len:
    if ra[i].pane != rb[i].pane: return false
    if abs(ra[i].x - rb[i].x) > PaneRectangleTolerancePp: return false
    if abs(ra[i].y - rb[i].y) > PaneRectangleTolerancePp: return false
    if abs(ra[i].w - rb[i].w) > PaneRectangleTolerancePp: return false
    if abs(ra[i].h - rb[i].h) > PaneRectangleTolerancePp: return false
  true

proc compareAnswer*(q: LayoutQuestion; left, right: string): QuestionComparison =
  ## **ONE comparator, called by the suite and by the mutation arm's grader**,
  ## so a repair that weakens it weakens both at once rather than leaving a
  ## control that agrees with itself (§30).
  result = QuestionComparison(question: q, left: left, right: right, detail: "")
  if left == Unanswered and right == Unanswered:
    result.verdict = cvBothSilent
    result.detail = "neither front-end can answer this question"
  elif left == Unanswered or right == Unanswered:
    result.verdict = cvOneSideSilent
    result.detail = "one front-end answered and the other did not; §3 calls " &
                    "this a failure, never a skipped row"
  elif left == right:
    result.verdict = cvEqual
  elif q == lqPaneRectangles and rectanglesWithinTolerance(left, right):
    result.verdict = cvWithinTolerance
    result.detail = "within " & $PaneRectangleTolerancePp &
                    " percentage points; see PaneRectangleTolerancePp's history"
  else:
    result.verdict = cvDiffers

proc keysOf(value, sep: string): seq[string] =
  ## The left-hand names of a `key=value` list joined by `sep`.
  result = @[]
  if value.len == 0 or value == Unanswered: return
  for part in value.split(sep):
    let eq = part.find('=')
    if eq > 0: result.add part[0 ..< eq]
    elif part.len > 0: result.add part

proc valuesOf(value, sep: string): Table[string, string] =
  result = initTable[string, string]()
  if value.len == 0 or value == Unanswered: return
  for part in value.split(sep):
    let eq = part.find('=')
    if eq > 0: result[part[0 ..< eq]] = part[eq + 1 .. ^1]

proc residualHolds*(q: LayoutQuestion; gpui, electron: string): (bool, string) =
  ## **WHAT A FILED GAP STILL PROMISES.**
  ##
  ## A gap says the two front-ends diverge on a question and why. On its own
  ## that is a license: "they differ" is satisfied by any two strings, so a
  ## question with a gap filed against it would be a question no mutation could
  ## ever redden, and eight filed gaps would turn forty-eight tier-3 cells into
  ## decoration. Measured on 2026-09-20, that is not hypothetical — the first
  ## graded run of this vocabulary diverged on ALL EIGHT questions.
  ##
  ## So every gap carries a RESIDUAL: the part of the answer that must still
  ## agree even though the whole does not. The residual is what the gap's own
  ## measurement claims the divergence is *limited to*, turned into a predicate
  ## — so a divergence that grows past its filed shape fails here rather than
  ## being absorbed by the gap that named a smaller one.
  ##
  ## One function, called by the suite and by nothing that could disagree with
  ## it (§30).
  if gpui == Unanswered or electron == Unanswered:
    return (false, "one side is silent; a gap does not license silence")
  case q
  of lqPaneRectangles:
    # PLAT35-VG3 / VG5: the two default layouts differ, so the pane SETS and
    # therefore the splits differ. What must still hold is that each side
    # placed the editor and gave it the largest rectangle it drew — a layout in
    # which the source editor is not the dominant pane is not this product on
    # either front-end.
    let g = parsePaneRectangles(gpui)
    let e = parsePaneRectangles(electron)
    if g.len == 0 or e.len == 0:
      return (false, "one side placed no pane at all")
    for side in [g, e]:
      var editorArea = -1
      var biggest = 0
      for r in side:
        let area = r.w * r.h
        if r.pane == "editor": editorArea = area
        if area > biggest: biggest = area
      if editorArea < 0:
        return (false, "a side placed no `editor` pane")
      if editorArea < biggest:
        return (false, "a side gave some other pane more area than the editor")
    (true, "both placed the editor and gave it the largest rectangle")
  of lqPanesPresent:
    # PLAT35-VG5: the Electron default opens more panes. What must still hold
    # is that the three panes a replay session is ABOUT are on both sides.
    let g = keysOf(gpui, ",")
    let e = keysOf(electron, ",")
    if g.len == 0 or e.len == 0:
      return (false, "one side reported no pane")
    for required in ["editor", "state", "calltrace"]:
      var inG = false
      var inE = false
      for p in g:
        if p.startsWith(required & "@"): inG = true
      for p in e:
        if p.startsWith(required & "@"): inE = true
      if not inG or not inE:
        return (false, "`" & required & "` is missing from one side")
    (true, "editor, state and calltrace are present on both")
  of lqEditorRowCount:
    # PLAT35-VG2: the two editors hold different windows. What must still hold
    # is that both drew rows and both numbered them ascending from a real line.
    for side in [gpui, electron]:
      let f = valuesOf(side, ";")
      if not (f.hasKey("rows") and f.hasKey("first") and f.hasKey("last")):
        return (false, "a side did not report rows/first/last")
      try:
        if parseInt(f["rows"]) <= 0:
          return (false, "a side drew no rows")
        if parseInt(f["first"]) < 1:
          return (false, "a side numbered its first row below 1")
        if parseInt(f["last"]) < parseInt(f["first"]):
          return (false, "a side numbered its last row above its first")
      except ValueError:
        return (false, "a side's row figures do not parse")
    (true, "both drew rows, numbered ascending from a real line")
  of lqGutterMarks:
    # PLAT35-VG6: the two front-ends stop on different LINES. What must still
    # hold is that they draw the same MARKS — the kinds, as a sorted multiset.
    # This is the residual that catches a pane drawing no gutter at all.
    # ATOMIC kinds, split on `+`. A line that carries BOTH a stop and a
    # breakpoint reports `execution+breakpoint` as one cell, and on the two
    # front-ends those two facts land on the same line or on different ones
    # depending only on where each stopped — which is the divergence
    # PLAT35-VG6 already names. Comparing the cells verbatim would report that
    # co-location as a second, different divergence; comparing the atoms asks
    # the question the gap actually leaves open, which is whether the same
    # MARKS were drawn at all.
    var gk = newSeq[string]()
    var ek = newSeq[string]()
    for part in gpui.split(';'):
      let eq = part.find('=')
      if eq > 0:
        for atom in part[eq + 1 .. ^1].split('+'): gk.add atom
    for part in electron.split(';'):
      let eq = part.find('=')
      if eq > 0:
        for atom in part[eq + 1 .. ^1].split('+'): ek.add atom
    gk.sort(cmp)
    ek.sort(cmp)
    if gk != ek:
      return (false, "the MARK KINDS differ, not only the lines: " &
                     gk.join(",") & " against " & ek.join(","))
    (true, "the same marks, at different lines")
  of lqInlineValueRuns:
    # PLAT35-VG9: only the GPUI arm draws an inline value, because the
    # Electron front-end's flow overlay is off in every scenario the set
    # defines. What must still hold is that the side which DOES answer answers
    # about the line the debugger is stopped on, and about a variable that is
    # actually in scope there — which is what makes a producer that invented a
    # run, or attached one to the wrong row, fail here rather than being
    # absorbed by "they differ".
    #
    # BOTH EMPTY IS A LEGITIMATE STATE HERE, and saying why is the point.
    # Three of the six scenarios stop where there is nothing to draw —
    # `entry-shell` is unstepped and a Python program at line 1 has no locals
    # at all, and `stepped-editor` and `breakpoint-editor` stop on a
    # module-level `def` — so a front-end drawing nothing there is the correct
    # picture rather than a failure, and requiring divergence would be
    # requiring the product to invent a value.
    #
    # **THE FAILURE THIS DOES NOT GUARD IS GUARDED ONE LEVEL UP.** Both sides
    # empty because the GPUI locals never arrived is `PLAT35-PD3`, and it is
    # what retired `PLAT35-VG7` by mistake; the suite's `the GPUI arm's locals
    # producer LOADED something, not just ran` is what fails on it. Putting
    # that check here instead would redden the three scenarios that are
    # correctly empty, which is the wrong subject.
    if gpui.len == 0 and electron.len == 0:
      return (true, "neither front-end draws an inline value at this stop, " &
                    "which is the correct picture where nothing is in scope; " &
                    "the locals-arrived claim is asserted separately")
    if gpui.len == 0:
      return (false, "the Electron arm draws an inline run and the GPUI arm " &
                     "does not; this gap says it is the other way round")
    if electron.len != 0:
      return (false, "the Electron arm now reports inline runs too; the gap " &
                     "says it does not, so re-measure it")
    # `<line>:<count>:<name>=<value>[|…]`, one cell per line.
    var linesWithRuns = 0
    for part in gpui.split(';'):
      if part.len == 0: continue
      inc linesWithRuns
      let bits = part.split(':', 2)
      if bits.len != 3:
        return (false, "the GPUI run `" & part & "` is not `line:count:runs`")
      try:
        if parseInt(bits[0]) < 1:
          return (false, "a GPUI run is attached to line " & bits[0])
        if parseInt(bits[1]) < 1:
          return (false, "a GPUI run reports a count of " & bits[1])
      except ValueError:
        return (false, "a GPUI run's line or count does not parse: " & part)
      if bits[2].find('=') < 0:
        return (false, "a GPUI run carries no `name=value`: " & part)
    # **AND THE RUNS SIT ON ONE LINE, BECAUSE THAT IS WHAT AN INLINE VALUE IS.**
    # `inlineValuesOf` renders *the values in scope at THIS tick* beside the row
    # the debugger stopped on; it is a pure function of the current position and
    # caches nothing. So a front-end drawing a value beside EVERY row is not
    # drawing inline values — it is stamping an attribute.
    #
    # THIS IS NOT AN OBSERVED COUNT DRESSED AS A RULE. It is the limit the gap's
    # own measurement states, and it is what the mutation harness's `M2` arm
    # exists to violate: measured 2026-09-21, replacing the GPUI editor's
    # `structuredValues(row.values)` with a literal puts a run on all forty-five
    # to fifty-four rendered rows, against the one line the three scenarios that
    # answer at all report. Without this clause that arm SURVIVES, which is how
    # it was found.
    if linesWithRuns > 1:
      return (false, "the GPUI arm reports inline runs on " &
                     $linesWithRuns & " lines; an inline value is drawn " &
                     "beside the stopped row, so at most one line carries one")
    (true, "only the GPUI arm draws inline values, they sit on one line, and " &
           "each names a line, a count and a named value")
  of lqTextMetrics:
    # PLAT35-VG1 / VG8: the GPUI side declares metrics for fewer roles. What
    # must still hold is that the roles BOTH answer for agree exactly.
    let g = valuesOf(gpui, ";")
    let e = valuesOf(electron, ";")
    var common = 0
    for role, metric in g:
      if e.hasKey(role):
        inc common
        if e[role] != metric:
          return (false, "role `" & role & "`: " & metric & " against " &
                         e[role])
    if common == 0:
      return (false, "the two sides answer for no role in common")
    (true, "the " & $common & " role(s) both answer for agree exactly")
  of lqTokenColour:
    # PLAT35-VG8: the GPUI state pane publishes no text role, so its role set
    # is smaller. What must still hold is that it is a SUBSET and that the
    # tokens agree on every common role — which is what makes a hex value, or a
    # role resolved to the wrong token, fail here.
    let g = valuesOf(gpui, ";")
    let e = valuesOf(electron, ";")
    if g.len == 0 or e.len == 0:
      return (false, "a side resolved no role to a token")
    # NOT "the GPUI set is a subset", which was the first spelling and was
    # wrong in the other direction: the GPUI editor annotates a value row and
    # so answers `value-text` on scenarios where the Electron state pane is
    # empty and does not. Neither set contains the other. What must hold is
    # that every token either side answers with is PUBLISHED, that the roles
    # both answer for agree, and that there are at least two of them — the
    # last clause is what stops "they agree about nothing" from passing.
    var common = 0
    for role, token in g:
      if not tokenIsPublished(token):
        return (false, "role `" & role & "` resolved to `" & token &
                       "`, which is not in the published token alphabet")
      if e.hasKey(role):
        inc common
        if e[role] != token:
          return (false, "role `" & role & "`: " & token & " against " &
                         e[role])
    for role, token in e:
      if not tokenIsPublished(token):
        return (false, "role `" & role & "` resolved to `" & token &
                       "`, which is not in the published token alphabet")
    if common < 2:
      return (false, "the two sides resolve fewer than two roles in common")
    (true, "every token is published and the " & $common &
           " shared role(s) agree")
  of lqFocusOrder:
    # PLAT35-VG4 / VG5: the two focus orders hold different pane sets. What
    # must still hold is that the panes BOTH have appear in the same relative
    # order — a front-end that reversed its focus chain fails here.
    let g = gpui.split(',')
    let e = electron.split(',')
    if g.len == 0 or e.len == 0:
      return (false, "a side reported no focus order")
    # NOT "the shared panes are in the same relative order", which was the
    # first spelling and was a claim PLAT35-VG5 explicitly does not make: the
    # two front-ends open on different default LAYOUTS, and a focus chain walks
    # the layout, so `state` and `calltrace` are swapped between them because
    # the trees are different rather than because either chain is wrong.
    # Asserting it anyway would have been an alignment finding about a
    # divergence already filed one question over.
    #
    # What must still hold: both orders are non-empty, neither repeats a pane,
    # and the editor is in both — a focus chain that cannot reach the source
    # editor is broken on any layout.
    var seen = initHashSet[string]()
    for p in g:
      if p in seen:
        return (false, "the GPUI focus order names `" & p & "` twice")
      seen.incl p
    var editorInBoth = ("editor" in g) and ("editor" in e)
    if not editorInBoth:
      return (false, "the source editor is missing from one focus order")
    var shared: seq[string] = @[]
    for p in g:
      if p in e: shared.add p
    if shared.len < 2:
      return (false, "fewer than two panes are in both focus orders")
    (true, "both orders reach the editor, repeat nothing, and share " &
           $shared.len & " panes")

proc productDefectRegister*(): array[ProductDefectId, ProductDefect] =
  ## **THE FILED PRODUCT DEFECTS.** An `array` indexed by the enum, not a
  ## `Table`, for `editor_rows.FiledEditorGaps`' reason: a new id does not
  ## compile until it is filed, so the register's cardinality is a property of
  ## the type rather than of somebody's diligence.
  ##
  ## Each of the three was found by LOOKING AT A CAPTURE, which is what tier 4
  ## is for. None is fixed here, and the milestone says why in its status
  ## rather than here, because the reason is about scope and this file is about
  ## the defect.
  [
    pdElectronPanesAmputateText: ProductDefect(
      id: pdElectronPanesAmputateText,
      subject: "front-end",
      owner: "codetracer-specs/Front-Ends/Electron-GUI.md, the spec that owns " &
        "this front-end. It has no milestones file, so no milestone owns " &
        "these panes today and the first Electron-GUI milestone inherits " &
        "this. The consequence if none has by `reviewBy` is stated in " &
        "`src/tests/visual/tier4-review.json`'s `knownRed` block and enforced " &
        "by it: the quarantine on this defect's tier-4 case expires and " &
        "`PLAT-35` goes red in the shared floor lane.",
      reviewBy: "2026-12-31",
      measurement: "AT 1440x900 THE ELECTRON PANES AMPUTATE TEXT WITH NO " &
        "ELISION AFFORDANCE. Measured 2026-09-21 on `advanced-state`'s " &
        "capture at its declared viewport: the state pane draws " &
        "`add:<function add at 0x7fffe7`, the call-trace pane draws " &
        "`evaluate #2 (expression=\"`, and the right-hand stack's header " &
        "reads `AGENT ACTI...`. Only the pane title carries an ellipsis. The " &
        "value text has neither an ellipsis nor a horizontal scrollbar, so " &
        "nothing on screen says the value continues, and the part removed is " &
        "the object identity the reader opened the pane for.",
      remedy: "decide ONCE what this front-end does when a pane is narrower " &
        "than its content — a middle ellipsis keeps the informative end of a " &
        "`<function ... at 0x...>`, a horizontal scrollbar keeps all of it — " &
        "and apply it consistently. **IT IS NOT A MISSING AFFORDANCE**, and " &
        "the first draft of this entry said it was: `text-overflow` appears " &
        "102 times across 37 of the 61 stylesheets in " &
        "`src/frontend/styles/components/`, and `state.styl` alone uses " &
        "`clip`, `ellipsis` and `visible` in six places. What this front-end " &
        "has is the vocabulary applied inconsistently: " &
        "`.value-line-view-text` and `.value-expanded-view-text` are " &
        "`display: flex` with `text-overflow: visible`, and on a flex row the " &
        "property applies to the CHILDREN — which the comment on the " &
        "current-line row in that same file already says, having moved the " &
        "ellipsis to the code for exactly that reason."),

    pdEventLogDrawsOneRowSixTimes: ProductDefect(
      id: pdEventLogDrawsOneRowSixTimes,
      subject: "front-end",
      owner: "codetracer-specs/Front-Ends/Electron-GUI.md, the spec that owns " &
        "this front-end. It has no milestones file, so no milestone owns this " &
        "pane today and the first Electron-GUI milestone inherits it. The " &
        "consequence if none has by `reviewBy` is the same one " &
        "`PLAT35-PD1` carries and is enforced in the same place.",
      reviewBy: "2026-12-31",
      measurement: "THE EVENT-LOG TABLE HAS NO COLUMN HEADERS AND DRAWS ONE " &
        "ROW SIX TIMES. Measured 2026-09-21 on `continued-event-log` at " &
        "1920x1080, after a single `continueForward`: four columns are drawn " &
        "— a left figure (`170`), a count (`5`), a source location " &
        "(`main.py:112`) and a payload (`stdout: checksum = 73`) — and none " &
        "is labelled. All six rows carry IDENTICAL text. " &
        "`test-programs/calc/main.py` prints one line per member of " &
        "`EXPRESSIONS`, which has five, at line 110, and then the checksum at " &
        "line 112, so the six rows should be five distinct results followed " &
        "by `checksum = 73`. The pane's own footer says `Rows 1 to 6 of 6`, " &
        "so it holds the right NUMBER of events and draws the wrong one in " &
        "five of them.",
      remedy: "label the four columns; and establish which of the two the row " &
        "renderer does — shows one event six times, or shows six events' " &
        "wrong field. **This remedy deliberately does not guess**: the tier-4 " &
        "reading that found it recorded it as an observation and said the " &
        "mechanism was not established, and `calc` at 1920x1080 after one " &
        "`continueForward` reproduces it in a single run."),

    pdGpuiDrawsNoInlineValue: ProductDefect(
      id: pdGpuiDrawsNoInlineValue,
      subject: "front-end",
      owner: "PLAT-21, `GPUI debugger surfaces`, which is the milestone that " &
        "built the surface this happens on. Recorded in PLAT-35's status with " &
        "this id and this date. The consequence if PLAT-21 has not taken it " &
        "by `reviewBy`: `PLAT35-VG9`'s six tier-3 cells are a coin flip — " &
        "they redden on the runs where the locals do not arrive — so on that " &
        "date the honest move is to stop counting them and say the milestone " &
        "grades seven of its eight questions, rather than keep a cell whose " &
        "verdict depends on the run.",
      reviewBy: "2026-12-31",
      measurement: "THE GPUI ARM'S LOCALS SOMETIMES DO NOT ARRIVE, AND " &
        "NOTHING RAISES WHEN THEY DO NOT. Measured 2026-09-21 over six runs " &
        "of ONE gate binary against ONE tree: five report " &
        "`56:1:mul=<function mul at 0x...>` on `advanced-state`, " &
        "`110:2:results=@[]|value=5` on `returned-calltrace` and " &
        "`113:1:results=05 07 2a 11 02 (5 bytes)` on `continued-event-log`; " &
        "the sixth reports an EMPTY inline-value run set on all six " &
        "scenarios. `requestAndLoadLocals` did not raise in that run — the " &
        "suite records each producer's exception and there was none — so the " &
        "state pane simply held no variables and every question about it " &
        "compared two empty answers and agreed.\n\n" &
        "THAT RUN IS WHAT RETIRED `PLAT35-VG7`, against a divergence which " &
        "five runs out of six can demonstrate. The gap is re-filed as " &
        "`PLAT35-VG9` and the suite now asserts the producers' EFFECT as " &
        "well as their not raising.\n\n" &
        "ONE HYPOTHESIS TESTED AND FALSE: that it is a load-timing race. The " &
        "gate was re-run with twenty-four busy loops saturating the machine " &
        "and the GPUI arm still reported all three values. The cause is NOT " &
        "established and is deliberately not guessed at here.",
      remedy: "make `requestAndLoadLocals` report the arrival rather than the " &
        "send — a producer whose reply did not land must fail, not return. " &
        "Until it does, `the GPUI arm's locals producer LOADED something, " &
        "not just ran` is what turns this from a silent empty pane into a " &
        "named red, which is the least this deserved and is not the fix."),

    pdEditorScrollNotRenormalised: ProductDefect(
      id: pdEditorScrollNotRenormalised,
      subject: "front-end",
      owner: "codetracer-specs/Front-Ends/Electron-GUI.md, the spec that owns " &
        "this front-end. Recorded in PLAT-35's status with this id and this " &
        "date. The consequence if nobody has taken it by `reviewBy`: the " &
        "row-count pins in `src/tests/visual/corpus-pins.json` that currently " &
        "admit three answers stay a SET rather than a value, so the strongest " &
        "check this campaign can make about where an editor came to rest goes " &
        "on being a weaker one, and the milestone should say so rather than " &
        "let a tolerance become the normal shape of a pin.",
      reviewBy: "2026-12-31",
      measurement: "THE EDITOR'S SCROLL IS NOT RE-NORMALISED WHEN ITS CONTENT " &
        "HEIGHT GROWS AFTER A MOVE, so it comes to rest in up to three places " &
        "for one operation. Measured 2026-09-21 on `calc`, both affected " &
        "scenarios, ten captures. The content height grows in three stages " &
        "after a debugger move — `117 x 22 = 2574` for the lines alone, " &
        "`+12` when the horizontal scrollbar appears, `+21` when the flow " &
        "overlay's loop-iteration view zone for the loop at line 108 is " &
        "installed — and the editor ends bottom-anchored at whichever value " &
        "was current when its last scroll was computed. Every observed " &
        "resting position is exactly `contentHeight - layoutHeight` for one " &
        "of the three: at the 978px viewport, 1596, 1608 and 1629; at the " &
        "798px viewport, 1776, 1788 and 1809. Nothing re-clamps afterwards — " &
        "the intermediate positions were still there several seconds later, " &
        "with the zone laid out and two byte-identical screenshots taken.\n\n" &
        "IT IS NOT A HARNESS RACE AND THAT WAS TESTED. Settling the rendered " &
        "frame between operations makes the TWENTY-TWO-operation scenario " &
        "reproduce (seven captures agree); it cannot help the ONE-operation " &
        "scenario, where the content growth follows the only move there is.",
      remedy: "re-clamp or re-reveal when the content height changes, so the " &
        "editor's resting position is a function of the final content height " &
        "rather than of when the last scroll happened. **Do not fix this in " &
        "the capture harness**: a harness that normalises the scroll before " &
        "the screenshot publishes a frame the product does not reliably " &
        "produce, which is hiding the defect rather than measuring it.")
  ]

proc gapRegister*(): Table[LayoutQuestion, seq[VisualGap]] =
  ## **The filed, named gaps.** Each carries its measurement and its remedy, so
  ## a divergence that is carried is one somebody decided to carry.
  result = initTable[LayoutQuestion, seq[VisualGap]]()
  result[lqTextMetrics] = @[
    VisualGap(
      id: vgGpuiHasNoPixelBackend,
      question: lqTextMetrics,
      subject: "renderer",
      measurement: "isonim-gpui's Rust shim is built WITHOUT `--features " &
        "gpui-backend` in this workspace, so `createWindow` opens nothing and " &
        "there is no shaped glyph to measure. Measured 2026-09-20: " &
        "`rust/target/debug/libgpui_nim_shim.so` is present and its window " &
        "state machine answers, and `gpui/main.nim`'s own header records the " &
        "same boundary. The GPUI answer is therefore the DECLARED metric the " &
        "leaf renderer stamps, not a measured one.",
      remedy: "build the shim with `--features gpui-backend` and read the " &
        "metric back through the text system, in the same run that captures " &
        "pixels for tier 1 and tier 2.")]
  result[lqEditorRowCount] = @[
    VisualGap(
      id: vgElectronEditorIsMonaco,
      question: lqEditorRowCount,
      subject: "front-end",
      measurement: "the Electron editor's rows are Monaco's `.view-line` " &
        "divs, which are absolutely positioned and reordered on scroll and " &
        "carry NO line number; the number lives on the gutter and the K-th " &
        "gutter child pairs with the K-th `.view-line` " &
        "(`src/tests/gui/page-objects/panes/editor/editor-pane.ts`). So the " &
        "Electron answer's first/last line numbers are read from the gutter " &
        "and its row count from the view-lines, and the two are asserted " &
        "equal in length before the answer is formed.",
      remedy: "none required; recorded so the next reader does not `grep` " &
        "`.view-line` for a line number and conclude the pane is broken.")]
  result[lqPanesPresent] = @[
    VisualGap(
      id: vgDefaultLayoutsDiffer,
      question: lqPanesPresent,
      subject: "front-end",
      measurement: "THE TWO FRONT-ENDS OPEN A REPLAY SESSION ON DIFFERENT " &
        "DEFAULT LAYOUTS, and this is the largest alignment defect this " &
        "milestone found. Measured 2026-09-20 on the `calc` recording, same " &
        "scenario, same viewport: the GPUI front-end draws FOUR panes — " &
        "`debugControls@0/1,editor@0/1,calltrace@0/1,state@0/2` — from " &
        "`layout_model.defaultReplayLayout()`; the Electron front-end draws " &
        "EIGHT — `commandPalette, filesystem, editor, state, calltrace, " &
        "eventLog, testResults, constraints` — from GoldenLayout's " &
        "`src/config/default_layout.json`. Only three pane ids are common to " &
        "both. The same divergence drives the pane-rectangle answers.",
      remedy: "one default, read from one place. Either " &
        "`defaultReplayLayout()` becomes the source `default_layout.json` is " &
        "generated from, or the Electron front-end reads the model's default " &
        "at session open. It is a product decision rather than a harness one " &
        "and it belongs with whichever milestone owns the shell's default; " &
        "this gate is what will notice when it lands, because the two answers " &
        "becoming equal FAILS this row until the gap is retired.")]
  result[lqGutterMarks] = @[
    VisualGap(
      id: vgBreakpointOffsetResolvesDifferently,
      question: lqGutterMarks,
      subject: "front-end",
      measurement: "THE BREAKPOINT OFFSET RESOLVES AGAINST TWO DIFFERENT " &
        "FIRST-DRAWN ROWS. Measured 2026-09-21: on `breakpoint-editor` the " &
        "GPUI arm answers `2=breakpoint;44=execution` and the Electron arm " &
        "`26=breakpoint;44=execution`. Both drivers obey the same rule — the " &
        "scenario's `line` is an offset from the FIRST ROW THE EDITOR DREW, " &
        "never a literal — and they disagree because the two editors hold " &
        "different windows: the GPUI surface starts its budgeted row set at " &
        "line 1, Monaco's viewport starts at line 25. That is " &
        "`PLAT35-VG2`'s subject arriving in a second answer.\n\n" &
        "THIS GAP PREVIOUSLY SAID SOMETHING ELSE AND IT WAS AN ARTEFACT. It " &
        "read: *the same operation sequence stops the two front-ends on " &
        "different lines — after six step-ins, line 44 on GPUI and line 29 " &
        "on Electron.* That is FALSE. The Electron figure came from a " &
        "capture that counted CLICKS ISSUED rather than MOVES MADE, so the " &
        "recorded corpus was one to three operations behind the sequence it " &
        "claimed. Re-measured against a corpus whose stopped line, tick " &
        "count, trajectory and settle attempts are byte-identical across " &
        "FIVE consecutive runs of the identical specification — it was three " &
        "when this was first written, and three runs agreeing is not a " &
        "measurement of reproducibility — the two arms agree on the " &
        "execution line in ALL SIX " &
        "scenarios: 1, 44, 56, 110, 113 and 44. The two step-ins travel the " &
        "same distance, and the finding that they did not was a defect in " &
        "the instrument.",
      remedy: "give the two drivers one definition of `the first drawn row`, " &
        "or resolve the scenario's offset against the FILE rather than " &
        "against the window — the second is the smaller change and makes the " &
        "mark independent of how many rows a front-end chose to draw. Until " &
        "then the two marks are on different lines for a reason the gate can " &
        "name, which is better than the reason it used to name.")]
  result[lqInlineValueRuns] = @[
    VisualGap(
      id: vgOnlyGpuiDrawsInlineValues,
      question: lqInlineValueRuns,
      subject: "front-end",
      measurement: "ONLY THE GPUI ARM DRAWS AN INLINE VALUE. Measured " &
        "2026-09-21 over six runs of one gate binary on one tree: five of " &
        "them answer `56:1:mul=<function mul at 0x...>` on `advanced-state`, " &
        "`110:2:results=@[]|value=5` on `returned-calltrace` and " &
        "`113:1:results=05 07 2a 11 02 (5 bytes)` on `continued-event-log`, " &
        "against an Electron arm that answers an EMPTY run set on all six in " &
        "every run. The sixth GPUI run answers empty everywhere, which is " &
        "`PLAT35-PD3` and is why `PLAT35-VG7` was retired by mistake. The " &
        "Electron side is Monaco with the flow overlay off in every scenario " &
        "the set defines; the GPUI side renders `inlineValuesOf(stateVM)` " &
        "beside the stopped line whenever its locals are loaded.",
      remedy: "decide whether the scenario set should turn the Electron " &
        "front-end's flow overlay ON — which would make these six cells " &
        "compare two NON-empty answers rather than one — or whether the GPUI " &
        "editor should stop drawing values the reference front-end does not. " &
        "Either closes it; neither is a change to this gate. `PLAT35-PD3` " &
        "has to be closed first, because until it is, a run in which the " &
        "GPUI locals do not arrive retires this gap again.")]
  result[lqTokenColour] = @[
    VisualGap(
      id: vgGpuiStatePaneHasNoTextRoles,
      question: lqTokenColour,
      subject: "renderer",
      measurement: "THE GPUI STATE PANE PUBLISHES NO TEXT ROLE, so two of the " &
        "five roles are answerable on one side only. Measured 2026-09-20: the " &
        "Electron arm answers all five — `editor-code`, " &
        "`gutter-line-number`, `pane-title`, `value-name`, `value-text` — and " &
        "the GPUI arm answers three, because its state pane is drawn through " &
        "`view_vocabulary/gpui_binding.renderGpui` from PLAT-3's medium-" &
        "independent tree, and that tree carries no text role. The editor's " &
        "three roles ARE stamped, by `gpui/app/leaves.nim`, which is why the " &
        "difference is a role SET rather than a role disagreement.",
      remedy: "stamp `TextRoleAttribute`, `TextMetricAttribute` and " &
        "`TokenAttribute` in `gpui_binding` from the vocabulary's own entry " &
        "kinds, which is a change to the BINDING and reaches all sixteen " &
        "entries at once rather than to this one pane. Doing it here would " &
        "have put a fourth spelling of the role alphabet in a fourth file.")]
  result[lqFocusOrder] = @[
    VisualGap(
      id: vgGpuiFocusIsDeclaredNotEnforced,
      question: lqFocusOrder,
      subject: "renderer",
      measurement: "the GPUI answer is the order `renderLeaves` STAMPS on " &
        "the leaves, and nothing enforces it: `PLAT21-VG3` measured that " &
        "isonim-gpui has focus at the WINDOW level only — `grep -n focus` " &
        "over the shim's `tree.rs` and `render_sync.rs` returns nothing — so " &
        "no element can hold, trap or refuse focus. The Electron answer is " &
        "also a declaration (`tabindex` on the pane roots) and IS enforced by " &
        "the DOM, so the two are comparable and only one of them happens.",
      remedy: "isonim-gpui: an element-level focus concept, which is " &
        "`PLAT21-VG3`'s own remedy. Until then the two declared orders are " &
        "compared, which catches a drift in either.")]
  result[lqPaneRectangles] = @[
    VisualGap(
      id: vgPaneRectangleTolerance,
      question: lqPaneRectangles,
      subject: "harness",
      measurement: "pane rectangles are the ONE question compared with a " &
        "tolerance, " & $PaneRectangleTolerancePp & " percentage points, " &
        "because a boundary falling between two device pixels rounds " &
        "differently at 1920 and at 1440. Every other question is exact.",
      remedy: "the tolerance's history is recorded beside its declaration; a " &
        "tolerance raised twice is a defect in the projection.")]

proc allGaps*(): seq[VisualGap] =
  result = @[]
  for _, gaps in gapRegister():
    for g in gaps: result.add g
  result.sort(proc (a, b: VisualGap): int = cmp(ord(a.id), ord(b.id)))
