## test_recursion_grouping.nim — CTUI-6, Tier 1, on a real trace.
##
## ## What this suite establishes
##
## CTUI-6: "on `wide_state`: a >50-frame recursion renders as a bounded group,
## the pane scrolls cleanly, and expanding the group yields the individual
## frames."
##
## All three, against the stack the ENGINE reports rather than against a
## constructed one: the session sets a breakpoint on the line the CALLTRACE
## gives for `descend` — so editing the program cannot disarm it — continues
## until DAP `stackTrace` reports more than fifty frames, and the pane is built
## from that answer.
##
## ## "SCROLLS CLEANLY" IS A COUNT, NOT AN IMPRESSION
##
## The expanded pane has more rows than the body, so the suite visits EVERY
## scroll position and asserts that the body is exactly the model's rows from
## the clamped top — plus that every row is reachable across the walk. A pane
## that dropped a row at a boundary, repeated one, or left the last row
## unreachable by a one-off in the clamp would satisfy every "the rows are
## sorted" or "the last row exists" check that could be written instead.
##
## A PAGE-AT-A-TIME WALK WAS TRIED FIRST AND WAS WRONG, which is worth
## recording: the pane CLAMPS its last page rather than showing a short one, so
## striding by the body height makes the final page overlap its predecessor and
## the walk cannot tell that overlap from a defect. Row by row there is nothing
## to tell apart.
##
## ## WHY THIS FILE IS NOT UNDER `app/tests/`
##
## The same reason as `test_call_stack_navigation.nim`'s, unchanged: this suite
## needs a real `HeadlessDebugSession`, which `app/`'s facade guard forbids.
##
## ## The 39 MB per stop CTUI-1 measured
##
## Every `continue` makes `replay-server` push events the session buffers until
## somebody asks for them, and on this fixture each stop's events carry the
## 600-member `wide_mapping`. CTUI-1 measured the growth at ~39 MB per stop —
## 126 MB to 2.85 GB over 67 stops — and the fix is one `drainEvents()` inside
## the loop. It is here for that reason and not as housekeeping.
##
## ## No mocks
##
## A real `.ct` trace recorded by the real Python recorder, opened by a real
## `replay-server`.
##
## ## Templates, not procs, for anything that calls `check`

import std/[json, strutils, unittest]

import isonim/core/[signals, computation]
import isonim/viewmodel

import headless_session
import store/[replay_data_store, types]

import ../app/call_stack_binding
import ../app/input/call_stack_keys
import ./fixtures/fixture_provider

# One line, deliberately: `ci/lib/run-nim-test-lane.sh` reads exactly this
# spelling as a RUNTIME assertion count, and inside a `const` block the
# declaration is invisible to it.
const ExpectedAssertions = 47

var countedAssertions = 0

template ck(condition: untyped) =
  inc countedAssertions
  check condition

const
  FixtureName = "wide_state"
  RecursiveFunction = "descend"
    ## The one name written into this file, and CTUI-1 wrote it for the same
    ## reason: the program under test is ours and its call graph is the thing
    ## being asserted about. Its LINE is never written down — it comes from the
    ## calltrace the backend returns.
  DepthFloor = 50
    ## CTUI-6's ">50-frame" bound. The loop stops at the first stack deeper than
    ## this, which CTUI-1 measured as 51 frames over 50 stops.
  MaxStops = 200
  PaneWidth = 46
  PaneHeight = 17
  BodyHeight = PaneHeight - 1

  ChecksDeepStack = 8
  ChecksGrouping = 9
  ChecksCollapsedPane = 11
  ChecksExpansion = 10
  ChecksScrolling = 5
  ChecksSummary = 4
  ChecksSkippedFixture = 2

var
  examinedFixtures = 0
  verifiedFixtures = 0
  skippedFixtures = 0

proc stackBody(session: HeadlessDebugSession): JsonNode =
  let response = session.sendRawDapRequest("stackTrace", %*{
    "threadId": 1, "startFrame": 0, "levels": 400,
  })
  response.getOrDefault("body")

proc rowFrames(rows: openArray[CallStackRow]): seq[int] =
  ## The frame each row stands for, in order. What the scroll walk compares.
  result = @[]
  for row in rows:
    result.add row.firstFrame

# ---------------------------------------------------------------------------
# Assertion templates. Every helper that calls `check` is a TEMPLATE.
# ---------------------------------------------------------------------------

template checkPaneRowsAreWellFormed(model: CallStackModel; label: string) =
  ## Every painted row is exactly the pane's width, at every scroll position.
  ##
  ## The cheap half of "no artifacts": a row that came out short or long would
  ## corrupt every row after it on a real terminal, and it is exactly what a
  ## width calculation that forgot the group indent produces.
  var wrongWidth = 0
  for row in callStackRows(model, PaneWidth, PaneHeight):
    if cellCount(row) != PaneWidth:
      inc wrongWidth
  checkpoint(label & ": rows of the wrong width: " & $wrongWidth)
  ck wrongWidth == 0

suite "CTUI-6: a >50-frame recursion is one bounded row until it is opened":

  test "wide_state: the recursion groups, scrolls and expands":
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
      let entryFile = session.getCurrentFile()

      # ---- drive the recursion to its floor --------------------------------
      # The breakpoint's LINE comes from the calltrace the backend returned for
      # the recursive function, not from this file.
      session.requestAndLoadCalltrace(depth = 200, height = 400)
      var recursiveFile = ""
      var recursiveLine = 0
      for callLine in session.getCalltraceLines():
        if callLine.name == RecursiveFunction:
          recursiveFile = callLine.location.file
          recursiveLine = callLine.location.line
          break
      checkpoint("recursive frame reported at " & recursiveFile & ":" &
                 $recursiveLine)
      ck recursiveFile.len > 0
      ck recursiveLine > 0
      session.setBreakpoint(recursiveFile, recursiveLine)

      var frames: seq[StackFrame] = @[]
      var body: JsonNode = nil
      var stops = 0
      var previousTick = session.getCurrentRRTicks()
      for _ in 0 ..< MaxStops:
        session.continueForward()
        let tick = session.getCurrentRRTicks()
        # TERMINATION, and it is not the iteration bound: `continue` at the end
        # of a recording returns at the SAME position rather than blocking, so
        # a program that lost its recursion FAILS below with the depth it
        # actually reached instead of hanging. Verification-Harness-Traps §1.
        if tick <= previousTick:
          break
        previousTick = tick
        inc stops
        body = session.stackBody()
        frames = framesFromStackTrace(body)
        # See this file's header: 39 MB per stop without this line.
        discard session.drainEvents()
        if frames.len > DepthFloor:
          break
      echo "CTUI-6 RECURSION: " & $frames.len & " frame(s) over " & $stops &
           " stop(s) at " & recursiveFile & ":" & $recursiveLine
      ck stops >= 1
      ck stops < MaxStops
      ck frames.len > DepthFloor
      ck reportedFrameCount(body) == frames.len
      ck frames[0].name == RecursiveFunction
      ck frames[0].line == recursiveLine

      # ---- the run the grouping is derived from ----------------------------
      # Counted here from the frames themselves, so the assertion on the group's
      # size is against the STACK and not against the grouper's own answer.
      var recursiveFrames = 0
      var otherFrames = 0
      for frame in frames:
        if frame.name == frames[0].name and frame.path == frames[0].path:
          inc recursiveFrames
        else:
          inc otherFrames
      checkpoint("recursive frames " & $recursiveFrames & ", other " &
                 $otherFrames)
      ck recursiveFrames > DepthFloor - 2
      # THE POSITIVE CONTROL ON THE GROUP: the stack is not ONE run. If it were,
      # a grouper that collapsed everything would pass every assertion below.
      ck otherFrames >= 1

      let runs = recursionRuns(frames)
      ck runs.len == 1
      ck runs[0][0] == 0
      ck runs[0][1] == recursiveFrames
      # …and a stack with no repetition produces no run at all, through the
      # same function: the grouper is not simply grouping whatever it is given.
      ck recursionRuns(frames[recursiveFrames .. ^1]).len == 0
      ck recursionRuns(@[frames[0], frames[^1]]).len == 0
      # Two identical frames are below the minimum and stay two rows.
      ck recursionRuns(@[frames[0], frames[0]]).len == 0
      ck recursionRuns(@[frames[0], frames[0], frames[0]]).len == 1

      # ---- COLLAPSED: THE GROUP IS ONE BOUNDED ROW -------------------------
      var model = callStackModelFor(frames, entryFile)
      let collapsedRows = model.paneRows()
      ck collapsedRows.len == 1 + otherFrames
      ck collapsedRows.len < frames.len
      let collapsedScreen = callStackScreen(model, PaneWidth, PaneHeight)
      checkpoint("collapsed pane:\n" &
                 callStackText(model, PaneWidth, PaneHeight).join("\n"))
      ck collapsedScreen.groupRows == 1
      ck collapsedScreen.frameRows == otherFrames
      ck collapsedScreen.totalRows == collapsedRows.len
      # BOUNDED: the whole 51-frame stack fits the pane body with rows to spare,
      # which is the property the group exists for.
      ck collapsedScreen.totalRows <= BodyHeight
      # THE GROUP ROW REPORTS ITS COUNT, which is CTUI-6's contract for it.
      #
      # Asserted against the count THIS SUITE derived from the stack and the
      # name the program uses — NOT against `groupLabel`, which is the function
      # under test. The first draft called `groupLabel` to build the
      # expectation, and a mutation arm that made it return the bare name left
      # the suite green: the expectation had moved with the implementation.
      # That is the self-comparison shape the CTUI-4 audit catalogues, found
      # here by running the arm rather than by review.
      let groupText = rowText(collapsedScreen.rows[1])
      checkpoint("group row: '" & groupText & "'")
      ck groupText.contains($recursiveFrames)
      ck groupText.contains(RecursiveFunction)
      ck groupText.startsWith(ExecutionFrameGlyph & InspectedFrameGlyph &
                              GroupCollapsedGlyph)
      ck groupText.contains("#0")
      checkPaneRowsAreWellFormed(model, "collapsed")

      # ---- EXPANDING YIELDS THE INDIVIDUAL FRAMES --------------------------
      ck model.applyKey(KeyToggleGroup, collapsedScreen) == csaGroupToggled
      ck model.isExpanded(0)
      let expandedRows = model.paneRows()
      ck expandedRows.len == 1 + recursiveFrames + otherFrames
      # …and they are the individual frames, in order, under their header.
      var membersInOrder = true
      for k in 0 ..< recursiveFrames:
        let row = expandedRows[1 + k]
        if row.kind != cskFrame or row.firstFrame != k or not row.depthInGroup:
          membersInOrder = false
      ck membersInOrder
      ck expandedRows[0].kind == cskGroup
      ck expandedRows[0].expanded
      ck expandedRows[^1].firstFrame == frames.len - 1
      checkPaneRowsAreWellFormed(model, "expanded")
      # …and it collapses again from the same key, which is what makes the
      # expansion a state rather than a one-way door.
      var reModel = model
      ck reModel.applyKey(KeyToggleGroup,
                          callStackScreen(reModel, PaneWidth, PaneHeight)) ==
         csaGroupToggled
      ck reModel.paneRows().len == collapsedRows.len

      # ---- THE PANE SCROLLS CLEANLY ----------------------------------------
      # Page by page over the EXPANDED pane, concatenating what each page
      # showed. See this file's header: the assertion is the concatenation, not
      # a property of it.
      let allRows = rowFrames(expandedRows)
      ck allRows.len > BodyHeight
      # EVERY scroll position, not every page: the pane CLAMPS rather than
      # wrapping, so a page walk in strides of the body height would find the
      # last page overlapping the one before it and would have to decide whether
      # that overlap was the clamp or a defect. Row by row there is nothing to
      # decide — at each `scrollTop` the body must be exactly the model's rows
      # from the CLAMPED top, and any drop, duplicate or gap is a mismatch at
      # the position it happened.
      var wrongPositions: seq[string] = @[]
      var reachedRows = newSeq[bool](allRows.len)
      for top in 0 ..< allRows.len:
        var paged = model
        paged.scrollTop = top
        let screen = callStackScreen(paged, PaneWidth, PaneHeight)
        let want = clampScrollTop(top, allRows.len, BodyHeight)
        let expectedRows = allRows[want ..< min(allRows.len, want + BodyHeight)]
        if rowFrames(screen.visible) != expectedRows:
          wrongPositions.add "scrollTop " & $top & ": " &
            $rowFrames(screen.visible) & " != " & $expectedRows
        for i in want ..< min(allRows.len, want + screen.visible.len):
          reachedRows[i] = true
      var reached = 0
      for hit in reachedRows:
        if hit: inc reached
      checkpoint("scrolled " & $allRows.len & " position(s); reached " &
                 $reached & " row(s); mismatches " & $wrongPositions.len)
      if wrongPositions.len > 0:
        checkpoint(wrongPositions[0 .. min(2, wrongPositions.high)].join("\n"))
      ck wrongPositions.len == 0
      # …and every row of the expanded pane is reachable by scrolling. A pane
      # whose clamp was one row tight would leave the last row unreachable while
      # every assertion above stayed green.
      ck reached == allRows.len
      # A scroll past the end is clamped to the last full page, so the body is
      # never painted with a gap at the bottom.
      var overscrolled = model
      overscrolled.scrollTop = allRows.len * 4
      let clamped = callStackScreen(overscrolled, PaneWidth, PaneHeight)
      ck clamped.visible.len == BodyHeight
      ck rowFrames(clamped.visible) == allRows[allRows.len - BodyHeight .. ^1]

  test "every fixture was examined, and the assertion tally proves it":
    ck examinedFixtures == 1
    ck verifiedFixtures + skippedFixtures == examinedFixtures
    ck verifiedFixtures >= 1
    let expected =
      verifiedFixtures * (
        ChecksDeepStack + ChecksGrouping + ChecksCollapsedPane +
        ChecksExpansion + ChecksScrolling) +
      skippedFixtures * ChecksSkippedFixture +
      ChecksSummary
    checkpoint("counted " & $countedAssertions & ", derived " & $expected)
    ck countedAssertions == expected

  test "assertion count":
    echo "CHECKS: " & $countedAssertions
    checkpoint("counted assertions: " & $countedAssertions)
    check countedAssertions == ExpectedAssertions
