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
##
## ## SESSIONS — the run that has not exited yet
##
## Every verb above describes a compiler: ask once, answer once, done. That is
## fatal for a development environment, where a node must survive between user
## actions and hold the world state they accumulate. So this module grew one
## new outbound verb and one refinement of an existing one:
##
## * `sendToSession` posts a `kind: "input"` addressed at a *running* run's
##   sequence. **It carries its own sequence** and settles on the worker's
##   acknowledgement — accepted, or refused with a named fault. The session's
##   own traffic continues to arrive as `output` on the session's sequence.
##   The two sequences exist because a `failed` FINISHES a run: a refusal
##   riding the session's sequence would destroy the session it was merely
##   declining to accept, so backpressure would be indistinguishable from
##   death.
## * `closeSession` posts `kind: "close"` and is the deliberate end.
##   `stopAll` remains the abrupt one and still kills the whole worker, which
##   is the only granularity a `Worker` has.
##
## There is no session id and no session table here. A session's address is
## the sequence of the `start` that opened it, so correlation, streaming and
## teardown are the ones this file already had — exercised by more traffic
## rather than duplicated for a second kind of thing.
##
## **A session's answer is a stream, not a response.** Nothing here pairs a
## reply to an `input`, deliberately. That belongs to whatever protocol rides
## inside the text, and `backend/worker_backend.nim` is already this
## repository's request/response correlator over exactly this shape: an
## injected `postProc(string)` and a `deliver(string)`. A session whose payload
## is DAP is correlated by pointing those two at `sendToSession` and the
## session's output, with no second correlator in the tree. What that module
## is NOT is a replacement for this one — it drives one worker as one DAP
## session and ends it by terminating the worker, so it cannot express two
## sessions in a worker and cannot carry a payload that is not DAP.
##
## ## Sequence 0 is the WORKER, not a run — and a `failed` on it is its death
##
## `configureSeq` is 0 and `beginRun` never allocates it, so a message on
## sequence 0 belongs to no run. Its `output`/`exit` are the acknowledgement of
## `configure` and are discarded, exactly as before. Its `failed` is not:
## `host/web_browser.nim`'s transport synthesises precisely that shape from
## `worker.onerror`, and it is the only notice a page gets that its worker has
## died. That message used to be **dropped** here — sequence 0 was never in
## `pending`, so `deliver` returned early and every outstanding run waited
## forever, which is the exact failure this module's header exists to prevent,
## arriving through the one path nothing tested. It now fails every run by
## name. Sessions turned it from theoretical into urgent: a compile is in
## flight for seconds, a session for as long as the tab is open.

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
  workerDiedPrefix* =
    "the wasm worker itself failed, so this run establishes nothing: "

  faultNotDelivered* = "not-delivered"
    ## This deployment ships no such module.
  faultNotServed* = "not-served"
    ## A URL was declared and the server does not have it: a broken deploy.
  faultBroken* = "broken"
    ## The bytes arrived and are not a usable module.
  faultNoSession* = "no-session"
    ## The sequence addressed is not a live session here.
  faultSessionBusy* = "session-busy"
    ## The session is alive and its inbox is full. Backpressure, not death.

proc kindForFault(fault: string): PlatformErrorKind =
  ## The worker's `fault` field, as an error kind a caller can BRANCH on.
  ##
  ## The field has carried three values since the module-load faults were
  ## split into three sentences, and **nothing on this side has ever read
  ## it** — a vocabulary designed for branching that no branch consumed. So
  ## the mapping is chosen here rather than inherited, and the point of it is
  ## that the five faults do not collapse:
  ##
  ## * `not-delivered` is `pkNotFound`. Nothing is broken; the deployment is
  ##   smaller than the product, and `outcome.nim` reserves this kind for a
  ##   thing that is simply not there.
  ## * `not-served` is `pkTransport`. The bytes did not arrive. It is a fact
  ##   about the wire and the fix is in the publish directory, not the module.
  ## * `broken` is `pkFailed`. The only one of the three that is the module's
  ##   own fault.
  ## * `no-session` is `pkNotFound` — a stale handle, addressing something
  ##   that is not there. Same kind as `not-delivered` and a different
  ##   sentence, which is the right trade: a caller branches on "absent" and
  ##   reads the message to learn what was absent.
  ## * `session-busy` is `pkQuotaExceeded`. A bounded buffer is full. It is
  ##   the one fault in the set that is TEMPORARY, and giving it a kind of its
  ##   own is what lets a caller retry this and only this.
  ##
  ## An unknown fault is `pkFailed` rather than a raise: the worker may be a
  ## newer build than the page, and a message this side cannot classify is
  ## still a failure it must report.
  case fault
  of faultNotDelivered: pkNotFound
  of faultNotServed: pkTransport
  of faultBroken: pkFailed
  of faultNoSession: pkNotFound
  of faultSessionBusy: pkQuotaExceeded
  else: pkFailed

proc newWasmWorker*(registry: WasmRegistry;
                    transport: WasmWorkerTransport): WasmWorker =
  WasmWorker(registry: registry, transport: transport,
             pending: initTable[int, PendingRun](),
             bySeq: initTable[string, int](),
             nextSeq: 0, stopped: false, stopReason: "")

const configureSeq* = 0
  ## The sequence number the `configure` handshake uses, and the one sequence
  ## that never names a run.
  ##
  ## Safe BY CONSTRUCTION rather than by convention: `beginRun` increments
  ## `nextSeq` *before* reading it, so the first real run is sequence 1 and 0
  ## is never allocated to one. The worker echoes an `output` and an `exit` for
  ## whatever sequence it was configured with, and `deliver` discards both.
  ##
  ## Declared here rather than beside `configure` because `deliver` now reads
  ## it: a `failed` on this sequence is the WORKER's failure and reaches every
  ## run. See the module header.

proc finish(worker: WasmWorker; seq: int; exit: ProcessExit;
            failure: string; kind = pkFailed; detail = "") =
  ## Settle one run, exactly once, and forget it.
  if seq notin worker.pending: return
  let run = worker.pending[seq]
  worker.pending.del(seq)
  worker.bySeq.del($run.handle)

  # A `start` HAS NOWHERE TO PUT A FAILURE, and that was a silent drop.
  #
  # `runOnWorker` passes a `settle` and gets the failure text as a
  # `PlatformError.message`. `startOnWorker` passes `settle: nil` — its handle
  # resolved long ago — so every branch below that carries a `failure` ended
  # at `run.onExit(ProcessExit(exitCode: 1))` and threw the message away. The
  # three module-load faults `wasm_worker_browser.js` composes are exactly
  # such messages ("this deployment does not ship the `noir-tracer` wasm
  # module…"), and a streaming caller saw a bare exit code 1 instead of any of
  # them: the same shrug for a module that was never published, one that the
  # server does not serve, and one that is broken — which is precisely the
  # conflation that file's own header says cost a sibling campaign hours.
  #
  # It goes to STDERR rather than to a new callback because that is what it
  # is: a process that failed wrote to stderr and exited non-zero, and every
  # caller of `start` already handles both. A fourth `WasmHost` operation
  # would have to be added to four hosts and every test that builds one, to
  # carry information the existing channel carries correctly.
  if failure.len > 0 and run.settle.isNil and not run.onOutput.isNil:
    run.onOutput(ProcessOutputChunk(stream: psStderr, text: failure))

  if not run.onExit.isNil:
    run.onExit(exit)
  if run.settle.isNil: return

  if failure.len > 0:
    run.settle(failed[ProcessRunResult](kind, failure, detail))
  else:
    run.settle(succeeded(ProcessRunResult(
      exit: exit, stdout: run.stdoutText, stderr: run.stderrText)))

proc finishAll(worker: WasmWorker; exit: ProcessExit; failure: string;
               kind = pkFailed; detail = "") =
  ## Settle EVERY outstanding run with the same failure.
  ##
  ## The three places `deliver` needed this had written the loop out three
  ## times, and a fourth was about to: `finish` mutates `pending`, so the keys
  ## must be snapshotted before iterating or the third caller gets an
  ## iteration-while-modifying bug the first two happened not to.
  var seqs: seq[int] = @[]
  for s in worker.pending.keys: seqs.add s
  for s in seqs:
    worker.finish(s, exit, failure, kind, detail)

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
    worker.finishAll(ProcessExit(exitCode: 1, signalled: false),
                     workerProtocolPrefix & "not JSON")
    return

  if message.kind != JObject or not message.hasKey("seq") or
     not message.hasKey("kind"):
    worker.finishAll(ProcessExit(exitCode: 1, signalled: false),
                     workerProtocolPrefix & "no seq or no kind")
    return

  let seq = message["seq"].getInt
  let kind = message["kind"].getStr

  if seq == configureSeq:
    # SEQUENCE 0 IS THE WORKER SPEAKING ABOUT ITSELF, not about a run — see
    # the header. `configure`'s `output`/`exit` are discarded here exactly as
    # they were when this was an early return, and for the same reason.
    #
    # A `failed` is the one case that is not noise, and dropping it was a real
    # defect: `newWorkerTransport` turns `worker.onerror` into
    # `{seq: 0, kind: "failed"}` because a worker-level error is not a message
    # and "must not be silently dropped: the protocol's own failure path is the
    # thing that stops a caller waiting forever". It reached here and was
    # silently dropped, so a dead worker left every run pending for the life of
    # the tab. A one-shot compile is exposed to that for seconds; a session is
    # exposed for as long as the page is open, which is why this is fixed here
    # rather than noted.
    if kind == "failed":
      worker.stopped = true
      worker.stopReason = message{"message"}.getStr
      worker.finishAll(
        ProcessExit(exitCode: 1, signalled: true, signalName: "worker-error"),
        workerDiedPrefix & worker.stopReason,
        kindForFault(message{"fault"}.getStr),
        message{"fault"}.getStr)
    return

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
    # `fault` reaches the caller for the first time here. It has been on the
    # wire since the module-load faults were split into three sentences and
    # had ZERO readers on this side — the vocabulary existed to be branched on
    # and nothing branched. `kindForFault` says what each one means; the raw
    # token rides in `detail`, which `outcome.nim` reserves for exactly this
    # ("the originating text survives in `detail` for logs").
    let fault = message{"fault"}.getStr
    worker.finish(seq, ProcessExit(exitCode: 1, signalled: false),
                  message{"message"}.getStr, kindForFault(fault), fault)
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

proc configure*(worker: WasmWorker;
                moduleUrls: seq[tuple[id: string, url: string]]) =
  ## Tell the worker where its wasm modules are, before any run.
  ##
  ## THE HANDSHAKE THAT WAS MISSING. `wasm_worker_browser.js` has always
  ## handled a `configure` message — it reads `moduleUrls` from it and refuses
  ## with "no url declared for wasm module <id>" without one — and nothing in
  ## Nim ever sent one. So a deployment could place both modules, serve them
  ## correctly, start a worker, and still fail every run, because the worker
  ## was never told the two URLs it needed. That is the same class of defect as
  ## a published engine no page references: every part present, working, and
  ## unconnected.
  ##
  ## Sent unconditionally at construction rather than lazily before the first
  ## run. A lazy handshake would have to be re-sent after a `terminate`, and
  ## the cost here is one small message on a worker that was just created
  ## anyway.
  var urls = newJObject()
  for entry in moduleUrls:
    urls[entry.id] = %entry.url
  worker.transport.send($(%*{
    "seq": configureSeq,
    "kind": "configure",
    "moduleUrls": urls}))

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
  ## Start a run and stream it. **This is also how a session is opened**, and
  ## nothing about the message changes: whether the run ends in the same turn
  ## or lives until the tab closes is the worker's decision, taken from the
  ## subcommand. The handle it returns is the session's address — pass it to
  ## `sendToSession` and `closeSession`.
  ##
  ## The handle resolves WITHOUT waiting for the worker, which is correct and
  ## worth stating for a session: holding it is not evidence that a session
  ## opened. A service says so itself, on its own stream, as its first output;
  ## a caller that treats the handle as the confirmation has the
  ## "acknowledgement is not a result" shape again, one layer up.
  if worker.stopped:
    return resolvedErr[ProcessHandle](pkCancelled, workerStoppedMessage)
  let handle = worker.beginRun(module, spec, onOutput, onExit, false, nil)
  resolvedOk(handle)

# ---------------------------------------------------------------------------
# Sessions
# ---------------------------------------------------------------------------

proc sessionSeqOf(worker: WasmWorker; session: ProcessHandle): int =
  ## The sequence a live handle names, or -1.
  if worker.bySeq.hasKey($session): worker.bySeq[$session] else: -1

proc beginControl(worker: WasmWorker; payload: JsonNode
                 ): PlatformFuture[PlatformOutcome[Nothing]] =
  ## Post one message that is ABOUT a run rather than a run of its own, and
  ## settle when the worker acknowledges or refuses it.
  ##
  ## It allocates a sequence and a `pending` slot exactly like `beginRun`, so
  ## the acknowledgement is correlated by the machinery that already exists —
  ## `deliver` needs no arm for it, and `stopAll` strands it no more than it
  ## strands a compile. It is deliberately NOT registered in `bySeq`: a
  ## delivery is not a process and must not answer `runIsActive`.
  ##
  ## The value is `Nothing` and that is the honest type. This future says the
  ## worker took the message, and nothing whatever about what the session then
  ## did with it — those answers arrive on the session's own stream. Returning
  ## anything richer here would be the "resolved on acknowledgement" shape the
  ## module header forbids, wearing a result's clothes.
  inc worker.nextSeq
  let s = worker.nextSeq
  payload["seq"] = %s
  let handle = ProcessHandle("wasm-ctl-" & $s)

  proc slot(settle: proc(outcome: PlatformOutcome[Nothing])) =
    worker.pending[s] = PendingRun(
      handle: handle, onOutput: nil, onExit: nil, collect: false,
      stdoutText: "", stderrText: "",
      settle: proc(outcome: PlatformOutcome[ProcessRunResult]) =
        if outcome.ok: settle(succeeded())
        else: settle(failed[Nothing](outcome.error)))

  when defined(js):
    var captured: proc(outcome: PlatformOutcome[Nothing])
    result = newPromise(proc(resolve: proc(o: PlatformOutcome[Nothing])) =
      captured = resolve)
    slot(captured)
  else:
    let future = newFuture[PlatformOutcome[Nothing]]("beginControl")
    slot(proc(outcome: PlatformOutcome[Nothing]) =
      if not future.finished: future.complete(outcome))
    result = future

  # After the slot exists, for `beginRun`'s reason: a transport that delivers
  # synchronously would otherwise acknowledge a message with no future.
  worker.transport.send($payload)

proc sendToSession*(worker: WasmWorker; session: ProcessHandle; text: string
                   ): PlatformFuture[PlatformOutcome[Nothing]] =
  ## Hand one message to a running session.
  ##
  ## THE VERB THAT WAS MISSING. Everything else in this file is main->worker
  ## once, at the start of a run; this is main->worker in the middle of one,
  ## and without it a `start` that never exits is a job nobody can talk to.
  ##
  ## Resolves when the worker has ACCEPTED the message. A refusal is named:
  ## `pkNotFound` if the handle no longer addresses a live session,
  ## `pkQuotaExceeded` if the session's inbox is full — which is backpressure
  ## and is retryable, and is the reason this is not fire-and-forget. A caller
  ## that ignored the result would be free to overrun a session it cannot see.
  ##
  ## Ordering is FIFO **per session**, guaranteed by the worker: two messages
  ## sent back to back are handled in that order even if the first is slow.
  ## Across sessions nothing is ordered, and nothing needs to be.
  if worker.stopped:
    return resolvedErr[Nothing](pkCancelled, workerStoppedMessage)
  let target = worker.sessionSeqOf(session)
  if target < 0:
    # Answered here rather than by a round trip, because this side already
    # knows: `finish` removed the handle when the session exited. The worker
    # answers the same way for a handle this side has not caught up with yet,
    # so the two agree; this one is merely faster and does not require a live
    # worker to produce a correct refusal.
    return resolvedErr[Nothing](pkNotFound,
      "there is no live wasm session `" & $session & "` to send to",
      faultNoSession)
  worker.beginControl(%*{
    "kind": "input",
    "session": target,
    "text": text})

proc closeSession*(worker: WasmWorker; session: ProcessHandle
                  ): PlatformFuture[PlatformOutcome[Nothing]] =
  ## End one session deliberately, leaving the worker and every other session
  ## running.
  ##
  ## Distinct from `stopAll`, which is `worker.terminate()` — abrupt, complete,
  ## and it reports every outstanding run as SIGNALLED. That is the right verb
  ## for "stop everything" and the wrong one for "I am done with this node":
  ## it would take a concurrent compile with it, and it would settle the
  ## session as killed rather than as finished. This one lets the session exit
  ## with code 0, which is what `onExit` sees and what `succeededExit` reads.
  if worker.stopped:
    return resolvedErr[Nothing](pkCancelled, workerStoppedMessage)
  let target = worker.sessionSeqOf(session)
  if target < 0:
    return resolvedErr[Nothing](pkNotFound,
      "there is no live wasm session `" & $session & "` to close",
      faultNoSession)
  worker.beginControl(%*{
    "kind": "close",
    "session": target})

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
  worker.finishAll(
    ProcessExit(exitCode: 1, signalled: true, signalName: "terminate"),
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
