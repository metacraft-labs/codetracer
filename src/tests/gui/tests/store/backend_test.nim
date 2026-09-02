## test_backend.nim
##
## Unit tests for BackendService and MockBackendService.
##
## Verifies:
## - The BackendService interface works through proc-field delegation.
## - MockBackendService returns expected responses from its queue.
## - MockBackendService records every command sent.
## - MockBackendService strict mode rejects unexpected commands.
## - MockBackendService autoRespond mode returns empty objects.
## - Event simulation reaches registered handlers.
## - Disconnect sets the disconnected flag.
##
## Uses IsoNim reactive primitives (signals, createRoot) to confirm
## that the service-injection pattern integrates correctly.
##
## ## Why the command strings here are real ones
##
## This suite is about the **transport** — proc-field delegation, the
## expectation FIFO, autoRespond, the null fallthrough — and not about any
## particular command, so it used placeholder strings: `ct/step`,
## `ct/anything`, `ct/unknown`. `MockBackendService.send` now validates what it
## is handed against `VALID_DAP_COMMANDS`, because a mock that accepted any
## string is why the nine commands in `backend/dap_dialect.md` §7 each had
## passing tests over an engine that implements none of them.
##
## The placeholders are therefore replaced with real commands rather than
## silenced with `validateCommands = false`. A suite that does not care which
## command it sends can just as easily send a real one, and then it keeps
## testing the transport without also carving a hole in the validation. The
## opt-out exists (see the field's documentation) but spending it here would
## buy nothing.
##
## One case changed meaning rather than just its string: "strict mode rejects
## unexpected commands" sent `ct/unknown`, which is now invalid *as well as*
## unexpected. Since `InvalidDapCommandDefect` derives from `AssertionDefect`,
## that case would still have gone green — for the wrong reason, proving
## validation rather than strict mode. It now sends `stepIn`: a real command,
## genuinely unexpected, so the assertion measures what its name claims.
##
## Compile and run:
##   nim c -r src/frontend/viewmodel/tests/test_backend.nim

import std/json
import std/unittest
import vm_test_helpers
import isonim/core/[signals, owner]
import isonim/viewmodel
import backend/backend_service
import backend/mock_backend

# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------

suite "BackendService interface":

  test "send delegates to sendProc":
    let mock = newMockBackendService()
    mock.expect("next", %*{"direction": "forward"})
    let svc = mock.toBackendService()

    let resp = waitForTest svc.send("next", %*{"direction": "forward"})
    check resp == %*{"direction": "forward"}

  test "onEvent delegates to onEventProc":
    let mock = newMockBackendService()
    let svc = mock.toBackendService()

    var received: JsonNode
    svc.onEvent proc(event: JsonNode) =
      received = event

    mock.emitEvent(%*{"kind": "stopped"})
    check received == %*{"kind": "stopped"}

  test "disconnect delegates to disconnectProc":
    let mock = newMockBackendService()
    let svc = mock.toBackendService()
    svc.disconnect()
    check mock.disconnected == true

suite "MockBackendService":

  test "returns expected response for matching command":
    let mock = newMockBackendService()
    mock.expect("ct/load-locals", %*{"locals": [1, 2, 3]})
    let svc = mock.toBackendService()

    let resp = waitForTest svc.send("ct/load-locals", %*{})
    check resp == %*{"locals": [1, 2, 3]}

  test "consumes expectations in FIFO order":
    let mock = newMockBackendService()
    mock.expect("next", %*{"seq": 1})
    mock.expect("next", %*{"seq": 2})
    let svc = mock.toBackendService()

    let r1 = waitForTest svc.send("next", %*{})
    let r2 = waitForTest svc.send("next", %*{})
    check r1 == %*{"seq": 1}
    check r2 == %*{"seq": 2}

  test "records all received commands":
    let mock = newMockBackendService(autoRespond = true)
    let svc = mock.toBackendService()

    discard waitForTest svc.send("next", %*{"a": 1})
    discard waitForTest svc.send("ct/load-locals", %*{"b": 2})

    check mock.receivedCommands.len == 2
    check mock.receivedCommands[0].command == "next"
    check mock.receivedCommands[0].args == %*{"a": 1}
    check mock.receivedCommands[1].command == "ct/load-locals"
    check mock.receivedCommands[1].args == %*{"b": 2}

  test "strict mode rejects unexpected commands":
    let mock = newMockBackendService(strict = true)
    let svc = mock.toBackendService()

    # `stepIn` is a real DAP command with no expectation queued: unexpected,
    # but not invalid. That distinction is the point — an invalid string would
    # raise `InvalidDapCommandDefect`, which is itself an `AssertionDefect`, so
    # this case would pass while measuring validation instead of strict mode.
    #
    # On JS, the mock raises AssertionDefect synchronously from send().
    # On native, it returns a failed future that raises on read.
    # Either way, the exception should be AssertionDefect.
    expect(AssertionDefect):
      let fut = svc.send("stepIn", %*{})
      discard waitForTest fut

  test "autoRespond returns empty object for unmatched commands":
    let mock = newMockBackendService(autoRespond = true)
    let svc = mock.toBackendService()

    let resp = waitForTest svc.send("ct/load-locals", %*{})
    check resp == %*{}

  test "returns null for unmatched non-strict non-autoRespond":
    let mock = newMockBackendService()
    let svc = mock.toBackendService()

    let resp = waitForTest svc.send("ct/load-locals", %*{})
    check resp.kind == JNull

  test "emitEvent reaches multiple handlers":
    let mock = newMockBackendService()
    let svc = mock.toBackendService()

    var count = 0
    svc.onEvent proc(event: JsonNode) =
      inc count
    svc.onEvent proc(event: JsonNode) =
      inc count

    mock.emitEvent(%*{"kind": "test"})
    check count == 2

suite "IsoNim integration":

  test "BackendService works inside a reactive root with signals":
    ## Verify that the service-injection pattern composes with IsoNim
    ## signals: a signal holds the latest response, updated by a
    ## BackendService call.
    createRoot proc(dispose: proc()) =
      let mock = newMockBackendService()
      mock.expect("ct/load-locals", %*{"x": 42})
      let svc = mock.toBackendService()

      let lastResponse = createSignal[JsonNode](newJNull())

      let fut = svc.send("ct/load-locals", %*{})
      lastResponse.val = waitForTest fut

      check lastResponse.val == %*{"x": 42}
      dispose()

  test "ViewModel with injected BackendService":
    ## A minimal ViewModel-style object that holds a BackendService
    ## and a signal for the latest response.
    type
      TestViewModel = ref object of ViewModel
        svc: BackendService
        lastResponse: Signal[JsonNode]

    let mock = newMockBackendService()
    mock.expect("next", %*{"ok": true})

    var vm: TestViewModel
    createRoot proc(dispose: proc()) =
      vm = TestViewModel(
        svc: mock.toBackendService(),
        lastResponse: createSignal[JsonNode](newJNull()),
        disposeProc: dispose,
      )

    let fut = vm.svc.send("next", %*{})
    vm.lastResponse.val = waitForTest fut

    check vm.lastResponse.val == %*{"ok": true}
    vm.dispose()
