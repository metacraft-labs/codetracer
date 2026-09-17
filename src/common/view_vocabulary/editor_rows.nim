## view_vocabulary/editor_rows.nim — PLAT-22. **What one row of a source
## editor is, declared ONCE for every front-end that draws one.**
##
## ## WHY THIS IS NOT A SEVENTEENTH VOCABULARY ENTRY
##
## PLAT-3's admission test REFUSED `Editor`, and PLAT-21 applied that decision
## by making the source pane a `nativeEscape` — `vocabulary.nativeEscape("source",
## medium, "editor")` — which `portability.checkPortable` refuses on purpose.
## PLAT-22 says the same from the other end: *"the editor is deliberately not a
## PLAT-3 vocabulary entry: it is a native view, the sanctioned escape, for the
## same reason the terminal's is."*
##
## That decision says an editor is not something every medium can draw from one
## abstract tree. **It does not say the three native views may disagree about
## what a ROW IS**, and until this module they did. The vocabulary is the set of
## things a binding can render anywhere; this is the set of facts an editor
## needs wherever it is written. Those are different questions and this file
## answers the second one only: there is no `ViewNode` here, no tag, no cell and
## no pixel, and `checkPortable` never sees any of it.
##
## ## THE DUPLICATION THIS EXISTS TO STOP, MEASURED RATHER THAN ASSERTED
##
## Verification-Harness-Traps §14 is the construction rule: *"one predicate, one
## function, rule and control both calling it"*. Measured on 2026-09-16, before
## this module existed, the repository answered "what is on line N of the source
## pane" in **two** places that share no type, no constant and no call:
##
##   * `tui/app/views/gutter.gutterRow(GutterLineSpec) -> StyledRow`
##   * `ui/trace.editorLineNumber(self, path, line, …) -> cstring`
##
## and a third partial spelling of the same three marks as string ids in
## `tui/app/theme/degradation.nim`. Concretely paired:
##
##   | concern             | terminal                        | web                          |
##   |---------------------|---------------------------------|------------------------------|
##   | execution marker    | the pointer field, `-->`        | `gutter-highlight-active`    |
##   | active breakpoint   | `gmBreakpoint`, `●`             | `gutter-breakpoint-enabled`  |
##   | disabled breakpoint | `gmBreakpointDisabled`, `○`     | `gutter-breakpoint-disabled` |
##   | tracepoint          | `gmTracepoint`, `◆`             | `gutter-trace`               |
##   | provenance          | `lineNumberStyle(provenance)`   | **absent**                   |
##
## A THIRD front-end written against either of those would have been the third
## copy. So the rules that decide a row are here, once, and the media map the
## answer onto glyphs, classes or elements. §14b's own test of whether an
## extraction is done is *"count the copies"*; `test_editor_surface.nim` counts
## them by driving the terminal's and the GPUI front-end's rows through these
## functions and requiring the same answers.
##
## ## THE FOUR CONCERNS ARE A VALUE, BECAUSE PLAT-22 MAKES THEM THE CRITERIA
##
## PLAT-22's risk note: *"an editor is adopted for its feature list and the
## debugger-specific overlays turn out to require forking it"*, mitigated by
## *"the overlays are in the evaluation criteria above, before adoption"*. A
## criterion in a paragraph is a criterion nobody can fail, so `EditorConcern`
## enumerates the four the milestone names and `EditorSupport` is what a medium
## answers for each. The table is not a claim: `editor_surface.nim` reports what
## it actually produced and the gate asserts the two are equal, in BOTH
## directions, the way PLAT-21's escape census does.
##
## ## PURE, AND THAT IS LOAD-BEARING TWICE
##
## `std/strutils` is the whole of the import list. Two things follow:
##
##   1. The GPUI front-end can read it without linking a terminal renderer —
##      `ci/lib/test-lane-files.sh`'s `gpui-shell` lane carries no `isonim_tui`
##      flags, deliberately, and a shared row model that reached `isonim_tui`
##      would have made that lane a lie.
##   2. It compiles in a workspace with no `isonim-tui` checkout at all, which
##      is the property `common/view_vocabulary.nim`'s own header claims for the
##      whole package and which a consumer added carelessly would remove.

import std/strutils

type
  EditorMark* = enum
    ## PLAT-22's "per-line status", as the closed set both existing front-ends
    ## already draw. An enum rather than a string for the reason
    ## `tui/app/source_binding.SourcePointKind` gives: a typo in a string
    ## degrades into "no mark on this line", which is a silent,
    ## plausible-looking screen, and a typo in an enum member does not compile.
    emNone
    emBreakpoint          ## stops here
    emBreakpointDisabled  ## present, not armed
    emTracepoint          ## records without stopping

  EditorPointKind* = enum
    ## What a declared point IS, before a line decides how to show it.
    epkBreakpoint
    epkTracepoint

  EditorPoint* = object
    ## One breakpoint or tracepoint, medium-free.
    ##
    ## Shaped like `point_list_vm.PointListEntry` (path, line, kind, enabled) so
    ## that the day something fills `PointListVM` from a backend the conversion
    ## is four field copies.
    ##
    ## **NOTHING A USER RUNS FILLS IT WITH THE POINTS A GUTTER NEEDS — and the
    ## measurement that used to stand here was wrong, corrected 2026-09-16 and
    ## again 2026-09-17.** It read *"`setPoints` still has two call sites and
    ## neither is a backend response"*. The correction is about the SIGNAL and
    ## not about `setPoints`, which is where the first attempt at it went
    ## wrong: `setPoints` has two invocations (the storybook fixture and
    ## `applyCollections` — a third grep hit is its own declaration) and
    ## neither of THOSE is a backend response, which still holds. What changed
    ## on 2026-09-17 is that `PointListVM.points` became
    ## `ReplayDataStore.pointList.rows`, which
    ## `ReplayDataStore.applyTracepointResults` writes from a
    ## `ct/run-tracepoints` sweep — **writing that signal directly, never
    ## through `setPoints`**. So the signal gained a backend producer while
    ## `setPoints` did not. That does not close this gap, because a sweep
    ## says where a tracepoint FIRED and a gutter needs the lines that CARRY
    ## one — which is `point_collection_source.applyCollections`, still with no
    ## production caller.
    ##
    ## The GAP is still real and it is a different gap: `applyCollections` has
    ## **no production caller** — all twelve of its call sites are tests (the
    ## thirteenth grep hit is its declaration; `source_binding.nim` says twelve
    ## and is the one to trust) — so
    ## what is missing is a shipped path that calls the producer, not the
    ## producer. Saying "nothing writes it" points the next reader at work that
    ## is already done. Recorded beside the parameter in `editor_surface.nim`
    ## too.
    path*: string
    line*: int
    kind*: EditorPointKind
    enabled*: bool

  EditorProvenance* = enum
    ## How much an editor may CLAIM about the text it is showing.
    ##
    ## CTUI-5: *"a file served `savUnverified` must not look identical to one
    ## served `savVerified`. CTUI-4 fought hard for this distinction; do not
    ## render it away."* It is here rather than in the terminal's gutter because
    ## the web front-end renders it NOWHERE — measured 2026-09-16, `grep -i
    ## unverified` over `src/frontend/ui`, `ui_js.nim` and `viewmodel/views`
    ## returns nothing — so it is a fact about the recording that exactly one of
    ## three media currently tells the user, and a shared row model is where
    ## that stops being invisible.
    epVerified     ## the recording's own copy
    epUnverified   ## a working-tree read, or a revision that could not be confirmed
    epAbsent       ## no source of any kind for this path

  EditorPointer* = enum
    ## PLAT-22's "execution pointer" — and the second cursor beside it.
    ##
    ## TWO VALUES AND NOT A BOOL, which is CTUI-6's contract carried across:
    ## the debugger's stop and the call-stack pane's inspection cursor are
    ## different questions, and a single flag with two meanings is the
    ## conflation that contract forbids. `eptExecution` wins when a line is
    ## both, which is the case where the inspected frame IS the frame the
    ## debugger is stopped in.
    eptNone
    eptInspection
    eptExecution

  EditorFlowState* = enum
    ## PLAT-22's "flow overlay", reduced to what a row can carry.
    ##
    ## THE OVERLAY IS PER LINE AND THE PANEL IS NOT, and only the per-line half
    ## belongs to a row: `FlowVM` also owns an iteration slider, a step list and
    ## a loop tree, which are a PANE (`isonim_flow_view.nim` draws them) rather
    ## than a property of line N.
    efsUnknown     ## the flow has nothing to say about this line
    efsTaken       ## this line ran in the selected iteration
    efsNotTaken    ## this line did not run

  EditorValue* = object
    ## One inline value, as it will appear beside a line.
    ##
    ## `name` and `value` and nothing else. The VALUE is already a string
    ## because PLAT-2's presenter produced it at a budget the front-end
    ## declared; re-formatting it here would be the second spelling of one
    ## value in one pane that PLAT-2's own risk note names.
    name*: string
    value*: string

  EditorRow* = object
    ## **One row of a source editor, on any medium.**
    line*: int
      ## 1-based.
    text*: string
      ## The source text, or "" when `held` is false.
    held*: bool
      ## Whether `text` is the file's text. FALSE IS NOT AN EMPTY LINE: it is
      ## `source_vm.srkRequest`, the answer whose whole reason for existing is
      ## that *"an empty-string default is exactly how a source pane silently
      ## renders blank, and a blank pane over a working debugger is
      ## indistinguishable from a file of blank lines"*. A medium renders its
      ## own placeholder; none of them may render nothing.
    pointer*: EditorPointer
    mark*: EditorMark
    values*: seq[EditorValue]
    flow*: EditorFlowState

  EditorConcern* = enum
    ## **PLAT-22's four evaluation criteria, as a value.**
    ecExecutionPointer = "execution pointer"
    ecLineStatus = "per-line status"
    ecInlineValues = "inline values"
    ecFlowOverlay = "flow overlay"

  EditorSupport* = enum
    ## What a medium's editor does with a concern. The three words are chosen
    ## so the middle one cannot be read as either of the others.
    esRendered
      ## The medium draws it, from the row.
    esDegraded
      ## The medium reports it rather than drawing it — PLAT-9's rule, never a
      ## blank region.
    esAbsent
      ## The medium's editor does not carry it at all.

  EditorConcernSupport* = array[EditorConcern, EditorSupport]

  EditorProducerGapId* = enum
    ## A filed gap's own name, so a status block, a comment and a case all
    ## spell it the same way.
    pgMarksHaveNoProducer = "PLAT22-PG1"
    pgFlowHasNoPerLineFact = "PLAT22-PG2"
    pgInlineValuesDiverge = "PLAT22-PG3"

  EditorProducerGap* = object
    ## **A concern a medium can draw and nothing supplies.**
    ##
    ## SEPARATE FROM `EditorSupport`, AND THE SEPARATION IS THE POINT.
    ## `EditorSupport` answers *what does this medium do with the row it is
    ## given*; this answers *is there anything to put in the row*. PLAT-21
    ## learned the cost of conflating them the other way round — its `PLAT21-VG4`
    ## is a gap against the VOCABULARY filed in a register of gaps against the
    ## RENDERER, and its own note says *"conflating them is how a renderer bug
    ## sends the next reader to edit the vocabulary, and how a vocabulary defect
    ## stops being looked at"*. A medium that draws a mark perfectly on a row no
    ## producer ever marks is a renderer with nothing wrong with it, and reading
    ## that as `esAbsent` would send the next reader to the wrong file.
    id*: EditorProducerGapId
    concern*: EditorConcern
    subject*: string
      ## Which layer owes the producer: `viewmodel`, `backend`, `front-end`.
    measurement*: string
      ## What was measured, and when. A gap with no measurement is an opinion.
    remedy*: string
      ## What would close it. Named so the next milestone inherits a task
      ## rather than a complaint.

const
  EditorConcerns*: set[EditorConcern] = {ecExecutionPointer, ecLineStatus,
                                         ecInlineValues, ecFlowOverlay}
    ## The four, as a set a test can assert the cardinality of. PLAT-22 names
    ## exactly these; a fifth arriving without the milestone's criteria being
    ## revisited moves a number a case reads.

  FiledEditorGaps*: array[EditorProducerGapId, EditorProducerGap] = [
    pgMarksHaveNoProducer: EditorProducerGap(
      id: pgMarksHaveNoProducer,
      concern: ecLineStatus,
      subject: "viewmodel",
      measurement: "`PointListVM.points` is `ReplayDataStore.pointList.rows` " &
        "since 2026-09-17 and has TWO producers — " &
        "`point_collection_source.applyCollections` (declared points) and " &
        "`ReplayDataStore.applyTracepointResults` (a `ct/run-tracepoints` " &
        "sweep). Neither reaches an editor gutter: `applyCollections` still " &
        "has no production caller, a sweep reports where a tracepoint FIRED " &
        "rather than which lines carry one, and the terminal's own production " &
        "caller (`tui/host/tui_session.nim`) leaves `sourcePaneModelFor`'s " &
        "`points` parameter at its default, so the shipped terminal draws no " &
        "mark. This is PLAT-21 residue 3, narrowed rather than closed.",
      remedy: "a producer that writes the engine's own `setBreakpoints` " &
        "acknowledgement into `PointListVM`; then `editorSurfaceFor` reads it " &
        "instead of taking the points as a parameter, and both editors gain " &
        "marks from one change."),
    pgFlowHasNoPerLineFact: EditorProducerGap(
      id: pgFlowHasNoPerLineFact,
      concern: ecFlowOverlay,
      subject: "viewmodel",
      measurement: "`FlowVM` owns `steps`, `loops`, `selectedIteration` and " &
        "`focusedLoop`. `FlowStepEntry` carries `step`, `location` (a DISPLAY " &
        "string), `expression`, `beforeValue` and `afterValue` — and no line " &
        "number — so taken/not-taken per line is not derivable from it. The " &
        "web front-end does not derive it from `FlowVM` either: " &
        "`ui/editor.flowStyleLines` reads `FlowComponent.flow` , a parallel " &
        "payload, and `ui/flow.nim`'s own header says `the FlowVM receives " &
        "the same data but does not affect rendering yet`. `FlowLoopInfo` " &
        "carries `first`/`last`, so loop EXTENT is derivable and is what this " &
        "row carries.",
      remedy: "a per-line taken/not-taken memo on `FlowVM`, fed from the same " &
        "payload `flowStyleLines` already reads. Until then a row may say " &
        "`in the focused loop` and must not say `this line ran`."),
    pgInlineValuesDiverge: EditorProducerGap(
      id: pgInlineValuesDiverge,
      concern: ecInlineValues,
      subject: "front-end",
      measurement: "The two existing editors show DIFFERENT DATA under one " &
        "name. The terminal's inline annotations are " &
        "`StateVM.currentVariables` selected by whole-word lexical match " &
        "(`tui/app/source_binding.annotationsFrom`); the web's are the flow " &
        "payload's `step.beforeValues`, anchored by " &
        "`flow_layout.inlineLabelAnchorColumn` " &
        "(`ui/flow.insertInlineDecorations`). Neither has a counterpart on " &
        "the other medium. So `wired to the same ViewModels the terminal and " &
        "web editors use` cannot be satisfied for this concern by any binding: " &
        "there is no ONE ViewModel the two editors use.",
      remedy: "decide which of the two `inline values` means, in a GUI spec, " &
        "before a third front-end picks one by accident. This binding picks " &
        "the terminal's — the shared ViewModel — and says so.")]
    ## **The filed gaps, as DATA.** PLAT-21's `gpui_gaps.FiledGpuiGaps` shape,
    ## reused rather than re-derived (a second register is §14 one level up).
    ##
    ## `array[EditorProducerGapId, …]` and not a `seq`, so the id and the entry
    ## cannot drift apart and a new id does not compile until it is filed.

func filedGap*(id: EditorProducerGapId): EditorProducerGap =
  FiledEditorGaps[id]

func concernsWithFiledGap*(): set[EditorConcern] =
  ## Which concerns carry a filed producer gap. Derived from the register, so a
  ## gate asserting it against a RUN is comparing two independent answers.
  for g in FiledEditorGaps:
    result.incl g.concern

func isWordChar(c: char): bool =
  c in {'a'..'z', 'A'..'Z', '0'..'9', '_'}

func mentionsWord*(line, word: string): bool =
  ## Does `line` contain `word` delimited by non-word characters?
  ##
  ## Whole-word, not substring: `sum` must not match `summary`, and an inline
  ## value attached to the wrong identifier is a STALE value by another route —
  ## which is worse than none, because `x: 42` beside a line where `x` is now 7
  ## reads exactly like the truth.
  ##
  ## MOVED HERE FROM `tui/app/views/inline_annotations.nim`, which now calls it.
  ## The rule was already stated there as *"the same rule an editor's inline-
  ## value overlay uses"*, and a second editor is exactly when that sentence
  ## stops being a description and becomes a duplication (§14).
  if word.len == 0:
    return false
  var start = 0
  while true:
    let at = line.find(word, start)
    if at < 0:
      return false
    let beforeOk = at == 0 or not isWordChar(line[at - 1])
    let afterIdx = at + word.len
    let afterOk = afterIdx >= line.len or not isWordChar(line[afterIdx])
    if beforeOk and afterOk:
      return true
    start = at + 1

func valuesForLine*(lineText: string;
                    values: openArray[EditorValue]): seq[EditorValue] =
  ## The subset of `values` whose names appear on `lineText`, in the order
  ## `values` gave them.
  ##
  ## The producer's order is kept rather than sorted, because
  ## `StateVM.currentVariables` reports arguments before locals and a reader
  ## scanning a line wants the same order twice running.
  result = @[]
  for v in values:
    if mentionsWord(lineText, v.name):
      result.add v

func markFor*(points: openArray[EditorPoint]; path: string;
              line: int): EditorMark =
  ## The mark on one line of one file.
  ##
  ## **A BREAKPOINT BEATS A TRACEPOINT**, and the precedence is here rather than
  ## in a paint order because two media resolved it two ways: the terminal's
  ## `marksForFile` emitted tracepoints first and let `markFor`'s last-wins pick
  ## the breakpoint, while the web's `editorLineNumber` writes both divs and
  ## lets CSS decide. Written as an explicit ranking, a medium cannot get it
  ## wrong by drawing in a different order — which is exactly what a third
  ## front-end was about to do.
  ##
  ## A DISABLED breakpoint does NOT beat an armed one on the same line, because
  ## a line carrying both is a line that stops.
  ##
  ## **THE FULL RANKING IS armed breakpoint > TRACEPOINT > disabled breakpoint**,
  ## and the headline above does not say where a tracepoint sits relative to a
  ## disabled breakpoint — which is exactly the case the two media disagree on.
  ## Measured 2026-09-16: a line carrying a TRACEPOINT and a DISABLED breakpoint
  ## renders `○` in the terminal (`app/source_binding.marksForFile` emits
  ## tracepoints first and then breakpoints of either kind, and
  ## `views/source_pane.markFor` takes the LAST) and `emTracepoint` here.
  ## Neither answer is obviously wrong — a disabled breakpoint does nothing, a
  ## tracepoint records — and **nothing in this repository asserts that the two
  ## agree, because today they do not.** The remedy is one cross-front-end case
  ## driving ONE `seq[EditorPoint]` through both media and requiring the same
  ## mark, and it needs the `tui` lane, which cannot be compiled where this was
  ## written. Until then this module is the second implementation it was
  ## written to prevent, which is worth saying in the header rather than only
  ## in a milestone.
  result = emNone
  var sawTracepoint = false
  var sawDisabled = false
  for p in points:
    if p.path != path or p.line != line or line <= 0:
      continue
    case p.kind
    of epkBreakpoint:
      if p.enabled:
        return emBreakpoint
      sawDisabled = true
    of epkTracepoint:
      sawTracepoint = true
  result =
    if sawTracepoint: emTracepoint
    elif sawDisabled: emBreakpointDisabled
    else: emNone

func pointerFor*(line, executionLine, inspectionLine: int): EditorPointer =
  ## Which cursor, if either, is on this line.
  ##
  ## `executionLine <= 0` means the debugger is NOT stopped in the file on
  ## screen — the binding sets it to zero when an outer frame in another file is
  ## inspected — and drawing an execution pointer then would be a pane claiming
  ## the program is somewhere it has never been.
  if line <= 0: eptNone
  elif executionLine > 0 and line == executionLine: eptExecution
  elif inspectionLine > 0 and line == inspectionLine: eptInspection
  else: eptNone

func supportOf*(table: EditorConcernSupport;
                c: EditorConcern): EditorSupport =
  ## One lookup function, so the table and every assertion over it ask the same
  ## question. §14 applied to a three-line accessor, because the alternative —
  ## call sites indexing the array themselves — is how a fifth concern gets read
  ## out of a table that does not have it.
  table[c]

func renderedConcerns*(table: EditorConcernSupport): set[EditorConcern] =
  ## Exactly the concerns a medium DRAWS. Derived rather than declared twice.
  for c in EditorConcern:
    if table[c] == esRendered:
      result.incl c
