## settle_once — answer a request EXACTLY ONCE, however its handler ends.
##
## The Electron main process answers a test run with one settle message —
## `CODETRACER::test-run-settled` from `traces.onRunTest`,
## `CODETRACER::test-suite-settled` from `traces.onRunTestSuite` — and the
## renderer's Test Results pane and editor spinner wait for it
## (`GUI/Core-Panes/Test-Results-Pane.md` §5: every path out of a dispatched
## run ends it). Two ways of breaking that are easy to write and hard to see:
##
##   * NO settle. A handler is an `async` proc; an `await` that REJECTS (a
##     Node or Electron error), or anything that raises, escapes it, rejects
##     its future, reaches no handler — and sends nothing. `onRunTest`'s
##     `findTraceWithCodetracer` was exactly that, before the send that the
##     success path hoists above the trace load.
##   * TWO settles. A handler that settles early (so the spinner stops before
##     a slow trace load) and then fails in the load must not send a second,
##     contradictory end of the same run.
##
## This module is the rule, with no Electron in it, so it is asserted on the
## JS backend the index runs on (`src/frontend/tests/settle_once_test.nim`).
## The handler receives a `SettleOnce` and sends its message only when
## `claim` answers true; `settleGuarded` runs the handler and, when it rejects
## or raises before anything was claimed, claims and sends the error sentence.

import std/asyncjs

type
  SettleOnce* = ref object
    ## Whether this request has been answered.
    settled: bool

proc newSettleOnce*(): SettleOnce =
  SettleOnce(settled: false)

proc claim*(once: SettleOnce): bool =
  ## True exactly once: the caller that gets `true` sends the settle message,
  ## and every later caller gets `false` and sends nothing.
  if once.settled:
    return false
  once.settled = true
  true

proc isSettled*(once: SettleOnce): bool =
  once.settled

proc failureDetail*(message: string): string =
  ## The thrown message, or a stand-in when the error carried none — a settle
  ## sentence that ends in ": " tells a user nothing.
  if message.len > 0: message else: "an unexpected error"

proc settleGuarded*(once: SettleOnce;
                    body: proc(once: SettleOnce): Future[void];
                    settleFailure: proc(detail: string);
                    failedAfterSettle: proc(detail: string) = nil):
                    Future[void] {.async.} =
  ## Run `body`. If it rejects or raises, and NOTHING has been claimed yet,
  ## claim and call `settleFailure` with the error's message — so the request
  ## is answered with a sentence instead of not at all. If something was
  ## already claimed, the failure happened AFTER the answer (the load that
  ## follows an early settle) and is not reported as a second answer:
  ## `failedAfterSettle`, when given, receives it to log.
  ##
  ## Never rejects itself: the handler's error is the thing it turns into an
  ## answer.
  try:
    await body(once)
  except:
    # Bare: on the JS backend a rejection from Node or Electron arrives as a
    # foreign exception, which a `CatchableError` arm does not catch.
    let detail = failureDetail(getCurrentExceptionMsg())
    if once.claim():
      settleFailure(detail)
    elif not failedAfterSettle.isNil:
      failedAfterSettle(detail)
