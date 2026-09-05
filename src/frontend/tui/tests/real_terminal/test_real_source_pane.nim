## test_real_source_pane.nim — CTUI-5, Tier 2.
##
## ## What only this file can say
##
## `codetracer-specs/Front-Ends/CodeTracer-TUI.milestones.org`, CTUI-5:
## "TermAssert: step with `sendKey(\"f10\")` and read the pointer row with
## `regionText`; assert the pointer cell's *real* SGR attributes via `cellAt`;
## assert breakpoint red and pointer accent are the colours a terminal shows.
## Cross-tier `snap` equality per CTUI-2. Uses the IPC settled-frame label
## rather than `waitForText`, so a slow step cannot pass on a half-painted
## frame."
##
## All five. And the distinction that makes the file worth its compile: every
## Tier-1 assertion CTUI-5 makes about a colour is an assertion about a
## `CellStyle` — a string like `"red"` in a style struct, which the compositor
## turns into `CSI 31 m`, which nothing in process ever parses back. Only here
## is the colour read out of a real terminal's own cell model, after a real
## terminal state machine consumed the bytes the pane emitted.
##
## ## THE STEP IS A REAL KEY, AND THE FRAME IS THE ONE THE CHILD DECLARED
##
## `sendKey("f10")` writes `\x1b[21~` into the pty
## (`TermAssert/src/term_assert.nim:432`). The child accumulates the sequence,
## increments its step counter and repaints — see
## `testing/test_app_runtime.nim`'s `TestAppStepKey`.
##
## `waitForText` is banned in this tree (docs/tui-testing.md, and
## `codetracer-specs/Testing/Verification-Harness-Traps.md` §3): it passes on a
## partially painted frame that happens to contain the needle. So the frames
## compared here are the ones the CHILD asked the harness to record, through
## `--test-ipc` and the capture handshake — the parent proves it has consumed
## the whole frame with the cursor barrier, THEN asks, and the child answers
## with a label. A slow step therefore cannot be mistaken for a fast one: the
## label for step 1 does not exist until the child has painted step 1.
##
## ## It does not skip
##
## A missing grammar archive, a child that will not compile, a child that never
## finishes a frame, a label that never arrives: every one FAILS by name. There
## is no `when false`, no early return on a missing prerequisite, and no
## `try/except` that turns a failure into a pass.
##
## ## No mocks
##
## The subject is a compiled binary in a real pty, parsed by a real terminal
## state machine. There is no ViewModel here at all — the model is the constant
## `apps/app_source_pane.nim` paints, which is what makes the cross-tier
## comparison a statement about the RENDERER.
##
## ## Templates, not procs, for anything that calls `check`

import std/[strutils, times, unicode, unittest]

import isonim_tui
import term_assert

import ../../app/views/source_pane
import ../../testing/dual_snap
import ../../testing/test_app_runtime
import ../apps/app_source_pane as paneApp

# One line, deliberately: `ci/lib/run-nim-test-lane.sh` reads exactly this
# spelling as a RUNTIME assertion count, and inside a `const` block the
# declaration is invisible to it.
const ExpectedAssertions = 71

const
  Cols = 90
  Rows = 46
    ## The Ultra-wide profile's `editor` rectangle at 200x60, from CTUI-3's
    ## measured table. Tall enough for both provenance panes to show their
    ## whole sample.
  Label = "source-pane"
  Stem = "app_source_pane"
  FrameTimeoutMs = 20000

var countedAssertions = 0

template ck(condition: untyped) =
  inc countedAssertions
  check condition

proc paneRowOf(model: SourcePaneModel; paneTop: int): int =
  ## Which SCREEN row the execution pointer sits on for `model`, given where
  ## its pane starts. Derived from the model rather than written down, so a
  ## change to `PointerLines` moves the assertion with it.
  paneTop + 1 + model.executionLine - model.viewportTop

proc pointerColumn(width: int; model: SourcePaneModel): int =
  ## The first cell of the gutter's pointer field, from the pane's own layout.
  let screen = sourcePaneScreen(model, width, 4)
  max(0, screen.gutterWidth - GutterPointerCells - GutterGapCells)

proc markColumn(): int =
  ## The gutter's mark cell is always column 0 of the pane, and the pane starts
  ## at column 0 of this screen.
  0

proc lineNumberColumn(): int =
  ## The first cell of the number field: right after the one-cell mark.
  GutterMarkCells

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

suite "CTUI-5 Tier 2: the source pane on a real terminal":

  test "F10 steps the pointer and the terminal shows the accent colour":
    compileChildApp(Stem)
    var sess = newTuiTest(appBinaryPath(Stem),
                          @["--cols=" & $Cols, "--rows=" & $Rows,
                            "--test-ipc", "--label=" & Label])
      .width(Cols).height(Rows)
      .spawn()
    try:
      let heights = paneApp.paneHeights(Rows)
      ck heights.top + heights.bottom == Rows
      ck heights.top > 2
      ck heights.bottom > 2

      # ---- step 0 -----------------------------------------------------------
      waitForCompleteFrame(sess, Cols, Rows, FrameTimeoutMs)
      # Nothing recorded yet: the child has painted and is waiting to be asked.
      # This is the positive control that the labels below are ANSWERS rather
      # than a race the parent won.
      ck sess.snapshots().len == 0
      sess.send($TestAppCaptureByte)
      let frame0 = waitForSnapshotLabel(sess, stepLabel(Label, 0))
      ck frame0.label == Label
      ck frame0.rows == Rows
      ck frame0.cols == Cols

      let model0 = paneApp.sourceModel(0, gpVerified)
      let row0 = paneRowOf(model0, 0)
      ck row0 > 0
      ck row0 < heights.top

      # `regionText` — the API the milestone names — reads the pointer row from
      # libvterm's own grid.
      let pointerRow0 = sess.regionText(row0, 0, Cols, 1).split('\n')[0]
      checkpoint("pointer row at step 0: '" & pointerRow0.strip() & "'")
      ck pointerRow0.contains(ExecutionPointerGlyph)
      ck pointerRow0.contains($model0.executionLine)
      # The MODEL's own text for that row, cell for cell. Not a needle: the
      # whole row, so a pointer drawn on the right row over the wrong line
      # fails here.
      let expected0 = sourcePaneText(model0, Cols, heights.top)
      ck pointerRow0.strip(leading = false) ==
         expected0[row0].strip(leading = false)

      # ---- THE POINTER CELL'S REAL SGR --------------------------------------
      let ptrCol = pointerColumn(Cols, model0)
      ck ptrCol > 0
      let ptrCell = sess.cellAt(row0, ptrCol)
      checkpoint("pointer cell (" & $row0 & "," & $ptrCol & "): " &
                 describeCell(ptrCell))
      ck $ptrCell.rune == "-"
      # `bright_yellow` is ANSI 11, which libvterm reports as indexed 11.
      ck ptrCell.fg.kind == ckIndexed
      ck ptrCell.fg.idx == 11'u8
      ck caBold in ptrCell.attrs
      # …and the execution line's background highlight really reached it.
      # `blue` is ANSI 4.
      ck ptrCell.bg.kind == ckIndexed
      ck ptrCell.bg.idx == 4'u8

      # ---- BREAKPOINT RED, TRACEPOINT CYAN, DISABLED MUTED ------------------
      # All three §3.3.2 indicators, on the same real screen.
      var markChecks = 0
      for (line, mark) in paneApp.SampleMarks:
        let row = 1 + line - model0.viewportTop
        let cell = sess.cellAt(row, markColumn())
        checkpoint("mark cell for line " & $line & " (" & $mark & "): " &
                   describeCell(cell))
        inc markChecks
        case mark
        of gmBreakpoint:
          ck $cell.rune == BreakpointGlyph
          ck cell.fg.kind == ckIndexed
          ck cell.fg.idx == 1'u8          # `red`
          ck caBold in cell.attrs
        of gmBreakpointDisabled:
          ck $cell.rune == BreakpointDisabledGlyph
          ck cell.fg.kind == ckIndexed
          ck cell.fg.idx == 8'u8          # `bright_black`, §3.3.2's "muted"
          ck caBold notin cell.attrs
        of gmTracepoint:
          ck $cell.rune == TracepointGlyph
          ck cell.fg.kind == ckIndexed
          ck cell.fg.idx == 6'u8          # `cyan`
          ck caBold in cell.attrs
        of gmNone:
          ck false                        # unreachable; the table has no gmNone
      ck markChecks == paneApp.SampleMarks.len
      ck markChecks == 3

      # ---- PROVENANCE, ON A REAL SCREEN, IN BOTH TREATMENTS -----------------
      # CTUI-5: "a file served `savUnverified` must not look identical to one
      # served `savVerified`". The app paints both, so the difference is read
      # off ONE terminal rather than compared between two runs.
      let verifiedTitle = sess.regionText(0, 0, Cols, 1).split('\n')[0]
      let unverifiedTitle =
        sess.regionText(heights.top, 0, Cols, 1).split('\n')[0]
      checkpoint("verified title:   " & verifiedTitle.strip())
      checkpoint("unverified title: " & unverifiedTitle.strip())
      ck verifiedTitle.contains(VerifiedMarker)
      ck unverifiedTitle.contains(UnverifiedMarker)
      ck not verifiedTitle.contains(UnverifiedMarker)
      # …and the line-number TINT, which is the signal that survives scrolling
      # the title row out of view. Read at the same column on both panes.
      let numCol = lineNumberColumn()
      let verifiedNumber = sess.cellAt(2, numCol)
      let unverifiedNumber = sess.cellAt(heights.top + 2, numCol)
      checkpoint("verified line number:   " & describeCell(verifiedNumber))
      checkpoint("unverified line number: " & describeCell(unverifiedNumber))
      ck verifiedNumber.fg.kind == ckIndexed
      ck verifiedNumber.fg.idx == 8'u8     # `bright_black`
      ck unverifiedNumber.fg.kind == ckIndexed
      ck unverifiedNumber.fg.idx == 3'u8   # `yellow`
      # THE WHOLE POINT, as one assertion: the two do not look the same.
      ck verifiedNumber.fg.idx != unverifiedNumber.fg.idx

      # ---- SYNTAX HIGHLIGHTING, THROUGH A REAL GRAMMAR, ON A REAL TERMINAL --
      # `import` on sample line 3 is a Nim keyword; the vendored grammar
      # classifies it and the palette gives it magenta+bold.
      let keywordRow = 1 + 3 - model0.viewportTop
      let keywordCell = sess.cellAt(keywordRow, pointerColumn(Cols, model0) +
                                    GutterPointerCells + GutterGapCells)
      checkpoint("first code cell of the `import` line: " &
                 describeCell(keywordCell))
      ck $keywordCell.rune == "i"
      ck keywordCell.fg.kind == ckIndexed
      ck keywordCell.fg.idx == 5'u8        # `magenta`
      ck caBold in keywordCell.attrs

      # ---- THE STEP ---------------------------------------------------------
      sess.sendKey("f10")
      waitForCompleteFrame(sess, Cols, Rows, FrameTimeoutMs)
      sess.send($TestAppCaptureByte)
      let frame1 = waitForSnapshotLabel(sess, stepLabel(Label, 1))
      ck frame1.label == stepLabel(Label, 1)
      ck frame1.label != frame0.label

      let model1 = paneApp.sourceModel(1, gpVerified)
      ck model1.executionLine != model0.executionLine
      let row1 = paneRowOf(model1, 0)
      ck row1 != row0

      let pointerRow1 = sess.regionText(row1, 0, Cols, 1).split('\n')[0]
      checkpoint("pointer row at step 1: '" & pointerRow1.strip() & "'")
      ck pointerRow1.contains(ExecutionPointerGlyph)
      ck pointerRow1.contains($model1.executionLine)
      # …and the row the pointer LEFT no longer carries it. A pointer that
      # appeared in its new place without leaving the old one is a defect a
      # "the new row has an arrow" check cannot see.
      let vacatedRow = sess.regionText(row0, 0, Cols, 1).split('\n')[0]
      ck not vacatedRow.contains(ExecutionPointerGlyph)
      # The accent moved with it, in the terminal's own cell model.
      let ptrCell1 = sess.cellAt(row1, pointerColumn(Cols, model1))
      ck $ptrCell1.rune == "-"
      ck ptrCell1.fg.kind == ckIndexed
      ck ptrCell1.fg.idx == 11'u8
      ck caBold in ptrCell1.attrs
      # …and the vacated row's gutter is back to the terminal default there.
      let vacatedCell = sess.cellAt(row0, pointerColumn(Cols, model0))
      checkpoint("vacated pointer cell: " & describeCell(vacatedCell))
      ck vacatedCell.fg.kind == ckDefault
      ck vacatedCell.bg.kind == ckDefault

      sess.send($TestAppQuitByte)
      let status = sess.waitExit(initDuration(seconds = 10))
      ck status.isSome
      ck status.get() == TestAppExitOk
    finally:
      sess.terminate()
      sess.close()

  test "cross-tier snapshot equality grounds the pane's Tier-1 goldens":
    # docs/tui-testing.md: "a new pane needs exactly one cross-tier equivalence
    # test. Not zero, and not one per assertion." This is the source pane's, at
    # CTUI-2's two geometries, through the SAME `buildTree` both tiers run.
    var checkedCases = 0
    for g in [(cols: 80, rows: 24), (cols: Cols, rows: Rows)]:
      let res = runDualSnap(Stem, paneApp.buildTree, g.cols, g.rows)
      inc checkedCases
      if res.divergences.len > 0:
        checkpoint(report(res))
      ck res.divergences.len == 0
      # THE NON-VACUITY FLOOR, and it is the EXACT painted-cell count rather
      # than "more than none": a screen the two tiers agree is blank would
      # satisfy the equality above for free. The number is knowable because the
      # tree is a pure function of the geometry.
      let canon = canonFromDir(res.tier1Dir)
      let painted = countCellsWhere(canon, proc(c: CanonCell): bool =
        c.rune != " " and c.rune.len > 0)
      var modelPainted = 0
      let heights = paneApp.paneHeights(g.rows)
      for (top, provenance) in [(0, gpVerified), (heights.top, gpUnverified)]:
        let paneHeight = if top == 0: heights.top else: heights.bottom
        if paneHeight <= 0:
          continue
        for line in sourcePaneText(paneApp.sourceModel(0, provenance),
                                   g.cols, paneHeight):
          for r in runes(line):
            if $r != " ":
              inc modelPainted
      checkpoint("app_source_pane at " & $g.cols & "x" & $g.rows & ": " &
                 $painted & " painted cell(s) of " &
                 $(canon.rows * canon.cols) & ", model says " & $modelPainted)
      ck painted == modelPainted
      ck painted > 0
      # And the two tiers really are two tiers — `compareSnapshotDirs` refuses
      # a directory compared with itself, which is the vacuous pass this whole
      # construction exists to prevent.
      ck canon.dialect == "tier1-isonim-tui"
      ck canonFromDir(res.tier2Dir).dialect == "tier2-libvterm"
    ck checkedCases == 2

  test "assertion count":
    echo "CHECKS: " & $countedAssertions
    checkpoint("counted assertions: " & $countedAssertions)
    check countedAssertions == ExpectedAssertions
