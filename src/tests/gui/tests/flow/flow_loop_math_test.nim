## flow_loop_math_test.nim
##
## Headless tests for `frontend/ui/flow_loop_math` — the arithmetic behind the
## Omniscience loop controls (issues #593 "iteration counter stuck at 0" and
## #595 "arrow advances more than one iteration").
##
## Why these live at this layer
## ----------------------------
## The logic used to be inline in `ui/flow.nim`, which imports karax and the
## Monaco bindings and therefore only compiles on the JS backend — so it could
## only be observed through Playwright, and in practice it was not observed at
## all. Extracted, it is a total function over a `seq[int]` and can be pinned
## exhaustively here in microseconds.
##
## No mocks: these are pure functions over plain values.
##
## Run with:
##   nim c -r --hints:off src/tests/gui/tests/flow/flow_loop_math_test.nim

import std/unittest

import ../../../../frontend/ui/flow_loop_math

suite "activeIterationForTicks":

  test "ticks strictly between two iteration starts select the CONTAINING iteration":
    # THE regression case (#593). `rrTicksForIterations` holds the tick of each
    # iteration's loop HEADER; every step the user actually stops on inside the
    # body falls strictly between two of them. The old implementation compared
    # for exact equality and left the active iteration untouched on a miss, so
    # the counter never moved off its initial value while stepping.
    let starts = @[100, 200, 300, 400]

    check activeIterationForTicks(starts, 101) == 0
    check activeIterationForTicks(starts, 150) == 0
    check activeIterationForTicks(starts, 199) == 0
    check activeIterationForTicks(starts, 201) == 1
    check activeIterationForTicks(starts, 299) == 1
    check activeIterationForTicks(starts, 301) == 2
    check activeIterationForTicks(starts, 399) == 2

  test "exact iteration-start ticks select that iteration":
    let starts = @[100, 200, 300, 400]

    check activeIterationForTicks(starts, 100) == 0
    check activeIterationForTicks(starts, 200) == 1
    check activeIterationForTicks(starts, 300) == 2
    check activeIterationForTicks(starts, 400) == 3

  test "ticks before the first iteration clamp to iteration 0":
    let starts = @[100, 200, 300]

    check activeIterationForTicks(starts, 0) == 0
    check activeIterationForTicks(starts, 99) == 0
    check activeIterationForTicks(starts, -1) == 0

  test "ticks at or after the last iteration clamp to the last index":
    let starts = @[100, 200, 300]

    check activeIterationForTicks(starts, 300) == 2
    check activeIterationForTicks(starts, 301) == 2
    check activeIterationForTicks(starts, 10_000) == 2

  test "an empty iteration list yields 0 and does not raise":
    # `updateFlowOnMove` calls this without a `try`; an IndexDefect here used to
    # abort the rest of `onCompleteMove`.
    var starts: seq[int] = @[]
    check activeIterationForTicks(starts, 42) == 0
    check activeIterationForTicks(starts, 0) == 0

  test "a single-iteration loop always reports iteration 0":
    let starts = @[100]

    check activeIterationForTicks(starts, 0) == 0
    check activeIterationForTicks(starts, 100) == 0
    check activeIterationForTicks(starts, 100_000) == 0

  test "every tick in a long loop maps to its containing iteration":
    # Table-driven sweep: iteration i starts at 10*i, so any tick t in
    # [10*i, 10*i + 9] must map to i. This is the invariant the counter needs
    # in order to count 0,1,2,... as the user steps rather than sticking.
    const iterations = 25
    var starts: seq[int] = @[]
    for i in 0 ..< iterations:
      starts.add(10 * i)

    for i in 0 ..< iterations:
      for offset in 0 .. 9:
        let ticks = 10 * i + offset
        check activeIterationForTicks(starts, ticks) == i

suite "nextIteration / previousIteration":

  test "forward advances by exactly one":
    check nextIteration(0, 9) == 1
    check nextIteration(1, 9) == 2
    check nextIteration(8, 9) == 9

  test "forward saturates at the maximum":
    check nextIteration(9, 9) == 9
    check nextIteration(20, 9) == 9

  test "backward retreats by exactly one":
    check previousIteration(9, 9) == 8
    check previousIteration(2, 9) == 1
    check previousIteration(1, 9) == 0

  test "backward saturates at zero":
    check previousIteration(0, 9) == 0
    check previousIteration(-5, 9) == 0

  test "a degenerate loop (no iterations) is pinned to 0":
    # `maxIteration` is `loopIterationSteps[loop].len - 1`, which is -1 for a
    # loop with no recorded iterations. Neither arrow may produce -1.
    check nextIteration(0, -1) == 0
    check previousIteration(0, -1) == 0

  test "N forward clicks from 0 yield 1, 2, 3, ... (issue #595)":
    # The user-visible contract: each click on the forward arrow advances the
    # counter by one, never by two, and never past the end.
    const maxIteration = 9
    var current = 0
    var seen: seq[int] = @[]
    for _ in 1 .. maxIteration:
      current = nextIteration(current, maxIteration)
      seen.add(current)

    check seen == @[1, 2, 3, 4, 5, 6, 7, 8, 9]

    # And back down again, one at a time.
    var back: seq[int] = @[]
    for _ in 1 .. maxIteration:
      current = previousIteration(current, maxIteration)
      back.add(current)

    check back == @[8, 7, 6, 5, 4, 3, 2, 1, 0]
