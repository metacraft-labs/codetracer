## LAYER RULE — `src/frontend/tui/app/` is the SDK-CONSUMING half of the TUI.
## See `app/cli.nim`'s header for the rule and
## `src/frontend/tui/tests/test_tui_facade_boundary.nim` for the walk that
## enforces it.
##
## app/views/heatmap.nim — CTUI-5. CodeTracer-TUI.md §3.3.2's "Execution
## Frequency Heatmap (Optional Gutter Mode)": the relative execution count of
## each visible line, in flame-spectrum colours.
##
## ## WHERE THE COUNTS COME FROM, AND WHAT THIS MILESTONE COULD NOT ESTABLISH
##
## §3.3.2 asks for the count "across the entire recorded execution". **No
## ViewModel in this repository exposes a per-line execution count**, and
## nothing in the DAP surface `viewmodel/backend/dap_commands.nim` allow-lists
## answers that question either — established by reading the ViewModel layer
## and the command table, and recorded here rather than worked around, because
## the difference between "counted over the whole recording" and "counted over
## what the session has visited" is exactly the difference between a heatmap
## that finds a hot path and one that describes where the user has been.
##
## So this module takes the counts as an INPUT. It is a mapping from
## `line -> count` onto glyphs and colours, and nothing in it collects
## anything. `app/source_binding.nim` builds one from the positions a real
## `DebugControlsVM` walk reported, which is a real execution count over a real
## traversal, and `test_source_stepping_forward_backward.nim` asserts it
## against the same walk. When a per-line count arrives from the engine, the
## only change here is who calls `newLineHeat`.
##
## **And the engine already has the number.** `omniscient_db.rs`, in
## `src/db-backend/`, declares `source_line_hits(file_id, line)` returning the
## ticks at which a line ran, over the `linehits.tc` namespace, implemented in
## `ctfs_trace_reader/linehits_namespace.rs` and
## `ctfs_trace_reader/materialization_cache.rs`, with an FFI arm in
## `emulator_ffi.rs`. What is missing is only the DAP arm: `dap_server.rs` does
## not mention it, and every non-test caller sits inside the omniscient/CTFS
## modules themselves, serving origin tracking. So the whole-recording heatmap
## §3.3.2 asks for is a request/response pair plus an allow-list entry away
## rather than a data-collection project — worth knowing before anyone
## concludes the count has to be accumulated in the front end.
##
## ## The spectrum is SIX buckets and they are ordered
##
## Five hot levels plus "never ran". Six because the sixteen-colour terminal
## palette has exactly that many rungs that read as a flame from a distance —
## `bright_black`, `red`, `bright_red`, `yellow`, `bright_yellow`,
## `bright_white` — and because a continuous ramp is unreadable in a
## one-column gutter. `heatLevel` buckets by the count's fraction of the
## window's MAXIMUM, so the colouring is relative, which is what "relative
## execution count" in §3.3.2 asks for.

import std/[algorithm, tables]

import ./styled_row

type
  LineHeat* = object
    ## Execution counts for a set of lines, plus the largest of them.
    ##
    ## `maxCount` is stored rather than recomputed per lookup: a source pane
    ## asks for a level once per visible row, and re-scanning the table for
    ## every row would make the gutter O(lines * counted lines) per frame.
    counts*: Table[int, int]
    maxCount*: int

const
  HeatLevels* = 6
    ## `heatLevel` returns `0 ..< HeatLevels`. Level 0 is "never ran".

  HeatPalette*: array[HeatLevels, CellStyle] = [
    CellStyle(fg: "bright_black"),           ## 0 — never executed
    CellStyle(fg: "red"),                    ## 1 — coldest of the hot
    CellStyle(fg: "bright_red"),             ## 2
    CellStyle(fg: "yellow"),                 ## 3
    CellStyle(fg: "bright_yellow"),          ## 4
    CellStyle(fg: "bright_white", bold: true)]  ## 5 — the hottest line
    ## Six DISTINCT styles, and their distinctness is asserted rather than
    ## assumed: a palette with a repeat would make two heat levels
    ## indistinguishable on screen while every count-based assertion stayed
    ## green.

proc newLineHeat*(samples: openArray[(int, int)]): LineHeat =
  ## Build a heatmap from `(line, count)` pairs. Repeated lines are SUMMED, so
  ## a caller may hand over one pair per observation rather than pre-tallying.
  result = LineHeat(counts: initTable[int, int](), maxCount: 0)
  for (line, count) in samples:
    if count <= 0:
      continue
    let total = result.counts.getOrDefault(line, 0) + count
    result.counts[line] = total
    if total > result.maxCount:
      result.maxCount = total

proc newLineHeatFromVisits*(lines: openArray[int]): LineHeat =
  ## Build a heatmap by counting how often each line appears in `lines`.
  ##
  ## This is the shape a stepping walk produces: one entry per stop, in the
  ## order the debugger reported them.
  result = LineHeat(counts: initTable[int, int](), maxCount: 0)
  for line in lines:
    if line <= 0:
      continue
    let total = result.counts.getOrDefault(line, 0) + 1
    result.counts[line] = total
    if total > result.maxCount:
      result.maxCount = total

proc countFor*(heat: LineHeat; line: int): int =
  ## How often `line` ran, or 0.
  heat.counts.getOrDefault(line, 0)

proc isEmpty*(heat: LineHeat): bool =
  heat.maxCount <= 0

proc heatLevel*(heat: LineHeat; line: int): int =
  ## Which of the `HeatLevels` buckets `line` falls in.
  ##
  ## Level 0 is reserved for a count of exactly zero, so "never ran" and "ran
  ## once in a recording whose hottest line ran ten thousand times" are
  ## different colours. Without that reservation the second would round into
  ## the first and a cold-but-executed line would be indistinguishable from
  ## dead code — which is the single most useful thing this mode shows.
  let count = heat.countFor(line)
  if count <= 0 or heat.maxCount <= 0:
    return 0
  # 1 .. HeatLevels-1, by the count's share of the maximum, rounding UP so the
  # hottest line is always the top level and a count of 1 is always level 1.
  let hot = HeatLevels - 1
  var level = (count * hot + heat.maxCount - 1) div heat.maxCount
  if level < 1: level = 1
  if level > hot: level = hot
  level

proc heatStyle*(heat: LineHeat; line: int): CellStyle =
  ## The flame colour for `line`.
  HeatPalette[heatLevel(heat, line)]

proc heatCountText*(heat: LineHeat; line: int): string =
  ## What the gutter's number field shows in heatmap mode.
  ##
  ## A line that never ran shows `·` rather than `0`, because a column of
  ## zeroes is noise and the point of the mode is to make the hot lines jump
  ## out. One cell wide, so it right-aligns into the same field a count does.
  let count = heat.countFor(line)
  if count <= 0: "·" else: $count

proc largestCount*(heat: LineHeat): int =
  heat.maxCount

proc countedLines*(heat: LineHeat): seq[int] =
  ## Every line with a non-zero count, ascending.
  ##
  ## Ascending rather than in `Table` order: a failure message that lists the
  ## counted lines has to list them the same way twice or two runs of one
  ## failure read as two different failures.
  result = @[]
  for line in heat.counts.keys:
    result.add line
  result.sort()

proc totalObservations*(heat: LineHeat): int =
  ## The sum of every count. Asserted against the number of stops a stepping
  ## walk made, which is what makes "the heatmap describes THIS walk" a
  ## checkable claim rather than a plausible one.
  for count in heat.counts.values:
    result += count
