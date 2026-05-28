## vm_test_helpers.nim
##
## Cross-platform async helpers for ViewModel headless tests.
##
## On the native (C) backend, futures use std/asyncdispatch and need
## poll(0) to fire synchronously-completed callbacks.
##
## On JS, `async_compat.onComplete` fires callbacks synchronously for
## futures created with `newCompletedFuture`/`newFailedFuture`, matching
## native `asyncdispatch.addCallback` behavior for completed futures.
## This makes `drain()` a no-op on JS.
##
## Import this module instead of importing std/asyncdispatch directly:
##
##   import vm_test_helpers

when not defined(js):
  import std/asyncdispatch

import isonim/core/async_compat
export async_compat.newFailedFuture
export async_compat.newCompletedFuture
when defined(js):
  export async_compat.isSyncResolved
  export async_compat.isSyncFailed
  export async_compat.getSyncValue
  export async_compat.getSyncError

when defined(js):
  proc waitForTest*[T](f: PlatformFuture[T]): T =
    ## On JS, read the synchronous result from a mock future.
    ## Only works for futures created with `newCompletedFuture`.
    ## For `newFailedFuture` futures, this will raise.
    # Flush any pending callbacks first so side effects fire.
    drainPlatformCallbacks()
    if isSyncResolved(f):
      return getSyncValue[T](f)
    elif isSyncFailed(f):
      raise newException(CatchableError, getSyncError(f))
    else:
      raise newException(CatchableError,
        "waitForTest: cannot synchronously wait for an async JS promise")
else:
  proc waitForTest*[T](f: PlatformFuture[T]): T =
    ## On native, drain the event loop until f completes and return its value.
    while not f.finished:
      poll(0)
    return f.read

proc drain*() =
  ## Drain the async event loop so that all synchronously-completed
  ## futures fire their callbacks.
  ##
  ## On JS, flushes the `pendingCallbacks` queue populated by
  ## `onComplete` for mock futures, matching native `poll(0)` behavior.
  ##
  ## On native, calls the active backend's non-blocking drain helper.
  drainPlatformCallbacks()
