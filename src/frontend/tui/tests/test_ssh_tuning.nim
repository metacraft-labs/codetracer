## test_ssh_tuning.nim — CTUI-14, Tier 1. What goes down the wire.
##
## ## What only this file can say
##
## `host/ssh_tuning.nim` is a pure function of two `ScreenBuffer`s, and that is
## the whole reason it is a module: the emission POLICY — which runs are dirty,
## where a run may start, when a diff is worse than a frame, whether a frame is
## held — is decidable without a terminal, and everything here is decided
## without one. The Tier-2 half of the same contract is
## `tests/real_terminal/test_real_high_latency.nim`, which asserts the thing no
## in-process test can: that a real terminal fed the diffed stream ends up
## showing the same screen a real terminal fed the full frames does.
##
## The division is the one `docs/tui-testing.md` states. **Nothing here claims
## the screens are equal.** Tier 1 has no terminal to be equal on; what it
## claims is that every cell that changed is inside a run, that a run never
## begins on the trailing half of a wide glyph, and that the joins and the
## fallbacks are the ones the module documents.
##
## ## THE ORACLE FOR "WHICH CELLS CHANGED" IS COMPUTED HERE, CELL BY CELL
##
## `dirtyRuns` is built on `isonim_tui`'s `ScreenBuffer.diff`, so a test that
## compared its answer against `diff` would be comparing the subject with its
## own dependency. The coverage check below walks the two buffers directly —
## `prev[r, c] != curr[r, c]` — and asserts that every differing cell falls
## inside some run. That is an expected value this file produces, which is what
## rule 6 of `docs/tui-testing.md` asks for.
##
## ## Templates, not procs, for anything that calls `check`
##
## `std/unittest`'s `check` assigns `testStatusIMPL`, which the `test` template
## injects into its own scope; inside a `proc` that symbol is invisible, `check`
## takes its `else` branch, and the case still prints `[OK]` while
## `programResult` goes to 1.

import std/[strutils, unicode, unittest]

import isonim_tui

import ../app/theme/capabilities
import ../host/ssh_tuning

# One line, deliberately: `ci/lib/run-nim-test-lane.sh` reads exactly this
# spelling as a RUNTIME assertion count, and inside a `const` block the
# declaration is invisible to it.
const ExpectedAssertions = 134

var countedAssertions = 0

template ck(condition: untyped) =
  inc countedAssertions
  check condition

const
  Cols = 120
  Rows = 40
    ## §3.1's STANDARD profile geometry, so the byte counts below are the ones
    ## a real session produces rather than the ones a toy screen would.

let
  SyncCaps = TerminalCapabilities(
    colors: cdAnsi256, borders: bmUnicode, mouse: true,
    synchronizedOutput: true, theme: utDark)
  PlainCaps = TerminalCapabilities(
    colors: cdAnsi256, borders: bmUnicode, mouse: true,
    synchronizedOutput: false, theme: utDark)

proc textCell(r: Rune; fg = defaultColor(); attrs: set[Attr] = {}): Cell =
  ## A narrow cell. Not `check`-reaching, so a `proc` is correct here.
  Cell(rune: r, fg: fg, bg: defaultColor(), attrs: attrs, width: 1)

proc filledScreen(cols, rows: int; fill = Rune(' ')): ScreenBuffer =
  ## A screen with something on every cell, so a "nothing changed" answer is
  ## never true for free.
  result = newScreenBuffer(cols, rows)
  for r in 0 ..< rows:
    for c in 0 ..< cols:
      result.setCell(r, c, textCell(fill))

proc wideScreen(cols, rows: int): ScreenBuffer =
  ## A screen carrying a WIDE glyph at columns 10-11 of row 3: the head at 10
  ## and its ghost (`width == 0`) at 11. Every other cell is a space.
  ##
  ## `世` is the same glyph the cross-tier suite found the compositor's
  ## ghost-cell defect on, which is why it is the one used here.
  result = filledScreen(cols, rows)
  result.setCell(3, 10, Cell(rune: "世".runeAt(0), fg: defaultColor(),
                             bg: defaultColor(), attrs: {}, width: 2))
  result.setCell(3, 11, Cell(rune: Rune(0), fg: defaultColor(),
                             bg: defaultColor(), attrs: {}, width: 0))

proc changedCells(a, b: ScreenBuffer): seq[(int, int)] =
  ## THE ORACLE. Every `(row, col)` at which the two screens differ, computed
  ## by walking them rather than by asking the module under test.
  result = @[]
  for r in 0 ..< min(a.rowsCount, b.rowsCount):
    for c in 0 ..< min(a.cols, b.cols):
      if a[r, c] != b[r, c]:
        result.add (r, c)

proc covers(runs: seq[DirtyRun]; row, col: int): bool =
  for run in runs:
    if run.row == row and col >= run.startCol and col < run.endCol:
      return true
  false

proc coveredWidth(runs: seq[DirtyRun]): int =
  for run in runs:
    result += run.runWidth

suite "CTUI-14 Tier 1: SSH emission tuning":

  test "an unchanged screen has no dirty runs, and a changed one does":
    let base = filledScreen(Cols, Rows)
    ck dirtyRuns(base, base).len == 0
    # THE POSITIVE TWIN, through the same function: a screen that DID change
    # produces runs, so the line above is a statement about the comparison and
    # not about a function that always answers nothing.
    var moved = base
    moved.setCell(7, 33, textCell(Rune('X')))
    let runs = dirtyRuns(base, moved)
    checkpoint("one changed cell -> " & $runs.len & " run(s)")
    ck runs.len == 1
    ck runs[0].row == 7
    ck runs[0].startCol == 33
    ck runs[0].endCol == 34
    ck runs[0].runWidth == 1

  test "every cell that changed is inside a run, over a realistic edit":
    # A STEP-SHAPED EDIT: four rows touched, in runs of different widths and at
    # different columns, which is what a source pane plus a header counter plus
    # a status line actually produces.
    let base = filledScreen(Cols, Rows)
    var next = base
    for (row, col, text) in [(0, 40, "tick 318"), (11, 4, "-->"),
                             (11, 30, "def add(left, right):"),
                             (Rows - 1, 12, "NORMAL")]:
      for i, r in toRunes(text):
        next.setCell(row, col + i, textCell(r))

    let expected = changedCells(base, next)
    checkpoint("cells changed by the edit: " & $expected.len)
    # THE NON-VACUITY FLOOR: an oracle that found nothing would make the
    # coverage sweep below true for free.
    #
    # THIRTY-FIVE, NOT THIRTY-EIGHT, and the difference is the whole reason the
    # oracle is computed cell by cell instead of taken from the text lengths: a
    # SPACE WRITTEN OVER A SPACE IS NOT A CHANGE. `tick 318` carries one,
    # `def add(left, right):` carries two, and those three cells are identical
    # in both buffers.
    ck expected.len == (8 - 1) + 3 + (21 - 2) + 6
    ck expected.len == 35

    let runs = dirtyRuns(base, next)
    checkpoint("runs: " & $runs.len & ", covering " & $coveredWidth(runs) &
               " cell(s)")
    var covered = 0
    for (row, col) in expected:
      if not covers(runs, row, col):
        checkpoint("UNCOVERED CHANGED CELL at " & $row & "," & $col)
      ck covers(runs, row, col)
      inc covered
    ck covered == expected.len
    # FOUR RUNS, one per touched row — the two edits on row 11 are 23 columns
    # apart, which is wider than `DefaultJoinGap`, so they stay separate.
    ck runs.len == 4
    # THE RUNS COVER 38 CELLS FOR 35 CHANGES, and the three extra are exactly
    # the interior spaces the join swallowed: each is one unchanged cell
    # between two changed ones, which `DefaultJoinGap` says costs less to
    # re-send than to jump over. Asserted as a NUMBER rather than as "roughly
    # the same", because a diff that answered "the whole screen" would be
    # covering 4800 and would still pass the sweep above.
    checkpoint("covered " & $coveredWidth(runs) & " cells for " &
               $expected.len & " changes")
    ck coveredWidth(runs) == 38
    ck coveredWidth(runs) - expected.len == 3
    # …and with no joining at all the runs cover EXACTLY the changed cells, so
    # the three above are the parameter's doing and not the diff's.
    ck coveredWidth(dirtyRuns(base, next, joinGap = 0)) == expected.len

  test "a run never begins on the trailing half of a wide glyph":
    # THE GHOST RULE. The cell at (3, 11) is the second half of `世` and has
    # `width == 0`; a run that began there would address the cursor between the
    # halves of one glyph and emit nothing for it.
    let base = wideScreen(Cols, Rows)
    var next = base
    # Change the ghost cell's ATTRIBUTES so the diff reports a change starting
    # exactly at column 11.
    next.setCell(3, 11, Cell(rune: Rune(0), fg: defaultColor(),
                             bg: defaultColor(), attrs: {attrBold}, width: 0))
    let runs = dirtyRuns(base, next)
    checkpoint("runs after mutating the ghost at (3,11): " & $runs.len)
    ck runs.len == 1
    ck runs[0].row == 3
    # EXPANDED LEFT onto the head at column 10.
    ck runs[0].startCol == 10
    ck runs[0].endCol == 12

    let bytes = emitRuns(next, runs)
    checkpoint("emitted: " & escape(bytes))
    # The head is written ONCE and the ghost is written not at all, which is
    # what `encodeAnsi` does for a full frame and therefore what keeps the two
    # paths in agreement about columns.
    ck bytes.count("世") == 1
    # NO NUL BYTE. `Rune(0)` is a cell nothing was written to; emitting it
    # verbatim is the defect this arm exists for.
    ck not bytes.contains('\0')
    ck bytes.startsWith(cursorTo(3, 10))

  test "the join gap is a measured trade, and both sides of it are asserted":
    let base = filledScreen(Cols, Rows)
    var next = base
    next.setCell(5, 20, textCell(Rune('a')))
    next.setCell(5, 24, textCell(Rune('b')))
    # THREE UNCHANGED CELLS BETWEEN THEM (21, 22, 23).
    let joined = dirtyRuns(base, next, joinGap = DefaultJoinGap)
    checkpoint("gap 3, joinGap " & $DefaultJoinGap & " -> " & $joined.len &
               " run(s)")
    ck joined.len == 1
    ck joined[0].startCol == 20
    ck joined[0].endCol == 25
    # …AND WITH NO JOINING AT ALL they are two runs, which is what makes the
    # line above a statement about the parameter rather than about the data.
    let split = dirtyRuns(base, next, joinGap = 0)
    checkpoint("gap 3, joinGap 0 -> " & $split.len & " run(s)")
    ck split.len == 2
    ck split[0].endCol == 21
    ck split[1].startCol == 24
    # A gap WIDER than the parameter is not joined either, so the rule is a
    # comparison and not "always join".
    var far = base
    far.setCell(5, 20, textCell(Rune('a')))
    far.setCell(5, 40, textCell(Rune('b')))
    ck dirtyRuns(base, far, joinGap = DefaultJoinGap).len == 2
    # …and raising the parameter past the gap joins them, through the same
    # call.
    ck dirtyRuns(base, far, joinGap = 25).len == 1
    # THE BYTES ARE WHAT THE TRADE IS ABOUT: joining three cells costs three
    # bytes and saves a cursor address.
    let joinedBytes = emitRuns(next, joined).len
    let splitBytes = emitRuns(next, split).len
    checkpoint("joined " & $joinedBytes & " bytes, split " & $splitBytes)
    ck joinedBytes < splitBytes

  test "geometry mismatch answers no runs rather than a partial diff":
    let small = filledScreen(80, 24)
    let large = filledScreen(Cols, Rows)
    ck dirtyRuns(small, large).len == 0
    ck dirtyRuns(large, small).len == 0
    # …and two screens of the SAME geometry do answer, so the two lines above
    # are about the mismatch.
    var moved = large
    moved.setCell(1, 1, textCell(Rune('z')))
    ck dirtyRuns(large, moved).len == 1

  test "the first frame is full, and every later one is a diff":
    let emitter = newFrameEmitter(PlainCaps)
    let base = filledScreen(Cols, Rows)
    let first = emitter.emit(base)
    checkpoint("frame 0: " & $first.len & " bytes; " & emitter.describe())
    ck emitter.fullFrames == 1
    ck emitter.diffFrames == 0
    # A full frame CLEARS and repaints, so it carries the clear and every row.
    ck first.startsWith(ClearScreenBytes)
    ck first.len > Cols * Rows

    var next = base
    for i, r in toRunes("stepped"):
      next.setCell(4, 10 + i, textCell(r))
    let second = emitter.emit(next)
    checkpoint("frame 1: " & $second.len & " bytes; " & emitter.describe())
    ck emitter.diffFrames == 1
    ck emitter.fullFrames == 1
    ck not second.contains(ClearScreenBytes)
    ck second.contains("stepped")
    # §8's SINGLE-STEP EMISSION BUDGET is 250 bytes, and a seven-character edit
    # is comfortably inside it — which is the point of the module: the same
    # edit as a full frame is two orders of magnitude larger.
    ck second.len < 250
    ck first.len > second.len * 20

  test "a diffed frame parks the cursor on the bottom-right cell":
    # THE FRAME BARRIER. `dual_snap.waitForCompleteFrame` waits for the cursor
    # at `(rows-1, cols-1)`; a full frame reaches it by writing the last cell,
    # and a diff that never touched the last row has to say so.
    let emitter = newFrameEmitter(PlainCaps)
    let base = filledScreen(Cols, Rows)
    discard emitter.emit(base)
    var next = base
    next.setCell(0, 0, textCell(Rune('!')))
    let diffed = emitter.emit(next)
    checkpoint("diffed frame: " & escape(diffed))
    ck diffed.endsWith(cursorTo(Rows - 1, Cols - 1))
    ck cursorTo(Rows - 1, Cols - 1) == "\x1b[40;120H"
    # …and an epilogue still comes after the park, because §3.3.6's prompt has
    # to be able to move the cursor back off it.
    var third = next
    third.setCell(0, 1, textCell(Rune('?')))
    let withEpilogue = emitter.emit(third, epilogue = "\x1b[9;9H")
    ck withEpilogue.endsWith("\x1b[9;9H")
    ck withEpilogue.contains(cursorTo(Rows - 1, Cols - 1))

  test "an unchanged repaint emits no cells and still reaches the barrier":
    let emitter = newFrameEmitter(PlainCaps)
    let base = filledScreen(Cols, Rows)
    discard emitter.emit(base)
    let idle = emitter.emit(base)
    checkpoint("repaint of an identical screen: " & escape(idle))
    ck emitter.emptyFrames == 1
    ck idle == cursorTo(Rows - 1, Cols - 1)
    ck idle.len == 9

  test "a diff that would cost more than the frame is not sent as a diff":
    # A CHECKERBOARD IS THE WORST CASE for a run-based diff: every changed cell
    # is its own run, and a run costs a cursor address that a full frame does
    # not. `joinGap = 0` is what makes it that shape deterministically — which
    # is also the measurement behind `DefaultJoinGap` existing at all.
    let emitter = newFrameEmitter(PlainCaps, joinGap = 0)
    let a = filledScreen(Cols, Rows, Rune('a'))
    discard emitter.emit(a)
    var checker = a
    for r in 0 ..< Rows:
      for c in countup(0, Cols - 1, 2):
        checker.setCell(r, c, textCell(Rune('b')))
    let runs = dirtyRuns(a, checker, joinGap = 0)
    checkpoint("checkerboard: " & $runs.len & " runs, diff would be " &
               $emitRuns(checker, runs).len & " bytes, frame is " &
               $frameBytes(checker).len)
    ck runs.len == Rows * (Cols div 2)
    ck emitRuns(checker, runs).len > frameBytes(checker).len

    let sent = emitter.emit(checker)
    checkpoint("emitted " & $sent.len & " bytes; " & emitter.describe())
    ck emitter.fullFrames == 2
    ck emitter.diffFrames == 0
    ck sent.startsWith(ClearScreenBytes)
    # …and the emitter's memory is still correct afterwards, so the NEXT small
    # change is a diff again.
    var one = checker
    one.setCell(2, 2, textCell(Rune('c')))
    let after = emitter.emit(one)
    ck emitter.diffFrames == 1
    ck after.len < 60

  test "a diffed frame is NEVER larger than the frame it replaces":
    # THE INVARIANT BEHIND THE ARM ABOVE, stated over three shapes rather than
    # over the one that happens to take the fallback: whatever changed, the
    # emitter sends the cheaper of the two. An emitter that always diffed would
    # redden on the checkerboard; one that always sent frames would redden on
    # `first.len > second.len * 20` two cases up.
    var shapes = 0
    for shape in 0 .. 2:
      let emitter = newFrameEmitter(PlainCaps)
      let base = filledScreen(Cols, Rows, Rune('a'))
      discard emitter.emit(base)
      var next = base
      case shape
      of 0:
        next.setCell(4, 4, textCell(Rune('x')))
      of 1:
        for c in 0 ..< Cols:
          next.setCell(9, c, textCell(Rune('y')))
      else:
        next = filledScreen(Cols, Rows, Rune('z'))
      let sent = emitter.emit(next)
      let full = frameBytes(next).len
      checkpoint("shape " & $shape & ": sent " & $sent.len & ", full " & $full)
      ck sent.len <= full + cursorTo(Rows - 1, Cols - 1).len
      inc shapes
    ck shapes == 3

  test "a resize forces a full frame, and so does an explicit reset":
    let emitter = newFrameEmitter(PlainCaps)
    discard emitter.emit(filledScreen(Cols, Rows))
    let resized = emitter.emit(filledScreen(80, 24))
    ck emitter.fullFrames == 2
    ck resized.startsWith(ClearScreenBytes)
    # A second frame at the NEW geometry diffs, so the full frame above was the
    # geometry change and not the emitter having given up.
    var moved = filledScreen(80, 24)
    moved.setCell(3, 3, textCell(Rune('r')))
    discard emitter.emit(moved)
    ck emitter.diffFrames == 1
    # `reset` — what `TerminalDriver.start` calls when it claims the alternate
    # screen — makes the next one full again.
    emitter.reset()
    discard emitter.emit(moved)
    ck emitter.fullFrames == 3
    ck emitter.diffFrames == 1

  test "DEC 2026 brackets exactly one pair around a diffed frame":
    let emitter = newFrameEmitter(SyncCaps)
    let base = filledScreen(Cols, Rows)
    let first = emitter.emit(base)
    ck first.startsWith(SynchronizedOpenBytes)
    ck first.endsWith(SynchronizedCloseBytes)
    ck first.count(SynchronizedOpenBytes) == 1
    ck first.count(SynchronizedCloseBytes) == 1
    var next = base
    next.setCell(6, 6, textCell(Rune('s')))
    let diffed = emitter.emit(next)
    checkpoint("bracketed diff: " & escape(diffed))
    ck diffed.startsWith(SynchronizedOpenBytes)
    ck diffed.endsWith(SynchronizedCloseBytes)
    ck diffed.count(SynchronizedOpenBytes) == 1
    ck diffed.count(SynchronizedCloseBytes) == 1
    # …and a terminal that does not advertise it is sent neither byte, through
    # the same emitter code path.
    let plain = newFrameEmitter(PlainCaps)
    discard plain.emit(base)
    let unbracketed = plain.emit(next)
    ck not unbracketed.contains(SynchronizedOpenBytes)
    ck not unbracketed.contains(SynchronizedCloseBytes)
    # The bodies are otherwise the same, which is what makes the bracket a
    # wrapper rather than a mode.
    ck diffed == SynchronizedOpenBytes & unbracketed & SynchronizedCloseBytes

  test "diffing off reproduces the pre-CTUI-14 stream, frame for frame":
    # THE CONTROL ARM, and the reason `FrameEmitter.diffing` exists at all:
    # `benchmarks/tui_benchmarks.nim` measures the tuned and untuned emission
    # in ONE run, so the saving is a difference rather than two numbers from
    # two builds.
    let base = filledScreen(Cols, Rows)
    var next = base
    next.setCell(9, 9, textCell(Rune('n')))
    let tuned = newFrameEmitter(PlainCaps, diffing = true)
    let untuned = newFrameEmitter(PlainCaps, diffing = false)
    ck tuned.emit(base) == untuned.emit(base)
    let tunedSecond = tuned.emit(next)
    let untunedSecond = untuned.emit(next)
    checkpoint("second frame: tuned " & $tunedSecond.len & " bytes, untuned " &
               $untunedSecond.len)
    ck untuned.fullFrames == 2
    ck untuned.diffFrames == 0
    ck tuned.diffFrames == 1
    ck untunedSecond == frameBytes(next)
    ck tunedSecond.len * 100 < untunedSecond.len

  test "coalescing holds a frame only when more input is already waiting":
    # THE CONTRACT: *coalescing must not increase p50 input latency*. It is
    # enforced by the SHAPE of `hold`, so this is what asserts the shape.
    var c = initWriteCoalescer(maxHeld = 3)
    # NOTHING PENDING — never held, however many times it is asked.
    var neverHeld = 0
    for _ in 0 ..< 50:
      if not c.hold(morePending = false):
        inc neverHeld
    checkpoint("frames painted immediately with an idle keyboard: " &
               $neverHeld)
    ck neverHeld == 50
    ck c.held == 0

    # WITH INPUT PENDING it holds, up to the ceiling, and then paints.
    ck c.hold(morePending = true)
    ck c.hold(morePending = true)
    ck c.hold(morePending = true)
    ck c.held == 3
    # THE CEILING: a held key repeating faster than the application can answer
    # must not freeze the screen for as long as it is held.
    ck not c.hold(morePending = true)
    ck c.held == 0
    # …and the run starts again afterwards, so the ceiling is periodic rather
    # than a one-shot.
    ck c.hold(morePending = true)
    ck c.held == 1
    # A frame that went out for another reason — a resize, the first paint —
    # ends the run too.
    c.noteFlush()
    ck c.held == 0
    # THE LAST KEY OF A BURST IS NEVER HELD: `morePending` is false for it by
    # construction, whatever happened before.
    ck c.hold(morePending = true)
    ck not c.hold(morePending = false)

  test "the emitter's byte counter is the driver's own budget":
    let emitter = newFrameEmitter(PlainCaps)
    let base = filledScreen(Cols, Rows)
    var total = 0
    total += emitter.emit(base).len
    var next = base
    next.setCell(1, 1, textCell(Rune('1')))
    total += emitter.emit(next).len
    var third = next
    third.setCell(2, 2, textCell(Rune('2')))
    total += emitter.emit(third).len
    checkpoint(emitter.describe())
    ck emitter.bytesEmitted == total
    ck emitter.fullFrames + emitter.diffFrames + emitter.emptyFrames == 3
    ck emitter.describe().contains("diffing=true")
    ck emitter.describe().contains("joinGap=" & $DefaultJoinGap)

  test "assertion count":
    echo "CHECKS: " & $countedAssertions
    checkpoint("counted assertions: " & $countedAssertions)
    check countedAssertions == ExpectedAssertions
