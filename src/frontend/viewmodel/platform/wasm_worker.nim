## A `WasmHost` over a worker — NS3, and the thing that turns a proven
## toolchain into something a tab runs.
##
## NS3 landed the registry (`wasm_registry.nim`) and `host/web_browser.nim`
## supplied `noWasmModules()`, because nothing in a tab could load a module.
## This is that half. The Noir compiler and tracer are published wasm modules
## with bare C ABIs (`nv_*` and `ct_*`); a worker instantiates them and this
## module speaks to it.
##
## ## The transport is INJECTED, and that is the house pattern
##
## `backend/worker_backend.nim` does exactly this for the DAP engine, for
## reasons that apply unchanged here: the protocol — sequence allocation,
## response correlation, output routing, teardown — is testable on the C
## backend when it does not import a `Worker`, and `std/jsffi` stays out of
## the import graph except where a real worker is constructed. So this module
## owns the protocol and knows nothing about how bytes reach the worker.
##
## ## One wire shape in BOTH directions, deliberately
##
## `worker_backend.nim`'s header records what the alternative costs. Its
## engine sends objects one way and JSON strings the other, plus bare strings
## for bootstrap — "that asymmetry is the transport's to absorb". A sibling
## campaign lost a day to precisely that shape: a reader that classified by
## message *type* reported a timeout over an engine that had answered.
##
## So this protocol is **JSON text in both directions, with no exceptions**,
## `deliver` takes a `string`, and there is no object path to drift from it.
## `test_wasm_worker.nim` pins that a non-JSON payload is a named failure
## rather than a silent drop, because "we only ever send text" is a claim that
## decays the moment someone adds a fast path.
##
## ## A chain of successes is not a result
##
## The same header records the other trap: an engine that answered
## `success: true` to three requests and then silently dropped everything
## after them. The equivalent here is a worker that acknowledges a run and
## never finishes it, and the shape that hides it is a future resolved on
## acknowledgement. **Nothing here resolves a run until an `exit` or a
## `failed` arrives for its sequence.** The suite asserts the negative: a
## worker that answers every message and sends no exit leaves the run
## unsettled.

import std/[json, tables]

import ./outcome
import ./process
import ./wasm_registry

export wasm_registry

type
  WasmWorkerTransport* {.requiresInit.} = ref object
    ## How bytes reach the worker. `{.requiresInit.}` so a transport added
    ## here fails the build at every construction site rather than defaulting
    ## to `nil`.
    send*: proc(message: string)
      ## Main -> worker. Always JSON text; see the header.
    terminateWorker*: proc()
      ## Abrupt and complete. There is no cooperative stop, which is why the
      ## web profile lacks `capProcessGracefulSignal`.

  PendingRun = ref object
    handle: ProcessHandle
    onOutput: proc(chunk: ProcessOutputChunk)
    onExit: proc(exit: ProcessExit)
    collect: bool
      ## `run` collects output and resolves with it; `start` streams it and
      ## resolved its handle long ago.
    stdoutText: string
    stderrText: string
    settle: proc(outcome: PlatformOutcome[ProcessRunResult])
      ## Nil for a `start`, which has nothing left to settle.

  WasmWorker* = ref object
    registry*: WasmRegistry
    transport: WasmWorkerTransport
    pending: Table[int, PendingRun]
    bySeq: Table[string, int]
    nextSeq: int
    stopped: bool
    stopReason: string

const
  workerStoppedMessage* =
    "the wasm worker was terminated, so this run establishes nothing"
  workerProtocolPrefix* = "the wasm worker sent something this protocol does not define: "

proc newWasmWorker*(registry: WasmRegistry;
                    transport: WasmWorkerTransport): WasmWorker =
  WasmWorker(registry: registry, transport: transport,
             pending: initTable[int, PendingRun](),
             bySeq: initTable[string, int](),
             nextSeq: 0, stopped: false, stopReason: "")

proc finish(worker: WasmWorker; seq: int; exit: ProcessExit;
            failure: string) =
  ## Settle one run, exactly once, and forget it.
  if seq notin worker.pending: return
  let run = worker.pending[seq]
  worker.pending.del(seq)
  worker.bySeq.del($run.handle)

  if not run.onExit.isNil:
    run.onExit(exit)
  if run.settle.isNil: return

  if failure.len > 0:
    run.settle(failed[ProcessRunResult](pkFailed, failure))
  else:
    run.settle(succeeded(ProcessRunResult(
      exit: exit, stdout: run.stdoutText, stderr: run.stderrText)))

proc deliver*(worker: WasmWorker; raw: string) =
  ## One message from the worker, already rendered as text by the transport.
  ##
  ## Every branch either settles a run or is a named failure. There is no
  ## `else: discard`, because a dropped message is how a run hangs forever
  ## while every individual exchange looks fine.
  var message: JsonNode
  try:
    message = parseJson(raw)
  except:
    # A BARE `except`, and not `except CatchableError`, because the two
    # backends do not agree on what a parse failure IS. On C, `parseJson`
    # raises `JsonParsingError`, a `CatchableError`. On JS it defers to V8's
    # `JSON.parse`, which throws a raw `SyntaxError` that `except
    # CatchableError` does NOT catch — so the narrow form handled a
    # non-JSON payload correctly on C and crashed the process on JS, which is
    # the backend the renderer ships on. Found by `vm-unit-js`, which is what
    # that lane is for.
    # A payload that is not JSON is the asymmetry hazard arriving. It is
    # reported against every outstanding run rather than swallowed: the
    # alternative is a worker that has clearly malfunctioned and a caller
    # that waits forever.
    let detail = workerProtocolPrefix & "not JSON"
    var seqs: seq[int] = @[]
    for s in worker.pending.keys: seqs.add s
    for s in seqs:
      worker.finish(s, ProcessExit(exitCode: 1, signalled: false), detail)
    return

  if message.kind != JObject or not message.hasKey("seq") or
     not message.hasKey("kind"):
    let detail = workerProtocolPrefix & "no seq or no kind"
    var seqs: seq[int] = @[]
    for s in worker.pending.keys: seqs.add s
    for s in seqs:
      worker.finish(s, ProcessExit(exitCode: 1, signalled: false), detail)
    return

  let seq = message["seq"].getInt
  let kind = message["kind"].getStr
  if seq notin worker.pending:
    # A message for a run that already settled. Ignored deliberately: a
    # terminate races an in-flight exit, and settling twice is worse.
    return

  let run = worker.pending[seq]
  case kind
  of "output":
    let text = message{"text"}.getStr
    let stream = if message{"stream"}.getStr == "stderr": psStderr else: psStdout
    if run.collect:
      if stream == psStderr: run.stderrText.add text
      else: run.stdoutText.add text
    if not run.onOutput.isNil:
      run.onOutput(ProcessOutputChunk(stream: stream, text: text))
  of "exit":
    worker.finish(seq, ProcessExit(
      exitCode: message{"exitCode"}.getInt,
      signalled: message{"signalled"}.getBool,
      signalName: message{"signalName"}.getStr), "")
  of "failed":
    worker.finish(seq, ProcessExit(exitCode: 1, signalled: false),
                  message{"message"}.getStr)
  else:
    worker.finish(seq, ProcessExit(exitCode: 1, signalled: false),
                  workerProtocolPrefix & kind)

proc post(worker: WasmWorker; seq: int; module: WasmModuleId;
          spec: ProcessSpec) =
  var args = newJArray()
  for a in spec.args: args.add %a
  worker.transport.send($(%*{
    "seq": seq,
    "kind": "start",
    "module": $module,
    "command": spec.command,
    "args": args,
    "workingDir": spec.workingDir,
    "stdin": spec.stdinText}))

proc beginRun(worker: WasmWorker; module: WasmModuleId; spec: ProcessSpec;
              onOutput: proc(chunk: ProcessOutputChunk);
              onExit: proc(exit: ProcessExit);
              collect: bool;
              settle: proc(outcome: PlatformOutcome[ProcessRunResult])
             ): ProcessHandle =
  inc worker.nextSeq
  let seq = worker.nextSeq
  let handle = ProcessHandle("wasm-" & $seq)
  worker.pending[seq] = PendingRun(
    handle: handle, onOutput: onOutput, onExit: onExit, collect: collect,
    stdoutText: "", stderrText: "", settle: settle)
  worker.bySeq[$handle] = seq
  # Registered BEFORE posting, for the reason `worker_backend.send` states:
  # a transport that delivers synchronously — every in-process test double —
  # would otherwise answer a run whose slot does not exist yet.
  worker.post(seq, module, spec)
  handle

proc runOnWorker*(worker: WasmWorker; module: WasmModuleId; spec: ProcessSpec
                 ): PlatformFuture[PlatformOutcome[ProcessRunResult]] =
  if worker.stopped:
    return resolvedErr[ProcessRunResult](pkCancelled, workerStoppedMessage)

  when defined(js):
    var captured: proc(outcome: PlatformOutcome[ProcessRunResult])
    result = newPromise(proc(resolve: proc(o: PlatformOutcome[ProcessRunResult])) =
      captured = resolve)
    discard worker.beginRun(module, spec, nil, nil, true, captured)
  else:
    let future = newFuture[PlatformOutcome[ProcessRunResult]]("runOnWorker")
    proc settle(o: PlatformOutcome[ProcessRunResult]) =
      if not future.finished: future.complete(o)
    discard worker.beginRun(module, spec, nil, nil, true, settle)
    result = future

proc startOnWorker*(worker: WasmWorker; module: WasmModuleId;
                    spec: ProcessSpec;
                    onOutput: proc(chunk: ProcessOutputChunk);
                    onExit: proc(exit: ProcessExit)
                   ): PlatformFuture[PlatformOutcome[ProcessHandle]] =
  if worker.stopped:
    return resolvedErr[ProcessHandle](pkCancelled, workerStoppedMessage)
  let handle = worker.beginRun(module, spec, onOutput, onExit, false, nil)
  resolvedOk(handle)

proc stopAll*(worker: WasmWorker): PlatformFuture[PlatformOutcome[Nothing]] =
  ## `worker.terminate()`: abrupt, complete, and every outstanding run is
  ## reported as SIGNALLED rather than as a clean exit.
  ##
  ## `process.nim`'s `ProcessExit.signalled` says why that distinction is
  ## load-bearing: "a cancelled run establishes nothing, and callers that
  ## conflate the two report a cancellation as a failure". A terminate that
  ## settled its runs with exitCode 0 would report a killed compile as a
  ## successful one.
  worker.stopped = true
  worker.transport.terminateWorker()
  var seqs: seq[int] = @[]
  for s in worker.pending.keys: seqs.add s
  for s in seqs:
    worker.finish(s, ProcessExit(
      exitCode: 1, signalled: true, signalName: "terminate"),
      workerStoppedMessage)
  resolvedOk()

proc runIsActive*(worker: WasmWorker; handle: ProcessHandle): bool =
  worker.bySeq.hasKey($handle)

proc asWasmHost*(worker: WasmWorker): WasmHost =
  ## The four facade operations, over this worker.
  ##
  ## Built from an existing `WasmWorker` rather than constructed with the
  ## registry and transport, because the caller needs the worker itself: the
  ## transport has to route incoming messages to `deliver`, and a constructor
  ## that hid the worker would force either a back-reference field on
  ## `WasmHost` — which is the facade's shape and must not grow a
  ## worker-specific one — or a second lookup.
  WasmHost(
    registry: worker.registry,
    run: proc(module: WasmModuleId; spec: ProcessSpec): auto =
      worker.runOnWorker(module, spec),
    start: proc(module: WasmModuleId; spec: ProcessSpec;
                onOutput: proc(chunk: ProcessOutputChunk);
                onExit: proc(exit: ProcessExit)): auto =
      worker.startOnWorker(module, spec, onOutput, onExit),
    terminate: proc(handle: ProcessHandle): auto =
      # The handle is accepted and ignored: a WebWorker is terminated whole,
      # so stopping one run stops them all. Refusing for an unknown handle
      # would imply a per-run granularity the platform does not have.
      worker.stopAll(),
    isRunning: proc(handle: ProcessHandle): auto =
      resolvedOk(worker.runIsActive(handle)))
