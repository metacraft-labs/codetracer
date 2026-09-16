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

func flowStateOf*(loops: openArray[FlowLoopInfo]; focused: int;
                  line: int): EditorFlowState =
  ## What the flow can say about one line, and NOT MORE THAN IT CAN.
  ##
  ## `efsTaken` here means *"this line is inside the loop whose control is on
  ## screen"*, which is the strongest per-line fact `FlowVM` carries:
  ## `FlowLoopInfo` has `first` and `last` source lines, and `FlowStepEntry` has
  ## no line number at all. It deliberately does NOT mean "this line ran in the
  ## selected iteration" — the web front-end's `flow-taken` / `flow-not-taken`
  ## classes mean that, and they are computed from a payload `FlowVM` does not
  ## expose (`editor_rows.FiledEditorGaps[pgFlowHasNoPerLineFact]`).
  ##
  ## So this function answers two of the three values and never the third, and
  ## `efsNotTaken` is returned for a line inside the focused loop's REGISTERED
  ## line but outside its body — the one negative the extent can justify. A
  ## medium rendering this must say "in the focused loop" and must not say "this
  ## line ran", which is the distinction a degradation exists to keep.
  if line <= 0 or focused < 0 or focused >= loops.len:
    return efsUnknown
  let loop = loops[focused]
  if loop.first <= 0 or loop.last < loop.first:
    return efsUnknown
  if line >= loop.first and line <= loop.last:
    efsTaken
  elif loop.registeredLine > 0 and line == loop.registeredLine:
    efsNotTaken
  else:
    efsUnknown

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
                    ecFlowOverlay: esDegraded]
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
  let loops = if flow.isNil: @[] else: flow.loops.val
  let focused = if flow.isNil: -1 else: flow.focusedLoop.val

  result.rows = @[]
  for read in source.visibleReads():
    var row = EditorRow(line: read.line, flow: efsUnknown)
    case read.kind
    of srkHeld:
      row.held = true
      row.text = read.text
    of srkRequest:
      row.held = false
      row.text = ""
    row.pointer = pointerFor(read.line, result.executionLine,
                             result.inspectionLine)
    row.mark = markFor(points, result.path, read.line)
    # INLINE VALUES ON THE EXECUTION LINE ONLY, which is the terminal's rule
    # carried across rather than re-decided. The values the ViewModel reports
    # are the values in scope AT THE STOP; attaching them to every line that
    # mentions the name would put the value of `x` at the stop beside a line
    # thirty above it that has not run yet, which is a stale value with extra
    # steps.
    if row.held and row.pointer == eptExecution:
      row.values = valuesForLine(row.text, values)
    if result.flowOverlayVisible:
      row.flow = flowStateOf(loops, focused, read.line)
    result.rows.add row

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

proc editorSurfaceForProject*(path, text: string; medium: string;
                              mutableHere: bool;
                              viewportTop = 1; viewportHeight = 0;
                              points: openArray[EditorPoint] = []):
                              EditorSurface =
  ## **The EDIT-mode surface: the WORKING TREE, and not through `SourceVM`.**
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
  let contract = sourceContractFor(pmEdit)
  result.medium = medium
  result.productMode = pmEdit
  result.sourceStatement = contract.statement
  result.mutable = contract.mutable and mutableHere
  result.path = path
  result.revisionLabel = ""
  # THE WORKING TREE IS `epUnverified` BY CONSTRUCTION, and that is not a
  # degradation — it is the truth about which copy this is. CTUI-5's rule is
  # that a working-tree read must not look identical to the recording's own
  # copy, and edit mode shows the working tree ALWAYS, so it is always the
  # unverified one. A surface that reported `epVerified` here would be
  # certifying bytes nobody recorded.
  result.provenance = epUnverified
  result.executionLine = 0
  result.inspectionLine = 0
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
  var lines = text.splitLines()
  # `splitLines` on text ending in a newline yields a final empty element, and
  # a file of four lines that ends the way every text file ends would report
  # five. Dropping it is what makes `totalLineCount` the number a user counts,
  # and it is done HERE rather than at each medium so three editors cannot
  # disagree about how long a file is. A file NOT ending in a newline keeps its
  # last line, which is the same rule `wc -l` gets wrong and an editor must
  # not.
  if lines.len > 1 and lines[^1].len == 0 and text.len > 0 and
     text[^1] in {'\n', '\r'}:
    lines.setLen(lines.len - 1)
  let lastLine =
    if viewportHeight <= 0: high(int)
    else: viewportTop + viewportHeight - 1
  for idx, lineText in lines:
    let line = idx + 1
    if line < viewportTop: continue
    if line > lastLine: break
    result.rows.add EditorRow(line: line, text: lineText, held: true,
                              pointer: eptNone,
                              mark: markFor(points, path, line),
                              flow: efsUnknown)
  result.totalLineCount = lines.len
  result.viewportTop = viewportTop

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
