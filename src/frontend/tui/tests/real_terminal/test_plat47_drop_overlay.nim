## test_plat47_drop_overlay.nim — PLAT-47 deliverable 6, Tier 2. **Dragging a
## tab shows where it would land, as GoldenLayout does: the region the drop
## would occupy is TINTED, glyphs unchanged, and nothing else is.**
##
## The shipped `codetracer-tui` on the `calc` recording at 200x50, in a real
## PTY; the gesture is a real mouse — a press on the Variables tab, motion
## reports with the button held (the terminal asks for `?1002`), then a
## release or `Esc`. For each of the four drop kinds the cells are read back
## through libvterm and compared with the same screen before the drag:
##
##   * SPLIT      — the pointer on the Source pane's right edge band: exactly
##                  the right HALF of the Source pane is tinted;
##   * WHOLE PANE — the pointer on the Source pane's body (a bare pane): the
##                  whole pane is tinted;
##   * TAB SLOT   — the pointer on the Call Trace stack's tab strip: exactly
##                  that strip row is tinted (the caret is a cell of it);
##   * DOCK EDGE  — the pointer above the body: the top strip of the layout.
##
## In each case: every tinted cell keeps its glyph (except the ghost label's
## own cells), no cell outside the region changed colour, and the ghost label
## ` Variables ` is drawn beside the pointer. Releasing performs the indicated
## command (the status line names it applied; `:undo-layout` puts the
## arrangement back for the next case); `Esc` cancels and every cell returns
## to exactly its colour before the drag.
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
const ExpectedAssertions = 17

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

proc dividerCols(s: Snapshot; row: int): seq[int] =
  ## The columns of `│` on a body row: the right edges the panes drew.
  for c in 0 ..< Cols:
    if $s[row][c].rune == "│":
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
    # The Source pane is a column of its own, the whole body tall: rows 1 ..
    # StatusRow - 2 — the row above the status line is the bottom strip, the
    # shared default's footer panels (PLAT-48).
    let source = Rect(row: 1, col: sourceLeft,
                      width: sourceRight - sourceLeft + 1,
                      height: StatusRow - 2)

    # A CLICK ON THE VARIABLES TAB FIRST, so the baseline carries the same
    # focus the drag will: the press that starts the drag focuses that stack.
    sess.sendMouseClick(1, varCol + 1)
    discard sess.waitStatus("activateTab(state)")
    let base = sess.snap()

    proc startDrag() =
      sess.mouse(0, 1, varCol + 1, 'M')
      discard sess.waitStatus("dragging")

    proc hover(row, col: int): Snapshot =
      sess.mouse(32, row, col, 'M')
      discard sess.waitStatus("would ")
      sess.snap()

    proc ghostAt(s: Snapshot; row, col: int): bool =
      s.rowText(row).runeSubStr(col + 1, 11) == " Variables "

    proc tintedExactly(s: Snapshot; region: Rect; pointerRow, pointerCol: int):
        bool =
      ## Every cell of `region` changed colour and kept its glyph; nothing
      ## outside `region` changed — apart from the ghost label's own cells.
      var ghost: HashSet[(int, int)]
      ghost.init()
      for i in 0 ..< 11:
        ghost.incl (pointerRow, pointerCol + 1 + i)
      let changed = changedCells(base, s) - ghost
      let want = rectCells(region) - ghost
      var glyphsKept = true
      for (r, c) in want:
        if base[r][c].rune != s[r][c].rune:
          glyphsKept = false
      if changed != want:
        checkpoint("changed outside the region: " & $((changed - want).len) &
                   ", region cells not changed: " & $((want - changed).len))
      changed == want and glyphsKept

    # ---- SPLIT: the right edge band of the Source pane -> its right half.
    startDrag()
    let splitRow = 20
    let splitCol = sourceRight - 1
    let split = hover(splitRow, splitCol)
    let half = (source.width + 1) div 2
    ck tintedExactly(split, Rect(row: source.row,
                                 col: source.col + source.width - half,
                                 width: half, height: source.height),
                     splitRow, splitCol)
    ck split.ghostAt(splitRow, min(splitCol, Cols - 12))
    # Release: the split is committed.
    sess.mouse(0, splitRow, splitCol, 'm')
    ck sess.waitStatus("applied").contains("split")
    let afterSplit = sess.snap()
    ck afterSplit.dividerCols(2).len > divs.len
    sess.send(":undo-layout\r")
    discard sess.waitStatus("layout undone")
    sess.sendMouseClick(1, varCol + 1)
    discard sess.waitStatus("activateTab(state)")

    # ---- WHOLE PANE: the Source pane's body -> all of it.
    startDrag()
    let midRow = 25
    let midCol = source.col + source.width div 2
    let whole = hover(midRow, midCol)
    ck tintedExactly(whole, source, midRow, midCol)
    ck whole.ghostAt(midRow, midCol)
    sess.mouse(0, midRow, midCol, 'm')
    ck sess.waitStatus("applied").len > 0
    sess.send(":undo-layout\r")
    discard sess.waitStatus("layout undone")
    sess.sendMouseClick(1, varCol + 1)
    discard sess.waitStatus("activateTab(state)")

    # ---- TAB SLOT: the Call Trace stack's strip -> that strip row.
    startDrag()
    let slotCol = callTraceCol + 1
    let slot = hover(1, slotCol)
    ck tintedExactly(slot, Rect(row: 1, col: callLeft,
                                width: Cols - callLeft, height: 1),
                     1, slotCol)
    sess.mouse(0, 1, slotCol, 'm')
    ck sess.waitStatus("applied").len > 0
    sess.send(":undo-layout\r")
    discard sess.waitStatus("layout undone")
    sess.sendMouseClick(1, varCol + 1)
    discard sess.waitStatus("activateTab(state)")

    # ---- DOCK EDGE: above the body -> the layout's top strip (row 1).
    startDrag()
    let dockCol = 100
    let dock = hover(0, dockCol)
    ck tintedExactly(dock, Rect(row: 1, col: 0, width: Cols, height: 1),
                     0, dockCol)
    ck dock.ghostAt(0, dockCol)
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
