## The browser half of a replay session: a real `Worker`, and nothing else.
##
## Everything about the handshake that can be decided without a browser is
## decided elsewhere — `platform/replay_engine_vfs.nim` turns a `MemoryTrace`
## into files and `backend/replay_engine_boot.nim` says what to post and when,
## both green in the `vm-unit` lane on both backends. This module is the
## adapter that could not be: it constructs the `Worker`, moves bytes across
## the `postMessage` boundary, and then gets out of the way.
##
## ## What it hands back, and why it is NOT a `BackendService`
##
## The first shape of this module built a `WorkerBackend` and returned a
## `BackendService`, on the reasoning that the ViewModels speak to a
## `BackendService` and so that is what a session needs. Measuring the
## renderer says otherwise, and the difference is the whole acceptance
## criterion.
##
## Source text does not travel over the ViewModel backend at all.
## `editor_service.onCompleteMove` — the legacy service, not a ViewModel —
## reads `location.missingPath` off a `ct/complete-move` event to choose
## between the editor pane and the NO SOURCE view, and then fetches the text
## with a `CODETRACER::tab-load` IPC round trip. That event reaches it through
## `dap.receiveEvent` and the `viewsApi` fan-out, which a `BackendService`
## swap does not touch. A session whose `sendProc` reached a live engine while
## `editor_service` still listened to the dead DAP channel would step, resolve
## positions, and paint nothing.
##
## So the engine is installed one layer lower, as a peer for the IPC id the
## DAP transport already writes to: `dap.asyncSendCtRequest` ends in
## `api.ipc.send("CODETRACER::dap-raw-message", packet)`, and `newWebIpc`'s
## `respond` is exactly the hook for answering it in-page. Give that id a
## responder and the whole existing pipeline — pending-response continuations,
## `receiveEvent`, `middleware`, `editor_service`, every panel VM's store —
## starts working with no changes at all. `installTemplateHost` already
## answers `CODETRACER::tab-load` the same way, and this is that pattern
## applied to the channel next to it.
##
## ## The two things that are not a string
##
## `vfs-write`'s `data` is raw bytes. `vfs_write_file(path, &[u8])` is a
## wasm-bindgen import that takes a `Uint8Array`, and a structured clone of a
## JS array of numbers is still a plain array on the other side — where it
## would fail inside the engine rather than at the boundary. And a DAP frame
## is posted as an object, because that is what the engine's dispatcher reads
## and what `dap.nim` built.

when not defined(js):
  {.error: "browser_replay_engine.nim constructs a browser `Worker`; there " &
           "is no native instantiation of it, and a native replay session " &
           "uses the desktop DAP transport".}

import std/[json, jsffi]

import ../backend/replay_engine_boot
import ../platform/replay_engine_vfs

type
  ReplayFrameHandler* = proc(frame: JsObject)
    ## Called for every DAP response and event the engine emits after `start`.

  ReplaySessionOutcome* = object
    ## What a caller gets back, without having to ask a second question.
    ready*: bool
    failure*: string
      ## Empty unless the boot failed. Always a sentence naming what is
      ## missing, never "an error occurred".
    send*: proc(frame: JsObject)
      ## Post a DAP request frame to the engine. Nil unless `ready`.
    terminate*: proc()
      ## Tear the worker down. Nil unless `ready`.

proc jsNewWorker(url: cstring): JsObject
  {.importjs: "new Worker(#, { type: 'module' })".}
proc jsWorkerTerminate(worker: JsObject)
  {.importjs: "#.terminate()".}
proc jsWorkerPostObject(worker: JsObject; message: JsObject)
  {.importjs: "#.postMessage(#)".}

proc postBootMessage(worker: JsObject; messageJson: cstring)
  {.importjs: """
  (function (w, text) {
    var message = JSON.parse(text);
    // `vfs-write` is the only boot message whose payload is bytes rather than
    // JSON. `data` arrives as an array of byte values because that is what
    // survives a Nim `JsonNode`; `vfs_write_file` wants a `Uint8Array`, and a
    // structured clone of a plain array is still a plain array on the other
    // side.
    if (message && message.type === 'vfs-write' && Array.isArray(message.data)) {
      message.data = new Uint8Array(message.data);
    }
    w.postMessage(message);
  })(#, #)
  """.}

proc jsFrameKind(frame: JsObject): cstring
  {.importjs: "((# || {}).type || '')".}

proc jsStringify(value: JsObject): cstring {.importjs: "JSON.stringify(#)".}

proc newBrowserReplaySession*(scriptUrl: string;
                              moduleUrls: seq[tuple[id: string, url: string]];
                              payload: ReplayVfsPayload;
                              onFrame: ReplayFrameHandler;
                              onSettled: proc(outcome: ReplaySessionOutcome)):
    void =
  ## Boot the engine over `payload` and settle exactly once.
  ##
  ## `onSettled` is called with `ready: true` and a `send` once the engine
  ## holds the whole trace and its source and has handed the worker to the DAP
  ## dispatcher, and with a reason otherwise. It is called ONCE: a caller that
  ## had to distinguish "not yet" from "never" would be holding the state
  ## machine's job.
  ##
  ## A defective payload never constructs a `Worker` at all — `beginReplayBoot`
  ## refuses before posting, and there is nothing to tear down.
  var settled = false
  var boot: ReplayBoot
  var messages: seq[JsonNode]
  (boot, messages) = beginReplayBoot(payload, moduleUrls)

  if boot.phase == rbpFailed:
    onSettled(ReplaySessionOutcome(ready: false, failure: boot.failure))
    return

  let worker = jsNewWorker(scriptUrl.cstring)

  proc terminateWorker() =
    jsWorkerTerminate(worker)

  proc settle(outcome: ReplaySessionOutcome) =
    if settled: return
    settled = true
    onSettled(outcome)

  proc post(message: JsonNode) =
    postBootMessage(worker, ($message).cstring)

  proc sendFrame(frame: JsObject) =
    jsWorkerPostObject(worker, frame)

  proc receive(raw: JsObject) =
    # THE SWITCH IS THE BOOT'S OWN PHASE, not a flag set when `start` is
    # posted. That flag was the first shape and it lost the handshake's last
    # message: `wasm_start()` answers with `"ready"`, and a flag set before
    # the post routed that answer straight past the state machine into the DAP
    # handler. Measured in a browser — six VFS writes, every one acknowledged,
    # and then silence, with no error anywhere because nothing had failed.
    #
    # `rbpReady` is set BY the `"ready"` message, so gating on it hands over
    # exactly one message later than the flag did, which is the correct
    # boundary: after `wasm_start()` the engine's dispatcher owns `onmessage`
    # and everything from then on is a DAP frame.
    if boot.phase == rbpReady:
      if not onFrame.isNil: onFrame(raw)
      return
    var decoded: JsonNode
    try:
      decoded = parseJson($jsStringify(raw))
    except:
      # A BARE except: under `nim js` a malformed frame raises a `SyntaxError`
      # that `except CatchableError` does not catch, and an unhandled
      # rejection here would leave the boot waiting forever with no reason.
      decoded = nil
    if decoded.isNil:
      terminateWorker()
      settle(ReplaySessionOutcome(
        ready: false,
        failure: "the replay worker sent a message that is not JSON, so the " &
                 "engine's handshake cannot be followed"))
      return
    # A BARE STRING IS A STATUS, not a frame. `wasm_start()` posts the string
    # `"ready"` and nothing else does; `WorkerBackend.deliver` wraps exactly
    # this shape as `worker-status` for the same reason, and without the wrap
    # it decodes to a `JString`, fails the state machine's `JObject` guard,
    # and is dropped in silence.
    if decoded.kind == JString:
      decoded = %*{"type": "worker-status", "status": decoded.getStr}
    let replies = boot.deliver(decoded)
    for reply in replies:
      post(reply)
    case boot.phase
    of rbpFailed:
      # The worker holds an 18 MB wasm instance and a whole trace; a session
      # nobody can reach is the expensive kind of leak.
      terminateWorker()
      settle(ReplaySessionOutcome(ready: false, failure: boot.failure))
    of rbpReady:
      settle(ReplaySessionOutcome(
        ready: true, send: sendFrame, terminate: terminateWorker))
    else: discard

  {.emit: """
  `worker`.onmessage = function (event) {
    `receive`(event.data);
  };
  `worker`.onerror = function (event) {
    // An error event is not a message and must not be dropped. It is reported
    // THROUGH the handshake's own failure path, which is the thing that stops
    // a caller waiting for a `wasm-loaded` that will never arrive.
    `receive`({
      type: "worker-error",
      error: "the replay worker failed: " + String(event.message || event)
    });
  };
  """.}

  for message in messages: post(message)

proc replayFrameIsResponse*(frame: JsObject): bool =
  ## Whether a frame from the engine is a response rather than an event.
  ##
  ## The two go to different entry points — `onDapReceiveResponse` settles the
  ## `asyncSendCtRequest` continuation waiting on `request_seq` and then runs
  ## the legacy fan-out, `onDapReceiveEvent` only runs the fan-out — and
  ## sending a response down the event path would leave every ViewModel future
  ## unresolved until its timeout while the legacy panels updated. That
  ## asymmetry is exactly the failure `dap.nim`'s own M49 comment records.
  $jsFrameKind(frame) == "response"
