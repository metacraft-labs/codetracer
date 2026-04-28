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
## Compile and run:
##   nim c -r src/frontend/viewmodel/tests/test_backend.nim

import std/[json, unittest, asyncdispatch]
import isonim/core/[signals, owner]
import isonim/viewmodel
import ../backend/backend_service
import ../backend/mock_backend

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

proc waitFor[T](f: Future[T]): T =
  ## Synchronously drain the async event loop until f completes.
  while not f.finished:
    poll(0)
  return f.read

# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------

suite "BackendService interface":

  test "send delegates to sendProc":
    let mock = newMockBackendService()
    mock.expect("ct/step", %*{"direction": "forward"})
    let svc = mock.toBackendService()

    let resp = waitFor svc.send("ct/step", %*{"direction": "forward"})
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

    let resp = waitFor svc.send("ct/load-locals", %*{})
    check resp == %*{"locals": [1, 2, 3]}

  test "consumes expectations in FIFO order":
    let mock = newMockBackendService()
    mock.expect("ct/step", %*{"seq": 1})
    mock.expect("ct/step", %*{"seq": 2})
    let svc = mock.toBackendService()

    let r1 = waitFor svc.send("ct/step", %*{})
    let r2 = waitFor svc.send("ct/step", %*{})
    check r1 == %*{"seq": 1}
    check r2 == %*{"seq": 2}

  test "records all received commands":
    let mock = newMockBackendService(autoRespond = true)
    let svc = mock.toBackendService()

    discard waitFor svc.send("ct/step", %*{"a": 1})
    discard waitFor svc.send("ct/load-locals", %*{"b": 2})

    check mock.receivedCommands.len == 2
    check mock.receivedCommands[0].command == "ct/step"
    check mock.receivedCommands[0].args == %*{"a": 1}
    check mock.receivedCommands[1].command == "ct/load-locals"
    check mock.receivedCommands[1].args == %*{"b": 2}

  test "strict mode rejects unexpected commands":
    let mock = newMockBackendService(strict = true)
    let svc = mock.toBackendService()

    let fut = svc.send("ct/unknown", %*{})
    expect(AssertionDefect):
      discard waitFor fut

  test "autoRespond returns empty object for unmatched commands":
    let mock = newMockBackendService(autoRespond = true)
    let svc = mock.toBackendService()

    let resp = waitFor svc.send("ct/anything", %*{})
    check resp == %*{}

  test "returns null for unmatched non-strict non-autoRespond":
    let mock = newMockBackendService()
    let svc = mock.toBackendService()

    let resp = waitFor svc.send("ct/anything", %*{})
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
      # In the native backend the future is already complete.
      while not fut.finished:
        poll(0)
      lastResponse.val = fut.read

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
    mock.expect("ct/step", %*{"ok": true})

    var vm: TestViewModel
    createRoot proc(dispose: proc()) =
      vm = TestViewModel(
        svc: mock.toBackendService(),
        lastResponse: createSignal[JsonNode](newJNull()),
        disposeProc: dispose,
      )

    let fut = vm.svc.send("ct/step", %*{})
    while not fut.finished:
      poll(0)
    vm.lastResponse.val = fut.read

    check vm.lastResponse.val == %*{"ok": true}
    vm.dispose()
