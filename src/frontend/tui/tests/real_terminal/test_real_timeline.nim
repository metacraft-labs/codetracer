## test_real_timeline.nim — CTUI-8, Tier 2.
##
## ## What only this file can say
##
## CTUI-8: "TermAssert: `sendMouseClick` on the scrubber track seeks to the
## clicked ratio, which is the mouse contract from §4.4 and is untestable in
## process."
##
## That, plus the five glyphs of §3.3.5 read back out of a real terminal's own
## cell model in their own colours. Both are unobservable anywhere else
## (`docs/tui-testing.md`'s table): a real SGR-1006 byte sequence arriving on a
## real fd, and the colours a terminal shows after its own state machine has
## parsed them.
##
## ## EVERY COLOUR HERE IS ASSERTED ABSOLUTELY, AND THAT IS A RULE
##
## `docs/tui-testing.md`, "What cross-tier equality cannot catch, and never
## will": a differential check compares two renderings of the SAME program, so it
## is blind by construction to any defect both tiers share. CTUI-5 measured that
## — a mutation that rendered provenance away kept `runDualSnap` at zero
## divergences and was caught only by `fg.idx == 3'u8`.
##
## §3.3.5 is a bar with five meanings on it, so every one is asserted as a
## NUMBER: `bright_cyan` is 14 for the needle `▲`, `yellow` is 3 for a
## tracepoint diamond `◆`, `blue` is 4 for a recorded call span `█`,
## `bright_black` is 8 for the empty track `─`, and `white` is 7 for the bounds
## `[` and `]`. The cross-tier case is the last in this file and asserts
## something else entirely: that the renderer is faithful.
##
## ## THE CLICK IS THE POINT
##
## The needle's destination is computed by `timeline_bar.tickForColumn` — the
## same pure function `app/tests/test_timeline_scrubber_quantization.nim` sweeps
## — and the terminal is asked where the needle ENDED UP. So the case is a
## statement about the whole path: TermAssert's bytes, the pty, the runtime's
## input framing, `input/timeline_keys.decodeMouse`, the seek, and the repaint.
## Nothing about it can be checked in process.
##
## ## EVERY DRIVEN FRAME IS WAITED FOR BY NAME
##
## `waitForCompleteFrame` cannot be the barrier after an input: the cursor is
## already parked on the bottom-right cell from the PREVIOUS frame, so it
## returns immediately and the assertions would read the screen from before the
## click. The child labels an input-driven repaint `<label>-stepN` and every
## case here waits for the label of the frame it is about to read. No sleeps, no
## `waitForText`.
##
## ## It does not skip
##
## A missing grammar archive, a child that will not compile, a child that never
## finishes a frame, a label that never arrives: every one FAILS by name.
##
## ## No mocks
##
## The subject is a compiled binary in a real pty, parsed by a real terminal
## state machine. Its data is a constant — see `apps/app_timeline.nim`'s header
## on why a snapshot app cannot open a `.ct` container, and where the fixture
## evidence lives instead.
##
## ## Templates, not procs, for anything that calls `check`

import std/[options, strutils, times, unicode, unittest]

import isonim_tui
import term_assert

import ../../app/views/event_log
import ../../app/views/timeline_bar
import ../../app/views/tracepoint_manager
import ../../testing/dual_snap
import ../../testing/test_app_runtime
import ../apps/app_timeline as timelineApp

# One line, deliberately: `ci/lib/run-nim-test-lane.sh` reads exactly this
# spelling as a RUNTIME assertion count, and inside a `const` block the
# declaration is invisible to it.
const ExpectedAssertions = 93

const
  Cols = 90
  Rows = 30
    ## Wide enough for an 88-cell track — so a click has somewhere to land that
    ## is neither end — and tall enough for the scrubber, the event log and the
    ## tracepoint dialog at once.
  Label = "timeline"
  Stem = "app_timeline"
  FrameTimeoutMs = 20000
  LabelTimeoutMs = 10000

  Blue = 4'u8
  Yellow = 3'u8
  White = 7'u8
  BrightBlack = 8'u8
  BrightCyan = 14'u8

  ClickColumn = 60
    ## A TRACK cell, chosen to be inside no other field and to be far from both
    ## ends: the needle starts at track cell 21 and the diamonds are at 5 and 60
    ## on this geometry, so a click here lands on a cell that already carries a
    ## `◆` — which is the case where the needle's precedence over a mark is
    ## observable on a real screen.

var countedAssertions = 0

template ck(condition: untyped) =
  inc countedAssertions
  check condition

proc describeCell(c: term_assert.Cell): string =
  var attrs: seq[string] = @[]
  for a in c.attrs:
    attrs.add $a
  "rune='" & (if c.rune.int32 == 0: " " else: $c.rune) & "' fg=" &
    (case c.fg.kind
     of ckDefault: "default"
     of ckIndexed: "indexed:" & $c.fg.idx
     of ckRgb: "rgb") &
    " bg=" &
    (case c.bg.kind
     of ckDefault: "default"
     of ckIndexed: "indexed:" & $c.bg.idx
     of ckRgb: "rgb") &
    " attrs={" & attrs.join(",") & "}"

proc paneRow(sess: var TuiTestSession; row: int): string =
  sess.regionText(row, 0, Cols, 1).split('\n')[0]

proc settledFrame(sess: var TuiTestSession; step: int): ScreenSnapshot =
  ## Wait for the frame the child declares final at `step`, by name.
  waitForCompleteFrame(sess, Cols, Rows, FrameTimeoutMs)
  sess.send($TestAppCaptureByte)
  waitForSnapshotLabel(sess, stepLabel(Label, step), LabelTimeoutMs)

proc spawnChild(): TuiTestSession =
  compileChildApp(Stem)
  newTuiTest(appBinaryPath(Stem),
             @["--cols=" & $Cols, "--rows=" & $Rows,
               "--test-ipc", "--label=" & Label])
    .width(Cols).height(Rows)
    .spawn()

# ---------------------------------------------------------------------------
# Assertion templates. Every helper that calls `check` is a TEMPLATE.
# ---------------------------------------------------------------------------

template checkGlyphCell(sess: var TuiTestSession; screen: TimelineBarScreen;
                        trackColumn: int; wantRune: string; wantFg: uint8;
                        wantBold: bool; what: string) =
  ## One track cell, read out of a real terminal: the rune §3.3.5 names and the
  ## colour that says what it MEANS.
  let cell = sess.cellAt(screen.barRow, screen.trackCol + trackColumn)
  checkpoint(what & " at track cell " & $trackColumn & ": " & describeCell(cell))
  ck $cell.rune == wantRune
  ck cell.fg.kind == ckIndexed
  ck cell.fg.idx == wantFg
  if wantBold:
    ck caBold in cell.attrs
  else:
    ck caBold notin cell.attrs

# ---------------------------------------------------------------------------

suite "CTUI-8 Tier 2: the scrubber on a real terminal":

  test "the five glyphs of §3.3.5 are five colours a terminal parsed":
    var sess = spawnChild()
    try:
      let screen = timelineApp.screenFor(timelineApp.InitialTick, Cols, Rows)

      # Nothing recorded yet: the child has painted and is waiting to be asked.
      # The positive control that every label below is an ANSWER rather than a
      # race the parent won.
      waitForCompleteFrame(sess, Cols, Rows, FrameTimeoutMs)
      ck sess.snapshots().len == 0
      sess.send($TestAppCaptureByte)
      let frame0 = waitForSnapshotLabel(sess, stepLabel(Label, 0),
                                        LabelTimeoutMs)
      ck frame0.label == Label
      ck frame0.rows == Rows
      ck frame0.cols == Cols

      # The bar on the terminal is the bar the model says.
      let barText = paneRow(sess, screen.barRow)
      let modelBar = rowText(screen.rows[1])
      checkpoint("terminal bar: '" & barText & "'\n     model bar: '" &
                 modelBar & "'")
      ck barText == modelBar
      ck paneRow(sess, 0).contains(TimelineTitle)
      ck screen.trackWidth == trackWidthFor(Cols)
      ck screen.trackWidth == 88

      # ---- THE BOUNDS ------------------------------------------------------
      let openCell = sess.cellAt(screen.barRow, screen.boundsColumns[0])
      let closeCell = sess.cellAt(screen.barRow, screen.boundsColumns[1])
      checkpoint("bounds: " & describeCell(openCell) & " … " &
                 describeCell(closeCell))
      ck $openCell.rune == BoundsOpenGlyph
      ck $closeCell.rune == BoundsCloseGlyph
      ck openCell.fg.kind == ckIndexed
      ck openCell.fg.idx == White
      ck caBold in openCell.attrs
      ck closeCell.fg.idx == White
      ck caBold in closeCell.attrs

      # ---- THE NEEDLE ------------------------------------------------------
      ck screen.needleColumn ==
        columnForTick(timelineApp.InitialTick, 0'u64, timelineApp.MaxTick,
                      screen.trackWidth)
      checkGlyphCell(sess, screen, screen.needleColumn, NeedleGlyph,
                     BrightCyan, true, "needle")

      # ---- A CALL SPAN -----------------------------------------------------
      # `█` at a cell the model says a recorded call covers, and NOT at a cell
      # it does not — the negative twin through the same reader.
      ck screen.spanColumns.len > 0
      ck screen.paintedSpans > 0
      checkGlyphCell(sess, screen, screen.spanColumns[0], SpanGlyph, Blue,
                     false, "call span")

      # ---- A TRACEPOINT DIAMOND -------------------------------------------
      ck screen.markColumns.len == 2
      ck screen.paintedMarks == 2
      checkGlyphCell(sess, screen, screen.markColumns[0], MarkGlyph, Yellow,
                     true, "tracepoint mark")

      # ---- EMPTY TRACK -----------------------------------------------------
      # A cell that is none of the above: it must be the plain rule in the muted
      # colour, which is what makes the four above DISTINCTIONS rather than
      # decorations.
      var plainColumn = -1
      for c in 0 ..< screen.trackWidth:
        if c != screen.needleColumn and c notin screen.markColumns and
           c notin screen.spanColumns:
          plainColumn = c
          break
      ck plainColumn >= 0
      checkGlyphCell(sess, screen, plainColumn, TrackGlyph, BrightBlack, false,
                     "empty track")

      # ---- THE POINT, as one assertion: five glyphs, five colours ----------
      var distinctColours: seq[uint8] = @[]
      for c in [screen.needleColumn, screen.markColumns[0],
                screen.spanColumns[0], plainColumn]:
        let idx = sess.cellAt(screen.barRow, screen.trackCol + c).fg.idx
        if idx notin distinctColours:
          distinctColours.add idx
      let boundsColour = sess.cellAt(screen.barRow,
                                     screen.boundsColumns[0]).fg.idx
      if boundsColour notin distinctColours:
        distinctColours.add boundsColour
      checkpoint("distinct scrubber colours: " & $distinctColours)
      ck distinctColours.len == 5

      sess.send($TestAppQuitByte)
      let status = sess.waitExit(initDuration(seconds = 10))
      ck status.isSome
      ck status.get() == TestAppExitOk
    finally:
      sess.terminate()
      sess.close()

  test "a real mouse click on the track seeks to the clicked ratio":
    var sess = spawnChild()
    try:
      let before = timelineApp.screenFor(timelineApp.InitialTick, Cols, Rows)
      discard settledFrame(sess, 0)
      ck before.needleColumn != ClickColumn
      # The cell about to be clicked carries a DIAMOND before the click, so the
      # move is a change of glyph as well as a change of column.
      ck ClickColumn in before.markColumns
      checkGlyphCell(sess, before, ClickColumn, MarkGlyph, Yellow, true,
                     "the cell about to be clicked")

      # THE CLICK. Real SGR-1006 bytes on a real fd, which is the whole reason
      # this case cannot be a Tier-1 one.
      sess.sendMouseClick(before.barRow, before.trackCol + ClickColumn)
      discard settledFrame(sess, 1)

      # THE RATIO, computed by the pure mapping and not read back off the pane.
      let expectedTick = tickForColumn(ClickColumn, 0'u64, timelineApp.MaxTick,
                                       before.trackWidth)
      let after = timelineApp.screenFor(expectedTick, Cols, Rows)
      checkpoint("clicked track cell " & $ClickColumn & " of " &
                 $before.trackWidth & " -> tick " & $expectedTick & " of " &
                 $timelineApp.MaxTick)
      ck expectedTick != timelineApp.InitialTick
      ck after.needleColumn == ClickColumn

      # THE NEEDLE IS THERE, ON THE TERMINAL, in the needle's own colour —
      # and it has taken the diamond's cell, which is the precedence rule
      # `paintTimelineBar` states.
      checkGlyphCell(sess, after, ClickColumn, NeedleGlyph, BrightCyan, true,
                     "needle after the click")
      # …AND IT HAS LEFT WHERE IT WAS. A pane that painted a second needle
      # would satisfy the assertion above.
      let vacated = sess.cellAt(after.barRow,
                                after.trackCol + before.needleColumn)
      checkpoint("vacated cell " & describeCell(vacated))
      ck $vacated.rune != NeedleGlyph
      ck after.paintedMarks == before.paintedMarks - 1

      # THE WHOLE BAR AGREES WITH THE MODEL FOR THE CLICKED TICK, so the title's
      # tick counter moved with the needle rather than only the glyph.
      let barText = paneRow(sess, after.barRow)
      checkpoint("bar after click: '" & barText & "'")
      ck barText == rowText(after.rows[1])
      let titleText = paneRow(sess, 0)
      checkpoint("title after click: '" & titleText & "'")
      ck titleText.contains("tick " & $expectedTick & " / " &
                            $timelineApp.MaxTick)
      ck not titleText.contains("tick " & $timelineApp.InitialTick & " /")

      # A CLICK OUTSIDE THE TRACK DOES NOTHING. §4.4 is about the scrubber, and
      # a decoder that treated any click as a seek would move the needle from
      # the event log below. The frame is not even repainted, so the label the
      # child would emit for a step-2 frame never arrives — asserted by reading
      # the SAME frame again and finding it unchanged.
      sess.sendMouseClick(after.barRow + 4, 3)
      waitForCompleteFrame(sess, Cols, Rows, FrameTimeoutMs)
      ck paneRow(sess, after.barRow) == barText
      ck paneRow(sess, 0) == titleText

      sess.send($TestAppQuitByte)
      let status = sess.waitExit(initDuration(seconds = 10))
      ck status.isSome
      ck status.get() == TestAppExitOk
    finally:
      sess.terminate()
      sess.close()

  test "the event log and the tracepoint dialog are on the same real screen":
    var sess = spawnChild()
    try:
      discard settledFrame(sess, 0)
      let logScreen = timelineApp.logScreenFor(Cols, Rows)
      let dialog = timelineApp.dialogScreenFor(Cols, Rows)

      # THE EVENT LOG. Its rows are the recording's, and the selected one
      # carries the cursor's background — read as a NUMBER off the terminal.
      ck logScreen.eventRows == timelineApp.sampleEvents().len
      ck logScreen.selectedRow > 0
      let selectedText = paneRow(sess, logScreen.selectedRow)
      checkpoint("selected event row: '" & selectedText & "'")
      ck selectedText.contains($timelineApp.sampleEvents()[2].tick)
      let selectedCell = sess.cellAt(logScreen.selectedRow,
                                     logScreen.tickColumn)
      checkpoint("selected row's first cell " & describeCell(selectedCell))
      ck selectedCell.bg.kind == ckIndexed
      ck selectedCell.bg.idx == BrightBlack
      # THE NEGATIVE TWIN: an unselected row has no background at all.
      let plainCell = sess.cellAt(logScreen.selectedRow - 1,
                                  logScreen.tickColumn)
      checkpoint("unselected row's first cell " & describeCell(plainCell))
      ck plainCell.bg.kind == ckDefault
      # …and the category field is the OUTPUT colour, at the column the pane
      # reports rather than one this file counted.
      let categoryCell = sess.cellAt(
        logScreen.selectedRow, logScreen.tickColumn + TickFieldCells + GapCells)
      checkpoint("category cell " & describeCell(categoryCell))
      ck $categoryCell.rune == "o"
      ck categoryCell.fg.kind == ckIndexed
      ck categoryCell.fg.idx == 2'u8

      # THE TRACEPOINT DIALOG. Its `◆` is the SAME yellow the scrubber's is —
      # one fact, one colour, on two panes.
      ck dialog.entryRows == 1
      ck dialog.hitRows == 2
      ck dialog.selectedRow > 0
      let dialogMark = sess.cellAt(dialog.selectedRow, dialog.markColumn)
      checkpoint("dialog diamond " & describeCell(dialogMark))
      ck $dialogMark.rune == MarkGlyph
      ck dialogMark.fg.kind == ckIndexed
      ck dialogMark.fg.idx == Yellow
      ck caBold in dialogMark.attrs
      # …and a HIT ROW names the tick the sweep reported and the value it read.
      let hitText = paneRow(sess, dialog.selectedRow + 1)
      checkpoint("first hit row: '" & hitText & "'")
      ck hitText.contains("@" & $timelineApp.sampleHits()[0].tick)
      ck hitText.contains(timelineApp.sampleHits()[0].values[0][1])
      # The hit's tick is a diamond ON THE BAR, which is what ties the dialog to
      # the scrubber rather than leaving them two unrelated lists.
      let bar = timelineApp.screenFor(timelineApp.InitialTick, Cols, Rows)
      ck columnForTick(timelineApp.sampleHits()[0].tick, 0'u64,
                       timelineApp.MaxTick, bar.trackWidth) in bar.markColumns

      sess.send($TestAppQuitByte)
      let status = sess.waitExit(initDuration(seconds = 10))
      ck status.isSome
      ck status.get() == TestAppExitOk
    finally:
      sess.terminate()
      sess.close()

  test "cross-tier snapshot equality grounds the pane's Tier-1 goldens":
    # docs/tui-testing.md: "a new pane needs exactly one cross-tier equivalence
    # test. Not zero, and not one per assertion." This is the timeline pane's,
    # at CTUI-2's two geometries, through the SAME `buildTree` both tiers run.
    var checkedCases = 0
    for g in [(cols: 80, rows: 24), (cols: Cols, rows: Rows)]:
      let res = runDualSnap(Stem, timelineApp.buildTree, g.cols, g.rows)
      inc checkedCases
      if res.divergences.len > 0:
        checkpoint(report(res))
      ck res.divergences.len == 0
      # THE NON-VACUITY FLOOR, as the EXACT painted-cell count rather than "more
      # than none": a screen the two tiers agree is blank would satisfy the
      # equality above for free. The number is knowable because the tree is a
      # pure function of the geometry.
      let canon = canonFromDir(res.tier1Dir)
      let painted = countCellsWhere(canon, proc(c: CanonCell): bool =
        c.rune != " " and c.rune.len > 0)
      var modelPainted = 0
      for line in timelineApp.paneTextFor(timelineApp.InitialTick, g.cols,
                                          g.rows):
        for r in line.runes:
          if $r != " ":
            inc modelPainted
      checkpoint("app_timeline at " & $g.cols & "x" & $g.rows & ": " &
                 $painted & " painted cell(s) of " &
                 $(canon.rows * canon.cols) & ", model says " & $modelPainted)
      ck painted == modelPainted
      ck painted > 0
      # And the two tiers really are two tiers — `compareSnapshotDirs` refuses a
      # directory compared with itself, which is the vacuous pass this whole
      # construction exists to prevent.
      ck canon.dialect == "tier1-isonim-tui"
      ck canonFromDir(res.tier2Dir).dialect == "tier2-libvterm"
    ck checkedCases == 2

  test "assertion count":
    echo "CHECKS: " & $countedAssertions
    checkpoint("counted assertions: " & $countedAssertions)
    check countedAssertions == ExpectedAssertions
