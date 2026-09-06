## test_timeline_scrubber_quantization.nim — CTUI-8, Tier 1, PURE.
##
## ## What this suite establishes
##
## CTUI-8: "for widths 20..200 and tick counts spanning several orders of
## magnitude, asserts the needle is monotonic, never leaves the track, lands on
## column 0 at tick 0 and on the last column at the final tick. Property-style
## over the pure mapping, because off-by-one at the ends is the whole defect
## class." And its verification gate: "needle mapping correct at every tested
## width."
##
## All of it, over `app/views/timeline_bar.columnForTick` — 181 widths x 11 tick
## counts, and no cell is painted to check any of it. That is the point of the
## mapping being a pure function: a rendering test could only ever sample the
## widths a terminal happens to have.
##
## Four properties, and the two ENDS are separate cases rather than corollaries
## of monotonicity. A mapping that put the needle on column 1 at tick 0 and on
## `trackWidth - 2` at the last tick is perfectly monotonic and perfectly
## in-range, and it is exactly the defect CTUI-8 names.
##
##   1. THE ENDS: column 0 at `minTick`, `trackWidth - 1` at `maxTick`.
##   2. MONOTONIC AND IN RANGE, over an ascending sweep of ticks.
##   3. SURJECTIVE: every track cell is reachable, whenever the recording has at
##      least as many ticks as the track has cells. A mapping that crowded the
##      needle into the left half would satisfy 1 and 2 and fail this.
##   4. A CLICK LANDS WHERE IT WAS AIMED:
##      `columnForTick(tickForColumn(c)) == c` for every cell. That is §4.4's
##      mouse contract as arithmetic, and it is the half of the inverse that can
##      hold — the other half cannot, and is not claimed.
##
## ## THE SWEEP IS AGGREGATED, AND THE AGGREGATE IS AN EXACT COUNT
##
## The sweep makes millions of comparisons; `ExpectedAssertions` counts the
## `ck`s, so a `ck` inside the innermost loop would make that number a function
## of the sweep's size and useless as a guard. Instead each loop counts its own
## violations AND its own comparisons, and asserts BOTH: zero violations, and
## the exact number of comparisons the loop parameters imply. A loop that
## `break`ed early would leave the second number short and redden the case —
## which is `docs/tui-testing.md`'s rule 4 ("if a scan's size is knowable,
## assert the SIZE") applied to a property sweep.
##
## ## It stays under `app/tests/`, and that is the point
##
## `tests/test_tui_facade_boundary.nim` walks every `.nim` under `app/`,
## including this file, so a suite placed here cannot import `host/`,
## `headless_session`, `std/posix` or `std/osproc` without reddening that guard.
## This one needs none of them: its subject is four `func`s over integers.
##
## ## No mocks
##
## There is nothing to mock. The subject is a pure function and the inputs are
## integers.
##
## ## Templates, not procs, for anything that calls `check`

import std/[monotimes, strutils, times, unittest]

import headless_app/layout_model

import ../views/shell
import ../views/timeline_bar

# One line, deliberately: `ci/lib/run-nim-test-lane.sh` reads exactly this
# spelling as a RUNTIME assertion count, and inside a `const` block the
# declaration is invisible to it.
const ExpectedAssertions = 86

var countedAssertions = 0

template ck(condition: untyped) =
  inc countedAssertions
  check condition

const
  MinWidth = 20
  MaxWidth = 200
    ## CTUI-8's range, verbatim. These are PANE widths; the track is two cells
    ## narrower, because `[` and `]` are markers and not ticks.
  WidthCount = MaxWidth - MinWidth + 1

  TickCounts: array[11, uint64] = [
    2'u64, 3'u64, 10'u64, 172'u64, 1315'u64, 3897'u64, 10_000'u64,
    100_000'u64, 1_000_000'u64, 100_000_000'u64, 4_000_000_000'u64]
    ## Eleven counts over nine orders of magnitude. Four are REAL: 172, 1315 and
    ## 3897 are `calc`, `noir_space_ship` and `wide_state`'s recorded tick
    ## counts (`maxRRTicks + 1`, measured 2026-09-06), and 100_000 is the number
    ## CTUI-8's verification gate names. 2 is the smallest recording that has
    ## two distinct ends, and it is the one an off-by-one is likeliest to break.

  SamplesPerSweep = 512
    ## Ticks sampled per (width, count) pair for the monotonicity sweep, on top
    ## of every exact cell-boundary preimage. A recording of four billion ticks
    ## cannot be walked; the boundaries are where a monotonicity break would be,
    ## and the even samples are the arm that does not assume that.

  SeekBenchTicks = 100_000'u64
    ## CTUI-8's gate: "Seek across 100,000 ticks < 25 ms."
  SeekBenchWidth = 200
  SeekBenchRepeats = 40
  SeekGateMs = 25.0

proc trackFor(width: int): int = trackWidthFor(width)

# ---------------------------------------------------------------------------

suite "CTUI-8: the scrubber's tick-to-column mapping":

  test "the needle lands on column 0 at the first tick and on the last column at the last":
    # CTUI-8's whole defect class, at every width it names, for every tick count
    # it names. Both ends, both directions.
    var pairs = 0
    var firstWrong = 0
    var lastWrong = 0
    var firstReport = ""
    var lastReport = ""
    for width in MinWidth .. MaxWidth:
      let track = trackFor(width)
      for count in TickCounts:
        inc pairs
        let maxTick = count - 1
        let atStart = columnForTick(0'u64, 0'u64, maxTick, track)
        let atEnd = columnForTick(maxTick, 0'u64, maxTick, track)
        if atStart != 0:
          inc firstWrong
          if firstReport.len == 0:
            firstReport = "width " & $width & " count " & $count &
              ": tick 0 -> column " & $atStart
        if atEnd != track - 1:
          inc lastWrong
          if lastReport.len == 0:
            lastReport = "width " & $width & " count " & $count & ": tick " &
              $maxTick & " -> column " & $atEnd & " of track " & $track
    if firstReport.len > 0: checkpoint(firstReport)
    if lastReport.len > 0: checkpoint(lastReport)
    echo "CTUI-8 QUANTIZATION ENDS: ", pairs, " (width, tick-count) pairs, ",
         firstWrong, " wrong at the start, ", lastWrong, " wrong at the end"
    # THE COUNT IS ASSERTED TOO: a loop that skipped a width would report zero
    # violations for free.
    ck pairs == WidthCount * TickCounts.len
    ck firstWrong == 0
    ck lastWrong == 0

  test "the needle is monotonic and never leaves the track":
    # An ascending walk of ticks must produce a non-decreasing walk of columns,
    # every one of them inside `[0, trackWidth)`. The walk includes every EXACT
    # cell-boundary preimage — `tickForColumn(c)` and its two neighbours — which
    # is where a rounding error lives, plus `SamplesPerSweep` even samples,
    # which is the arm that does not assume where the errors are.
    var comparisons = 0
    var expectedComparisons = 0
    var monotonicViolations = 0
    var outOfTrack = 0
    var report = ""
    for width in MinWidth .. MaxWidth:
      let track = trackFor(width)
      for count in TickCounts:
        let maxTick = count - 1
        var ticks: seq[uint64] = @[]
        for i in 0 ..< SamplesPerSweep:
          ticks.add uint64((float(maxTick) * float(i)) /
                           float(SamplesPerSweep - 1) + 0.5)
        for c in 0 ..< track:
          let t = tickForColumn(c, 0'u64, maxTick, track)
          ticks.add t
          if t > 0: ticks.add t - 1
          if t < maxTick: ticks.add t + 1
        # Sorted so the walk is ascending by construction; duplicates are kept,
        # because two equal ticks must map to two equal columns and a
        # deduplicating sweep would never test that.
        for i in 1 ..< ticks.len:
          var j = i
          while j > 0 and ticks[j - 1] > ticks[j]:
            swap(ticks[j - 1], ticks[j])
            dec j
        var previous = -1
        for t in ticks:
          let column = columnForTick(t, 0'u64, maxTick, track)
          inc comparisons
          if column < 0 or column >= track:
            inc outOfTrack
            if report.len == 0:
              report = "width " & $width & " count " & $count & " tick " & $t &
                " -> column " & $column & " outside track " & $track
          if column < previous:
            inc monotonicViolations
            if report.len == 0:
              report = "width " & $width & " count " & $count & " tick " & $t &
                ": column " & $column & " after " & $previous
          previous = column
        expectedComparisons += ticks.len
    if report.len > 0: checkpoint(report)
    echo "CTUI-8 QUANTIZATION MONOTONICITY: ", comparisons,
         " tick->column mappings over ", WidthCount, " widths x ",
         TickCounts.len, " tick counts, ", monotonicViolations,
         " non-monotonic, ", outOfTrack, " off the track"
    ck comparisons == expectedComparisons
    ck comparisons > 0
    ck monotonicViolations == 0
    ck outOfTrack == 0

  test "every track cell is reachable when the recording is long enough":
    # THE PROPERTY THAT CATCHES A COMPRESSED MAPPING. A needle that never
    # reaches the right-hand third of the bar is monotonic, in range and right
    # at both ends.
    var pairs = 0
    var unreachable = 0
    var report = ""
    for width in MinWidth .. MaxWidth:
      let track = trackFor(width)
      for count in TickCounts:
        if count < uint64(track):
          # A 10-tick recording cannot fill a 100-cell track and is not asked to.
          continue
        inc pairs
        let maxTick = count - 1
        var seen = newSeq[bool](track)
        for c in 0 ..< track:
          let column = columnForTick(tickForColumn(c, 0'u64, maxTick, track),
                                     0'u64, maxTick, track)
          if column >= 0 and column < track:
            seen[column] = true
        for c in 0 ..< track:
          if not seen[c]:
            inc unreachable
            if report.len == 0:
              report = "width " & $width & " count " & $count & ": column " &
                $c & " of " & $track & " is unreachable"
    if report.len > 0: checkpoint(report)
    echo "CTUI-8 QUANTIZATION SURJECTIVITY: ", pairs,
         " (width, tick-count) pairs long enough to fill their track, ",
         unreachable, " unreachable cell(s)"
    ck pairs > 0
    ck unreachable == 0

  test "a click lands on the cell it was aimed at":
    # §4.4's mouse contract as arithmetic. The property has TWO regimes and
    # conflating them would be a false claim in one of them:
    #
    #   * a recording with AT LEAST as many ticks as the track has cells can
    #     address every cell, so `columnForTick(tickForColumn(c)) == c` exactly.
    #     This is every real recording — `calc` is the smallest in CTUI-1's
    #     corpus at 172 ticks against a 78-cell track at 80 columns;
    #   * a recording SHORTER than the track cannot. A two-tick recording on an
    #     18-cell track has exactly two reachable cells, so a click on cell 1
    #     resolves to tick 0, which is drawn on cell 0. What must hold there is
    #     IDEMPOTENCE — clicking the cell the first click landed on stays put —
    #     and MONOTONICITY of `tickForColumn`, which together mean a click lands
    #     on the nearest tick that exists rather than anywhere.
    #
    # The other direction — tick -> column -> tick — cannot hold in either
    # regime and is not claimed: a 78-cell track cannot address 1314 ticks.
    var exactTrips = 0
    var expectedExact = 0
    var shortTrips = 0
    var expectedShort = 0
    var misses = 0
    var report = ""
    for width in MinWidth .. MaxWidth:
      let track = trackFor(width)
      for count in TickCounts:
        let maxTick = count - 1
        let addressable = count >= uint64(track)
        if addressable: expectedExact += track else: expectedShort += track
        var previousTick = 0'u64
        for c in 0 ..< track:
          let tick = tickForColumn(c, 0'u64, maxTick, track)
          let back = columnForTick(tick, 0'u64, maxTick, track)
          if addressable:
            inc exactTrips
            if back != c:
              inc misses
              if report.len == 0:
                report = "addressable: width " & $width & " count " & $count &
                  ": column " & $c & " -> tick " & $tick & " -> column " & $back
          else:
            inc shortTrips
            let settled = columnForTick(
              tickForColumn(back, 0'u64, maxTick, track), 0'u64, maxTick, track)
            if settled != back:
              inc misses
              if report.len == 0:
                report = "short: width " & $width & " count " & $count &
                  ": column " & $c & " -> " & $back & " -> " & $settled
          if c > 0 and tick < previousTick:
            inc misses
            if report.len == 0:
              report = "width " & $width & " count " & $count & ": column " &
                $c & " -> tick " & $tick & " after " & $previousTick
          previousTick = tick
          if tick > maxTick:
            inc misses
            if report.len == 0:
              report = "width " & $width & " count " & $count & ": column " &
                $c & " -> tick " & $tick & " beyond " & $maxTick
    if report.len > 0: checkpoint(report)
    echo "CTUI-8 QUANTIZATION ROUND TRIP: ", exactTrips,
         " exact column->tick->column trips on recordings long enough to " &
         "address every cell, ", shortTrips, " idempotence trips on shorter " &
         "ones, ", misses, " missed"
    ck exactTrips == expectedExact
    ck shortTrips == expectedShort
    ck exactTrips > 0
    ck shortTrips > 0
    ck misses == 0

  test "a tick outside the recording is clamped onto the track, not off it":
    # The needle for a tick beyond the end is the LAST cell, and the needle for
    # a recording that has not started is the first. Neither is -1 and neither
    # is `trackWidth`, which are the two values that would silently paint
    # nothing and paint over `]` respectively.
    let track = trackFor(80)
    ck track == 78
    ck columnForTick(5000'u64, 0'u64, 1314'u64, track) == track - 1
    ck columnForTick(1314'u64, 0'u64, 1314'u64, track) == track - 1
    ck columnForTick(0'u64, 0'u64, 1314'u64, track) == 0
    # A non-zero MINIMUM: the bar's left end is the recording's first tick, not
    # tick 0. `wide_state`'s events start at 2686 and a pane bounded to them
    # must put the first of them on column 0.
    ck columnForTick(2686'u64, 2686'u64, 3896'u64, track) == 0
    ck columnForTick(3896'u64, 2686'u64, 3896'u64, track) == track - 1
    ck columnForTick(2000'u64, 2686'u64, 3896'u64, track) == 0
    ck tickForColumn(0, 2686'u64, 3896'u64, track) == 2686'u64
    ck tickForColumn(track - 1, 2686'u64, 3896'u64, track) == 3896'u64
    ck tickForColumn(-4, 2686'u64, 3896'u64, track) == 2686'u64
    ck tickForColumn(track + 9, 2686'u64, 3896'u64, track) == 3896'u64

  test "a geometry with no track answers rather than paints":
    # Every degenerate shape a resize can produce. `-1` for "there is no track",
    # `0` for "the track is one cell and everything is on it".
    ck trackWidthFor(2) == 0
    ck trackWidthFor(3) == 1
    ck trackWidthFor(0) == 0
    ck trackWidthFor(-7) == 0
    ck columnForTick(5'u64, 0'u64, 10'u64, 0) == -1
    ck columnForTick(5'u64, 0'u64, 10'u64, -3) == -1
    # A ONE-CELL TRACK: both ends land on the only cell there is.
    ck columnForTick(0'u64, 0'u64, 10'u64, 1) == 0
    ck columnForTick(10'u64, 0'u64, 10'u64, 1) == 0
    # A recording with ONE tick: `maxTick <= minTick`, so every tick is column 0
    # and `tickForColumn` cannot invent a range that is not there.
    ck columnForTick(0'u64, 7'u64, 7'u64, 40) == 0
    ck tickForColumn(20, 7'u64, 7'u64, 40) == 7'u64

  test "a span covers at least one cell however short it is":
    # A three-tick call in a 1314-tick recording is still a call. A span
    # arithmetic that produced an empty range would make the busiest part of a
    # recording the emptiest part of the bar.
    let track = trackFor(80)
    let shortSpan = TimelineSpan(startTick: 22'u64, endTick: 24'u64, depth: 3,
                                 name: "calculate_remaining_shield_pct")
    let cells = trackColumnsForSpan(shortSpan, 0'u64, 1314'u64, track)
    checkpoint("short span cells: " & $cells)
    ck cells.len >= 1
    ck cells[0] == columnForTick(22'u64, 0'u64, 1314'u64, track)
    ck cells[^1] == columnForTick(24'u64, 0'u64, 1314'u64, track)
    # …and a span covering the whole recording covers the whole track.
    let wholeSpan = TimelineSpan(startTick: 0'u64, endTick: 1314'u64, depth: 0,
                                 name: "main")
    ck trackColumnsForSpan(wholeSpan, 0'u64, 1314'u64, track).len == track
    # A span whose ends arrive reversed is still the same cells: the caller is
    # a `CallLine` walk and a malformed calltrace must not produce a hole.
    let reversed = TimelineSpan(startTick: 24'u64, endTick: 22'u64, depth: 3,
                                name: "reversed")
    ck trackColumnsForSpan(reversed, 0'u64, 1314'u64, track) == cells

  test "seeking across 100,000 ticks is under the gate":
    # CTUI-8's verification gate. What is measured is the whole IN-PROCESS seek:
    # the quantization, the model, the paint, and reading the needle back off
    # the painted screen — everything a user waits for after a seek except the
    # engine, which `tests/test_call_boundary_seeking.nim` measures against a
    # real `replay-server`.
    #
    # The sweep below visits 100,000 DISTINCT ticks per repeat, so "it was fast"
    # cannot mean "it did nothing": the accumulated column sum is asserted
    # against the value the mapping's own ends imply.
    let maxTick = SeekBenchTicks - 1
    let track = trackFor(SeekBenchWidth)
    var best = 1.0e9
    var total = 0.0
    var lastColumns = 0
    for repeat in 0 ..< SeekBenchRepeats:
      let started = getMonoTime()
      var columns = 0
      var tick = 0'u64
      while tick <= maxTick:
        columns += columnForTick(tick, 0'u64, maxTick, track)
        tick += 1
      let elapsed = (getMonoTime() - started).inNanoseconds.float / 1.0e6
      total += elapsed
      if elapsed < best: best = elapsed
      lastColumns = columns
    let sweepMean = total / float(SeekBenchRepeats)

    # …and ONE seek, end to end through the pane, SPLIT IN TWO for CTUI-7's
    # reason: a regression in the mapping and a regression in the painting are
    # different defects and the log should name which one moved.
    var needleBest = 1.0e9
    var needleTotal = 0.0
    var needled = 0
    for repeat in 0 ..< SeekBenchRepeats:
      let tick = uint64((repeat * 7919) mod int(SeekBenchTicks))
      let started = getMonoTime()
      let model = initTimelineBarModel(
        minTick = 0'u64, maxTick = maxTick, currentTick = tick,
        boundsKnown = true)
      let column = model.needleTrackColumn(track)
      let elapsed = (getMonoTime() - started).inNanoseconds.float / 1.0e6
      needleTotal += elapsed
      if elapsed < needleBest: needleBest = elapsed
      if column == columnForTick(tick, 0'u64, maxTick, track):
        inc needled
    let needleMean = needleTotal / float(SeekBenchRepeats)

    var paintBest = 1.0e9
    var paintTotal = 0.0
    var painted = 0
    for repeat in 0 ..< SeekBenchRepeats:
      let tick = uint64((repeat * 7919) mod int(SeekBenchTicks))
      let started = getMonoTime()
      let model = initTimelineBarModel(
        minTick = 0'u64, maxTick = maxTick, currentTick = tick,
        boundsKnown = true)
      let screen = timelineBarScreen(model, SeekBenchWidth, TimelineBarRows)
      let elapsed = (getMonoTime() - started).inNanoseconds.float / 1.0e6
      paintTotal += elapsed
      if elapsed < paintBest: paintBest = elapsed
      if screen.needleColumn ==
         columnForTick(tick, 0'u64, maxTick, track):
        inc painted
    let paintMean = paintTotal / float(SeekBenchRepeats)

    echo "CTUI-8 SEEK LATENCY: full 100000-tick sweep best ",
         best.formatFloat(ffDecimal, 3), " ms (mean ",
         sweepMean.formatFloat(ffDecimal, 3),
         "); one seek needle-only best ", needleBest.formatFloat(ffDecimal, 4),
         " ms (mean ", needleMean.formatFloat(ffDecimal, 4),
         "); one seek + repaint best ", paintBest.formatFloat(ffDecimal, 4),
         " ms (mean ", paintMean.formatFloat(ffDecimal, 4), ") at width ",
         SeekBenchWidth, ", gate < ", SeekGateMs.formatFloat(ffDecimal, 0)
    # THE WORK REALLY HAPPENED: every one of the 100,000 ticks contributed a
    # column, and the total is the one the mapping's ends imply — the first tick
    # is 0, the last is `track - 1`, and 100,000 ticks over 198 cells put
    # 100000/198 of them on each. Asserted as bounds rather than as an exact sum,
    # because the exact sum is what the code under test computes and asserting it
    # against itself would be the self-comparison this campaign keeps finding.
    ck lastColumns > 0
    ck lastColumns >= int(SeekBenchTicks) * (track - 1) div 2 - int(SeekBenchTicks)
    ck lastColumns <= int(SeekBenchTicks) * (track - 1) div 2 + int(SeekBenchTicks)
    ck needled == SeekBenchRepeats
    ck painted == SeekBenchRepeats
    ck best < SeekGateMs
    ck needleBest < SeekGateMs
    ck paintBest < SeekGateMs

  test "the shell paints the scrubber and the log into the timeline rectangle":
    # CTUI-3 gives the `timeline` pane a rectangle in the Standard and
    # Ultra-wide profiles and a TAB of the `state` stack in the Compact one.
    # §3.3.5 is ONE pane holding a scrubber AND an event log, so the rectangle
    # is split: `TimelineBarRows` at the top, the log below.
    #
    # Every changed row is asserted to be INSIDE the rectangle and none outside,
    # which is what makes this a statement about the shell rather than about the
    # panes — the panes' own screens are asserted above and at Tier 2.
    const Width = 120
    const Height = 40
    var plain = newShellModel(Width, Height)
    let before = shellRows(plain, Width, Height)
    ck plain.profile == lpStandard
    ck plain.timeline.isEmpty
    ck not plain.tracepoints.open

    var filled = plain
    filled.timeline = initTimelineBarModel(
      minTick = 0'u64, maxTick = 1314'u64, currentTick = 320'u64,
      boundsKnown = true,
      spans = @[TimelineSpan(startTick: 0'u64, endTick: 8'u64, depth: 0,
                             name: "main")],
      marks = @[TimelineMark(tick: 71'u64, kind: tmkTracepoint,
                             label: "log(damage)")])
    let after = shellScreen(filled, Width, Height)
    ck after.rows.len == Height

    var timelineArea = CellArea()
    var found = false
    for region in after.projection.regions:
      if region.pane == paneTimeline:
        timelineArea = region.area
        found = true
    ck found
    ck timelineArea.height > TimelineBarRows

    var changedInside = 0
    var changedOutside = 0
    var firstOutside = ""
    for row in 0 ..< Height:
      if after.rows[row] == before[row]:
        continue
      if row >= timelineArea.row and
         row < timelineArea.row + timelineArea.height:
        inc changedInside
      else:
        inc changedOutside
        if firstOutside.len == 0:
          firstOutside = "row " & $row & ":\n  was '" & before[row] &
            "'\n  now '" & after.rows[row] & "'"
    if firstOutside.len > 0: checkpoint(firstOutside)
    echo "CTUI-8 SHELL: timeline rectangle ", timelineArea, "; ", changedInside,
         " row(s) changed inside it, ", changedOutside, " outside"
    ck changedOutside == 0
    # THE TWO ROWS THE BAR OWNS really changed — a shell that painted nothing
    # would also change nothing outside.
    ck changedInside >= TimelineBarRows
    ck after.rows[timelineArea.row].contains(TimelineTitle)
    ck after.rows[timelineArea.row + 1].contains(BoundsOpenGlyph)
    ck after.rows[timelineArea.row + 1].contains(NeedleGlyph)
    ck after.rows[timelineArea.row + 1].contains(MarkGlyph)
    ck after.rows[timelineArea.row + 1].contains(SpanGlyph)
    # …and the needle is at the column the pure mapping says, on the SHELL's
    # own row, at the shell's own rectangle offset.
    let shellTrack = trackWidthFor(timelineArea.width)
    let needleCell = columnForTick(320'u64, 0'u64, 1314'u64, shellTrack)
    ck cellSlice(after.rows[timelineArea.row + 1],
                 timelineArea.col + 1 + needleCell,
                 timelineArea.col + 2 + needleCell) == NeedleGlyph

    # ---- THE EVENT LOG TAKES THE REST OF THE RECTANGLE -------------------
    var withLog = filled
    withLog.eventLog = initEventLogModel(
      pages = proc(offset, limit: int): EventPage =
        EventPage(rows: @[EventRow(index: 0, tick: 7'u64, file: "main.nr",
                                   line: 13, content: "Positive Test Case",
                                   category: ecOutput, kindId: KindWrite)],
                  atEnd: true),
      pageSize = 16)
    withLog.eventLog.ensureWindow(0, 16)
    let logged = shellScreen(withLog, Width, Height)
    ck logged.rows[timelineArea.row + TimelineBarRows].contains(EventLogTitle)
    ck logged.rows[timelineArea.row + TimelineBarRows + 1].contains(
      "Positive Test Case")
    # The scrubber's own two rows are untouched by the log below it.
    ck logged.rows[timelineArea.row] == after.rows[timelineArea.row]
    ck logged.rows[timelineArea.row + 1] == after.rows[timelineArea.row + 1]

    # ---- THE COMPACT PROFILE STACKS IT BEHIND CTUI-3'S TAB STRIP ---------
    # `paneTimeline` is a tab of the `state` stack at 80x24, so the rectangle
    # only exists when that tab is active — which is `LayoutNode.activate`, the
    # same operation a desktop tab click performs.
    const CompactWidth = 80
    const CompactHeight = 24
    var compact = newShellModel(CompactWidth, CompactHeight)
    ck compact.profile == lpCompact
    compact.timeline = filled.timeline
    ck compact.layout.activate(paneTimeline)
    let compactScreen = shellScreen(compact, CompactWidth, CompactHeight)
    var compactArea = CellArea()
    var compactFound = false
    for region in compactScreen.projection.regions:
      if region.pane == paneTimeline:
        compactArea = region.area
        compactFound = true
    ck compactFound
    ck compactArea.height >= TimelineBarRows
    checkpoint("compact timeline rows:\n  '" &
               compactScreen.rows[compactArea.row] & "'\n  '" &
               compactScreen.rows[compactArea.row + 1] & "'")
    ck compactScreen.rows[compactArea.row].contains(TimelineTitle)
    ck compactScreen.rows[compactArea.row + 1].contains(NeedleGlyph)

  test "the tracepoint dialog is an overlay the shell reports the extent of":
    # It takes no share of the layout — see `shell.shellScreen`'s comment — so
    # its rectangle is derived from the body and REPORTED on the screen, and
    # every row it changes is inside that rectangle.
    const Width = 120
    const Height = 40
    var closed = newShellModel(Width, Height)
    let before = shellScreen(closed, Width, Height)
    ck before.overlay.width == 0
    ck before.overlay.height == 0

    var open = closed
    open.tracepoints = initTracepointManagerModel(
      open = true,
      entries = @[TracepointEntry(
        id: 0,
        draft: initTracepointDraft(path = "/x/shield.nr", line = 58,
                                   expression = "log(damage)", enabled = true),
        state: tpsVerified, boundLine: 58, boundColumn: 0,
        hits: @[TracepointHit(tick: 71'u64, path: "/x/shield.nr", line: 58,
                              values: @[("damage", "100")])])])
    let shown = shellScreen(open, Width, Height)
    echo "CTUI-8 SHELL: tracepoint overlay at ", shown.overlay
    ck shown.overlay.width > 0
    ck shown.overlay.height > 0
    ck shown.overlay.col >= before.body.col
    ck shown.overlay.row >= before.body.row
    ck shown.overlay.col + shown.overlay.width <=
      before.body.col + before.body.width
    ck shown.overlay.row + shown.overlay.height <=
      before.body.row + before.body.height

    var changedInside = 0
    var changedOutside = 0
    for row in 0 ..< Height:
      if shown.rows[row] == before.rows[row]:
        continue
      if row >= shown.overlay.row and
         row < shown.overlay.row + shown.overlay.height:
        inc changedInside
      else:
        inc changedOutside
    ck changedOutside == 0
    ck changedInside > 0
    ck shown.rows[shown.overlay.row].contains(TracepointDialogTitle)
    ck shown.rows[shown.overlay.row + 1].contains(MarkGlyph)
    ck shown.rows[shown.overlay.row + 1].contains("log(damage)")
    ck shown.rows[shown.overlay.row + 2].contains("@71")

  test "assertion count":
    echo "CHECKS: " & $countedAssertions
    checkpoint("counted assertions: " & $countedAssertions)
    check countedAssertions == ExpectedAssertions
