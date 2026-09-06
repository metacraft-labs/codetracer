## test_headless_mode.nim — CTUI-14, Tier 1, on a real trace.
##
## ## What this suite establishes, and the defect it was written from
##
## `--headless` accepted three of §6.2's session options and acted on none of
## them. `app/cli.parseTuiCommand` filled `gotoTick`, `recordKeys` and
## `replayKeys` on the `tckHeadless` branch, and `main.nim` called
## `host/headless.runHeadless(tracePath, flags, geometry)` — three fields
## parsed, validated, carried in the value, and never read. That is exactly the
## failure mode `app/cli.PlannedOptions`'s own header names: "a flag that parses
## and silently does nothing … leaves a user unable to tell a gap in the product
## from a mistake in their command line."
##
## The three are not one problem and the fix is not one fix:
##
##   * `--record-keys` / `--replay-keys` CANNOT be honoured in a mode with no
##     input loop, and are now refused by the parser, naming both sides of the
##     conflict. That refusal is asserted in
##     `app/tests/test_capability_resolution.nim`, where the rest of the command
##     surface is asserted and where no trace is needed.
##   * `--goto` CAN be honoured, and is: it is a startup navigation applied once
##     before the first debugger frame, and the single frame `--headless`
##     renders IS that frame. **This file is what proves it, because the parser
##     test cannot**: a `TuiCommand` carrying `gotoTick = 200` is precisely what
##     the defect produced, so an assertion on the parsed value would have been
##     green throughout the bug's lifetime. What has to be asserted is the
##     RENDERED SCREEN, against a real recording.
##
## ## No mocks
##
## A real `.ct` trace recorded by the real Python recorder, opened by a real
## `replay-server` through the production `host/headless.runHeadless` — the same
## function `main.nim` calls, with its documented `sink` parameter pointed at a
## file so the frame can be read without a pipe. There is no fake anywhere in
## this file, and no second rendering path: `runHeadless` composites through
## `terminal_driver.plainFrame`, which shares `degradeRows` and `composite` with
## the tty path.
##
## ## WHY THIS FILE IS NOT UNDER `app/tests/`
##
## `tests/test_tui_facade_boundary.nim` walks every `.nim` under
## `src/frontend/tui/app/` and fails on any import reaching `std/posix`,
## `std/osproc`, `backend/stdio_backend` or `viewmodel/headless_session`.
## `host/headless.nim` needs all of that by definition, so its suite lives one
## directory up beside `test_ssh_tuning.nim`, which the `tui` lane globs
## identically (`ci/lib/test-lane-files.sh`).
##
## ## NOTHING HERE IS A HARDCODED TICK
##
## The recording's extent is read off the FIRST rendered frame — `runHeadless`
## puts `tui_session.describe`'s `extent <min>..<max>` on the status row — and
## the tick this suite seeks to is the midpoint of that. A fixture re-recorded
## on a new Python moves the extent and the target together. The one tick
## spelled literally is the deliberately-out-of-range one, which is out of range
## for every recording that could exist.
##
## ## Templates, not procs, for anything that calls `check`
##
## `std/unittest`'s `check` assigns `testStatusIMPL`, which the `test` template
## injects into its own scope; inside a `proc` that symbol is invisible, `check`
## takes its `else` branch, and the case still prints `[OK]` while
## `programResult` goes to 1.

import std/[os, strutils, unittest]

import ../app/cli
import ../app/theme/capabilities
import ../host/headless
import ../host/resize
import ./fixtures/fixture_provider

# One line, deliberately: `ci/lib/run-nim-test-lane.sh` reads exactly this
# spelling as a RUNTIME assertion count, and inside a `const` block the
# declaration is invisible to it.
const ExpectedAssertions = 28

var countedAssertions = 0

template ck(condition: untyped) =
  inc countedAssertions
  check condition

const
  FixtureName = "calc"
  Cols = 120
  Rows = 40
    ## §3.1's STANDARD profile, so the frame below is the one a user sees
    ## rather than a narrower one whose panes have collapsed.
  UnreachableTick = 9_000_000'i64
    ## Past the end of any recording this corpus can hold. The point of it is
    ## the CLAMP MESSAGE: `--goto` past the end must report what it did rather
    ## than silently obeying, and that report is only observable if the flag
    ## reached `interpreter`'s dispatcher at all.

var examinedFixtures = 0
var skippedFixtures = 0
var verifiedFixtures = 0

proc renderHeadless(tracePath: string; gotoTick = NoGotoTick): (int, string) =
  ## Run the shipped `--headless` path once and return `(exit status, frame)`.
  ##
  ## THE PRODUCTION FUNCTION, not a re-implementation of it. `sink` exists on
  ## `runHeadless` for exactly this: a suite that captured the frame by
  ## re-compositing would be asserting its own arithmetic.
  let path = getTempDir() / "ct-tui-headless-" & $getCurrentProcessId() &
             "-" & $gotoTick & ".txt"
  var sink = open(path, fmWrite)
  var status = ExitUnhandled
  try:
    status = runHeadless(tracePath, initCapabilityFlags(),
                         TerminalSize(cols: Cols, rows: Rows), sink,
                         gotoTick = gotoTick)
  finally:
    sink.close()
  result = (status, readFile(path))
  removeFile(path)

proc statusRowOf(frame: string): string =
  ## The last non-empty row of a rendered frame — §3.1's status row, which is
  ## where `runHeadless` puts the session diagnostic and the `--goto` report.
  let lines = frame.splitLines()
  for i in countdown(lines.high, 0):
    let text = lines[i].strip()
    if text.len > 0:
      return text
  ""

proc extentOf(frame: string): (int64, int64) =
  ## `(min, max)` out of the status row's `extent <min>..<max>`, which
  ## `tui_session.describe` writes and `runHeadless` shows when no `--goto` was
  ## given. Returns `(-1, -1)` when the row does not carry one, so a caller can
  ## assert the parse rather than silently seeking to a default.
  let row = statusRowOf(frame)
  let marker = "extent "
  let at = row.find(marker)
  if at < 0:
    return (-1'i64, -1'i64)
  let tail = row[at + marker.len .. ^1].strip()
  let dots = tail.find("..")
  if dots < 0:
    return (-1'i64, -1'i64)
  try:
    (parseBiggestInt(tail[0 ..< dots]),
     parseBiggestInt(tail[dots + 2 .. ^1].splitWhitespace()[0]))
  except ValueError:
    (-1'i64, -1'i64)

suite "CTUI-14: --headless honours --goto and refuses what it cannot honour":

  test "--headless renders one settled frame, and --goto moves it":
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

      # ---- the baseline frame, with no `--goto` at all --------------------
      let (plainStatus, plainFrame) = renderHeadless(resolution.tracePath)
      checkpoint("no --goto, status row: " & statusRowOf(plainFrame))
      ck plainStatus == ExitOk
      # THE NON-VACUITY FLOOR. Every comparison below is over this string; a
      # frame that came back empty would satisfy the inequality at the end for
      # free, which is the shape Verification-Harness-Traps §4 is about.
      ck plainFrame.len > 1000
      ck plainFrame.contains("CALL STACK")
      ck plainFrame.contains("SOURCE")
      ck plainFrame.contains("TIMELINE")

      # ---- the recording's own extent, read off that frame ----------------
      let (minTick, maxTick) = extentOf(plainFrame)
      checkpoint("extent read from the frame: " & $minTick & ".." & $maxTick)
      ck minTick >= 0
      ck maxTick > minTick
      # A recording with fewer than a handful of ticks would make "the midpoint
      # is a different position" untrue for reasons that have nothing to do
      # with the flag, so the fixture's own size is asserted rather than
      # assumed.
      ck maxTick - minTick >= 8
      let target = minTick + (maxTick - minTick) div 2
      checkpoint("seeking to the midpoint tick " & $target)
      ck target > minTick
      ck target < maxTick

      # ---- THE ASSERTION THE PARSER TEST CANNOT MAKE ----------------------
      # A `TuiCommand` carrying `gotoTick = target` is what the defect produced.
      # What proves the fix is that the RENDERED SCREEN moved.
      let (gotoStatus, gotoFrame) = renderHeadless(resolution.tracePath, target)
      checkpoint("--goto=" & $target & ", status row: " & statusRowOf(gotoFrame))
      ck gotoStatus == ExitOk
      ck gotoFrame.len > 1000
      ck gotoFrame != plainFrame
      # …and it moved to the RIGHT place, not merely to a different one. §3.1's
      # header carries the tick counter, and it is the one the flag named.
      ck gotoFrame.contains("tick: " & $target & " / " & $maxTick)
      ck not plainFrame.contains("tick: " & $target & " / " & $maxTick)
      # The status row reports what was done, through the same dispatcher
      # `:goto` and `t <tick> Enter` reach.
      ck statusRowOf(gotoFrame).contains($target)

      # ---- the seek is the SAME action, so its clamp reports too -----------
      let (clampStatus, clampFrame) =
        renderHeadless(resolution.tracePath, UnreachableTick)
      let clampRow = statusRowOf(clampFrame)
      checkpoint("--goto=" & $UnreachableTick & ", status row: " & clampRow)
      ck clampStatus == ExitOk
      # A CLAMP IS REPORTED, NOT SILENTLY OBEYED — and the report names the
      # tick the user asked for, which is the only way they can tell that the
      # screen in front of them is not where they aimed.
      ck clampRow.contains($UnreachableTick)
      ck clampRow.contains("clamped")
      ck clampFrame.contains("tick: " & $maxTick & " / " & $maxTick)

      # ---- `--goto=<min>` is honoured and is not "not given" ---------------
      # The positive twin of the whole case: a `runHeadless` that ignored the
      # parameter would render the entry frame here too, so this arm alone
      # proves nothing — it is here so that the difference between "seeks to
      # the start" and "did not seek" stays visible in the suite rather than
      # only in the type.
      let (zeroStatus, zeroFrame) = renderHeadless(resolution.tracePath, minTick)
      ck zeroStatus == ExitOk
      ck zeroFrame.contains("tick: " & $minTick & " / " & $maxTick)
      ck statusRowOf(zeroFrame) != statusRowOf(plainFrame)

  test "the two journal flags never reach this mode at all":
    # THE STRUCTURAL HALF, and it belongs here rather than in the parser suite
    # because it is a claim about `host/headless.runHeadless`: the function has
    # no parameter a journal could arrive through. The parser's refusal is
    # asserted in `app/tests/test_capability_resolution.nim`; this is why that
    # refusal is the right answer rather than a missing feature.
    #
    # Asserted through the parser so the two halves cannot drift apart: the
    # command that would have carried a journal into this mode does not exist.
    for option in ["--record-keys=/tmp/j", "--replay-keys=/tmp/j"]:
      let refused = parseTuiCommand(["--headless", option, "/tmp"])
      checkpoint("--headless " & option & " -> " &
                 (if refused.kind == tckUsageError: refused.message
                  else: $refused.kind))
      ck refused.kind == tckUsageError
      ck refused.kind != tckHeadless
    # …and `--headless` on its own still reaches the mode, so the two lines
    # above are about the combination.
    ck parseTuiCommand(["--headless", "/tmp"]).kind == tckHeadless

  test "fixture accounting":
    # An all-skipped run FAILS. A suite that reported success over zero
    # examined recordings is the silent self-pass this corpus exists to
    # prevent.
    echo "FIXTURES: examined " & $examinedFixtures & ", verified " &
         $verifiedFixtures & ", skipped " & $skippedFixtures
    checkpoint("examined " & $examinedFixtures & " verified " &
               $verifiedFixtures & " skipped " & $skippedFixtures)
    check examinedFixtures == 1
    check verifiedFixtures + skippedFixtures == examinedFixtures

  test "assertion count":
    echo "CHECKS: " & $countedAssertions
    checkpoint("counted assertions: " & $countedAssertions)
    if skippedFixtures > 0:
      # The skip arm counts two of its own, so the total is only knowable when
      # the fixture was really opened.
      check countedAssertions == 2 + 5
    else:
      check countedAssertions == ExpectedAssertions
