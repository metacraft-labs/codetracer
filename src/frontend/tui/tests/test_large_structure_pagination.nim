## test_large_structure_pagination.nim — CTUI-7, Tier 1, on a real trace.
##
## ## What this suite establishes
##
## CTUI-7: "on `wide_state`: expanding a >500-property node completes within the
## gate and pages rather than materialising everything", with the verification
## gate "expansion of a 500-property node < 15 ms" and the risk mitigation
## "slice pagination with an explicit `… N more` affordance".
##
## All four, against the fixture's own 600-member mapping:
##
##   * THE GATE, measured on the path an expansion really takes — collapse,
##     expand, paint — over many iterations, best-of. The collapse is INSIDE the
##     loop on purpose: an iteration that found the node already materialised
##     would do no work and time nothing, which is the CTUI-4 shape (a
##     comparison whose second side finds the state populated and compares
##     something with itself). The suite asserts the loop performed exactly one
##     population per iteration, so "it was fast" cannot mean "it did nothing".
##   * PAGES RATHER THAN MATERIALISES. `heldNodes` is the count of materialised
##     member objects; it is asserted to equal the page size and to be strictly
##     less than the member count the PROGRAM declares.
##   * THE `… N MORE` AFFORDANCE, as a row with an exact number: `600 - page`,
##     then `600 - 2 * page`, then gone at the last page. A pane that said
##     "more" without the count would pass a `contains` check and tell a reader
##     nothing.
##   * A WALK TO THE END. Paging all the way through 600 members yields each one
##     exactly once, in order, and the affordance disappears on the last page —
##     which is the assertion an off-by-one in the slice arithmetic fails.
##
## ## WHY THIS FILE IS NOT UNDER `app/tests/`, WHICH IS WHERE CTUI-7 NAMES IT
##
## The same reason CTUI-5 and CTUI-6 recorded, unchanged: the facade guard
## forbids `headless_session` under `app/`.
##
## ## No mocks
##
## A real `.ct` trace recorded by the real Python recorder, opened by a real
## `replay-server`.
##
## ## Templates, not procs, for anything that calls `check`

import std/[json, monotimes, os, strutils, times, unittest]

import isonim/core/[signals, computation]
import isonim/viewmodel

import headless_session
import store/[replay_data_store, types]

import ../app/variables_binding
import ./fixtures/fixture_provider

# One line, deliberately: `ci/lib/run-nim-test-lane.sh` reads exactly this
# spelling as a RUNTIME assertion count, and inside a `const` block the
# declaration is invisible to it.
const ExpectedAssertions = 43

var countedAssertions = 0

template ck(condition: untyped) =
  inc countedAssertions
  check condition

const
  FixtureName = "wide_state"
  RecursiveFunction = "descend"
    ## Used only to NAVIGATE, exactly as in
    ## `test_variables_tree_expansion.nim`: the calltrace says where it is, and
    ## its caller is the stop whose locals hold the wide structures.
  OuterFunction = "main"
  WideMappingName = "wide_mapping"
  CountConstantName = "WIDE_PROPERTY_COUNT"
  MaxSteps = 8
  PaneWidth = 60
  PaneHeight = 24
    ## The geometry the gate is measured at — a terminal-sized pane, not a
    ## synthetic one.
  TallPaneHeight = 100
    ## Tall enough that the first page AND its `… N more` row are painted at
    ## once, which one assertion below reads off the painted screen. Every other
    ## assertion about the affordance goes through the pane's own ROW MODEL, so
    ## a later page that does not fit a viewport is still checked.
  PageSize = 50
  GateMs = 15.0
    ## CTUI-7's verification gate: "expansion of a 500-property node < 15 ms".
  GateIterations = 40
    ## Best-of, like CTUI-5's stepping figure and CTUI-6's frame-selection one,
    ## and for the same reason: the number is compared against a fixed gate on a
    ## shared host, so the figure that matters is the one the machine can do
    ## rather than the one a scheduler happened to allow.

  ChecksNavigation = 6
  ChecksFirstPage = 9
  ChecksMoreRow = 8
  ChecksWalkToEnd = 8
  ChecksGate = 8
  ChecksSummary = 4
  ChecksSkippedFixture = 2

var
  examinedFixtures = 0
  verifiedFixtures = 0
  skippedFixtures = 0

proc frameFunction(session: HeadlessDebugSession): string =
  let response = session.sendRawDapRequest("stackTrace", %*{
    "threadId": 1, "startFrame": 0, "levels": 5,
  })
  discard session.drainEvents()
  let frames = response.getOrDefault("body").getOrDefault("stackFrames")
  if frames.isNil or frames.len == 0: ""
  else: frames[0].getOrDefault("name").getStr("")

proc declaredMemberCount(path: string): int =
  ## `WIDE_PROPERTY_COUNT = <n>` as the recorded PROGRAM declares it. The
  ## independent ground truth for the member count, read off disk at the path
  ## the backend reported.
  result = -1
  if not fileExists(path):
    return
  for line in readFile(path).splitLines():
    let text = line.strip()
    if text.startsWith(CountConstantName) and text.contains("="):
      try:
        return parseInt(text.split('=')[1].strip())
      except ValueError:
        return -1

proc moreRowText(model: VariablesModel; path: string; width: int): string =
  ## The `… N more` row under `path`, rendered by the PRODUCTION row renderer,
  ## or "" when the pane has no such row.
  ##
  ## Found by walking the pane's own ROW MODEL for a `vrkMore` row whose parent
  ## is `path`, rather than by searching a screen for an ellipsis: a value
  ## rendered with a `…` because it was truncated would match a text scan, and a
  ## row scrolled out of a viewport would be missing from one.
  for row in model.paneRows():
    if row.kind == vrkMore and row.node.path == path:
      return treeRowText(rowSpecFor(model, row, width))
  ""

proc remainingReported(model: VariablesModel; path: string): int =
  ## What the `… N more` row SAYS is left. -1 when there is no such row.
  for row in model.paneRows():
    if row.kind == vrkMore and row.node.path == path:
      return row.remaining
  -1

# ---------------------------------------------------------------------------
# Assertion templates. Every helper that calls `check` is a TEMPLATE.
# ---------------------------------------------------------------------------

template checkPageBoundary(model: VariablesModel; path: string;
                           held, total: int) =
  ## The pane holds `held` of `total` members and says how many are left.
  let remaining = total - held
  let text = moreRowText(model, path, PaneWidth)
  checkpoint("held " & $held & " of " & $total & "; more row '" & text & "'")
  ck model.heldNodes(path) == held
  ck remainingReported(model, path) == remaining
  ck text.contains($remaining)

# ---------------------------------------------------------------------------

suite "CTUI-7: a 600-member node pages rather than materialising itself":

  test "wide_state: expansion is bounded, paged, and inside the gate":
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
      let session = newHeadlessDebugSession(resolution.tracePath,
                                            findReplayServer())
      defer: session.close()

      # ---- NAVIGATE TO THE FRAME THAT HOLDS THE WIDE STRUCTURES ------------
      session.requestAndLoadCalltrace(depth = 200, height = 400)
      var target = CallLine(index: -1)
      for callLine in session.getCalltraceLines():
        if callLine.name == RecursiveFunction:
          target = callLine
          break
      ck target.index >= 0
      session.calltraceJumpByLine(target)
      discard session.drainEvents()
      var steps = 0
      while steps < MaxSteps and session.frameFunction() != OuterFunction:
        session.stepOut()
        discard session.drainEvents()
        inc steps
      ck steps < MaxSteps
      ck session.frameFunction() == OuterFunction

      session.requestAndLoadLocals()
      let locals = session.getLocals()
      let declared = declaredMemberCount(session.getCurrentFile())
      ck locals.len > 0
      ck declared > 500

      var timeline = initValueTimeline()
      let tick = session.getCurrentRRTicks()
      timeline.observeStop(tick, locals)
      var model = variablesModelFor(session.session.stateVM, timeline, tick,
                                    pageSize = PageSize)
      let localsPath = scopePath(skLocals)
      let widePath = childPath(localsPath, WideMappingName)
      ck model.isExpanded(localsPath)

      # ---- THE FIRST PAGE --------------------------------------------------
      let heldBefore = model.heldNodeTotal()
      let populationsBefore = model.populations
      model.expandNode(widePath)
      echo "CTUI-7 PAGINATION: " & WideMappingName & " has " &
           $model.memberTotal(widePath) & " member(s); page " & $PageSize &
           "; the model holds " & $model.heldNodes(widePath)
      ck model.memberTotal(widePath) == declared
      ck model.populations == populationsBefore + 1
      ck model.heldNodes(widePath) == PageSize
      # THE POINT: not everything.
      ck model.heldNodes(widePath) < declared
      ck model.heldNodeTotal() == heldBefore + PageSize
      ck model.heldNodeTotal() < declared
      # …and the pane's rows are bounded by the page too, not by the member
      # count: the tree cannot be taller than what has been materialised.
      let firstScreen = variablesScreen(model, PaneWidth, TallPaneHeight)
      ck firstScreen.totalRows < declared
      ck firstScreen.totalRows >= PageSize
      # …and the affordance is really PAINTED, once, at this height.
      ck firstScreen.moreRows == 1

      # ---- THE `… N MORE` AFFORDANCE ---------------------------------------
      checkPageBoundary(model, widePath, PageSize, declared)
      let grew = model.expandMore(widePath)
      ck grew == PageSize
      checkPageBoundary(model, widePath, 2 * PageSize, declared)
      ck model.populations == populationsBefore + 2

      # ---- PAGING TO THE END -----------------------------------------------
      # Every member arrives exactly once, in order, and the affordance is gone
      # on the last page. An off-by-one in the slice arithmetic fails here and
      # nowhere else.
      var pages = 2
      while model.heldNodes(widePath) < declared and pages < declared:
        if model.expandMore(widePath) == 0:
          break
        inc pages
      let all = model.childrenOf(widePath)
      var outOfOrder = 0
      for i, member in all:
        if member.name != "[" & $i & "]":
          inc outOfOrder
      echo "CTUI-7 PAGINATION: paged to the end in " & $pages &
           " fetch(es); held " & $all.len & " member(s), out of order " &
           $outOfOrder
      ck all.len == declared
      ck outOfOrder == 0
      ck pages == (declared + PageSize - 1) div PageSize
      ck model.populations == populationsBefore + pages
      ck moreRowText(model, widePath, PaneWidth).len == 0
      ck remainingReported(model, widePath) == -1
      # A further page is refused rather than fetched, so the walk terminates
      # for a reason rather than by the loop bound.
      ck model.expandMore(widePath) == 0
      ck model.populations == populationsBefore + pages

      # ---- THE VERIFICATION GATE -------------------------------------------
      # Measured on the path an expansion really takes: the node is COLLAPSED
      # first, so every iteration re-queries the seam and re-materialises a
      # page, and then the pane is PAINTED, because an expansion a user cannot
      # see is not an expansion. Best-of, and the population count is asserted
      # afterwards so "it was fast" cannot mean "it did nothing".
      #
      # TWO NUMBERS ARE REPORTED AND BOTH ARE GATED. The first is the expansion
      # ALONE, which is what CTUI-7's sentence names; the second adds the paint,
      # which is what a user waits for. Reporting only the first would gate on
      # the cheaper half, and reporting only the second would hide which half
      # moved when it regresses.
      model.collapseNode(widePath)
      let gateStartPopulations = model.populations
      var bestMs = 1.0e9
      var bestExpandMs = 1.0e9
      var samples = 0
      var paintedRows = 0
      for _ in 1 .. GateIterations:
        let t0 = getMonoTime()
        model.expandNode(widePath)
        let expandedAt = getMonoTime()
        let screen = variablesScreen(model, PaneWidth, PaneHeight)
        let t1 = getMonoTime()
        let expandMs = (expandedAt - t0).inMicroseconds.float / 1000.0
        let ms = (t1 - t0).inMicroseconds.float / 1000.0
        paintedRows += screen.rows.len
        inc samples
        if ms < bestMs:
          bestMs = ms
        if expandMs < bestExpandMs:
          bestExpandMs = expandMs
        model.collapseNode(widePath)
      echo "CTUI-7 EXPANSION LATENCY: expand-only best " &
           formatFloat(bestExpandMs, ffDecimal, 3) &
           " ms, expand+paint best " & formatFloat(bestMs, ffDecimal, 3) &
           " ms over " & $GateIterations & " expansions of a " & $declared &
           "-member node (page " & $PageSize & ", pane " & $PaneWidth & "x" &
           $PaneHeight & ", gate < " & formatFloat(GateMs, ffDecimal, 0) & ")"
      ck samples == GateIterations
      ck paintedRows == GateIterations * PaneHeight
      ck bestExpandMs < GateMs
      ck bestMs < GateMs
      # THE WORK WAS DONE: one population per iteration, and the node was
      # really empty at the top of each one.
      ck model.populations == gateStartPopulations + GateIterations
      ck model.heldNodes(widePath) == 0
      # …and one more expansion after the loop still yields a full page, so the
      # collapse inside the loop did not leave the seam unable to answer.
      model.expandNode(widePath)
      ck model.heldNodes(widePath) == PageSize
      ck model.childrenOf(widePath)[PageSize - 1].name ==
         "[" & $(PageSize - 1) & "]"

  test "every fixture was examined, and the assertion tally proves it":
    ck examinedFixtures == 1
    ck verifiedFixtures + skippedFixtures == examinedFixtures
    ck verifiedFixtures >= 1
    let expected =
      verifiedFixtures * (
        ChecksNavigation + ChecksFirstPage + ChecksMoreRow +
        ChecksWalkToEnd + ChecksGate) +
      skippedFixtures * ChecksSkippedFixture +
      ChecksSummary
    checkpoint("counted " & $countedAssertions & ", derived " & $expected)
    ck countedAssertions == expected

  test "assertion count":
    echo "CHECKS: " & $countedAssertions
    checkpoint("counted assertions: " & $countedAssertions)
    check countedAssertions == ExpectedAssertions
