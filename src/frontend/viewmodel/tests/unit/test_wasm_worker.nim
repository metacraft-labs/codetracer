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

proc failedMessage(s: int; message: string; fault = ""): string =
  if fault.len == 0:
    $(%*{"seq": s, "kind": "failed", "message": message})
  else:
    $(%*{"seq": s, "kind": "failed", "message": message, "fault": fault})

proc openSession(worker: WasmWorker; onOutput: proc(chunk: ProcessOutputChunk);
                 onExit: proc(exit: ProcessExit)): ProcessHandle =
  ## A session is an ordinary `start`; the module id is opaque to this layer
  ## and the worker routes on the subcommand, so the registry's `nargo` entry
  ## serves as well as any other. What makes the run a SESSION is that the
  ## fake below never posts an `exit` for it.
  let box = watch(worker.startOnWorker(
    noirModule, processSpec("nargo", @["session-probe"]), onOutput, onExit))
  drainPlatformCallbacks()
  doAssert box.did and box.value.ok, "startOnWorker must resolve its handle"
  box.value.value

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

suite "a session is addressed by its run's sequence, and messages say which":

  test "an input carries its OWN sequence and NAMES the session's":
    ## The structural heart of the design, and the reason it is asserted on
    ## the parsed message rather than on a substring: a `failed` finishes the
    ## run it names, so an `input` that reused the session's sequence would
    ## make a refusal — a full inbox, say — indistinguishable from the death
    ## of the session it was declining to accept. Two facts, two sequences.
    let (worker, fake) = newFakePair(registry)
    let handle = worker.openSession(nil, nil)
    let sessionSeq = seqOf(fake, 0)

    discard worker.sendToSession(handle, "{\"id\":1,\"method\":\"status\"}")
    check fake.sent.len == 2
    let input = parseJson(fake.sent[1])
    check input["kind"].getStr == "input"
    check input["session"].getInt == sessionSeq
    check input["seq"].getInt != sessionSeq
    check input["text"].getStr == "{\"id\":1,\"method\":\"status\"}"

  test "two inputs to one session get two distinct sequences":
    let (worker, fake) = newFakePair(registry)
    let handle = worker.openSession(nil, nil)
    discard worker.sendToSession(handle, "one")
    discard worker.sendToSession(handle, "two")
    check fake.sent.len == 3
    check seqOf(fake, 1) != seqOf(fake, 2)
    check parseJson(fake.sent[1])["session"].getInt ==
          parseJson(fake.sent[2])["session"].getInt

  test "close names the session and does NOT terminate the worker":
    ## `stopAll` is `worker.terminate()` and takes every other session and
    ## every in-flight compile with it. A session that could only be ended
    ## that way would make "I am done with this node" cost the whole tab's
    ## toolchain, so the counter-check here is on `terminated`.
    let (worker, fake) = newFakePair(registry)
    let handle = worker.openSession(nil, nil)
    discard worker.closeSession(handle)
    check fake.sent.len == 2
    check parseJson(fake.sent[1])["kind"].getStr == "close"
    check parseJson(fake.sent[1])["session"].getInt == seqOf(fake, 0)
    check fake.terminated == 0

  test "a delivery is not a process: it does not answer runIsActive":
    let (worker, fake) = newFakePair(registry)
    let handle = worker.openSession(nil, nil)
    discard worker.sendToSession(handle, "one")
    let deliverySeq = parseJson(fake.sent[1])["seq"].getInt
    check not worker.runIsActive(ProcessHandle("wasm-" & $deliverySeq))
    check worker.runIsActive(handle)

  test "sending to a handle that is not a live session posts NOTHING":
    ## Refused on this side, because this side already knows — `finish`
    ## removed the handle when the run ended. The assertion is on `sent`: a
    ## round trip to ask a question whose answer is already held is a request
    ## a dead worker cannot answer at all.
    let (worker, fake) = newFakePair(registry)
    let handle = worker.openSession(nil, nil)
    worker.deliver(exitMessage(seqOf(fake, 0), 0))
    discard worker.sendToSession(handle, "one")
    check fake.sent.len == 1

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
  echo "[Suite] a SESSION outlives its answers, and a refusal does not kill it"

  block:
    const name = "a session stays live across two round trips and is not settled"
    # The property the whole mechanism exists for, asserted as a NEGATIVE with
    # its positive twin: the run must still be unsettled after traffic has
    # flowed both ways twice, and it must settle the moment the session
    # actually exits. Without the twin, "never settles" is satisfied by a
    # protocol that settles nothing.
    let (worker, fake) = newFakePair(registry)
    var lines: seq[string] = @[]
    var exits: seq[ProcessExit] = @[]
    proc onOutput(chunk: ProcessOutputChunk) = lines.add chunk.text
    proc onExit(exit: ProcessExit) = exits.add exit
    let handle = worker.openSession(onOutput, onExit)
    let s = seqOf(fake, 0)

    let firstAck = watch(worker.sendToSession(handle, "{\"method\":\"register\"}"))
    worker.deliver(exitMessage(parseJson(fake.sent[1])["seq"].getInt, 0))
    worker.deliver(outputMessage(s, "stdout", "{\"id\":1,\"result\":{}}\n"))
    await settleTurn()

    let secondAck = watch(worker.sendToSession(handle, "{\"method\":\"send\"}"))
    worker.deliver(exitMessage(parseJson(fake.sent[2])["seq"].getInt, 0))
    worker.deliver(outputMessage(s, "stdout", "{\"id\":2,\"result\":{}}\n"))
    await settleTurn()

    let stillLive = worker.runIsActive(handle) and exits.len == 0
    let bothAcked = firstAck.did and firstAck.value.ok and
                    secondAck.did and secondAck.value.ok

    # THE TWIN.
    worker.deliver(exitMessage(s, 0))
    await settleTurn()
    report(name,
      stillLive and bothAcked and lines.len == 2 and
      exits.len == 1 and exits[0].exitCode == 0 and
      not worker.runIsActive(handle),
      "live=" & $stillLive & " acked=" & $bothAcked & " lines=" & $lines.len &
      " exits=" & $exits.len)

  block:
    const name = "A REFUSED DELIVERY LEAVES THE SESSION RUNNING"
    # Why an `input` carries its own sequence. The worker refuses the delivery
    # with `session-busy`; the SESSION's run must be untouched, because
    # backpressure that destroys the thing applying it is worse than no
    # backpressure at all. Asserted on both halves: the delivery settles as a
    # named, retryable refusal AND the session is still live.
    let (worker, fake) = newFakePair(registry)
    var exits: seq[ProcessExit] = @[]
    proc onOutput(chunk: ProcessOutputChunk) = discard
    proc onExit(exit: ProcessExit) = exits.add exit
    let handle = worker.openSession(onOutput, onExit)

    let ack = watch(worker.sendToSession(handle, "one"))
    worker.deliver(failedMessage(parseJson(fake.sent[1])["seq"].getInt,
                                 "session 1 already has 64 message(s) waiting",
                                 faultSessionBusy))
    await settleTurn()
    report(name,
      ack.did and (not ack.value.ok) and
      ack.value.error.kind == pkQuotaExceeded and
      worker.runIsActive(handle) and exits.len == 0,
      "settled=" & $ack.did & " kind=" &
      (if ack.did: $ack.value.error.kind else: "-") &
      " sessionLive=" & $worker.runIsActive(handle))

  block:
    const name = "an input sent after the session exited is refused, not hung"
    let (worker, fake) = newFakePair(registry)
    let handle = worker.openSession(nil, nil)
    worker.deliver(exitMessage(seqOf(fake, 0), 0))
    let ack = watch(worker.sendToSession(handle, "one"))
    await settleTurn()
    report(name,
      ack.did and (not ack.value.ok) and ack.value.error.kind == pkNotFound,
      "settled=" & $ack.did)

  block:
    const name = "a pending delivery is stranded by nothing: terminate settles it"
    let (worker, fake) = newFakePair(registry)
    let handle = worker.openSession(nil, nil)
    let ack = watch(worker.sendToSession(handle, "one"))
    discard worker.stopAll()
    await settleTurn()
    report(name,
      ack.did and (not ack.value.ok) and
      workerStoppedMessage in ack.value.error.message,
      "settled=" & $ack.did)

  echo ""
  echo "[Suite] the worker's own death reaches every run (sequence 0)"

  block:
    const name = "A `failed` ON SEQUENCE 0 FAILS EVERY OUTSTANDING RUN"
    # THE DEFECT THIS FIXES. `host/web_browser.newWorkerTransport` turns
    # `worker.onerror` into exactly this message — "an error event is not a
    # message, and must not be silently dropped" — and `deliver` dropped it,
    # because sequence 0 is never in `pending` and the early return took it.
    # Every outstanding run then waited for the life of the tab. A compile is
    # exposed to that for seconds; a session for as long as the page is open.
    let (worker, fake) = newFakePair(registry)
    var exits: seq[ProcessExit] = @[]
    proc onOutput(chunk: ProcessOutputChunk) = discard
    proc onExit(exit: ProcessExit) = exits.add exit
    let session = worker.openSession(onOutput, onExit)
    let compile = watch(worker.runOnWorker(
      noirModule, processSpec("nargo", @["compile"])))
    worker.deliver(failedMessage(0, "the wasm worker failed: boom"))
    await settleTurn()
    report(name,
      compile.did and (not compile.value.ok) and
      workerDiedPrefix in compile.value.error.message and
      "boom" in compile.value.error.message and
      exits.len == 1 and exits[0].signalled and
      not worker.runIsActive(session),
      "compileSettled=" & $compile.did & " sessionExits=" & $exits.len)

  block:
    const name = "and the CONFIGURE acknowledgement on sequence 0 fails nothing"
    # The counter-check, and it is not decoration: `configure` is answered on
    # sequence 0 with an `output` and an `exit`, so a broadcast that keyed on
    # the sequence alone would kill every run on the handshake — a fix strictly
    # worse than the defect. Only `failed` broadcasts.
    let (worker, fake) = newFakePair(registry)
    let box = watch(worker.runOnWorker(noirModule, processSpec("nargo", @["trace"])))
    worker.configure(@[(id: "noir-compiler", url: "/assets/noir_wasm.wasm")])
    worker.deliver(outputMessage(0, "stdout", ""))
    worker.deliver(exitMessage(0, 0))
    await settleTurn()
    let survived = not box.did
    worker.deliver(exitMessage(seqOf(fake, 0), 0))
    await settleTurn()
    report(name,
      survived and box.did and box.value.ok,
      "survivedConfigure=" & $survived & " thenSettled=" & $box.did)

  echo ""
  echo "[Suite] each `fault` reaches the caller as its OWN error kind"

  # The field has been on the wire since the module-load faults were split
  # into three sentences, and had ZERO readers on this side: a vocabulary
  # designed for branching that nothing branched on. Each row is its own
  # counted assertion, because a single loop reporting once would let four
  # collapse into one and still look green.
  for row in [
      (fault: faultNotDelivered, want: pkNotFound),
      (fault: faultNotServed,    want: pkTransport),
      (fault: faultBroken,       want: pkFailed),
      (fault: faultNoSession,    want: pkNotFound),
      (fault: faultSessionBusy,  want: pkQuotaExceeded)]:
    let (worker, fake) = newFakePair(registry)
    let box = watch(worker.runOnWorker(noirModule, processSpec("nargo", @["trace"])))
    worker.deliver(failedMessage(seqOf(fake, 0), "the module said no", row.fault))
    await settleTurn()
    report("fault `" & row.fault & "` is " & $row.want,
      box.did and (not box.value.ok) and
      box.value.error.kind == row.want and
      box.value.error.detail == row.fault,
      "kind=" & (if box.did: $box.value.error.kind else: "-"))

  block:
    const name = "a fault this build does not know is still a failure, not a raise"
    # The worker may be a newer build than the page — they are separate assets
    # with separate cache lifetimes. An unclassifiable fault must still settle
    # the run.
    let (worker, fake) = newFakePair(registry)
    let box = watch(worker.runOnWorker(noirModule, processSpec("nargo", @["trace"])))
    worker.deliver(failedMessage(seqOf(fake, 0), "from the future", "quantum"))
    await settleTurn()
    report(name,
      box.did and (not box.value.ok) and box.value.error.kind == pkFailed,
      "settled=" & $box.did)

  echo ""
  echo "async checks: " & $asyncOk & " passed, " & $asyncFailed & " failed"

  # THE COUNT ITSELF, ASSERTED. Every block above is a `report`, and a block
  # that raised before reaching its `report` — or one deleted in a merge —
  # leaves the tally short while every line printed says `[OK]`. Universal
  # quantification over an empty set passes vacuously; this is the guard
  # against the set quietly shrinking.
  const expectedAsyncChecks = 20
    ## 8 that were here, plus 12: 4 on a session outliving its answers, 2 on
    ## sequence 0, and 6 on the `fault` vocabulary. Written from a run — and
    ## the first run had it wrong by two, which is the guard earning its place
    ## before the code it guards had a chance to rot.
  if asyncOk + asyncFailed != expectedAsyncChecks:
    echo "  [FAILED] " & $(asyncOk + asyncFailed) & " async check(s) ran, " &
      $expectedAsyncChecks & " were written. An assertion that did not run " &
      "is not an assertion that passed."
    quit(1)

  if asyncFailed > 0:
    quit(1)

when defined(js):
  discard asyncSuite()
else:
  waitFor asyncSuite()
