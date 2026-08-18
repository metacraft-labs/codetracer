## flow_line_styles_test.nim
##
## Headless unit tests for the editor's per-line Omniscience flow classes
## (`src/frontend/ui/flow_line_styles.nim`), which is the body of
## `ui/editor.nim`'s `flowStyleLines`.
##
## Regression target (RV-5, `codetracer-specs/DeepReview/
## Review-Command.milestones.org`): `flowStyleLines` read
##
##     flow.flow.branchesTaken[0][0].table.hasKey(position)
##
## with no bounds and no nil check, while `conditionStyleLines` twelve lines
## below checked all three. `FlowViewUpdate.branchesTaken` is a
## `seq[seq[BranchesTaken]]` whose well-formed-empty shape is guaranteed only by
## the backend's own `FlowViewUpdate::new()` (`src/db-backend/src/task.rs:801`),
## so any window that did not come from there — a partially decoded one, or the
## review-dataset adapter RV-5 adds — turned the expression into an
## `IndexDefect` that aborted `applyEventualStylesLines` before a single
## decoration was applied. This is a latent crash independent of DeepReview and
## is tested here on its own terms.
##
## The suite builds real `FlowViewUpdate` values from `common/types` rather than
## stand-ins, because the shape of that type IS the subject: a test over a mock
## with a differently shaped `branchesTaken` could not express the defect.
##
## Compile and run:
##   nim c -r src/tests/gui/tests/editor/flow_line_styles_test.nim

import std/[strutils, tables, unittest]

import ../../../../common/types as ct
import ../../../../frontend/ui/flow_line_styles

proc windowOver(first, last: int; visited: openArray[int];
                branchesTaken: seq[seq[ct.BranchesTaken]];
                commentLines: openArray[int] = []): ct.FlowViewUpdate =
  ## A flow window spanning `first .. last` in which `visited` lines ran.
  ##
  ## `relevantStepCount` holds *line numbers*, not step counts, despite its
  ## name — `flow_preloader.rs:761` pushes `line` into it.
  ct.FlowViewUpdate(
    location: ct.Location(
      path: "src/main.rs",
      functionFirst: first,
      functionLast: last),
    steps: @[],
    loops: @[],
    branchesTaken: branchesTaken,
    loopIterationSteps: @[],
    relevantStepCount: @visited,
    commentLines: @commentLines)

proc wellFormedEmptyBranches(): seq[seq[ct.BranchesTaken]] =
  ## What `FlowViewUpdate::new()` emits: one outer and one inner element
  ## carrying an empty table.
  @[@[ct.BranchesTaken(table: initTable[int, ct.BranchState]())]]

suite "flowStyleLines survives a malformed branchesTaken":

  test "an empty branchesTaken yields the function's lines instead of raising":
    # THE regression case. Before the guard this raised `IndexDefect: index 0
    # not in 0 .. -1` on the very first line of the loop, so the editor lost
    # every flow decoration rather than one.
    let flow = windowOver(10, 13, visited = [11, 12],
                          branchesTaken = @[])
    # An `IndexDefect` escaping here fails the test, which is precisely how
    # this case failed before the guard.
    let styled = flowStyledLines(flow, finished = true)
    check styled.len == 3
    check styled[0] == FlowStyledLine(position: 11, kind: flskHit)
    check styled[1] == FlowStyledLine(position: 12, kind: flskHit)
    check styled[2] == FlowStyledLine(position: 13, kind: flskSkip)

  test "an outer element with no inner element yields lines instead of raising":
    # The second way `[0][0]` goes out of bounds: the outer seq exists, the
    # inner one is empty. `process_loops` pushes an outer element and its first
    # inner element together, so only a window assembled elsewhere can be in
    # this state — which is exactly the case the guard exists for.
    let flow = windowOver(10, 12, visited = [11],
                          branchesTaken = @[newSeq[ct.BranchesTaken]()])
    let styled = flowStyledLines(flow, finished = true)
    check styled.len == 2
    check styled[0].kind == flskHit
    check styled[1].kind == flskSkip

  test "hasBranchStateAt answers false rather than raising for both shapes":
    check not hasBranchStateAt(newSeq[seq[ct.BranchesTaken]](), 11)
    check not hasBranchStateAt(@[newSeq[ct.BranchesTaken]()], 11)

suite "flowStyleLines over a well-formed window":

  test "a line with a recorded branch state is left to conditionStyleLines":
    # `conditionToLine` paints `flow-taken` / `flow-not-taken` for exactly the
    # lines in this table; painting them here as well would fight over the same
    # line, so they are skipped. That behaviour predates RV-5 and must survive
    # the guard.
    var table = initTable[int, ct.BranchState]()
    table[12] = ct.Taken
    let flow = windowOver(10, 13, visited = [11, 12, 13],
                          branchesTaken = @[@[ct.BranchesTaken(table: table)]])
    let styled = flowStyledLines(flow, finished = true)
    check styled.len == 2
    check styled[0].position == 11
    check styled[1].position == 13

  test "an unfinished window reports unknown, a finished one reports skip":
    let flow = windowOver(10, 12, visited = [11],
                          branchesTaken = wellFormedEmptyBranches())
    let loading = flowStyledLines(flow, finished = false)
    check loading[0] == FlowStyledLine(position: 11, kind: flskHit)
    check loading[1] == FlowStyledLine(position: 12, kind: flskUnknown)
    let finished = flowStyledLines(flow, finished = true)
    check finished[1] == FlowStyledLine(position: 12, kind: flskSkip)

  test "comment lines get no flow class":
    let flow = windowOver(10, 13, visited = [11],
                          branchesTaken = wellFormedEmptyBranches(),
                          commentLines = [12])
    let styled = flowStyledLines(flow, finished = true)
    check styled.len == 2
    check styled[0].position == 11
    check styled[1].position == 13

  test "a nil window yields nothing":
    var flow: ct.FlowViewUpdate = nil
    check flowStyledLines(flow, finished = true).len == 0

  test "the classes are the standard Omniscience ones, and are not comments":
    # DeepReview-GUI.md §7: review flow "must use the standard CodeTracer
    # Omniscience visual style (Monaco decorations with the flow annotation
    # classes)", never a text comment. The class names are asserted literally
    # because they are what `styles/components/flow.styl` styles.
    check flowLineStyleClass(flskHit) == "line-flow-hit"
    check flowLineStyleClass(flskSkip) == "line-flow-skip"
    check flowLineStyleClass(flskUnknown) == "line-flow-unknown"
    for kind in FlowLineStyleKind:
      check "//" notin flowLineStyleClass(kind)
