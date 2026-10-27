## test_calltrace_current_call.nim — **the call the debugger is in, when the
## call trace does not show it** (codetracer#845, Pxor-Bugs M78).
##
## `calltrace_vm.currentCallOf` names the call the debugger is in among the
## LOADED call-trace lines, from the stop's tick and call stack. The terminal
## marks that row (`tui/app/views/call_trace.initCallTraceModel`) and both
## native front ends select it (`tui/host/native_host.selectCurrentCall`).
##
## The reported defect: at a stop inside `apply_op #12`, collapsing the
## `evaluate` call that contains it hid `apply_op #12`, and the pane then
## marked `apply_op #9` — an earlier call with the same name at the same
## depth, which had already RETURNED. `Call-Trace-Pane.md` § Tree Structure:
## "The currently focused call is highlighted"; a call that has returned is
## not the current one, whatever the expansion state.
##
## The loaded lines are the trace in preorder at its current expansion (a
## collapsed call is listed, its descendants are not). So a line at depth `d`
## has provably returned by `tick` when a LATER line, entered at or before
## `tick`, has depth `<= d`: that later call is not inside it, so it ran
## after it. Each case below is driven over constructed `CallLine`s so the
## shape is reached deterministically.
##
## No mocks: `currentCallOf` is a pure function of its arguments.

import std/[options, unittest]

import ../../viewmodels/calltrace_vm
import ../../store/types

# One line, deliberately: `ci/lib/run-nim-test-lane.sh` reads this spelling
# as the suite's RUNTIME assertion count.
const ExpectedAssertions = 24

var countedAssertions = 0

template ck(condition: untyped) =
  inc countedAssertions
  check condition

func cl(index: int64; name: string; depth: int; ticks: uint64;
        expanded = true): CallLine =
  CallLine(index: index, name: name, depth: depth, rrTicks: ticks,
           hasChildren: true, isExpanded: expanded)

const
  # The reporter's example, as a whole trace in preorder. `#n` is the call's
  # index. The debugger is stopped inside `apply_op #12` at tick 25.
  Stop = 25'u64
  StackAtStop = @["apply_op", "evaluate", "main", "<__main__>", "<toplevel>"]
    ## Innermost first; five frames, so the current call is at depth 4.

func fullTrace(): seq[CallLine] =
  @[cl(0, "<toplevel>", 0, 1), cl(1, "<__main__>", 1, 2), cl(2, "main", 2, 3),
    cl(3, "evaluate", 3, 4), cl(4, "tokenize", 4, 5), cl(5, "parse", 4, 6),
    cl(6, "apply_op", 4, 7),
    cl(7, "evaluate", 3, 10), cl(8, "tokenize", 4, 11),
    cl(9, "apply_op", 4, 12),                       # returned by tick 20
    cl(10, "evaluate", 3, 20), cl(11, "tokenize", 4, 21),
    cl(12, "apply_op", 4, 22),                      # THE CURRENT CALL
    cl(13, "evaluate", 3, 40)]                      # entered after the stop

func withCollapsed(lines: seq[CallLine]; collapsed: int64): seq[CallLine] =
  ## `lines` as the pane lists them once call `collapsed` is collapsed: the
  ## call stays, its descendants (the deeper lines after it) go.
  var depth = -1
  for l in lines:
    if depth >= 0:
      if l.depth > depth: continue
      depth = -1
    if l.index == collapsed:
      var c = l
      c.isExpanded = false
      result.add c
      depth = l.depth
    else:
      result.add l

suite "#845: a call that has returned is never the current call":

  test "control: with the tree expanded the current call is apply_op #12":
    ck currentCallOf(fullTrace(), Stop, StackAtStop) == some(12'i64)

  test "the current call's parent collapsed: not the returned apply_op #9":
    # THE REPORTED DEFECT. `evaluate #10` is collapsed, so `apply_op #12` is
    # not loaded; `apply_op #9` is, with the same name and depth, entered
    # before the stop. `evaluate #10`, listed after it at a shallower depth
    # and entered before the stop, shows it returned.
    let lines = fullTrace().withCollapsed(10)
    ck lines.len == 12              # the instrument: #11 and #12 are gone
    let at = currentCallOf(lines, Stop, StackAtStop)
    checkpoint("currentCallOf answered " & $at)
    ck at != some(9'i64)
    ck at != some(6'i64)
    ck at.isNone

  test "a collapsed ancestor further up hides it the same way":
    # `main` collapsed: every `apply_op` is gone, so nothing qualifies.
    ck currentCallOf(fullTrace().withCollapsed(2), Stop, StackAtStop).isNone

  test "collapsing an unrelated call leaves the current call marked":
    # `evaluate #7` (the parent of the returned namesake) collapsed.
    ck currentCallOf(fullTrace().withCollapsed(7), Stop, StackAtStop) ==
       some(12'i64)

  test "the current call is kept though deeper calls inside it returned":
    # At tick 30 the debugger is back in `evaluate #10`; its children
    # `tokenize #11` and `apply_op #12` returned. Lines after `#10` that are
    # DEEPER than it do not show that it returned.
    ck currentCallOf(fullTrace(), 30,
                     @["evaluate", "main", "<__main__>", "<toplevel>"]) ==
       some(10'i64)

  test "a later call at the SAME depth shows the earlier one returned":
    # The stack says the debugger is in an `apply_op` at depth 4, and the
    # last depth-4 call loaded before the stop is `tokenize`, so the
    # `apply_op` before it has returned and the current one is not loaded.
    let lines = @[cl(0, "evaluate", 3, 10), cl(1, "apply_op", 4, 12),
                  cl(2, "tokenize", 4, 21)]
    ck currentCallOf(lines, Stop, StackAtStop).isNone

  test "a later call entered exactly at the stop shows it returned":
    let lines = @[cl(0, "apply_op", 4, 12), cl(1, "evaluate", 3, Stop)]
    ck currentCallOf(lines, Stop, StackAtStop).isNone

  test "a later shallower call entered AFTER the stop proves nothing":
    # `evaluate` starts after the stop, so `apply_op` may still be running:
    # it is the current call.
    let lines = @[cl(0, "apply_op", 4, 12), cl(1, "evaluate", 3, 40)]
    ck currentCallOf(lines, Stop, StackAtStop) == some(0'i64)

  test "with no stack the fallback is still the last call entered":
    # Unchanged by #845, and stated so: the last line entered at or before
    # the stop has no later line entered by then, so nothing shows it
    # returned. With `evaluate #10` collapsed that is `evaluate #10` itself.
    ck currentCallOf(fullTrace().withCollapsed(10), Stop, @[]) ==
       some(10'i64)
    ck currentCallOf(fullTrace(), Stop, @[]) == some(12'i64)

suite "#845: a loaded SECTION answers only what it can show":

  # `currentCallInSectionOf`: the line that shows a candidate returned lies
  # between it and the first line entered after the stop. A section that
  # ends before that stretch does cannot show it.

  test "a section ending just after the returned namesake: none":
    let section = fullTrace().withCollapsed(10)[0 .. 9]   # ends at #9
    # The instrument: the whole-listing rule cannot see past the section.
    ck currentCallOf(section, Stop, StackAtStop) == some(9'i64)
    ck currentCallInSectionOf(section, Stop, StackAtStop,
                              reachesTraceEnd = false).isNone
    # The engine names the collapsed `evaluate #10`, not `#9`.
    ck currentCallInSectionOf(section, Stop, StackAtStop,
                              reachesTraceEnd = false,
                              engineIndex = 10).isNone

  test "a section ending just after the current call: the engine decides":
    let section = fullTrace()[0 .. 12]                   # ends at #12
    ck currentCallInSectionOf(section, Stop, StackAtStop,
                              reachesTraceEnd = false,
                              engineIndex = 12) == some(12'i64)
    ck currentCallInSectionOf(section, Stop, StackAtStop,
                              reachesTraceEnd = false).isNone

  test "a section holding a line entered after the stop shows it":
    ck currentCallInSectionOf(fullTrace(), Stop, StackAtStop,
                              reachesTraceEnd = false) == some(12'i64)
    ck currentCallInSectionOf(fullTrace()[3 .. 13], Stop, StackAtStop,
                              reachesTraceEnd = false) == some(12'i64)

  test "a section that ends the trace shows it, either way":
    ck currentCallInSectionOf(fullTrace()[0 .. 12], Stop, StackAtStop,
                              reachesTraceEnd = true) == some(12'i64)
    ck currentCallInSectionOf(fullTrace().withCollapsed(10), Stop,
                              StackAtStop, reachesTraceEnd = true).isNone

  test "with no stack: the last line entered, when the section shows it":
    ck currentCallInSectionOf(fullTrace(), Stop, @[],
                              reachesTraceEnd = false) == some(12'i64)
    ck currentCallInSectionOf(fullTrace()[0 .. 9], Stop, @[],
                              reachesTraceEnd = false).isNone

suite "#845: every case in this file ran":
  test "the assertion count is the one this file declares":
    checkpoint("counted " & $countedAssertions & ", expected " &
               $ExpectedAssertions)
    check countedAssertions == ExpectedAssertions
