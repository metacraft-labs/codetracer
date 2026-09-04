## The Event Log does not re-fetch its rows because the reader moved.
##
## Spec:
##   codetracer-specs/GUI/Core-Panes/Event-Log-Pane.md
##   § "What a move changes, and what it does not".
##
## Reported: "The event log completely disappears after some jumps through the
## call trace. The event log is supposed to be fully static."
##
## WHY THIS IS ASSERTED AT THE VIEWMODEL AND NOT ONLY IN THE BROWSER. The
## user-visible contract — the rows are identical either side of a jump — is
## asserted end-to-end in
## `src/tests/gui/tests/event-log/event_log_is_static_across_jumps.spec.ts`.
## This file asserts the cause rather than the symptom: that a move issues no
## request at all. That distinction matters because the symptom is
## intermittent. Re-fetching on a move only *sometimes* empties the pane — it
## takes a lost `drawId` race in `onUpdatedTable`, which drops any reply that
## is not for the newest draw — so a browser test can pass on a tree that is
## still doing the wrong thing and still vanishing for the user. The request
## count is deterministic; the race is not.
##
## Compile + run:
##   nim c -r src/frontend/viewmodel/tests/unit/test_event_log_static_across_moves.nim

import std/[json, options, unittest]

import isonim/core/async_compat
import isonim/core/[signals, computation]

import ../../backend/mock_backend
import ../../store/replay_data_store
import ../../viewmodels/event_log_vm

proc drain() =
  ## Flush whatever the reactive layer resolved synchronously. See the note in
  ## `test_event_log_marker_vm.nim` for why this is not `poll(0)`.
  drainPlatformCallbacks()

proc makeEventLogVM(): tuple[vm: EventLogVM, store: ReplayDataStore,
                             mock: MockBackendService] =
  let mock = newMockBackendService(autoRespond = true)
  let store = createReplayDataStore(mock.toBackendService())
  let vm = createEventLogVM(store)
  drain()
  (vm, store, mock)

proc eventLoadCount(mock: MockBackendService): int =
  for rc in mock.receivedCommands:
    if rc.command == "ct/event-load":
      result += 1

suite "Event Log rows are static across debugger moves":

  test "test_event_log_vm_does_not_reload_when_only_the_position_changes":
    let (vm, store, mock) = makeEventLogVM()

    # Arrive at a first position. This is the initial load, and it is the one
    # fetch the pane is entitled to.
    store.updateDebuggerPosition(100'u64, "main.nr", 10)
    drain()

    # CONTROL — without an initial load having happened, "no further loads"
    # would be trivially true and this test would pass on a pane that never
    # fetched anything at all.
    let afterFirstPosition = mock.eventLoadCount()
    check afterFirstPosition > 0

    # Now move, the way a jump through the call trace moves: a new position,
    # in a different file, at a different tick. Repeatedly, including a jump
    # backwards, because "some jumps" was the report and a backwards jump is
    # the case where a position-keyed fetch could legitimately return fewer
    # rows.
    store.updateDebuggerPosition(200'u64, "shield.nr", 26)
    drain()
    store.updateDebuggerPosition(350'u64, "shield.nr", 34)
    drain()
    store.updateDebuggerPosition(150'u64, "main.nr", 12)   # backwards
    drain()
    store.updateDebuggerPosition(0'u64, "main.nr", 1)      # back to the start
    drain()

    # THE CLAIM. Five positions, one load. The row set is a property of the
    # recording, so nothing about moving through it can require asking again.
    check mock.eventLoadCount() == afterFirstPosition

    # The same position reported twice — which happens on every move, because
    # each panel mirrors the position into the shared store and the signal
    # does not compare values — must likewise not reload.
    store.updateDebuggerPosition(0'u64, "main.nr", 1)
    drain()
    store.updateDebuggerPosition(0'u64, "main.nr", 1)
    drain()
    check mock.eventLoadCount() == afterFirstPosition

    discard vm

  test "test_event_log_vm_does_not_send_the_position_as_a_fetch_parameter":
    ## A request that names the reader's position invites a backend to answer
    ## it differently at different positions, which is the row set becoming a
    ## function of the cursor by the back door. The backend's `event_load`
    ## reads only `start`/`count`, so the parameter was dead on the wire; this
    ## keeps it that way.
    let (vm, store, mock) = makeEventLogVM()

    store.updateDebuggerPosition(4242'u64, "main.nr", 10)
    drain()

    let load = mock.findCommand("ct/event-load")
    check load.isSome

    let args = load.get().args
    check not args.hasKey("rrTicks")

    discard vm

  test "test_event_log_vm_reloads_when_paging_changes":
    ## The counterweight: this pane is not inert. Paging, sorting and
    ## searching genuinely change which rows belong on screen, and they must
    ## still reach the backend. Without this, "never reload" could be
    ## satisfied by a pane that had simply stopped working.
    let (vm, store, mock) = makeEventLogVM()

    store.updateDebuggerPosition(100'u64, "main.nr", 10)
    drain()
    let baseline = mock.eventLoadCount()
    check baseline > 0

    vm.currentPage.val = 1
    drain()
    check mock.eventLoadCount() > baseline

    let afterPaging = mock.eventLoadCount()
    vm.searchQuery.val = "socket"
    drain()
    check mock.eventLoadCount() > afterPaging

    discard store
