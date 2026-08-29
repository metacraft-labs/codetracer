## The result and latency vocabulary every platform facade speaks.
##
## NS1 (Noir-Studio.milestones.org) sets two constraints on the facade that this
## module exists to satisfy mechanically rather than by convention:
##
## 1. **No capability may assume synchronous, in-process access.** The container
##    instantiation (Noir-Studio.md §3.1a) is remote by construction, so every
##    operation returns a `PlatformFuture`. A facade that returned a bare value
##    would force a second, async client the day `ct host` grew a facade —
##    which is exactly the "two clients with one name" drift §3 exists to
##    prevent.
##
## 2. **Errors cross the boundary as values, not as exceptions.** The three
##    instantiations do not agree on exceptions: `std/asyncdispatch` futures
##    carry a `ref Exception`, JS promises reject with an arbitrary value, and
##    the `asyncBackend=none` stub has no propagation machinery at all. So the
##    contract is `PlatformFuture[PlatformOutcome[T]]` — the future expresses
##    *latency*, the outcome expresses *failure*, and neither is backend-
##    specific. `test_a_remote_instantiation_needs_no_signature_change` is only
##    cheap because of this: an endpoint-backed stub returns the same shape a
##    local call does.
##
## `PlatformFuture` comes from `isonim/core/async_compat`, which is
## nim-everywhere's cross-target future — the same facade lineage
## nim-everywhere-Time-Facade.md describes, reused rather than reinvented.

import isonim/core/async_compat

export async_compat

type
  PlatformFutureT*[T] = PlatformFuture[T]
    ## Spelled out so consumers can name the type without importing
    ## `async_compat` themselves. Every facade signature is
    ## `PlatformFutureT[PlatformOutcome[...]]`.

  PlatformErrorKind* = enum
    ## Deliberately platform-neutral. A desktop `ENOENT`, an OPFS
    ## `NotFoundError` and a container `404` are all `pkNotFound`; the
    ## originating text survives in `detail` for logs, and nothing above the
    ## facade is allowed to branch on it.
    pkNone
    pkNotFound
    pkAlreadyExists
    pkAccessDenied
    pkQuotaExceeded
    pkNotSupported
      ## The capability is absent on this platform. Callers should have asked
      ## `capabilities` first; this is the backstop, not the mechanism.
    pkTimeout
    pkTransport
      ## The instantiation is remote and the hop failed. Impossible in-process,
      ## which is precisely why it must exist in the vocabulary from day one.
    pkInvalidArgument
    pkConflict
    pkCancelled
    pkFailed

  PlatformError* = object
    kind*: PlatformErrorKind
    message*: string
      ## Safe to show a user.
    detail*: string
      ## The originating diagnostic (errno text, HTTP body, DOMException name).
      ## For logs and bug reports; never parsed.

  Nothing* = object
    ## The unit value. `PlatformOutcome[void]` is not expressible in Nim, and a
    ## `bool` return would invite callers to read success from the value rather
    ## than from `ok`.

  PlatformOutcome*[T] = object
    ## Not a case object on purpose: object variants generate branch-transition
    ## checks that behave differently under `--mm:orc` and the JS backend, and
    ## this type crosses both. `ok` is the discriminator by convention, and the
    ## accessors below are the only supported way to read it.
    ok*: bool
    value*: T
    error*: PlatformError

const nothing* = Nothing()

proc platformError*(kind: PlatformErrorKind; message: string;
                    detail = ""): PlatformError =
  PlatformError(kind: kind, message: message, detail: detail)

proc succeeded*[T](value: T): PlatformOutcome[T] =
  PlatformOutcome[T](ok: true, value: value)

proc succeeded*(): PlatformOutcome[Nothing] =
  PlatformOutcome[Nothing](ok: true, value: nothing)

proc failed*[T](error: PlatformError): PlatformOutcome[T] =
  PlatformOutcome[T](ok: false, error: error)

proc failed*[T](kind: PlatformErrorKind; message: string;
                detail = ""): PlatformOutcome[T] =
  PlatformOutcome[T](ok: false, error: platformError(kind, message, detail))

proc unsupported*[T](what: string): PlatformOutcome[T] =
  ## The canonical answer for a capability this platform does not have. Paired
  ## with `capabilities.degradedBehaviour`, which says what the user gets
  ## instead — Noir-Studio.milestones.org NS1: "Capabilities the web cannot
  ## provide enumerated, each with its degraded behaviour".
  failed[T](pkNotSupported, what & " is not available on this platform")

proc isOk*[T](outcome: PlatformOutcome[T]): bool = outcome.ok
proc isErr*[T](outcome: PlatformOutcome[T]): bool = not outcome.ok

proc valueOr*[T](outcome: PlatformOutcome[T]; fallback: T): T =
  if outcome.ok: outcome.value else: fallback

proc `$`*(error: PlatformError): string =
  result = $error.kind & ": " & error.message
  if error.detail.len > 0:
    result.add " (" & error.detail & ")"

proc resolved*[T](value: PlatformOutcome[T]): PlatformFuture[PlatformOutcome[T]] =
  ## An already-settled future. Every instantiation needs this — the desktop one
  ## for operations that genuinely are synchronous underneath, every one of them
  ## for the `pkNotSupported` short-circuit — and writing it once here keeps the
  ## backend-specific spelling of "completed future" out of the facades.
  ##
  ## `newCompletedFuture` rather than a bare `newPromise` on JS, and the
  ## difference is load-bearing rather than stylistic. A plain promise's `then`
  ## runs on the browser's microtask queue, so a synchronous caller — every
  ## headless test in the ViewModel suites — cannot observe the value at all:
  ## `drainPlatformCallbacks` drains nim-everywhere's own queue, not V8's.
  ## `newCompletedFuture` stamps `__syncResolved`, which is what lets
  ## `async_compat.onComplete` deliver inline. Written the other way, every
  ## assertion about a facade result would silently not run on the JS backend —
  ## the exact "case that cannot fail" this milestone is required to avoid, and
  ## the exact defect `vm-unit-js` was created to catch.
  newCompletedFuture(value)

proc resolvedOk*[T](value: T): PlatformFuture[PlatformOutcome[T]] =
  resolved(succeeded(value))

proc resolvedOk*(): PlatformFuture[PlatformOutcome[Nothing]] =
  resolved(succeeded())

proc resolvedErr*[T](kind: PlatformErrorKind; message: string;
                     detail = ""): PlatformFuture[PlatformOutcome[T]] =
  resolved(failed[T](kind, message, detail))

proc resolvedUnsupported*[T](what: string): PlatformFuture[PlatformOutcome[T]] =
  resolved(unsupported[T](what))

# ---------------------------------------------------------------------------
# Composition
# ---------------------------------------------------------------------------
#
# NS1 shipped the vocabulary and no way to sequence it, which was fine while
# every caller performed exactly one facade operation. NS2's project store is
# the first consumer that cannot: "write this file atomically" is a lock read,
# a temp write, a replace and a temp removal, and an OPFS volume makes every
# one of those a genuine promise.
#
# There is no portable `then`. `std/asyncjs.then` exists only on the JS target;
# `std/asyncdispatch` has `addCallback` and no `then`. `async_compat` unifies
# `onComplete`, which is a subscription rather than a combinator — it returns
# nothing, so it cannot express "and then do this, yielding a new future". So
# the combinators live here, once, rather than in each caller's `when defined(js)`.
#
# ## The property that makes them testable, and why it is not an optimisation
#
# Each combinator checks whether its input has ALREADY settled and, if so, runs
# the continuation INLINE and hands back the continuation's own future.
#
# That is not about speed. `outcome.resolved` uses `newCompletedFuture` so a
# settled facade result is observable synchronously (see its comment; NS1
# records that a bare `newPromise` made every JS assertion a silent no-op). If
# these combinators dropped to a promise the moment they were used, that
# property would end at the first composition — every store operation would be
# a real microtask on JS, `drainPlatformCallbacks` could not pump it, and the
# whole store suite would assert nothing under `vm-unit-js`. Preserving settled-
# ness through composition is what keeps the store testable on the backend it
# ships on; the async path underneath is exercised unchanged by the OPFS volume,
# which never settles synchronously.

proc thenOutcome*[A, B](future: PlatformFuture[PlatformOutcome[A]];
                        step: proc(value: A): PlatformFuture[PlatformOutcome[B]]
                       ): PlatformFuture[PlatformOutcome[B]] =
  ## Run `step` on success; propagate the error otherwise. The error is
  ## propagated as a *value*, so a failure short-circuits the chain without any
  ## backend's exception machinery being involved — the reason
  ## `PlatformOutcome` exists at all.
  when defined(js):
    if isSyncResolved(future):
      let settled = getSyncValue[PlatformOutcome[A]](future)
      if settled.ok: return step(settled.value)
      return newCompletedFuture(failed[B](settled.error))
    if isSyncFailed(future):
      return newCompletedFuture(failed[B](
        pkTransport, "the operation failed", getSyncError(future)))
    var capturedStep = step
    result = newPromise(proc(resolve: proc(value: PlatformOutcome[B])) =
      discard future.then(proc(settled: PlatformOutcome[A]) =
        if not settled.ok:
          resolve(failed[B](settled.error))
        else:
          let next = capturedStep(settled.value)
          discard next.then(proc(final: PlatformOutcome[B]) = resolve(final))))
  else:
    if future.finished and not future.failed:
      let settled = future.read()
      if settled.ok: return step(settled.value)
      return newCompletedFuture(failed[B](settled.error))
    let promise = newFuture[PlatformOutcome[B]]("thenOutcome")
    var capturedStep = step
    # `addCallback` wants `proc() {.closure, gcsafe.}` and the captured `step`
    # carries no such annotation. The cast is the bridge `remote_stub.nim`
    # already uses, and is safe for the same reason: nothing captured crosses a
    # thread.
    future.addCallback(proc() {.gcsafe.} =
      {.cast(gcsafe).}:
        if future.failed:
          promise.complete(failed[B](
            pkTransport, "the operation failed", future.readError.msg))
        else:
          let settled = future.read()
          if not settled.ok:
            promise.complete(failed[B](settled.error))
          else:
            let next = capturedStep(settled.value)
            next.addCallback(proc() {.gcsafe.} =
              {.cast(gcsafe).}:
                if next.failed:
                  promise.complete(failed[B](
                    pkTransport, "the operation failed", next.readError.msg))
                else:
                  promise.complete(next.read())))
    result = promise

proc mapOutcome*[A, B](future: PlatformFuture[PlatformOutcome[A]];
                       transform: proc(value: A): B
                      ): PlatformFuture[PlatformOutcome[B]] =
  ## `thenOutcome` for a step that cannot itself fail.
  var capturedTransform = transform
  thenOutcome(future, proc(value: A): PlatformFuture[PlatformOutcome[B]] =
    resolvedOk(capturedTransform(value)))

proc discardOutcome*[A](future: PlatformFuture[PlatformOutcome[A]]
                       ): PlatformFuture[PlatformOutcome[Nothing]] =
  mapOutcome(future, proc(value: A): Nothing = nothing)

proc recoverOutcome*[A](future: PlatformFuture[PlatformOutcome[A]];
                        recover: proc(error: PlatformError
                                     ): PlatformFuture[PlatformOutcome[A]]
                       ): PlatformFuture[PlatformOutcome[A]] =
  ## The mirror of `thenOutcome`: run `recover` on failure and pass success
  ## through. The store needs this for the shapes where a failure is expected
  ## and meaningful — "no lock file yet" is `pkNotFound` and is the normal
  ## first-open case, not an error to report.
  when defined(js):
    if isSyncResolved(future):
      let settled = getSyncValue[PlatformOutcome[A]](future)
      if settled.ok: return future
      return recover(settled.error)
    if isSyncFailed(future):
      return recover(platformError(
        pkTransport, "the operation failed", getSyncError(future)))
    var capturedRecover = recover
    result = newPromise(proc(resolve: proc(value: PlatformOutcome[A])) =
      discard future.then(proc(settled: PlatformOutcome[A]) =
        if settled.ok:
          resolve(settled)
        else:
          let next = capturedRecover(settled.error)
          discard next.then(proc(final: PlatformOutcome[A]) = resolve(final))))
  else:
    if future.finished and not future.failed:
      let settled = future.read()
      if settled.ok: return future
      return recover(settled.error)
    let promise = newFuture[PlatformOutcome[A]]("recoverOutcome")
    var capturedRecover = recover
    future.addCallback(proc() {.gcsafe.} =
      {.cast(gcsafe).}:
        var error: PlatformError
        if future.failed:
          error = platformError(
            pkTransport, "the operation failed", future.readError.msg)
        else:
          let settled = future.read()
          if settled.ok:
            promise.complete(settled)
            return
          error = settled.error
        let next = capturedRecover(error)
        next.addCallback(proc() {.gcsafe.} =
          {.cast(gcsafe).}:
            if next.failed:
              promise.complete(failed[A](
                pkTransport, "the operation failed", next.readError.msg))
            else:
              promise.complete(next.read())))
    result = promise

proc foldOutcome*[A](items: seq[A];
                     step: proc(item: A): PlatformFuture[PlatformOutcome[Nothing]]
                    ): PlatformFuture[PlatformOutcome[Nothing]] =
  ## Run `step` over every item, in order, stopping at the first failure.
  ##
  ## Sequential rather than concurrent, deliberately. The store's multi-file
  ## operations write into one tree under one lock, and a concurrent fan-out
  ## over OPFS would interleave `createWritable` calls on sibling paths whose
  ## ordering the atomic-replace argument depends on. There is no throughput
  ## case here worth that.
  var accumulated = resolvedOk()
  var capturedStep = step
  for item in items:
    let current = item
    accumulated = thenOutcome(accumulated,
      proc(ignored: Nothing): PlatformFuture[PlatformOutcome[Nothing]] =
        capturedStep(current))
  accumulated
