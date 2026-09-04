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
  @[@[ct.BranchesTaken(table: initTable[int, ct.BranchState](),
                       extents: initTable[int, ct.BranchExtent]())]]

proc armsOf(states: openArray[(int, ct.BranchState)];
            extents: openArray[(int, ct.BranchExtent)]):
    seq[seq[ct.BranchesTaken]] =
  ## The outer branch table: what the run did with each arm, and which lines
  ## each arm occupies.
  ##
  ## Both keyed on the arm's HEADER line, which is how the backend keys them
  ## (`expr_loader.rs`, `load_branch_for_position` / `final_branch_load` /
  ## `branch_extents` all insert on `header_line`).
  var stateTable = initTable[int, ct.BranchState]()
  for (header, state) in states:
    stateTable[header] = state
  var extentTable = initTable[int, ct.BranchExtent]()
  for (header, extent) in extents:
    extentTable[header] = extent
  @[@[ct.BranchesTaken(table: stateTable, extents: extentTable)]]

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
    # Line 13 earns no entry: it is not in an arm shown to have been declined —
    # this window records no arms at all — so nothing is claimed about it. That
    # it did not run is not, by itself, a reason to dim it.
    check styled.len == 2
    check styled[0] == FlowStyledLine(position: 11, kind: flskHit)
    check styled[1] == FlowStyledLine(position: 12, kind: flskHit)

  test "an outer element with no inner element yields lines instead of raising":
    # The second way `[0][0]` goes out of bounds: the outer seq exists, the
    # inner one is empty. `process_loops` pushes an outer element and its first
    # inner element together, so only a window assembled elsewhere can be in
    # this state — which is exactly the case the guard exists for.
    let flow = windowOver(10, 12, visited = [11],
                          branchesTaken = @[newSeq[ct.BranchesTaken]()])
    let styled = flowStyledLines(flow, finished = true)
    check styled.len == 1
    check styled[0] == FlowStyledLine(position: 11, kind: flskHit)

  test "hasBranchStateAt answers false rather than raising for both shapes":
    check not hasBranchStateAt(newSeq[seq[ct.BranchesTaken]](), 11)
    check not hasBranchStateAt(@[newSeq[ct.BranchesTaken]()], 11)

  test "insideUntakenBranch answers false rather than raising for both shapes":
    # The same three ways the outer table can be unreadable, asked of the proc
    # that now decides dimming. It reads `[0][0]` exactly as `hasBranchStateAt`
    # does, so it inherits exactly the same crash if it is not guarded — and a
    # raise here aborts `applyEventualStylesLines` before any decoration is
    # applied, which is the RV-5 failure this file exists for.
    check not insideUntakenBranch(newSeq[seq[ct.BranchesTaken]](), 11)
    check not insideUntakenBranch(@[newSeq[ct.BranchesTaken]()], 11)

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

  test "a window that records no branch at all dims nothing, loading or not":
    # This replaces "an unfinished window reports unknown, a finished one
    # reports skip", which encoded the rule the user reported as a defect.
    #
    # `finished` is no longer consulted, and the pair below is how that is
    # stated rather than assumed. It was never a working safeguard in any case:
    # `FlowUpdate::new` sets `finished: false` and the only `true` in the crate
    # is `FlowUpdate::error`, so live replay always took the `flskUnknown` arm —
    # and `line-flow-unknown` and `line-flow-skip` are both `opacity: 0.5`, so
    # the downgrade was real in the data and invisible on screen.
    let flow = windowOver(10, 12, visited = [11],
                          branchesTaken = wellFormedEmptyBranches())
    for finished in [false, true]:
      let styled = flowStyledLines(flow, finished = finished)
      check styled == @[FlowStyledLine(position: 11, kind: flskHit)]

  test "comment lines get no flow class":
    let flow = windowOver(10, 13, visited = [11],
                          branchesTaken = wellFormedEmptyBranches(),
                          commentLines = [12])
    let styled = flowStyledLines(flow, finished = true)
    check styled == @[FlowStyledLine(position: 11, kind: flskHit)]

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

suite "dimming means the run declined a branch":
  ## The rule, from the user and now from
  ## `codetracer-specs/GUI/Debugging-Features/Omniscience-Flow.md`
  ## § *Dimming means "the run did not take this branch"*:
  ##
  ##   > A source line is dimmed when, and only when, it belongs to a branch of
  ##   > a conditional that the recorded run did not enter. Not having executed
  ##   > is not, by itself, a reason to dim a line.
  ##
  ## Reported as: "I jump into a function and all of its lines before the
  ## current line get dimmed."
  ##
  ## THE WINDOW BELOW IS `test-programs/noir_space_ship/src/shield.nr`'s
  ## `calculate_damage`, lines 22-38, on a pass that takes the `else` arm —
  ## the fixture the GUI-level assertion in
  ## `dimming_marks_only_untaken_branches.spec.ts` drives. Modelling a real
  ## function rather than an abstract range matters here: the failing line is a
  ## continuation line, and only a real function has one.
  ##
  ## WHY BOTH HALVES ARE ASSERTED. A test that only forbids dimming is
  ## satisfied by never dimming anything, which would delete the feature rather
  ## than correct it. The pair says what dimming IS, not merely what it is not.

  ## THE ARMS OF `calculate_damage`, as the backend now reports them.
  ##
  ##   28 |     if(shield_pct == 100){     <- header, `code_first_line` 29
  ##   29 |         damage = 0;            <- the `if` arm's interior
  ##   30 |     }                          <- `code_last_line`
  ##   31 |     else{                      <- header, `code_first_line` 32
  ##   32 |         damage = ...;          <- the `else` arm's interior
  ##   33 |     }                          <- `code_last_line`
  const
    IfHeader = 28
    IfArm = ct.BranchExtent(firstLine: 29, lastLine: 30)
    ElseHeader = 31
    ElseArm = ct.BranchExtent(firstLine: 32, lastLine: 33)

  proc calculateDamageWindow(
      ifState = ct.NotTaken; elseState = ct.Taken;
      shipExtents = true): ct.FlowViewUpdate =
    ## By default: `shield_pct != 100`, so the `else` at 31 ran and the `if` at
    ## 28 did not.
    ##
    ## Line 26 is `let shield_pct = calculate_remaining_shield_pct(` and line 27
    ## its continuation — one statement over two lines, which is why only 26
    ## carries a step. Line 27 is not a conditional, is not an arm of one, and
    ## is not inside one.
    ##
    ## `visited` is the SAME on every call, whatever the arms are set to. That
    ## is the point of the parameters: it makes the branch state the only
    ## variable, so an assertion that changes its answer with them is reading
    ## the branch state, and one that does not is reading the step set.
    let extents =
      if shipExtents: @[(IfHeader, IfArm), (ElseHeader, ElseArm)]
      else: newSeq[(int, ct.BranchExtent)]()
    windowOver(22, 38,
               visited = [26, 28, 31, 32, 34, 37],
               branchesTaken = armsOf(
                 states = [(IfHeader, ifState), (ElseHeader, elseState)],
                 extents = extents))

  proc kindAt(styled: seq[FlowStyledLine], position: int): FlowLineStyleKind =
    for s in styled:
      if s.position == position:
        return s.kind
    raise newException(ValueError, "no style computed for line " & $position)

  proc isDimmed(styled: seq[FlowStyledLine], position: int): bool =
    ## `line-flow-skip` and `line-flow-unknown` are both `opacity: 0.5`
    ## (`styles/components/flow.styl`), so the reader sees one state. Treating
    ## them as two here would let a fix that only renames the class pass.
    ##
    ## A line with NO entry is not dimmed: no decoration is applied to it at
    ## all, which is how "nothing is claimed about this line" reaches the
    ## screen.
    for s in styled:
      if s.position == position:
        return s.kind in {flskSkip, flskUnknown}
    false

  test "a line that is in no conditional is not dimmed for lacking a step":
    let styled = flowStyledLines(calculateDamageWindow(), finished = true)
    # Line 27 continues the statement begun on line 26. That statement ran —
    # every path into `calculate_damage` runs it — so nothing about line 27
    # was declined. It carries no step of its own only because a step is
    # recorded per statement, not per line.
    check not isDimmed(styled, 27)

  test "a line inside the arm the run did not enter IS dimmed":
    # The other half. Line 29 is the interior of the `if` at 28, and 28 is
    # `NotTaken`, so 29 belongs to a branch the run declined. This is the case
    # dimming exists for, and it must survive the fix for the case above.
    let styled = flowStyledLines(calculateDamageWindow(), finished = true)
    check isDimmed(styled, 29)

  test "the same line, dimmed or not, according to the arm it is in":
    # THE DISCRIMINATING PAIR, and the reason the test above is not enough on
    # its own. Line 29 has no step of its own in EITHER reading — `visited` is
    # identical — so the old rule dimmed it both times and the assertion above
    # passed for a reason that had nothing to do with branches. Here the arm
    # states are swapped and nothing else is, so an implementation still keyed
    # on `relevantStepCount` gives the same answer twice and fails.
    let declined = flowStyledLines(
      calculateDamageWindow(ifState = ct.NotTaken, elseState = ct.Taken),
      finished = true)
    let entered = flowStyledLines(
      calculateDamageWindow(ifState = ct.Taken, elseState = ct.NotTaken),
      finished = true)

    check isDimmed(declined, 29)          # the `if` arm was declined
    check not isDimmed(entered, 29)       # the same line; this time it ran
    check not isDimmed(declined, 32)      # the `else` arm ran
    check isDimmed(entered, 32)           # the same line; this time declined

  test "the header of a declined arm is not dimmed — its test was evaluated":
    # `Omniscience-Flow.md`: "What is dimmed is the arm's interior, not its
    # header. The line carrying the condition is evidence — for an `else if`,
    # it is the line whose test was evaluated and came out false, so it
    # demonstrably *did* run. Dimming it makes the one line that proves the
    # branch was considered look like the one line that proves it was not."
    #
    # Line 28 is `NotTaken` and is nonetheless not dimmed here: it carries a
    # branch state, so it is left to `conditionStyleLines`' background-colour
    # pass entirely. A regression that dimmed headers would have to emit an
    # entry for 28, and this fails the moment it does.
    let styled = flowStyledLines(calculateDamageWindow(), finished = true)
    check not isDimmed(styled, IfHeader)
    for s in styled:
      check s.position != IfHeader
      check s.position != ElseHeader

  test "a declined arm whose extent was not shipped dims nothing":
    # THE HONEST-PARTIAL CASE, asserted rather than left to chance.
    #
    # `branch_extents` skips a branch whose body node the language's grammar
    # configuration did not name, and a window built by hand — the
    # review-dataset adapter builds one — carries no extents at all. The arm
    # states still arrive. Under the rule, an arm whose lines are unknown
    # supports no claim about any line, so nothing is dimmed; the alternative
    # is to guess a span, which would dim lines on no evidence.
    #
    # This is also what makes the fix safe to land ahead of a backend that
    # ships extents for every language: the failure mode is a missing dim, not
    # a wrong one.
    let styled = flowStyledLines(
      calculateDamageWindow(shipExtents = false), finished = true)
    for s in styled:
      check s.kind == flskHit

  test "dimming does not move when the reader does":
    # The user's report in its own terms: "I jump into a function and all of
    # its lines before the current line get dimmed."
    #
    # The reader's position enters this module only through
    # `relevantStepCount`, which `ui/flow.nim` clears and rebuilds down to the
    # displayed loop iteration — so a narrower `visited` is exactly what
    # arriving higher up in the function, or looking at another iteration,
    # produces. The set of DIMMED lines must not change with it.
    proc dimmedLines(visited: openArray[int]): seq[int] =
      let flow = windowOver(22, 38, visited = visited,
                            branchesTaken = armsOf(
                              states = [(IfHeader, ct.NotTaken),
                                        (ElseHeader, ct.Taken)],
                              extents = [(IfHeader, IfArm),
                                         (ElseHeader, ElseArm)]))
      for s in flowStyledLines(flow, finished = true):
        if s.kind in {flskSkip, flskUnknown}:
          result.add(s.position)

    let deepInTheFunction = dimmedLines([26, 28, 31, 32, 34, 37])
    let justArrived = dimmedLines([26])
    let nothingWalkedYet = dimmedLines([])

    check deepInTheFunction == @[29, 30]
    check justArrived == deepInTheFunction
    check nothingWalkedYet == deepInTheFunction
