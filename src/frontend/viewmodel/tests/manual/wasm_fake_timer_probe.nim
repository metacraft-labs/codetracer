## NOT-A-TEST-LANE-FILE: a timing probe, not a suite. Its verdict is a RATIO
## between simulated and wall-clock time, which is the one form of timing
## assertion that survives being run on an unknown host — see below. The thing
## that compares the two backends is `ci/test/wasm-fake-timer-speed.sh`.
##
## wasm_fake_timer_probe.nim — PLAT-17's fourth verification signal.
##
## `Uniform-WASM-Core.md` §2.1.4, last bullet:
##
##     A fake-timer suite runs at native speed. §3A.4 makes this a rejection
##     criterion for *adoption*; here it is a correctness signal that the
##     dispatcher is genuinely inside WASM.
##
## ## What this measures, and why a ratio rather than a millisecond count
##
## The claim being tested is structural, not quantitative: **the clock, the
## dispatcher, the futures and the continuations are all inside one runtime**,
## so advancing a fake clock by an hour costs whatever the bookkeeping costs
## and nothing else. If any part of the chain reached a host timer — a
## `setTimeout`, a `poll()` that waits, an `epoll_wait` with a computed
## deadline — advancing an hour of simulated time would cost an hour, or the
## run would never finish at all.
##
## So the instrument is `simulated / wall`, and the threshold is not a tuning
## constant: it is the difference between two mechanisms. A run that defers to
## a host loop scores a ratio of about 1. A run that does not scores four or
## five orders of magnitude more. Nothing lands in between, which is what
## makes this readable on a machine whose speed is unknown and loaded — and is
## why it is NOT an absolute millisecond bound (Verification-Harness-Traps.md
## §12a: an absolute bound on a single measurement is a coin flip with one
## side hidden).
##
## ## What makes the measurement non-vacuous
##
## A timing over no work is the §10 defect wearing a stopwatch, and here it
## would be very easy to commit: a `sleepFor` whose future nobody observes
## costs nothing to "complete". So the probe COUNTS completions and refuses to
## report a ratio unless every one of them arrived. The count is asserted
## before the timing is printed, deliberately in that order.
##
## The second thing that could make it vacuous is subtler and is the reason
## `drainPlatformCallbacks()` is called inside the loop rather than once at
## the end. `sleepFor` with a `FakeAsyncContext` installed never touches
## `asyncdispatch` at all — it completes a bare `Future[void]` from the fake
## context's own queue — so a probe that only drove the fake clock would grade
## `fake_time.nim` and never reach the WASM arm this milestone added. Draining
## the platform dispatcher on every iteration is what puts
## `async_compat.drainWasmDispatcher` on the measured path, because
## `onCompleteVoid`'s callback goes through `addCallback` → `callSoon` →
## the dispatcher's queue, on every backend.
##
## ## The build a number quotes
##
## Printed, for the reason in Verification-Harness-Traps.md §12b: target,
## memory manager, release. A ratio this large is not going to be changed into
## a wrong verdict by a memory manager, but the rule is that a measurement
## names its inputs, and a probe that exempts itself teaches the exemption.
##
## Run:
##   nim c -r --mm:orc --path:src/frontend/viewmodel \
##     src/frontend/viewmodel/tests/manual/wasm_fake_timer_probe.nim

import std/[os, strutils, times]

import nim_everywhere
import nim_everywhere/async_compat

when defined(js):
  {.error: "wasm_fake_timer_probe compares a linear-memory target against " &
           "native. The JS backend's fake-timer question is the one " &
           "`vm-unit-js` already answers.".}

const
  DefaultIterations = 20_000
  SleepMs = 50
    ## Each iteration schedules a 50 ms sleep and then advances the fake
    ## clock past it. 20,000 of them is 1,000,000 ms — about 16 minutes of
    ## simulated time, which is long enough that a run deferring to a real
    ## timer would be unmistakable rather than merely slow.

when isMainModule:
  let iterations =
    if paramCount() >= 1: parseInt(paramStr(1)) else: DefaultIterations
  let simulatedMs = iterations * SleepMs

  var completed = 0
  var failed = 0

  # Warm-up: one iteration outside the measured region, so the first
  # `getGlobalDispatcher()` and the first allocation of the fake context's
  # sequence are not charged to the timing.
  block warmup:
    let warm = newFakeAsyncContext()
    warm.install()
    sleepFor(SleepMs).onCompleteVoid(
      (proc() = discard),
      (proc(message: string) = discard))
    warm.advance(SleepMs)
    warm.runPending()
    drainPlatformCallbacks()
    warm.uninstall()

  let ctx = newFakeAsyncContext()
  ctx.install()

  let started = epochTime()
  for _ in 0 ..< iterations:
    # The parentheses are load-bearing: without them Nim parses the comma as
    # part of the first lambda's body and the call becomes
    # `onCompleteVoid(inc completed, proc(...) = inc failed, 1)`.
    sleepFor(SleepMs).onCompleteVoid(
      (proc() = inc completed),
      (proc(message: string) = inc failed))
    ctx.advance(SleepMs)
    ctx.runPending()
    # The platform dispatcher, on every iteration — see the header for why
    # leaving this out of the loop would grade the fake clock and never the
    # WASM arm of the pump.
    drainPlatformCallbacks()
  let elapsed = epochTime() - started

  ctx.uninstall()

  var mm = "unknown"
  when defined(gcOrc): mm = "orc"
  elif defined(gcArc): mm = "arc"
  elif defined(gcRefc): mm = "refc"
  var target = "native"
  when defined(emscripten) or defined(wasm32): target = "wasm32-emscripten"

  echo "FAKETIMER-BUILD\ttarget=", target,
       "\tmm=", mm,
       "\trelease=", (when defined(release): "true" else: "false"),
       "\tplatformIsWasm=", platformIsWasm,
       "\titerations=", iterations
  echo "FAKETIMER-SIMULATED-MS\t", simulatedMs
  echo "FAKETIMER-WALL-MS\t", formatFloat(elapsed * 1000.0, ffDecimal, 3)
  echo "FAKETIMER-COMPLETED\t", completed, "\tof ", iterations
  echo "FAKETIMER-FAILED\t", failed

  # THE COUNT BEFORE THE RATIO. A timing over work that did not happen is not
  # a fast timing, and this is the branch that says so — it fires before the
  # ratio is computed, so a probe that completed nothing can never print a
  # number a reader might quote.
  if completed != iterations or failed != 0:
    echo "FAKETIMER-VERDICT\tFAILED\t", completed, " of ", iterations,
         " continuations arrived (", failed, " failed): the elapsed time above",
         " measures a chain that did not run"
    quit(1)

  # `elapsed` can legitimately round to zero on a fast host at a small
  # iteration count. Guard it rather than dividing, because `inf` is a ratio
  # that passes every threshold for the wrong reason.
  if elapsed <= 0.0:
    echo "FAKETIMER-VERDICT\tFAILED\twall time measured as 0; raise the",
         " iteration count so the measurement has a denominator"
    quit(1)

  let ratio = simulatedMs.float / (elapsed * 1000.0)
  echo "FAKETIMER-RATIO\t", formatFloat(ratio, ffDecimal, 1),
       "\tsimulated ms per wall ms"

  # The threshold separates two MECHANISMS rather than two speeds: a chain
  # that reaches a host timer scores ~1, a chain that does not scores
  # thousands. 100 is far above the first and far below the second, so the
  # verdict does not depend on how fast or how loaded this host is.
  const MinRatio = 100.0
  if ratio < MinRatio:
    echo "FAKETIMER-VERDICT\tFAILED\tratio ", formatFloat(ratio, ffDecimal, 1),
         " is below ", MinRatio,
         ": the fake clock is not driving the whole chain — something in it",
         " is waiting on a real timer"
    quit(1)
  echo "FAKETIMER-VERDICT\tOK\tthe clock, the dispatcher and the continuations",
       " are all inside this runtime"
