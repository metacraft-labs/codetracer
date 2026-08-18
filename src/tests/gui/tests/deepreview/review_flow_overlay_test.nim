## review_flow_overlay_test.nim
##
## Headless unit tests for the review's Omniscience overlay on the unified diff
## tab and for the in-editor invocation selector
## (`src/frontend/viewmodel/viewmodels/review_flow_overlay.nim`) — RV-5 in
## `codetracer-specs/DeepReview/Review-Command.milestones.org`.
##
## Four obligations are pinned here, all of which the Playwright suite can only
## observe indirectly:
##
##   * §4.4 "Restrict rendering to lines currently loaded into the diff tab" —
##     the diff tab's model is a synthetic document, so a source line that is
##     not on screen has no model line to map onto and cannot be decorated. The
##     tests assert the mapping, not a line number, because the document's
##     numbering shifts whenever expansion controls appear.
##   * §4.4's **inline values**: "Preserve existing interaction patterns such
##     as loop sliders and inline values". Asserted *by content* against the
##     fixture, because a count cannot tell one call's values from another's —
##     which is exactly how RV-5's first version shipped with no values at all
##     while its e2e coverage stayed green.
##   * §4.4's **loop sliders**, as the loop iteration control. On a review the
##     control is not an extra: the tab draws one value strip per line, so a
##     line inside a loop has no defined values until the reader has said which
##     pass they are looking at.
##   * §7's invocation selector: "an in-editor control, modelled on the loop
##     iteration selector […] anchored immediately above the relevant lines".
##     `afterLineNumber` IS that anchoring, and it is asserted against the
##     function's first *visible* line rather than its declared first line.
##
## The rows are built from the same `sample-review.json` the Playwright review
## suites launch, through the shared decoder, and projected exactly the way
## `ui/unified_diff.diffRows` projects them — the JS-only half of that proc is
## the Monaco call, not the projection.
##
## Compile and run:
##   nim c -r src/tests/gui/tests/deepreview/review_flow_overlay_test.nim

import std/[strutils, tables, unittest]

import ../../../../common/types as ct
import ../../../../frontend/ui/flow_line_styles
import ../../../../frontend/ui/review_flow_adapter
import ../../../../frontend/ui/review_flow_selection
import ../../../../frontend/viewmodel/viewmodels/diff_document
import ../../../../frontend/viewmodel/viewmodels/review_flow_overlay
import ../../../../frontend/viewmodel/viewmodels/vcs_vm
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

proc rowFor(file: ct.DeepReviewFileData): VCSDiffFileRow =
  ## `ui/unified_diff.diffRows` for one file.
  var hunks: seq[VCSHunkRow] = @[]
  for hunk in file.diff.hunks:
    var lines: seq[VCSDiffLineRow] = @[]
    for line in hunk.lines:
      lines.add(VCSDiffLineRow(
        lineType: line.`type`, content: line.content,
        oldLine: line.oldLine, newLine: line.newLine))
    hunks.add(VCSHunkRow(
      oldStart: hunk.oldStart, oldCount: hunk.oldCount,
      newStart: hunk.newStart, newCount: hunk.newCount, lines: lines))
  VCSDiffFileRow(
    fileIndex: 0, status: file.diff.status, path: file.path,
    additions: file.diff.linesAdded, deletions: file.diff.linesRemoved,
    hunks: hunks, sourceLines: @[])

proc rowSpanning(file: ct.DeepReviewFileData; first, last: int):
    VCSDiffFileRow =
  ## A one-hunk row showing `first .. last` of the file as context lines.
  ##
  ## This is what a tab looks like after the reader has pressed "expand below"
  ## enough times: `ContextExpandStep` is 10 and the fixture's hunk ends at line
  ## 11, so one click reveals 12..21 and puts `compute` — the only function in
  ## the fixture that contains a loop — on screen. Building the row directly
  ## rather than driving `VCSVM.expandContextBelow` keeps the loop cases about
  ## the loop rather than about expansion, which Tests 14-16b already own.
  var lines: seq[VCSDiffLineRow] = @[]
  let source = file.sourceContent.split('\n')
  for number in first .. last:
    if number < 1 or number > source.len:
      continue
    lines.add(VCSDiffLineRow(
      lineType: "context", content: source[number - 1],
      oldLine: number, newLine: number))
  VCSDiffFileRow(
    fileIndex: 0, status: file.diff.status, path: file.path,
    additions: 0, deletions: 0,
    hunks: @[VCSHunkRow(
      oldStart: first, oldCount: lines.len,
      newStart: first, newCount: lines.len, lines: lines)],
    sourceLines: @[])

proc styledFor(file: ct.DeepReviewFileData; invocation: int):
    seq[FlowStyledLine] =
  ## The very same production path the normal editor takes: adapter →
  ## `FlowUpdate` → `flowStyledLines`.
  var update = ct.FlowUpdate()
  fillFlowUpdate(reviewFlowPlan(file, invocation), update, ct.ViewSource)
  flowStyledLines(update.viewUpdates[ct.ViewSource], update.finished)

proc invocationOf(file: ct.DeepReviewFileData; functionKey: string;
                  ordinal: int): int =
  ## The dataset index of one call of one function, by the ordinal the
  ## in-editor selector counts.
  reviewInvocationIndex(reviewFunctionInvocations(file), functionKey, ordinal)

proc chipTexts(annotations: seq[ReviewValueAnnotation]): seq[string] =
  ## Every chip of every annotation, as the pair a reader sees.
  result = @[]
  for annotation in annotations:
    for chip in annotation.values:
      result.add(reviewValueChipName(chip) & chip.text)

proc chipsAt(annotations: seq[ReviewValueAnnotation];
             sourceLine: int): seq[string] =
  result = @[]
  for annotation in annotations:
    if annotation.sourceLine != sourceLine:
      continue
    for chip in annotation.values:
      result.add(reviewValueChipName(chip) & chip.text)

suite "flow decorations land on the diff tab's own line numbers":

  test "every decoration names the model line holding that source line":
    let file = sampleReview().fileNamed("src/main.rs")
    let doc = buildDiffDocument([rowFor(file)])
    let decorations = reviewFlowDecorations(doc, 0, styledFor(file, 0))
    check decorations.len > 0
    for decoration in decorations:
      let line = doc.lines[decoration.modelLine - 1]
      check line.newNumber == decoration.sourceLine
      check line.kind in {dlkAdded, dlkContext}

  test "only the lines the tab has loaded are decorated (§4.4)":
    # `main` runs on lines 1..4 and 10; the hunk shows 2..11. Line 1 is off
    # screen and gets nothing, which is the restriction §4.4 asks for — here
    # structural rather than checked, because an absent line has no model line.
    let file = sampleReview().fileNamed("src/main.rs")
    let doc = buildDiffDocument([rowFor(file)])
    let decorations = reviewFlowDecorations(doc, 0, styledFor(file, 0))
    var sourceLines: seq[int] = @[]
    for decoration in decorations:
      if decoration.sourceLine notin sourceLines:
        sourceLines.add(decoration.sourceLine)
    check 1 notin sourceLines
    check 2 in sourceLines
    check 10 in sourceLines
    check 12 notin sourceLines

  test "executed lines are hits and unexecuted ones are skips":
    let file = sampleReview().fileNamed("src/main.rs")
    let doc = buildDiffDocument([rowFor(file)])
    let decorations = reviewFlowDecorations(doc, 0, styledFor(file, 0))
    for decoration in decorations:
      let expected =
        if decoration.sourceLine in [2, 3, 4, 10]: "line-flow-hit"
        else: "line-flow-skip"
      check decoration.inlineClassName == expected

  test "removed lines are never annotated":
    # A removed line has no position in the revision the flow was recorded
    # against, so annotating it would attribute the new file's execution to the
    # old file's text.
    let file = sampleReview().fileNamed("src/config.rs")   # deleted file
    let doc = buildDiffDocument([rowFor(file)])
    check reviewFlowDecorations(doc, 0, styledFor(file, 0)).len == 0

  test "the classes are the standard Omniscience ones, never a comment":
    # DeepReview-GUI.md §4.4: "Inline variable values MUST NOT be rendered as
    # text comments"; §7 names the standard classes. This is the guard that
    # replaces the deleted panel's `deepreview-inline-value` after-content
    # decorations.
    let file = sampleReview().fileNamed("src/main.rs")
    let doc = buildDiffDocument([rowFor(file)])
    for decoration in reviewFlowDecorations(doc, 0, styledFor(file, 0)):
      check decoration.inlineClassName.startsWith("line-flow-")
      check "deepreview-inline-value" notin decoration.inlineClassName
      check "//" notin decoration.inlineClassName

  test "no flow means no decoration, not a blank overlay":
    let file = sampleReview().fileNamed("src/main.rs")
    let doc = buildDiffDocument([rowFor(file)])
    check reviewFlowDecorations(doc, 0, @[]).len == 0

suite "the inline values §4.4 requires are on the diff tab":
  ## "Preserve existing interaction patterns such as loop sliders and **inline
  ## values**" (§4.4), drawn in "the standard CodeTracer Omniscience visual
  ## style (Monaco decorations with the flow annotation classes)" (§7).
  ##
  ## These cases assert the values **by content against the fixture**, which is
  ## what the deleted standalone panel's Tests 17/18 did and what a count-only
  ## assertion cannot do: a strip of the wrong invocation's values, or of the
  ## wrong loop pass's, has exactly the same count as the right one.

  test "the fixture's own values are what the first call of main shows":
    # From `sample-review.json`, `main` execution 0:
    #   line 2  x = 10
    #   line 3  x = 10, y = 20
    #   line 4  result = 55
    #   line 10 result = 55
    let file = sampleReview().fileNamed("src/main.rs")
    let doc = buildDiffDocument([rowFor(file)])
    let plan = reviewFlowPlan(file, invocationOf(file, "main", 0))
    let annotations = reviewValueAnnotations(doc, 0, plan)
    check annotations.len > 0
    check annotations.chipsAt(2) == @["<x>10"]
    check annotations.chipsAt(3) == @["<x>10", "<y>20"]
    check annotations.chipsAt(4) == @["<result>55"]
    check annotations.chipsAt(10) == @["<result>55"]

  test "every annotation names the model line holding that source line":
    let file = sampleReview().fileNamed("src/main.rs")
    let doc = buildDiffDocument([rowFor(file)])
    let plan = reviewFlowPlan(file, invocationOf(file, "main", 0))
    let annotations = reviewValueAnnotations(doc, 0, plan)
    check annotations.len > 0
    for annotation in annotations:
      let line = doc.lines[annotation.modelLine - 1]
      check line.newNumber == annotation.sourceLine
      check line.kind in {dlkAdded, dlkContext}

  test "only the lines the tab has loaded carry values (§4.4)":
    # `main`'s line 1 records no value, so `format_output` is the case that
    # matters: its line 1 DOES record `input`, and its hunk shows line 1.
    # Line 12 of main.rs is off screen and must stay bare.
    let file = sampleReview().fileNamed("src/main.rs")
    let doc = buildDiffDocument([rowFor(file)])
    let plan = reviewFlowPlan(file, invocationOf(file, "main", 0))
    let annotations = reviewValueAnnotations(doc, 0, plan)
    for annotation in annotations:
      check annotation.sourceLine >= 2
      check annotation.sourceLine <= 11

  test "switching the invocation switches the values, not just the classes":
    # Call 1 computes 55 from x = 10; call 2 computes 903 from x = 42. This is
    # the assertion Test 26's "hit count > 0" cannot make.
    let file = sampleReview().fileNamed("src/main.rs")
    let doc = buildDiffDocument([rowFor(file)])
    let firstCall = reviewValueAnnotations(
      doc, 0, reviewFlowPlan(file, invocationOf(file, "main", 0)))
    let secondCall = reviewValueAnnotations(
      doc, 0, reviewFlowPlan(file, invocationOf(file, "main", 1)))
    check firstCall.chipsAt(2) == @["<x>10"]
    check secondCall.chipsAt(2) == @["<x>42"]
    check firstCall.chipsAt(4) == @["<result>55"]
    check secondCall.chipsAt(4) == @["<result>903"]
    # Call 2 never reached line 10, so it carries no strip there at all —
    # rather than call 1's, relabelled.
    check firstCall.chipsAt(10) == @["<result>55"]
    check secondCall.chipsAt(10).len == 0

  test "a string value reads back as the collector rendered it":
    let file = sampleReview().fileNamed("src/utils.rs")
    let doc = buildDiffDocument([rowFor(file)])
    let plan = reviewFlowPlan(file, invocationOf(file, "format_output", 0))
    let annotations = reviewValueAnnotations(doc, 0, plan)
    check annotations.chipsAt(2) == @["<trimmed>\"hello world\""]
    check annotations.chipsAt(6) == @["<result>\"[hello world]\""]

  test "a truncated value carries the collector's marker":
    let file = sampleReview().fileNamed("src/utils.rs")
    let doc = buildDiffDocument([rowFor(file)])
    let plan = reviewFlowPlan(file, invocationOf(file, "format_output", 0))
    let annotations = reviewValueAnnotations(doc, 0, plan)
    let first = annotations.chipsAt(1)
    check first.len == 1
    check first[0].startsWith("<input>")
    check first[0].endsWith("...")
    for annotation in annotations:
      for chip in annotation.values:
        check chip.truncated == (chip.name == "input")

  test "the chips are the standard classes, never a text comment":
    # §7: "The inline variable values MUST NOT be rendered as text comments
    # (e.g. `// x = 10`) — they must use the standard CodeTracer Omniscience
    # visual style (Monaco decorations with the flow annotation classes)."
    # `deepreview-inline-value` was the deleted after-content comment's class;
    # neither it nor a `//` may appear here.
    check ReviewValueNameClass.contains("ct-omni-name")
    check ReviewValueNameClass.contains("flow-parallel-value-name")
    check ReviewValueBoxClass.contains("flow-parallel-value-box")
    check ReviewValueBoxClass.contains("flow-parallel-value-before-only")
    check "deepreview-inline-value" notin ReviewValueNameClass
    check "deepreview-inline-value" notin ReviewValueBoxClass
    let file = sampleReview().fileNamed("src/main.rs")
    let doc = buildDiffDocument([rowFor(file)])
    for text in reviewValueAnnotations(
        doc, 0, reviewFlowPlan(file, invocationOf(file, "main", 0))).chipTexts():
      check "//" notin text
      check " = " notin text

  test "a removed file's lines are never annotated":
    let file = sampleReview().fileNamed("src/config.rs")
    let doc = buildDiffDocument([rowFor(file)])
    check reviewValueAnnotations(doc, 0, reviewFlowPlan(file, 0)).len == 0

  test "a plan that found nothing draws no strip":
    let file = sampleReview().fileNamed("src/main.rs")
    let doc = buildDiffDocument([rowFor(file)])
    check reviewValueAnnotations(doc, 0, reviewFlowPlan(file, 99)).len == 0

suite "the loop iteration control, and the values it selects":
  ## §4.4 names loop sliders alongside inline values. On a review the two are
  ## one feature: the tab draws one strip per line, so a line inside a loop is
  ## undefined until the reader has said which pass they are looking at.
  ##
  ## `compute` is the fixture's only looping function — `for i in 0..n` on lines
  ## 16..18, recorded for three passes — and its lines reach the tab after one
  ## "expand below" click.

  proc computePlan(file: ct.DeepReviewFileData): ReviewFlowPlan =
    reviewFlowPlan(file, invocationOf(file, "compute", 0))

  test "the loop's recorded passes are counted from the header crossings":
    let file = sampleReview().fileNamed("src/main.rs")
    let plan = computePlan(file)
    # The static loop record claims six iterations for the whole program; this
    # invocation crossed the header three times, and three is what a control
    # over this call may offer.
    check plan.loopIterationCount(1) == 3
    check plan.loopIterationCount(0) == 0
    check plan.loopIterationCount(7) == 0

  test "the control sits immediately above the loop's first visible line":
    let file = sampleReview().fileNamed("src/main.rs")
    let doc = buildDiffDocument([rowSpanning(file, 12, 21)])
    let zones = reviewLoopZones(doc, 0, computePlan(file))
    check zones.len == 1
    check zones[0].loopIndex == 1
    check zones[0].functionKey == "compute"
    check zones[0].headerLine == 16
    check zones[0].afterLineNumber == zones[0].firstModelLine - 1
    check doc.lines[zones[0].firstModelLine - 1].newNumber == 16
    check zones[0].loopSelectorLabel() == "iteration 1 / 3"
    check not zones[0].canStepBack()
    check zones[0].canStepForward()

  test "a loop the tab does not show gets no control":
    let file = sampleReview().fileNamed("src/main.rs")
    let doc = buildDiffDocument([rowFor(file)])   # the hunk stops at line 11
    check reviewLoopZones(doc, 0, computePlan(file)).len == 0

  test "a function with no loop offers no control":
    let file = sampleReview().fileNamed("src/utils.rs")
    let doc = buildDiffDocument([rowFor(file)])
    let plan = reviewFlowPlan(file, invocationOf(file, "format_output", 0))
    check reviewLoopZones(doc, 0, plan).len == 0

  test "stepping the control changes which pass's values are drawn":
    # The fixture records, on the header line 16:
    #   pass 1  i = 0, acc = 0
    #   pass 2  i = 1, acc = 1
    #   pass 3  i = 2, acc = 3
    let file = sampleReview().fileNamed("src/main.rs")
    let doc = buildDiffDocument([rowSpanning(file, 12, 21)])
    let plan = computePlan(file)
    check reviewValueAnnotations(doc, 0, plan, @[(1, 0)]).chipsAt(16) ==
      @["<i>0", "<acc>0"]
    check reviewValueAnnotations(doc, 0, plan, @[(1, 1)]).chipsAt(16) ==
      @["<i>1", "<acc>1"]
    check reviewValueAnnotations(doc, 0, plan, @[(1, 2)]).chipsAt(16) ==
      @["<i>2", "<acc>3"]
    # The body line 17 ran on the first two passes only, so the third pass
    # leaves it bare rather than repeating the second's values.
    check reviewValueAnnotations(doc, 0, plan, @[(1, 1)]).chipsAt(17) ==
      @["<acc>1"]
    check reviewValueAnnotations(doc, 0, plan, @[(1, 2)]).chipsAt(17).len == 0

  test "lines outside the loop are unaffected by the choice":
    let file = sampleReview().fileNamed("src/main.rs")
    let doc = buildDiffDocument([rowSpanning(file, 12, 21)])
    let plan = computePlan(file)
    for iteration in 0 .. 2:
      check reviewValueAnnotations(doc, 0, plan, @[(1, iteration)]).chipsAt(15) ==
        @["<n>10", "<acc>0"]
      check reviewValueAnnotations(doc, 0, plan, @[(1, iteration)]).chipsAt(19) ==
        @["<acc>55"]

  test "the iteration is clamped rather than wrapped at both ends":
    let file = sampleReview().fileNamed("src/main.rs")
    let doc = buildDiffDocument([rowSpanning(file, 12, 21)])
    let plan = computePlan(file)
    check plan.selectedLoopIteration(1, @[(1, 9)]) == 2
    check plan.selectedLoopIteration(1, @[(1, -3)]) == 0
    check plan.selectedLoopIteration(1, @[]) == 0
    let last = reviewLoopZones(doc, 0, plan, @[(1, 2)])[0]
    check last.iteration == 2
    check last.loopSelectorLabel() == "iteration 3 / 3"
    check last.canStepBack()
    check not last.canStepForward()
    check last.nextIteration(1) == 2
    check last.nextIteration(-1) == 1
    check last.nextIteration(-9) == 0
    # A stale choice from a call that looped further cannot select a pass this
    # one never made.
    check reviewLoopZones(doc, 0, plan, @[(1, 5)])[0].iteration == 2

  test "the reader's loop choice is remembered per file, function and loop":
    clearReviewFlowSelections()
    check reviewLoopIteration("src/main.rs", "compute", 1) == 0
    setReviewLoopIteration("src/main.rs", "compute", 1, 2)
    check reviewLoopIteration("src/main.rs", "compute", 1) == 2
    check reviewLoopIteration("src/main.rs", "compute", 2) == 0
    check reviewLoopIteration("src/main.rs", "main", 1) == 0
    check reviewLoopIteration("src/utils.rs", "compute", 1) == 0
    setReviewLoopIteration("src/main.rs", "compute", 1, -1)
    check reviewLoopIteration("src/main.rs", "compute", 1) == 2
    clearReviewFlowSelections()
    check reviewLoopIteration("src/main.rs", "compute", 1) == 0

suite "the invocation selector is anchored to the code it governs":

  test "the zone sits immediately above the function's first visible line":
    # §7: "a Monaco view zone anchored to the function's lines". Monaco draws a
    # zone AFTER the given line, so the anchor is the line before the first one
    # the function occupies on screen — the arithmetic
    # `createLoopViewZones` uses for the loop slider (`loop.first - 1`).
    let file = sampleReview().fileNamed("src/main.rs")
    let doc = buildDiffDocument([rowFor(file)])
    let zones = reviewInvocationZones(doc, 0, reviewFunctionInvocations(file))
    check zones.len == 1
    check zones[0].functionKey == "main"
    check zones[0].afterLineNumber == zones[0].firstModelLine - 1
    let anchored = doc.lines[zones[0].firstModelLine - 1]
    check anchored.newNumber == 2      # the first line of `main` on screen

  test "a function the tab does not show gets no control":
    # `compute` spans lines 14..25, none of which the fixture's hunk shows. A
    # control detached from its lines is exactly what §7 forbids ("A control in
    # a panel header would be detached from the lines it governs").
    let file = sampleReview().fileNamed("src/main.rs")
    let doc = buildDiffDocument([rowFor(file)])
    let zones = reviewInvocationZones(doc, 0, reviewFunctionInvocations(file))
    for zone in zones:
      check zone.functionKey != "compute"

  test "the control selects the invocation and reads like the loop counter":
    let file = sampleReview().fileNamed("src/main.rs")
    let doc = buildDiffDocument([rowFor(file)])
    let functions = reviewFunctionInvocations(file)
    let first = reviewInvocationZones(doc, 0, functions)[0]
    check first.total == 2
    check first.ordinal == 0
    check first.invocationIndex == 0
    check first.invocationSelectorLabel() == "main: call 1 / 2"
    check not first.canStepBack()
    check first.canStepForward()

    let second = reviewInvocationZones(doc, 0, functions, @[("main", 1)])[0]
    check second.ordinal == 1
    check second.invocationIndex == 1
    check second.invocationSelectorLabel() == "main: call 2 / 2"
    check second.canStepBack()
    check not second.canStepForward()

  test "switching the invocation switches the rendered flow":
    # The milestone's third verification entry, at the layer that decides it:
    # the two calls of `main` visited different lines, so the overlay the tab
    # draws must differ.
    let file = sampleReview().fileNamed("src/main.rs")
    let doc = buildDiffDocument([rowFor(file)])
    let functions = reviewFunctionInvocations(file)
    let firstZone = reviewInvocationZones(doc, 0, functions)[0]
    let secondZone = reviewInvocationZones(doc, 0, functions, @[("main", 1)])[0]

    proc hitLines(zone: ReviewInvocationZone): seq[int] =
      result = @[]
      for decoration in reviewFlowDecorations(
          doc, 0, styledFor(file, zone.invocationIndex)):
        if decoration.inlineClassName == "line-flow-hit":
          result.add(decoration.sourceLine)

    # Call 1 reaches line 10 (`println!("yet another")`); call 2 stops at 4.
    check 10 in firstZone.hitLines()
    check 10 notin secondZone.hitLines()
    check firstZone.hitLines() != secondZone.hitLines()

  test "the ordinal is clamped rather than wrapped at both ends":
    let file = sampleReview().fileNamed("src/main.rs")
    let doc = buildDiffDocument([rowFor(file)])
    let functions = reviewFunctionInvocations(file)
    check reviewInvocationZones(doc, 0, functions, @[("main", 9)])[0].ordinal == 1
    check reviewInvocationZones(doc, 0, functions, @[("main", -4)])[0].ordinal == 0
    let zone = reviewInvocationZones(doc, 0, functions)[0]
    check zone.nextOrdinal(-1) == 0
    check zone.nextOrdinal(1) == 1
    check zone.nextOrdinal(5) == 1

suite "a function the changeset only calls (RV-4 gap 8)":

  test "a recorded-once, called-twice function says so instead of pretending":
    # RV-4 gap 8: `format_output` has `callCount: 2` and one flow entry. A
    # selector offering "call 1 / 2" would render the first invocation twice and
    # claim the second was what the reader is looking at.
    let file = sampleReview().fileNamed("src/utils.rs")
    let doc = buildDiffDocument([rowFor(file)])
    let zones = reviewInvocationZones(doc, 0, reviewFunctionInvocations(file))
    check zones.len == 1
    check zones[0].functionKey == "format_output"
    check zones[0].total == 1
    check zones[0].callCount == 2
    check zones[0].invocationSelectorLabel() ==
      "format_output: call 1 / 1 (2 called, 1 recorded)"
    check not zones[0].canStepForward()
    check not zones[0].canStepBack()

  test "a function with no flow at all is labelled, not silently blank":
    let zone = ReviewInvocationZone(
      functionKey: "helper", total: 0, callCount: 3,
      invocationIndex: NoInvocation)
    check zone.invocationSelectorLabel() ==
      "helper: called 3 times, no flow recorded"
    check not zone.canStepForward()
    check ReviewInvocationZone(functionKey: "helper", total: 0, callCount: 1)
      .invocationSelectorLabel() == "helper: called 1 time, no flow recorded"
    check ReviewInvocationZone(functionKey: "helper")
      .invocationSelectorLabel() == "helper: no flow recorded"

  test "a file with no functions offers no controls":
    let file = sampleReview().fileNamed("src/config.rs")
    let doc = buildDiffDocument([rowFor(file)])
    check reviewInvocationZones(doc, 0, reviewFunctionInvocations(file)).len == 0

suite "the reader's invocation choice is shared by a review's two surfaces":
  ## `ui/review_flow_selection.nim`.  A review shows the same function on the
  ## diff tab and, in Open File mode, on the ordinary editor tab; §7 makes the
  ## displayed invocation a property of the code, so both must draw the same
  ## call or the view-mode toggle would silently change which execution is on
  ## screen.

  setup:
    clearReviewFlowSelections()

  test "an unseen function shows its first invocation":
    check reviewInvocationOrdinal("src/main.rs", "main") == 0

  test "a choice is keyed by file and function, not by either alone":
    setReviewInvocationOrdinal("src/main.rs", "main", 1)
    check reviewInvocationOrdinal("src/main.rs", "main") == 1
    # A different function of the same file, and the same function of a
    # different file, are different questions.
    check reviewInvocationOrdinal("src/main.rs", "compute") == 0
    check reviewInvocationOrdinal("src/utils.rs", "main") == 0

  test "a negative ordinal is refused rather than stored":
    setReviewInvocationOrdinal("src/main.rs", "main", 1)
    setReviewInvocationOrdinal("src/main.rs", "main", -2)
    check reviewInvocationOrdinal("src/main.rs", "main") == 1

  test "the stored choice is what the zones render":
    setReviewInvocationOrdinal("src/main.rs", "main", 1)
    let file = sampleReview().fileNamed("src/main.rs")
    let doc = buildDiffDocument([rowFor(file)])
    let functions = reviewFunctionInvocations(file)
    var ordinals: seq[(string, int)] = @[]
    for fn in functions:
      ordinals.add((fn.functionKey,
                    reviewInvocationOrdinal("src/main.rs", fn.functionKey)))
    let zones = reviewInvocationZones(doc, 0, functions, ordinals)
    check zones[0].ordinal == 1
    check zones[0].invocationIndex == 1
