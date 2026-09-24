## locals_answer_identity_test.nim
##
## A `ct/load-locals` ANSWER IS MATCHED TO THE REQUEST THAT PRODUCED IT — on
## the web renderer's real wiring, from both of its senders through the real
## response fan-out.
##
## ## The defect this pins
##
## The web renderer sends `ct/load-locals` from TWO places on every debugger
## move:
##
##   A. `StateComponent.onCompleteMove` -> `loadLocals` -> the component's
##      mediator -> `middleware` -> `DapApi.sendCtRequest`;
##   B. the StateVM's auto-load effect (`state_vm.nim`) -> `store.requestLocals`
##      -> the store's backend (`dap_backend.newDapBackendService`) ->
##      `DapApi.asyncSendCtRequest`.
##
## Both answers are fanned out by `ui_js.onDapReceiveResponse` to the State
## pane's store. The store used to reconcile each answer against the OLDEST
## request it had recorded — but only sender A recorded one. So each move
## produced more answers than records, the queue desynchronised, and after a
## fast move an answer about the FIRST stop was checked against the SECOND
## stop's stamp and APPLIED: last stop's values drawn beside this stop's
## line, the one thing the stop timeline exists to prevent.
##
## The fix names each request by the transport's own identity
## (`dap.trackCtRequests`, recorded from `dap.dispatchCtRequest`, the one send
## path both senders reach) and carries it back in the answer's body
## (`dap.deliverDapResponse`). This suite drives both senders and the delivery
## for real and reads the store.
##
## ## What is real, and the one stand-in
##
## REAL: `DapApi` (its `dispatchCtRequest`, `asyncSendCtRequest`,
## `sendCtRequest`, `deliverDapResponse`), `middleware.setupMiddlewareApis`
## (the view -> DAP request relay and the DAP -> views response relay), the
## views mediator and a component mediator built by `types`' own
## constructors, `StateComponent.register` / `onCompleteMove` / `loadLocals` /
## `registerLocals`, `state.wireLocalsAnswers` (called by `ui_js` in
## production), the StateVM and its auto-load effect over a
## `ReplayDataStore` whose backend is `newDapBackendService` (the constructor
## `ui_js` uses), and the frame shape the backend answers with.
##
## THE ONE STAND-IN: the `ipc` object's `send`, which records the request
## frame instead of writing it to the Backend Manager — and the answer frames,
## which the test writes in the Backend Manager's shape (`type`, `command`,
## `request_seq` echoing the request's `seq`, `success`, `body`) and hands to
## `deliverDapResponse` exactly as `ui_js.onDapReceiveResponse` does. It is not
## a mock: nothing in the code under test is replaced or observed through it,
## and it is the only way to control WHEN an answer arrives relative to a
## move, which is the whole property. `ui_js.onDapReceiveResponse` itself is
## not called because `ui_js.nim` is the renderer's entry module (importing it
## boots the application); its body is now one call to `deliverDapResponse`,
## which is what this suite calls.
##
## Lane: `renderer-dom` — the BROWSER target (`nim js -d:ctRenderer`, no
## `-d:nodejs`: `ui/state.nim`'s karax graph does not compile under it), run
## by `jsdom-run.mjs` over a real DOM. WITHOUT `-d:ctInExtension`: the
## extension transport carries no request `seq`. Without `-d:nodejs`
## `std/unittest` cannot set the exit status, so this suite sets it.

import std/[unittest, jsffi, strutils, asyncjs]

import ../types
import ../dap
import ../dap_backend
import ../communication
import ../middleware
import ../../common/ct_event
import ../ui/state
import ../viewmodel/store/replay_data_store
from ../viewmodel/store/types as store_types import nil
import ../viewmodel/editor/reconcile
import isonim/core/signals

var checks = 0
var failedChecks = 0
template ck(cond: untyped) =
  inc checks
  if not (cond):
    inc failedChecks
  check cond

# ---------------------------------------------------------------------------
# The transport: a recording `ipc` (the one stand-in)
# ---------------------------------------------------------------------------

var sentPackets: seq[JsObject] = @[]

proc recordingIpc(): JsObject =
  let ipc = JsObject{}
  ipc.send = proc(channel: cstring, packet: JsObject) =
    sentPackets.add(packet)
  ipc

proc localsRequests(): seq[JsObject] =
  for p in sentPackets:
    if p["command"].to(cstring) == cstring"ct/load-locals":
      result.add p

proc readFixture(): cstring {.importjs:
  "require('fs').readFileSync(require('path').join(globalThis.ctRepoRoot, 'ci/test/watch-expressions-probe/backend-response.json'), 'utf8')".}
proc jsonParse(text: cstring): JsObject {.importjs: "JSON.parse(#)".}

proc localsAnswer(requestSeq: int; marker: int): JsObject =
  ## The Backend Manager's response frame for one `ct/load-locals`, around a
  ## body the REAL backend produced: `ci/test/watch-expressions-probe/
  ## backend-response.json`, the `ct/load-locals` answer
  ## `watch_expressions_dap_test.rs` captures (one fixture, shared with the
  ## watch gate's probe, so the two cannot drift). The body is its one
  ## primitive local, `initial_shield`, with the recorded integer replaced by
  ## `marker` — the only thing that tells one stop's answer from another's.
  let fixture = jsonParse(readFixture())
  let shield = fixture["locals"][1]
  doAssert shield["expression"].to(cstring) == cstring"initial_shield"
  shield["value"]["i"] = cstring($marker)
  # Keyed by string: `JsObject{locals: ...}` does not produce a `locals` key
  # (the literal macro mangles that identifier).
  let body = newJsObject()
  body[cstring"locals"] = [shield].toJs
  JsObject{
    `type`: cstring"response",
    request_seq: requestSeq,
    success: true,
    command: cstring"ct/load-locals",
    body: body
  }

# ---------------------------------------------------------------------------
# The renderer, wired as `ui_js.configureMiddleware` wires it
# ---------------------------------------------------------------------------

let dapApi = DapApi(ipc: recordingIpc(), seq: 0, sessionId: 0)
let viewsApi = setupSinglePageViewsApi(cstring"test-views")
setupMiddlewareApis(dapApi, viewsApi)

let store = createReplayDataStore(newDapBackendService(dapApi))
initStateVMWithStore(store)
wireLocalsAnswers(viewsApi)

let component = StateComponent(
  id: 0,
  values: JsAssoc[cstring, ValueComponent]{},
  valueHistory: JsAssoc[cstring, ValueHistory]{})
component.register(setupLocalViewToMiddlewareApi(cstring"state api", viewsApi))

var moveFailures: seq[string] = @[]

proc moveTo(rrTicks, line: int) =
  ## A debugger move as the State component receives it.
  # Every `cstring` a real `MoveState` carries is a string; a nil one is not
  # a shape the wire produces.
  var loc = Location(path: cstring"/src/calc.rs", line: line, rrTicks: rrTicks,
                     sourceDigest: cstring"")
  # `onCompleteMove` is async; everything this suite reads happens before its
  # first `await` returns, but a failure inside it would otherwise vanish
  # into a rejected promise — so it is surfaced and counted.
  discard component.onCompleteMove(MoveState(location: loc)).catch(
    proc(e: Error) =
      echo "move rejected: ", e.message
      moveFailures.add $e.message)

proc deliver(frame: JsObject) =
  ## What `ui_js.onDapReceiveResponse` does with a response frame.
  deliverDapResponse(dapApi, dapApi, frame)

proc shown(): seq[string] =
  for row in store.locals.locals.val:
    result.add row.name & "=" & row.value

proc dropped(): int =
  store.stops.report.count(pkInlineValues, roDropped)

proc newSince(baseline: int): seq[JsObject] =
  let all = localsRequests()
  all[baseline .. ^1]

proc langOf(packet: JsObject): string =
  $packet["arguments"]["lang"].to(cstring)

proc seqOf(packet: JsObject): int =
  packet["seq"].to(int)

# The StateVM's effect asked once at construction, before `wireLocalsAnswers`
# ran — the boot request `resetForNewSession` is about. Not recorded, so its
# answer, were it to arrive, would name no stop.
let bootRequests = localsRequests().len

suite "the web renderer matches a ct/load-locals answer to its request":

  test "both senders are recorded; a stale answer is dropped, the current one applied":
    moveTo(100, 10)
    let atStop1 = newSince(bootRequests)
    # BOTH SENDERS SENT — the premise of the defect, asserted by what each
    # one sends: the State component names the file's language (`rust`, from
    # `calc.rs`), the store's request carries its default (`c`). If either
    # stopped sending, the rest would pass without the mismatch it pins.
    ck atStop1.len == 2
    ck atStop1.len == 2 and langOf(atStop1[0]) != langOf(atStop1[1])
    ck store.pendingLocals.len == 2

    moveTo(200, 20)
    let atStop2 = newSince(bootRequests + 2)
    ck atStop2.len == 2
    ck store.pendingLocals.len == 4

    # The FAST MOVE: stop 1's answers arrive after the debugger reached stop 2.
    let droppedBefore = dropped()
    deliver(localsAnswer(seqOf(atStop1[0]), 10))
    ck "initial_shield=10" notin shown()
    deliver(localsAnswer(seqOf(atStop1[1]), 11))
    ck "initial_shield=11" notin shown()
    ck shown().len == 0
    # Counted once per ANSWER, however many subscribers it was fanned out to.
    ck dropped() - droppedBefore == 2
    # A record lives exactly as long as its answer's delivery.
    ck store.pendingLocals.len == 2

    deliver(localsAnswer(seqOf(atStop2[0]), 20))
    ck shown() == @["initial_shield=20"]
    deliver(localsAnswer(seqOf(atStop2[1]), 21))
    ck shown() == @["initial_shield=21"]
    ck dropped() - droppedBefore == 2
    ck store.pendingLocals.len == 0
    # The legacy component's own subscription received the answer as well.
    ck component.locals.len == 1

  test "an answer overtaken by a later one is still judged by its own stop":
    let base = localsRequests().len
    moveTo(300, 30)
    let atStop3 = newSince(base)
    moveTo(400, 40)
    let atStop4 = newSince(base + 2)
    ck atStop3.len == 2 and atStop4.len == 2
    # One of stop 4's answers overtakes both of stop 3's; the other comes last.
    deliver(localsAnswer(seqOf(atStop4[0]), 40))
    ck shown() == @["initial_shield=40"]
    deliver(localsAnswer(seqOf(atStop3[0]), 30))
    deliver(localsAnswer(seqOf(atStop3[1]), 31))
    ck shown() == @["initial_shield=40"]
    deliver(localsAnswer(seqOf(atStop4[1]), 41))
    ck shown() == @["initial_shield=41"]
    ck store.pendingLocals.len == 0

  test "an answer to a request this store never recorded is not applied":
    let before = shown()
    let droppedBefore = dropped()
    deliver(localsAnswer(9_999, 999))
    ck shown() == before
    ck dropped() - droppedBefore == 1

  test "the identity travels in the body every subscriber receives":
    let base = localsRequests().len
    moveTo(500, 50)
    let sent = newSince(base)
    ck sent.len == 2
    let frame = localsAnswer(seqOf(sent[^1]), 50)
    deliver(frame)
    ck $ctRequestIdOf(frame["body"]) == "0:" & $seqOf(sent[^1])
    ck shown() == @["initial_shield=50"]

  test "an answer is named by the session that sent it, not the one on screen":
    # Every replay session's `DapApi` numbers its requests from zero, so two
    # sessions routinely have a request with the same `seq` in flight. The
    # answer must be judged against the stop of the request ITS session sent
    # — named by the `DapApi` that sent it (`responseDap`), not by the one the
    # fan-out goes through (`fanOut`, the session on screen).
    let base = localsRequests().len
    # The previous case leaves one of its two requests unanswered.
    let pendingBefore = store.pendingLocals.len
    moveTo(600, 60)
    let atStop6 = newSince(base)
    ck atStop6.len == 2
    moveTo(700, 70)
    let atStop7 = newSince(base + 2)
    ck atStop7.len == 2
    # A second session asks at stop 7 with the same wire `seq` session 0
    # used at stop 6.
    let other = DapApi(ipc: recordingIpc(), seq: seqOf(atStop6[0]),
                       sessionId: 1)
    discard other.asyncSendCtRequest(CtLoadLocals, JsObject{})
    ck store.pendingLocals.len == pendingBefore + 5
    # Session 1's answer: about the current stop, so applied — although
    # session 0's identically numbered request is about stop 6.
    deliverDapResponse(dapApi, other, localsAnswer(seqOf(atStop6[0]), 71))
    ck shown() == @["initial_shield=71"]
    # Session 0's answer to that seq: about stop 6, dropped.
    deliver(localsAnswer(seqOf(atStop6[0]), 60))
    ck shown() == @["initial_shield=71"]
    deliver(localsAnswer(seqOf(atStop6[1]), 61))
    deliver(localsAnswer(seqOf(atStop7[0]), 72))
    deliver(localsAnswer(seqOf(atStop7[1]), 73))
    ck shown() == @["initial_shield=73"]
    ck store.pendingLocals.len == pendingBefore

  ck moveFailures.len == 0
  echo "CHECKS: ", checks
  if failedChecks > 0:
    {.emit: "process.exitCode = 1;".}
