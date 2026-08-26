## Pure loop-iteration arithmetic for the Omniscience flow loop controls.
##
## This module deliberately has **no imports**: `ui/flow.nim` is JS-only (it
## pulls in karax and the Monaco bindings), so the arithmetic that decides
## *which loop iteration the user is currently inside* could not be unit-tested
## at all while it lived there. Everything here compiles on the C backend, so
## `src/tests/gui/tests/flow/flow_loop_math_test.nim` can exercise it headlessly
## in microseconds.
##
## Vocabulary
## ----------
## `rrTicksForIterations[i]` is the trace tick of the **loop header** of
## iteration `i` — the moment the walker passed `for ...:` / `while ...:` for
## the i-th time. The backend builds it in `flow_preloader.rs::process_loops`.
## It is therefore:
##
## * strictly increasing (the walker only moves forward), and
## * a set of *interval starts*, not a set of positions the debugger will ever
##   stop on: stepping through the loop **body** produces ticks strictly
##   between two consecutive header ticks.
##
## The second point is the whole reason this module exists — see
## `activeIterationForTicks`.

## No import of `common_types/utils/constants` (where `FLOW_ITERATION_START`
## lives) is possible here: that file is `include`d into `common/common_types`
## rather than importable on its own, and pulling in the whole types module
## would drag the JS-only surface back in. It is not a DRY violation to say 0
## below — the first iteration index is 0 because these are `seq` indices, which
## is the same fact `FLOW_ITERATION_START = 0` records.

const
  FirstIteration = 0

proc activeIterationForTicks*(rrTicksForIterations: openArray[int], locationTicks: int): int =
  ## Index of the loop iteration that **contains** `locationTicks`.
  ##
  ## Iteration `i` spans `[rrTicksForIterations[i], rrTicksForIterations[i+1])`,
  ## with the last iteration extending to the end of the loop. So this is the
  ## last index whose header tick is `<= locationTicks`, clamped into range:
  ##
  ## * ticks before the first header  -> `FLOW_ITERATION_START` (0)
  ## * ticks at or after the last one -> `len - 1`
  ## * empty input                    -> `FLOW_ITERATION_START` (0), never raises
  ##
  ## Regression note (#593): the previous implementation compared
  ## `rrTicksForIterations[i] == locationTicks` and left the active iteration
  ## **unchanged** when nothing matched. Since a header tick is only ever the
  ## debugger's position on the single step where the loop condition is
  ## evaluated, that comparison failed for every step inside the body, so the
  ## counter froze at whatever it happened to hold — usually 0.
  if rrTicksForIterations.len == 0:
    # Guard: the caller (`updateFlowOnMove`) is not wrapped in a `try`, and an
    # IndexDefect here aborted the rest of `onCompleteMove`.
    return FirstIteration

  if locationTicks <= rrTicksForIterations[0]:
    return FirstIteration

  let lastIndex = rrTicksForIterations.len - 1
  if locationTicks >= rrTicksForIterations[lastIndex]:
    return lastIndex

  # `rrTicksForIterations` is sorted ascending, so a binary search for the last
  # entry `<= locationTicks` is exact. A linear scan would also be correct, but
  # this runs for every loop on every debugger move.
  var low = 0
  var high = lastIndex
  while low < high:
    # Bias the midpoint upwards so `low` can make progress when `high == low+1`.
    let mid = low + (high - low + 1) div 2
    if rrTicksForIterations[mid] <= locationTicks:
      low = mid
    else:
      high = mid - 1
  low

proc nextIteration*(current: int, maxIteration: int): int =
  ## The iteration the "forward" loop-control arrow should select.
  ##
  ## Clamped at both ends so a stale DOM node whose closure captured an older
  ## `current` can never drive the selection out of range.
  if maxIteration < FirstIteration:
    return FirstIteration
  min(max(current, FirstIteration) + 1, maxIteration)

proc previousIteration*(current: int, maxIteration: int): int =
  ## The iteration the "backward" loop-control arrow should select.
  if maxIteration < FirstIteration:
    return FirstIteration
  max(min(current, maxIteration) - 1, FirstIteration)
