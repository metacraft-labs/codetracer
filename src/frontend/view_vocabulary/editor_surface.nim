## frontend/view_vocabulary/editor_surface.nim — PLAT-22. **The ONE place that
## turns the shared ViewModels into `EditorRow`s.**
##
## ## WHAT PLAT-22 ASKS FOR, AND THE PART OF IT THAT CANNOT BE SATISFIED
##
## Deliverable 3 is *"whichever is chosen, wired to the same ViewModels the
## terminal and web editors use"*. Taken literally that is not reachable, and
## the reason is a measurement rather than an opinion (2026-09-16):
##
##   * the TERMINAL editor is wired to the shared ViewModels — `SourceVM` for
##     the text and the execution line, `EditorVM` for the §14 degradation and
##     the overlay toggles, `StateVM` for the inline values;
##   * the WEB editor is wired to almost none of them. It delegates text to
##     Monaco and reads the legacy Karax `data.services.debugger` for the
##     position and `DebuggerService.breakpointTable` for the marks.
##     `ui/editor.nim` CONSTRUCTS an `EditorVM` and its own header says
##     *"the EditorVM receives the same data but does not affect rendering
##     yet"*; the only fields of it anything on that side reads are three
##     `data-*` attributes in `isonim_editor_view.nim`. `SourceVM` has exactly
##     one production caller in the repository and it is `tui/host/tui_session.nim`.
##
## So there is no set of ViewModels that BOTH existing editors use, and a
## milestone claiming a third front-end joined them would be claiming something
## about the web that is not true. What this module does instead, said exactly:
## **it is wired to the shared ViewModels the TERMINAL editor uses, and the
## terminal's own derivation is rewritten to call it**, so the two are one
## function rather than two that agree. The web is the outstanding half and is
## named as such in PLAT-22's status rather than rounded up.
##
## ## WHY THE DERIVATION IS HERE AND NOT IN THE GPUI FRONT-END
##
## Verification-Harness-Traps §14. `tui/app/source_binding.nim` already held
## this logic and `ui/trace.editorLineNumber` held a second spelling of half of
## it; a third written in `gpui/app/` would be the third copy, and §14's own
## evidence is that the copy nobody mutates is the one that stays wrong. This
## module is the extraction and `editor_rows.nim` holds the pure rules both
## media call. §14b: *"grade a shared predicate from BOTH consumers"* — the
## terminal's suites and the GPUI suites both go red when a rule here moves, and
## that is what makes either of them evidence about the other.
##
## ## IT READS PRODUCERS, NOT PARAMETERS, WHEREVER A PRODUCER EXISTS
##
## The terminal's binding takes `points`, `variables` and `heat` as PARAMETERS
## with defaults, and its production caller passes none of them — measured
## 2026-09-16 at `tui/host/tui_session.nim`, where `sourcePaneModelFor(s.source,
## availability)` leaves all three defaulted. The consequence is that the
## terminal's inline annotations and gutter marks are exercised thoroughly by
## suites and drawn by the shipped binary never, which is the defect this
## campaign has now recorded five times under the name *"has no production
## caller"*.
##
## So this module takes the `StateVM` and the `FlowVM` themselves and reads
## them, rather than taking what somebody read out of them. A nil ViewModel is
## a real state — a session in `dspCreated` has them all nil — and produces an
## empty list, which is different from a caller that forgot.
##
## The one thing still taken as a parameter is `points`, and it is taken as one
## BECAUSE there is no producer: `PointListVM.points` is filled by nothing
## (`editor_rows.FiledEditorGaps[pgMarksHaveNoProducer]` carries the
## measurement). Reading an empty signal would have looked wired; taking a
## parameter says the caller owes it.
##
## ## NO MOCKS
##
## Nothing here constructs a ViewModel, a store or a backend. It reads the ones
## a real session built.

import std/strutils

import codetracer_embed

# `ProductMode` and `sourceContractFor` are re-exported by NAME rather than by
# re-exporting the whole facade. PLAT-16 put the answer to "which source does a
# mode show" in the core precisely so every front-end reads one answer, and a
# front-end that had to import the SDK facade to learn the name of a product
# mode would have a reason to spell it itself instead.
import viewmodels/product_mode
export product_mode

# PLAT-28's trailing-line policy and the one function that applies it, by the
# same bare-module spelling `viewmodels/product_mode` above uses. The enum is
# re-exported because it appears in this module's published signature: a caller
# choosing `tlpKeep` over `tlpDropFinalEmpty` is making PLAT-28's decision, and
# a decision a caller cannot spell is one it cannot make.
import editor/row_projection
export row_projection.TrailingLinePolicy

import ../../common/view_vocabulary
import ../../common/value_presentation

export editor_rows

type
  EditorSurface* = object
    ## **The whole of what a native source editor draws, as a value.**
    ##
    ## A PLAIN OBJECT for `tui/app/views/source_pane.SourcePaneModel`'s three
    ## reasons, which are not terminal-specific: the surface can be asserted
    ## without a debugger, two frames are two comparable values, and the memory
    ## ceiling is a property of a field a reader can see — `rows` is the
    ## viewport, never the file.
    medium*: string
      ## Which front-end this was built for. NON-EMPTY ALWAYS, and it is the
      ## same string `vocabulary.nativeEscape` is given, so an escape naming one
      ## front-end and a surface built for another is a comparison a case can
      ## make. PLAT-21's verification planted exactly that mutation
      ## (`nativeMedium` hardcoded to `"terminal"` while the `PaneView` said
      ## `"gpui"`) and nothing in the tree could tell.
    path*: string
    revisionLabel*: string
      ## `@<generation>`, plus `#<digest>` when a recorder emits one. Empty for
      ## generation 0 with no digest, which is every recording this workspace
      ## produces today — so the label appears exactly when there is something
      ## to disambiguate.
    provenance*: EditorProvenance
    viewportTop*: int
    totalLineCount*: int
    executionLine*: int
    inspectionLine*: int
    flowOverlayVisible*: bool
    gutterVisible*: bool
    rows*: seq[EditorRow]
    degradedMessage*: string
    productMode*: ProductMode
      ## **Which PRODUCT mode this surface was built for, and it is orthogonal
      ## to the front-end.** PLAT-16 established `ProductMode` as a dimension
      ## separate from `UiMode`, with the answer to *"which source does a mode
      ## show"* in the CORE — *"this is a core question, not a terminal one, and
      ## the answer applies to every front-end"*. PLAT-22's deliverable is the
      ## same sentence from the GPUI side: edit mode is a product mode, so
      ## reaching it is not a front-end feature.
    sourceStatement*: string
      ## What the pane must SAY it is showing, read from
      ## `product_mode.sourceContractFor(mode).statement` rather than spelled
      ## here. §2's Requirement is that the pane states which mode's source it
      ## is showing **always**, *"not only when they differ, because 'only when
      ## it matters' requires the user to know when it matters"* — so a surface
      ## always carries it and a medium always draws it.
    mutable*: bool
      ## Whether this front-end will let the user CHANGE the text. Read from
      ## the contract AND narrowed by what the medium can do; see
      ## `editorSurfaceForProject`.
    report*: string
      ## Non-empty when **there is nothing to draw** — no session, no project,
      ## an unopenable root. PLAT-9's rule: a pane reports, it never renders
      ## blank.
    notice*: string
      ## Non-empty when there IS something to draw and the front-end has
      ## something to say about it — today, that EDIT mode reached a medium
      ## with no text buffer.
      ##
      ## **A SECOND FIELD AND NOT A SECOND MEANING FOR `report`**, which is
      ## Verification-Harness-Traps §5a caught inside this milestone's own
      ## diff. `report` already meant "draw this INSTEAD of rows", every reader
      ## acted on it that way, and giving it the read-only notice made
      ## `renderEditor` draw a sentence and no source — measured, as a red case
      ## in `test_gpui_editing_surface.nim` on the first run: *"an escape naming
      ## another front-end is refused"* failed on the POSITIVE half, because
      ## the surface it was handed had a notice and therefore rendered nothing.
      ## §5a's rule is that the remedy is to split the value rather than to
      ## surface it, and the two differ in exactly the way that matters: one
      ## replaces the content, the other accompanies it.
    support*: EditorConcernSupport
      ## **What this surface actually did with each of PLAT-22's four
      ## concerns**, filled from the run rather than declared. The gate compares
      ## it with `editor_rows.concernsWithFiledGap()` in both directions, so
      ## neither an unfiled degradation nor a filed gap nothing degrades for can
      ## pass — PLAT-21's escape census, pointed at the overlays.

const
  NoSessionReport* = "the source pane has no ViewModel; the session has not " &
                     "launched"

func revisionLabelOf*(rev: SourceRevision): string =
  ## `@<generation>[#<digest>]`, or "" when there is nothing to disambiguate.
  ##
  ## Lifted verbatim from `tui/app/source_binding.revisionLabel`, which now
  ## calls this. It takes the REVISION rather than the `SourceVM` so it is a
  ## pure function a case can drive with no reactive root.
  if rev.sourceGeneration == 0 and rev.sourceDigest.len == 0:
    return ""
  result = "@" & $rev.sourceGeneration
  if rev.sourceDigest.len > 0:
    result.add "#" & rev.sourceDigest

func provenanceOf*(availability: SourceAvailability): EditorProvenance =
  ## Page-Descriptions.md §14's source axis, as the editor's three-way
  ## distinction.
  ##
  ## `savUnverified` covers both "read off a machine rather than out of the
  ## recording" and "the requested revision is not the one I have". Both are
  ## text an editor may render and must not certify, which is exactly one
  ## visual treatment.
  case availability
  of savVerified: epVerified
  of savUnverified: epUnverified
  of savAbsent: epAbsent

func degradedMessageFor*(state: PaneDegradation): string =
  ## §14's row, as the one line an editor prints.
  ##
  ## Only `pdNoVerifiedSource` produces text. The other degradations are other
  ## panes' — a source pane printing "no calltrace" would be reinventing §14's
  ## canonical treatment, which is the thing §14 exists to prevent.
  if state == pdNoVerifiedSource:
    "No verified source for this revision — showing what is available."
  else:
    ""

func editorPointsOf*(rows: openArray[PointListEntry]): seq[EditorPoint] =
  ## The store's point rows as the editor's points — the GPUI arm of the
  ## conversion `tui/app/source_binding.sourcePointsOf` is on the terminal:
  ## breakpoints and tracepoints by `store/types`' one spelling of each kind,
  ## rows without a line skipped.
  for r in rows:
    if r.line < 1: continue
    if r.kind == PointKindBreakpoint:
      result.add EditorPoint(path: r.path, line: r.line, kind: epkBreakpoint,
                             enabled: r.enabled)
    elif r.kind == PointKindTracepoint:
      result.add EditorPoint(path: r.path, line: r.line, kind: epkTracepoint,
                             enabled: r.enabled)

proc inlineValuesOf*(vm: StateVM; budget: Budget): seq[EditorValue] =
  ## The values in scope at THIS tick, rendered through PLAT-2's pipeline.
  ##
  ## **THE BUDGET IS THE CALLER'S AND THE RENDERING IS THE PRESENTER'S**, which
  ## is PLAT-2's boundary: there is no `[0 ..< n]`, no `&"…"` and no width in
  ## this file. `surfaces.gpuiRowBudget()` is what the GPUI editor passes and
  ## `surfaces.tuiRowBudget(cells, focused)` is what the terminal's rows pass —
  ## an inline value beside a line is ONE ROW's worth of value, which is what
  ## those two budgets are for and, until this function existed, what
  ## `gpuiRowBudget` had no caller for.
  ##
  ## A variable with no rendered value is DROPPED rather than shown as `x: `.
  ## An empty value says the debugger reported nothing for `x`, which is not
  ## what it means: it means the formatter had nothing to print, and silence is
  ## the honest rendering of that.
  ##
  ## NOTHING IS CACHED, ANYWHERE, and that is the contract rather than an
  ## omission. A stale inline value is worse than none because it is
  ## indistinguishable from a correct one — `x: 42` beside a line where `x` is
  ## now 7 reads exactly like the truth — so this is a pure function of the
  ## current tick and there is nowhere for a previous tick's answer to live.
  result = @[]
  if vm.isNil:
    return
  for v in vm.currentVariables.val:
    if v.name.len == 0:
      continue
    let rendered =
      if v.presented.isNil: v.value.strip()
      else: presentText(v.presented, budget).strip()
    if rendered.len == 0:
      continue
    result.add EditorValue(name: v.name, value: rendered)

func flowStateOf*(facts: openArray[FlowStyledLine]; line: int): EditorFlowState =
  ## What the flow says about one line.
  ##
  ## `facts` is `FlowVM.styledLines` — the shared dimming rule
  ## (`ui/flow_line_styles.flowStyledLines`) applied to the window the backend
  ## sent, plus the arm headers whose test was evaluated. This function only
  ## TRANSLATES; it decides nothing, so the desktop editor, the terminal and
  ## GPUI cannot disagree about which line ran (Verification-Harness-Traps
  ## §30: one predicate, every caller).
  ##
  ##   * `flskHit`  → `efsTaken`    — the line ran in this window;
  ##   * `flskSkip` → `efsNotTaken` — it sits inside an arm the run declined;
  ##   * no entry   → `efsUnknown`  — nothing is claimed. NOT `efsNotTaken`:
  ##     "the window has no step for this line" is a fact about the window, and
  ##     rendering it as "this line did not run" is the defect
  ##     `flowStyledLines`' own header records.
  ##
  ## Until 2026-09-23 this read the focused loop's EXTENT and answered
  ## `efsTaken` for every line inside it, because the per-line facts were
  ## discarded by `FlowVM.applyFlowUpdate` (filed as `PLAT22-PG2`). That was
  ## the strongest fact available then, and it said "in the focused loop"
  ## under a name that means "ran".
  if line <= 0:
    return efsUnknown
  for f in facts:
    if f.position == line:
      case f.kind
      of flskHit: return efsTaken
      of flskSkip: return efsNotTaken
      of flskUnknown: return efsUnknown
  efsUnknown

func notTakenLinesOf*(facts: openArray[FlowStyledLine]): seq[int] =
  ## The lines `flowStateOf` answers `efsNotTaken` for — what a medium that
  ## draws only the dimming (the terminal) needs. Derived THROUGH `flowStateOf`
  ## rather than by filtering on `flskSkip`, so the translation exists once.
  result = @[]
  for f in facts:
    if flowStateOf(facts, f.position) == efsNotTaken and
       (result.len == 0 or result[^1] != f.position):
      result.add f.position

const FlowOverlayShownByDefault* = true
  ## Whether a native host opens with the flow overlay drawn.
  ##
  ## The desktop front-end draws it whenever `flow.enabled` is set, and
  ## `src/config/default_config.yaml` ships `flow.enabled: true`. The native
  ## hosts do not read that file (`frontend/config.nim` is renderer-only), so
  ## the shipped default is carried here and `test_flow_line_facts.nim` reads
  ## the YAML and fails if the two disagree. `EditorVM.showFlowOverlay` itself
  ## still starts `false` — that is the ViewModel's neutral state, and the host
  ## is what knows the product default.

type
  RowFacts = object
    ## What one row says beyond its text: the four vocabulary fields a
    ## producer decided. `projectedRows` encodes them as decorations and the
    ## projection decodes them, so a row's fields reach the medium through
    ## PLAT-28's model and through nothing else.
    mark: EditorMark
    pointer: EditorPointer
    flow: EditorFlowState
    values: seq[EditorValue]

proc projectedRows(doc: string; firstLine: int; trailing: TrailingLinePolicy;
                   viewportTop, viewportHeight: int; requested: seq[int];
                   factsOf: proc (line: int; text: string;
                                  held: bool): RowFacts {.closure.}):
                   seq[EditorRow] =
  ## **EVERY `EditorRow` THIS MODULE RETURNS IS BUILT HERE, AS A PROJECTION**
  ## (PLAT-28, Editor-ViewModel.md §8.4). The producers' per-line answers
  ## become a `DecorationSet` over `doc` — line decorations for the mark, the
  ## pointer and the flow state, inline widgets for the values — and the rows
  ## are `row_projection.editorRowsOf` of that set. Until 2026-09-23 both
  ## surfaces assembled `EditorRow`s field by field beside a projection that
  ## could have produced them, which is the parallel structure §8.4 names.
  ##
  ## `factsOf` is asked only for the lines the viewport shows, so a 40,000-line
  ## file costs a viewport's worth of decisions, as the direct loop did.
  let ls = projectionLinesFor(doc, trailing)
  let starts = projectionLineStarts(doc)
  let base = max(1, firstLine)
  let lastLine = if viewportHeight <= 0: high(int)
                 else: viewportTop + viewportHeight - 1
  var ds: seq[Decoration] = @[]
  var nextId = 0
  for idx in 0 ..< ls.len:
    let line = base + idx
    if line < viewportTop: continue
    if line > lastLine: break
    let held = line notin requested
    let f = factsOf(line, if held: ls[idx] else: "", held)
    for d in decorationsForRow(f.mark, f.pointer, f.flow, f.values,
                               starts[idx], ls[idx].len, nextId):
      ds.add d
      inc nextId
  editorRowsOf(RowProjection(doc: doc, decorations: decorationSet(ds),
                             firstLine: base, viewportTop: viewportTop,
                             viewportHeight: viewportHeight,
                             trailing: trailing, requested: requested))

proc editorSurfaceFor*(source: SourceVM; editor: EditorVM; state: StateVM;
                       flow: FlowVM; availability: SourceAvailability;
                       budget: Budget; medium: string;
                       points: openArray[EditorPoint] = [];
                       inspectionLine = 0): EditorSurface =
  ## **The editor's surface for the CURRENT frame, on any medium.**
  ##
  ## Everything is read at call time and nothing is retained, so two frames are
  ## two values and the difference between them is exactly the difference on
  ## screen.
  ##
  ## `source.executionLine` AND NOT `editor.cursorLine`, and the difference was
  ## measured rather than assumed: nothing in the ViewModel layer writes
  ## `cursorLine` from the debugger position, so an editor that followed the
  ## caret sat on line 1 for a whole session while the pointer walked off the
  ## bottom. The caret and the execution pointer are different questions and
  ## this asks the second.
  result.medium = medium
  result.productMode = pmDebug
  result.sourceStatement = sourceContractFor(pmDebug).statement
  result.mutable = sourceContractFor(pmDebug).mutable
  result.support = [ecExecutionPointer: esRendered,
                    ecLineStatus: esRendered,
                    ecInlineValues: esRendered,
                    ecFlowOverlay: esRendered]
  if source.isNil:
    result.report = NoSessionReport
    result.rows = @[]
    # A surface with no session renders nothing, so it DEGRADES every concern
    # rather than claiming three of them. Overwriting the table here rather
    # than leaving the launched-session answer standing is the difference
    # between "this medium cannot do it" and "there is nothing to do it to".
    for c in EditorConcern:
      result.support[c] = esDegraded
    return
  let rev = source.revision.val
  result.path = source.path.val
  result.revisionLabel = revisionLabelOf(rev)
  result.provenance = provenanceOf(availability)
  result.viewportTop = source.visibleFirstLine.val
  result.totalLineCount = source.totalLineCount.val
  result.executionLine = source.executionLine.val
  result.inspectionLine = inspectionLine
  result.flowOverlayVisible =
    if editor.isNil: false else: editor.showFlowOverlay.val
  result.gutterVisible =
    if editor.isNil: true else: editor.showBreakpointGutter.val
  result.degradedMessage =
    if availability == savAbsent and not editor.isNil:
      degradedMessageFor(editor.degradedState.val)
    else: ""

  # `points` has no producer, so a surface handed none degrades the concern
  # rather than reporting a clean gutter. The alternative — leaving
  # `esRendered` because the MECHANISM works — is the claim
  # `FiledEditorGaps[pgMarksHaveNoProducer]` exists to stop being made.
  if points.len == 0:
    result.support[ecLineStatus] = esDegraded

  let values = inlineValuesOf(state, budget)
  if values.len == 0 and not state.isNil and
     state.currentVariables.val.len == 0:
    # Nothing in scope is a real answer and is NOT a degradation: the clearing
    # case is the one CTUI-5 asks to be asserted explicitly, and reporting it
    # as a gap would make "the debugger is at an `import` line" look like a
    # defect. The table only moves when the PRODUCER is missing, and `StateVM`
    # is present.
    discard
  # A window with no facts is an answer, not a degradation — the same reading
  # as "nothing in scope" above: every row is `efsUnknown`, which claims
  # nothing. The concern degrades only when there is no `FlowVM` at all.
  let flowFacts = if flow.isNil: @[] else: flow.styledLines.val
  if flow.isNil:
    result.support[ecFlowOverlay] = esDegraded

  # THE WINDOW AS A DOCUMENT. `visibleReads` is one read per line of a
  # contiguous run, so the window's text joined by `'\n'` is a document whose
  # first line is `visibleFirstLine`; a line still in flight contributes an
  # empty line and is named in `requested`, so its row is `held = false`.
  let reads = source.visibleReads()
  result.rows = @[]
  if reads.len == 0:
    return
  var windowLines: seq[string] = @[]
  var requested: seq[int] = @[]
  for read in reads:
    case read.kind
    of srkHeld: windowLines.add read.text
    of srkRequest:
      windowLines.add ""
      requested.add read.line
  let executionLine = result.executionLine
  let inspection = result.inspectionLine
  let path = result.path
  let flowVisible = result.flowOverlayVisible
  let pts = @points
  result.rows = projectedRows(windowLines.join("\n"), reads[0].line, tlpKeep,
                              reads[0].line, 0, requested,
    proc (line: int; text: string; held: bool): RowFacts =
      result.pointer = pointerFor(line, executionLine, inspection)
      result.mark = markFor(pts, path, line)
      # INLINE VALUES ON THE EXECUTION LINE ONLY, which is the terminal's rule
      # carried across rather than re-decided. The values the ViewModel
      # reports are the values in scope AT THE STOP; attaching them to every
      # line that mentions the name would put the value of `x` at the stop
      # beside a line thirty above it that has not run yet, which is a stale
      # value with extra steps.
      if held and result.pointer == eptExecution:
        result.values = valuesForLine(text, values)
      result.flow = if flowVisible: flowStateOf(flowFacts, line)
                    else: efsUnknown)

proc followAndRequest*(vm: SourceVM): seq[SourceLineRequest] =
  ## Scroll to the execution pointer and report what the window then lacks.
  ##
  ## **THE TWO CALLS BELONG TOGETHER AND IN THIS ORDER**, which is why they are
  ## one function: `followExecutionPointer` moves the window, `requestMissing`
  ## trims the held range to the NEW window and then asks for the gap. Reversed,
  ## the trim runs against the OLD window and the editor asks for lines it is
  ## about to scroll away from.
  ##
  ## MOVED HERE FROM `tui/app/source_binding.nim` by PLAT-22, which now calls
  ## it, because a second host needed it and copying a two-line function whose
  ## whole content is an ORDERING is how the ordering gets reversed in one of
  ## the two copies (§14). It was never a terminal concern.
  vm.followExecutionPointer()
  vm.requestMissing()

proc editorSurfaceForDocument*(d: EditingDocument; medium: string;
                               mutableHere: bool;
                               viewportTop = 1; viewportHeight = 0;
                               points: openArray[EditorPoint] = [];
                               trailing = tlpKeep;
                               showCaret = true): EditorSurface =
  ## **THE EDIT-MODE SURFACE, DERIVED FROM THE EDITING CORE (PLAT-34).**
  ##
  ## This is the function that makes "one editing core, two front-ends" a
  ## thing a source scan can check rather than a claim. Its input is an
  ## `EditingDocument` — the model — and every field below is read off it.
  ## Nothing here reads a file, splits a string it was handed, or takes a
  ## front-end's word for how long the document is.
  ##
  ## **THE TERMINAL DOES NOT CALL THIS ONE**, and that is deliberate rather
  ## than an omission. `tui/app/views/edit_pane.EditPaneModel` predates the
  ## shared row model by two milestones, carries a gutter mode, a syntax
  ## highlighter and a fold column that `EditorRow` has no fields for, and is
  ## graded by four suites in a lane this file's other callers do not run in.
  ## Collapsing the two row models is real work with its own risk and it is
  ## not PLAT-34's; what PLAT-34 owns is that both derivations read ONE
  ## buffer, which they now do. The residual is named in the milestone rather
  ## than rounded up into "both front-ends share a row model".
  ##
  ## `product_mode.sourceContractFor(pmEdit)` is read rather than re-decided,
  ## and it says three things this function obeys: the origin is the working
  ## tree, the text is `mutable`, and `windowed` is FALSE — §2.1's *"Edit mode
  ## does not use `SourceVM`"*.
  ##
  ## **`mutableHere` IS THE MEDIUM'S ANSWER AND THE CONTRACT'S IS NOT
  ## OVERRIDDEN — IT IS REPORTED AGAINST.** See the note on `notice`. A
  ## front-end that cannot yet mutate must not answer `mutable = true` (it
  ## would be claiming a capability) and must not quietly rewrite the
  ## contract to `false` (the contract is the core's).
  let contract = sourceContractFor(pmEdit)
  result.medium = medium
  result.productMode = pmEdit
  result.sourceStatement = contract.statement
  result.mutable = contract.mutable and mutableHere
  result.path = d.path
  result.revisionLabel = ""
  # THE WORKING TREE IS `epUnverified` BY CONSTRUCTION, and that is not a
  # degradation — it is the truth about which copy this is. CTUI-5's rule is
  # that a working-tree read must not look identical to the recording's own
  # copy, and edit mode shows the working tree ALWAYS.
  result.provenance = epUnverified
  result.executionLine = 0
  # **`showCaret` IS A SECOND PARAMETER AND NOT A SECOND MEANING FOR
  # `trailing`** (§5a). Both answer "is this a BUFFER or a FILE", and they
  # answer it about different things — how many rows there are, and whether
  # one of them carries a cursor — so a caller that wanted one and got the
  # other would have no way to say so. `editorSurfaceForProject` is handed a
  # string and passes `false`: the caret in the document that wrapper opens is
  # an artefact of the delegation, not a fact about the bytes, and PLAT-28's
  # `EditorRow.pointer x edit-mode` cases are what said so.
  #
  # **THE CARET IS THE INSPECTION CURSOR, AND IT IS WHY THIS SURFACE
  # RE-RENDERS.** PLAT-34's gate is that a change in the model changes what
  # BOTH front-ends draw, read from a run. A read-only medium draws no
  # keystroke, so without this the GPUI shadow tree would only move when the
  # TEXT moved — and every motion in the 224-operation vocabulary would be
  # invisible to it. `EditorPointer` already distinguishes the debugger's stop
  # from an inspection cursor (CTUI-6's contract), and a caret in a buffer
  # nobody is stopped in is exactly the second one.
  result.inspectionLine = if showCaret: d.caretLine else: 0
  result.flowOverlayVisible = false
  result.gutterVisible = true
  # Three of the four concerns belong to a RECORDING and edit mode has none.
  # `esAbsent` and not `esDegraded`: a degradation is a thing the medium could
  # not draw, and there is nothing here to draw — the debugger is not running.
  result.support = [ecExecutionPointer: esAbsent,
                    ecLineStatus: esRendered,
                    ecInlineValues: esAbsent,
                    ecFlowOverlay: esAbsent]
  if points.len == 0:
    result.support[ecLineStatus] = esDegraded
  if contract.mutable and not mutableHere:
    result.notice = "this is " & contract.statement & ", read-only: the '" &
      medium & "' front-end has no text buffer yet, so EDIT mode reaches it " &
      "and cannot change it"
  result.rows = @[]
  # **THE TRAILING-LINE POLICY IS PLAT-28's, APPLIED BY PLAT-28's FUNCTION.**
  #
  # `row_projection.projectionLinesFor` is the one place `TrailingLinePolicy`
  # is applied; this function carried its own `splitLines`-and-drop until
  # PLAT-34, which was a third spelling of a decision that enum exists to make
  # once — and PLAT-28's case "THE TRAILING-LINE POLICY IS A NAMED DECISION
  # AND BOTH ARMS ARE REACHED" is what said so, by name, on the first
  # floor-gate run of the milestone that added the third.
  #
  # **THE DEFAULT IS `tlpKeep` AND `editorSurfaceForProject` OVERRIDES IT**,
  # which is the whole of the distinction PLAT-28's two arms encode: this
  # entry point is handed a BUFFER, whose caret can reach the empty final
  # line, and that one is handed a FILE, whose length is the number a user
  # counts. Neither answer moved; which question each is asked is now said out
  # loud.
  let ls = projectionLinesFor(d.text, trailing)
  # **`result.inspectionLine` AND NOT `d.caretLine`, AND THE DIFFERENCE IS
  # §30 IN EIGHT WORDS.** The first spelling of this loop read the document
  # a second time, so the surface's own `inspectionLine` field and the
  # pointer its rows carry were two answers to one question — and PLAT-34's
  # arm `M3`, which blanks the field, SURVIVED: the field moved and the rows
  # did not, because nothing downstream read the field. One value, one
  # reader, and the arm lands.
  #
  # The rows themselves are `projectedRows`' — PLAT-28's projection — with
  # the pointer and the mark as the two line decorations edit mode has.
  let executionLine = result.executionLine
  let inspection = result.inspectionLine
  let path = d.path
  let pts = @points
  result.rows = projectedRows(d.text, 1, trailing, viewportTop,
                              viewportHeight, @[],
    proc (line: int; text: string; held: bool): RowFacts =
      RowFacts(pointer: pointerFor(line, executionLine, inspection),
               mark: markFor(pts, path, line), flow: efsUnknown))
  result.totalLineCount = ls.len
  result.viewportTop = viewportTop

proc editorSurfaceForProject*(path, text: string; medium: string;
                              mutableHere: bool;
                              viewportTop = 1; viewportHeight = 0;
                              points: openArray[EditorPoint] = []):
                              EditorSurface =
  ## **The EDIT-mode surface over raw TEXT — one line, and it opens a
  ## document.**
  ##
  ## Kept as the entry point a caller that has bytes rather than a model comes
  ## through, and it is now a wrapper: open the document, derive the surface,
  ## with the two parameters that say a string is a FILE — its length is the
  ## number a user counts, and it has no cursor.
  ##
  ## ## THIS CLOSES `PLAT28-DG3`, AND PLAT-28 ASKED FOR THE DECISION FIRST
  ##
  ## Until PLAT-34 this function split its text with `strutils.splitLines`,
  ## which breaks on a LONE CR and on CRLF, while `text_store`, `wrap` and
  ## `row_projection` split on `'\n'` only — they must agree or `LAW-C4`'s
  ## partition is false. PLAT-28 measured the divergence (three rows against
  ## two on `"one\r\ntwo\rthree\n"`), filed it as `PLAT28-DG3`, and said
  ## exactly why it did not fix it: *"rewiring would change edit-mode line
  ## counting in production for every file containing a CR"*, with the remedy
  ## *"decide what a line terminator is for EDIT mode, and move whichever side
  ## is wrong."*
  ##
  ## **THE DECISION IS TAKEN AND THE SURFACE IS THE SIDE THAT MOVED.** A lone
  ## CR is not a line terminator in this editor, because the buffer's
  ## coordinate model says it is not: the caret cannot be placed on a row the
  ## store does not have, and a surface that drew more rows than the buffer
  ## has positions is the same defect as one that drew fewer. It is recorded
  ## in `Architecture/Editor-ViewModel.md` §3.2 rather than in a GUI spec,
  ## because *what a line is* is a contract question that document owns and
  ## every medium inherits; PLAT-28's remedy said "a GUI spec" and the
  ## departure is named rather than taken quietly.
  ##
  ## `product_mode.sourceContractFor(pmEdit)` is read rather than re-decided,
  ## and it says three things this function obeys: the origin is the working
  ## tree, the text is `mutable`, and `windowed` is FALSE — §2.1's *"Edit mode
  ## does not use `SourceVM`"*. That last one is why this is a second
  ## constructor rather than a flag on the first: a virtualised, revision-
  ## identified, read-only window over a recording's payload is the wrong model
  ## for a buffer the user is typing into, and expressing one through the other
  ## would be the collapse §2's table exists to prevent.
  ##
  ## **`mutableHere` IS THE MEDIUM'S ANSWER AND THE CONTRACT'S IS NOT OVERRIDDEN
  ## — IT IS REPORTED AGAINST.** The contract says edit mode is mutable. A
  ## front-end that cannot yet mutate must not answer `mutable = true` (it would
  ## be claiming a capability) and must not quietly rewrite the contract to
  ## `false` (the contract is the core's, and a front-end editing it is exactly
  ## the two-dimensions-into-one collapse PLAT-16 is written against). So the
  ## contract's answer decides `productMode` and `sourceStatement`, the medium's
  ## answer decides `mutable`, and when they DISAGREE the surface carries a
  ## report saying so by name. PLAT-9's rule: degrade out loud.
  editorSurfaceForDocument(initEditingDocument(path, text), medium,
                           mutableHere, viewportTop, viewportHeight, points,
                           trailing = tlpDropFinalEmpty, showCaret = false)

proc reportedConcerns*(s: EditorSurface): set[EditorConcern] =
  ## The concerns this surface DEGRADED, read back out of the value.
  ##
  ## Read from the surface rather than recomputed, so the gate compares the run
  ## with the register instead of comparing the register with itself (§4a).
  for c in EditorConcern:
    if s.support[c] != esRendered:
      result.incl c

func materializedLines*(s: EditorSurface): int =
  ## Rows whose text came out of the held window. A surface that reached for a
  ## whole file would have to do it through a field that is not there, and this
  ## is the number a virtualization case asserts.
  for r in s.rows:
    if r.held: inc result

func rowAt*(s: EditorSurface; line: int): EditorRow =
  ## The row for `line`, or a row with `line == 0` when the surface does not
  ## cover it.
  ##
  ## A NIL-SAFE ACCESSOR rather than an index, for Verification-Harness-Traps
  ## §1a's reason: a case that indexes a seq a mutation can empty takes the
  ## test binary down, `unittest` prints no verdict line for it, and the
  ## harness folds that into `SURVIVED` — the most expensive mislabel
  ## available, because it reads as a gap in the suite when it is a gap in the
  ## harness's evidence.
  for r in s.rows:
    if r.line == line:
      return r
  EditorRow(line: 0)
