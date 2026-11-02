## test_call_trace_current_call.nim — **the terminal's call trace never marks
## a call that has returned** (codetracer#845, Pxor-Bugs M78), Tier 1.
##
## The reporter, in the TUI: at a stop inside `apply_op #12`, collapse the
## `evaluate` call that contains it, and `apply_op #9` — an earlier call of
## the same name at the same depth, already returned — is drawn as the current
## call. `Call-Trace-Pane.md` § Tree Structure: "The currently focused call
## is highlighted"; a returned call is not the current one.
##
## The rule itself is the ViewModel's and is tested headless in
## `src/frontend/viewmodel/tests/unit/test_calltrace_current_call.nim`. This
## suite covers what the terminal does with it: the pane's model
## (`initCallTraceModel`: `current`, `currentTraceIndex`) and the painted
## rows (`paintCallTrace`: the active-row ground and the bold callee).
##
## No fake ViewModel or backend: the input is the `CallTraceRow`s the host
## builds from the store's loaded section (`tui_session.callTraceModelOf`),
## constructed here in the shape a collapse leaves, because that shape is the
## defect and a recording reaches it only through a front-end click.

import std/[options, strutils, unittest]

import ../app/views/call_trace

# One line, deliberately: `ci/lib/run-nim-test-lane.sh` reads this spelling
# as the suite's RUNTIME assertion count.
const ExpectedAssertions = 13

var countedAssertions = 0

template ck(condition: untyped) =
  inc countedAssertions
  check condition

const
  Stop = 25'u64
  StackAtStop = @["apply_op", "evaluate", "main", "<__main__>", "<toplevel>"]

func row(index: int64; name: string; depth: int; ticks: uint64): CallTraceRow =
  CallTraceRow(index: index, name: name, depth: depth, rrTicks: ticks)

func collapsedSection(): seq[CallTraceRow] =
  ## The reporter's trace at the stop inside `apply_op #12`, with its parent
  ## `evaluate #10` collapsed: `tokenize #11` and `apply_op #12` are not
  ## listed, and `evaluate #13` takes the row after `evaluate #10`.
  @[row(0, "<toplevel>", 0, 1), row(1, "<__main__>", 1, 2),
    row(2, "main", 2, 3),
    row(3, "evaluate", 3, 4), row(4, "tokenize", 4, 5), row(5, "parse", 4, 6),
    row(6, "apply_op", 4, 7),
    row(7, "evaluate", 3, 10), row(8, "tokenize", 4, 11),
    row(9, "apply_op", 4, 12),
    row(10, "evaluate", 3, 20),
    row(11, "evaluate", 3, 40)]

func expandedSection(): seq[CallTraceRow] =
  @[row(0, "<toplevel>", 0, 1), row(1, "<__main__>", 1, 2),
    row(2, "main", 2, 3),
    row(3, "evaluate", 3, 4), row(4, "tokenize", 4, 5), row(5, "parse", 4, 6),
    row(6, "apply_op", 4, 7),
    row(7, "evaluate", 3, 10), row(8, "tokenize", 4, 11),
    row(9, "apply_op", 4, 12),
    row(10, "evaluate", 3, 20), row(11, "tokenize", 4, 21),
    row(12, "apply_op", 4, 22),
    row(13, "evaluate", 3, 40)]

proc markedRows(m: CallTraceModel; height: int): seq[int] =
  ## The pane rows painted as the current call: the active-row ground under
  ## the callee, or the callee bold.
  var g = newStyledGrid(80, height)
  let area = CellArea(col: 0, row: 0, width: 80, height: height)
  discard paintCallTrace(g, area, m)
  for r in 0 ..< height:
    for s in g.rowSpans(r):
      if s.text.strip.len > 0 and
         (s.style.surface == srSurfaceActiveRow or s.style.bold):
        result.add r
        break

suite "#845: the terminal's call trace after a collapse":

  test "control: expanded, apply_op #12 is the current call and is marked":
    let m = initCallTraceModel(expandedSection(), Stop, StackAtStop)
    ck m.current == 12
    ck m.currentTraceIndex == 12
    # Row 0 is the title; call `i` is pane row `i + 1`.
    ck m.markedRows(16) == @[13]

  test "its parent collapsed: apply_op #9 is NOT marked; no row is":
    var m = initCallTraceModel(collapsedSection(), Stop, StackAtStop)
    checkpoint("current = " & $m.current)
    ck m.current != 9
    ck m.current == -1
    ck m.markedRows(14).len == 0

  test "the scrubber's mark is the engine's, not the returned namesake":
    # The engine's `currentCallLineIndex` at this expansion is the last
    # listed call keyed at or before the current one: the collapsed
    # `evaluate #10`.
    var m = initCallTraceModel(collapsedSection(), Stop, StackAtStop)
    m.currentIndex = 10
    ck m.currentTraceIndex == 10

suite "#845: a section of the trace marks only what it can show":

  test "the section ends just after the returned namesake: no row marked":
    # Scrolled to the top: the loaded section is the first ten calls of the
    # collapsed listing (twelve), ending at `apply_op #9`. `evaluate #10`,
    # which shows `#9` returned, is past its end.
    let m = initCallTraceModel(collapsedSection()[0 .. 9], Stop, StackAtStop,
                               firstIndex = 0, total = 12, currentIndex = 10)
    ck m.current == -1
    ck m.currentTraceIndex == 10
    ck m.markedRows(12).len == 0

  test "the section ends just after the current call: the engine confirms":
    let m = initCallTraceModel(expandedSection()[5 .. 12], Stop, StackAtStop,
                               firstIndex = 5, total = 14, currentIndex = 12)
    ck m.current == 7
    ck m.currentTraceIndex == 12
    let unknown = initCallTraceModel(expandedSection()[5 .. 12], Stop,
                                     StackAtStop, firstIndex = 5, total = 14)
    ck unknown.current == -1

suite "#845: every case in this file ran":
  test "the assertion count is the one this file declares":
    checkpoint("counted " & $countedAssertions & ", expected " &
               $ExpectedAssertions)
    check countedAssertions == ExpectedAssertions
