## worker_backend_wasm_e2e.nim
##
## Drives the real `WorkerBackendService` against the real `db-backend`
## WASM replay engine, running in a real worker, over a real `.ct` trace.
##
## Nothing here is mocked: the DAP traffic is produced by the Nim adapter
## under test and consumed by the compiled Rust engine. The only shim is
## `src/db-backend/wasm-testing/node-host/worker_host.mjs`, which supplies
## the browser globals Node lacks (`self`, `DedicatedWorkerGlobalScope`,
## `fetch` over `file:`) and then imports the production `worker.js`
## unmodified.
##
## Run via `ci/test/worker-backend-wasm-e2e.sh`, which fails — never skips —
## when the WASM artifact is absent.
##
##   nim js -d:nodejs --path:src/frontend/viewmodel \
##     -o:OUT.js src/frontend/viewmodel/tests/e2e/worker_backend_wasm_e2e.nim
##   node OUT.js <host.mjs> <trace.ct>

when not defined(js):
  {.error: "worker_backend_wasm_e2e.nim drives a WebWorker; it is JS-only".}

import std/[json, strutils]
import isonim/core/async_compat
import backend/[backend_service, worker_backend]

# ---------------------------------------------------------------------------
# Node worker_threads FFI. Kept in this file, not in `worker_backend.nim`:
# the adapter must stay transport-agnostic (and free of a Node dependency).
# ---------------------------------------------------------------------------

proc startWorker(hostPath: cstring; onMessage: proc(raw: cstring)): bool {.importjs: """
(function(path, cb){
  const { Worker } = require('node:worker_threads');
  const w = new Worker(path);
  globalThis.__ctWorker = w;
  w.on('message', function(m){
    cb(typeof m === 'string' ? m : JSON.stringify(m));
  });
  w.on('error', function(e){
    cb(JSON.stringify({ type: 'worker-error', error: String((e && e.stack) || e) }));
  });
  return true;
})(#, #)
""".}

proc postJson(messageJson: cstring) {.importjs: """
(function(s){ globalThis.__ctWorker.postMessage(JSON.parse(s)); })(#)
""".}
  ## The worker expects a structured-clone object and does
  ## `JSON.stringify(event.data)` on it, so the text goes back to an object
  ## here rather than being posted as a string.

proc postTraceBytes(vfsPath: cstring; filePath: cstring) {.importjs: """
(function(vp, fp){
  const fs = require('node:fs');
  globalThis.__ctWorker.postMessage({
    type: 'vfs-write', path: vp, data: new Uint8Array(fs.readFileSync(fp))
  });
})(#, #)
""".}
  ## `vfs-write` carries raw bytes, which JSON cannot represent — this is the
  ## one message that does not go through the adapter's text boundary.

proc terminateWorker() {.importjs: """
(function(){ if (globalThis.__ctWorker) { globalThis.__ctWorker.terminate(); } })()
""".}

proc fileExists(path: cstring): bool {.importjs:
  "(function(p){ return require('node:fs').existsSync(p); })(#)".}

proc argAt(i: int): cstring {.importjs: "(process.argv[# + 2] || '')".}

proc installWatchdog(ms: int) {.importjs: """
(function(ms){
  setTimeout(function(){
    console.error('E2E TIMEOUT after ' + ms + 'ms — the worker never answered.');
    process.exit(1);
  }, ms);
})(#)
""".}

proc microtask(): Future[void] {.importjs: "Promise.resolve()".}

proc afterMs(ms: int): Future[void] {.importjs:
  "new Promise(function(r){ setTimeout(r, #); })".}

# ---------------------------------------------------------------------------
# Waiting for the worker's bootstrap (non-DAP) traffic
# ---------------------------------------------------------------------------

type Waiter = ref object
  matches: proc(m: JsonNode): bool
  resolve: proc(m: JsonNode)

var waiters: seq[Waiter] = @[]
var controlLog: seq[JsonNode] = @[]
var events: seq[JsonNode] = @[]

proc onControlMessage(m: JsonNode) =
  controlLog.add(m)
  var i = 0
  while i < waiters.len:
    if waiters[i].matches(m):
      let resolve = waiters[i].resolve
      waiters.delete(i)
      resolve(m)
    else:
      inc i

proc waitControl(pred: proc(m: JsonNode): bool): Future[JsonNode] =
  for m in controlLog:
    if pred(m):
      return newCompletedFuture[JsonNode](m)
  newPromise(proc(resolve: proc(m: JsonNode)) =
    waiters.add(Waiter(matches: pred, resolve: resolve)))

proc hasType(t: string): proc(m: JsonNode): bool =
  result = proc(m: JsonNode): bool = m{"type"}.getStr == t

proc isStatus(s: string): proc(m: JsonNode): bool =
  result = proc(m: JsonNode): bool =
    m{"type"}.getStr == "worker-status" and m{"status"}.getStr == s

# ---------------------------------------------------------------------------
# Reporting
# ---------------------------------------------------------------------------

var passed = 0
var failed = 0

proc report(name: string; ok: bool; detail = "") =
  if ok:
    inc passed
    echo "  [OK] " & name
  else:
    inc failed
    echo "  [FAILED] " & name & (if detail.len > 0: " — " & detail else: "")

proc eventNamed(name: string): JsonNode =
  for e in events:
    if e{"event"}.getStr == name:
      return e
  nil

proc succeeded(response: JsonNode): bool =
  (not response.isNil) and response{"success"}.getBool

# ---------------------------------------------------------------------------
# The session
# ---------------------------------------------------------------------------

proc run() {.async.} =
  let hostPath = $argAt(0)
  let tracePath = $argAt(1)

  echo "[Suite] WorkerBackendService against the real db-backend WASM engine"
  echo "  host:  " & hostPath
  echo "  trace: " & tracePath

  # A missing artifact is a failure, never a skip.
  if hostPath.len == 0 or tracePath.len == 0:
    echo "  [FAILED] usage: worker_backend_wasm_e2e <worker_host.mjs> <trace.ct>"
    quit(1)
  if not fileExists(hostPath.cstring):
    echo "  [FAILED] worker host missing: " & hostPath
    quit(1)
  if not fileExists(tracePath.cstring):
    echo "  [FAILED] trace fixture missing: " & tracePath
    quit(1)

  installWatchdog(180_000)

  # --- wire the adapter to a real worker ----------------------------------
  let backend = newWorkerBackend(
    postProc = proc(messageJson: string) = postJson(messageJson.cstring),
    terminateProc = proc() = terminateWorker())
  backend.onControl(onControlMessage)
  backend.onEvent(proc(e: JsonNode) = events.add(e))

  let service = backend.toBackendService()

  discard startWorker(hostPath.cstring, proc(raw: cstring) =
    backend.deliver($raw))

  # --- bootstrap ----------------------------------------------------------
  discard await waitControl(hasType("wasm-loaded"))
  report("the WASM module loads in the worker", true)

  postTraceBytes("trace/trace.ct".cstring, tracePath.cstring)
  let ack = await waitControl(hasType("vfs-ack"))
  report("the .ct container is written into the engine's VFS",
    ack{"ok"}.getBool, $ack)

  postJson("""{"type":"start"}""")
  discard await waitControl(isStatus("ready"))
  report("wasm_start() installs the DAP handler and reports ready", true)

  # --- DAP handshake ------------------------------------------------------
  # Order matters: `launch` must precede `configurationDone`, because
  # `handle_message_browser`'s configurationDone arm is the only place
  # `setup_from_vfs` runs and it reads the folder that `launch` populates
  # (src/db-backend/src/dap_server.rs:2745-2779).
  let initResponse = await service.send("initialize", %*{
    "clientID": "codetracer-embed-e2e",
    "adapterID": "codetracer",
    "supportsProgressReporting": false,
  })
  report("initialize", initResponse.succeeded, $initResponse)

  let launchResponse = await service.send("launch", %*{"traceFolder": "trace"})
  report("launch", launchResponse.succeeded, $launchResponse)

  let configResponse = await service.send("configurationDone", newJObject())
  report("configurationDone", configResponse.succeeded, $configResponse)

  # --- a real replay session ---------------------------------------------
  let threads = await service.send("threads", newJObject())
  report("threads", threads.succeeded, $threads)

  proc topFrame(response: JsonNode): JsonNode =
    let frames = response{"body"}{"stackFrames"}
    if frames.isNil or frames.kind != JArray or frames.len == 0: newJNull()
    else: frames[0]

  let entry = await service.send("stackTrace", %*{"threadId": 1})
  let entryFrame = entry.topFrame
  report("stackTrace returns a real frame at the entry point",
    entry.succeeded and (not entryFrame.isNil) and entryFrame.kind == JObject and
      entryFrame{"line"}.getInt(0) > 0 and
      entryFrame{"source"}{"path"}.getStr.len > 0,
    $entry)
  let entryLine = entryFrame{"line"}.getInt(0)
  let entryName = entryFrame{"name"}.getStr
  echo "        entry: " & entryName & " at " &
       entryFrame{"source"}{"path"}.getStr & ":" & $entryLine

  # Variable state.
  let scopes = await service.send("scopes", %*{"frameId": 0})
  report("scopes", scopes.succeeded, $scopes)

  # NOTE: `ct/load-locals` is deliberately NOT exercised here. With the full
  # argument set the ViewModels send, it traps the WASM engine
  # (`SystemTime::now()` on wasm32 — see the engine-defect notes in
  # src/db-backend/wasm-testing/node-host/probe_engine_defects.mjs), which
  # kills the worker and would make every later check meaningless. That is an
  # engine defect, not an adapter defect, and it is reported separately.

  let variables = await service.send("variables", %*{"variablesReference": 1})
  let variableList = variables{"body"}{"variables"}
  report("variables returns readable program state",
    variables.succeeded and (not variableList.isNil) and
      variableList.kind == JArray,
    $variables)
  if not variableList.isNil and variableList.kind == JArray:
    echo "        variables: " & $variableList.len & " in scope"
    for v in variableList:
      echo "          " & v{"name"}.getStr & " = " & v{"value"}.getStr

  # The call trace.
  let calltrace = await service.send("ct/load-calltrace-section", %*{
    "location": %*{"rrTicks": 0},
    "startCallLineIndex": 0,
    "depth": 3,
    "height": 30,
    "rawIgnorePatterns": "",
  })
  report("ct/load-calltrace-section answers over the worker transport",
    calltrace.succeeded, $calltrace)

  # --- unsolicited events -------------------------------------------------
  # Flow data is preloaded backend-side (`flow_preloader.rs`), so the payload
  # for `ct/load-flow` comes back as a `ct/updated-flow` EVENT (dap.rs:250) as
  # well as a response. An adapter that correlates replies but silently drops
  # unsolicited events would pass every request/response check above and still
  # be useless in a running session, so the event path is asserted directly.
  # NOTE the argument shape. `flowMode` is deserialised as a numeric ordinal
  # (`CtLoadFlowArguments.flow_mode: FlowMode`, task.rs:52-64) and `location`
  # is required. `FlowVM` sends neither of those things — see the dialect
  # report — so this test sends what the ENGINE accepts, in order to prove the
  # transport and the event path. The ViewModel-side mismatch is a separate,
  # reported defect and is not papered over here.
  let flowLocation = %*{
    "path": entryFrame{"source"}{"path"}.getStr,
    "line": entryLine,
    "rrTicks": 0,
    "functionName": entryName,
    "key": "",
    "globalCallKey": "",
    "callstackDepth": 0,
  }
  let flow = await service.send("ct/load-flow", %*{
    "flowMode": 0,
    "location": flowLocation,
  })
  report("ct/load-flow", flow.succeeded, $flow)

  # Poll for the event rather than calling a generic `{.async.}` helper:
  # std/asyncjs cannot instantiate one that returns `Future[JsonNode]`.
  var flowEvent: JsonNode = nil
  var flowWaited = 0
  while flowWaited < 8000 and flowEvent.isNil:
    flowEvent = eventNamed("ct/updated-flow")
    if flowEvent.isNil:
      await afterMs(25)
      flowWaited += 25
  report("ct/updated-flow arrives as an unsolicited event, not a response",
    not flowEvent.isNil, "events seen: " & $events.len)

  # `ct/originChain` (Value-Origin-Tracking M2) is NOT exercised here: it
  # traps the WASM engine, like `ct/load-locals`. See probe_engine_defects.mjs.

  # The general proof that the event channel is live, independent of any one
  # command: the engine emits `stopped` and `ct/complete-move` for every
  # navigation, and they must reach `onEventProc`.
  report("navigation events reach onEventProc",
    (not eventNamed("stopped").isNil) and
    (not eventNamed("ct/complete-move").isNil) and
    (not eventNamed("initialized").isNil),
    "events seen: " & $events.len)

  # --- stepping -----------------------------------------------------------
  # Walk forward a few steps, recording the line at each stop, then reverse
  # one step and check we land back where we were.
  #
  # We step in from the entry point rather than reversing immediately: a
  # reverse step that reaches the *beginning* of the trace makes the engine
  # emit a boundary warning, and `Notification::new` (task.rs:1960) calls
  # `SystemTime::now()`, which is unimplemented on wasm32-unknown-unknown and
  # traps the whole worker. That is an engine defect, reported separately; it
  # is not what this test is measuring, so it stays out of the path.
  var lines: seq[int] = @[entryLine]
  var forwardOk = true
  for i in 1 .. 4:
    let stepped = await service.send("next", %*{"threadId": 1})
    if not stepped.succeeded:
      forwardOk = false
      report("step forward (next) #" & $i, false, $stepped)
      break
    let at = await service.send("stackTrace", %*{"threadId": 1})
    let atLine = at.topFrame{"line"}.getInt(0)
    if not at.succeeded or atLine <= 0:
      forwardOk = false
      report("stackTrace after next #" & $i, false, $at)
      break
    lines.add(atLine)
    echo "        after next #" & $i & ": line " & $atLine

  report("stepping forward walks the program", forwardOk and lines.len == 5,
    "collected " & $lines.len & " stops")
  report("stepping forward moves the program counter",
    forwardOk and lines.len > 1 and lines[1] != lines[0],
    "stops: " & $lines)

  if forwardOk:
    let back = await service.send("stepBack", %*{"threadId": 1})
    report("step backward (stepBack)", back.succeeded, $back)
    let afterBack = await service.send("stackTrace", %*{"threadId": 1})
    let backLine = afterBack.topFrame{"line"}.getInt(0)
    echo "        after stepBack: line " & $backLine
    report("stepping backward returns to the previously visited line",
      afterBack.succeeded and backLine == lines[^2],
      "expected line " & $lines[^2] & ", got " & $backLine)

  echo ""
  echo "  DAP events observed: " & $events.len
  for e in events:
    echo "    event: " & e{"event"}.getStr

  # --- teardown -----------------------------------------------------------
  service.disconnect()
  await microtask()
  report("disconnect tears the worker down and strands nothing",
    backend.pendingCount == 0 and backend.disconnected)

  echo ""
  echo "worker/WASM e2e: " & $passed & " passed, " & $failed & " failed"
  if failed > 0:
    quit(1)
  quit(0)

discard run()
