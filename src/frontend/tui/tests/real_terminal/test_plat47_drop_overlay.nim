## test_plat47_drop_overlay.nim — PLAT-47 deliverable 6, Tier 2. **Dragging a
## tab shows where it would land, as GoldenLayout does: the region the drop
## would occupy is TINTED, glyphs unchanged, and nothing else is.**
##
## The shipped `codetracer-tui` on the `calc` recording at 200x50, in a real
## PTY; the gesture is a real mouse — a press on the Variables tab, motion
## reports with the button held (the terminal asks for `?1002`), then a
## release or `Esc`. PLAT-51: the drag lifts the tab out of its stack
## (GoldenLayout's drag proxy), so a tint is measured as the DIFFERENCE
## between two hovers of the same drag, read back through libvterm:
##
##   * SPLIT  — the Source pane's right edge band, then its left quarter:
##              exactly the two halves' difference changed colour, glyphs
##              kept;
##   * JOIN   — the Source pane's centre (the user's smaller middle): the tint
##              leaves the right half for the pane's tab strip and nothing
##              else changes;
##   * GROUND — the layout's right edge: GoldenLayout's 50 px band, the
##              layout's full height.
##
## The ghost label ` Variables ` is drawn beside the pointer. Releasing
## performs the indicated command (the status line names it applied;
## `:undo-layout` puts the arrangement back for the next case); `Esc` cancels
## and every cell returns to exactly its colour before the drag.
##
## The expected regions are derived from the screen itself — the dividers
## the terminal drew — not from the binding's own geometry, so the test does
## not agree with the code by construction.
##
## No mocks: the real binary, a real recording, a real PTY (TermAssert +
## libvterm).

import std/[monotimes, options, os, sets, strutils, times, unicode, unittest]

import term_assert

import ../fixtures/fixture_provider
import ./lifecycle_support

# One line, deliberately: `ci/lib/run-nim-test-lane.sh` reads exactly this
# spelling as a RUNTIME assertion count.
const ExpectedAssertions = 21

const
  Cols = 200
  Rows = 50
  StatusRow = Rows - 1

var countedAssertions = 0

template ck(condition: untyped) =
  inc countedAssertions
  check condition

type
  Rect = object
    row, col, width, height: int
  Snapshot = seq[seq[Cell]]

proc contains(r: Rect; row, col: int): bool =
  row >= r.row and row < r.row + r.height and col >= r.col and
    col < r.col + r.width

proc colorKey(c: Color): string =
  case c.kind
  of ckDefault: "default"
  of ckIndexed: "idx" & $c.idx
  of ckRgb: $c.r & "," & $c.g & "," & $c.b

proc snap(sess: var TuiTestSession): Snapshot =
  discard sess.drainOutput(40)
  for r in 0 ..< Rows:
    var row: seq[Cell] = @[]
    for c in 0 ..< Cols:
      row.add sess.cellAt(r, c)
    result.add row

proc rowText(s: Snapshot; r: int): string =
  for c in s[r]:
    result.add(if int(c.rune) == 0: " " else: $c.rune)

proc cellFind(s, needle: string): int =
  ## The CELL column of `needle` in a row's text: runes before its byte index
  ## (the row holds multi-byte box-drawing glyphs, all one cell wide).
  let at = s.find(needle)
  if at < 0: -1 else: s[0 ..< at].runeLen

proc mouse(sess: var TuiTestSession; code, row, col: int; final: char) =
  sess.send("\x1b[<" & $code & ";" & $(col + 1) & ";" & $(row + 1) & $final)

proc waitStatus(sess: var TuiTestSession; needle: string;
                timeoutMs = 20000): string =
  let deadline = getMonoTime() + initDuration(milliseconds = timeoutMs)
  while getMonoTime() < deadline:
    discard sess.drainOutput(40)
    result = sess.regionText(StatusRow, 0, Cols, 1)
    if result.contains(needle):
      return
  raise newException(AssertionFailedError,
    "status never said '" & needle & "': " & result)

proc clickTab(sess: var TuiTestSession; row, col: int) =
  ## A click on a tab activates it SILENTLY (PLAT-49: a plain tab click does
  ## not echo its layout command on the status line), so the frame is let
  ## settle rather than a note waited for.
  sess.sendMouseClick(row, col)
  discard sess.drainOutput(600)

proc dividerCols(s: Snapshot; row: int): seq[int] =
  ## The columns of the divider glyph on a body row: the right edges the
  ## panes drew (PLAT-50: `▏`, `shell.DividerGlyph`).
  for c in 0 ..< Cols:
    if $s[row][c].rune == "▏":
      result.add c

proc changedCells(a, b: Snapshot): HashSet[(int, int)] =
  ## Cells whose colours differ, outside the status line (it narrates).
  result.init()
  for r in 0 ..< StatusRow:
    for c in 0 ..< Cols:
      if colorKey(a[r][c].fg) != colorKey(b[r][c].fg) or
         colorKey(a[r][c].bg) != colorKey(b[r][c].bg):
        result.incl (r, c)

proc rectCells(r: Rect): HashSet[(int, int)] =
  result.init()
  for row in r.row ..< r.row + r.height:
    for col in r.col ..< r.col + r.width:
      result.incl (row, col)

suite "PLAT-47 deliverable 6: the drop indication on a real terminal":

  test "each drop kind tints exactly its region, glyphs kept; release commits, Esc cancels":
    let resolved = resolveFixture("calc")
    ck resolved.outcome == foRecorded
    let state = getEnv("CODETRACER_TUI_LAYOUT_DIR") / "drop-overlay"
    # A FRESH state: the case's geometry is the shared default's, and a
    # document an earlier run left here (a gesture's `:undo-layout` still
    # counts as the user's arrangement and is written through) — or one a
    # mutation harness's rebuilt binary left — would be restored instead.
    # Found when PLAT-48's footer strip was absent from such a document.
    removeDir(state)
    createDir(state)
    var sess = newTuiTest(tuiBinary(), @[resolved.tracePath])
      .width(Cols).height(Rows)
      .envRemove("TERM_PROGRAM", "NO_COLOR", "LC_ALL", "LC_CTYPE", "TMUX")
      .envSet("TERM", "xterm-256color").envSet("LANG", "en_US.UTF-8")
      .envSet("COLORTERM", "truecolor")
      .envSet("CODETRACER_TUI_LAYOUT_DIR", state)
      .spawn()
    settleOnDebugger(sess, Cols, Rows)

    # THE GEOMETRY, READ OFF THE SCREEN. Row 1 is the body's first row: the
    # strips and the Source title. The dividers on row 2 bound the columns.
    var s0 = sess.snap()
    let strip = s0.rowText(1)
    let varCol = strip.cellFind("Variables")
    let callTraceCol = strip.cellFind("Call Trace")
    ck varCol > 0 and callTraceCol > varCol
    let divs = s0.dividerCols(2)
    # Files | Source | Variables stack | Call Trace stack.
    ck divs.len >= 3
    let sourceLeft = divs[0] + 1
    let sourceRight = divs[1]            # the pane's own divider column
    let callLeft = block:
      var c = 0
      for d in divs:
        if d < callTraceCol: c = d + 1
      c
    # The Source pane is a column of its own, the whole body tall; since
    # PLAT-49 part B the footer panels' labels are ON the status line, so the
    # body reaches the row above it. A drop tints the pane's CONTENT — below
    # its tab strip (row 1), as GoldenLayout highlights a stack's content.
    let source = Rect(row: 2, col: sourceLeft,
                      width: sourceRight - sourceLeft + 1,
                      height: StatusRow - 2)

    # A CLICK ON THE VARIABLES TAB FIRST, so the baseline carries the same
    # focus the drag will: the press that starts the drag focuses that stack.
    sess.clickTab(1, varCol + 1)
    let base = sess.snap()

    var lastStatus = ""

    proc startDrag() =
      # PLAT-49: a press only marks the tab; the drag begins once the pointer
      # has moved past the threshold (`binding.DragThresholdCols`), so the
      # press is followed by a motion report three columns along the strip.
      # PLAT-51: the drag LIFTS the Variables tab out of its stack
      # (GoldenLayout's drag proxy), so the pointer is then over that stack's
      # strip with the Scratchpad left in it, and the status line names that
      # drop.
      sess.mouse(0, 1, varCol + 1, 'M')
      sess.mouse(32, 1, varCol + 4, 'M')
      lastStatus = sess.waitStatus("would ")

    proc hover(row, col: int): Snapshot =
      sess.mouse(32, row, col, 'M')
      # Wait for the status line to name the NEW target.
      let deadline = getMonoTime() + initDuration(milliseconds = 20000)
      while getMonoTime() < deadline:
        discard sess.drainOutput(40)
        let st = sess.regionText(StatusRow, 0, Cols, 1)
        if st.contains("would ") and st != lastStatus:
          lastStatus = st
          break
      sess.snap()

    proc ghostStart(col: int): int = min(col, Cols - 12)

    proc ghostAt(s: Snapshot; row, col: int): bool =
      s.rowText(row).runeSubStr(ghostStart(col) + 1, 11) == " Variables "

    proc ghostCells(row, col: int): HashSet[(int, int)] =
      result.init()
      for i in 0 ..< 11:
        result.incl (row, ghostStart(col) + 1 + i)

    proc glyphsSame(a, b: Snapshot; skip: HashSet[(int, int)]): bool =
      for r in 0 ..< StatusRow:
        for c in 0 ..< Cols:
          if (r, c) notin skip and a[r][c].rune != b[r][c].rune:
            checkpoint("glyph differs at " & $r & "," & $c)
            return false
      true

    proc tintMoved(a, b: Snapshot; want, skip: HashSet[(int, int)]): bool =
      ## THE TINT, MEASURED AS A DIFFERENCE between two hovers of ONE drag
      ## (the arrangement the drag draws is the same for both): exactly the
      ## cells in `want` changed colour, apart from the ghost labels' cells.
      let changed = changedCells(a, b) - skip
      let w = want - skip
      if changed != w:
        checkpoint("changed but not expected: " & $((changed - w).len) &
                   ", expected but unchanged: " & $((w - changed).len))
      changed == w

    let half = (source.width + 1) div 2
    let rightHalf = rectCells(Rect(row: source.row,
                                   col: source.col + source.width - half,
                                   width: half, height: source.height))
    let leftHalf = rectCells(Rect(row: source.row, col: source.col,
                                  width: half, height: source.height))
    let splitRow = 20
    let rightCol = sourceRight - 1
    let leftCol = source.col + 1

    # ---- SPLIT: the right edge band of the Source pane -> its right half;
    # the left quarter -> its left half. Between the two hovers EXACTLY the
    # two halves' difference changed colour, and every glyph stayed.
    startDrag()
    let right = hover(splitRow, rightCol)
    ck lastStatus.contains("would splitAfter(")
    let left = hover(splitRow, leftCol)
    ck lastStatus.contains("would splitBefore(")
    let ghosts = ghostCells(splitRow, rightCol) + ghostCells(splitRow, leftCol)
    ck tintMoved(right, left, (rightHalf - leftHalf) + (leftHalf - rightHalf),
                 ghosts)
    ck glyphsSame(right, left, ghosts)
    ck right.ghostAt(splitRow, rightCol) and left.ghostAt(splitRow, leftCol)
    # Release on the right band: the split is committed.
    sess.mouse(0, splitRow, rightCol, 'm')
    ck sess.waitStatus("applied").contains("split")
    let afterSplit = sess.snap()
    ck afterSplit.dividerCols(2).len > divs.len
    sess.send(":undo-layout\r")
    discard sess.waitStatus("layout undone")
    sess.clickTab(1, varCol + 1)

    # ---- THE SMALLER MIDDLE: the Source pane's centre JOINS it — the tint
    # leaves the right half and goes onto the pane's tab strip, where the
    # tab would land (GoldenLayout highlights the header for a join).
    startDrag()
    let fromRight = hover(splitRow, rightCol)
    let midRow = source.row + source.height div 2
    let midCol = source.col + source.width div 2
    let mid = hover(midRow, midCol)
    ck lastStatus.contains("would intoStack(")
    let midGhosts = ghostCells(splitRow, rightCol) + ghostCells(midRow, midCol)
    let moved = changedCells(fromRight, mid) - midGhosts
    var offStrip = 0
    var onStrip = 0
    for (r, c) in moved:
      if r == 1:
        inc onStrip
        if c < source.col or c >= source.col + source.width: inc offStrip
      elif (r, c) notin rightHalf:
        inc offStrip
    checkpoint("join: " & $onStrip & " strip cells changed, " & $offStrip &
               " outside the pane's strip and right half")
    ck offStrip == 0 and onStrip >= source.width - 1
    ck ((rightHalf - midGhosts) - moved).len == 0
    ck mid.ghostAt(midRow, midCol)
    sess.mouse(0, midRow, midCol, 'm')
    ck sess.waitStatus("applied").len > 0
    sess.send(":undo-layout\r")
    discard sess.waitStatus("layout undone")
    sess.clickTab(1, varCol + 1)

    # ---- THE LAYOUT'S OWN EDGE: GoldenLayout's 50 px ground band along the
    # right edge -> a band of the WHOLE layout's height there.
    startDrag()
    let fromLeft = hover(splitRow, leftCol)
    let edgeCol = Cols - 2
    let edge = hover(splitRow, edgeCol)
    ck lastStatus.contains("would splitRoot(right)")
    let band = changedCells(fromLeft, edge) - ghostCells(splitRow, leftCol) -
               ghostCells(splitRow, edgeCol) - leftHalf
    var bandCols: HashSet[int]
    bandCols.init()
    var bandRows: HashSet[int]
    bandRows.init()
    for (r, c) in band:
      bandCols.incl c
      bandRows.incl r
    checkpoint("band columns " & $bandCols.len & ", rows " & $bandRows.len)
    ck bandCols.len >= 4 and bandCols.len <= 6 and Cols - 1 in bandCols
    ck bandRows.len >= StatusRow - 2
    # ---- ESC cancels: every cell is back to its colour before the drag.
    sess.send("\x1b")
    discard sess.waitStatus("gesture cancelled")
    let cancelled = sess.snap()
    ck changedCells(base, cancelled).len == 0
    var textSame = true
    for r in 0 ..< StatusRow:
      if base.rowText(r) != cancelled.rowText(r):
        textSame = false
    ck textSame

    sess.send(":quit\r")
    ck sess.waitExit(initDuration(seconds = 30)) == some(0)
    sess.close()

  test "assertion count":
    check countedAssertions == ExpectedAssertions
