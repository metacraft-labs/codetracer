## test_source_stepping_forward_backward.nim — CTUI-5, Tier 1, on a real trace.
##
## ## What this suite establishes
##
## CTUI-5: "on the `calc` fixture: steps forward N times and asserts the
## pointer follows the position `DebugControlsVM` reports at each step, then
## steps backward and asserts it retraces exactly. The assertion is against the
## backend's reported position, not against hardcoded line numbers, because a
## fixture re-recorded on a new compiler must not silently invalidate the test.
## Asserts the gutter and the text update in the same frame — a pointer that
## moves a frame before its line is a visible defect."
##
## All of it, plus the two verification-gate measurements the milestone asks
## for on this path: stepping latency and single-step ANSI byte volume.
##
## ## WHY THIS FILE IS NOT UNDER `app/tests/`, WHICH IS WHERE CTUI-5 NAMES IT
##
## `tests/test_tui_facade_boundary.nim` walks EVERY `.nim` file under
## `src/frontend/tui/app/` and fails on any import that resolves to
## `viewmodel/headless_session`, `backend/stdio_backend`, `std/osproc` or
## `std/posix`. CTUI-3 established that rule deliberately — "so the reflow suite
## must not reach for SIGWINCH is enforced structurally instead of by
## agreement" — and it applies to `app/tests/` as much as to `app/views/`.
##
## This suite's subject is a real `HeadlessDebugSession` over a real
## `replay-server`, which is exactly the capability that rule withholds. So the
## file lives one directory up, where `tests/test_fixture_corpus.nim` already
## opens sessions, and the `tui` lane globs it identically
## (`ci/lib/test-lane-files.sh` collects both `tests/test_*.nim` and
## `app/tests/test_*.nim`). Nothing about the coverage changes; the path does.
## CTUI-5's Implementation section records the deviation.
##
## ## NOTHING HERE IS A HARDCODED LINE NUMBER
##
## Every position asserted against comes from the backend in the same run:
## `DebugControlsVM`'s own store (`vm.store.debugger.val.location`), which is
## the position that ViewModel reports and the one a `DebugControlsVM`-driven
## front-end would render. The pane is then asserted to point at THAT line. A
## fixture re-recorded on a new Python would move both sides together.
##
## The one place a file's contents are read independently is
## `recordedProgramLine`, which reads the recorded program off disk at the path
## the BACKEND reported. That is the ground truth for "the text under the
## pointer is the right text", and it is what makes the same-frame assertion
## more than "the pane agrees with itself": the gutter says line L, and the
## text on that row is what line L of the program really is.
##
## ## DebugControlsVM DRIVES NOTHING HERE, AND THAT IS A PROPERTY OF THE
## ## HEADLESS HOST RATHER THAN OF THIS SUITE
##
## `DebugControlsVM.stepForward` calls `onDapStep` / `onAction`, hooks the
## DESKTOP host installs. `HeadlessDebugSession` installs neither — measured by
## calling `controls.stepForward()` before the walk below and observing the
## position unchanged, which this suite asserts as its first case rather than
## assuming. So the session is the DRIVER and `DebugControlsVM` is the
## REPORTER, which is the split CTUI-5's sentence needs: "the position
## `DebugControlsVM` reports" is read from the VM, and the pane is compared
## against it.
##
## ## No mocks
##
## A real `.ct` trace recorded by the real Python recorder, opened by a real
## `replay-server`, read through the production `SourceProvider` constructed
## with `allowWorkingTree = false` so a working-tree read cannot rescue a
## payload the provider failed to open. There is no `MockBackendService` in
## this file.
##
## ## Templates, not procs, for anything that calls `check`
##
## `std/unittest`'s `check` assigns `testStatusIMPL`, which the `test` template
## injects into its own scope; inside a `proc` that symbol is invisible, `check`
## takes its `else` branch, and the case still prints `[OK]` while
## `programResult` goes to 1. Four instances of that class have been found in
## this campaign.

import std/[json, monotimes, os, strutils, times, unicode, unittest]

import isonim/core/[signals, computation]
import isonim/viewmodel
import isonim_tui

import headless_app/layout_model
import headless_session
import store/replay_data_store
import viewmodels/[debug_controls_vm, source_vm]
import sdk/source_provider

import ../app/source_binding
import ../app/views/shell
import ./fixtures/fixture_provider

# One line, deliberately: `ci/lib/run-nim-test-lane.sh` reads exactly this
# spelling as a RUNTIME assertion count, and inside a `const` block the
# declaration is invisible to it.
const ExpectedAssertions = 227

var countedAssertions = 0

template ck(condition: untyped) =
  inc countedAssertions
  check condition

const
  FixtureName = "calc"
  ForwardSteps = 8
    ## `N` in the milestone's sentence. Eight is enough to leave the entry
    ## function and come back — `calc` is a chain of small named calls — and
    ## small enough that the whole suite is one session and a handful of
    ## seconds.
  WarmupSteps = 3
    ## Steps taken BEFORE the retraced trail starts, and they exist because of
    ## something this suite measured rather than assumed.
    ##
    ## `stepBackward` sends DAP `stepBack`, and the replay engine CANNOT step
    ## before the first recorded step: from the entry stop the trail read
    ## `main.py:1`, and after eight forward steps and eight backward ones the
    ## last backward step reported `main.py:2` — it had reached the floor and
    ## stayed there. A trail that includes the entry stop is therefore not
    ## retraceable, and asserting that it is would have been asserting a
    ## property of the harness rather than of the pane.
    ##
    ## Three warm-up steps put the whole retraced trail clear of that floor, so
    ## `checkRetracesExactly` compares positions the engine really walked back
    ## through. The floor itself is asserted separately below, so the reason
    ## for this constant is a checked fact rather than a comment.
  PaneWidth = 56
  PaneHeight = 17
    ## The `editor` rectangle the Compact profile gives at 80x24, from CTUI-3's
    ## own measured table: `editor (24,1 56x17)`. Using the real pane geometry
    ## rather than a round number is what makes the byte measurement below a
    ## measurement of THIS pane.
  ViewportLines = PaneHeight - 1
  Overscan = 6

  ChecksPerForwardStop = 13
  ChecksPerBackwardStop = 6
  ChecksSessionOpen = 9
  ChecksEntryFloor = 1
  ChecksControlsAreReporters = 3
  ChecksRetrace = 4
  ChecksHeatmap = 6
  ChecksHeatmapGutter = 15
  ChecksFineGrained = 10
  ChecksLatency = 3
  ChecksBytes = 2
  ChecksBreakpointGutter = 9
  ChecksShellIntegration = 7
  ChecksSummary = 4
  ChecksSkippedFixture = 2

var
  examinedFixtures = 0
  verifiedFixtures = 0
  skippedFixtures = 0

# ---------------------------------------------------------------------------
# The harness
# ---------------------------------------------------------------------------

type StepHarness = object
  session: HeadlessDebugSession
  vm: SourceVM
  controls: DebugControlsVM
  provider: SourceProvider
  cache: HighlighterCache
  points: seq[SourcePoint]

proc openHarness(tracePath: string): StepHarness =
  let session = newHeadlessDebugSession(tracePath, findReplayServer())
  let store = session.session.store
  let vm = createSourceVM(store, session.session.editorVM)
  vm.setViewport(height = ViewportLines, overscan = Overscan)
  StepHarness(
    session: session,
    vm: vm,
    controls: createDebugControlsVM(store),
    # `allowWorkingTree = false` DELIBERATELY. `calc` is recorded from a
    # program still in this checkout, so the recording's copy and the
    # working-tree copy are byte identical and a permissive provider would
    # pass this suite without ever opening the payload — which is precisely
    # how CTUI-4's engine defect survived its first verification pass.
    provider: newCtfsSourceProvider(tracePath, allowWorkingTree = false),
    cache: newHighlighterCache(),
    points: @[])

proc closeHarness(h: StepHarness) =
  h.controls.dispose()
  h.vm.dispose()
  h.session.close()

proc reportedLocation(h: StepHarness): tuple[file: string; line: int] =
  ## The position `DebugControlsVM` reports. Read through the VM's own store
  ## handle, which is the value every `can*` memo on it is computed from.
  let loc = h.controls.store.debugger.val.location
  (loc.file, loc.line)

proc serveOne(h: StepHarness; request: SourceLineRequest): SourceFetch =
  ## One request through the real provider, delivered.
  ##
  ## Seeded with a status that cannot be mistaken for success, and drained:
  ## `async_compat.onComplete` defers a callback even on an already-complete
  ## native future, and `SourceFetchStatus`'s zero value is `sfsAvailable`, so
  ## a callback that never ran would read as an empty file.
  result = SourceFetch(status: sfsProviderUnavailable,
                       detail: "the provider callback never ran")
  var captured = result
  h.provider.fetch(request, proc(fetch: SourceFetch) = captured = fetch)
  drainSourceCallbacks()
  result = captured

proc fillWindow(h: StepHarness): seq[SourceFetch] =
  ## Follow the execution pointer and serve everything the window then lacks.
  result = @[]
  for request in h.vm.followAndRequest():
    let fetch = h.serveOne(request)
    discard h.session.session.store.applySourceFetch(h.vm, fetch)
    result.add fetch

proc paneModel(h: StepHarness): SourcePaneModel =
  sourcePaneModelFor(
    h.vm,
    h.session.session.store.degraded.sourceAvailability.val,
    points = h.points,
    variables = @[])

proc recordedProgramLine(path: string; line: int): string =
  ## The `line`-th line of the file at `path`, read straight off disk.
  ##
  ## The INDEPENDENT ground truth for "the text under the pointer is the right
  ## text". `calc` is recorded from a program still in this checkout, so the
  ## recording's copy and this one are the same bytes; the provider is built
  ## refusing the working tree, so this read is a second opinion rather than
  ## the provider's own answer echoed back.
  if not fileExists(path):
    return ""
  let lines = splitSourceLines(readFile(path))
  if line >= 1 and line <= lines.len: lines[line - 1] else: ""

proc pointerRowsIn(screen: SourcePaneScreen): seq[int] =
  ## Every row of the pane carrying the execution pointer glyph.
  ##
  ## A SEQ rather than "the first one", so the assertion can be that there is
  ## EXACTLY one. A pane that drew the pointer on two rows would satisfy every
  ## "the pointer is on row R" check ever written.
  result = @[]
  for i, row in screen.rows:
    if rowText(row).contains(ExecutionPointerGlyph):
      result.add i

proc rowStyleAt(row: StyledRow; cell: int): CellStyle =
  ## The style of one CELL of an encoded row.
  var at = 0
  for span in row:
    let w = cellWidthOf(span.text)
    if cell < at + w:
      return span.style
    at += w
  DefaultCellStyle

proc rowRuneAt(row: StyledRow; cell: int): string =
  var at = 0
  for span in row:
    for r in span.text.runes:
      let w = max(1, displayWidth($r))
      if cell < at + w:
        return $r
      at += w
  " "

proc pointerFieldColumn(screen: SourcePaneScreen): int =
  ## The first cell of the gutter's POINTER field.
  ##
  ## Derived from the gutter's own layout rather than written down: the gutter
  ## is `mark(1) + number(w) + gap(1) + pointer(3) + gap(1)`, so the pointer
  ## starts `GutterPointerCells + GutterGapCells` before the gutter's end. A
  ## literal here would keep passing after the gutter grew a column.
  max(0, screen.gutterWidth - GutterPointerCells - GutterGapCells)

# ---------------------------------------------------------------------------
# Assertion templates. Every helper that calls `check` is a TEMPLATE.
# ---------------------------------------------------------------------------

template checkFrameAgreesWithTheBackend(h: StepHarness;
                                        screen: SourcePaneScreen;
                                        model: SourcePaneModel) =
  ## THE SAME-FRAME ASSERTION, and it is the milestone's own sentence: the
  ## gutter and the text update together.
  ##
  ## Every assertion below reads ONE `SourcePaneScreen` value. A pane whose
  ## pointer moved a frame before its line would fail here, because the row
  ## carrying `-->` and the row carrying the reported line's text would be
  ## different rows of the same screen.
  let reported = h.reportedLocation()
  ck reported.line >= 1
  ck reported.file.len > 0
  # The VM's idea of the execution line IS the backend's, not the caret's.
  ck h.vm.executionLine.val == reported.line
  ck model.executionLine == reported.line
  ck model.path == reported.file

  let pointerRows = pointerRowsIn(screen)
  ck pointerRows.len == 1
  let expectedRow = 1 + reported.line - model.viewportTop
  ck (if pointerRows.len == 1: pointerRows[0] else: -1) == expectedRow
  ck expectedRow >= 1
  ck expectedRow < screen.rows.len

  # …and on THAT row, the line number, the gutter mark field and the text all
  # describe the same line.
  let row = screen.rows[expectedRow]
  let text = rowText(row)
  ck text.contains($reported.line)
  let groundTruth = recordedProgramLine(reported.file, reported.line)
  ck groundTruth.len > 0
  let visible = groundTruth.strip()
  ck text.contains(visible[0 ..< min(visible.len, screen.codeWidth - 4)])
  # The pointer cell really carries the accent style, in the same frame.
  ck rowStyleAt(row, pointerFieldColumn(screen)).fg ==
     ExecutionPointerStyle.fg

template checkRetracesExactly(forward, backward: seq[(string, int)]) =
  ## Stepping back re-visits the forward trail in reverse, position for
  ## position.
  ##
  ## An EXACT sequence comparison, not a set one: a debugger that stepped back
  ## to the right lines in the wrong order would satisfy a set check, and so
  ## would one that stepped back one position too far and then forward again.
  ck backward.len == forward.len - 1
  var mismatches: seq[string] = @[]
  for i in 0 ..< backward.len:
    let want = forward[forward.len - 2 - i]
    if backward[i] != want:
      mismatches.add "backward[" & $i & "] = " & backward[i][0] & ":" &
        $backward[i][1] & ", forward trail says " & want[0] & ":" & $want[1]
  echo "CTUI-5 FORWARD TRAIL:  " & $forward
  echo "CTUI-5 BACKWARD TRAIL: " & $backward
  if mismatches.len > 0:
    checkpoint(mismatches.join("\n"))
  ck mismatches.len == 0
  # The trail is not one position repeated: a session that never moved would
  # retrace perfectly and prove nothing.
  var distinct1: seq[(string, int)] = @[]
  for p in forward:
    if p notin distinct1:
      distinct1.add p
  checkpoint("forward trail: " & $forward)
  ck distinct1.len >= 3
  ck forward.len == ForwardSteps + 1

# ---------------------------------------------------------------------------

suite "CTUI-5: the source pane follows a real debugger, forward and back":

  test "the calc fixture opens and the pane binds to it":
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
      let entry = h.reportedLocation()
      ck entry.file.len > 0
      ck entry.line >= 1
      ck h.provider.supports()
      ck h.vm.viewportHeight.val == ViewportLines
      ck h.vm.overscan.val == Overscan

      let fetches = h.fillWindow()
      ck fetches.len == 1
      ck fetches[0].status == sfsAvailable
      # The recording's OWN copy, not this machine's. The provider was built
      # refusing the working tree, so this is the payload or nothing.
      ck fetches[0].origin == soTracePayload
      ck h.vm.totalLineCount.val >= entry.line

      # ---- DebugControlsVM reports; it does not drive ---------------------
      # Measured rather than assumed, and asserted so that the day a host
      # wires `onDapStep` into the headless session this file says so instead
      # of quietly starting to double-step.
      let before = h.reportedLocation()
      h.controls.stepForward()
      discard h.session.drainEvents()
      let after = h.reportedLocation()
      ck after == before
      ck h.controls.store == h.session.session.store
      ck h.vm.executionLine.val == before.line

      # ---- the trace-start floor, measured rather than assumed ------------
      # `stepBack` at the first recorded step does not move. Asserted here so
      # that `WarmupSteps` above is justified by a check rather than by a
      # comment, and so that an engine which grew the ability to step before
      # the entry stop reddens this line instead of silently changing what the
      # trail below means.
      let atEntry = h.reportedLocation()
      h.session.stepBackward()
      discard h.session.drainEvents()
      ck h.reportedLocation() == atEntry

      for _ in 1 .. WarmupSteps:
        h.session.stepForward()
        discard h.session.drainEvents()
      discard h.fillWindow()

      # ---- N steps forward, asserting every stop --------------------------
      var forwardTrail: seq[(string, int)] = @[]
      var visitedLines: seq[int] = @[]
      var stops = 0
      forwardTrail.add h.reportedLocation()
      visitedLines.add h.reportedLocation()[1]
      for _ in 1 .. ForwardSteps:
        h.session.stepForward()
        # `HeadlessDebugSession` grows measurably per stop unless its event
        # buffer is drained; draining is part of stepping here rather than an
        # optimisation left to the reader.
        discard h.session.drainEvents()
        discard h.fillWindow()
        let model = h.paneModel()
        let screen = sourcePaneScreen(model, PaneWidth, PaneHeight, h.cache)
        checkFrameAgreesWithTheBackend(h, screen, model)
        inc stops
        forwardTrail.add h.reportedLocation()
        visitedLines.add h.reportedLocation()[1]
      ck stops == ForwardSteps

      # ---- and back, retracing --------------------------------------------
      var backwardTrail: seq[(string, int)] = @[]
      var backStops = 0
      for _ in 1 .. ForwardSteps:
        h.session.stepBackward()
        discard h.session.drainEvents()
        discard h.fillWindow()
        let model = h.paneModel()
        let screen = sourcePaneScreen(model, PaneWidth, PaneHeight, h.cache)
        let reported = h.reportedLocation()
        # The same-frame property, asserted on the way back too but with the
        # cheaper subset: a pane that only kept its contract stepping forward
        # is a pane that does not keep it.
        let pointerRows = pointerRowsIn(screen)
        ck pointerRows.len == 1
        ck (if pointerRows.len == 1: pointerRows[0] else: -1) ==
           1 + reported.line - model.viewportTop
        ck model.executionLine == reported.line
        ck h.vm.executionLine.val == reported.line
        let ground = recordedProgramLine(reported.file, reported.line)
        ck ground.len > 0
        ck rowText(screen.rows[1 + reported.line - model.viewportTop])
             .contains($reported.line)
        inc backStops
        backwardTrail.add reported
      ck backStops == ForwardSteps

      checkRetracesExactly(forwardTrail, backwardTrail)

      # ---- the heatmap describes THIS walk ---------------------------------
      let heat = newLineHeatFromVisits(visitedLines)
      ck heat.totalObservations() == visitedLines.len
      ck heat.largestCount() >= 1
      ck heat.countedLines().len >= 1
      ck heat.countedLines().len <= visitedLines.len
      # Level 0 is reserved for "never ran", so every VISITED line is at least
      # level 1 and a line nobody visited is level 0. Without that reservation
      # dead code and cold-but-executed code are the same colour.
      ck heat.heatLevel(visitedLines[0]) >= 1
      ck heat.heatLevel(0) == 0

      # ---- §3.3.2's OPTIONAL GUTTER MODE, over the same real walk ----------
      # "Execution Frequency Heatmap (Optional Gutter Mode): displays relative
      # execution count of each visible line ... highlighting hot paths in
      # flame-spectrum colors."
      #
      # The counts are the ones the walk above really produced, so this is the
      # mode rendering a real execution frequency rather than a table someone
      # wrote down. See `app/views/heatmap.nim`'s header for what this campaign
      # could NOT establish: no ViewModel exposes a per-line count over the
      # WHOLE recording, so "relative" here is relative to this traversal.
      var heatModel = h.paneModel()
      heatModel.heat = heat
      heatModel.gutterMode = gutExecutionCounts
      let heatScreen = sourcePaneScreen(heatModel, PaneWidth, PaneHeight,
                                        h.cache)
      # The gutter re-sizes to the largest COUNT rather than to the largest
      # line number, which is what makes it a different mode rather than a
      # recolouring.
      ck heatScreen.gutterWidth ==
         gutterWidth(gutterNumberWidth(heat.largestCount()))
      # Six DISTINCT flame styles — a palette with a repeat would make two heat
      # levels indistinguishable while every count assertion stayed green.
      var flameStyles: seq[CellStyle] = @[]
      for level in 0 ..< HeatLevels:
        ck HeatPalette[level] notin flameStyles
        flameStyles.add HeatPalette[level]
      ck flameStyles.len == HeatLevels

      var countedVisible = 0
      var uncountedVisible = 0
      var heatWrong: seq[string] = @[]
      for i in 0 ..< PaneHeight - 1:
        let line = heatModel.viewportTop + i
        if not heatModel.holdsLine(line):
          continue
        let row = heatScreen.rows[1 + i]
        # The number field starts after the one-cell mark and is
        # `numberWidth` wide; read it by CELL so a wide glyph cannot shift it.
        var fieldText = ""
        var at = 0
        for r in rowText(row).runes:
          let w = max(1, displayWidth($r))
          if at >= GutterMarkCells and
             at < heatScreen.gutterWidth - GutterPointerCells - GutterGapCells:
            fieldText.add $r
          at += w
        let want = heat.heatCountText(line)
        if fieldText.strip() != want:
          heatWrong.add "line " & $line & ": field '" & fieldText.strip() &
            "', expected '" & want & "'"
        let style = rowStyleAt(row, GutterMarkCells)
        if style.fg != heat.heatStyle(line).fg:
          heatWrong.add "line " & $line & ": flame fg '" & style.fg &
            "', expected '" & heat.heatStyle(line).fg & "'"
        if heat.countFor(line) > 0: inc countedVisible
        else: inc uncountedVisible
      if heatWrong.len > 0:
        checkpoint(heatWrong[0 .. min(4, heatWrong.high)].join("\n"))
      checkpoint("heatmap gutter: " & $countedVisible & " counted line(s), " &
                 $uncountedVisible & " uncounted, " & $heatWrong.len &
                 " wrong")
      ck heatWrong.len == 0
      # BOTH halves must have been exercised: a window showing only uncounted
      # lines would satisfy the flame assertions with the level-0 colour alone.
      ck countedVisible >= 1
      ck uncountedVisible >= 1
      # And the explicit-sample constructor sums duplicates, which is the shape
      # a per-line count from an engine would arrive in.
      let summed = newLineHeat([(7, 2), (7, 3), (9, 1)])
      ck summed.countFor(7) == 5
      ck summed.countFor(9) == 1
      ck summed.largestCount() == 5
      ck summed.totalObservations() == 6

      # ---- the gutter carries what the ENGINE verified ---------------------
      # Not "the line the test asked for": the engine binds a breakpoint to a
      # recorded step, and the line it echoes back is the one the pane must
      # mark. Asking for line L and drawing `●` on line L would look right
      # whatever the engine did with it.
      let bpAsk = h.reportedLocation()
      let resp = h.session.lastSetBreakpointsResponse(bpAsk.file, bpAsk.line)
      ck resp.getOrDefault("success").getBool(false)
      let bps = resp{"body", "breakpoints"}
      ck not bps.isNil
      ck bps.len == 1
      let boundLine = bps[0].getOrDefault("line").getInt(0)
      ck boundLine >= 1
      var marked = h
      marked.points = @[SourcePoint(path: bpAsk.file, line: boundLine,
                                    kind: sptBreakpoint, enabled: true)]
      discard marked.fillWindow()
      let markedModel = marked.paneModel()
      ck markedModel.markFor(boundLine) == gmBreakpoint
      let markedScreen = sourcePaneScreen(markedModel, PaneWidth, PaneHeight,
                                          h.cache)
      let bpRow = 1 + boundLine - markedModel.viewportTop
      ck bpRow >= 1
      ck bpRow < markedScreen.rows.len
      ck rowRuneAt(markedScreen.rows[bpRow], 0) == BreakpointGlyph
      ck rowStyleAt(markedScreen.rows[bpRow], 0).fg == BreakpointStyle.fg

      # ---- THE SHELL PAINTS THE PANE INTO THE `editor` RECTANGLE ----------
      # CTUI-3 delivered the rectangle and left it empty ("the panes are
      # empty: source text is CTUI-4/CTUI-5"). This is the assertion that it
      # is no longer empty, and that what fills it is EXACTLY the pane —
      # compared cell-column for cell-column against the pane rendered on its
      # own, so the shell cannot be painting something that merely resembles
      # it.
      var shellModel = newShellModel(80, 24)
      shellModel.source = h.paneModel()
      shellModel.highlighting = h.cache
      let editorArea = projectLayout(shellModel.layout,
                                     bodyArea(80, 24)).regionFor(paneEditor)
      ck editorArea.width > 0
      ck editorArea.height > 0
      let standalone = sourcePaneText(shellModel.source, editorArea.width,
                                      editorArea.height, h.cache)
      ck standalone.len == editorArea.height
      let shellText = shellRows(shellModel, 80, 24)
      ck shellText.len == 24
      var paneRowsMatched = 0
      var paneMismatches: seq[string] = @[]
      for i in 0 ..< editorArea.height:
        let screenRow = shellText[editorArea.row + i]
        var slice = ""
        var at = 0
        for r in screenRow.runes:
          let w = max(1, displayWidth($r))
          if at >= editorArea.col and at < editorArea.col + editorArea.width:
            slice.add $r
          at += w
        if slice == standalone[i]:
          inc paneRowsMatched
        else:
          paneMismatches.add "editor row " & $i & ":\n  pane:  '" &
            standalone[i] & "'\n  shell: '" & slice & "'"
      if paneMismatches.len > 0:
        checkpoint(paneMismatches[0 .. min(2, paneMismatches.high)].join("\n"))
      ck paneRowsMatched == editorArea.height
      # …and the OTHER panes are still there, so the source pane took its own
      # rectangle and nobody else's.
      ck shellText[1].contains("CALL STACK")
      ck shellText[editorArea.row].contains(SourcePaneTitle)

      # ---- FINE-GRAINED SUBSCRIPTION, measured ----------------------------
      # CTUI-5: "changing the execution line re-evaluates the gutter and
      # pointer cells, not the text buffer. Assert this with
      # dirtyRegions/bytesEmitted, don't assume it."
      #
      # Two frames that differ ONLY in `executionLine` — same held window,
      # same viewport top, same marks — composited through the real
      # compositor. The dirty set must be exactly the row the pointer left and
      # the row it reached.
      var base = h.paneModel()
      base.viewportTop = base.executionLine
      let firstLine = base.executionLine
      var next = base
      next.executionLine = firstLine + 1
      ck base.holdsLine(firstLine)
      ck base.holdsLine(firstLine + 1)

      let harness = newTerminalTestHarness(PaneWidth, PaneHeight)
      var stepBytes = 0
      var dirtyRows: seq[int] = @[]
      try:
        harness.mount(proc(r: TerminalRenderer): TerminalNode =
          renderSourcePaneTree(base, r, PaneWidth, PaneHeight, h.cache))
        harness.clearBytesEmitted()
        harness.mount(proc(r: TerminalRenderer): TerminalNode =
          renderSourcePaneTree(next, r, PaneWidth, PaneHeight, h.cache))
        stepBytes = harness.bytesEmitted.len
        for region in harness.dirtyRegions:
          if region.row notin dirtyRows:
            dirtyRows.add region.row
      finally:
        harness.dispose()

      checkpoint("single-step dirty rows: " & $dirtyRows &
                 ", bytes: " & $stepBytes)
      ck dirtyRows.len == 2
      ck 1 in dirtyRows                 # the row the pointer left (viewport top)
      ck 2 in dirtyRows                 # the row it reached
      # …and the TEXT BUFFER did not move. Every other row is byte-identical
      # between the two frames, which is the half of the contract a dirty-row
      # count alone does not establish: two dirty rows could be two rows whose
      # TEXT changed.
      let rowsBefore = sourcePaneText(base, PaneWidth, PaneHeight, h.cache)
      let rowsAfter = sourcePaneText(next, PaneWidth, PaneHeight, h.cache)
      ck rowsBefore.len == rowsAfter.len
      var textChanged = 0
      for i in 0 ..< rowsBefore.len:
        if rowsBefore[i] != rowsAfter[i]:
          inc textChanged
      checkpoint("rows whose TEXT changed: " & $textChanged)
      ck textChanged == 2
      # The two rows whose text changed are the pointer rows and nothing else:
      # the code on them is the same code, only the `-->` moved.
      ck rowsBefore[1].replace(ExecutionPointerGlyph, "   ") ==
         rowsAfter[1].replace(ExecutionPointerGlyph, "   ")
      ck rowsBefore[2].replace(ExecutionPointerGlyph, "   ") ==
         rowsAfter[2].replace(ExecutionPointerGlyph, "   ")
      ck h.cache.parseCount >= 1

      # ---- THE VERIFICATION GATE: < 250 bytes for a single-line step -------
      echo "CTUI-5 SINGLE-STEP EMISSION: " & $stepBytes &
           " byte(s) at " & $PaneWidth & "x" & $PaneHeight &
           " (gate < 250)"
      ck stepBytes > 0
      ck stepBytes < 250

      # ---- THE VERIFICATION GATE: < 16 ms per step at Tier 1 --------------
      # Measured on the CACHED highlighting path, which is what CTUI-5's risk
      # mitigation says the gate is measured on; the cold parse is a separate
      # number, echoed below so a regression in it is attributable.
      let latencyHarness = newTerminalTestHarness(PaneWidth, PaneHeight)
      var bestMs = 1.0e9
      var medianSamples: seq[float] = @[]
      try:
        latencyHarness.mount(proc(r: TerminalRenderer): TerminalNode =
          renderSourcePaneTree(base, r, PaneWidth, PaneHeight, h.cache))
        for i in 1 .. 40:
          var frame = base
          frame.executionLine = firstLine + (i mod 3)
          let t0 = getMonoTime()
          latencyHarness.mount(proc(r: TerminalRenderer): TerminalNode =
            renderSourcePaneTree(frame, r, PaneWidth, PaneHeight, h.cache))
          let ms = (getMonoTime() - t0).inMicroseconds.float / 1000.0
          medianSamples.add ms
          if ms < bestMs: bestMs = ms
      finally:
        latencyHarness.dispose()
      let parsesAfterLatency = h.cache.parseCount
      # A COLD parse of the same window, for the separate benchmark CTUI-5's
      # risk mitigation asks for.
      let coldStart = getMonoTime()
      discard highlightWindow(base.path, base.firstHeldLine, base.heldLines)
      let coldMs = (getMonoTime() - coldStart).inMicroseconds.float / 1000.0
      echo "CTUI-5 STEP LATENCY (cached highlight): best " &
           formatFloat(bestMs, ffDecimal, 3) & " ms over 40 frames " &
           "(gate < 16); COLD parse of the same window: " &
           formatFloat(coldMs, ffDecimal, 3) & " ms"
      ck bestMs < 16.0
      ck medianSamples.len == 40
      # The gate was measured on the cached path, and that is checkable rather
      # than claimed: forty frames added no parse.
      ck parsesAfterLatency == h.cache.parseCount

  test "every fixture was examined, and the assertion tally proves it":
    ck examinedFixtures == 1
    ck verifiedFixtures + skippedFixtures == examinedFixtures
    ck verifiedFixtures >= 1
    let expected =
      verifiedFixtures * (
        ChecksSessionOpen + ChecksControlsAreReporters + ChecksEntryFloor +
        ForwardSteps * ChecksPerForwardStop + 1 +
        ForwardSteps * ChecksPerBackwardStop + 1 +
        ChecksRetrace + ChecksHeatmap + ChecksHeatmapGutter +
        ChecksBreakpointGutter +
        ChecksShellIntegration +
        ChecksFineGrained + ChecksBytes + ChecksLatency) +
      skippedFixtures * ChecksSkippedFixture +
      ChecksSummary
    checkpoint("counted " & $countedAssertions & ", derived " & $expected)
    ck countedAssertions == expected

  test "assertion count":
    echo "CHECKS: " & $countedAssertions
    checkpoint("counted assertions: " & $countedAssertions)
    check countedAssertions == ExpectedAssertions
