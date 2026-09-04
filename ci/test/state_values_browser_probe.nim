## state_values_browser_probe.nim — a recorded value's journey from the
## backend's response to the State pane, in a REAL browser.
##
## ## THE TWO THINGS THIS PAGE MEASURES
##
## **Pane A (`#ct-state-pane`) — what a structured value LOOKS LIKE.**
## CodeTracer has two renderings for a recorded `Value`:
##
##   * the *structured* one, `textRepr` in
##     `common_types/utils/text_representation.nim`, which every other pane
##     paints — `ui/value.nim:789 collapsedValueTextAndClass` for Editor,
##     Call Trace, Flow and Trace — and which renders a sequence as
##     `@[100, 2000, 200, 14]`;
##   * the *string* one, `text()` / `$value` in the same file, a
##     multi-line diagnostic dump that renders the same sequence as
##     `"Sequence(Seq [Field; 4]):\n  100\n  2000\n  200\n  14"`.
##
## The State pane took the second: `ui/state.nim:valueDisplayText` is
## `$v`. So a recorded structure arrived intact and was displayed as
## prose about itself. Worse, `text()` has **no `of Error` branch**, so it
## falls through to `$value.kind` and a watch refusal — an `Error` value
## whose `msg` IS the reason — painted the bare word `Error`.
##
## **Pane B (`#ct-ordering-pane`) — whether the pane ever ASKED.**
## `StateVM`'s auto-load effect (`state_vm.nim:596`) runs eagerly at
## construction, inside `configureMiddleware`, long before a replay worker
## exists. It calls `store.requestLocals(0, @[])`, which marks
## `"load-locals"` pending (`replay_data_store.nim:710`) and sends into a
## channel with no peer. Nothing clears that entry: `RequestTracker.clear`
## exists (`request_tracker.nim:62`) and had **zero call sites**. So when
## the worker finally arrives and the first move re-fires the effect, the
## identical request (`rrTicks` is 0 for every position on a db-backend
## trace) hits `isDuplicate` at `replay_data_store.nim:707` and returns
## without asking. The pane waits for an answer nobody was asked for.
##
## ## WHY THE MEASUREMENTS LOOK THE WAY THEY DO
##
## Pane B's readings are **whether a command reached the backend** and
## **what the pane painted** — never a count of DOM mutations or repaints.
## A repaint count cannot separate correct work from redundant work (see
## `493ad8e4a`), but "zero `ct/load-locals` reached the backend after the
## worker arrived" is not a matter of degree.
##
## The backend here is `MockBackendService(autoRespond = false)`, whose
## `send` records the command and returns a future nobody resolves. That
## is precisely what a dropped frame produces on the web path: `ipc.send`
## warns `no host for ...` (`ui_js.nim:5685`), the DAP future is never
## settled, and it stays unsettled until the 30-second timeout
## (`dap.nim:428`). The void is modelled at the store boundary because the
## store boundary is where the defect lives.
##
## ## THE FIXTURE IS THE BACKEND'S OWN RESPONSE
##
## `ci/test/watch-expressions-probe/backend-response.json` — the same
## `ct/load-locals` body `watch_expressions_dap_test.rs` captures under
## `CT_WRITE_WATCH_FIXTURE`. Reused rather than copied so there is one
## fixture and the two gates cannot drift apart. It carries a `Seq`
## (`asteroid_masses`), an `Instance` (`landing_point`) and an `Error`
## (the refused watch) — the three shapes the string renderer mangles.
##
## The rows are built by **`ui/state.nim:localsToStoreRows`**, the
## product's own mapping, rather than by a hand-written copy. That is not
## a detail: the watch gate's probe hand-mapped the wire's `msg` field and
## so painted the refusal correctly while the shipping product painted
## `Error`. Twenty-four green checks over the wrong string. A probe that
## re-implements the mapping cannot see the mapping being wrong.
##
## Build (browser target — NOT -d:nodejs):
##   nim js -d:ctWeb -d:ctRenderer -d:chronicles_enabled=off \
##     --path:src --path:src/frontend/viewmodel \
##     -o:<out>/probe.js ci/test/state_values_browser_probe.nim

import std/[json, strutils]
import std/jsffi

import isonim/core/[signals, computation]
import isonim/web/dom_api as dom

# SELECTIVE, because `common_types` and `store/types` both export a type
# called `Variable` — the wire's (which carries a structured `Value`) and
# the store's (which carries a `string`). That collision is itself part of
# the subject here, so the two are kept apart by name.
#
# Via `frontend/types`, which `include`s `common/common_types` — importing
# that file directly does not compile on its own (`langstring` comes from
# the including module's prelude).
from ../../src/frontend/types import
  Value, TypeKind, CtLoadLocalsResponseBody, `$`, textRepr
import ../../src/frontend/ui/state as ui_state
import ../../src/frontend/viewmodel/store/replay_data_store
import ../../src/frontend/viewmodel/store/types as store_types
import ../../src/frontend/viewmodel/store/request_tracker
import ../../src/frontend/viewmodel/backend/mock_backend
import ../../src/frontend/viewmodel/viewmodels/state_vm
import ../../src/frontend/viewmodel/views/isonim_state_view

# The backend's own `ct/load-locals` body, in the bundle so the page needs
# no network. A compile-time define so an arm can point this elsewhere.
const StateFixturePath {.strdefine.} =
  "watch-expressions-probe/backend-response.json"
const BackendResponse = staticRead(StateFixturePath)

# ---------------------------------------------------------------------------
# ARMS
# ---------------------------------------------------------------------------
#
# Each arm reproduces the PRE-FIX product inside the harness, the way
# `watch-expressions-in-browser.sh`'s arms A and B do, so the gate can show
# its assertions are able to go red without anyone editing `src/`.
#
#   ValueArm = "legacy"      — the value cell is filled by `$v`, which is
#                              what `valueDisplayText` did before the fix.
#   OrderingArm = "no-hook"  — the moment the worker arrives, nothing
#                              clears the request tracker, which is what
#                              the product did before the fix.
const ValueArm {.strdefine.} = "product"
const OrderingArm {.strdefine.} = "product"

proc jsJsonParse(s: cstring): JsObject {.importjs: "JSON.parse(#)".}
  ## THE PRODUCT'S OWN DESERIALISATION. `Value` is a plain (non-variant)
  ## `ref object` whose field names are exactly the wire's, so on the JS
  ## target a parsed response IS a `CtLoadLocalsResponseBody` — the same
  ## structural cast the real host performs on a DAP body. Going through
  ## `std/json` into a hand-built `Value` would put a translation of my
  ## own between the backend's bytes and the pane.

proc legacyValueDisplayText(v: Value): string =
  ## `valueDisplayText` as it stood before the fix, kept here so the
  ## mutation arm has something to be. Verbatim: nil guard, then `$v`.
  if v.isNil:
    return ""
  $v

proc rowsFromBody(body: CtLoadLocalsResponseBody): seq[store_types.Variable] =
  when ValueArm == "legacy":
    result = newVariableSeq()
    for v in body.locals:
      let hasChild = (if v.value.isNil: false
                      else: v.value.elements.len > 0 or
                            v.value.kind in {TypeKind.Pointer, TypeKind.Ref,
                                             TypeKind.Instance, TypeKind.Union,
                                             TypeKind.Tuple, TypeKind.TableKind,
                                             TypeKind.Variant})
      result.add(makeVariable(
        name = $v.expression,
        value = legacyValueDisplayText(v.value),
        typeName = ui_state.valueDisplayType(v.value),
        hasChildren = hasChild,
        children = ui_state.toVariableChildren(v.value),
        isWatch = (not v.value.isNil and v.value.isWatch),
      ))
  else:
    # THE PRODUCT'S MAPPING, called and not copied.
    result = ui_state.localsToStoreRows(body.locals)

proc deferToTask(cb: proc()) {.importjs: "setTimeout(#, 0)".}

proc settle(store: ReplayDataStore) =
  ## Leave the pane as a host does once its request has been answered.
  ## The VM's auto-load effect issues `ct/load-locals` through the store
  ## and this page has no engine for pane A, so the loading flag would
  ## stay set over rows that are already painted. Deferred by a task
  ## because the effect clears it a line after we would.
  deferToTask(proc() = store.locals.loadingState.val = lsIdle)

# ---------------------------------------------------------------------------
# Pane A — what a structured value looks like
# ---------------------------------------------------------------------------

proc mountValuePane(): int =
  let backend = newMockBackendService(autoRespond = true).toBackendService()
  let store = createReplayDataStore(backend)
  let vm = createStateVM(store)

  let body = cast[CtLoadLocalsResponseBody](jsJsonParse(cstring(BackendResponse)))
  let rows = rowsFromBody(body)

  # `applyLocalsResponse` is the product's own locals/watch split — the
  # one entry point every host uses.
  store.applyLocalsResponse(rows)
  store.updateCodeStateLine(2, "let shield = 10000;")

  # The Watches tab holds the refusal row, so open it after the locals
  # have been read. Driven through the VM here because pane A's subject is
  # the RENDERING; the gesture that reaches this tab is already gated by
  # `ci/test/watch-expressions-in-browser.sh`.
  let container = dom.getElementById(dom.document, cstring"ct-state-pane")
  mountIsoNimStatePanel(container, vm)
  settle(store)
  rows.len

# ---------------------------------------------------------------------------
# Pane B — whether the pane ever asked
# ---------------------------------------------------------------------------

proc loadLocalsCount(mock: MockBackendService): int =
  result = 0
  for received in mock.receivedCommands:
    if received.command == "ct/load-locals":
      result += 1

var timeline: seq[string] = @[]

proc note(step: string) =
  timeline.add(step)

proc runOrderingTimeline(): JsonNode =
  ## THE ORDERING, STEP BY STEP, each step observed rather than reasoned
  ## about. The three moments the defect turns on are T0 (the key is set),
  ## T1 (the worker exists) and T2 (the first move after it).
  let mock = newMockBackendService(autoRespond = false)
  let store = createReplayDataStore(mock.toBackendService())

  # --- T0: the pane's ViewModel is constructed. -----------------------------
  # `createStateVM` runs its auto-load effect EAGERLY, here, which is the
  # whole defect: on the shipping frontends this happens inside
  # `configureMiddleware`, before `openSession` has made a worker.
  note("T0 before createStateVM: sent=" & $loadLocalsCount(mock) &
       " pending=" & $store.requestTracker.hasPending("load-locals"))
  let vm = createStateVM(store)
  let sentAtBoot = loadLocalsCount(mock)
  let pendingAfterBoot = store.requestTracker.hasPending("load-locals")
  note("T0 after createStateVM: sent=" & $sentAtBoot &
       " pending=" & $pendingAfterBoot &
       " unanswered=" & $mock.pendingDeferredCount)

  # The boot send is never answered — the channel had no peer. Nothing is
  # settled here, which is the point: `markComplete` is not reached.
  note("T0 the boot request is never answered (no worker existed to answer it)")

  # --- T1: the worker arrives. ---------------------------------------------
  # On the shipping web path this is `jsNewWorker` in
  # `browser_replay_engine.nim:141` followed by the dap responder going in
  # at `web_replay_host.nim:237`. From the store's side the observable
  # event is simply "a session is now live".
  when OrderingArm == "no-hook":
    note("T1 worker arrives: ARM — nothing clears the tracker (the pre-fix product)")
  else:
    store.resetForNewSession()
    note("T1 worker arrives: store.resetForNewSession() ran")
  let pendingAfterWorker = store.requestTracker.hasPending("load-locals")
  note("T1 after worker: pending=" & $pendingAfterWorker)

  # --- T2: the first complete-move. ----------------------------------------
  # `updateDebuggerPosition` always assigns a fresh DebuggerState so the
  # signal fires (db-backend traces are rrTicks=0 at every position), so
  # the VM's effect re-runs and asks again — with byte-identical arguments
  # to the stranded boot request.
  mock.clearReceivedCommands()
  store.updateDebuggerPosition(rrTicks = 0'u64, file = "main.nr", line = 12)
  let sentAfterMove = loadLocalsCount(mock)
  note("T2 first move at rrTicks=0: ct/load-locals reaching the backend=" &
       $sentAfterMove)

  # Answer whatever was actually asked, so the pane paints what a real
  # session would put in front of the reader at this moment.
  let body = cast[CtLoadLocalsResponseBody](jsJsonParse(cstring(BackendResponse)))
  let rows = rowsFromBody(body)
  if sentAfterMove > 0:
    store.applyLocalsResponse(rows)
    store.locals.loadingState.val = lsIdle
    note("T2 the answer arrives and is applied: " & $rows.len & " row(s)")
  else:
    note("T2 no request was issued, so no answer arrives — the pane keeps waiting")

  let container = dom.getElementById(dom.document, cstring"ct-ordering-pane")
  mountIsoNimStatePanel(container, vm)

  %*{
    "sentAtBoot": sentAtBoot,
    "pendingAfterBoot": pendingAfterBoot,
    "pendingAfterWorker": pendingAfterWorker,
    "sentAfterMove": sentAfterMove,
    "timeline": timeline,
  }

proc main() =
  let rowCount = mountValuePane()
  let ordering = runOrderingTimeline()

  # A machine-readable line beside the painted DOM, so the gate can tell
  # "the pane painted the wrong thing" from "the fixture never loaded".
  let summary = dom.getElementById(dom.document, cstring"ct-probe-summary")
  dom.appendChild(dom.Node(summary), dom.createTextNode(dom.document, cstring(
    "valueArm=" & ValueArm & " orderingArm=" & OrderingArm &
    " rows=" & $rowCount & " ordering=" & $ordering)))

main()
