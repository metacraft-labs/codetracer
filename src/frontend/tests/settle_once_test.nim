## settle_once_test.nim
##
## A test run's settle message is sent EXACTLY ONCE by the Electron main
## process, however the handler ends (`index/settle_once.nim`, used by
## `index/traces.onRunTest` and `onRunTestSuite`).
##
## Spec: codetracer-pm `spec/GUI/Core-Panes/Test-Results-Pane.md` §5 — every
## path out of a dispatched run ends it. The defect this guards: an `await`
## that REJECTED before `onRunTest`'s hoisted send (its
## `findTraceWithCodetracer`) escaped the `async` proc and sent nothing, so the
## renderer's pane and spinner waited for an answer that never came.
##
## The cases, each on the JS backend the index runs on, because that is where
## a rejected promise arrives as a foreign exception:
##
## 1. A handler whose awaited promise REJECTS before it settles produces one
##    settle, carrying the rejection's message.
## 2. A handler that RAISES synchronously before it settles produces one.
## 3. A handler that settles and THEN fails (the trace load after the early
##    send) produces no second settle.
## 4. A handler that settles normally is not followed by an error settle.
## 5. An error with no message still yields a sentence.
##
## No mocks. The handler bodies are real `async` procs awaiting real
## promises; `settle` is a closure that counts what it was asked to send —
## the Electron `webContents.send` it stands for is a process boundary with
## nothing to contribute but "was I called, with what".
##
## Lane: `main-process` — `nim js -d:nodejs -d:ctIndex -d:server`, run under
## node.

import std/[asyncjs, strutils]

import ../index/settle_once

var checks = 0
var failedChecks = 0

proc ck(cond: bool; name: string) =
  inc checks
  if cond: echo "  [OK] ", name
  else:
    inc failedChecks
    echo "  [FAILED] ", name

proc exitProcess(code: int) {.importjs: "process.exit(#)".}

proc rejectedPromise(message: cstring): Future[void] {.importjs:
  "Promise.reject(new Error(#))".}
  ## What a Node or Electron API hands back when it fails.

proc resolvedPromise(): Future[void] {.importjs: "Promise.resolve()".}

proc throwJsError(message: cstring) {.importjs: "(function(m){ throw new Error(m); })(#)".}
  ## A synchronous throw from host code — not a Nim exception.

type Sent = ref object
  settles: seq[string]
    ## Every settle message, as "ok:<payload>" or "error:<detail>".

proc newSent(): Sent = Sent(settles: @[])

proc errorSettle(sent: Sent): proc(detail: string) =
  result = proc(detail: string) = sent.settles.add "error:" & detail

proc rejectsBeforeSettling(once: SettleOnce): Future[void] {.async.} =
  # The `findTraceWithCodetracer` shape: an await that rejects before the
  # handler reaches its own send.
  await rejectedPromise("trace index unavailable")
  discard once.claim()

proc throwsBeforeSettling(once: SettleOnce): Future[void] {.async.} =
  await resolvedPromise()
  throwJsError("structured clone failed")
  discard once.claim()

proc runCases() {.async.} =
  echo "[Suite] a test run's settle is sent exactly once, however the handler ends"

  block:
    let sent = newSent()
    let once = newSettleOnce()
    await settleGuarded(once, rejectsBeforeSettling, sent.errorSettle())
    ck sent.settles.len == 1, "a rejected await before the send settles exactly once"
    ck sent.settles.len == 1 and sent.settles[0].startsWith("error:") and
       "trace index unavailable" in sent.settles[0],
       "the settle carries the rejection's message"

  block:
    let sent = newSent()
    let once = newSettleOnce()
    await settleGuarded(once, throwsBeforeSettling, sent.errorSettle())
    ck sent.settles == @["error:structured clone failed"],
       "a host error thrown before the send settles exactly once, with its message"

  block:
    let sent = newSent()
    let once = newSettleOnce()
    let settlesThenFails = proc(once: SettleOnce): Future[void] {.async.} =
      if once.claim():
        sent.settles.add "ok:rec-1"
      # The load that follows the early settle, failing.
      await rejectedPromise("loading the recording failed")
    var lateFailures: seq[string]
    await settleGuarded(once, settlesThenFails, sent.errorSettle(),
      proc(detail: string) = lateFailures.add detail)
    ck sent.settles == @["ok:rec-1"],
       "a failure AFTER the settle sends no second, contradictory settle"
    ck once.isSettled, "the request reads as answered"
    ck lateFailures == @["loading the recording failed"],
       "the late failure is handed to the caller to log, not dropped"

  block:
    let sent = newSent()
    let once = newSettleOnce()
    let settlesNormally = proc(once: SettleOnce): Future[void] {.async.} =
      await resolvedPromise()
      if once.claim():
        sent.settles.add "ok:rec-2"
    await settleGuarded(once, settlesNormally, sent.errorSettle())
    ck sent.settles == @["ok:rec-2"], "a normal settle is the only one"

  block:
    let sent = newSent()
    let once = newSettleOnce()
    let rejectsWithoutMessage = proc(once: SettleOnce): Future[void] {.async.} =
      await rejectedPromise("")
    await settleGuarded(once, rejectsWithoutMessage, sent.errorSettle())
    ck sent.settles == @["error:an unexpected error"],
       "an error with no message still yields a sentence"

  block:
    let once = newSettleOnce()
    ck once.claim() and not once.claim() and not once.claim(),
       "claim answers true exactly once"

proc main() {.async.} =
  try:
    await runCases()
  except:
    inc failedChecks
    echo "  [FAILED] the suite itself raised: ", getCurrentExceptionMsg()
  echo "CHECKS: ", checks, " FAILED: ", failedChecks
  exitProcess(if failedChecks == 0 and checks == 9: 0 else: 1)

discard main()
