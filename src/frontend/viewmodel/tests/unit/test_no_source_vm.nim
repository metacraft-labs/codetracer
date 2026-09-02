## codetracer#698 — the no-source panel's "Jump back" must name a destination.
##
## `NoSourceVM.jumpBack` sends `ct/history-jump`, and the backend deserialises
## that command's arguments into `task::Location`.  `Location` carries
## `#[serde(default)]` at CONTAINER level, so `serde_json::from_value` succeeds
## for *any* JSON object — including one written against a different struct
## entirely — and yields a fully zeroed location.  `location_jump` navigates by
## `rrTicks`, so a payload the backend could not read was a jump to STEP 0,
## answered with `success`.
##
## `jumpBack` used to send `{previousPath, action}`.  Neither name appears
## anywhere in `Location`.  Every click of "Jump back" therefore seeked to the
## first step of the recording and reported that it had worked, and nothing in
## the suite noticed, because the only thing asserted about payloads at this
## layer was that a command had been sent.
##
## SO THESE TESTS ASSERT THE DESTINATION THE REQUEST NAMES, never that a
## command was sent and never that a status was `success` — "returns success"
## is precisely what the defect did.  The other half of the pair lives in
## `src/db-backend/src/db.rs` (`mod jump_destination_tests`), which drives
## these exact payload shapes through a real `MaterializedReplaySession` and
## asserts the step the session ends up on.
##
## Compile + run:
##   nim c -r src/frontend/viewmodel/tests/unit/test_no_source_vm.nim

import std/[json, options, unittest]

import isonim/core/async_compat
import isonim/core/[signals, owner]
import isonim/viewmodel

import ../../backend/[backend_service, mock_backend]
import ../../store/[replay_data_store, types]
import ../../viewmodels/no_source_vm

proc drain() =
  ## Flush whatever the reactive layer resolved synchronously.
  drainPlatformCallbacks()

proc makeNoSourceVM(): tuple[vm: NoSourceVM,
                             store: ReplayDataStore,
                             mock: MockBackendService] =
  let mock = newMockBackendService(autoRespond = true)
  let store = createReplayDataStore(mock.toBackendService())
  let vm = createNoSourceVM(store)
  drain()
  mock.clearReceivedCommands()
  (vm, store, mock)

suite "codetracer#698 — NoSourceVM.jumpBack names the step it jumps to":

  test "test_no_source_jump_back_requests_the_previous_entrys_ticks":
    let (vm, _, mock) = makeNoSourceVM()
    vm.setHistory(NoSourceHistoryInfo(
      hasHistory: true,
      previousPath: "src/main.nim",
      action: "step in",
      previousLine: 42,
      previousRRTicks: 1337,
    ))
    vm.jumpBack()
    drain()

    let request = mock.findCommand("ct/history-jump")
    check request.isSome
    let args = request.get.args

    # THE DESTINATION.  `rrTicks` is the field `db.rs`'s `location_jump`
    # navigates by; without it the backend built a zeroed `Location` and
    # seeked to step 0.
    check args.hasKey("rrTicks")
    check args["rrTicks"].getBiggestInt == 1337
    check args["path"].getStr == "src/main.nim"
    check args["line"].getInt == 42

    # And the shape is a `Location`, not the private vocabulary this call
    # site used to invent.  `previousPath` and `action` are captions for the
    # panel's "We were in '…'" line; they are not fields of anything the
    # backend deserialises, and sending them was sending nothing.
    check not args.hasKey("previousPath")
    check not args.hasKey("action")

  test "test_no_source_jump_back_reads_the_history_rather_than_a_constant":
    # A SECOND, DIFFERENT ENTRY.  One case cannot distinguish "reads the
    # history entry" from "sends a fixed number", and a fixed number is the
    # defect's own shape — it sent 0 for everything.
    let (vm, _, mock) = makeNoSourceVM()
    vm.setHistory(NoSourceHistoryInfo(
      hasHistory: true,
      previousPath: "lib/accounting/ledger.nim",
      action: "next",
      previousLine: 7,
      previousRRTicks: 91021,
    ))
    vm.jumpBack()
    drain()

    let args = mock.findCommand("ct/history-jump").get.args
    check args["rrTicks"].getBiggestInt == 91021
    check args["path"].getStr == "lib/accounting/ledger.nim"
    check args["line"].getInt == 7

  test "test_no_source_jump_back_with_no_history_sends_nothing":
    # The guard that keeps a payload naming no destination off the wire in
    # the first place.  The backend refuses such a payload now, but a request
    # that should never have been made is better not made: the user would see
    # an error for pressing a button the view does not render.
    let (vm, _, mock) = makeNoSourceVM()
    vm.setHistory(NoSourceHistoryInfo())
    vm.jumpBack()
    drain()
    check mock.findCommand("ct/history-jump").isNone

suite "codetracer#698 — the panel keeps the caption AND the destination":

  test "test_no_source_history_carries_both_the_label_and_the_ticks":
    # `previousPath` is what the panel prints; `previousRRTicks` is where the
    # button goes.  The bug was keeping only the first, so this asserts the
    # VM still exposes both — a later cleanup that drops the ticks as
    # "unused by the view" would reintroduce the defect exactly.
    let (vm, _, _) = makeNoSourceVM()
    vm.setHistory(NoSourceHistoryInfo(
      hasHistory: true,
      previousPath: "src/main.nim",
      action: "step in",
      previousLine: 42,
      previousRRTicks: 1337,
    ))
    let history = vm.history.val
    check history.previousPath == "src/main.nim"
    check history.action == "step in"
    check history.previousLine == 42
    check history.previousRRTicks == 1337
