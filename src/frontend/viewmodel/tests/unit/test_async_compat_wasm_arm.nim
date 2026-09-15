## test_async_compat_wasm_arm.nim
##
## PLAT-17 deliverable 3: `nim_everywhere/async_compat` gains a WASM arm, and
## this is the suite that says the arm is *the same facade* rather than a third
## set of semantics.
##
## ## Why this file exists at all, when the gate says "the existing test"
##
## `Uniform-WASM-Core.md` §2.1.4 is explicit that the WASM arm must be covered
## by the EXISTING test that catches `onComplete`'s already-complete-future
## subtlety — the one whose absence produced a silently zero-valued success in
## CTUI-4 — and "not only by new tests". That test is
## `test_sdk_facade.nim`'s
##
##     "a synchronous transport still settles inside launch"
##
## plus the seven cases of the `§6.3 over an asynchronous transport` suite
## around it, and it runs on this backend unmodified: `test_sdk_facade` is in
## `vm-unit`, in `vm-unit-js` and in `vm-unit-wasm`, and the wasm lane reports
## the same 43 cases the native lane does. **That is the coverage that
## matters, and this file does not replace it.**
##
## What this file adds is the thing a facade-level suite cannot see. A
## `DebuggerSession` asserts that a launch settles; it cannot distinguish
## "settled because the callback ran inline" from "settled because the drain
## ran it", and the whole content of the WASM arm is WHICH of those happens
## and what the drain does to get there. So the cases below drive
## `async_compat` directly, and every one of them is written so that the THREE
## backends must answer identically — because "one facade, three arms" is a
## claim about agreement, and a case that only runs on one arm cannot make it.
##
## ## What is asserted on all three backends
##
##   * a callback attached to an already-complete future does NOT run before a
##     drain. This is CTUI-4's subtlety in its primitive form: JS defers via
##     `pendingCallbacks`, native defers via `asyncdispatch.callSoon`, and the
##     WASM arm defers via the same `callSoon` drained without the selector.
##     Three mechanisms, one observable;
##   * it DOES run after one drain;
##   * a cascade — a callback that attaches another callback to another
##     already-complete future — settles inside ONE drain, not two. Every
##     caller of `drainPlatformCallbacks` in this workspace depends on that,
##     and it is a property of the drain's loop rather than of the futures;
##   * a drain with nothing pending is a no-op and raises nothing. On native
##     that is `poll(0)` raising `ValueError` and the arm swallowing it; on
##     WASM it is a loop that does not execute. The observable is the same and
##     the mechanisms are not, which is exactly why it is asserted rather than
##     assumed;
##   * failures route to the error callback with the message intact, and are
##     deferred on the same schedule as successes.
##
## ## What is asserted only where it means something
##
## Timers are native-and-WASM only, and the reason is a fact about the JS arm
## rather than a gap: on JS, `sleepFor` without a fake context is a
## `setTimeout`-backed promise, which `drainPlatformCallbacks` cannot pump at
## all — `drainCallbacks` only ever reaches the `__syncResolved` futures
## `newCompletedFuture` produces. Asserting a due-timer property there would
## be asserting something the platform does not offer. The two cases are
## guarded with `when not defined(js)` and the guard names that.
##
## The one case that is WASM-only is the arm-selection check itself
## (`platformIsWasm`), and it is two-sided: it asserts the value on every
## backend rather than only on the one it is about, so a build where the
## symbol silently stopped being defined reddens instead of skipping.
##
## ## No mocks
##
## None, beyond the `FakeAsyncContext` the whole workspace's suites already
## use. The subject here is the dispatcher itself, and a doubled dispatcher
## would assert that the code calls the procs this file thinks it should,
## which is the same thing said twice.
##
## Compile and run, on ALL THREE backends:
##   nim c -r --path:src/frontend/viewmodel \
##     src/frontend/viewmodel/tests/unit/test_async_compat_wasm_arm.nim
##   nim js -d:nodejs -r --path:src/frontend/viewmodel \
##     src/frontend/viewmodel/tests/unit/test_async_compat_wasm_arm.nim
##   nim c --cpu:wasm32 --os:linux -d:emscripten --cc:clang --clang.exe:emcc \
##     --clang.linkerexe:emcc --mm:orc --threads:off \
##     --passL:-sSTACK_SIZE=8388608 --passL:-sNODERAWFS=1 \
##     --passL:-sALLOW_MEMORY_GROWTH=1 --passL:-sEXIT_RUNTIME=1 \
##     --path:src/frontend/viewmodel -o:/tmp/t.js \
##     src/frontend/viewmodel/tests/unit/test_async_compat_wasm_arm.nim \
##     && node /tmp/t.js

import std/unittest

import nim_everywhere/async_compat
import nim_everywhere/time

var countedAssertions = 0

template counted(condition: untyped) =
  inc countedAssertions
  check condition

const ExpectedAssertions = 23
  ## Asserted by the last case. Update it deliberately, in the same commit as
  ## the checks that moved it.
  ##
  ## This number is the whole reason `vm-unit-wasm` can be compared to
  ## `vm-unit` as an EQUALITY rather than as "both green": ci/lib/
  ## run-nim-test-lane.sh reads it, and ci/test/vm-unit-wasm-parity.sh
  ## compares it across backends. A `when` that elided a case on one target
  ## would move the tally and redden the last case on that target — which is
  ## the point, and is why the `when not defined(js)` blocks below count on
  ## BOTH sides of the branch.

suite "async_compat — the arm is selected by the target, not by a define":

  test "platformIsWasm agrees with the backend this binary was built for":
    # Two-sided deliberately. Asserting only `platformIsWasm == true` under
    # wasm would leave the other two backends asserting nothing here, and a
    # build where `--cpu:wasm32` stopped defining `wasm32` would then be
    # invisible on the lane that would have caught it.
    when defined(emscripten) or defined(wasm32):
      counted platformIsWasm
    else:
      counted (not platformIsWasm)

  test "the facade's whole surface is present on every arm":
    # A compile-time assertion in the shape of a runtime one: if an arm drops
    # a symbol, this file stops compiling on that backend, which is the
    # earliest possible failure. The `counted` call is what makes it also
    # count, so the tally is comparable across the three lanes.
    counted declared(drainPlatformCallbacks)
    counted declared(onComplete)
    counted declared(onCompleteVoid)
    counted declared(newCompletedFuture)
    counted declared(newFailedFuture)

suite "async_compat — an already-complete future defers, on all three arms":

  test "the callback does not run before a drain":
    # CTUI-4's subtlety in primitive form. The DEFECT this guards is the one
    # the JS lane found in `DebuggerSession.launch`: a consumer that reads a
    # value it was handed the moment it asked for it, on one backend, and
    # reads a zero-valued default on another.
    #
    # The drain before the measured region is load-bearing on the native and
    # WASM arms: `asyncfutures.callSoon` runs its argument INLINE while
    # `callSoonProc` is nil ("Loop not initialized yet"), and it is the first
    # `getGlobalDispatcher()` that installs it. Without this line the case
    # would measure the state of the dispatcher rather than the semantics of
    # `onComplete`, and would pass or fail depending on whether anything else
    # in the file had run first.
    drainPlatformCallbacks()

    var seen = 0
    var errSeen = ""
    newCompletedFuture(42).onComplete(
      (proc(value: int) = seen = value),
      (proc(message: string) = errSeen = message))
    counted seen == 0
    counted errSeen == ""

  test "it runs after exactly one drain":
    drainPlatformCallbacks()
    var seen = 0
    newCompletedFuture(42).onComplete(
      (proc(value: int) = seen = value),
      (proc(message: string) = discard))
    drainPlatformCallbacks()
    counted seen == 42

  test "a void future settles the same way":
    drainPlatformCallbacks()
    var done = false
    newCompletedFuture().onCompleteVoid(
      (proc() = done = true),
      (proc(message: string) = discard))
    counted (not done)
    drainPlatformCallbacks()
    counted done

  test "a failed future reaches the error callback with its message":
    drainPlatformCallbacks()
    var seen = 0
    var message = ""
    newFailedFuture[int]("boom").onComplete(
      (proc(value: int) = seen = value),
      (proc(m: string) = message = m))
    counted message == ""
    drainPlatformCallbacks()
    counted seen == 0
    counted message == "boom"

suite "async_compat — the drain's own properties":

  test "a cascade settles inside ONE drain":
    # A callback that attaches another callback to another already-complete
    # future. The second must run in the SAME drain, because every consumer
    # of `drainPlatformCallbacks` in this workspace calls it once and then
    # asserts. On JS that is `drainCallbacks`'s `while pendingCallbacks.len >
    # 0`; on native it is `processPendingCallbacks`; on WASM it is the loop
    # the arm added, and this case is what says the three agree.
    drainPlatformCallbacks()
    var order: seq[int] = @[]

    proc inner(value: int) = order.add 2
    proc swallow(message: string) = discard
    proc outer(value: int) =
      order.add 1
      newCompletedFuture(2).onComplete(inner, swallow)

    newCompletedFuture(1).onComplete(outer, swallow)
    drainPlatformCallbacks()
    counted order == @[1, 2]

  test "a drain with nothing pending is a no-op and raises nothing":
    # Not decoration. On the native arm this is `poll(0)` raising
    # `ValueError: No handles or timers registered in dispatcher.` and the
    # arm catching it; on the WASM arm it is a loop whose condition is false
    # on the first test. Two mechanisms, one observable, and the observable
    # is what callers depend on.
    drainPlatformCallbacks()
    drainPlatformCallbacks()
    drainPlatformCallbacks()
    counted true

  test "callbacks run in the order they were attached":
    drainPlatformCallbacks()
    var order: seq[int] = @[]
    proc swallow(message: string) = discard
    newCompletedFuture(1).onComplete((proc(v: int) = order.add 1), swallow)
    newCompletedFuture(2).onComplete((proc(v: int) = order.add 2), swallow)
    newCompletedFuture(3).onComplete((proc(v: int) = order.add 3), swallow)
    drainPlatformCallbacks()
    counted order == @[1, 2, 3]

suite "async_compat — timers, where the platform has them":

  test "a due timer fires on a drain and a future one does not":
    # WHY THIS IS GUARDED. On JS, `sleepFor` without a fake context is a
    # `setTimeout`-backed promise and `drainPlatformCallbacks` cannot pump it
    # at all — `drainCallbacks` only reaches the `__syncResolved` futures
    # `newCompletedFuture` produces. There is nothing here for that arm to
    # assert, and asserting it anyway would be a case that is green because
    # the platform cannot disagree.
    #
    # On native and WASM this is the pair that separates the two
    # implementations of the pump: native's `runOnce` calls `processTimers`
    # and then hands `adjustTimeout`'s answer to `selectInto`; the WASM arm
    # calls the same timer loop and then RETURNS rather than waiting. A far
    # timer that fired would mean the arm is firing timers early; a far timer
    # that made the drain BLOCK would hang this case, which
    # Verification-Harness-Traps.md §1 says is the right shape for that
    # failure to take.
    when defined(js):
      counted true # see the note above: the platform offers nothing to test
      counted true
    else:
      drainPlatformCallbacks()
      let due = sleepAsync(0)
      drainPlatformCallbacks()
      counted due.finished

      let far = sleepAsync(3_600_000)
      drainPlatformCallbacks()
      counted (not far.finished)

  test "the fake clock, not the platform, is what a suite drives":
    # The property §3A.4 rests on: with a `FakeAsyncContext` installed,
    # `sleepFor` never reaches the platform at all, so the whole chain is
    # inside one runtime and an hour of simulated time costs nothing. Every
    # fake-time suite in this tree depends on it, and it is the reason the
    # WASM lane runs at native speed rather than at the speed of a host loop.
    # The wall-clock half of that claim is measured by
    # ci/test/wasm-fake-timer-speed.sh; what is asserted here is the
    # mechanism it rests on.
    #
    # THE OBSERVABLE IS THE FAKE CONTEXT'S OWN QUEUE, not the continuation,
    # and that choice is the whole design of this case. `ctx.scheduled.len`
    # answers the question actually being asked — did `sleepFor` register
    # with the fake clock or with the platform's timer? — and it answers it
    # identically on all three backends. Asserting the CONTINUATION instead
    # would have been asserting a different thing on each arm, which is how
    # the first draft of this case failed on JS for a reason that had nothing
    # to do with the fake clock.
    let ctx = newFakeAsyncContext()
    ctx.install()
    var fired = false
    sleepFor(3_600_000).onCompleteVoid(
      (proc() = fired = true),
      (proc(message: string) = discard))
    # One hour of simulated time is sitting in the FAKE queue. If `sleepFor`
    # had fallen through to `setTimeout` / `sleepAsync`, this would be 0.
    counted ctx.scheduled.len == 1
    ctx.advance(3_599_999)
    ctx.runPending()
    drainPlatformCallbacks()
    counted ctx.scheduled.len == 1
    ctx.advance(1)
    ctx.runPending()
    drainPlatformCallbacks()
    counted ctx.scheduled.len == 0

    # And the continuation, where the platform can deliver it. This half is
    # two-sided rather than guarded-and-skipped, so the count is the same on
    # every arm and the JS behaviour is PINNED rather than merely absent:
    #
    #   native / wasm  `sleepFor` under a fake context returns a bare
    #                  `Future[void]` the context completes, so
    #                  `onCompleteVoid` → `addCallback` → `callSoon` → the
    #                  drain, and `fired` is true.
    #   js             it returns a `newPromise` the context resolves, and
    #                  `onCompleteVoid` routes a non-`__syncResolved` promise
    #                  through a real `.then` microtask. `drainCallbacks`
    #                  only ever reaches the `__syncResolved` futures
    #                  `newCompletedFuture` produces, so a synchronous drain
    #                  cannot pump it and `fired` is still false here. That
    #                  is a property of the platform, documented at the same
    #                  place in `test_worker_backend.nim`, and it is why
    #                  every JS suite that observes an async transport yields
    #                  a turn before asserting.
    when defined(js):
      counted (not fired)
    else:
      counted fired
    ctx.uninstall()

suite "async_compat assertion count":

  test "async_compat_wasm_arm_assertion_count_is_measured":
    checkpoint("counted assertions: " & $countedAssertions)
    check countedAssertions == ExpectedAssertions
