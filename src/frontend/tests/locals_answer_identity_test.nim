## locals_answer_identity_test.nim
##
## A `ct/load-locals` ANSWER IS MATCHED TO THE REQUEST THAT PRODUCED IT — on
## the web renderer's real wiring, from both of its senders through the real
## response fan-out.
##
## ## The defects this pins
##
## The web renderer used to send `ct/load-locals` from TWO places on every
## debugger move:
##
##   A. `StateComponent.onCompleteMove` -> `loadLocals` -> the component's
##      mediator -> `middleware` -> `DapApi.sendCtRequest`;
##   B. the StateVM's auto-load effect (`state_vm.nim`) -> `store.requestLocals`
##      -> the store's backend (`dap_backend.newDapBackendService`) ->
##      `DapApi.asyncSendCtRequest`.
##
## Both answers were fanned out by `ui_js.onDapReceiveResponse` to the State
## pane's store, which reconciled each against the OLDEST request it had
## recorded — but only sender A recorded one. So each move produced more
## answers than records, the queue desynchronised, and after a fast move an
## answer about the FIRST stop was checked against the SECOND stop's stamp
## and APPLIED: last stop's values drawn beside this stop's line, the one
## thing the stop timeline exists to prevent.
##
## The first fix names each request by the transport's own identity
## (`dap.trackCtRequests`, recorded from `dap.dispatchCtRequest`, the one send
## path every sender reaches) and carries it back in the answer's body
## (`dap.deliverDapResponse`). The second removes the duplicate: the two
## requests were not even the same question — A named the file's language
## (`rust` for `calc.rs`) and a tick of 0 (the component's `rrTicks` is never
## assigned), B named the stop's tick and the store's fallback language `c`,
## and the native replay backend renders values through the named language's
## printers. Now B is the ONE request per move, naming the stop's tick and
## the file's language (`ReplayDataStore.sourceLanguageOf`, installed by
## `initStateVMWithStore`), and A stands down once the StateVM runs over the
## session's store. Where it does not — the stub-backed StateVM a host that
## never builds the session's store is left with (the VS Code extension) — A
## is still the one sender, and the first suite asserts it still asks.
##
## This suite drives the real senders and the delivery and reads the store
## and the wire.
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
import ../lang
from ../viewmodel/viewmodels/state_vm import addWatch, removeWatch
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

# The State component registers FIRST, over the stub-backed StateVM
# `register` builds — the order a host that never builds the session's store
# (the VS Code extension) is left in, and the order the desktop is in when
# `createUIComponents` beats `configureMiddleware`.
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

proc newSince(baseline: int): seq[JsObject] =
  let all = localsRequests()
  all[baseline .. ^1]

proc langOf(packet: JsObject): string =
  $packet["arguments"]["lang"].to(cstring)

proc ticksOf(packet: JsObject): int =
  packet["arguments"]["rrTicks"].to(int)

proc seqOf(packet: JsObject): int =
  packet["seq"].to(int)

proc watchesOf(packet: JsObject): seq[string] =
  let raw = packet["arguments"]["watchExpressions"]
  for i in 0 ..< raw["length"].to(int):
    result.add $raw[i].to(cstring)

# The language `calc.rs` is in, as the wire names it — resolved the way the
# renderer resolves it, so the suite does not restate the table.
let rustWire = langWireName(toLangFromFilename(cstring"/src/calc.rs"))
doAssert rustWire != LoadLocalsDefaultLang

suite "where the StateVM runs over a stub store, the State component asks":

  test "the stub-store host still asks once per move, in the file's language":
    # Before `initStateVMWithStore` the StateVM's auto-load goes to a stub
    # backend that sends nothing, so the legacy component is the only
    # sender: it must still ask, and name the file's language.
    let base = localsRequests().len
    moveTo(50, 5)
    let sent = newSince(base)
    ck sent.len == 1
    ck sent.len == 1 and langOf(sent[0]) == rustWire

# ---------------------------------------------------------------------------
# The session's store, wired as `ui_js.configureMiddleware` wires it
# ---------------------------------------------------------------------------

let store = createReplayDataStore(newDapBackendService(dapApi))
initStateVMWithStore(store)
wireLocalsAnswers(viewsApi)

proc deliver(frame: JsObject) =
  ## What `ui_js.onDapReceiveResponse` does with a response frame.
  deliverDapResponse(dapApi, dapApi, frame)

proc shown(): seq[string] =
  for row in store.locals.locals.val:
    result.add row.name & "=" & row.value

proc dropped(): int =
  store.stops.report.count(pkInlineValues, roDropped)

# The StateVM's effect asked once at construction, before `wireLocalsAnswers`
# ran — the boot request `resetForNewSession` is about. Not recorded, so its
# answer, were it to arrive, would name no stop.
let bootRequests = localsRequests().len

suite "the web renderer matches a ct/load-locals answer to its request":

  test "one request per move, in the file's language; a stale answer is dropped":
    moveTo(100, 10)
    let atStop1 = newSince(bootRequests)
    # ONE REQUEST PER MOVE — the StateVM's auto-load over the session's
    # store; the legacy component stands down. It names the language of the
    # file the debugger stopped in (`rust`, from `calc.rs`), not the store's
    # fallback `c`, and the stop's own tick.
    ck atStop1.len == 1
    ck atStop1.len == 1 and langOf(atStop1[0]) == rustWire
    ck atStop1.len == 1 and ticksOf(atStop1[0]) == 100
    ck store.pendingLocals.len == 1

    moveTo(200, 20)
    let atStop2 = newSince(bootRequests + 1)
    ck atStop2.len == 1
    ck atStop2.len == 1 and langOf(atStop2[0]) == rustWire
    ck store.pendingLocals.len == 2

    # The FAST MOVE: stop 1's answer arrives after the debugger reached stop 2.
    let droppedBefore = dropped()
    deliver(localsAnswer(seqOf(atStop1[0]), 10))
    ck "initial_shield=10" notin shown()
    ck shown().len == 0
    # Counted once per ANSWER, however many subscribers it was fanned out to.
    ck dropped() - droppedBefore == 1
    # A record lives exactly as long as its answer's delivery.
    ck store.pendingLocals.len == 1

    deliver(localsAnswer(seqOf(atStop2[0]), 20))
    ck shown() == @["initial_shield=20"]
    ck dropped() - droppedBefore == 1
    ck store.pendingLocals.len == 0
    # The legacy component's own subscription received the answer as well.
    ck component.locals.len == 1

  test "an answer overtaken by a later one is still judged by its own stop":
    let base = localsRequests().len
    moveTo(300, 30)
    let atStop3 = newSince(base)
    moveTo(400, 40)
    let atStop4 = newSince(base + 1)
    ck atStop3.len == 1 and atStop4.len == 1
    # Stop 4's answer overtakes stop 3's.
    deliver(localsAnswer(seqOf(atStop4[0]), 40))
    ck shown() == @["initial_shield=40"]
    deliver(localsAnswer(seqOf(atStop3[0]), 30))
    ck shown() == @["initial_shield=40"]
    ck store.pendingLocals.len == 0

  test "a repeated move asks nothing; a new stop at the same tick asks":
    let base = localsRequests().len
    moveTo(450, 45)
    ck newSince(base).len == 1
    # The same move delivered again is absorbed.
    moveTo(450, 45)
    ck newSince(base).len == 1
    # Another line at the SAME tick (another frame of the same instant) is a
    # new stop, asked about although the first request is still in flight:
    # that one's answer names the stop the debugger has left.
    moveTo(450, 46)
    let sent = newSince(base)
    ck sent.len == 2
    ck sent.len == 2 and ticksOf(sent[1]) == 450
    deliver(localsAnswer(seqOf(sent[0]), 45))
    deliver(localsAnswer(seqOf(sent[1]), 46))
    ck shown() == @["initial_shield=46"]
    ck store.pendingLocals.len == 0

  test "a watch-list change asks once, with the watch, in the file's language":
    let base = localsRequests().len
    activeStateVM().addWatch("initial_shield")
    let sent = newSince(base)
    ck sent.len == 1
    ck sent.len == 1 and watchesOf(sent[0]) == @["initial_shield"]
    ck sent.len == 1 and langOf(sent[0]) == rustWire
    deliver(localsAnswer(seqOf(sent[^1]), 47))
    activeStateVM().removeWatch("initial_shield")
    let after = newSince(base)
    ck after.len == 2
    ck after.len == 2 and watchesOf(after[1]).len == 0
    deliver(localsAnswer(seqOf(after[^1]), 48))
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
    ck sent.len == 1
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
    let pendingBefore = store.pendingLocals.len
    moveTo(600, 60)
    let atStop6 = newSince(base)
    ck atStop6.len == 1
    moveTo(700, 70)
    let atStop7 = newSince(base + 1)
    ck atStop7.len == 1
    # A second session asks at stop 7 with the same wire `seq` session 0
    # used at stop 6.
    let other = DapApi(ipc: recordingIpc(), seq: seqOf(atStop6[0]),
                       sessionId: 1)
    discard other.asyncSendCtRequest(CtLoadLocals, JsObject{})
    ck store.pendingLocals.len == pendingBefore + 3
    # Session 1's answer: about the current stop, so applied — although
    # session 0's identically numbered request is about stop 6.
    deliverDapResponse(dapApi, other, localsAnswer(seqOf(atStop6[0]), 71))
    ck shown() == @["initial_shield=71"]
    # Session 0's answer to that seq: about stop 6, dropped.
    deliver(localsAnswer(seqOf(atStop6[0]), 60))
    ck shown() == @["initial_shield=71"]
    deliver(localsAnswer(seqOf(atStop7[0]), 72))
    ck shown() == @["initial_shield=72"]
    ck store.pendingLocals.len == pendingBefore

proc settle(): Future[void] =
  ## Yield to the event loop until every pending microtask has run — the
  ## continuations that retire an ANSWERED request (`requestLocals`'
  ## `onComplete`) run there, never inside a synchronous test block.
  newPromise proc(resolve: proc()) =
    {.emit: "setTimeout(`resolve`, 0);".}

proc afterAnswersSettle() {.async.} =
  await settle()
  suite "once an answer has settled":

    test "a status-only change is not a new stop, and asks nothing":
      # The debugger is marked stepping at the stop it is LEAVING — a write
      # to `status` alone, which is what `store.requestStep` does before the
      # new position arrives. Once the stop's own request has been answered
      # nothing is in flight to absorb a second one, so only the auto-load's
      # reading of the STOP (not the whole state) keeps it from asking about
      # the stop being left — an answer that could only be dropped.
      let base = localsRequests().len
      var stepping = store.debugger.val
      stepping.status = store_types.dsStepping
      store.debugger.val = stepping
      ck newSince(base).len == 0
      # A real move afterwards is asked about, once.
      moveTo(900, 90)
      ck newSince(base).len == 1

    ck moveFailures.len == 0
    echo "CHECKS: ", checks
    if failedChecks > 0:
      {.emit: "process.exitCode = 1;".}

block:
  # The last answered request's retirement (a microtask) must have run.
  let base = localsRequests().len
  moveTo(800, 80)
  let sent = newSince(base)
  doAssert sent.len == 1
  deliver(localsAnswer(seqOf(sent[0]), 80))
  discard afterAnswersSettle()
