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
## ## M73 (#840): THE SHIPPED EDITOR UNDER THE WHEEL
##
## One case here is not about the snapshot app: it spawns the shipped
## `codetracer-tui` on the real `calc` recording (a real `replay-server`
## behind it), sends the wheel's SGR-1006 bytes over the editor with
## `sendMouseScroll`, and reads back off the terminal's cells that the lines
## the editor shows moved — three a notch — and that the vertical bar's thumb
## in the pane's last column moved with them (Scrollbar-Scrubbers.md §4).
## Before M73 the wheel was not routed to the editor and the pane had no
## vertical bar (Pxor-Bugs M73).
##
## ## Templates, not procs, for anything that calls `check`

import std/[os, strutils, times, unicode, unittest]

import isonim_tui
import term_assert

import ../../app/views/source_pane
import ../../testing/dual_snap
import ../../testing/test_app_runtime
import ../apps/app_source_pane as paneApp
import ./derived_colours
# M73 (#840): the shipped binary on a real recording.
import ../fixtures/fixture_provider
import ./lifecycle_support

# One line, deliberately: `ci/lib/run-nim-test-lane.sh` reads exactly this
# spelling as a RUNTIME assertion count, and inside a `const` block the
# declaration is invisible to it.
const ExpectedAssertions = 81

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
      # PLAT-51: the mark is the field's middle cell (` ▸ `; it was `-->`).
      let ptrCell = sess.cellAt(row0, ptrCol + 1)
      checkpoint("pointer cell (" & $row0 & "," & $ptrCol & "): " &
                 describeCell(ptrCell))
      ck $ptrCell.rune == ExecutionPointerGlyph.strip()
      # PLAT-46: the execution pointer's role, on the DERIVED 16-colour rung
      # (`derived_colours`), which libvterm reports as an index.
      ck ptrCell.fg.kind == ckIndexed
      ck ptrCell.fg.idx == ansiIndexOf(srGutterExecutionPointer)
      ck caBold in ptrCell.attrs
      # …and the execution line's background highlight is the desktop's
      # Monaco band (PLAT-47): it reaches the pane's LAST column, past the
      # end of the line's text, and leaves the gutter (the pointer) alone.
      let bandCell = sess.cellAt(row0, Cols - 1)
      ck bandCell.bg.kind == ckIndexed and
         bandCell.bg.idx == ansiIndexOf(srLineExecution, background = true)
      ck not (ptrCell.bg.kind == ckIndexed and
              ptrCell.bg.idx == ansiIndexOf(srLineExecution, background = true))

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
          ck cell.fg.idx == ansiIndexOf(srGutterBreakpoint)
          ck caBold in cell.attrs
        of gmBreakpointDisabled:
          ck $cell.rune == BreakpointDisabledGlyph
          ck cell.fg.kind == ckIndexed
          ck cell.fg.idx == ansiIndexOf(srGutterBreakpointDisabled)
          ck caBold notin cell.attrs
        of gmTracepoint:
          ck $cell.rune == TracepointGlyph
          ck cell.fg.kind == ckIndexed
          ck cell.fg.idx == ansiIndexOf(srGutterTracepoint)
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
      ck verifiedNumber.fg.idx == ansiIndexOf(srLineNumber)
      ck unverifiedNumber.fg.kind == ckIndexed
      ck unverifiedNumber.fg.idx == ansiIndexOf(srLineNumberUnverified)
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
      ck keywordCell.fg.idx == ansiIndexOf(srSyntaxKeyword)
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
      let ptrCell1 = sess.cellAt(row1, pointerColumn(Cols, model1) + 1)
      ck $ptrCell1.rune == ExecutionPointerGlyph.strip()
      ck ptrCell1.fg.kind == ckIndexed
      ck ptrCell1.fg.idx == ansiIndexOf(srGutterExecutionPointer)
      ck caBold in ptrCell1.attrs
      # …and the vacated row's gutter is back to the terminal default there.
      let vacatedCell = sess.cellAt(row0, pointerColumn(Cols, model0))
      checkpoint("vacated pointer cell: " & describeCell(vacatedCell))
      ck vacatedCell.fg.kind == ckDefault
      ck vacatedCell.bg.kind == ckDefault
      # …and the band left the vacated row to its last column.
      let vacatedEnd = sess.cellAt(row0, Cols - 1)
      ck not (vacatedEnd.bg.kind == ckIndexed and
              vacatedEnd.bg.idx == ansiIndexOf(srLineExecution, background = true))

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

  test "M73 (#840): the wheel over the shipped editor moves its lines, and the vertical bar's thumb moves with them":
    # THE SHIPPED BINARY on a real recording, not the snapshot app: the
    # defect was that nothing a user did reached the window `SourceVM` holds
    # (Pxor-Bugs M73), so only the real runtime, host and engine can show it.
    # `calc`'s `main.py` is 116 lines, several times the editor's height
    # here. The wheel is TermAssert's `sendMouseScroll` — the SGR-1006 bytes
    # a terminal writes — aimed at the editor's body while another pane may
    # hold the focus (CodeTracer-TUI.md §4.4).
    let fixture = resolveFixture("calc")
    require fixture.outcome == foRecorded
    let state = getTempDir() / ("m73-pty-" & $getCurrentProcessId())
    removeDir(state)
    createDir(state)
    const M73Cols = 160
    const M73Rows = 48
    var sess = newTuiTest(tuiBinary(), @["--theme=dark", fixture.tracePath])
      .width(M73Cols).height(M73Rows)
      .envRemove("TERM_PROGRAM", "NO_COLOR", "LC_ALL", "LC_CTYPE", "TMUX",
                 "STY", "NERD_FONT", "NERDFONT", "COLORFGBG")
      .envSet("TERM", "xterm-256color").envSet("LANG", "en_US.UTF-8")
      .envSet("COLORTERM", "truecolor")
      .envSet("XDG_STATE_HOME", state)
      .envSet("CODETRACER_HOME", state / "ct-home")
      .envSet("CODETRACER_TUI_LAYOUT_DIR", state / "layout")
      .spawn()
    try:
      settleOnDebugger(sess, M73Cols, M73Rows)
      let source = readFile(lifecycle_support.repoRoot() / "test-programs/calc/main.py")
        .splitLines()

      proc glyphAt(s: var TuiTestSession; r, c: int): string =
        let cell = s.cellAt(r, c)
        if int(cell.rune) == 0: " " else: $cell.rune

      proc rowText(s: var TuiTestSession; r: int): string =
        for c in 0 ..< M73Cols:
          result.add s.glyphAt(r, c)

      type Shown = object
        rowOf: seq[(int, int)]
          ## (screen row, source line) for every row whose text is one of
          ## the file's distinctive lines — read off the cells, so the
          ## lines are what the terminal SHOWS.
        textCol: int
          ## The screen column the code starts in.

      proc distinctive(n: int): bool =
        ## A line long enough, and whose first 24 characters — what a row is
        ## searched for — occur in no other line, to place a row by its text.
        let t = source[n - 1].strip
        if t.len < 24: return false
        var count = 0
        for l in source:
          if l.contains(t[0 ..< 24]): inc count
        count == 1

      proc shown(s: var TuiTestSession): Shown =
        discard s.drainOutput(80)
        result.textCol = -1
        for r in 1 ..< M73Rows - 1:
          let text = s.rowText(r)
          for n in 1 .. source.len:
            if distinctive(n):
              let t = source[n - 1].strip
              let at = text.find(t[0 ..< 24])
              if at >= 0:
                result.rowOf.add (r, n)
                if result.textCol < 0:
                  # The cell where the line's text (with its indentation)
                  # starts.
                  let indent = source[n - 1].len - source[n - 1].strip(
                    trailing = false).len
                  result.textCol = text[0 ..< at].runeLen - indent
                break

      proc trackCol(s: var TuiTestSession; sh: Shown): int =
        ## The vertical bar's column: the first column right of the code
        ## whose every placed row holds a track or thumb glyph.
        result = -1
        if sh.rowOf.len == 0 or sh.textCol < 0: return
        const TrackGlyphs = ["│", "█", "▁", "▂", "▃", "▄", "▅", "▆", "▇"]
        for c in sh.textCol + 1 ..< M73Cols:
          var all = true
          for (r, _) in sh.rowOf:
            if s.glyphAt(r, c) notin TrackGlyphs:
              all = false
              break
          if all:
            return c

      proc thumbStart(s: var TuiTestSession; col, top, bottom: int): int =
        ## The first row of the LONGEST run of non-track cells down `col`
        ## between `top` and `bottom` — the thumb (the execution line's mark
        ## is a single cell, so it is never the longest run of a thumb taller
        ## than one cell).
        var best = (start: -1, len: 0)
        var run = (start: -1, len: 0)
        for r in top .. bottom:
          if s.glyphAt(r, col) != "│":
            if run.start < 0: run = (start: r, len: 0)
            inc run.len
            if run.len > best.len: best = run
          else:
            run = (start: -1, len: 0)
        best.start

      let before = sess.shown()
      checkpoint("placed rows before: " & $before.rowOf)
      ck before.rowOf.len >= 3
      # The anchor: the first placed row that is still on the screen once the
      # lines have moved 18 rows up (six notches of three), so where its line
      # lands is read back rather than inferred.
      var anchor = (-1, -1)
      for (r, n) in before.rowOf:
        if r - 18 >= before.rowOf[0][0]:
          anchor = (r, n)
          break
      checkpoint("anchor (row, line): " & $anchor)
      ck anchor[0] >= 0
      let col = sess.trackCol(before)
      checkpoint("vertical bar column: " & $col)
      ck col > before.textCol
      let firstRow = before.rowOf[0][0]
      let lastRow = before.rowOf[^1][0]
      let thumb0 = if col > 0: sess.thumbStart(col, firstRow, lastRow) else: -1

      # Six notches DOWN over the code, mid-pane.
      let wheelRow = (firstRow + lastRow) div 2
      let wheelCol = before.textCol + 10
      for _ in 0 ..< 6:
        sess.sendMouseScroll(wheelRow, wheelCol, sdDown)
        discard sess.drainOutput(120)
      sleep(300)
      let after = sess.shown()
      checkpoint("placed rows after six notches down: " & $after.rowOf)
      # The line that was on `anchor`'s row is now 18 rows higher (three
      # lines a notch): the editor moved, and by exactly the wheel's lines.
      var moved = -1
      for (r, n) in after.rowOf:
        if n == anchor[1]:
          moved = anchor[0] - r
      checkpoint("anchor line " & $anchor[1] & " moved up " & $moved &
                 " row(s)")
      ck moved == 18
      ck after.rowOf.len >= 1 and after.rowOf != before.rowOf
      # The thumb moved down with the lines.
      let thumb1 = if col > 0: sess.thumbStart(col, firstRow, lastRow) else: -1
      checkpoint("thumb first row " & $thumb0 & " -> " & $thumb1)
      ck thumb0 >= 0
      ck thumb1 > thumb0

      # Six notches UP: back where it was, thumb and lines.
      for _ in 0 ..< 6:
        sess.sendMouseScroll(wheelRow, wheelCol, sdUp)
        discard sess.drainOutput(120)
      sleep(300)
      let back = sess.shown()
      ck back.rowOf == before.rowOf
      ck col > 0 and sess.thumbStart(col, firstRow, lastRow) == thumb0
    finally:
      sess.send("\x11")  # Ctrl+Q, the CUA base's quit
      discard sess.waitExit(initDuration(seconds = 10))
      sess.terminate()
      sess.close()

  test "assertion count":
    echo "CHECKS: " & $countedAssertions
    checkpoint("counted assertions: " & $countedAssertions)
    check countedAssertions == ExpectedAssertions
