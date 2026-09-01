## wasm_session_harness.nim — a long-lived wasm-worker session, driven from a
## real tab by the product's own protocol driver.
##
## ## Why this exists rather than a unit test
##
## `test_wasm_worker.nim` proves the protocol against a fake transport on both
## backends, and it should: it can express "never settled", which a browser
## cannot. What it cannot express is whether any of it is REACHED. This
## repository has produced at least ten defects whose shape was machinery that
## was present, correct and unreachable — `newBrowserWasmHost` went uncalled
## for a milestone with a doc comment explaining why, and `configure` was
## handled by the worker script from the day it was written while nothing in
## Nim ever sent one, so a correctly deployed pair of modules would still have
## failed every run.
##
## So this program is deliberately made of the SHIPPING parts and nothing else:
##
## * `host/web_browser.newBrowserWasmWorker` — the one place a browser
##   `Worker` is constructed, the same call `newBrowserWasmHost` makes;
## * `platform/wasm_worker` — the protocol driver, unmodified;
## * `/assets/wasm-worker.js` — served from the assembled publish tree, byte
##   for byte as `web-bundle-assets.sh` placed it.
##
## A harness that re-implemented the transport would have proven that a
## harness works.
##
## ## What it measures, and why each one is here
##
## The results land in `#session-report` as one JSON object, which
## `wasm_session_probe.mjs` reads and `wasm-worker-session.sh` counts
## assertions over. This program asserts NOTHING — the split
## `web_renderer_probe.mjs` uses, so the control arm and the mutation arms
## read the same instrument.
##
## The load-bearing measurement is `sendRefusedBeforeRegister` /
## `sendAcceptedAfterRegister`: the session refuses a transaction against a
## contract it does not know, and accepts the same transaction after a
## SEPARATE round trip registered it. A worker that opened a fresh session per
## message, or lost its state between them, produces two refusals. That pair is
## what "holds state between round trips" means as a measurement rather than as
## a claim.

import std/[json, strutils]
import isonim/core/async_compat

import ../../src/frontend/viewmodel/platform/outcome
import ../../src/frontend/viewmodel/platform/process
import ../../src/frontend/viewmodel/platform/wasm_registry
import ../../src/frontend/viewmodel/platform/wasm_worker
import ../../src/frontend/viewmodel/host/web_browser

proc drainSync() =
  ## Pump nim-everywhere's own callback queue.
  ##
  ## `dap_dialect.md` §5 is about the half of this that BITES A CONSUMER, and
  ## the other half bit this harness on its first run. `onComplete` routes
  ## through the drainable `pendingCallbacks` queue **only** for futures
  ## carrying a `__syncResolved` marker — the ones `newCompletedFuture` builds
  ## — and a real promise takes the `.then` branch instead. So the two kinds
  ## need opposite things: a promise resolves itself on V8's microtask queue
  ## and a drain cannot pump it; a synchronously resolved future is INERT until
  ## somebody drains.
  ##
  ## `startOnWorker` returns `resolvedOk(handle)` and `sendToSession` returns
  ## `resolvedErr(...)` on every refusal path — both synchronous. Without this
  ## call the harness registered its callbacks and none of them ever ran: the
  ## session opened, announced itself, and the page never learned its handle.
  ## It looked exactly like a worker that had not answered.
  drainPlatformCallbacks()

proc jsSetText(id: cstring; text: cstring) {.importjs: """
(function (id, text) {
  var el = document.getElementById(id);
  if (el) { el.textContent = text; }
})(#, #)
""".}

proc jsSetTimeout(callback: proc(); ms: int) {.importjs: "setTimeout(#, #)".}

proc jsAfter(ms: int; callback: proc()) =
  ## Argument order flipped in Nim rather than in the `importjs` pattern.
  ##
  ## Written first as `{.importjs: "setTimeout(#2, #1)".}`, which compiles and
  ## emits `setTimeout(<ms>, <temporary>)` with the temporary DECLARED IN
  ## ANOTHER SCOPE — a `ReferenceError` at run time and nothing at compile
  ## time. Reordering placeholders makes the code generator emit the argument
  ## temporaries in source order and consume them in pattern order, and the two
  ## are then not the same order. So the pattern takes its arguments as JS
  ## wants them and the readable order is a Nim wrapper's job.
  jsSetTimeout(callback, ms)

proc jsQueryFlag(name: cstring; fallback: cstring): cstring {.importjs: """
(function (n, d) {
  var v = new URLSearchParams(location.search).get(n);
  return v === null ? d : v;
})(#, #)
""".}

# ---------------------------------------------------------------------------
# The run
# ---------------------------------------------------------------------------

type Harness = ref object
  worker: WasmWorker
  session: ProcessHandle
  lines: seq[JsonNode]      ## every JSON value the session emitted, in order
  exits: seq[ProcessExit]
  report: JsonNode
  steps: seq[string]        ## what was attempted, so a stall is legible

const reportElementId = "session-report"

proc publish(h: Harness) =
  h.report["lines"] = %h.lines.len
  h.report["steps"] = %h.steps
  jsSetText(reportElementId.cstring, ($h.report).cstring)

proc note(h: Harness; step: string) =
  h.steps.add step
  h.publish()

proc replyFor(h: Harness; id: int): JsonNode =
  ## The session's answer to one request id, or nil. Searched rather than
  ## indexed: the session also emits unsolicited `block` events on its timer,
  ## so a positional read would drift the moment the clock ticked.
  for line in h.lines:
    if line.kind == JObject and line{"id"}.getInt(-1) == id:
      return line
  nil

proc blocksSeen(h: Harness): int =
  for line in h.lines:
    if line.kind == JObject and line{"event"}.getStr == "block":
      inc result

proc newHarness(scriptUrl: string): Harness =
  let h = Harness(lines: @[], exits: @[], report: newJObject(), steps: @[])

  # A registry with one command, which is what makes this a legitimate use of
  # the product path rather than a bypass: `newBrowserWasmWorker` builds the
  # worker from whatever registry it is handed, and the worker script routes on
  # the SUBCOMMAND. `session-probe` is declared here for the same reason
  # `noirWasmRegistry` declares `compile`/`trace` — so that a command with no
  # wasm build is refused by name rather than mid-run.
  let registry = WasmRegistry(modules: @[WasmModule(
    command: "ct-session",
    moduleId: WasmModuleId("session-probe@1"),
    displayName: "the session probe",
    subcommands: @["session-probe"],
    builtFrom: "codetracer host/wasm_worker_browser.js")])

  h.worker = newBrowserWasmWorker(registry, scriptUrl, @[])
  h.report["scriptUrl"] = %scriptUrl
  h.report["registryCommands"] = %registry.modules.len
  h

proc openSession(h: Harness; tickMs: int) =
  proc onOutput(chunk: ProcessOutputChunk) =
    for raw in chunk.text.split('\n'):
      let line = raw.strip()
      if line.len == 0: continue
      try:
        h.lines.add parseJson(line)
      except:
        h.lines.add %*{"unparsed": line}
    h.publish()

  proc onExit(exit: ProcessExit) =
    h.exits.add exit
    h.report["sessionExitCode"] = %exit.exitCode
    h.report["sessionSignalled"] = %exit.signalled
    h.publish()

  let started = h.worker.startOnWorker(
    WasmModuleId("session-probe@1"),
    processSpec("ct-session", @["session-probe", "--tick-ms=" & $tickMs]),
    onOutput, onExit)
  started.onComplete(proc(o: PlatformOutcome[ProcessHandle]) =
    if o.ok:
      h.session = o.value
      h.report["handle"] = %($h.session)
      # NOT evidence that a session opened — `startOnWorker` resolves without
      # waiting for the worker. The `ready` line is the evidence, and it is
      # measured separately below.
      h.note("opened")
    else:
      h.report["openError"] = %o.error.message
      h.note("open-failed"),
    proc(message: string) =
      h.report["openError"] = %message
      h.note("open-failed"))
  drainSync()

proc send(h: Harness; label: string; payload: JsonNode;
          then: proc()) =
  ## One `input`, with its acknowledgement recorded under `<label>Ack`.
  ##
  ## The acknowledgement is recorded SEPARATELY from the session's reply,
  ## because they are different facts and conflating them is the shape this
  ## protocol was built to prevent: `ack` says the worker took the message,
  ## and only the reply says what it did.
  let ack = h.worker.sendToSession(h.session, $payload)
  ack.onComplete(proc(o: PlatformOutcome[Nothing]) =
    h.report[label & "Ack"] = %o.ok
    if not o.ok:
      h.report[label & "AckKind"] = %($o.error.kind)
      h.report[label & "AckDetail"] = %o.error.detail
    h.note(label)
    then(),
    proc(message: string) =
      h.report[label & "Ack"] = %false
      h.report[label & "AckError"] = %message
      h.note(label & "-failed")
      then())
  drainSync()

proc serialOf(h: Harness; id: int): int =
  let reply = h.replyFor(id)
  if reply.isNil: -1 else: reply{"serial"}.getInt(-1)

proc finishedOf(h: Harness; id: int): int =
  let reply = h.replyFor(id)
  if reply.isNil: -1 else: reply{"finished"}.getInt(-1)

proc finish(h: Harness) =
  # WHAT THE SESSION KNEW, read out of the replies rather than out of anything
  # this program remembered. A harness that reported its own bookkeeping would
  # go green over a worker that answered nothing.
  var sawReady = false
  for line in h.lines:
    if line.kind == JObject and line{"event"}.getStr == "ready": sawReady = true
  h.report["readyEvent"] = %sawReady

  let sendBefore = h.replyFor(1)
  let register = h.replyFor(2)
  let sendAfter = h.replyFor(3)
  let sealed = h.replyFor(7)
  let status = h.replyFor(8)

  # THE ROUND-TRIP PAIR, and the load-bearing measurement of the whole gate.
  # `send` before `register` must be refused and the SAME `send` after it must
  # be accepted. A worker that opened a fresh session per message, or lost its
  # state between them, produces two refusals — and produces them while every
  # acknowledgement stays green, which is why the pair is measured rather than
  # the acknowledgements.
  h.report["sendRefusedBeforeRegister"] =
    %(not sendBefore.isNil and sendBefore.hasKey("error"))
  h.report["sendRefusalNamesEmptyRegistry"] =
    %(not sendBefore.isNil and
      "registered: []" in sendBefore{"error"}{"message"}.getStr)
  h.report["registerAccepted"] =
    %(not register.isNil and register.hasKey("result"))
  h.report["sendAcceptedAfterRegister"] =
    %(not sendAfter.isNil and sendAfter.hasKey("result"))
  h.report["queuedAfterSend"] =
    %(if sendAfter.isNil: -1 else: sendAfter{"result"}{"queued"}.getInt(-1))

  # ORDERING. `serial` is assigned when a message is HANDLED, not when it is
  # accepted, which is the only way to tell a queue that serialises from one
  # that merely receives in order: a worker running the queue concurrently
  # would accept 4, 5, 6 in that order and finish 5 and 6 while 4 was still
  # stalling. The burst at t=900 is three messages in ONE turn, the first of
  # which stalls, so this is measured rather than argued.
  var serials: seq[int] = @[]
  for line in h.lines:
    if line.kind == JObject and line.hasKey("serial"):
      serials.add line{"serial"}.getInt(-1)
  h.report["serials"] = %serials
  h.report["serialCount"] = %serials.len
  var ordered = serials.len > 0
  for i in 1 ..< serials.len:
    if serials[i] <= serials[i - 1]: ordered = false
  h.report["serialsAreFifo"] = %ordered
  h.report["burstStallSerial"] = %h.serialOf(4)
  h.report["burstSendSerial"] = %h.serialOf(5)
  h.report["burstStatusSerial"] = %h.serialOf(6)
  h.report["burstStallFinished"] = %h.finishedOf(4)
  h.report["burstSendFinished"] = %h.finishedOf(5)
  h.report["burstStatusFinished"] = %h.finishedOf(6)
  # BOTH counters, and the completions are the half that discriminates. A
  # first draft compared only the start stamps and stayed green with the
  # per-session drain guard REMOVED, because dispatch happens in arrival order
  # either way — the reordering is in when the handlers finish. `serial ==
  # finished` on the stalling message is the statement "nothing ran while it
  # was awaiting", which is what serialisation means.
  h.report["burstHandledInOrder"] =
    %(h.serialOf(4) > 0 and h.serialOf(4) < h.serialOf(5) and
      h.serialOf(5) < h.serialOf(6) and
      h.finishedOf(4) < h.finishedOf(5) and
      h.finishedOf(5) < h.finishedOf(6) and
      h.serialOf(4) == h.finishedOf(4))
  var allSerially = serials.len > 0
  for line in h.lines:
    if line.kind == JObject and line.hasKey("serial"):
      if line{"serial"}.getInt(-1) != line{"finished"}.getInt(-2):
        allSerially = false
  h.report["handledSerially"] = %allSerially

  # STATE AT THE END, as the session itself reports it.
  h.report["statusHeight"] =
    %(if status.isNil: -1 else: status{"result"}{"height"}.getInt(-1))
  h.report["statusSealed"] =
    %(if status.isNil: -1 else: status{"result"}{"sealed"}.getInt(-1))
  h.report["statusContracts"] =
    %(if status.isNil: newJArray() else: status{"result"}{"contracts"})
  h.report["statusRoot"] =
    %(if status.isNil: "" else: status{"result"}{"stateRoot"}.getStr)
  h.report["sealedNumber"] =
    %(if sealed.isNil: -1 else: sealed{"result"}{"number"}.getInt(-1))
  h.report["blocks"] = %h.blocksSeen()
  var blockNumbers: seq[int] = @[]
  var tickCaused = 0
  for line in h.lines:
    if line.kind == JObject and line{"event"}.getStr == "block":
      blockNumbers.add line{"number"}.getInt(-1)
      # UNSOLICITED, and the `cause` is what says so. A block sealed because
      # somebody asked proves nothing about a clock; a node produces them
      # whether or not anyone is asking, and that is the property.
      if line{"cause"}.getStr == "tick": inc tickCaused
  h.report["blockNumbers"] = %blockNumbers
  h.report["tickCausedBlocks"] = %tickCaused
  h.report["sessionStillActive"] = %h.worker.runIsActive(h.session)
  h.publish()

  # AND THEN END IT DELIBERATELY, which is the fourth thing a lifecycle needs
  # and the one a `terminate` cannot express: the worker must still be alive
  # afterwards. Measured by sending into the closed session and requiring the
  # named refusal rather than silence.
  # Written with NAMED procs rather than nested anonymous ones. The nested
  # form compiles and leaves no place to put the `drainSync` the inner
  # callback needs: `sendToSession` into a closed session answers
  # synchronously, so its callback is inert until something drains, and there
  # is no statement position after an inline `onComplete` argument.
  proc afterClosed(o: PlatformOutcome[Nothing]) =
    h.report["afterCloseRefused"] = %(not o.ok)
    h.report["afterCloseKind"] = %(if o.ok: "" else: $o.error.kind)
    h.report["afterCloseDetail"] = %(if o.ok: "" else: o.error.detail)
    h.report["done"] = %true
    h.note("done")

  proc afterClosedFailed(message: string) =
    h.report["afterCloseRefused"] = %true
    h.report["done"] = %true
    h.note("done")

  proc onClosed(o: PlatformOutcome[Nothing]) =
    h.report["closeAck"] = %o.ok
    h.note("closed")
    # THE PROOF THAT CLOSE ENDED SOMETHING. A `close` that was acknowledged
    # and left the session running would satisfy `closeAck` perfectly; only
    # sending into it afterwards can tell the two apart, and the answer must
    # be a NAMED refusal rather than silence.
    let after = h.worker.sendToSession(h.session, "{\"id\":9}")
    after.onComplete(afterClosed, afterClosedFailed)
    drainSync()

  proc onCloseFailed(message: string) =
    h.report["closeAck"] = %false
    h.report["closeError"] = %message
    h.report["done"] = %true
    h.note("done")

  let closing = h.worker.closeSession(h.session)
  closing.onComplete(onClosed, onCloseFailed)
  drainSync()

proc main() =
  let scriptUrl = $jsQueryFlag("worker".cstring, "/assets/wasm-worker.js".cstring)
  # DEFAULT ZERO, deliberately. A running clock makes the height at any moment
  # a function of how fast the machine is, so the control arm's numbers would
  # be approximate and every assertion on them would have to be an inequality.
  # The timer is a real property and it gets its own arm (`?tick=`), where the
  # assertion is "blocks appeared with nobody asking" — which is what a clock
  # is FOR — rather than a count that drifts.
  let tickMs = parseInt($jsQueryFlag("tick".cstring, "0".cstring))
  let h = newHarness(scriptUrl)
  h.report["tickMs"] = %tickMs
  h.openSession(tickMs)

  # Laid out as a chain rather than a loop because each step is a DIFFERENT
  # question and the order between them is the evidence. Timers rather than
  # awaits: a session answers on its own stream, so there is no future to
  # await — which is the property being demonstrated, not one being worked
  # around.
  jsAfter(150, proc() =
    # ROUND TRIP 1 — a transaction against a contract nobody registered.
    h.send("sendBefore", %*{"id": 1, "method": "send",
                            "params": {"contract": "Counter", "call": "inc"}},
           proc() = discard))

  jsAfter(400, proc() =
    # ROUND TRIP 2 — register it. A separate user action, minutes apart in the
    # product and 250 ms apart here.
    h.send("register", %*{"id": 2, "method": "register",
                          "params": {"name": "Counter"}},
           proc() = discard))

  jsAfter(650, proc() =
    # ROUND TRIP 3 — the SAME transaction, which can only succeed if round
    # trip 2's state is still there.
    h.send("sendAfter", %*{"id": 3, "method": "send",
                           "params": {"contract": "Counter", "call": "inc"}},
           proc() = discard))

  jsAfter(900, proc() =
    # THE BURST — three messages in ONE turn, the first of which stalls for
    # 180 ms. This is what "messages arrive during a long operation" looks
    # like, and the answer is that they QUEUE: all three are accepted at once
    # and handled one at a time, in order. Without the drain guard, 5 and 6
    # would be handled while 4 was still stalling and would carry lower
    # serials than it.
    h.send("burstStall", %*{"id": 4, "method": "stall",
                            "params": {"ms": 180, "mode": "await"}},
           proc() = discard)
    h.send("burstSend", %*{"id": 5, "method": "send",
                           "params": {"contract": "Counter", "call": "inc"}},
           proc() = discard)
    h.send("burstStatus", %*{"id": 6, "method": "status"}, proc() = discard))

  jsAfter(1400, proc() =
    h.send("seal", %*{"id": 7, "method": "seal"}, proc() = discard))

  jsAfter(1650, proc() =
    h.send("status", %*{"id": 8, "method": "status"}, proc() = discard))

  jsAfter(2100, proc() = h.finish())

main()
