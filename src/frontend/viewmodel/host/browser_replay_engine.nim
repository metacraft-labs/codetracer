## The browser half of a replay session: a real `Worker`, and nothing else.
##
## Everything about the handshake that can be decided without a browser is
## decided elsewhere — `platform/replay_engine_vfs.nim` turns a `MemoryTrace`
## into files and `backend/replay_engine_boot.nim` says what to post and when,
## and both run in the `vm-unit` lane on both backends. This module is the
## adapter that could not be: it constructs the `Worker`, moves bytes across
## the `postMessage` boundary, and hands back the `BackendService` the
## ViewModels already speak to.
##
## It is deliberately the smallest thing that can be written here, for the
## reason `web_browser.nim`'s header gives about itself: a web instantiation
## written as one large `when defined(js)` branch would be the most important
## module in the product to check and the one nothing checks.
##
## ## The one thing that is NOT a string
##
## `worker_backend.nim` hands its transport a JSON **string**, because DAP
## traffic is JSON and the module owns the protocol rather than the wire. That
## is right for every message except `vfs-write`, whose `data` is the raw bytes
## of a trace or a source file: `vfs_write_file(path, &[u8])` is a wasm-bindgen
## import that takes a `Uint8Array`, and a structured clone of a JS array of
## numbers is not one. So this adapter parses the text back into an object
## before posting — which `worker_backend.nim`'s header already requires of any
## transport, since the engine `JSON.stringify`s what it sends — and converts
## `data` in the one place where the shape is known.

when not defined(js):
  {.error: "browser_replay_engine.nim constructs a browser `Worker`; there " &
           "is no native instantiation of it, and a native replay session " &
           "uses backend/stdio_backend.nim".}

import std/[json, jsffi]

import ../backend/backend_service
import ../backend/worker_backend
import ../backend/replay_engine_boot
import ../platform/replay_engine_vfs

type
  ReplaySessionOutcome* = object
    ## What a caller gets back, without having to ask a second question.
    service*: BackendService
      ## Nil unless `ready`. A caller holding a nil service and a reason is
      ## holding the whole truth about the session.
    ready*: bool
    failure*: string
      ## Empty unless the boot failed. Always a sentence naming what is
      ## missing, never "an error occurred".

proc jsNewWorker(url: cstring): JsObject
  {.importjs: "new Worker(#, { type: 'module' })".}
proc jsWorkerTerminate(worker: JsObject)
  {.importjs: "#.terminate()".}

proc postStructured(worker: JsObject; messageJson: cstring)
  {.importjs: """
  (function (w, text) {
    var message = JSON.parse(text);
    // `vfs-write` is the only message whose payload is bytes rather than
    // JSON. `data` arrives as an array of byte values because that is what
    // survives a Nim `JsonNode`; `vfs_write_file` wants a `Uint8Array`, and a
    // structured clone of a plain array is still a plain array on the other
    // side — where it would reach wasm-bindgen as the wrong type and fail
    // inside the engine rather than here.
    if (message && message.type === 'vfs-write' && Array.isArray(message.data)) {
      message.data = new Uint8Array(message.data);
    }
    w.postMessage(message);
  })(#, #)
  """.}

proc newBrowserReplaySession*(scriptUrl: string;
                              moduleUrls: seq[tuple[id: string, url: string]];
                              payload: ReplayVfsPayload;
                              onSettled: proc(outcome: ReplaySessionOutcome)):
    void =
  ## Boot the engine over `payload` and settle exactly once.
  ##
  ## `onSettled` is called with `ready: true` and a live `BackendService` when
  ## the engine has the whole trace and its source and has handed the worker to
  ## the DAP dispatcher, and with a reason otherwise. It is called ONCE: a
  ## caller that had to distinguish "not yet" from "never" would be holding the
  ## state machine's job.
  ##
  ## The defective-payload case never constructs a `Worker` at all —
  ## `beginReplayBoot` refuses before posting, and there is nothing to tear
  ## down.
  var settled = false
  var boot: ReplayBoot
  var messages: seq[JsonNode]
  (boot, messages) = beginReplayBoot(payload, moduleUrls)

  if boot.phase == rbpFailed:
    onSettled(ReplaySessionOutcome(ready: false, failure: boot.failure))
    return

  let worker = jsNewWorker(scriptUrl.cstring)
  var backend: WorkerBackend

  proc terminateWorker() =
    jsWorkerTerminate(worker)

  proc settle(outcome: ReplaySessionOutcome) =
    if settled: return
    settled = true
    onSettled(outcome)

  proc post(message: JsonNode) =
    postStructured(worker, ($message).cstring)

  backend = newWorkerBackend(
    postProc = proc(messageJson: string) =
      postStructured(worker, messageJson.cstring),
    terminateProc = terminateWorker)

  backend.onControl(proc(message: JsonNode) =
    # Every control message goes through the state machine, including the ones
    # it ignores. A handler that filtered first would be a second copy of the
    # machine's own opinion about which messages are progress.
    if settled: return
    let replies = boot.deliver(message)
    for reply in replies: post(reply)
    case boot.phase
    of rbpFailed:
      # The worker is torn down rather than left running: it holds an 18 MB
      # wasm instance and a trace, and a session nobody can reach is the
      # expensive kind of leak.
      terminateWorker()
      settle(ReplaySessionOutcome(ready: false, failure: boot.failure))
    of rbpReady:
      settle(ReplaySessionOutcome(
        service: backend.toBackendService(), ready: true))
    else: discard)

  # A Nim closure rather than a method call on `backend` from inside the emit:
  # `deliver` is a proc taking the object, not a JS method hanging off it, and
  # the same shape in `web_browser.nim`'s `newWorkerTransport` is why that one
  # routes through a local `receive`.
  proc receive(raw: cstring) =
    backend.deliver($raw)

  {.emit: """
  `worker`.onmessage = function (event) {
    `receive`(typeof event.data === 'string'
      ? event.data
      : JSON.stringify(event.data));
  };
  `worker`.onerror = function (event) {
    // An error event is not a message and must not be dropped. It is reported
    // THROUGH the protocol's own failure path, which is the thing that stops a
    // caller waiting for a `wasm-loaded` that will never arrive.
    `receive`(JSON.stringify({
      type: "worker-error",
      error: "the replay worker failed: " + String(event.message || event)
    }));
  };
  """.}

  for message in messages: post(message)
