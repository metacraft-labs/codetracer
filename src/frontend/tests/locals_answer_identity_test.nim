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
## `installSourceLanguage`), and A stands down once the StateVM runs over the
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
## production), and the session `ui_js.configureMiddleware` builds: a
## `DebuggerSession` over `newDapBackendService` (the constructor `ui_js`
## uses), its panel ViewModels and its stop loader, attached to a trace as
## `ui_js.attachLoadedTrace` attaches it. The frame shape the backend answers
## with is the real one.
##
## THE ANSWER IS MATCHED BY ITS OWN REQUEST'S FUTURE. Since HSF-S1 the stop
## loader is the web's sender and applies what it asked for when that
## request's future settles — `DapApi` resolves it from the response whose
## `request_seq` names it, in the session that sent it. The fan-out
## (`syncStoreLocals`) stands down on such a store. Settling happens on the
## microtask queue, so every read below follows `settle()`.
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
## `-d:nodejs`: `ui/state.nim`'s kdom graph does not compile under it), run
## by `jsdom-run.mjs` over a real DOM. WITHOUT `-d:ctInExtension`: the
## extension transport carries no request `seq`. Without `-d:nodejs`
## `std/unittest` cannot set the exit status, so this suite sets it.

import std/[unittest, jsffi, strutils, asyncjs, json]

import ../types
import ../dap
import ../dap_backend
import ../communication
import ../middleware
import ../../common/ct_event
import ../ui/state
from ../ui/process_tree import consumeListProcessesEvent
import ../lang
from ../viewmodel/viewmodels/state_vm import addWatch, removeWatch
import ../viewmodel/store/replay_data_store
import ../viewmodel/session_vm
import ../viewmodel/sdk/[debugger_session, trace_source]
from ../viewmodel/sdk/stop_loader import claimLocalsLoading
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

proc jsPush(arr: JsObject; item: JsObject) {.importjs: "#.push(#)".}

proc answerFromRequest(packet: JsObject; marker: int): JsObject =
  ## `localsAnswer`, plus the watch rows the REQUEST asked for: one copy of
  ## the fixture's `initial_shield` value per expression in the request's
  ## `watchExpressions`, renamed to that expression and marked
  ## `value.isWatch` — the shape `db-backend/src/watch_expression.rs` gives a
  ## watch answer. A request that named no watches gets no watch rows, as
  ## from the engine, so a request that dropped the watch list (#855) cannot
  ## be hidden by an answer that carries one anyway.
  result = localsAnswer(seqOf(packet), marker)
  let rows = result["body"]["locals"]
  for expression in watchesOf(packet):
    let row = jsonParse(readFixture())["locals"][1]
    row["value"]["i"] = cstring($marker)
    row["expression"] = cstring(expression)
    row["value"]["isWatch"] = true
    rows.jsPush(row)

# The language `calc.rs` is in, as the wire names it — resolved the way the
# renderer resolves it, so the suite does not restate the table.
let rustWire = langWireName(toLangFromFilename(cstring"/src/calc.rs"))
doAssert rustWire != LoadLocalsDefaultLang

suite "where the StateVM runs over a stub store, the State component asks":

  test "the stub-store host still asks once per move, in the file's language":
    # Before `initStateVMFromSession` the StateVM's auto-load goes to a stub
    # backend that sends nothing, so the legacy component is the only
    # sender: it must still ask, and name the file's language.
    let base = localsRequests().len
    moveTo(50, 5)
    let sent = newSince(base)
    ck sent.len == 1
    ck sent.len == 1 and langOf(sent[0]) == rustWire

# ---------------------------------------------------------------------------
# The session, built as `ui_js.configureMiddleware` builds it
# ---------------------------------------------------------------------------

let session = newDebuggerSession(newDapBackendService(dapApi))
let store = session.store
installSourceLanguage(store)
store.claimLocalsLoading()
session.session.initializePanelViewModels()
initStateVMFromSession(session.session.stateVM)
wireLocalsAnswers(viewsApi)
session.attach(localFolderTrace("/trace"))
# The engine answers every launch with an unsolicited `ct/listProcesses`, a
# single-trace launch too (`dap_server.rs::dispatch_session_load_event`, over
# `wrap_single_trace_as_session`); `ui_js`'s `subscribeListProcesses` hands it
# to `consumeListProcessesEvent`. Delivered here, as at session load, because
# it decides which StateVM the session reads the watch list from (#855).
session.session.consumeListProcessesEvent(%*{"processes": [{
  "recordingId": "calc", "role": "", "displayName": "calc.ct",
  "defaultThreadPrefix": "", "threadCount": 1, "threadIds": [1]}]})

proc deliver(frame: JsObject) =
  ## What `ui_js.onDapReceiveResponse` does with a response frame.
  deliverDapResponse(dapApi, dapApi, frame)

proc shown(): seq[string] =
  for row in store.locals.locals.val:
    result.add row.name & "=" & row.value

proc dropped(): int =
  store.stops.report.count(pkInlineValues, roDropped)

proc settle(): Future[void] =
  ## Yield to the event loop until every pending microtask has run — the
  ## stop loader applies an answer in its request future's continuation,
  ## which never runs inside the delivering call.
  newPromise proc(resolve: proc()) =
    {.emit: "setTimeout(`resolve`, 0);".}

# Attaching asks nothing: the store has no stop yet.
let bootRequests = localsRequests().len

proc sessionChecks() {.async.} =
  # ---- one request per move, in the file's language; a stale answer is dropped
  moveTo(100, 10)
  let atStop1 = newSince(bootRequests)
  # ONE REQUEST PER MOVE — the stop loader's; the legacy component stands
  # down. It names the language of the file the debugger stopped in (`rust`,
  # from `calc.rs`), not the store's fallback `c`, and the stop's own tick.
  ck atStop1.len == 1
  ck atStop1.len == 1 and langOf(atStop1[0]) == rustWire
  ck atStop1.len == 1 and ticksOf(atStop1[0]) == 100

  moveTo(200, 20)
  let atStop2 = newSince(bootRequests + 1)
  ck atStop2.len == 1
  ck atStop2.len == 1 and langOf(atStop2[0]) == rustWire

  # The FAST MOVE: stop 1's answer arrives after the debugger reached stop 2.
  let droppedBefore = dropped()
  deliver(localsAnswer(seqOf(atStop1[0]), 10))
  await settle()
  ck "initial_shield=10" notin shown()
  ck shown().len == 0
  # Counted once per ANSWER, however many subscribers it was fanned out to.
  ck dropped() - droppedBefore == 1

  deliver(localsAnswer(seqOf(atStop2[0]), 20))
  await settle()
  ck shown() == @["initial_shield=20"]
  ck dropped() - droppedBefore == 1
  # The legacy component's own subscription received the answer as well.
  ck component.locals.len == 1

  # ---- an answer overtaken by a later one is still judged by its own stop
  block:
    let base = localsRequests().len
    moveTo(300, 30)
    let atStop3 = newSince(base)
    moveTo(400, 40)
    let atStop4 = newSince(base + 1)
    ck atStop3.len == 1 and atStop4.len == 1
    # Stop 4's answer overtakes stop 3's.
    deliver(localsAnswer(seqOf(atStop4[0]), 40))
    await settle()
    ck shown() == @["initial_shield=40"]
    deliver(localsAnswer(seqOf(atStop3[0]), 30))
    await settle()
    ck shown() == @["initial_shield=40"]

  # ---- a repeated move asks nothing; a new stop at the same tick asks
  block:
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
    await settle()
    ck shown() == @["initial_shield=46"]

  # ---- a watch-list change asks once, with the watch, in the file's language
  block:
    let base = localsRequests().len
    activeStateVM().addWatch("initial_shield")
    let sent = newSince(base)
    ck sent.len == 1
    ck sent.len == 1 and watchesOf(sent[0]) == @["initial_shield"]
    ck sent.len == 1 and langOf(sent[0]) == rustWire
    deliver(localsAnswer(seqOf(sent[^1]), 47))
    await settle()
    activeStateVM().removeWatch("initial_shield")
    let after = newSince(base)
    ck after.len == 2
    ck after.len == 2 and watchesOf(after[1]).len == 0
    deliver(localsAnswer(seqOf(after[^1]), 48))
    await settle()
    ck shown() == @["initial_shield=48"]

  # ---- #855: a watch's result survives a move
  block:
    # Reported: add a watch, step, and the Watches tab is empty until
    # another watch is added. On the desktop the move reaches the store from
    # the State component (`onCompleteMove`), the session's stop loader asks,
    # and the store writes `store.locals.watches` from that answer — so the
    # answer to the MOVE must still carry the watch. Each answer here carries
    # exactly the watches its own request named (`answerFromRequest`).
    proc watchRows(): seq[string] =
      for row in store.locals.watches.val:
        result.add row.name & "=" & row.value
    let base = localsRequests().len
    activeStateVM().addWatch("initial_shield")
    let added = newSince(base)
    ck added.len == 1
    deliver(answerFromRequest(added[^1], 81))
    await settle()
    ck watchRows() == @["initial_shield=81"]
    moveTo(810, 81)
    let moved = newSince(base + 1)
    ck moved.len == 1
    ck moved.len == 1 and watchesOf(moved[0]) == @["initial_shield"]
    deliver(answerFromRequest(moved[^1], 82))
    await settle()
    ck shown() == @["initial_shield=82"]
    ck watchRows() == @["initial_shield=82"]
    # And a second move.
    moveTo(820, 82)
    let movedAgain = newSince(base + 2)
    ck movedAgain.len == 1
    deliver(answerFromRequest(movedAgain[^1], 83))
    await settle()
    ck watchRows() == @["initial_shield=83"]
    # Leave the session as the blocks below expect it: no watches.
    activeStateVM().removeWatch("initial_shield")
    let removed = newSince(base + 3)
    ck removed.len == 1 and watchesOf(removed[0]).len == 0
    deliver(answerFromRequest(removed[^1], 84))
    await settle()
    ck watchRows().len == 0

  # ---- an answer to a request this session never sent is not applied
  block:
    let before = shown()
    deliver(localsAnswer(9_999, 999))
    await settle()
    ck shown() == before

  # ---- an answer is named by the session that sent it, not the one on screen
  block:
    # Every replay session's `DapApi` numbers its requests from zero, so two
    # sessions routinely have a request with the same `seq` in flight. An
    # answer settles the request ITS session sent — named by the `DapApi`
    # that sent it (`responseDap`), not by the one the fan-out goes through
    # (`fanOut`, the session on screen) — so another session's answer never
    # reaches this session's store.
    let base = localsRequests().len
    moveTo(600, 60)
    let atStop6 = newSince(base)
    ck atStop6.len == 1
    moveTo(700, 70)
    let atStop7 = newSince(base + 1)
    ck atStop7.len == 1
    # A second session asks with the same wire `seq` session 0 used at stop 6.
    let other = DapApi(ipc: recordingIpc(), seq: seqOf(atStop6[0]),
                       sessionId: 1)
    discard other.asyncSendCtRequest(CtLoadLocals, JsObject{})
    deliverDapResponse(dapApi, other, localsAnswer(seqOf(atStop6[0]), 71))
    await settle()
    ck "initial_shield=71" notin shown()
    # Session 0's answer to that seq: about stop 6, dropped.
    deliver(localsAnswer(seqOf(atStop6[0]), 60))
    await settle()
    ck "initial_shield=60" notin shown()
    deliver(localsAnswer(seqOf(atStop7[0]), 72))
    await settle()
    ck shown() == @["initial_shield=72"]

  # ---- a status-only change is not a new stop, and asks nothing
  block:
    # The debugger is marked stepping at the stop it is LEAVING — a write to
    # `status` alone, which is what `store.requestStep` does before the new
    # position arrives. The stop loader keys a load on the stop's identity,
    # so it asks nothing about the stop being left.
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

discard sessionChecks()
