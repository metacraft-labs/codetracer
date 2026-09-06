## test_event_log_jump.nim — CTUI-8, Tier 1, on a real trace.
##
## ## THE ASSERTION THIS MILESTONE EXISTS FOR
##
## CTUI-8: "selecting an event issues one atomic `goto`; a partially-applied
## seek that moves the source but not the stack is the defect to prevent", and
## its test: "selects a real recorded event and asserts *every* pane — source,
## stack, variables, timeline — reports the tick of that event. Asserting only
## the source pane would pass a partial seek."
##
## So all four panes are BUILT and READ here, from four different ViewModels,
## after one call to `TimelineVM.seek`:
##
##   * the SOURCE pane, through a real `SourceProvider` refusing the working
##     tree, with the line under its execution pointer compared against the file
##     read independently off disk at the path the BACKEND reported;
##   * the CALL STACK pane, from the engine's own `stackTrace` at the
##     destination, with the innermost frame's line asserted to be the line the
##     `ct/complete-move` reported;
##   * the VARIABLES pane, from a fresh `ct/load-locals` at the destination,
##     with the pane's own tick label;
##   * the TIMELINE scrubber, with the needle's PAINTED column asserted to be
##     the column the pure mapping gives for the destination tick.
##
## A pane that did not move fails its own assertion, which is the whole point:
## reading one shared `rrTicks` four times would pass a seek that moved nothing
## but the store.
##
## ## "ONE ATOMIC GOTO" IS COUNTED, NOT ASSUMED
##
## The session's event queue is drained to empty before the seek, one
## `stopped` + `ct/complete-move` pair is consumed after it, and the queue is
## then asserted to hold NO further `stopped`. A seek that issued two commands
## would leave a second pair behind and redden that count.
##
## ## THREE FIELDS ARE ASSERTED TO BE EMPTY, AS EQUALITIES
##
## `EventLogVM.eventRows`, `EventLogVM.markerRows` and `TimelineVM.markers` are
## filled by nothing on a replay session — see `app/timeline_binding.nim`'s
## header for the grep and the measurements. Each is asserted as `== 0` beside
## the surface that DOES answer, so the day a host starts filling one the suite
## goes red and says the pane can stop working around it. The same shape CTUI-7
## used for `store.locals.globals`.
##
## ## WHY THIS FILE IS NOT UNDER `app/tests/`
##
## `tests/test_tui_facade_boundary.nim` walks every `.nim` under
## `src/frontend/tui/app/` and fails on an import resolving to
## `headless_session`, `backend/stdio_backend`, `std/osproc` or `std/posix`.
## This suite's subject is a real `HeadlessDebugSession` over a real
## `replay-server`. The `tui` lane globs `tests/test_*.nim` and
## `app/tests/test_*.nim` identically, so nothing about the coverage changes.
##
## ## No mocks
##
## A real `.ct` trace recorded by a real recorder, opened by a real
## `replay-server`, with source read through the production `SourceProvider`
## constructed with `allowWorkingTree = false`.
##
## ## Templates, not procs, for anything that calls `check`

import std/[json, options, os, strutils, unicode, unittest]

import isonim/core/[signals, computation]
import isonim/viewmodel

import headless_session
import store/[replay_data_store, types]
import viewmodels/[calltrace_vm, debug_controls_vm, event_log_vm, source_vm,
                   state_vm, timeline_vm]
import sdk/source_provider

import ../app/call_stack_binding
import ../app/source_binding
import ../app/timeline_binding
import ../app/variables_binding
import ./fixtures/fixture_provider

# One line, deliberately: `ci/lib/run-nim-test-lane.sh` reads exactly this
# spelling as a RUNTIME assertion count, and inside a `const` block the
# declaration is invisible to it.
const ExpectedAssertions = 147

var countedAssertions = 0

template ck(condition: untyped) =
  inc countedAssertions
  check condition

const
  FixtureName = "noir_space_ship"
    ## The densest log in CTUI-1's corpus: 70 recorded events against `calc`'s
    ## and `wide_state`'s 6. A jump suite wants a log with an interior.
  PageSize = 16
  BarWidth = 80
  BarHeight = 2
  LogWidth = 80
  LogHeight = 12
  SourceViewport = 16
  StackWidth = 46
  StackHeight = 17
  VariablesWidth = 60
  VariablesHeight = 20

  ChecksSeam = 8
  ChecksSelection = 8
  ChecksAtomicGoto = 5
  ChecksAllFourPanes = 22
    ## Per call of `checkEveryPaneAt`, which is called TWICE — on two different
    ## recorded events — so one agreement cannot be a coincidence of the tick
    ## the session happened to start at.
  ChecksCategories = 7
  ChecksUnfilledFields = 8
  ChecksSummary = 4
  ChecksSkippedFixture = 2

  AdditionStatement = "return left + right"
    ## A statement of `calc`'s own `add` helper. The LINE it is on is found by
    ## searching the recorded program at the path the BACKEND reported, so no
    ## line number is written down here — the same rule CTUI-6 and CTUI-7
    ## followed.
  SweepExpression = "log(left)"
  SweepLocalName = "left"
  PythonDbLangOrdinal = 21
    ## `Lang.PythonDb` (`libs/ct-lang/src/lib.rs`). Measured on `calc` with 12
    ## (`Python`) as well: the engine answered identically and echoed `lang: 0`
    ## on every `Stop`, so the field does not select the evaluator on a CTFS
    ## trace. It is sent because `Tracepoint` requires it.

var
  examinedFixtures = 0
  verifiedFixtures = 0
  skippedFixtures = 0

# ---------------------------------------------------------------------------
# The harness
# ---------------------------------------------------------------------------

type JumpHarness = object
  session: HeadlessDebugSession
  timeline: TimelineVM
  events: EventLogVM
  calltrace: CalltraceVM
  source: SourceVM
  state: StateVM
  controls: DebugControlsVM
  provider: SourceProvider

proc openHarness(tracePath: string): JumpHarness =
  let session = newHeadlessDebugSession(tracePath, findReplayServer())
  let store = session.session.store
  let source = createSourceVM(store, session.session.editorVM)
  source.setViewport(height = SourceViewport, overscan = 4)
  JumpHarness(
    session: session,
    timeline: createTimelineVM(store),
    events: createEventLogVM(store),
    calltrace: createCalltraceVM(store),
    source: source,
    state: createStateVM(store),
    controls: createDebugControlsVM(store),
    # `allowWorkingTree = false` DELIBERATELY, for CTUI-5's reason:
    # `noir_space_ship` is recorded from a program still in this checkout, so a
    # permissive provider would answer every request off the working tree and
    # the suite would pass without the trace payload ever being opened.
    provider: newCtfsSourceProvider(tracePath, allowWorkingTree = false))

proc closeHarness(h: JumpHarness) =
  h.controls.dispose()
  h.state.dispose()
  h.source.dispose()
  h.calltrace.dispose()
  h.events.dispose()
  h.timeline.dispose()
  h.session.close()

proc eventPagesOver(session: HeadlessDebugSession): EventPages =
  ## THE SERVER-PAGINATION SEAM, over the real `ct/event-load`.
  ##
  ## `(offset, limit)` go straight onto the wire as `(start, count)`, which
  ## `Handler::event_load` clamps against its cached events and slices
  ## server-side. Nothing here holds the whole log.
  let s = session
  result = proc(offset, limit: int): EventPage =
    let entries = s.requestAndLoadEventLog(start = offset, count = limit)
    var rows: seq[EventRow] = @[]
    for entry in entries:
      rows.add EventRow(
        index: entry.eventIndex,
        tick: entry.rrTicks,
        file: entry.file,
        line: entry.line,
        content: entry.content,
        category: categoryFor(entry.kind, entry.stdout),
        kindId: entry.kind)
    EventPage(rows: rows, atEnd: entries.len < limit)

proc wholeLog(session: HeadlessDebugSession): seq[EventLogEntry] =
  ## The recording's entire event log in ONE request — the GROUND TRUTH the
  ## paged reads are compared against. Deliberately not the path the pane takes:
  ## a paged pane compared against its own paging would be comparing a thing
  ## with itself.
  session.requestAndLoadEventLog(start = 0, count = 1_000_000)

proc serveOne(h: JumpHarness; request: SourceLineRequest): SourceFetch =
  ## One request through the real provider, delivered. Seeded with a status
  ## that cannot be mistaken for success, and drained: `async_compat.onComplete`
  ## defers a callback even on an already-complete native future, and
  ## `SourceFetchStatus`'s zero value is `sfsAvailable`, so a callback that
  ## never ran would read as an empty file.
  result = SourceFetch(status: sfsProviderUnavailable,
                       detail: "the provider callback never ran")
  var captured = result
  h.provider.fetch(request, proc(fetch: SourceFetch) = captured = fetch)
  drainSourceCallbacks()
  result = captured

proc fillSourceWindow(h: JumpHarness) =
  for request in h.source.followAndRequest():
    let fetch = h.serveOne(request)
    discard h.session.session.store.applySourceFetch(h.source, fetch)

proc recordedProgramLine(path: string; line: int): string =
  ## The `line`-th line of the file at `path`, read straight off disk — the
  ## INDEPENDENT ground truth for "the source pane is showing the right line".
  if not fileExists(path):
    return ""
  let lines = splitSourceLines(readFile(path))
  if line >= 1 and line <= lines.len: lines[line - 1] else: ""

proc stackBody(h: JumpHarness): JsonNode =
  let response = h.session.sendRawDapRequest("stackTrace", %*{
    "threadId": 1, "startFrame": 0, "levels": 400,
  })
  discard h.session.drainEvents()
  response.getOrDefault("body")

proc bufferedStops(h: JumpHarness): int =
  ## How many `stopped` events are still queued. THE COUNT THAT MAKES "one
  ## atomic goto" a measurement.
  for event in h.session.drainEvents():
    if event.getOrDefault("event").getStr("") == "stopped":
      inc result

# ---------------------------------------------------------------------------
# Assertion templates. Every helper that calls `check` is a TEMPLATE.
# ---------------------------------------------------------------------------

template checkEveryPaneAt(h: JumpHarness; destination: uint64;
                          bounds: TimelineBounds; label: string) =
  ## ALL FOUR PANES REPORT THE DESTINATION. Each one is built from its OWN
  ## ViewModel and read from its OWN rendered model, so a seek that moved one
  ## and not another fails here and names which.
  let engineFile = h.session.getCurrentFile()
  let engineLine = h.session.getCurrentLine()
  let engineTick = h.session.getCurrentRRTicks()
  checkpoint(label & ": engine reports tick " & $engineTick & " at " &
             engineFile & ":" & $engineLine)
  ck engineTick == destination
  ck engineFile.len > 0
  ck engineLine > 0

  # ---- THE TIMELINE ------------------------------------------------------
  # The VM's own memo, and the needle's PAINTED column against the pure
  # mapping's answer for the destination.
  ck h.timeline.currentPosition.val == destination
  var spans: seq[TimelineSpan] = @[]
  let barModel = timelineBarModelFor(h.timeline, bounds, spans, @[],
                                     currentTick = destination)
  let barScreen = timelineBarScreen(barModel, BarWidth, BarHeight)
  ck barModel.currentTick == destination
  ck barScreen.trackWidth == trackWidthFor(BarWidth)
  ck barScreen.needleColumn ==
    columnForTick(destination, bounds.minTick, bounds.maxTick,
                  barScreen.trackWidth)
  ck barScreen.needleColumn >= 0
  let barRowText = rowText(barScreen.rows[1])
  checkpoint(label & " scrubber: '" & barRowText & "'")
  ck cellSlice(barRowText, barScreen.trackCol + barScreen.needleColumn,
               barScreen.trackCol + barScreen.needleColumn + 1) == NeedleGlyph

  # ---- THE SOURCE PANE ---------------------------------------------------
  # Through the real provider, and the line under the pointer compared against
  # the file read off disk at the path the BACKEND reported.
  fillSourceWindow(h)
  let sourceModel = sourcePaneModelFor(
    h.source, h.session.session.store.degraded.sourceAvailability.val)
  ck sourceModel.executionLine == engineLine
  ck sourceModel.path == engineFile
  ck sourceModel.holdsLine(engineLine)
  let paneText = sourceModel.heldTextAt(engineLine)
  let onDisk = recordedProgramLine(engineFile, engineLine)
  checkpoint(label & " source line " & $engineLine & ": pane '" & paneText &
             "' disk '" & onDisk & "'")
  ck onDisk.len > 0
  ck paneText.strip() == onDisk.strip()

  # ---- THE CALL STACK PANE -----------------------------------------------
  # The engine's own `stackTrace` at the destination. The innermost frame is
  # where the debugger is, so its line must be the line the move reported.
  let body = stackBody(h)
  let frames = framesFromStackTrace(body)
  ck frames.len > 0
  ck frames[0].line == engineLine
  ck frames[0].path == engineFile
  let stackModel = initCallStackModel(frames = frames, userRoots = @[],
                                      executionFrame = 0, selected = 0)
  let stackScreen = callStackScreen(stackModel, StackWidth, StackHeight)
  ck stackScreen.frameRows + stackScreen.groupRows > 0
  ck bodyRowForFrame(stackScreen, 0) > 0

  # ---- THE VARIABLES PANE ------------------------------------------------
  # A fresh `ct/load-locals` at the destination, through `StateVM`'s own memo.
  h.session.requestAndLoadLocals()
  discard h.session.drainEvents()
  var timelineOfValues = initValueTimeline()
  observeStop(timelineOfValues, destination, h.state.currentVariables.val)
  let varsModel = variablesModelFor(h.state, timelineOfValues, destination,
                                    tickLabel = "tick " & $destination)
  let varsScreen = variablesScreen(varsModel, VariablesWidth,
                                   VariablesHeight)
  ck varsModel.tickLabel == "tick " & $destination
  ck varsScreen.totalRows > 0
  ck rowText(varsScreen.rows[0]).contains("tick " & $destination)

  # ---- AND THE DEBUG CONTROLS, which is the fifth reader of the same move --
  ck h.controls.store.debugger.val.rrTicks == destination
  ck h.controls.store.debugger.val.location.line == engineLine

# ---------------------------------------------------------------------------

suite "CTUI-8: selecting a recorded event moves every pane to its tick":

  test "noir_space_ship: one seek, four panes, one atomic goto":
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
      defer: closeHarness(h)

      # ---- THE SEAM, AND THE GROUND TRUTH BESIDE IT ------------------------
      let truth = wholeLog(h.session)
      echo "CTUI-8 EVENT LOG: ", FixtureName, " records ", truth.len,
           " event(s); maxRRTicks ", truth[0].maxRRTicks
      ck truth.len > 0
      ck truth[0].maxRRTicks > 0

      var model = eventLogModelFor(eventPagesOver(h.session),
                                   currentTick = h.session.getCurrentRRTicks(),
                                   pageSize = PageSize)
      model.ensureWindow(0, PageSize)
      ck model.fetchCount == 1
      ck model.heldPages == 1
      ck model.heldRows == min(PageSize, truth.len)
      # The pane has NOT loaded the whole log, which is the mitigation.
      ck model.heldRows < truth.len
      let firstPage = model.paneRows(0, PageSize)
      ck firstPage.len == min(PageSize, truth.len)
      ck firstPage[0].event.tick == truth[0].rrTicks

      # ---- BOUNDS: NOT from `TimelineVM`, and the source says so ----------
      var rowsSoFar: seq[EventRow] = @[]
      for row in firstPage:
        if row.kind == elrEvent:
          rowsSoFar.add row.event
      let bounds = resolveBounds(h.timeline, rowsSoFar, truth[0].maxRRTicks)
      echo "CTUI-8 TIMELINE BOUNDS: ", bounds.minTick, "..", bounds.maxTick,
           " from ", bounds.source
      ck bounds.known
      ck bounds.source == "ct/event-load.maxRRTicks"
      ck bounds.maxTick == truth[0].maxRRTicks
      ck bounds.minTick == 0'u64

      # ---- SELECT A REAL RECORDED EVENT -----------------------------------
      # An INTERIOR one, chosen from the data: the first event whose tick is
      # neither the session's current position nor the recording's ends, so the
      # seek is a real move in both directions of comparison.
      # The LAST interior event of the first page, so the second jump below has
      # somewhere EARLIER to go and the pair exercises the seek in both
      # directions. Both indices come from the data; neither is written down.
      let startedAt = h.session.getCurrentRRTicks()
      var chosen = -1
      var earliest = -1
      for row in firstPage:
        if row.kind != elrEvent or row.event.tick <= startedAt or
           row.event.tick >= bounds.maxTick:
          continue
        if earliest < 0:
          earliest = row.index
        chosen = row.index
      ck chosen >= 0
      ck earliest >= 0
      ck chosen != earliest
      let (found, chosenEvent) = model.rowAt(chosen)
      ck found
      ck chosenEvent.tick != startedAt
      model.selected = chosen
      publishSelection(h.events, model)
      ck h.events.selectedRow.val.isSome
      ck h.events.selectedRow.val.get() == chosen
      # SELECTING DID NOT MOVE THE PROGRAM. CTUI-6's contract for a cursor,
      # here as the first half of "selecting issues ONE goto": the cursor moved
      # and nothing else has yet.
      ck h.session.getCurrentRRTicks() == startedAt

      # ---- THE ONE ATOMIC GOTO --------------------------------------------
      discard h.session.drainEvents()
      seekTo(h.timeline, chosenEvent.tick)
      h.session.settleAfterSeek()
      let leftover = bufferedStops(h)
      echo "CTUI-8 ATOMIC GOTO: seek to tick ", chosenEvent.tick, " from ",
           startedAt, "; ", leftover, " further stop event(s) queued"
      ck leftover == 0
      ck h.session.getCurrentRRTicks() == chosenEvent.tick

      # ---- ALL FOUR PANES --------------------------------------------------
      checkEveryPaneAt(h, chosenEvent.tick, bounds, "first jump")

      # ---- AND AGAIN, on a different event, BACKWARDS ---------------------
      # A second event whose tick is BELOW the first, so the seek runs the other
      # way. One agreement could be the tick the session happened to be at.
      let second = earliest
      let (foundSecond, secondEvent) = model.rowAt(second)
      ck foundSecond
      ck secondEvent.tick < chosenEvent.tick
      discard h.session.drainEvents()
      model.selected = second
      publishSelection(h.events, model)
      seekTo(h.timeline, secondEvent.tick)
      h.session.settleAfterSeek()
      ck bufferedStops(h) == 0
      checkEveryPaneAt(h, secondEvent.tick, bounds, "second jump")

  test "the recorded log's categories are what §3.3.5 says, and four are empty":
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
      defer: closeHarness(h)

      let truth = wholeLog(h.session)
      var rows: seq[EventRow] = @[]
      var kinds: seq[int] = @[]
      for entry in truth:
        rows.add EventRow(
          index: entry.eventIndex, tick: entry.rrTicks, file: entry.file,
          line: entry.line, content: entry.content,
          category: categoryFor(entry.kind, entry.stdout), kindId: entry.kind)
        if entry.kind notin kinds:
          kinds.add entry.kind
      var counts: array[EventCategory, int]
      for row in rows:
        inc counts[row.category]
      echo "CTUI-8 EVENT CATEGORIES: kinds ", kinds, " -> out ",
           counts[ecOutput], ", mut ", counts[ecMutation], ", sys ",
           counts[ecSyscall], ", err ", counts[ecFault], ", trc ",
           counts[ecTracepoint], ", unknown ", counts[ecUnknown]
      # EVERY RECORDED EVENT IN THIS CORPUS IS A STDOUT WRITE. Asserted as
      # EQUALITIES so the day a recorder emits a storage write, a syscall or a
      # panic, this case says so instead of silently gaining coverage nobody
      # notices.
      ck kinds == @[KindWrite]
      ck counts[ecOutput] == truth.len
      ck counts[ecMutation] == 0
      ck counts[ecSyscall] == 0
      ck counts[ecFault] == 0
      ck counts[ecUnknown] == 0
      # …and therefore `{` and `}` have nowhere to go on this recording, which
      # is the honest consequence and not a gap in the key handler: its
      # behaviour over a non-empty mutation set is asserted in
      # `app/tests/test_timeline_scrubber_quantization.nim`'s sibling suite.
      ck mutationTicks(rows).len == 0

  test "the three ViewModel fields nothing fills are still empty":
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
      defer: closeHarness(h)

      # A REAL `ct/event-load` has been answered by the time this runs — the
      # `EventLogVM`'s own auto-load effect fires on creation, and the request
      # below is a second one through the harness. If anything filled these,
      # they would be full.
      let truth = wholeLog(h.session)
      discard h.session.drainEvents()
      h.session.stepForward()
      discard h.session.drainEvents()
      echo "CTUI-8 UNFILLED: EventLogVM.eventRows ", h.events.eventRows.val.len,
           ", markerRows ", h.events.markerRows.val.len,
           ", TimelineVM.markers ", h.timeline.markers.val.len,
           ", store.timeline ", h.session.session.store.timeline.val,
           " — against ", truth.len, " event(s) the wire really returned"
      # THE POSITIVE TWIN: the wire answered, so "empty" is a statement about
      # the ViewModel and not about the recording.
      ck truth.len > 0
      ck h.events.eventRows.val.len == 0
      ck h.events.totalEventCount.val == 0
      ck h.events.markerRows.val.len == 0
      ck h.timeline.markers.val.len == 0
      ck h.session.session.store.timeline.val.maxRRTicks == 0'u64
      # `seekAtFraction` is the one TimelineVM action that depends on `markers`,
      # so it is a no-op on every recording in this corpus. Measured rather than
      # argued: the position does not change.
      let before = h.session.getCurrentRRTicks()
      h.timeline.seekAtFraction(0.75)
      ck h.session.getCurrentRRTicks() == before
      ck h.session.drainEvents().len == 0

  test "a post-hoc tracepoint the dialog composes puts real diamonds on the bar":
    # THE `◆` HALF OF §3.3.5, end to end on a real recording, and the evidence
    # that `app/views/tracepoint_manager.nim` is a dialog over a surface that
    # exists rather than a form with nothing behind it.
    #
    # Both engine arms are exercised, because they answer DIFFERENT things and
    # only one of them can put a mark on a timeline:
    #
    #   * `setBreakpoints` with a `logMessage` — the DAP logpoint — VERIFIES the
    #     line, and its `output` events carry no tick;
    #   * `ct/run-tracepoints` — the post-hoc sweep — answers `Stop` rows that
    #     DO carry `rrTicks`, plus the locals the expression named.
    #
    # The line is chosen from the recorded program's own source, at the path the
    # BACKEND reported, so nothing here is a hardcoded line number.
    inc examinedFixtures
    let resolution = resolveFixture("calc")
      ## `calc` rather than `noir_space_ship`: its `add` helper is called five
      ## times from three different expressions, so a sweep has several hits to
      ## report and `left` is a local the expression can name.
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
      defer: closeHarness(h)

      let programPath = h.session.getCurrentFile()
      ck programPath.len > 0
      let sourceLines = splitSourceLines(readFile(programPath))
      var targetLine = 0
      for i, line in sourceLines:
        if line.strip() == AdditionStatement:
          targetLine = i + 1
          break
      checkpoint("tracepoint target: " & programPath & ":" & $targetLine)
      # THE PROGRAM REALLY SAYS THAT, asserted before it is used.
      ck targetLine > 0
      ck sourceLines[targetLine - 1].strip() == AdditionStatement

      # ---- THE DIALOG COMPOSES THE REQUEST --------------------------------
      var dialog = initTracepointManagerModel(open = true)
      dialog.draft = initTracepointDraft(path = programPath)
      ck dialog.applyKey(TracepointKeyEdit) == tmaEditBegan
      ck dialog.editing
      ck dialog.field == tfLine
      for ch in $targetLine:
        ck dialog.applyKey($ch) == tmaEdited
      ck dialog.applyKey(TracepointKeyNextField) == tmaEdited
      ck dialog.applyKey(TracepointKeyNextField) == tmaEdited
      ck dialog.field == tfExpression
      for ch in SweepExpression:
        ck dialog.applyKey($ch) == tmaEdited
      ck dialog.draft.line == targetLine
      ck dialog.draft.expression == SweepExpression
      ck dialog.draft.isComplete()
      ck dialog.applyKey(KeyEnter) == tmaSubmitted
      let request = dialog.sweepRequest()
      ck request.path == programPath
      ck request.line == targetLine
      ck request.expression == SweepExpression

      # ---- ARM ONE: THE ENGINE VERIFIES THE LOGPOINT ----------------------
      let verifyResponse = h.session.lastSetTracepointResponse(
        request.path, request.line, request.column, request.expression)
      discard h.session.drainEvents()
      ck verifyResponse.getOrDefault("success").getBool(false)
      let bound = verifyResponse["body"]["breakpoints"][0]
      checkpoint("setBreakpoints answered " & $bound)
      ck bound.getOrDefault("verified").getBool(false)
      ck bound.getOrDefault("line").getInt(0) == targetLine

      # ---- ARM TWO: THE SWEEP, WHICH IS THE ONE WITH TICKS ----------------
      # `ct/run-tracepoints` sends NO DAP RESPONSE — see
      # `headless_session.runTracepoints`'s header, and the hang that
      # established it. This call synchronises on the event.
      let hits = h.session.runTracepoints(@[TracepointSweepSpec(
        tracepointId: 0, path: request.path, line: request.line,
        expression: request.expression, lang: PythonDbLangOrdinal)])
      var hitTicks: seq[uint64] = @[]
      var values: seq[string] = @[]
      for hit in hits:
        hitTicks.add hit.rrTicks
        if hit.values.len > 0:
          values.add hit.values[0][1]
      echo "CTUI-8 TRACEPOINT SWEEP: ", request.path.extractFilename, ":",
           request.line, " '", request.expression, "' -> ", hits.len,
           " hit(s) at ", hitTicks, " with ", SweepLocalName, " = ", values
      ck hits.len > 1
      ck hitTicks.len == hits.len
      # EVERY HIT CARRIES A TICK AND THE ENGINE'S OWN LOCATION, and the ticks
      # ascend — a sweep is a walk of the recording.
      var ascending = true
      var wrongPath = 0
      var wrongLine = 0
      for i, hit in hits:
        if i > 0 and hit.rrTicks <= hits[i - 1].rrTicks:
          ascending = false
        if hit.path != programPath: inc wrongPath
        if hit.line != targetLine: inc wrongLine
      ck ascending
      ck wrongPath == 0
      ck wrongLine == 0
      ck hitTicks[0] > 0'u64
      # …AND THE EXPRESSION WAS EVALUATED: one named local per hit, and the
      # values are not all the same, so the sweep read the recording rather than
      # repeating one answer.
      ck values.len == hits.len
      ck hits[0].values[0][0] == SweepLocalName
      var distinctValues: seq[string] = @[]
      for value in values:
        if value notin distinctValues:
          distinctValues.add value
      ck distinctValues.len > 1

      # ---- THE HITS BECOME DIAMONDS, AND THE DIAMONDS ARE SEEKABLE --------
      var appHits: seq[TracepointHit] = @[]
      for hit in hits:
        appHits.add TracepointHit(tick: hit.rrTicks, path: hit.path,
                                  line: hit.line, values: hit.values)
      discard dialog.recordSubmission(tpsVerified, targetLine, 0, appHits)
      ck dialog.entries.len == 1
      ck dialog.hitCount() == hits.len
      let marks = marksFrom(dialog.entries)
      ck marks.len == hits.len
      ck marks[0].kind == tmkTracepoint
      ck marks[0].tick == hitTicks[0]

      let truth = wholeLog(h.session)
      let bounds = resolveBounds(h.timeline, @[], truth[0].maxRRTicks)
      ck bounds.known
      let barModel = timelineBarModelFor(h.timeline, bounds, @[], marks,
                                        currentTick = 0'u64)
      let barScreen = timelineBarScreen(barModel, BarWidth, BarHeight)
      let barRowText = rowText(barScreen.rows[1])
      checkpoint("scrubber with tracepoint marks: '" & barRowText & "'")
      ck barScreen.markColumns.len > 0
      ck barScreen.paintedMarks == barScreen.markColumns.len
      ck cellSlice(barRowText,
                   barScreen.trackCol + barScreen.markColumns[^1],
                   barScreen.trackCol + barScreen.markColumns[^1] + 1) ==
        MarkGlyph
      # A DISABLED TRACEPOINT CONTRIBUTES NO DIAMOND and keeps its hits, which is
      # the one behaviour `marksFrom` exists to have.
      dialog.selected = 0
      ck dialog.applyKey(TracepointKeyToggle) == tmaToggled
      ck not dialog.entries[0].draft.enabled
      ck dialog.entries[0].hits.len == hits.len
      ck marksFrom(dialog.entries).len == 0

      # ---- AND SEEKING TO ONE MOVES THE DEBUGGER --------------------------
      discard h.session.drainEvents()
      seekTo(h.timeline, hitTicks[^1])
      h.session.settleAfterSeek()
      ck bufferedStops(h) == 0
      ck h.session.getCurrentRRTicks() == hitTicks[^1]
      ck h.session.getCurrentLine() == targetLine
      ck h.session.getCurrentFile() == programPath

  test "assertion count":
    echo "CTUI-8 EVENT JUMP: examined ", examinedFixtures, " fixture case(s), ",
         verifiedFixtures, " verified, ", skippedFixtures, " skipped"
    ck examinedFixtures == 4
    ck verifiedFixtures + skippedFixtures == examinedFixtures
    ck verifiedFixtures > 0
    echo "CHECKS: " & $countedAssertions
    checkpoint("counted assertions: " & $countedAssertions)
    check countedAssertions == ExpectedAssertions
