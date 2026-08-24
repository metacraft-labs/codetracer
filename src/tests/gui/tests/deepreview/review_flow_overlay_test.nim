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
  ## Since UD-2 the diff tab's document holds the whole file anyway, so this is
  ## simply what the tab shows for a file whose lines `first .. last` are all
  ## unchanged — which is where `compute`, the only function in the fixture
  ## that contains a loop, lives. Building the row directly keeps the loop
  ## cases about the loop rather than about which of those lines Monaco has
  ## currently collapsed, which Tests 14-16f already own.
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
    let doc = buildDiffPair([rowFor(file)]).modified
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
    let doc = buildDiffPair([rowFor(file)]).modified
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
    let doc = buildDiffPair([rowFor(file)]).modified
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
    #
    # Since UD-1 this is guaranteed twice over, and both halves are asserted:
    # the overlay still refuses any line whose kind is not added or context,
    # AND the document it is given — the diff editor's *modified* model —
    # structurally cannot contain a removal, because removals are what the
    # *original* model is for.
    let file = sampleReview().fileNamed("src/config.rs")   # deleted file
    let pair = buildDiffPair([rowFor(file)])
    check reviewFlowDecorations(pair.modified, 0, styledFor(file, 0)).len == 0
    for line in pair.modified.lines:
      check line.kind != dlkRemoved
    # The old side is where they went, so the fixture really does carry them
    # and this is not passing because the file has no removals at all.
    var removals = 0
    for line in pair.original.lines:
      if line.kind == dlkRemoved: removals += 1
    check removals > 0
    # And the overlay refuses them even when handed the side that has them.
    check reviewFlowDecorations(pair.original, 0, styledFor(file, 0)).len == 0

  test "the classes are the standard Omniscience ones, never a comment":
    # DeepReview-GUI.md §4.4: "Inline variable values MUST NOT be rendered as
    # text comments"; §7 names the standard classes. This is the guard that
    # replaces the deleted panel's `deepreview-inline-value` after-content
    # decorations.
    let file = sampleReview().fileNamed("src/main.rs")
    let doc = buildDiffPair([rowFor(file)]).modified
    for decoration in reviewFlowDecorations(doc, 0, styledFor(file, 0)):
      check decoration.inlineClassName.startsWith("line-flow-")
      check "deepreview-inline-value" notin decoration.inlineClassName
      check "//" notin decoration.inlineClassName

  test "no flow means no decoration, not a blank overlay":
    let file = sampleReview().fileNamed("src/main.rs")
    let doc = buildDiffPair([rowFor(file)]).modified
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
    let doc = buildDiffPair([rowFor(file)]).modified
    let plan = reviewFlowPlan(file, invocationOf(file, "main", 0))
    let annotations = reviewValueAnnotations(doc, 0, plan)
    check annotations.len > 0
    check annotations.chipsAt(2) == @["<x>10"]
    check annotations.chipsAt(3) == @["<x>10", "<y>20"]
    check annotations.chipsAt(4) == @["<result>55"]
    check annotations.chipsAt(10) == @["<result>55"]

  test "every annotation names the model line holding that source line":
    let file = sampleReview().fileNamed("src/main.rs")
    let doc = buildDiffPair([rowFor(file)]).modified
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
    let doc = buildDiffPair([rowFor(file)]).modified
    let plan = reviewFlowPlan(file, invocationOf(file, "main", 0))
    let annotations = reviewValueAnnotations(doc, 0, plan)
    for annotation in annotations:
      check annotation.sourceLine >= 2
      check annotation.sourceLine <= 11

  test "switching the invocation switches the values, not just the classes":
    # Call 1 computes 55 from x = 10; call 2 computes 903 from x = 42. This is
    # the assertion Test 26's "hit count > 0" cannot make.
    let file = sampleReview().fileNamed("src/main.rs")
    let doc = buildDiffPair([rowFor(file)]).modified
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
    let doc = buildDiffPair([rowFor(file)]).modified
    let plan = reviewFlowPlan(file, invocationOf(file, "format_output", 0))
    let annotations = reviewValueAnnotations(doc, 0, plan)
    check annotations.chipsAt(2) == @["<trimmed>\"hello world\""]
    check annotations.chipsAt(6) == @["<result>\"[hello world]\""]

  test "a truncated value carries the collector's marker":
    let file = sampleReview().fileNamed("src/utils.rs")
    let doc = buildDiffPair([rowFor(file)]).modified
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
    let doc = buildDiffPair([rowFor(file)]).modified
    for text in reviewValueAnnotations(
        doc, 0, reviewFlowPlan(file, invocationOf(file, "main", 0))).chipTexts():
      check "//" notin text
      check " = " notin text

  test "a removed file's lines are never annotated":
    let file = sampleReview().fileNamed("src/config.rs")
    let pair = buildDiffPair([rowFor(file)])
    check reviewValueAnnotations(pair.modified, 0,
                                 reviewFlowPlan(file, 0)).len == 0
    # Handed the side that DOES hold the deleted text, it still refuses.
    check reviewValueAnnotations(pair.original, 0,
                                 reviewFlowPlan(file, 0)).len == 0

  test "a plan that found nothing draws no strip":
    let file = sampleReview().fileNamed("src/main.rs")
    let doc = buildDiffPair([rowFor(file)]).modified
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
    let doc = buildDiffPair([rowSpanning(file, 12, 21)]).modified
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
    let doc = buildDiffPair([rowFor(file)]).modified   # the hunk stops at line 11
    check reviewLoopZones(doc, 0, computePlan(file)).len == 0

  test "a function with no loop offers no control":
    let file = sampleReview().fileNamed("src/utils.rs")
    let doc = buildDiffPair([rowFor(file)]).modified
    let plan = reviewFlowPlan(file, invocationOf(file, "format_output", 0))
    check reviewLoopZones(doc, 0, plan).len == 0

  test "stepping the control changes which pass's values are drawn":
    # The fixture records, on the header line 16:
    #   pass 1  i = 0, acc = 0
    #   pass 2  i = 1, acc = 1
    #   pass 3  i = 2, acc = 3
    let file = sampleReview().fileNamed("src/main.rs")
    let doc = buildDiffPair([rowSpanning(file, 12, 21)]).modified
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
    let doc = buildDiffPair([rowSpanning(file, 12, 21)]).modified
    let plan = computePlan(file)
    for iteration in 0 .. 2:
      check reviewValueAnnotations(doc, 0, plan, @[(1, iteration)]).chipsAt(15) ==
        @["<n>10", "<acc>0"]
      check reviewValueAnnotations(doc, 0, plan, @[(1, iteration)]).chipsAt(19) ==
        @["<acc>55"]

  test "the iteration is clamped rather than wrapped at both ends":
    let file = sampleReview().fileNamed("src/main.rs")
    let doc = buildDiffPair([rowSpanning(file, 12, 21)]).modified
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
    let doc = buildDiffPair([rowFor(file)]).modified
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
    let doc = buildDiffPair([rowFor(file)]).modified
    let zones = reviewInvocationZones(doc, 0, reviewFunctionInvocations(file))
    for zone in zones:
      check zone.functionKey != "compute"

  test "the control selects the invocation and reads like the loop counter":
    let file = sampleReview().fileNamed("src/main.rs")
    let doc = buildDiffPair([rowFor(file)]).modified
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
    let doc = buildDiffPair([rowFor(file)]).modified
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
    let doc = buildDiffPair([rowFor(file)]).modified
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
    let doc = buildDiffPair([rowFor(file)]).modified
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
    let doc = buildDiffPair([rowFor(file)]).modified
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
    let doc = buildDiffPair([rowFor(file)]).modified
    let functions = reviewFunctionInvocations(file)
    var ordinals: seq[(string, int)] = @[]
    for fn in functions:
      ordinals.add((fn.functionKey,
                    reviewInvocationOrdinal("src/main.rs", fn.functionKey)))
    let zones = reviewInvocationZones(doc, 0, functions, ordinals)
    check zones[0].ordinal == 1
    check zones[0].invocationIndex == 1

# ---------------------------------------------------------------------------
# UD-3: the parallel value columns the debugger's own Omniscience view uses
# ---------------------------------------------------------------------------

proc columnChips(annotations: seq[ReviewValueAnnotation];
                 sourceLine: int): seq[seq[string]] =
  ## Every column of one line, each as the chips a reader sees in it.
  ##
  ## A column with no chips is kept as an empty seq rather than dropped: an
  ## empty column is how a pass that skipped the line keeps its place in the
  ## band, and dropping it would silently slide the next pass's values under
  ## the wrong heading.
  result = @[]
  for annotation in annotations:
    if annotation.sourceLine != sourceLine:
      continue
    for column in annotation.columns:
      var chips: seq[string] = @[]
      for chip in column.values:
        chips.add(reviewValueChipName(chip) & chip.text)
      result.add(chips)

suite "the values are laid out in the flow view's parallel columns (UD-3)":
  ## UD-3: "The parallel value columns the flow feature uses, rather than
  ## RV-5's single strip."
  ##
  ## The debugger's `ui/flow.renderFlow` draws one `.flow-parallel-values`
  ## column per loop iteration, side by side, starting at the iteration the
  ## slider names (`if index < self.selectedIndex: continue`). These cases pin
  ## the same shape on the review's side of the same DOM.

  proc computePlan(file: ct.DeepReviewFileData): ReviewFlowPlan =
    reviewFlowPlan(file, invocationOf(file, "compute", 0))

  test "a loop body line carries one column per recorded pass":
    let file = sampleReview().fileNamed("src/main.rs")
    let doc = buildDiffPair([rowSpanning(file, 12, 21)]).modified
    let plan = computePlan(file)
    let annotations = reviewValueAnnotations(doc, 0, plan, @[(1, 0)], 3)
    check annotations.columnChips(16) == @[
      @["<i>0", "<acc>0"],
      @["<i>1", "<acc>1"],
      @["<i>2", "<acc>3"]]

  test "each column names the pass it belongs to":
    let file = sampleReview().fileNamed("src/main.rs")
    let doc = buildDiffPair([rowSpanning(file, 12, 21)]).modified
    let plan = computePlan(file)
    var seen: seq[int] = @[]
    var selected: seq[bool] = @[]
    for annotation in reviewValueAnnotations(doc, 0, plan, @[(1, 1)], 3):
      if annotation.sourceLine != 16:
        continue
      for column in annotation.columns:
        seen.add(column.iteration)
        selected.add(column.selected)
    # Starting at the selected pass, exactly as `renderFlow` skips every
    # iteration below `selectedIndex`.
    check seen == @[1, 2]
    check selected == @[true, false]

  test "a line outside any loop carries exactly one column":
    let file = sampleReview().fileNamed("src/main.rs")
    let doc = buildDiffPair([rowSpanning(file, 12, 21)]).modified
    let plan = computePlan(file)
    let annotations = reviewValueAnnotations(doc, 0, plan, @[(1, 0)], 3)
    check annotations.columnChips(15) == @[@["<n>10", "<acc>0"]]
    for annotation in annotations:
      if annotation.sourceLine != 15:
        continue
      check annotation.columns.len == 1
      check annotation.columns[0].iteration == -1
      check annotation.columns[0].selected

  test "a pass that skipped the line leaves an empty column, not another pass's values":
    # Line 17 ran on the first two passes only. Its third column must be empty
    # — the property RV-5 established, now stated per column rather than per
    # line, because a band that silently dropped the empty column would put
    # pass 2's values under pass 3's heading.
    let file = sampleReview().fileNamed("src/main.rs")
    let doc = buildDiffPair([rowSpanning(file, 12, 21)]).modified
    let plan = computePlan(file)
    check reviewValueAnnotations(doc, 0, plan, @[(1, 0)], 3).columnChips(17) ==
      @[@["<acc>0"], @["<acc>1"], newSeq[string]()]

  test "a line the invocation never executed carries no columns at all":
    let file = sampleReview().fileNamed("src/main.rs")
    let doc = buildDiffPair([rowFor(file)]).modified
    let secondCall = reviewValueAnnotations(
      doc, 0, reviewFlowPlan(file, invocationOf(file, "main", 1)), @[], 4)
    for annotation in secondCall:
      if annotation.sourceLine == 10:
        check false      # line 10 belongs to the first call only
    check secondCall.columnChips(10).len == 0

  test "the selected column is what the single-strip readers still see":
    # `values` remains the selected pass's chips, so every caller written
    # against the RV-5 shape keeps working while the band is built from
    # `columns`.
    let file = sampleReview().fileNamed("src/main.rs")
    let doc = buildDiffPair([rowSpanning(file, 12, 21)]).modified
    let plan = computePlan(file)
    for iteration in 0 .. 2:
      let annotations =
        reviewValueAnnotations(doc, 0, plan, @[(1, iteration)], 3)
      for annotation in annotations:
        var selectedChips: seq[ReviewValueChip] = @[]
        for column in annotation.columns:
          if column.selected:
            selectedChips = column.values
        check selectedChips == annotation.values

  test "asking for one column reproduces the single strip exactly":
    let file = sampleReview().fileNamed("src/main.rs")
    let doc = buildDiffPair([rowSpanning(file, 12, 21)]).modified
    let plan = computePlan(file)
    for iteration in 0 .. 2:
      let one = reviewValueAnnotations(doc, 0, plan, @[(1, iteration)], 1)
      check one.chipsAt(16) ==
        reviewValueAnnotations(doc, 0, plan, @[(1, iteration)]).chipsAt(16)
      for annotation in one:
        check annotation.columns.len == 1

suite "the band is sized so a column is never sheared (UD-3)":
  ## Every reviewer of UD-1 and UD-2 reported the value chips cut off at the
  ## pane's right edge. The band answers it the way the debugger's does: it is
  ## laid out past the longest line, and it draws only as many columns as the
  ## remaining width holds — so the last column drawn is whole.

  test "the band starts past the longest line, at the debugger's own gap":
    # `ui/flow.flowLoopBackgroundStyle` puts the values at
    # `maxFlowLineWidth + distanceToSource`; `distanceToSource` is 50.
    check reviewValueBandLeftPx(320.0) == 370.0
    check reviewValueBandLeftPx(0.0) == 50.0

  test "a pane that cannot pay the debugger's gap pays a smaller one":
    # The order of surrender: whitespace first, then the placement. The gap is
    # empty space — shrinking it moves no code, hides no line and drops no
    # chip, and the offset is still ONE number for every band, so the left rail
    # a reader scans down is untouched.
    #
    # Measured on `sample-review.json` at 1920x1080: content 519px, the longest
    # annotated line ends at 259px, the widest column needs 240px. The
    # debugger's gap would put the band at 309 and the column's right edge at
    # 549 — thirty pixels past the pane. At 279 it ends exactly at 519.
    check reviewValueBandLeftPx(259.0, 519.0, 240.0) == 279.0
    # Where the pane can pay, it pays: the debugger's number, unchanged.
    check reviewValueBandLeftPx(259.0, 900.0, 240.0) == 309.0
    check reviewValueBandLeftPx(259.0, 549.0, 240.0) == 309.0

  test "the gap never shrinks to nothing, and never runs backwards":
    # A band drawn ON the code it annotates is the failure two reviewers
    # reported of an earlier round ("chips drawn directly on top of the code
    # glyphs at the same baseline"), so the offset stops at a readable
    # separation and the tab takes the row-below placement instead.
    check reviewValueBandLeftPx(259.0, 400.0, 240.0) ==
      259.0 + ReviewValueBandMinGapPx
    check reviewValueBandLeftPx(259.0, 0.0, 240.0) ==
      259.0 + ReviewValueBandMinGapPx
    # …and at that offset the column does not fit, which is what sends the tab
    # to the row-below placement rather than drawing it past the edge.
    check not reviewValueBandFitsBeside(
      400.0, reviewValueBandLeftPx(259.0, 400.0, 240.0), 240.0)
    check reviewValueBandFitsBeside(
      519.0, reviewValueBandLeftPx(259.0, 519.0, 240.0), 240.0)

  test "a pane with no room beside the code says so before a band is placed":
    # Measured in the design corpus: the modified editor's content area is
    # 541px and the reviewed file's own annotated lines reach 495px of it, so
    # the band would start at 545 — four pixels PAST the pane. The answer is
    # taken once, for the tab, rather than by clamping each band back to the
    # edge, which is what shears a column.
    check not reviewValueBandFitsBeside(541.0, 545.0, 120.0)
    check not reviewValueBandFitsBeside(541.0, 470.0, 120.0)
    check reviewValueBandFitsBeside(541.0, 309.0, 120.0)

  test "the room needed is the column a line actually needs, not a floor":
    # THE UD-3 DEFECT, in the running product's own numbers.
    #
    # Measured on `sample-review.json` at 1920x1080: the modified editor's
    # content area is 519px, the band is placed at 309px — so 210px of room —
    # the character advance is 9.6px, and the widest annotated line's column
    # needs 25 characters, which is 240px.
    #
    # The shipped arithmetic asked only for `ReviewValueBandMinColumnChars`
    # (12) characters, said yes, and the column was then drawn at its full
    # 230px from x=618 to x=848 against a pane whose right edge is 829. It also
    # cost a recorded value: the chips were budgeted at `210 / 9.6 = 21`
    # characters against a 24-character column, so `<y> 20` was replaced by an
    # ellipsis and left the screen entirely.
    check not reviewValueBandFitsBeside(519.0, 309.0, 240.0)
    # The old floor — `ReviewValueBandMinColumnChars` (12) characters, 115.2px
    # at this advance — is comfortably inside the same 210px of room, which is
    # exactly why it answered yes to a pane that could not hold the column.
    check reviewValueBandFitsBeside(519.0, 309.0, 12.0 * 9.6)
    # And the boundary is exact: a column that fits to the pixel is placed.
    check reviewValueBandFitsBeside(519.0, 309.0, 210.0)
    check not reviewValueBandFitsBeside(519.0, 309.0, 210.1)

  test "an unmeasured pane never claims there is room":
    # Before the first layout `getLayoutInfo().contentWidth` is 0. Answering
    # "yes" there would place every band against a width that does not exist.
    check not reviewValueBandFitsBeside(0.0, 50.0, 120.0)
    check not reviewValueBandFitsBeside(-10.0, 50.0, 120.0)

  test "a tab with nothing to place does not claim a placement":
    # No annotations means no column width, and answering "yes" would commit
    # every band of a later repaint to a decision taken against zero.
    check not reviewValueBandFitsBeside(541.0, 100.0, 0.0)
    check not reviewValueBandFitsBeside(541.0, 100.0, -8.0)

  test "the width the tab is measured against is its widest line's column":
    # One decision for the tab, so it is the widest annotated line that decides
    # — not the first, and not each line for itself, which would give a tab
    # with two left rails.
    let narrow = ReviewValueAnnotation(columns: @[
      ReviewValueColumn(values: @[ReviewValueChip(name: "i", text: "0")])])
    let wide = ReviewValueAnnotation(columns: @[
      ReviewValueColumn(values: @[
        ReviewValueChip(name: "contribution", text: "0")])])
    check reviewWidestColumnChars([narrow]) == 4 + ReviewValueChipChromeChars
    check reviewWidestColumnChars([narrow, wide]) ==
      15 + ReviewValueChipChromeChars
    check reviewWidestColumnChars([wide, narrow]) ==
      15 + ReviewValueChipChromeChars
    # An empty tab has no width to be measured against at all, which
    # `reviewValueBandFitsBeside` reads as "do not place beside".
    check reviewWidestColumnChars([]) == 0
    check reviewWidestColumnChars([ReviewValueAnnotation(columns: @[])]) == 0

  test "the column width is the line's widest pass, and the same for all of it":
    # `FlowComponent.calculatePositionMaxWidth` sizes a loop's columns from the
    # widest step at that position; a band whose columns changed width from
    # pass to pass could not be read across.
    let file = sampleReview().fileNamed("src/main.rs")
    let doc = buildDiffPair([rowSpanning(file, 12, 21)]).modified
    let plan = reviewFlowPlan(file, invocationOf(file, "compute", 0))
    for annotation in reviewValueAnnotations(doc, 0, plan, @[(1, 0)], 3):
      if annotation.sourceLine != 16:
        continue
      # The widest pass is `<i>2 <acc>3`: four characters of text in the first
      # chip and six in the second, each plus `ReviewValueChipChromeChars` of
      # padding and margin.
      check annotation.columns.len == 3
      check reviewColumnWidthChars(annotation) ==
        (4 + ReviewValueChipChromeChars) + (6 + ReviewValueChipChromeChars)

  test "a narrow line of a loop is not widened by a wide one":
    # A DELIBERATE departure from the debugger, recorded because it was tried
    # the other way and measured.
    #
    # `FlowComponent.calculatePositionMaxWidth` raises
    # `loopState.defaultIterationWidth` over EVERY position of the loop, so the
    # debugger draws one width for all of a loop's lines and pass 2 starts at
    # the same x down the whole loop. That was implemented here, and in a 461px
    # review band the single width is the WIDEST line's — so every line of the
    # loop fitted exactly one pass and the parallel columns, the deliverable
    # this milestone is about, stopped appearing anywhere. A fresh reviewer of
    # that build rated it 2/10 for exactly that.
    #
    # The debugger can afford it because it narrows the neighbours of the
    # selected iteration (`shrinkedLoopColumnMinWidth`) and owns a whole
    # editor. Without either, per line is what keeps the narrow lines showing
    # their passes; the `+N` marker says what the wide ones are hiding.
    let header = ReviewValueAnnotation(sourceLine: 16, loop: 1, columns: @[
      ReviewValueColumn(values: @[ReviewValueChip(name: "i", text: "0")]),
      ReviewValueColumn(values: @[ReviewValueChip(name: "i", text: "1")])])
    let body = ReviewValueAnnotation(sourceLine: 17, loop: 1, columns: @[
      ReviewValueColumn(values: @[
        ReviewValueChip(name: "contribution", text: "0")])])
    check reviewColumnWidthChars(header) == 4 + ReviewValueChipChromeChars
    check reviewColumnWidthChars(body) == 15 + ReviewValueChipChromeChars
    # Which is what lets the narrow line draw both of its passes in a band the
    # wide line can only draw one pass in.
    const charWidth = 9.6
    let available = 300.0
    check reviewVisibleColumnCount(
      available, float(reviewColumnWidthChars(header)) * charWidth,
      header.columns.len) == 2
    check reviewVisibleColumnCount(
      available, float(reviewColumnWidthChars(body)) * charWidth,
      body.columns.len) == 1

  test "a column too wide for the pane drops whole chips, never half of one":
    # Squeezing was tried and measured: three fresh reviewers rated the result
    # 3/10, all three naming the same cause — a squeezed chip clips its own
    # value, so the row reads as a name with no value.
    let chips = @[
      ReviewValueChip(name: "contribution", text: "0"),   # <contribution>0 -> 22
      ReviewValueChip(name: "i", text: "0"),              # <i>0            -> 11
      ReviewValueChip(name: "total", text: "0"),          # <total>0        -> 15
      ReviewValueChip(name: "x", text: "5")]              # <x>5            -> 11
    check reviewChipWidthChars(chips[0]) == 22
    check reviewChipsThatFit(chips, 200) == 4
    check reviewChipsThatFit(chips, 48) == 3     # 22 + 11 + 15 = 48
    check reviewChipsThatFit(chips, 47) == 2
    check reviewChipsThatFit(chips, 33) == 2     # 22 + 11
    check reviewChipsThatFit(chips, 32) == 1

  test "a single chip too wide for the pane is drawn whole anyway":
    # Drawing nothing reads as "this pass recorded nothing", which is a
    # different and false statement — the same rule the column count follows.
    let chips = @[ReviewValueChip(name: "configuration", text: "{...}")]
    check reviewChipsThatFit(chips, 1) == 1
    check reviewChipsThatFit(chips, 0) == 1
    check reviewChipsThatFit(chips, -5) == 1

  test "an empty column asks for no chips at all":
    check reviewChipsThatFit(@[], 100) == 0

  test "a column is never narrower than a heading":
    # A column whose only pass recorded nothing still reserves a readable
    # width, so the band's columns stay in step across the loop's lines.
    check reviewColumnWidthChars(
      ReviewValueAnnotation(columns: @[ReviewValueColumn(values: @[])])) == 10
    check reviewColumnWidthChars(ReviewValueAnnotation(columns: @[])) == 10
    # A column that does carry a chip is as wide as the chip.
    check reviewColumnWidthChars(ReviewValueAnnotation(columns: @[
      ReviewValueColumn(values: @[ReviewValueChip(name: "i", text: "0")])])) ==
      4 + ReviewValueChipChromeChars

  test "a band with no room for even one column still draws one":
    # Drawing nothing would read as "this line was never executed", which is a
    # different and false statement.
    check reviewVisibleColumnCount(0.0, 120.0, 5) == 1
    check reviewVisibleColumnCount(-40.0, 120.0, 5) == 1

  test "only whole columns are drawn":
    check reviewVisibleColumnCount(360.0, 120.0, 5) == 3
    check reviewVisibleColumnCount(359.0, 120.0, 5) == 2
    check reviewVisibleColumnCount(480.0, 120.0, 5) == 4

  test "the count never exceeds the passes the invocation recorded":
    check reviewVisibleColumnCount(2400.0, 120.0, 3) == 3
    check reviewVisibleColumnCount(2400.0, 120.0, 0) == 1

  test "a column with no measurable width does not divide by zero":
    check reviewVisibleColumnCount(480.0, 0.0, 5) == 1
    check reviewVisibleColumnCount(480.0, -12.0, 5) == 1

  test "the marker that says passes were dropped is never bought with a pass":
    # It comes out of the room the columns leave over, so a band whose columns
    # tile it exactly draws no marker rather than dropping a recorded pass to
    # make room for a glyph saying a pass was dropped.
    #
    # 390px of room, three 120px columns = 360, 30px left over: the marker
    # fits.
    check reviewMorePassesMarkerFits(390.0, 120.0, 3, 30.0)
    check not reviewMorePassesMarkerFits(389.0, 120.0, 3, 30.0)
    # The measured fixture's tight case: two 230.4px columns in a 461.4px band
    # leave 0.6px, which holds nothing.
    check not reviewMorePassesMarkerFits(461.4, 230.4, 2, 28.8)
    # And the case the reviewer actually complained about — a WIDE column, so
    # few of them fit and the leftover is large — does hold it.
    check reviewMorePassesMarkerFits(461.4, 210.0, 2, 28.8)
    # Degenerate inputs never claim room.
    check not reviewMorePassesMarkerFits(390.0, 120.0, 3, 0.0)
    check not reviewMorePassesMarkerFits(390.0, 120.0, 0, 30.0)
    check not reviewMorePassesMarkerFits(390.0, 0.0, 3, 30.0)

  test "a column is never drawn wider than the room its band has":
    # THE COMPANION TO "at least one column always".
    #
    # The floor is right — a band with no columns reads as "this line never
    # executed" — but on its own it is how a column too wide for the pane was
    # drawn anyway, at its full natural width, 20px past the pane's edge on the
    # measured fixture. The floor keeps the column; this decides how wide the
    # kept column may be.
    #
    # The measured case: a 24-character column against 210px of room at a
    # 9.6px advance, which is 21 characters.
    check reviewDrawnColumnChars(24, 210.0, 9.6) == 21
    check float(reviewDrawnColumnChars(24, 210.0, 9.6)) * 9.6 <= 210.0
    # Room to spare changes nothing: a column is drawn at the width it needs.
    check reviewDrawnColumnChars(24, 480.0, 9.6) == 24
    check reviewDrawnColumnChars(24, 230.4, 9.6) == 24
    # Never zero, and never negative, whatever it is asked.
    check reviewDrawnColumnChars(24, 4.0, 9.6) == 1
    check reviewDrawnColumnChars(0, 480.0, 9.6) == 1
    check reviewDrawnColumnChars(-3, 480.0, 9.6) == 1

  test "an unmeasured band clamps nothing rather than clamping to zero":
    # Before the first layout there is no width to clamp against. The natural
    # width is the honest answer; the repaint that follows the layout has a
    # real one.
    check reviewDrawnColumnChars(24, 0.0, 9.6) == 24
    check reviewDrawnColumnChars(24, -40.0, 9.6) == 24
    check reviewDrawnColumnChars(24, 480.0, 0.0) == 24
    check reviewDrawnColumnChars(24, 480.0, -1.0) == 24

  test "the drawn column and the chips inside it are measured in one number":
    # The second half of the UD-3 defect, and the reason it dropped a recorded
    # value. The budget used to be `available / charWidth div visible` — 21
    # characters against a 24-character column on the measured fixture — so a
    # column that was drawn at its FULL width had its last chip replaced by an
    # ellipsis. `<y> 20` was gone from the screen, which Test 29 caught.
    #
    # Now the box and the budget are the same number, so a column drawn at its
    # natural width holds every chip it was sized for. Asserted as the property
    # rather than as an arithmetic coincidence: for any column, drawing it in
    # the room it asked for loses nothing.
    let chips = @[
      ReviewValueChip(name: "x", text: "10"),
      ReviewValueChip(name: "y", text: "20")]
    let annotation = ReviewValueAnnotation(
      columns: @[ReviewValueColumn(values: chips)])
    let natural = reviewColumnWidthChars(annotation)
    # `<x>` is three characters (`reviewValueChipName` brackets the name) and
    # `10` is two, plus the chip's own chrome; twice, for the two chips.
    check natural == 2 * (3 + 2 + ReviewValueChipChromeChars)
    let drawn = reviewDrawnColumnChars(natural, 480.0, 9.6)
    check drawn == natural
    check reviewChipsThatFit(chips, drawn) == chips.len
    # And when the pane genuinely cannot hold the column, chips drop — whole
    # ones, and the marker says so. That is the honest half, kept.
    let squeezed = reviewDrawnColumnChars(natural, 210.0, 9.6)
    check squeezed < natural
    check reviewChipsThatFit(chips, squeezed) < chips.len

  test "the pane's own measurements never place anything past its edge":
    # The end-to-end arithmetic of `applyFlowValueBands`, over the fixture's
    # measured geometry, asserted as the invariant the Playwright case
    # "UD-3: no value column is drawn past the pane's right edge" measures:
    # whatever the branch taken, the drawn columns plus the marker fit.
    const
      contentWidth = 519.0
      charWidth = 9.6
      maxLineOffset = 259.0
    let annotation = ReviewValueAnnotation(columns: @[
      ReviewValueColumn(values: @[
        ReviewValueChip(name: "i", text: "0"),
        ReviewValueChip(name: "acc", text: "0")]),
      ReviewValueColumn(values: @[
        ReviewValueChip(name: "i", text: "1"),
        ReviewValueChip(name: "acc", text: "1")]),
      ReviewValueColumn(values: @[
        ReviewValueChip(name: "i", text: "2"),
        ReviewValueChip(name: "acc", text: "3")])])
    let widest = float(reviewWidestColumnChars([annotation])) * charWidth
    let bandLeft = reviewValueBandLeftPx(maxLineOffset, contentWidth, widest)
    let beside = reviewValueBandFitsBeside(contentWidth, bandLeft, widest)
    # The band clears the code it annotates in either placement.
    check (not beside) or bandLeft >= maxLineOffset + ReviewValueBandMinGapPx
    let lineLeft = if beside: bandLeft else: 0.0
    let prefix =
      if beside: 0.0 else: ReviewValueBandLinePrefixChars * charWidth
    let available = contentWidth - lineLeft - prefix
    let drawnChars = reviewDrawnColumnChars(
      reviewColumnWidthChars(annotation), available, charWidth)
    let columnWidth = float(drawnChars) * charWidth
    let marker = float(ReviewValueMorePassesChars) * charWidth
    let visible = reviewVisibleColumnCount(
      available, columnWidth, annotation.columns.len)
    let markerFits = reviewMorePassesMarkerFits(
      available, columnWidth, visible, marker)
    let drawnWidth =
      float(visible) * columnWidth +
      (if visible < annotation.columns.len and markerFits: marker else: 0.0)
    check drawnWidth <= available
    check lineLeft + prefix + drawnWidth <= contentWidth
    # And the chips inside every drawn column are whole ones.
    for column in annotation.columns:
      check reviewChipsThatFit(column.values, drawnChars) >= 1
