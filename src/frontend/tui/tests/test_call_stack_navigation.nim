## test_call_stack_navigation.nim — CTUI-6, Tier 1, on a real trace.
##
## ## What this suite establishes
##
## CTUI-6: "on `noir_space_ship`: steps into a nested call, asserts the frame
## count the backend reports, navigates to an outer frame and asserts the source
## pane follows *and* that `DebugControlsVM`'s position did not change. The
## second half is the assertion that matters and the one an implementation is
## most likely to break."
##
## Both halves, on both arms of the case that makes the second half hard:
##
##   * the CROSS-FILE arm — after nine `stepIn`s the stack is
##     `iterate_asteroids@shield.nr | main@main.nr`, so selecting frame 1 puts
##     ANOTHER FILE on screen. The execution pointer must disappear, because
##     `SourceVM.executionLine` is a LINE with no file attached and drawing it
##     here would mark a line of `main.nr` the program has never executed;
##   * the SAME-FILE arm — after a calltrace jump the stack is three frames of
##     `shield.nr` under `main.nr`, so selecting frame 1 leaves the debugger's
##     own file on screen and BOTH cursors are visible at once, on two different
##     lines, in two different glyphs and colours.
##
## ## WHY THIS FILE IS NOT UNDER `app/tests/`, WHICH IS WHERE CTUI-6 NAMES IT
##
## The same reason CTUI-5 recorded for three of its four suites, unchanged:
## `tests/test_tui_facade_boundary.nim` walks every `.nim` under
## `src/frontend/tui/app/` and fails on an import resolving to
## `headless_session`, `backend/stdio_backend`, `std/osproc` or `std/posix`.
## This suite's subject is a real `HeadlessDebugSession` over a real
## `replay-server`, and `fixtures/fixture_provider.nim` shells out to `ct` to
## record. The `tui` lane globs `tests/test_*.nim` and `app/tests/test_*.nim`
## identically, so nothing about the coverage changes; the path does.
##
## ## NOTHING HERE IS A HARDCODED LINE NUMBER OR FRAME COUNT
##
## The frame count comes from the engine's own `stackTrace` — and from its
## `totalFrames` field, read separately and asserted to agree, so a paginated
## answer cannot masquerade as a complete stack. The lines come from the frames.
## The text under the cursor is read INDEPENDENTLY off disk at the path the
## BACKEND reported, so "the pane is showing the right line" is not the pane
## agreeing with itself.
##
## ## No mocks
##
## A real `.ct` trace recorded by real `nargo`, opened by a real
## `replay-server`, with source read through the production `SourceProvider`
## constructed with `allowWorkingTree = false` — so a working-tree read cannot
## rescue a payload the provider failed to open.
##
## ## Templates, not procs, for anything that calls `check`
##
## `std/unittest`'s `check` assigns `testStatusIMPL`, which the `test` template
## injects into its own scope; inside a `proc` that symbol is invisible, `check`
## takes its `else` branch, and the case still prints `[OK]` while
## `programResult` goes to 1.

import std/[json, monotimes, os, strutils, times, unicode, unittest]

import isonim/core/[signals, computation]
import isonim/viewmodel
import isonim_tui

import headless_session
import store/[replay_data_store, types]
import viewmodels/[calltrace_vm, debug_controls_vm, source_vm]
import sdk/source_provider
import headless_app/layout_model

import ../app/call_stack_binding
import ../app/input/call_stack_keys
import ../app/views/shell
import ./fixtures/fixture_provider

# One line, deliberately: `ci/lib/run-nim-test-lane.sh` reads exactly this
# spelling as a RUNTIME assertion count, and inside a `const` block the
# declaration is invisible to it.
const ExpectedAssertions = 113

var countedAssertions = 0

template ck(condition: untyped) =
  inc countedAssertions
  check condition

const
  FixtureName = "noir_space_ship"
  StackPaneWidth = 46
  StackPaneHeight = 17
  SourcePaneWidth = 56
  SourcePaneHeight = 17
    ## The `editor` rectangle the Compact profile gives at 80x24, from CTUI-3's
    ## measured table — the same geometry CTUI-5 measured its emission at.
  SourceViewport = SourcePaneHeight - 1
  MaxStepIns = 60
    ## Bound on the walk into a nested call. NINE was measured on this fixture
    ## (2026-09-05); the bound is generous so a re-recording on a new `nargo`
    ## that inlines differently fails on the assertion after the loop — with the
    ## depth it actually reached — rather than by hanging.
  LatencyFrames = 40

  ChecksSessionOpen = 7
  ChecksStepIn = 5
  ChecksClassification = 5
  ChecksPaneShape = 10
  ChecksSourceFollows = 12
    ## Per call of `checkSourceFollowsFrame`, which is called THREE times: the
    ## cross-file arm, the same-file arm with a viewport that shows both
    ## cursors, and the same-file arm with one too short to. All three assert
    ## the same NUMBER of things, which is why the template's two branches are
    ## the same length.
  ChecksDebuggerUnmoved = 6
    ## Per call of `checkDebuggerDidNotMove`, also twice.
  ChecksCrossFileArm = 8
  ChecksCalltraceCursor = 4
  ChecksSameFileArm = 10
  ChecksLatency = 7
  ChecksShellIntegration = 5
  ChecksSummary = 4
  ChecksSkippedFixture = 2

var
  examinedFixtures = 0
  verifiedFixtures = 0
  skippedFixtures = 0

# ---------------------------------------------------------------------------
# The harness
# ---------------------------------------------------------------------------

type NavHarness = object
  session: HeadlessDebugSession
  controls: DebugControlsVM
  calltrace: CalltraceVM
  provider: SourceProvider
  entryFile: string

proc openHarness(tracePath: string): NavHarness =
  let session = newHeadlessDebugSession(tracePath, findReplayServer())
  let store = session.session.store
  NavHarness(
    session: session,
    controls: createDebugControlsVM(store),
    calltrace: createCalltraceVM(store),
    # `allowWorkingTree = false` DELIBERATELY, and it matters more here than it
    # did for CTUI-5's `calc`: `noir_space_ship` is recorded from a program
    # still in this checkout, so a permissive provider would answer every
    # request off the working tree and the suite would pass without the trace
    # payload ever being opened.
    provider: newCtfsSourceProvider(tracePath, allowWorkingTree = false),
    entryFile: session.getCurrentFile())

proc closeHarness(h: NavHarness) =
  h.calltrace.dispose()
  h.controls.dispose()
  h.session.close()

proc reportedLocation(h: NavHarness): tuple[file: string; line: int] =
  ## The position `DebugControlsVM` reports, read through the VM's own store
  ## handle — the value every `can*` memo on it is computed from.
  let loc = h.controls.store.debugger.val.location
  (loc.file, loc.line)

proc reportedTick(h: NavHarness): uint64 =
  h.controls.store.debugger.val.rrTicks

proc stackBody(h: NavHarness): JsonNode =
  ## The engine's own `stackTrace` answer for the current stop.
  let response = h.session.sendRawDapRequest("stackTrace", %*{
    "threadId": 1, "startFrame": 0, "levels": 400,
  })
  discard h.session.drainEvents()
  response.getOrDefault("body")

proc serveOne(h: NavHarness; request: SourceLineRequest): SourceFetch =
  ## One request through the real provider, delivered.
  ##
  ## Seeded with a status that cannot be mistaken for success, and drained:
  ## `async_compat.onComplete` defers a callback even on an already-complete
  ## native future, and `SourceFetchStatus`'s zero value is `sfsAvailable`, so a
  ## callback that never ran would read as an empty file.
  result = SourceFetch(status: sfsProviderUnavailable,
                       detail: "the provider callback never ran")
  var captured = result
  h.provider.fetch(request, proc(fetch: SourceFetch) = captured = fetch)
  drainSourceCallbacks()
  result = captured

proc recordedProgramLine(path: string; line: int): string =
  ## The `line`-th line of the file at `path`, read straight off disk.
  ##
  ## The INDEPENDENT ground truth for "the pane is showing the right line". The
  ## provider above is built refusing the working tree, so this read is a second
  ## opinion rather than the provider's own answer echoed back.
  if not fileExists(path):
    return ""
  let lines = splitSourceLines(readFile(path))
  if line >= 1 and line <= lines.len: lines[line - 1] else: ""

proc rowStyleAt(row: StyledRow; cell: int): CellStyle =
  var at = 0
  for span in row:
    let w = cellWidthOf(span.text)
    if cell < at + w:
      return span.style
    at += w
  DefaultCellStyle

proc pointerFieldColumn(screen: SourcePaneScreen): int =
  ## The first cell of the source gutter's POINTER field, derived from the
  ## gutter's own layout rather than written down.
  max(0, screen.gutterWidth - GutterPointerCells - GutterGapCells)

proc pointerFieldText(screen: SourcePaneScreen; row: int): string =
  ## The three cells of the source gutter's POINTER FIELD on `row`.
  ##
  ## BY CELL POSITION, NOT BY SUBSTRING, and that is a correction this suite
  ## made after its first run rather than a precaution: `InspectionPointerGlyph`
  ## is `" > "`, and `shield.nr` contains ` > ` in ordinary source text, so a
  ## `contains` scan reported the cursor on two rows — one of them a comparison
  ## operator. The pointer field is at a known column derived from the gutter's
  ## own layout, and reading it is exact.
  result = ""
  if row < 0 or row >= screen.rows.len:
    return
  let col = pointerFieldColumn(screen)
  var at = 0
  for span in screen.rows[row]:
    for r in span.text.runes:
      let w = max(1, displayWidth($r))
      if at >= col and at < col + GutterPointerCells:
        result.add $r
      at += w

proc pointerFieldRows(screen: SourcePaneScreen; glyph: string): seq[int] =
  ## Every BODY row whose pointer field holds `glyph`.
  ##
  ## A SEQ rather than "the first one", so an assertion can be that there is
  ## EXACTLY one: a pane that drew a cursor on two rows would satisfy every
  ## "the cursor is on row R" check ever written. Row 0 is the title and has no
  ## gutter.
  result = @[]
  for i in 1 ..< screen.rows.len:
    if pointerFieldText(screen, i) == glyph:
      result.add i

# ---------------------------------------------------------------------------
# Assertion templates. Every helper that calls `check` is a TEMPLATE.
# ---------------------------------------------------------------------------

template checkSourceFollowsFrame(h: NavHarness; frame: StackFrame;
                                 model: SourcePaneModel;
                                 screen: SourcePaneScreen;
                                 expectExecution: bool) =
  ## The pane is showing the INSPECTED frame, and the execution pointer is
  ## present exactly when the debugger is in the file on screen.
  ck model.path == frame.path
  ck model.inspectionLine == frame.line
  let reported = h.reportedLocation()
  if expectExecution:
    ck model.executionLine == reported.line
  else:
    ck model.executionLine == 0

  let inspectionRows = pointerFieldRows(screen, InspectionPointerGlyph)
  let executionRows = pointerFieldRows(screen, ExecutionPointerGlyph)
  let bodyRows = screen.rows.len - 1
  let executionVisible = expectExecution and
    reported.line >= model.viewportTop and
    reported.line < model.viewportTop + bodyRows
  checkpoint("inspection rows " & $inspectionRows & ", execution rows " &
             $executionRows & ", viewportTop " & $model.viewportTop &
             ", execution line " & $reported.line & ", visible " &
             $executionVisible)
  ck inspectionRows.len == 1
  let wantRow = 1 + frame.line - model.viewportTop
  ck (if inspectionRows.len == 1: inspectionRows[0] else: -1) == wantRow
  ck rowStyleAt(screen.rows[wantRow], pointerFieldColumn(screen) + 1).fg ==
     InspectionPointerStyle.fg
  if executionVisible:
    ck executionRows.len == 1
    ck (if executionRows.len == 1: executionRows[0] else: -1) ==
       1 + reported.line - model.viewportTop
    # THE TWO CURSORS ARE ON TWO ROWS AND CARRY TWO COLOURS. This is CTUI-6's
    # contract as one assertion: a pane that conflated them would put both
    # glyphs on one row, or one glyph on both.
    ck executionRows != inspectionRows
  else:
    # The execution line is either in another file or scrolled out of this
    # window. EITHER WAY THE POINTER IS ABSENT rather than clamped to an edge:
    # a pointer parked on the first visible row would claim the program is
    # somewhere it is not, which is the same defect as drawing it in the wrong
    # file.
    ck executionRows.len == 0
    ck (if expectExecution: reported.line < model.viewportTop or
                            reported.line >= model.viewportTop + bodyRows
        else: model.executionLine == 0)
    ck inspectionRows.len == 1

  # …and the text on the inspected row is the text the recorded program really
  # has at that line, read independently off disk.
  let ground = recordedProgramLine(frame.path, frame.line).strip()
  ck ground.len > 0
  let shown = rowText(screen.rows[wantRow])
  ck shown.contains($frame.line)
  ck shown.contains(ground[0 ..< min(ground.len, screen.codeWidth - 6)])

template checkDebuggerDidNotMove(h: NavHarness;
                                 before: tuple[file: string; line: int];
                                 beforeTick: uint64) =
  ## THE ASSERTION THAT MATTERS. Selecting a frame is an inspection, and an
  ## inspection moves nothing.
  ##
  ## Asserted through three independent readers of the same fact, because one of
  ## them alone could be right for the wrong reason: `DebugControlsVM`'s store
  ## (what CTUI-6 names), the session's own getters (what the backend last
  ## reported), and the tick (which a jump would move even inside one line).
  let after = h.reportedLocation()
  checkpoint("position before " & before.file & ":" & $before.line &
             " @" & $beforeTick & ", after " & after.file & ":" &
             $after.line & " @" & $h.reportedTick())
  ck after == before
  ck h.reportedTick() == beforeTick
  ck h.session.getCurrentFile() == before.file
  ck h.session.getCurrentLine() == before.line
  ck h.session.getCurrentRRTicks() == beforeTick
  ck h.controls.store.debugger.val.status == dsIdle

# ---------------------------------------------------------------------------

suite "CTUI-6: the call stack pane navigates without moving the debugger":

  test "noir_space_ship: an outer frame is inspected, the debugger stays put":
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

      # ---- the session is really open, at a real position -----------------
      ck h.session.getDebuggerStatus() == dsIdle
      ck h.entryFile.len > 0
      ck h.provider.supports()
      let entryStack = framesFromStackTrace(h.stackBody())
      checkpoint("entry stack: " & $entryStack.len & " frame(s)")
      ck entryStack.len == 1
      ck entryStack[0].path == h.entryFile
      ck h.controls.store == h.session.session.store
      ck userRootsFor(h.entryFile).len == 1

      # ---- STEP INTO A NESTED CALL ----------------------------------------
      # `stepIn` really steps in: the walk stops as soon as the ENGINE reports
      # a deeper stack, and the assertion after the loop is on the depth the
      # engine reported rather than on the number of steps it took.
      var stepIns = 0
      var frames = entryStack
      while stepIns < MaxStepIns and frames.len < 2:
        h.session.stepIn()
        discard h.session.drainEvents()
        inc stepIns
        frames = framesFromStackTrace(h.stackBody())
      let body = h.stackBody()
      frames = framesFromStackTrace(body)
      echo "CTUI-6 STEP-IN WALK: " & $stepIns & " stepIn(s) to a " &
           $frames.len & "-frame stack at " & h.session.getCurrentFile() &
           ":" & $h.session.getCurrentLine()
      ck stepIns < MaxStepIns
      ck frames.len >= 2
      # THE FRAME COUNT THE BACKEND REPORTS, from its own `totalFrames` field
      # as well as from the array — an engine that paginated a deep stack would
      # answer fewer frames than it has, and a pane that trusted the array alone
      # would show a truncated stack as a complete one.
      ck reportedFrameCount(body) == frames.len
      # Frame 0 IS the stop: the engine's two answers about "where am I" agree.
      ck frames[0].path == h.session.getCurrentFile()
      ck frames[0].line == h.session.getCurrentLine()

      # ---- §3.3.3's user/library badge -------------------------------------
      var userFrames = 0
      let roots = userRootsFor(h.entryFile)
      for frame in frames:
        if classifyFrame(frame.path, roots) == foUser:
          inc userFrames
      checkpoint("frames classified user: " & $userFrames & " of " &
                 $frames.len & " against root " & $roots)
      # EVERY frame of this fixture is the recorded program's own, which is a
      # measured statement about the corpus rather than a property of the
      # classifier: no recorder in this workspace produces a trace whose stack
      # enters a library.
      ck userFrames == frames.len
      # …so the library arm is exercised through the same function on a
      # constructed path, and the boundary case that a prefix match would get
      # wrong is exercised too.
      ck classifyFrame("/nix/store/9r2c1v/lib/python3.12/runpy.py", roots) ==
         foLibrary
      ck classifyFrame("", roots) == foLibrary
      ck classifyFrame(roots[0] & "ile/other.nr", roots) == foLibrary
      ck classifyFrame(roots[0] & "/other.nr", roots) == foUser

      # ---- the pane's shape ------------------------------------------------
      var model = callStackModelFor(frames, h.entryFile)
      var screen = callStackScreen(model, StackPaneWidth, StackPaneHeight)
      checkpoint("pane rows:\n" &
                 callStackText(model, StackPaneWidth, StackPaneHeight)
                   .join("\n"))
      ck screen.rows.len == StackPaneHeight
      ck rowText(screen.rows[0]).contains(CallStackTitle)
      ck rowText(screen.rows[0]).contains($frames.len & " frame(s)")
      # NO GROUPING ON THIS FIXTURE, and that is a positive control on the
      # recursion suite rather than an absence: `noir_space_ship`'s stack has no
      # repeated frame, so a grouper that fired here would be grouping unrelated
      # calls.
      ck recursionRuns(frames).len == 0
      ck screen.groupRows == 0
      ck screen.frameRows == frames.len
      ck screen.visible.len == frames.len
      # Frame 0 carries BOTH markers to start with: it is where the debugger is
      # and it is what is being inspected.
      let firstRow = rowText(screen.rows[1])
      ck firstRow.startsWith(ExecutionFrameGlyph & InspectedFrameGlyph)
      ck firstRow.contains("#0")
      ck firstRow.contains(pathBaseName(frames[0].path) & ":" &
                           $frames[0].line)

      # ---- NAVIGATE TO AN OUTER FRAME, IN ANOTHER FILE ---------------------
      let before = h.reportedLocation()
      let beforeTick = h.reportedTick()
      let action = model.applyKey(KeyDown, screen)
      ck action == csaSelectionMoved
      ck model.selected == 1
      ck model.executionFrame == 0
      let outer = model.selectedFrame()
      checkpoint("outer frame: " & outer.name & " at " & outer.path & ":" &
                 $outer.line)
      # The arm this fixture was chosen for: the outer frame is in ANOTHER FILE.
      ck outer.path != frames[0].path

      let fetch = h.serveOne(frameSourceRequest(outer, SourceViewport))
      ck fetch.status == sfsAvailable
      ck fetch.origin == soTracePayload
      ck fetch.lines.len > 0
      let outerModel = sourcePaneModelForFrame(
        outer, fetch, h.session.session.store.degraded.sourceAvailability.val,
        debuggerPath = before.file, debuggerLine = before.line,
        viewportHeight = SourceViewport)
      let outerScreen = sourcePaneScreen(outerModel, SourcePaneWidth,
                                         SourcePaneHeight)
      checkSourceFollowsFrame(h, outer, outerModel, outerScreen,
                              expectExecution = false)
      ck outerScreen.loadingLines == 0

      # ---- …AND THE DEBUGGER DID NOT MOVE ----------------------------------
      checkDebuggerDidNotMove(h, before, beforeTick)

      # ---- the inspection cursor lives in `CalltraceVM` ---------------------
      # `selectEntry` writes one signal and issues no backend command, which is
      # what makes it the right home for a cursor that must not move the
      # program. Asserted by moving it and re-checking the position.
      ck inspectionCursorFrom(h.calltrace) == -1
      publishInspectionCursor(h.calltrace, model.selected)
      ck inspectionCursorFrom(h.calltrace) == model.selected
      ck h.reportedLocation() == before
      ck h.reportedTick() == beforeTick

      # ---- THE SAME-FILE ARM: BOTH CURSORS ON ONE SCREEN -------------------
      # A calltrace jump takes the session to a stop three calls deep, where the
      # two outer frames are in the SAME file as the stop. Selecting one leaves
      # the execution pointer on screen, so the pane has to show two cursors at
      # once — the case where conflating them is easiest and worst.
      h.session.requestAndLoadCalltrace(depth = 200, height = 400)
      var jumpTarget = CallLine(index: -1)
      for callLine in h.session.getCalltraceLines():
        if callLine.depth >= 3:
          jumpTarget = callLine
          break
      ck jumpTarget.index >= 0
      h.session.calltraceJumpByLine(jumpTarget)
      discard h.session.drainEvents()
      let deepBody = h.stackBody()
      let deepFrames = framesFromStackTrace(deepBody)
      echo "CTUI-6 DEEP STOP: " & $deepFrames.len & " frame(s) at " &
           h.session.getCurrentFile() & ":" & $h.session.getCurrentLine()
      ck deepFrames.len >= 3
      ck reportedFrameCount(deepBody) == deepFrames.len
      ck deepFrames[1].path == deepFrames[0].path

      var deepModel = callStackModelFor(deepFrames, h.entryFile)
      let deepScreen = callStackScreen(deepModel, StackPaneWidth,
                                       StackPaneHeight)
      let deepBefore = h.reportedLocation()
      let deepBeforeTick = h.reportedTick()
      ck deepModel.applyKey(KeyDown, deepScreen) == csaSelectionMoved
      let sameFileFrame = deepModel.selectedFrame()
      ck sameFileFrame.path == deepBefore.file
      ck sameFileFrame.line != deepBefore.line

      # THE PANE IS SIZED FROM THE DATA, not from a round number. The two
      # cursors are `|inspected - stopped|` lines apart — 26 on this fixture —
      # and a viewport shorter than that cannot show both however correct the
      # pane is. So the height is derived from the distance the BACKEND
      # reported, and the small-viewport case (the execution line scrolled out)
      # is asserted separately below rather than being the case that happened
      # to occur.
      let cursorDistance = abs(sameFileFrame.line - deepBefore.line)
      let bothViewport = max(SourceViewport, 2 * cursorDistance + 6)
      echo "CTUI-6 TWO CURSORS: inspected line " & $sameFileFrame.line &
           ", execution line " & $deepBefore.line & ", " & $cursorDistance &
           " apart, viewport " & $bothViewport
      let deepFetch = h.serveOne(frameSourceRequest(sameFileFrame,
                                                    bothViewport))
      ck deepFetch.status == sfsAvailable
      let sameFileModel = sourcePaneModelForFrame(
        sameFileFrame, deepFetch,
        h.session.session.store.degraded.sourceAvailability.val,
        debuggerPath = deepBefore.file, debuggerLine = deepBefore.line,
        viewportHeight = bothViewport)
      let sameFileScreen = sourcePaneScreen(sameFileModel, SourcePaneWidth,
                                            bothViewport + 1)
      checkSourceFollowsFrame(h, sameFileFrame, sameFileModel, sameFileScreen,
                              expectExecution = true)
      checkDebuggerDidNotMove(h, deepBefore, deepBeforeTick)

      # ---- THE SAME FRAME IN A VIEWPORT TOO SHORT TO SHOW BOTH -------------
      # The state is unchanged — `executionLine` still says where the debugger
      # is — and the pointer is simply not on this window. Asserted because the
      # tempting implementation of "keep the execution pointer visible" is to
      # clamp it to the nearest edge, which is a pane lying about the program's
      # position rather than admitting it is off screen.
      let shortModel = sourcePaneModelForFrame(
        sameFileFrame, deepFetch,
        h.session.session.store.degraded.sourceAvailability.val,
        debuggerPath = deepBefore.file, debuggerLine = deepBefore.line,
        viewportHeight = SourceViewport)
      let shortScreen = sourcePaneScreen(shortModel, SourcePaneWidth,
                                         SourcePaneHeight)
      ck shortModel.executionLine == deepBefore.line
      ck cursorDistance > SourceViewport div 2
      checkSourceFollowsFrame(h, sameFileFrame, shortModel, shortScreen,
                              expectExecution = true)

      # ---- THE VERIFICATION GATE: frame selection to source display < 10 ms
      # Measured on the path a keystroke really takes — apply the key, build the
      # source model for the newly selected frame, paint the pane — with the
      # frames' windows already held, because a fetch is I/O over a spawned
      # process and is reported separately below rather than folded into a gate
      # about the front-end.
      # MEASURED ON THE CACHED HIGHLIGHTING PATH, which is what CTUI-5's risk
      # mitigation established the gate is measured on — and it is CHECKABLE
      # rather than claimed: the cache is warmed with every frame's window
      # first, and the loop is asserted to have added no parse. The cold parse
      # and the provider fetch are echoed as SEPARATE numbers so a regression in
      # either is attributable.
      var windows: seq[SourceFetch] = @[]
      for frame in deepFrames:
        windows.add h.serveOne(frameSourceRequest(frame, SourceViewport))
      let cache = newHighlighterCache()

      template modelForFrame(picked: StackFrame): SourcePaneModel =
        sourcePaneModelForFrame(
          picked, windows[picked.index],
          h.session.session.store.degraded.sourceAvailability.val,
          debuggerPath = deepBefore.file, debuggerLine = deepBefore.line,
          viewportHeight = SourceViewport)

      for frame in deepFrames:
        discard sourcePaneScreen(modelForFrame(frame), SourcePaneWidth,
                                 SourcePaneHeight, cache)
      let parsesBeforeLatency = cache.parseCount
      var bestMs = 1.0e9
      var samples = 0
      var paintedRows = 0
      for i in 1 .. LatencyFrames:
        var frameModel = callStackModelFor(deepFrames, h.entryFile)
        let paneScreen = callStackScreen(frameModel, StackPaneWidth,
                                         StackPaneHeight)
        let t0 = getMonoTime()
        discard frameModel.applyKey(
          (if i mod 2 == 0: KeyDown else: KeyBottom), paneScreen)
        let picked = frameModel.selectedFrame()
        let s = sourcePaneScreen(modelForFrame(picked), SourcePaneWidth,
                                 SourcePaneHeight, cache)
        let ms = (getMonoTime() - t0).inMicroseconds.float / 1000.0
        paintedRows += s.rows.len
        inc samples
        if ms < bestMs: bestMs = ms
      let parsesAfterLatency = cache.parseCount

      # THE SAME WALK WITH NO CACHE AT ALL — the cost of a selection into a
      # window nothing has parsed yet, which is what a user's FIRST visit to a
      # frame really pays. Reported rather than gated, for the reason CTUI-5's
      # risk mitigation gives (the gate is measured on the cached path), but
      # reported because the difference is the whole justification for the
      # cache and a reader should not have to add two numbers to find it.
      var uncachedBest = 1.0e9
      for i in 1 .. LatencyFrames:
        var frameModel = callStackModelFor(deepFrames, h.entryFile)
        let paneScreen = callStackScreen(frameModel, StackPaneWidth,
                                         StackPaneHeight)
        let t0 = getMonoTime()
        discard frameModel.applyKey(
          (if i mod 2 == 0: KeyDown else: KeyBottom), paneScreen)
        discard sourcePaneScreen(modelForFrame(frameModel.selectedFrame()),
                                 SourcePaneWidth, SourcePaneHeight)
        let ms = (getMonoTime() - t0).inMicroseconds.float / 1000.0
        if ms < uncachedBest: uncachedBest = ms

      let coldStart = getMonoTime()
      discard highlightWindow(windows[0].revision.path, windows[0].firstLine,
                              windows[0].lines)
      let coldMs = (getMonoTime() - coldStart).inMicroseconds.float / 1000.0
      let fetchStart = getMonoTime()
      discard h.serveOne(frameSourceRequest(deepFrames[0], SourceViewport))
      let fetchMs = (getMonoTime() - fetchStart).inMicroseconds.float / 1000.0
      echo "CTUI-6 FRAME-SELECTION LATENCY (cached highlight): best " &
           formatFloat(bestMs, ffDecimal, 3) & " ms over " & $LatencyFrames &
           " selections (gate < 10); UNCACHED best " &
           formatFloat(uncachedBest, ffDecimal, 3) &
           " ms; COLD parse of the same window: " &
           formatFloat(coldMs, ffDecimal, 3) &
           " ms; one provider FETCH of it: " &
           formatFloat(fetchMs, ffDecimal, 3) & " ms"
      ck samples == LatencyFrames
      ck paintedRows == LatencyFrames * SourcePaneHeight
      ck bestMs < 10.0
      ck fetchMs > 0.0
      # The gate was measured on the cached path, and forty selections added no
      # parse.
      ck parsesAfterLatency == parsesBeforeLatency
      ck parsesBeforeLatency >= 1
      # The cache is what the gate rests on, and the margin is a MEASURED
      # number rather than an argument: an uncached selection costs strictly
      # more, on the same host in the same run.
      ck uncachedBest > bestMs

      # ---- THE SHELL PAINTS THE PANE INTO THE `calltrace` RECTANGLE --------
      # CTUI-3 delivered the rectangle and left it empty; CTUI-5 filled the
      # `editor` one. This is the assertion that the `calltrace` one is no
      # longer empty and that what fills it is EXACTLY this pane.
      var shellModel = newShellModel(80, 24)
      shellModel.callStack = deepModel
      let screenBody = bodyArea(80, 24)
      let stackArea = projectLayout(shellModel.layout,
                                    screenBody).regionFor(paneCalltrace)
      ck stackArea.width > 0
      ck stackArea.height > 0
      # THE PANE IS NOT FLUSH RIGHT, so the shell keeps the last column for its
      # own separator and hands the pane `width - 1`. Derived from the geometry
      # exactly as `shell.paintPane` derives it, rather than assumed: the
      # `editor` rectangle CTUI-5 compared IS flush right, so a comparison
      # copied from that suite would fail here for a reason that is not a
      # defect.
      let flushRight = stackArea.col + stackArea.width >= screenBody.col + screenBody.width
      let inner = if flushRight: stackArea.width else: stackArea.width - 1
      let shellText = shellRows(shellModel, 80, 24)
      let standalone = callStackText(deepModel, inner, stackArea.height)
      var matched = 0
      var separators = 0
      for i in 0 ..< stackArea.height:
        let row = shellText[stackArea.row + i]
        var slice = ""
        var edge = ""
        var at = 0
        for r in row.runes:
          let w = max(1, displayWidth($r))
          if at >= stackArea.col and at < stackArea.col + inner:
            slice.add $r
          elif at == stackArea.col + stackArea.width - 1:
            edge = $r
          at += w
        if slice == standalone[i]:
          inc matched
        if flushRight or edge == PaneSeparatorGlyph:
          inc separators
      ck matched == stackArea.height
      ck separators == stackArea.height
      # …and the pane still says what CTUI-3's plain title row said, so every
      # assertion written against that row keeps reading it.
      ck shellText[stackArea.row].contains(CallStackTitle)

  test "every fixture was examined, and the assertion tally proves it":
    ck examinedFixtures == 1
    ck verifiedFixtures + skippedFixtures == examinedFixtures
    ck verifiedFixtures >= 1
    let expected =
      verifiedFixtures * (
        ChecksSessionOpen + ChecksStepIn + ChecksClassification +
        ChecksPaneShape + ChecksCrossFileArm + ChecksCalltraceCursor +
        ChecksSameFileArm + ChecksLatency + ChecksShellIntegration +
        3 * ChecksSourceFollows + 2 * ChecksDebuggerUnmoved) +
      skippedFixtures * ChecksSkippedFixture +
      ChecksSummary
    checkpoint("counted " & $countedAssertions & ", derived " & $expected)
    ck countedAssertions == expected

  test "assertion count":
    echo "CHECKS: " & $countedAssertions
    checkpoint("counted assertions: " & $countedAssertions)
    check countedAssertions == ExpectedAssertions
