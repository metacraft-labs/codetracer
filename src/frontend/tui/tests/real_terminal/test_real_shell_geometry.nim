## test_real_shell_geometry.nim — CTUI-3, Tier 2.
##
## ## What only this file can say
##
## CodeTracer-TUI.milestones.org, CTUI-3: "the same three geometries through
## TermAssert, using `regionText` to read each pane's area from a real screen,
## plus a real `setWindowSize` 80x24 -> 120x40 with `assertWindowResize` and a
## `waitForRegionChange` on the body. This is the only place SIGWINCH is
## genuinely exercised; `h.resize` does not deliver a signal. Closes with a
## cross-tier `snap` equality per CTUI-2."
##
## All four, and the second is the reason the file exists. `h.resize()` is a
## method call on an in-process harness: it changes two integers and repaints.
## `setWindowSize` changes the pty's window size in the KERNEL, which delivers
## SIGWINCH to the child, which wakes on `host/resize.nim`'s self-pipe and asks
## `ioctl(TIOCGWINSZ)` what happened. Not one step of that is observable from
## Tier 1, and `app/tests/test_resize_reflow.nim` says so about itself.
##
## ## HOW A SIGNAL IS PROVED TO HAVE BEEN DELIVERED
##
## `assertWindowResize` reads libvterm's window-op log, and that log is filled
## only by escape sequences the CHILD writes (`nim-libvterm`'s `decodeWindowOp`
## off `handleCsi`). `setWindowSize` records nothing in it. So the child, under
## the test-only `--reflow` flag, emits `CSI 8 ; rows ; cols t` carrying the
## numbers it read back from the ioctl, and `assertWindowResize(120, 40)` is
## then a statement about the whole path: the parent resized the pty, the
## kernel signalled, the handler fired, the ioctl returned 120x40, and the
## child said so. Asserting only that the screen changed would have been
## satisfied by a child that repainted on a timer.
##
## ## It does not skip
##
## A missing grammar archive, a child that will not compile, a child that never
## finishes a frame: every one FAILS by name with the recipe or the measurement
## that explains it. There is no `when false`, no early return on a missing
## prerequisite, and no `try/except` that turns a failure into a pass.
##
## ## No mocks
##
## The subject is a compiled binary in a real pty, parsed by a real terminal
## state machine. There is no `MockBackendService` here and no ViewModel at
## all.
##
## ## Templates, not procs, for anything that calls `check`
##
## `std/unittest`'s `check` assigns `testStatusIMPL`, which the `test` template
## injects into its own scope; inside a `proc` that symbol is invisible, `check`
## takes its `else` branch, and the case still prints `[OK]` while
## `programResult` goes to 1. CTUI-2 measured that happening in this very tree.

import std/[monotimes, strutils, times, unicode, unittest]

import isonim_tui
import term_assert

import ../../app/layout/profile
import ../../app/layout/project
import ../../app/views/shell
import ../../testing/dual_snap
import ../apps/app_shell as shellApp

# One line, deliberately: `ci/lib/run-nim-test-lane.sh` reads exactly this
# spelling as a RUNTIME assertion count, and inside a `const` block the
# declaration is invisible to it.
const ExpectedAssertions = 48

const
  Geometries = [(cols: 80, rows: 24), (cols: 120, rows: 40),
                (cols: 200, rows: 60)]
    ## The three CTUI-3 names, one per profile.

  FrameTimeoutMs = 20000
  ReflowTimeout = initDuration(seconds = 10)

var countedAssertions = 0

template ck(condition: untyped) =
  inc countedAssertions
  check condition

proc sliceCells(line: string; col, width: int): string =
  ## `width` cells of `line` starting at cell `col`.
  ##
  ## By RUNE rather than by byte: the shell paints box-drawing glyphs, which are
  ## three bytes and one cell each, so a byte slice would cut one in half and
  ## the comparison below would be about UTF-8 rather than about geometry.
  result = ""
  var at = 0
  for r in runes(line):
    if at >= col + width:
      break
    if at >= col:
      result.add $r
    at += max(1, displayWidth($r))

proc expectedRows(cols, rows: int): seq[string] =
  ## What the model says the screen is — the SAME `buildTree` the child runs,
  ## composited in process. Not a second hand-written fixture.
  shellApp.shellModel(cols, rows).shellRows(cols, rows)

proc spawnShell(cols, rows: int; reflow: bool): TuiTestSession =
  ## Compile (if stale) and spawn `apps/app_shell.nim` at this geometry.
  compileChildApp("app_shell")
  var args = @["--cols=" & $cols, "--rows=" & $rows]
  if reflow:
    args.add "--reflow"
  newTuiTest(appBinaryPath("app_shell"), args).width(cols).height(rows).spawn()

suite "CTUI-3 Tier 2: the shell's geometry on a real terminal":

  test "each pane's region reads back from a real screen at all three profiles":
    var checkedPanes = 0
    var checkedRows = 0
    var mismatches: seq[string] = @[]
    for g in Geometries:
      let body = bodyArea(g.cols, g.rows)
      let model = shellApp.shellModel(g.cols, g.rows)
      let proj = projectLayout(model.layout, body)
      ck proj.status == prOk
      ck coverageProblems(proj.regions, body).len == 0
      let want = expectedRows(g.cols, g.rows)
      ck want.len == g.rows

      var sess = spawnShell(g.cols, g.rows, reflow = false)
      try:
        waitForCompleteFrame(sess, g.cols, g.rows, FrameTimeoutMs)
        # THE POSITIVE CONTROL on every comparison below: a screen that parsed
        # to nothing satisfies a `strip()`-wise equality for free.
        ck sess.screenContents().strip().len > 0

        for region in proj.regions:
          inc checkedPanes
          let a = region.area
          # `regionText` — the API the milestone names — reads the rectangle
          # from libvterm's own grid, one row per line.
          let got = sess.regionText(a.row, a.col, a.width, a.height)
          let lines = got.split('\n')
          for i in 0 ..< a.height:
            inc checkedRows
            let expected = sliceCells(want[a.row + i], a.col, a.width)
            let actual = if i < lines.len: lines[i] else: ""
            if expected.strip(leading = false) != actual.strip(leading = false):
              mismatches.add(
                $g.cols & "x" & $g.rows & " " & $region.pane & " row " & $i &
                ":\n  model:    '" & expected & "'\n  terminal: '" & actual & "'")
        # The header and the status bar are not panes, and they are where a
        # one-row offset in the body would hide: if the body started a row too
        # low, every pane region would still match ITSELF.
        let headerGot = sess.regionText(0, 0, g.cols, 1).split('\n')[0]
        ck headerGot.strip(leading = false) ==
           want[0].strip(leading = false)
        let statusGot = sess.regionText(g.rows - 1, 0, g.cols, 1).split('\n')[0]
        ck statusGot.strip(leading = false) ==
           want[^1].strip(leading = false)
        sess.send("q")
        let status = sess.waitExit(initDuration(seconds = 5))
        ck status.isSome
        ck status.get() == 0
      finally:
        sess.terminate()
        sess.close()
    if mismatches.len > 0:
      checkpoint(mismatches[0 .. min(4, mismatches.high)].join("\n"))
    checkpoint("panes read back: " & $checkedPanes & ", rows compared: " &
               $checkedRows)
    # EXACT COUNTS, not "more than none" (Verification-Harness-Traps §4b). The
    # pane count is 3 + 4 + 5, and the row count is each pane's height summed —
    # both knowable, both asserted, so a loop that skipped a region reddens
    # here instead of leaving `mismatches.len == 0` true for free.
    ck checkedPanes == 3 + 4 + 5
    ck checkedRows == (17 + 17 + 5) + (30 + 30 + 30 + 8) +
                      (46 + 46 + 46 + 46 + 12)
    ck mismatches.len == 0

  test "a real SIGWINCH reflows the shell from Compact to Standard":
    # THE ONLY PLACE THE SIGNAL EXISTS. See this file's header for why the
    # child emits a window-op and what asserting on it proves.
    var sess = spawnShell(80, 24, reflow = true)
    try:
      waitForCompleteFrame(sess, 80, 24, FrameTimeoutMs)
      let before = expectedRows(80, 24)
      let bodyRow = bodyArea(80, 24).row
      let firstBody = sess.regionText(bodyRow, 0, 80, 1).split('\n')[0]
      checkpoint("body row at 80x24: '" & firstBody.strip() & "'")
      ck firstBody.strip(leading = false) ==
         before[bodyRow].strip(leading = false)
      ck firstBody.contains("CALL STACK")
      # The Compact profile's tab strip is on screen before the resize, which
      # is what makes its absence afterwards evidence of a profile change
      # rather than of a blank screen.
      ck sess.screenContents().contains("[Variables]")

      # THE KERNEL-DELIVERED RESIZE. No pump between this call and the wait
      # below, so the baseline `waitForRegionChange` captures is the screen as
      # it was BEFORE the child could respond.
      let resizedAt = getMonoTime()
      sess.setWindowSize(120, 40)
      let changed = sess.waitForRegionChange(bodyRow, 0, 120, 1, ReflowTimeout)
      let reflowMs = (getMonoTime() - resizedAt).inMicroseconds.float / 1000.0
      checkpoint("body row after SIGWINCH: '" & changed.strip() & "'")
      # WHAT THIS NUMBER IS AND IS NOT. It is the wall time from `setWindowSize`
      # to the parent OBSERVING the reflowed row, and it therefore contains the
      # parent's own read granularity: `waitForRegionChange` pumps the pty with
      # `drainOutput(30)`, so it cannot resolve anything below ~30 ms. CTUI-3's
      # gate cites CTUI-14's 20 ms reflow budget, and this measurement CANNOT
      # establish that — a 20 ms reflow and a 5 ms one are the same reading
      # here. So the number is reported and the assertion is a loose sanity
      # bound; the budget belongs to CTUI-14's benchmark harness, which measures
      # from inside the process. Claiming it from here would be a number that
      # did not survive its own error bars.
      echo "REFLOW 80x24 -> 120x40 observed after " &
           formatFloat(reflowMs, ffDecimal, 1) &
           " ms (parent-side, >= the 30 ms drainOutput granularity)"
      ck reflowMs < 5000.0

      # THE SIGNAL ITSELF, read from the terminal's side: the child's
      # acknowledgement carries the size IT read from `ioctl(TIOCGWINSZ)`.
      sess.assertWindowResize(120, 40)
      var sawResize = 0
      for op in sess.windowOps():
        if op.kind == woResize:
          inc sawResize
      checkpoint("window-op resize records: " & $sawResize)
      ck sawResize == 1

      waitForCompleteFrame(sess, 120, 40, FrameTimeoutMs)
      let after = expectedRows(120, 40)
      # THE WHOLE SCREEN, not one row. A reflow that repainted the body and
      # left a stale header would pass a single-row check.
      var compared = 0
      var stale: seq[string] = @[]
      for row in 0 ..< 40:
        inc compared
        let got = sess.regionText(row, 0, 120, 1).split('\n')[0]
        if got.strip(leading = false) != after[row].strip(leading = false):
          stale.add("row " & $row & ":\n  model:    '" & after[row] &
                    "'\n  terminal: '" & got & "'")
      if stale.len > 0:
        checkpoint(stale[0 .. min(4, stale.high)].join("\n"))
      ck compared == 40
      ck stale.len == 0
      # And the profile really did change: the Standard tree has three columns
      # and no tab strip at all.
      let screen = sess.screenContents()
      ck screen.contains("VARIABLES")
      ck not screen.contains("[Variables]")

      sess.send("q")
      let status = sess.waitExit(initDuration(seconds = 5))
      ck status.isSome
      ck status.get() == 0
    finally:
      sess.terminate()
      sess.close()

  test "cross-tier snapshot equality grounds the shell's Tier-1 goldens":
    # docs/tui-testing.md: "a new pane needs exactly one cross-tier equivalence
    # test. Not zero, and not one per assertion." This is the shell's, at both
    # of CTUI-2's geometries, through the SAME `buildTree` both tiers run.
    # ALL THREE geometries, not CTUI-2's two: CTUI-3's verification gate reads
    # "real-terminal geometry matches harness geometry cell-for-cell at all
    # three profiles", and the `regionText` case above compares TEXT with
    # trailing blanks stripped. Only this comparison is cell-for-cell — rune,
    # width, foreground, background, attribute set and underline style — so
    # leaving 200x60 out would have left the Ultra-wide profile's claim resting
    # on a whitespace-insensitive read.
    var checkedCases = 0
    for g in Geometries:
      let res = runDualSnap("app_shell", shellApp.buildTree, g.cols, g.rows)
      inc checkedCases
      if res.divergences.len > 0:
        checkpoint(report(res))
      ck res.divergences.len == 0
      # THE NON-VACUITY FLOOR, and it is the exact painted-cell count rather
      # than "more than none": a screen the two tiers agree is blank would
      # satisfy the equality above for free, and so would one that had quietly
      # lost half its rows. The number is knowable because the tree is a pure
      # function of the geometry.
      let canon = canonFromDir(res.tier1Dir)
      let painted = countCellsWhere(canon, proc(c: CanonCell): bool =
        c.rune != " " and c.rune.len > 0)
      let expected = expectedRows(g.cols, g.rows)
      var modelPainted = 0
      for line in expected:
        for r in runes(line):
          if $r != " ":
            inc modelPainted
      checkpoint("app_shell at " & $g.cols & "x" & $g.rows & ": " & $painted &
                 " painted cell(s) of " & $(canon.rows * canon.cols) &
                 ", model says " & $modelPainted)
      ck painted == modelPainted
      ck painted > 0
    ck checkedCases == Geometries.len

  test "assertion count":
    echo "CHECKS: " & $countedAssertions
    checkpoint("counted assertions: " & $countedAssertions)
    check countedAssertions == ExpectedAssertions
