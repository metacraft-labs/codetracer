## test_inline_annotations.nim — CTUI-5, Tier 1, on a real trace.
##
## ## What this suite establishes
##
## CTUI-5: "annotations show the values the ViewModel reports at the current
## tick, and *clear* when stepping to a line with none. A stale annotation is
## the failure mode; the test asserts the clearing case explicitly."
##
## A stale annotation is worse than no annotation because it is
## indistinguishable from a correct one: `total: 42` beside a line where
## `total` is now 7 reads exactly like the truth. So this suite does three
## things, in this order:
##
##   1. establishes that annotations APPEAR at all, from values a real
##      `StateVM` reported at a real stop — the positive control, without which
##      every "it cleared" assertion below is satisfied by a pane that never
##      annotates anything;
##   2. asserts that the value rendered is the value the ViewModel reports AT
##      THAT TICK, by comparing the pane's text against `StateVM`'s own
##      `currentVariables` read in the same frame;
##   3. asserts the CLEARING case explicitly — a stop whose line mentions none
##      of the in-scope names renders NO annotation, and specifically does not
##      render the previous stop's.
##
## ## WHY THIS FILE IS NOT UNDER `app/tests/`
##
## Same reason as `test_source_stepping_forward_backward.nim`: `app/tests/` is
## walked by `tests/test_tui_facade_boundary.nim`, which forbids
## `viewmodel/headless_session`, and the values here have to come from a real
## `StateVM` over a real `replay-server`. See that file's header and CTUI-5's
## Implementation section.
##
## ## No mocks
##
## The variables are whatever `ct/load-locals` returned for the stop the
## debugger is really at. Nothing here writes a value into the ViewModel.
##
## ## Templates, not procs, for anything that calls `check`
##
## A `proc` that fails a `check` sets `programResult = 1` while the enclosing
## case still prints `[OK]`.

import std/[os, strutils, unittest]

import isonim/core/[signals, computation]
import isonim/viewmodel
import isonim_tui

import headless_session
import store/[replay_data_store, degraded_state, types]
import viewmodels/[source_vm, state_vm]
import sdk/source_provider

import ../app/source_binding
import ./fixtures/fixture_provider

# One line, deliberately: `ci/lib/run-nim-test-lane.sh` reads exactly this
# spelling as a RUNTIME assertion count.
const ExpectedAssertions = 32

var countedAssertions = 0

template ck(condition: untyped) =
  inc countedAssertions
  check condition

const
  FixtureName = "calc"
  WalkSteps = 40
    ## How far to walk looking for the two frames this suite needs: one that
    ## annotates and one that does not. Both are asserted to have been FOUND —
    ## a walk that found neither fails rather than passing vacuously.
    ##
    ## THE WALK USES `stepIn`, NOT `stepForward`, AND THAT IS A MEASURED
    ## CHOICE. `stepForward` sends DAP `next` — line-granularity step-OVER — and
    ## on `calc` it never descends into a frame: over 21 stops it walked the
    ## module's `def` lines, entered `main`, and then reported `main.py:113`
    ## five times running with the same locals, because the recording had
    ## ended. Every one of those stops reports module-level names whose values
    ## the engine renders EMPTY (`add=`, `results=`), which `annotationsFrom`
    ## drops, so the walk found zero annotated frames. `stepIn` descends, and
    ## the frames with live values — `left=2, right=3` on `return left + right`
    ## — are inside `evaluate`, `apply_op` and `add`.
  PaneWidth = 90
  PaneHeight = 24
    ## Wider than the Compact profile's editor, because an annotation only
    ## renders when there is room after the code (see
    ## `views/inline_annotations.MinAnnotationCells`). The narrow case is
    ## asserted separately below, at the width that leaves no room.
  ViewportLines = PaneHeight - 1
  Overscan = 6

var
  examinedFixtures = 0
  verifiedFixtures = 0
  skippedFixtures = 0

type Harness = object
  session: HeadlessDebugSession
  vm: SourceVM
  provider: SourceProvider
  cache: HighlighterCache

proc openHarness(tracePath: string): Harness =
  let session = newHeadlessDebugSession(tracePath, findReplayServer())
  let vm = createSourceVM(session.session.store, session.session.editorVM)
  vm.setViewport(height = ViewportLines, overscan = Overscan)
  Harness(
    session: session,
    vm: vm,
    provider: newCtfsSourceProvider(tracePath, allowWorkingTree = false),
    cache: newHighlighterCache())

proc closeHarness(h: Harness) =
  h.vm.dispose()
  h.session.close()

proc serveOne(h: Harness; request: SourceLineRequest): SourceFetch =
  result = SourceFetch(status: sfsProviderUnavailable,
                       detail: "the provider callback never ran")
  var captured = result
  h.provider.fetch(request, proc(fetch: SourceFetch) = captured = fetch)
  drainSourceCallbacks()
  result = captured

proc fillWindow(h: Harness) =
  for request in h.vm.followAndRequest():
    let fetch = h.serveOne(request)
    discard h.session.session.store.applySourceFetch(h.vm, fetch)

proc currentVariables(h: Harness): seq[types.Variable] =
  ## What `StateVM` reports at THIS tick.
  ##
  ## `requestAndLoadLocals` is the production route — it issues
  ## `ct/load-locals` and applies the response through `applyLocalsResponse` —
  ## so the values below are the ViewModel's own, not a second parse of the
  ## same wire message.
  h.session.requestAndLoadLocals()
  h.session.session.stateVM.currentVariables.val

proc modelAt(h: Harness; variables: seq[types.Variable]): SourcePaneModel =
  sourcePaneModelFor(
    h.vm,
    h.session.session.store.degraded.sourceAvailability.val,
    variables = variables)

proc lineTextAt(h: Harness; line: int): string =
  let read = h.vm.lineAt(line)
  if read.kind == srkHeld: read.text else: ""

type Frame = object
  line: int
  lineText: string
  variables: seq[types.Variable]
  expected: seq[Annotation]
  rendered: string
    ## The EXACT annotation text the pane should have drawn on this row —
    ## `fitAnnotation` over the room the code left. Computed from the pane's
    ## own helpers rather than restated, so a truncated annotation is checked
    ## exactly instead of being excused.
  codeWidth: int
  model: SourcePaneModel
    ## The model this frame was rendered FROM, kept so a later case can
    ## re-render exactly this stop after the debugger has moved on. Without it
    ## a "render it again" assertion would render the CURRENT stop with an old
    ## frame's values, which is a different question.
  paneRow: string
  annotated: int

proc captureFrame(h: Harness): Frame =
  ## One stop, as everything this suite asserts about it.
  let line = h.vm.executionLine.val
  let variables = h.currentVariables()
  let model = h.modelAt(variables)
  let screen = sourcePaneScreen(model, PaneWidth, PaneHeight, h.cache)
  let row = 1 + line - model.viewportTop
  let lineText = h.lineTextAt(line)
  let selected = annotationsForLine(lineText, annotationsFrom(variables))
  let shown = min(cellWidthOf(lineText), screen.codeWidth)
  Frame(
    line: line,
    lineText: lineText,
    variables: variables,
    expected: selected,
    rendered: fitAnnotation(annotationText(selected),
                            annotationRoom(screen.codeWidth, shown)),
    codeWidth: screen.codeWidth,
    model: model,
    paneRow: (if row >= 0 and row < screen.rows.len: rowText(screen.rows[row])
              else: ""),
    annotated: screen.annotatedLines)

# ---------------------------------------------------------------------------
# Assertion templates
# ---------------------------------------------------------------------------

template checkAnnotatedFrameShowsTheViewModelsValues(frame: Frame) =
  ## The pane's annotation names and values are the ViewModel's, at this tick.
  ck frame.expected.len >= 1
  ck frame.annotated == 1
  ck frame.paneRow.contains(AnnotationOpen.strip())
  # The WHOLE annotation, exactly as the pane should have fitted it. Compared
  # as one string rather than pair by pair, so a truncated annotation is
  # asserted against its truncation instead of being excused by it.
  ck frame.rendered.len > 0
  ck frame.paneRow.contains(frame.rendered)
  # …and, for a frame whose annotation fitted whole, NAME AND VALUE TOGETHER.
  # `contains(name)` alone is satisfied by the source line itself — the name
  # is on it, which is why it was selected — and `contains(value)` alone by a
  # coincidence of digits.
  ck frame.rendered == annotationText(frame.expected)
  for a in frame.expected:
    ck frame.paneRow.contains(a.name & ": " & a.value)

template checkClearedFrameShowsNothing(frame, previous: Frame) =
  ## The clearing case, asserted explicitly and in two independent ways.
  ck frame.expected.len == 0
  ck frame.annotated == 0
  # No annotation marker anywhere on the row…
  ck not frame.paneRow.contains(AnnotationOpen.strip())
  # …and specifically NOT the previous stop's, which is the stale-annotation
  # failure mode named in CTUI-5. Asserted per rendered pair rather than as a
  # whole string, because a stale annotation would carry the previous frame's
  # name AND its previous value.
  for a in previous.expected:
    ck not frame.paneRow.contains(a.name & ": " & a.value)

suite "CTUI-5: inline annotations follow the tick, and clear":

  test "annotations appear, carry the ViewModel's values, and clear":
    inc examinedFixtures
    let resolution = resolveFixture(FixtureName)
    if resolution.outcome == foMissingPrereq:
      inc skippedFixtures
      let message = missingPrereqMessage(resolution.spec, resolution.detail)
      echo "  ", message
      ck message.startsWith(MissingPrereqSkipPrefix)
      ck resolution.tracePath.len == 0
      skip()
    else:
      inc verifiedFixtures
      let h = openHarness(resolution.tracePath)
      defer: h.closeHarness()
      h.fillWindow()

      # ---- walk, capturing every frame ------------------------------------
      var frames: seq[Frame] = @[]
      var walked = 0
      frames.add h.captureFrame()
      for _ in 1 .. WalkSteps:
        h.session.stepIn()
        discard h.session.drainEvents()
        h.fillWindow()
        frames.add h.captureFrame()
        inc walked
      ck walked == WalkSteps
      ck frames.len == WalkSteps + 1

      var annotatedIdx = -1
      var clearedIdx = -1
      var annotatedCount = 0
      var clearedCount = 0
      for i, f in frames:
        if f.expected.len > 0:
          inc annotatedCount
          if annotatedIdx < 0:
            annotatedIdx = i
        else:
          inc clearedCount
          # The CLEARING case has to follow an ANNOTATED one to be the case
          # CTUI-5 names — "clear when STEPPING TO a line with none".
          #
          # ANY bare frame whose PREDECESSOR annotated, not specifically the one
          # after the FIRST annotated frame. The stricter form was what this
          # suite was written with and it was an accident of the data rather
          # than a statement about the pane: CTUI-7 corrected
          # `headless_session.extractValueText`, whose `TypeKind` ordinals were
          # wrong for six kinds, and frames 7-10 of this walk — the four
          # `OPERATIONS = {…}` lines, each binding a FUNCTION OBJECT, which the
          # wire sends as `TypeKind.Raw` (16), an ordinal the old mapping did
          # not have at all, so it decoded to `""` and `annotationsFrom` dropped
          # it — started annotating. Measured either side of the correction:
          # 16 annotated frames with the first at index 20, and 23 with the
          # first at index 7. The case this suite exists to assert is still in
          # the walk; the index it sits at moved.
          if clearedIdx < 0 and i > 0 and frames[i - 1].expected.len > 0:
            clearedIdx = i
      echo "CTUI-5 ANNOTATION WALK: " & $frames.len & " frame(s), " &
           $annotatedCount & " annotated, " & $clearedCount & " bare; " &
           "first annotated at " & $annotatedIdx &
           ", first bare-after-annotated at " & $clearedIdx
      # BOTH must have been found. A walk that found only annotated frames
      # cannot assert the clearing case, and a walk that found only bare ones
      # would let every assertion below pass over an empty set.
      ck annotatedIdx >= 0
      ck clearedIdx > annotatedIdx
      ck annotatedCount >= 1
      ck clearedCount >= 1
      ck annotatedCount + clearedCount == frames.len

      let annotated = frames[annotatedIdx]
      let cleared = frames[clearedIdx]
      checkpoint("annotated line " & $annotated.line & ": " &
                 annotated.lineText.strip())
      checkpoint("annotated row: " & annotated.paneRow.strip())
      checkpoint("cleared line " & $cleared.line & ": " &
                 cleared.lineText.strip())
      checkpoint("cleared row: " & cleared.paneRow.strip())

      checkAnnotatedFrameShowsTheViewModelsValues(annotated)
      # The second argument is the frame the walk really came FROM, which is
      # what `checkClearedFrameShowsNothing`'s stale-annotation half is about.
      # It used to be `annotated`, and that was the same frame only because the
      # selector above insisted on `annotatedIdx + 1`; once the selector took
      # any bare frame whose predecessor annotated, the two parted company.
      checkClearedFrameShowsNothing(cleared, frames[clearedIdx - 1])

      # ---- the values are THIS tick's, not a remembered one ----------------
      # Two frames on the SAME line with DIFFERENT values would be the sharpest
      # form of this, and `calc` may or may not offer one in `WalkSteps`. What
      # is always available and is asserted instead: every annotated frame's
      # rendered value equals the value `StateVM` reported in that same frame,
      # for every variable on the line — over EVERY annotated frame in the
      # walk, not only the first.
      var checkedPairs = 0
      var checkedAnnotations = 0
      var truncated = 0
      var wrong: seq[string] = @[]
      for f in frames:
        if f.expected.len == 0:
          continue
        inc checkedAnnotations
        # THE EXACT RENDERING, truncated or not. `f.rendered` is
        # `fitAnnotation` over the room the code left on that row, computed
        # with the pane's own helpers.
        if not f.paneRow.contains(f.rendered):
          wrong.add "line " & $f.line & ": expected `" & f.rendered &
            "` on `" & f.paneRow.strip() & "`"
          continue
        if f.rendered.endsWith(AnnotationEllipsis):
          inc truncated
          continue
        for a in f.expected:
          inc checkedPairs
          if not f.paneRow.contains(a.name & ": " & a.value):
            wrong.add "line " & $f.line & ": expected `" & a.name & ": " &
              a.value & "` on `" & f.paneRow.strip() & "`"
      if wrong.len > 0:
        checkpoint(wrong[0 .. min(4, wrong.high)].join("\n"))
      echo "CTUI-5 ANNOTATION CHECKS: " & $checkedAnnotations &
           " annotated frame(s), " & $truncated & " truncated, " &
           $checkedPairs & " name/value pair(s) compared in full"
      ck checkedAnnotations == annotatedCount
      ck checkedPairs >= 1
      ck wrong.len == 0

      # ---- the clearing property, over EVERY bare frame in the walk --------
      # The two named frames above are the case CTUI-5 asks for explicitly.
      # This is the same property quantified over the whole walk, and it is
      # the assertion that would catch a renderer which cleared correctly once
      # and then started carrying a value forward: 25 bare frames, none of
      # them carrying an annotation marker, and the pane's own counter
      # agreeing with the model's on every frame.
      var bareWithMarker = 0
      var counterDisagreements = 0
      for f in frames:
        if f.expected.len == 0:
          if f.paneRow.contains(AnnotationOpen.strip()):
            inc bareWithMarker
          if f.annotated != 0:
            inc counterDisagreements
        else:
          if f.annotated != 1:
            inc counterDisagreements
      checkpoint("bare frames carrying a marker: " & $bareWithMarker &
                 ", counter disagreements: " & $counterDisagreements)
      ck bareWithMarker == 0
      ck counterDisagreements == 0

      # ---- nothing is retained between frames ------------------------------
      # `views/inline_annotations.nim` holds no state at all, and this asserts
      # it from the outside: after the debugger has walked far past both, the
      # ANNOTATED frame's model still renders its annotation and the CLEARED
      # frame's model still renders none. Order matters — the annotated one is
      # rendered FIRST, so a renderer that remembered anything would carry it
      # into the second.
      let annotatedAgain = sourcePaneScreen(annotated.model, PaneWidth,
                                            PaneHeight, h.cache)
      ck annotatedAgain.annotatedLines == 1
      let clearedAgain = sourcePaneScreen(cleared.model, PaneWidth,
                                          PaneHeight, h.cache)
      ck clearedAgain.annotatedLines == 0
      var markers = 0
      for row in clearedAgain.rows:
        if rowText(row).contains(AnnotationOpen.strip()):
          inc markers
      ck markers == 0

      # ---- a pane too narrow for an annotation omits it, never truncates it
      # to a stub. The positive twin is the SAME MODEL at `PaneWidth`, which
      # annotates — so "no annotation here" is a property of the width rather
      # than of the model.
      let narrow = sourcePaneScreen(annotated.model, 30, PaneHeight, h.cache)
      ck annotatedAgain.annotatedLines == 1
      ck narrow.annotatedLines == 0
      var narrowMarkers = 0
      for row in narrow.rows:
        if rowText(row).contains(AnnotationOpen.strip()):
          inc narrowMarkers
      ck narrowMarkers == 0

  test "assertion count":
    ck examinedFixtures == 1
    ck verifiedFixtures + skippedFixtures == examinedFixtures
    ck verifiedFixtures >= 1
    echo "CHECKS: " & $countedAssertions
    checkpoint("counted assertions: " & $countedAssertions)
    check countedAssertions == ExpectedAssertions
