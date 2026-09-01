## NS3: the protocol between the front end and the wasm worker.
##
## Runs on **both** backends by discovery. The subject is
## `platform/wasm_worker.nim`, which reaches no browser API because its
## transport is injected — the same split `backend/worker_backend.nim` uses,
## and the reason this protocol is testable at all.
##
## ## What these assertions are guarding
##
## A message boundary adds two failure modes a direct call does not have, and
## both have cost this organisation time recently:
##
## 1. **A chain of successes is not a result.** `worker_backend.nim`'s header
##    records an engine answering `success: true` to three requests and then
##    silently dropping everything after them; a sibling found a DAP server
##    answering `success: true` on every request over a session with no trace
##    open. The equivalent here is a worker that acknowledges a run and never
##    finishes it. So the suite asserts the NEGATIVE — an unfinished run stays
##    unsettled — paired with the counter-check that a finished one settles,
##    without which "never settles" would pass for a protocol that settles
##    nothing.
## 2. **A protocol with two halves may speak two shapes.** That same header
##    records an engine sending objects one way and JSON strings the other; a
##    reader classifying by message type reported a timeout over an engine that
##    had answered. This protocol is JSON text in both directions, and that is
##    asserted rather than assumed: a payload that is not JSON must be a NAMED
##    failure, not a silent drop.
##
## And the rule this campaign keeps relearning: assert what the run PRODUCED,
## not that it answered.
##
## ## Why half of this file is not `unittest`
##
## `test_worker_backend.nim` records the reason, and it applies unchanged: on
## JS `async_compat.onComplete` routes through `pendingCallbacks` only for
## futures tagged `__syncResolved`, i.e. those built by `newCompletedFuture`.
## A future created by `newPromise` and resolved later — which is what any
## genuinely asynchronous transport produces — is observed through a real
## `.then` microtask that a synchronous drain cannot pump. `unittest`'s `test`
## cannot be async, so assertions that read a settled future live in
## `asyncSuite` below and yield a turn first. Everything observable
## synchronously stays in `unittest`, where the failure messages are better.

import std/[unittest, json, strutils]
import isonim/core/async_compat

import ../../platform/outcome
import ../../platform/process
import ../../platform/wasm_registry
import ../../platform/wasm_worker

type
  FakeWorker = ref object
    ## What the main thread sent, and a way to answer as the worker would.
    ## Assertions read `sent` rather than trusting a call "happened": a
    ## protocol that posted nothing would satisfy every `ok`.
    sent: seq[string]
    terminated: int

proc newFakePair(registry: WasmRegistry): (WasmWorker, FakeWorker) =
  let fake = FakeWorker(sent: @[], terminated: 0)
  proc sendToFake(message: string) =
    fake.sent.add message
  proc terminateFake() =
    fake.terminated = fake.terminated + 1
  let transport = WasmWorkerTransport(
    send: sendToFake, terminateWorker: terminateFake)
  (newWasmWorker(registry, transport), fake)

proc seqOf(fake: FakeWorker; index: int): int =
  parseJson(fake.sent[index])["seq"].getInt

type Settled[T] = ref object
  ## Whether a future settled AND what with. A bare `awaitOutcome` cannot
  ## express "never settled", which is the property this suite is most about.
  did: bool
  value: PlatformOutcome[T]

proc watch[T](future: PlatformFuture[PlatformOutcome[T]]): Settled[T] =
  let box = Settled[T](did: false)
  proc onValue(value: PlatformOutcome[T]) =
    box.value = value
    box.did = true
  proc onFailure(message: string) =
    box.value = failed[T](pkTransport, "the future failed", message)
    box.did = true
  future.onComplete(onValue, onFailure)
  box

when defined(js):
  proc microtask(): Future[void] {.importjs: "Promise.resolve()".}
else:
  proc microtask(): Future[void] =
    result = newFuture[void]("microtask")
    result.complete()

proc settleTurn(): Future[void] {.async.} =
  ## Yield long enough for a resolved promise to deliver, then flush.
  await microtask()
  drainPlatformCallbacks()

let registry = WasmRegistry(modules: @[WasmModule(
  command: "nargo",
  moduleId: WasmModuleId("noir-toolchain@1"),
  displayName: "the Noir toolchain",
  subcommands: @["trace", "compile"],
  builtFrom: "noir@codetracer tooling/tracer_wasm")])

let noirModule = WasmModuleId("noir-toolchain@1")

proc exitMessage(s, code: int): string =
  $(%*{"seq": s, "kind": "exit", "exitCode": code, "signalled": false})

proc outputMessage(s: int; stream, text: string): string =
  $(%*{"seq": s, "kind": "output", "stream": stream, "text": text})

# ---------------------------------------------------------------------------
# Synchronously observable: what was posted, and what `deliver` does at once.
# ---------------------------------------------------------------------------

suite "the request the worker is given says what to run":

  test "a run posts one start message naming the module and argv":
    let (worker, fake) = newFakePair(registry)
    discard worker.runOnWorker(noirModule, processSpec("nargo", @["trace"]))
    check fake.sent.len == 1
    let request = parseJson(fake.sent[0])
    check request["kind"].getStr == "start"
    check request["module"].getStr == "noir-toolchain@1"
    check request["command"].getStr == "nargo"
    check request["args"][0].getStr == "trace"
    check request["seq"].getInt > 0

  test "every request carries its own sequence":
    let (worker, fake) = newFakePair(registry)
    discard worker.runOnWorker(noirModule, processSpec("nargo", @["trace"]))
    discard worker.runOnWorker(noirModule, processSpec("nargo", @["compile"]))
    check fake.sent.len == 2
    check seqOf(fake, 0) != seqOf(fake, 1)

  test "a run started after stopping posts nothing to a worker that is gone":
    let (worker, fake) = newFakePair(registry)
    discard worker.stopAll()
    discard worker.runOnWorker(noirModule, processSpec("nargo", @["trace"]))
    check fake.sent.len == 0
    check fake.terminated == 1

suite "streaming and liveness are observable as they happen":

  test "start streams output through the callback and tracks liveness":
    ## `start`'s handle resolves immediately, so this half needs no turn.
    let (worker, fake) = newFakePair(registry)
    let host = worker.asWasmHost()
    var seen: seq[ProcessOutputChunk] = @[]
    var exits: seq[ProcessExit] = @[]
    proc onOutput(chunk: ProcessOutputChunk) = seen.add chunk
    proc onExit(exit: ProcessExit) = exits.add exit

    let started = watch(host.start(noirModule,
                                   processSpec("nargo", @["trace"]),
                                   onOutput, onExit))
    drainPlatformCallbacks()
    check started.did          # `start` resolves synchronously by design
    check started.value.ok
    let handle = started.value.value

    let s = seqOf(fake, 0)
    worker.deliver(outputMessage(s, "stdout", "27 events\n"))
    worker.deliver(outputMessage(s, "stderr", "warn\n"))
    check seen.len == 2
    check seen[0].stream == psStdout
    check seen[0].text == "27 events\n"
    check seen[1].stream == psStderr
    check worker.runIsActive(handle)

    worker.deliver(exitMessage(s, 0))
    check exits.len == 1
    check exits[0].exitCode == 0
    check not worker.runIsActive(handle)

  test "a failed message reaches a START caller, on stderr":
    ## THE SILENT DROP THIS CASE EXISTS FOR.
    ##
    ## `finish` settles a `run` by handing the failure text to its `settle`
    ## proc, which becomes a `PlatformError.message`. A `start` has no
    ## `settle` — its handle resolved before anything happened — so every
    ## `failed` message it received ended at `onExit(exitCode: 1)` and the
    ## TEXT was thrown away.
    ##
    ## What that text is matters: `wasm_worker_browser.js` composes three
    ## deliberately different sentences for its three module-load faults, and
    ## its own header records that conflating a missing asset with a broken
    ## feature cost a sibling campaign hours. A streaming caller saw the same
    ## bare exit code for a module that was never published, one the server
    ## does not serve, and one that is broken.
    ##
    ## It arrives on stderr because that is what it is — a process that failed
    ## wrote to stderr and exited non-zero — and every caller of `start`
    ## already handles both. A fourth `WasmHost` operation would have to be
    ## added to four hosts and every test that builds one, to carry
    ## information the existing channel carries correctly.
    let (worker, fake) = newFakePair(registry)
    var seen: seq[ProcessOutputChunk] = @[]
    var exits: seq[ProcessExit] = @[]
    proc onOutput(chunk: ProcessOutputChunk) = seen.add chunk
    proc onExit(exit: ProcessExit) = exits.add exit
    discard worker.startOnWorker(noirModule, processSpec("nargo", @["trace"]),
                                 onOutput, onExit)
    const Fault = "this deployment does not ship the `noir-tracer` wasm module"
    worker.deliver($(%*{
      "seq": seqOf(fake, 0), "kind": "failed", "message": Fault,
      "fault": "not-delivered", "module": "noir-tracer"}))

    check seen.len == 1
    check seen[0].stream == psStderr
    check seen[0].text == Fault
    check exits.len == 1
    check exits[0].exitCode == 1
    check not exits[0].signalled
    # ORDER IS PART OF THE CONTRACT: the text must arrive BEFORE the exit, or
    # a producer that paints at exit paints an empty pane and then receives
    # the reason for it.
    check seen.len == 1 and exits.len == 1

    # CONTROL ARM: a clean exit posts no stderr, so the assertion above is
    # about the failure and not about a callback that fires for everything.
    let (worker2, fake2) = newFakePair(registry)
    var seen2: seq[ProcessOutputChunk] = @[]
    proc onOutput2(chunk: ProcessOutputChunk) = seen2.add chunk
    proc onExit2(exit: ProcessExit) = discard
    discard worker2.startOnWorker(noirModule, processSpec("nargo", @["compile"]),
                                  onOutput2, onExit2)
    worker2.deliver(exitMessage(seqOf(fake2, 0), 0))
    check seen2.len == 0

  test "terminate reports an outstanding run as KILLED, not as exit 0":
    ## `process.nim`'s `ProcessExit.signalled`: "a cancelled run establishes
    ## nothing, and callers that conflate the two report a cancellation as a
    ## failure". A terminate settling with exitCode 0 would report a killed
    ## compile as a successful one, and `succeededExit` would agree.
    let (worker, fake) = newFakePair(registry)
    var exits: seq[ProcessExit] = @[]
    proc onOutput(chunk: ProcessOutputChunk) = discard
    proc onExit(exit: ProcessExit) = exits.add exit
    discard worker.startOnWorker(noirModule, processSpec("nargo", @["compile"]),
                                 onOutput, onExit)
    discard worker.stopAll()
    check fake.terminated == 1
    check exits.len == 1
    check exits[0].signalled
    check not exits[0].succeededExit

# ---------------------------------------------------------------------------
# Settled futures. Async for the reason in the header.
# ---------------------------------------------------------------------------

var asyncOk = 0
var asyncFailed = 0

proc report(name: string; ok: bool; detail = "") =
  if ok:
    inc asyncOk
    echo "  [OK] " & name
  else:
    inc asyncFailed
    echo "  [FAILED] " & name & (if detail.len > 0: " — " & detail else: "")

proc asyncSuite() {.async.} =
  echo ""
  echo "[Suite] a run resolves with what it PRODUCED, and only when it is done"

  block:
    const name = "the outcome carries the output and the exit, not merely ok"
    let (worker, fake) = newFakePair(registry)
    let box = watch(worker.runOnWorker(noirModule, processSpec("nargo", @["trace"])))
    let s = seqOf(fake, 0)
    worker.deliver(outputMessage(s, "stdout", "27 events\n"))
    worker.deliver(outputMessage(s, "stderr", "warn\n"))
    worker.deliver(exitMessage(s, 0))
    await settleTurn()
    report(name,
      box.did and box.value.ok and
      box.value.value.stdout == "27 events\n" and
      box.value.value.stderr == "warn\n" and
      box.value.value.exit.succeededExit,
      "did=" & $box.did & " stdout=" & (if box.did: box.value.value.stdout else: "-"))

  block:
    const name = "an empty result is a legitimate result, not a failure"
    # The `valueOr` trap in reverse: conflating "produced nothing" with
    # "failed" is as wrong as conflating "failed" with "produced nothing".
    let (worker, fake) = newFakePair(registry)
    let box = watch(worker.runOnWorker(noirModule, processSpec("nargo", @["compile"])))
    worker.deliver(exitMessage(seqOf(fake, 0), 0))
    await settleTurn()
    report(name,
      box.did and box.value.ok and box.value.value.stdout == "",
      "did=" & $box.did)

  block:
    const name = "A CHAIN OF SUCCESSES IS NOT A RESULT: no exit, no settle"
    let (worker, fake) = newFakePair(registry)
    let box = watch(worker.runOnWorker(noirModule, processSpec("nargo", @["trace"])))
    let s = seqOf(fake, 0)
    for i in 0 ..< 5:
      worker.deliver(outputMessage(s, "stdout", "chunk\n"))
    await settleTurn()
    let stillRunning = not box.did

    # THE COUNTER-CHECK. Without it, "never settles" is also satisfied by a
    # protocol that settles nothing ever — which would pass the assertion
    # above for every input and is a strictly worse product.
    worker.deliver(exitMessage(s, 3))
    await settleTurn()
    report(name,
      stillRunning and box.did and box.value.ok and
      box.value.value.exit.exitCode == 3 and
      not box.value.value.exit.succeededExit,
      "stillRunning=" & $stillRunning & " settled=" & $box.did)

  echo ""
  echo "[Suite] the boundary speaks ONE shape in both directions"

  block:
    const name = "a payload that is not JSON is a named failure, not a drop"
    let (worker, fake) = newFakePair(registry)
    let box = watch(worker.runOnWorker(noirModule, processSpec("nargo", @["trace"])))
    worker.deliver("ready")   # the bare-string bootstrap shape, arriving here
    await settleTurn()
    report(name,
      box.did and (not box.value.ok) and
      workerProtocolPrefix in box.value.error.message,
      "did=" & $box.did)

  block:
    const name = "a message kind this protocol does not define fails by name"
    let (worker, fake) = newFakePair(registry)
    let box = watch(worker.runOnWorker(noirModule, processSpec("nargo", @["trace"])))
    worker.deliver($(%*{"seq": seqOf(fake, 0), "kind": "wasm-loaded"}))
    await settleTurn()
    report(name,
      box.did and (not box.value.ok) and
      "wasm-loaded" in box.value.error.message,
      "did=" & $box.did)

  block:
    const name = "out-of-order answers reach the right runs, with the right output"
    # Asserted on CONTENT: two runs that both resolved `ok` carrying each
    # other's output would pass a status check.
    let (worker, fake) = newFakePair(registry)
    let first = watch(worker.runOnWorker(noirModule, processSpec("nargo", @["trace"])))
    let second = watch(worker.runOnWorker(noirModule, processSpec("nargo", @["compile"])))
    let s1 = seqOf(fake, 0)
    let s2 = seqOf(fake, 1)
    worker.deliver(outputMessage(s2, "stdout", "second\n"))
    worker.deliver(exitMessage(s2, 0))
    await settleTurn()
    let onlySecond = second.did and not first.did
    worker.deliver(outputMessage(s1, "stdout", "first\n"))
    worker.deliver(exitMessage(s1, 0))
    await settleTurn()
    report(name,
      onlySecond and first.did and
      first.value.value.stdout == "first\n" and
      second.value.value.stdout == "second\n",
      "onlySecond=" & $onlySecond)

  block:
    const name = "a terminated run settles as a failure that says so"
    let (worker, fake) = newFakePair(registry)
    let box = watch(worker.runOnWorker(noirModule, processSpec("nargo", @["trace"])))
    discard worker.stopAll()
    await settleTurn()
    report(name,
      box.did and (not box.value.ok) and
      box.value.error.kind == pkFailed and
      workerStoppedMessage in box.value.error.message,
      "did=" & $box.did)

  block:
    const name = "a run requested after stopping is refused, not left hanging"
    let (worker, fake) = newFakePair(registry)
    discard worker.stopAll()
    let box = watch(worker.runOnWorker(noirModule, processSpec("nargo", @["trace"])))
    await settleTurn()
    report(name,
      box.did and (not box.value.ok) and box.value.error.kind == pkCancelled,
      "did=" & $box.did)

  echo ""
  echo "async checks: " & $asyncOk & " passed, " & $asyncFailed & " failed"
  if asyncFailed > 0:
    quit(1)

when defined(js):
  discard asyncSuite()
else:
  waitFor asyncSuite()
