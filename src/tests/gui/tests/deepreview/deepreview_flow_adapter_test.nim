## deepreview_flow_adapter_test.nim
##
## Headless unit tests for the review-dataset → `FlowUpdate` adapter
## (`src/frontend/ui/review_flow_adapter.nim`) — RV-5 in
## `codetracer-specs/DeepReview/Review-Command.milestones.org`, which supersedes
## DR-R6.
##
##   "The overlay is driven by the dataset, not by a live recording. […] It
##    follows that the adapter, not the replay backend, is the thing standing
##    between a dataset and a flow overlay."
##   — `DeepReview-GUI.md` §7
##
## The suite runs over the same `fixtures/sample-review.json` the Playwright
## review suites launch, decoded by the shared `lib/review_dataset_json.nim`
## reader, so the adapter is fed exactly what a `ct review` launch feeds it
## rather than a hand-built stand-in. Everything it asserts is a property of the
## real `FlowUpdate` value the adapter produces, built with the `common/types`
## flavour of the type — the *same generic code* the renderer instantiates over
## the `cstring` flavour.
##
## Mock objects: none. The one thing that is not production code is the JSON
## decode, and that is the renderer's `cast[DeepReviewData](JSON.parse(...))`
## written out field-for-field — see `lib/review_dataset_json.nim`'s header.
##
## Compile and run:
##   nim c -r src/tests/gui/tests/deepreview/deepreview_flow_adapter_test.nim

import std/[strutils, tables, unittest]

import ../../../../common/types as ct
import ../../../../frontend/ui/review_flow_adapter
import ../../../../frontend/ui/flow_line_styles
import lib/review_dataset_json

# The fixture is read at COMPILE time, not with `readFile`: this suite runs on
# the JS lane too (`just test-vm-js`), where there is no `fopen` — the pattern
# `deepreview_entry_test.nim` and `materialized_review_dataset_test.nim`
# already use for the same file.
proc fixtureDirPath(): string {.compileTime.} =
  let p = currentSourcePath()
  var cut = p.rfind('/')
  let backslash = p.rfind('\\')
  if backslash > cut:
    cut = backslash
  p[0 .. cut] & "fixtures/"

const SampleReviewJson = staticRead(fixtureDirPath() & "sample-review.json")

proc sampleReview(): ct.DeepReviewData =
  decodeReviewDatasetJson(SampleReviewJson)

proc fileNamed(data: ct.DeepReviewData; path: string): ct.DeepReviewFileData =
  for file in data.files:
    if file.path == path:
      return file
  raise newException(ValueError, "fixture has no file " & path)

proc flowUpdateFor(file: ct.DeepReviewFileData; invocation: int): ct.FlowUpdate =
  result = ct.FlowUpdate()
  fillFlowUpdate(reviewFlowPlan(file, invocation), result, ct.ViewSource)

suite "the adapter produces a well-formed FlowUpdate from a fixture":

  test "steps carry the fixture's lines as position, unchanged counts and ticks":
    # DR-R6's mismatch table: "`FlowStep.position` <- `DeepReviewFlowStep.line`
    # — rename only. `stepCount`, `rrTicks`, `iteration` map directly; `loopId`
    # to `loop`."
    let file = sampleReview().fileNamed("src/main.rs")
    let plan = reviewFlowPlan(file, 0)   # main, executionIndex 0
    check plan.found
    check plan.functionKey == "main"
    check plan.executionIndex == 0
    check plan.steps.len == 5
    check plan.steps[0].position == 1
    check plan.steps[1].position == 2
    check plan.steps[1].stepCount == 1
    check plan.steps[1].rrTicks == 100010
    check plan.steps[1].iteration == 0
    # A step outside any loop lands on the placeholder `loops[0]`, never on the
    # dataset's -1, which would index the seq out of bounds.
    check plan.steps[1].loop == 0

  test "the location is synthesised from the function's declared span":
    # `flowStyleLines` iterates `functionFirst + 1 .. functionLast`, so without
    # this the overlay would touch no line at all. `main` is declared
    # `startLine: 1, endLine: 12` in `functions`.
    let file = sampleReview().fileNamed("src/main.rs")
    let update = file.flowUpdateFor(0)
    let view = update.viewUpdates[ct.ViewSource]
    check view.location.path == "src/main.rs"
    check view.location.highLevelPath == "src/main.rs"
    check view.location.functionName == "main"
    check view.location.functionFirst == 1
    check view.location.functionLast == 12
    check view.location.line == 1
    check update.finished
    check not update.error

  test "the derived step counts make the executed lines read as hits":
    # "`relevantStepCount`, `positionStepCounts` … all absent; must be derived
    # from the steps, or emitted as empty with the consequence understood
    # (`toLineFlowKind` returns `LineFlowSkip` for every line once
    # `finished`)." — DR-R6. They are derived.
    let file = sampleReview().fileNamed("src/main.rs")
    let view = file.flowUpdateFor(0).viewUpdates[ct.ViewSource]
    # The fixture's first call of `main` visits lines 1, 2, 3, 4 and 10.
    check view.relevantStepCount == @[1, 2, 3, 4, 10]
    check view.positionStepCounts[2] == @[1]
    # Read through `flowStyledLines`, the one implementation of the per-line
    # rule. `ct.toLineFlowKind` was a second copy of it and is deleted — see
    # the note in its place in `common_types/codetracer_features/flow.nim`.
    var hits: seq[int] = @[]
    for s in flowStyledLines(view, finished = true):
      check s.kind == flskHit
      hits.add(s.position)
    # Line 1 is `functionFirst` and carries no flow, so the derived hits over
    # the offered span are 2, 3, 4 and 10. Lines 5-9, 11 and 12 earn no class:
    # the dataset records no branch, so nothing is claimed about them and they
    # are not dimmed.
    check hits == @[2, 3, 4, 10]

  test "a DeepReviewLoop becomes a Loop the slider can drive":
    # "`FlowViewUpdate.loops: seq[Loop]` <- `DeepReviewLoop`. Different shapes
    # […] Loop-slider behaviour depends on the last two." — DR-R6.
    # `rrTicksForIterations` holds the tick at which the loop HEADER was passed
    # for each iteration, which is what `flow_loop_math.activeIterationForTicks`
    # reads; the fixture passes line 16 at ticks 100060/100062/100064.
    let file = sampleReview().fileNamed("src/main.rs")
    let view = file.flowUpdateFor(2).viewUpdates[ct.ViewSource]  # compute, 0
    check view.loops.len == 2
    check view.loops[0].base == -1        # the placeholder `Loop::default()`
    let loop = view.loops[1]
    # -1 is "not nested" (`ui/flow.nim:339`): a review dataset carries no loop
    # nesting, so every loop it describes is top-level.
    check loop.base == -1
    check loop.first == 16
    check loop.last == 18
    check loop.registeredLine == 16
    check loop.rrTicksForIterations == @[100060, 100062, 100064]
    check loop.stepCounts == @[2, 4, 6]
    check loop.iteration == 2
    # And the loop's steps point at it by index, so `flow.loops[step.loop]`
    # resolves.
    for step in view.steps:
      check step.loop >= 0
      check step.loop < view.loops.len
    check view.steps[2].loop == 1
    check view.steps[2].iteration == 0
    check view.steps[4].iteration == 1

suite "the adapter emits a well-formed empty branchesTaken":

  test "one outer and one inner element with an empty table, not an empty seq":
    # DR-R6: "The adapter must emit a well-formed empty
    # `@[@[BranchesTaken(table: <empty>)]]` *and* `flowStyleLines` should be
    # guarded." This pins the first half; `flow_line_styles_test.nim` pins the
    # second. Both, because the guard is a second line of defence and not a
    # licence for the adapter to emit garbage.
    let file = sampleReview().fileNamed("src/main.rs")
    # `main` enters no loop, so the window carries only the outer row — the
    # file's loop (which belongs to `compute`) must not add one.
    let view = file.flowUpdateFor(0).viewUpdates[ct.ViewSource]
    check view.loops.len == 1
    check view.branchesTaken.len == 1
    check view.branchesTaken[0].len == 1
    check view.branchesTaken[0][0].table.len == 0
    check view.loopIterationSteps.len == 1
    check view.loopIterationSteps[0].len == 1

  test "a loop gets one inner element per iteration, as process_loops does":
    # `process_loops` pushes an outer element when a loop opens and an inner one
    # per iteration; `add_branches` then writes into `[loop_id].last()`. An
    # adapter that emitted one row per loop would make that write land on the
    # wrong iteration.
    let file = sampleReview().fileNamed("src/main.rs")
    let view = file.flowUpdateFor(2).viewUpdates[ct.ViewSource]
    check view.branchesTaken.len == 2
    check view.branchesTaken[0].len == 1
    check view.branchesTaken[1].len == 3   # three passes of the header
    check view.loopIterationSteps[1].len == 3

  test "the output is safe to hand straight to flowStyleLines":
    let file = sampleReview().fileNamed("src/main.rs")
    let update = file.flowUpdateFor(0)
    let styled = flowStyledLines(update.viewUpdates[ct.ViewSource],
                                 update.finished)
    # `flowStyleLines` has always spanned `functionFirst + 1 .. functionLast` —
    # the signature line carries no flow — so `main` (1..12) offers 2..12.
    #
    # NOTHING IS DIMMED HERE, and that is the correct reading rather than a
    # loss. The adapter emits a well-formed but EMPTY branch table (the test
    # above pins that), so no arm of any conditional is shown to have been
    # declined, and `Omniscience-Flow.md` § *Dimming means "the run did not take
    # this branch"* makes "not dimmed" the rendering of "nothing is claimed
    # about this line". Line 6 was `flskSkip` before that rule was written, on
    # the strength of nothing but its absence from `relevantStepCount`.
    # The fixture's first call of `main` visits 1, 2, 3, 4 and 10; the span
    # offered is 2..12, so four lines earn a class and every one of them is a
    # hit.
    check styled == @[
      FlowStyledLine(position: 2, kind: flskHit),
      FlowStyledLine(position: 3, kind: flskHit),
      FlowStyledLine(position: 4, kind: flskHit),
      FlowStyledLine(position: 10, kind: flskHit)]

suite "the adapter selects one invocation and does not merge them":

  test "two invocations of one function produce different steps":
    # "*Granularity mismatch.* `DeepReviewFunctionFlow` is per-invocation […]
    # `FlowUpdate` is per-view, for one location. The adapter needs an explicit
    # invocation selector." — DR-R6. `main` runs twice in the fixture, at
    # different ticks and with different values.
    let file = sampleReview().fileNamed("src/main.rs")
    let firstCall = reviewFlowPlan(file, 0)
    let secondCall = reviewFlowPlan(file, 1)
    check firstCall.functionKey == "main"
    check secondCall.functionKey == "main"
    check firstCall.executionIndex == 0
    check secondCall.executionIndex == 1
    check firstCall.steps.len == 5
    check secondCall.steps.len == 4
    check firstCall.steps[1].rrTicks == 100010
    check secondCall.steps[1].rrTicks == 200010
    check firstCall.steps[1].values[0].value == "10"
    check secondCall.steps[1].values[0].value == "42"
    # Same function, so the same span — the difference is the execution, not
    # the location.
    check firstCall.functionFirst == secondCall.functionFirst
    check firstCall.functionLast == secondCall.functionLast

  test "the invocation index resolves through the function it belongs to":
    let file = sampleReview().fileNamed("src/main.rs")
    let functions = reviewFunctionInvocations(file)
    check reviewInvocationIndex(functions, "main", 0) == 0
    check reviewInvocationIndex(functions, "main", 1) == 1
    check reviewInvocationIndex(functions, "compute", 0) == 2
    # Clamped, not wrapped: "next" on the last invocation stays on the last one,
    # the way the loop iteration slider stops at the last iteration.
    check reviewInvocationIndex(functions, "main", 7) == 1
    check reviewInvocationIndex(functions, "main", -3) == 0

  test "the selector is anchored by the line the reader is on":
    # §7: "which invocation is displayed is a property of the code on screen,
    # the way the loop iteration is". `reviewFunctionAt` is what turns a line
    # into the function whose control belongs above it.
    let file = sampleReview().fileNamed("src/main.rs")
    let functions = reviewFunctionInvocations(file)
    check functions[reviewFunctionAt(functions, 3)].functionKey == "main"
    check functions[reviewFunctionAt(functions, 17)].functionKey == "compute"
    check reviewFunctionAt(functions, 40) == -1

  test "an out-of-range invocation yields nothing rather than the first one":
    let file = sampleReview().fileNamed("src/main.rs")
    check not reviewFlowPlan(file, 3).found
    check not reviewFlowPlan(file, -1).found
    check reviewFlowPlan(file, 3).invocationCount == 3

suite "a function the changeset only calls (RV-4 gap 8)":

  test "a function with a callCount and no flow reports zero invocations":
    # RV-4 gap 8: "Flow for a function the diff only CALLS — absent, with a real
    # `callCount` beside `executionCount: 0`. […] a reviewer who expects the
    # callee's overlay should know why it is not there."  `format_output` is
    # called twice and recorded once, so the *second* call has no flow; the
    # selector must say "1 recorded" rather than offering two and rendering the
    # first twice.
    let file = sampleReview().fileNamed("src/utils.rs")
    let functions = reviewFunctionInvocations(file)
    check functions.len == 1
    check functions[0].functionKey == "format_output"
    check functions[0].callCount == 2
    check functions[0].invocations.len == 1
    check reviewInvocationIndex(functions, "format_output", 1) == 0

  test "a file with no flow at all offers no invocation and no overlay":
    # `src/config.rs` is deleted in the fixture: it has neither functions nor
    # flow.  An adapter that answered with an empty-but-found plan would push a
    # `FlowUpdate` spanning no lines into the editor and wipe the overlay.
    let file = sampleReview().fileNamed("src/config.rs")
    check reviewInvocations(file).len == 0
    check reviewFunctionInvocations(file).len == 0
    let plan = reviewFlowPlan(file, 0)
    check not plan.found
    check plan.invocationCount == 0
    check plan.steps.len == 0
    check reviewInvocationIndex(reviewFunctionInvocations(file), "anything", 0) ==
      NoInvocation

  test "a nil file is answered, not raised at":
    var file: ct.DeepReviewFileData = nil
    check reviewInvocations(file).len == 0
    check not reviewFlowPlan(file, 0).found

suite "the synthesised values (the value-fidelity interim)":

  test "a recognised scalar renders back as exactly what the collector wrote":
    # The interim recorded in RV-5: the dataset carries a pre-rendered string,
    # so the adapter synthesises a `Value` that renders back to it. An int keeps
    # its `Int` kind, so it is styled `value-int` rather than as raw text.
    let file = sampleReview().fileNamed("src/main.rs")
    let view = file.flowUpdateFor(0).viewUpdates[ct.ViewSource]
    let step = view.steps[1]
    check step.exprOrder == @["x"]
    let value = step.afterValues["x"]
    check value.kind == ct.Int
    check value.i == "10"
    check $value == "10"
    # Both slots are filled: `FlowComponent` reads whichever the reader's value
    # mode selects, and a half-filled step renders blank in the other mode.
    check step.beforeValues["x"].i == "10"

  test "a string keeps one pair of quotes, not two":
    # The collector renders a string WITH its quotes and `Value`'s own `$` adds
    # them again for `TypeKind.String`; stripping one pair is what makes the
    # round trip identity rather than `""hello world""`.
    let file = sampleReview().fileNamed("src/utils.rs")
    let view = file.flowUpdateFor(0).viewUpdates[ct.ViewSource]
    let value = view.steps[1].afterValues["trimmed"]
    check value.kind == ct.String
    check value.text == "hello world"
    check $value == "\"hello world\""

  test "an unrecognised kind becomes Raw carrying the rendered text verbatim":
    # Cost 3 of the interim, asserted rather than assumed: a language type the
    # map does not know falls back to `Raw`, which `ui/value.nim:1073` prints
    # straight out of `r`.
    check synthesizedValueKind("Vec<u8>") == rvkRaw
    check synthesizedValueKind("HashMap<String, i32>") == rvkRaw
    check synthesizedValueKind("i64") == rvkInt
    check synthesizedValueKind("F64") == rvkFloat
    check synthesizedValueKind("&str") == rvkString
    check synthesizedValueKind("boolean") == rvkBool
    var raw = ct.Value()
    fillFlowValue(raw, ReviewFlowValue(
      name: "config", value: "Config { retries: 3 }", kind: "Config"))
    check raw.kind == ct.TypeKind.Raw
    check raw.r == "Config { retries: 3 }"

  test "no value the adapter produces is a comment":
    # DeepReview-GUI.md §4.4/§7: "Inline variable values MUST NOT be rendered as
    # text comments". The deleted standalone panel built `"  // " & parts.join`
    # here; nothing the adapter emits may carry that shape again.
    let data = sampleReview()
    for file in data.files:
      for invocation in 0 ..< reviewInvocations(file).len:
        let view = file.flowUpdateFor(invocation).viewUpdates[ct.ViewSource]
        for step in view.steps:
          for valueName, flowValue in step.afterValues.pairs:
            check not valueName.startsWith("//")
            check not ($flowValue).strip().startsWith("//")
            check "  // " notin $flowValue

# ---------------------------------------------------------------------------
# UD-3: the structured values, where the collector emits them
# ---------------------------------------------------------------------------

proc structuredFile(): ct.DeepReviewFileData =
  ## One file whose flow carries a compound value with its structure, and a
  ## scalar without it.
  ##
  ## Hand-built rather than read from a fixture, because the two cases that
  ## matter are the two *collectors* and only one of them exists on this
  ## machine: `sample-review.json` is shaped like the native `.dr` exporter,
  ## which writes no structure at all, and the materialized collector's real
  ## output is asserted in Rust
  ## (`db-backend/tests/deepreview_materialized_collector_test.rs`, "flow
  ## carries the functions steps values and loop iterations"). This is the
  ## adapter's side of that seam: a dataset with structure and one without,
  ## fed to the same code.
  # `Instance` is what Nim calls the kind Rust calls `Struct` — the two enums
  # are one list in one order and travel as an ordinal
  # (`TypeKind` derives `Serialize_repr`), which is why the field names differ
  # and the values do not.
  let point = ct.Value(
    kind: ct.TypeKind.Instance,
    typ: ct.Type(kind: ct.TypeKind.Instance, langType: "Point"),
    elements: @[
      ct.Value(kind: ct.TypeKind.Int, typ: ct.Type(
        kind: ct.TypeKind.Int, langType: "i32"), i: "3"),
      ct.Value(kind: ct.TypeKind.Int, typ: ct.Type(
        kind: ct.TypeKind.Int, langType: "i32"), i: "4")])
  ct.DeepReviewFileData(
    path: "src/geom.rs",
    functions: @[ct.DeepReviewFunctionCoverage(
      name: "origin", startLine: 1, endLine: 9, callCount: 1)],
    loops: @[],
    flow: @[ct.DeepReviewFunctionFlow(
      functionKey: "origin",
      executionIndex: 0,
      steps: @[
        ct.DeepReviewFlowStep(
          line: 2, stepCount: 0, rrTicks: 0, loopId: -1, iteration: -1,
          values: @[ct.DeepReviewVariableValue(
            name: "p", value: "(3, 4)", kind: "Point", truncated: false,
            structured: point)]),
        ct.DeepReviewFlowStep(
          line: 3, stepCount: 1, rrTicks: 1, loopId: -1, iteration: -1,
          values: @[ct.DeepReviewVariableValue(
            name: "n", value: "7", kind: "i32", truncated: false)])])])

proc structuredUpdate(file: ct.DeepReviewFileData): ct.FlowUpdate =
  result = ct.FlowUpdate()
  fillFlowUpdate(file, reviewFlowPlan(file, 0), result, ct.ViewSource)

suite "the structured values the collectors now emit (UD-3)":
  ## RV-5 recorded four costs of synthesising a `Value` from a rendered string.
  ## The materialized collector carries the structure now
  ## (`json.rs::VariableValueData.structured`), and these are the two of the
  ## four the adapter can close on its own.

  test "a compound value arrives with its members, not as one Raw string":
    # RV-5's cost 1, and its falsifiable form: "every such value is
    # `TypeKind.Raw`".
    let file = structuredFile()
    let view = structuredUpdate(file).viewUpdates[ct.ViewSource]
    let value = view.steps[0].beforeValues["p"]
    check value.kind == ct.TypeKind.Instance
    check value.elements.len == 2
    check value.elements[0].i == "3"
    check value.elements[1].i == "4"

  test "the kind comes from the recorder, not from the type name's spelling":
    # RV-5's cost 3: `Point` is not in `synthesizedValueKind`'s map and would
    # have become `Raw`.  Asserted against the synthesis directly, so the test
    # fails if the map ever grows a `Point` entry and stops proving anything.
    check synthesizedValueKind("Point") == rvkRaw
    let file = structuredFile()
    let view = structuredUpdate(file).viewUpdates[ct.ViewSource]
    check view.steps[0].beforeValues["p"].typ.langType == "Point"

  test "both value slots carry the structure, as the synthesis filled both":
    # The dataset carries ONE value per name per step and `FlowComponent` reads
    # whichever the reader's value mode selects, so a half-filled step renders
    # blank in the other mode — the rule `fillFlowUpdate` already follows for
    # the synthesised value, and the structured path must not break it.
    let file = structuredFile()
    let view = structuredUpdate(file).viewUpdates[ct.ViewSource]
    for slot in [view.steps[0].beforeValues["p"], view.steps[0].afterValues["p"]]:
      check slot.kind == ct.TypeKind.Instance
      check slot.elements.len == 2

  test "a value with no structure keeps the typed synthesis":
    # The whole native `.dr` case: no `structured`, so the adapter's own
    # mapping still runs and the value is still an `Int` rather than nothing.
    let file = structuredFile()
    let view = structuredUpdate(file).viewUpdates[ct.ViewSource]
    let value = view.steps[1].beforeValues["n"]
    check value.kind == ct.TypeKind.Int
    check value.i == "7"
    check value.elements.len == 0

  test "a dataset with no structure anywhere is unchanged by the new path":
    # `sample-review.json` is shaped like the native exporter's output.  The
    # file-taking overload must leave it exactly as the plan-only one does, or
    # every native-collector review would change behaviour for nothing.
    let file = sampleReview().fileNamed("src/main.rs")
    var withFile = ct.FlowUpdate()
    fillFlowUpdate(file, reviewFlowPlan(file, 0), withFile, ct.ViewSource)
    let plain = flowUpdateFor(file, 0)
    let a = withFile.viewUpdates[ct.ViewSource]
    let b = plain.viewUpdates[ct.ViewSource]
    check a.steps.len == b.steps.len
    for i in 0 ..< a.steps.len:
      check a.steps[i].exprOrder == b.steps[i].exprOrder
      for name in a.steps[i].exprOrder:
        check a.steps[i].beforeValues[name].kind ==
          b.steps[i].beforeValues[name].kind
        check a.steps[i].beforeValues[name].r == b.steps[i].beforeValues[name].r

  test "a plan and a file that do not match leave the update alone":
    # The positional lookup is safe because `reviewFlowPlan` is 1:1 with the
    # dataset, but a caller that pairs the wrong two must fail loudly-empty
    # rather than write somebody else's value under this name.
    let file = structuredFile()
    var update = ct.FlowUpdate()
    var plan = reviewFlowPlan(file, 0)
    plan.invocationIndex = 42
    fillFlowUpdate(file, plan, update, ct.ViewSource)
    let view = update.viewUpdates[ct.ViewSource]
    check view.steps[0].beforeValues["p"].kind == ct.TypeKind.Raw
    check view.steps[0].beforeValues["p"].r == "(3, 4)"
