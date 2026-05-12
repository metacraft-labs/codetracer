// gateway-client.js -- Main-thread driver for the M40 browser-replay client.
//
// This module wires the WASM replay-server to the codetracer-ci authenticated
// gateway (M40 slices 1-3). Concretely it:
//
//   1. Reads the (gatewayBaseUrl, traceId, authToken) configuration from the
//      page URL.
//   2. Boots the WebWorker (worker.js) that loads the replay-server WASM.
//   3. Asks the worker to fetch the recording manifest from
//      `${gatewayBaseUrl}/api/v1/observability/gateway/manifests/${traceId}`
//      with an Authorization: Bearer header, then to fetch every payload-
//      bearing object referenced by the manifest via HTTP Range requests
//      against `${gatewayBaseUrl}/api/v1/observability/gateway/ranges/${traceId}/...`.
//   4. Pushes the fetched bytes into the WASM in-memory VFS so the existing
//      CTFS/MCR loader can replay the trace entirely client-side.
//   5. Drives the DAP initialize / launch / configurationDone handshake plus
//      a follow-up state-inspection sequence (threads, stackTrace, scopes,
//      variables, setBreakpoints) and surfaces a hard-asserted result on
//      `window.__replayTestResult` for Playwright (and any future
//      codetracer-ci integration test) to inspect. The state-inspection
//      sequence (F5) is what proves the user can actually examine real
//      captured program state through the live MCR replay path.
//
// The WASM module itself is NOT modified -- the gateway URL and auth token
// are intercepted on the JavaScript side, then the bytes are presented to
// the WASM via the existing `vfs_write_file` binding. This is "Path A"
// from the M40 implementation guidance: the WASM source stays untouched.

const statusEl = document.getElementById("status");
const logEl = document.getElementById("log");

function setStatus(text, level = "pending") {
  if (!statusEl) return;
  statusEl.textContent = text;
  statusEl.className = level;
}

function appendLog(msg) {
  if (!logEl) return;
  const line = `[${new Date().toISOString().slice(11, 23)}] ${msg}\n`;
  logEl.textContent += line;
  logEl.scrollTop = logEl.scrollHeight;
  // Mirror to console so Playwright captures it too.
  // eslint-disable-next-line no-console
  console.log(`[browser-replay] ${msg}`);
}

function safeStringify(value, maxLen = 400) {
  let str;
  try {
    str = JSON.stringify(value ?? null);
  } catch {
    str = String(value);
  }
  return str.length > maxLen ? str.slice(0, maxLen) + "..." : str;
}

// ---------------------------------------------------------------------------
// Configuration
// ---------------------------------------------------------------------------

const params = new URLSearchParams(window.location.search);
const gatewayBaseUrl = (params.get("gatewayBaseUrl") || "").replace(/\/+$/, "");
const traceId = params.get("traceId") || "";
const authToken = params.get("authToken") || "";
const traceFolder = params.get("traceFolder") || "trace";
const testMode = params.get("mode") || "basic";

const haveGatewayConfig = Boolean(gatewayBaseUrl && traceId && authToken);
appendLog(
  `config: gatewayBaseUrl=${gatewayBaseUrl ? "<set>" : "<unset>"}, ` +
    `traceId=${traceId || "<unset>"}, ` +
    `authToken=${authToken ? "<set>" : "<unset>"}, ` +
    `traceFolder=${traceFolder}, mode=${testMode}`,
);

// ---------------------------------------------------------------------------
// Worker bootstrap
// ---------------------------------------------------------------------------

const worker = new Worker(new URL("./worker.js", import.meta.url), { type: "module" });
let workerAlive = true;
let nextSeq = 1;

worker.onerror = (event) => {
  workerAlive = false;
  appendLog(`WORKER ERROR: ${event.message}`);
  setStatus(`Worker error: ${event.message}`, "error");
};

function waitForMessage(predicate, timeoutMs, label) {
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => {
      worker.removeEventListener("message", handler);
      reject(new Error(`Timed out waiting for ${label} after ${timeoutMs}ms`));
    }, timeoutMs);

    function handler(event) {
      try {
        if (predicate(event.data)) {
          worker.removeEventListener("message", handler);
          clearTimeout(timer);
          resolve(event.data);
        }
      } catch (err) {
        worker.removeEventListener("message", handler);
        clearTimeout(timer);
        reject(err);
      }
    }
    worker.addEventListener("message", handler);
  });
}

function collectMessages(durationMs = 2000) {
  return new Promise((resolve) => {
    const messages = [];
    function handler(event) {
      const data = event.data;
      if (typeof data === "string") {
        try {
          messages.push(JSON.parse(data));
        } catch {
          messages.push(data);
        }
      } else {
        messages.push(data);
      }
    }
    worker.addEventListener("message", handler);
    setTimeout(() => {
      worker.removeEventListener("message", handler);
      resolve(messages);
    }, durationMs);
  });
}

async function sendDapRequest(command, args = {}, collectMs = 3000, postResponseGraceMs = 150) {
  if (!workerAlive) {
    return { response: null, events: [], allMessages: [], seq: -1, workerDead: true };
  }
  const seq = nextSeq++;
  // Short-circuit collector: resolve as soon as the response arrives,
  // plus a small grace window so trailing `event` messages (like the
  // `stopped` event after configurationDone) are picked up too. If no
  // response shows up within `collectMs`, fall back to the original
  // "drain everything until timeout" behaviour. This keeps the existing
  // semantics for cases where the WASM does not respond at all (so the
  // test can assert response: null) while bringing the F5 multi-request
  // sequence under the Playwright test timeout.
  return new Promise((resolve) => {
    const messages = [];
    let hardTimer = null;
    let graceTimer = null;

    function finish() {
      worker.removeEventListener("message", handler);
      if (hardTimer) clearTimeout(hardTimer);
      if (graceTimer) clearTimeout(graceTimer);
      const response = messages.find((m) => m && m.command === command && m.type === "response") || null;
      const events = messages.filter((m) => m && m.type === "event");
      resolve({ response, events, allMessages: messages, seq });
    }

    function handler(event) {
      const data = event.data;
      let parsed;
      if (typeof data === "string") {
        try {
          parsed = JSON.parse(data);
        } catch {
          parsed = data;
        }
      } else {
        parsed = data;
      }
      messages.push(parsed);
      if (parsed && parsed.command === command && parsed.type === "response" && !graceTimer) {
        graceTimer = setTimeout(finish, postResponseGraceMs);
      }
    }

    worker.addEventListener("message", handler);
    worker.postMessage({ seq, type: "request", command, arguments: args });
    hardTimer = setTimeout(finish, collectMs);
  });
}

// Expose a hook for the legacy "Send DAP Initialize" button in index.html.
window.addEventListener("manual-dap-initialize", async () => {
  appendLog("manual DAP initialize requested");
  const result = await sendDapRequest("initialize", {
    clientID: "codetracer-browser",
    clientName: "CodeTracer Browser",
    adapterID: "codetracer",
    linesStartAt1: true,
    columnsStartAt1: true,
    pathFormat: "path",
  });
  appendLog(`manual initialize response: ${safeStringify(result.response)}`);
});

// ---------------------------------------------------------------------------
// Main flow
// ---------------------------------------------------------------------------

(async () => {
  try {
    setStatus("Loading WASM module...", "pending");
    await waitForMessage((d) => d && d.type === "wasm-loaded", 30_000, "wasm-loaded");
    appendLog("WASM module loaded");

    if (!haveGatewayConfig) {
      // Legacy / manual mode: leave the page idle so the user (or an external
      // test) can drive the worker by hand. The "Send DAP Initialize" button
      // is enabled so the original transport-test flow still works.
      setStatus("Idle (no gateway configuration)", "pending");
      const btn = document.getElementById("manualInitBtn");
      if (btn) btn.disabled = false;
      window.__replayTestResult = {
        success: false,
        error: "no gateway configuration provided",
        wasmLoaded: true,
      };
      return;
    }

    // -------------------------------------------------------------------
    // Step 1: Fetch + load through the gateway. Done inside the worker so
    // the bytes never have to cross postMessage as ArrayBuffers larger than
    // what we strictly need.
    // -------------------------------------------------------------------
    setStatus("Fetching manifest and trace bytes from gateway...", "pending");
    worker.postMessage({
      type: "load-trace-from-gateway",
      gatewayBaseUrl,
      traceId,
      authToken,
      traceFolder,
    });

    const loadResult = await new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        worker.removeEventListener("message", handler);
        reject(new Error("timed out waiting for trace-loaded after 30s"));
      }, 30_000);
      function handler(event) {
        const data = event.data;
        if (data && data.type === "trace-loaded") {
          worker.removeEventListener("message", handler);
          clearTimeout(timer);
          resolve(data);
        } else if (data && data.type === "trace-load-error") {
          worker.removeEventListener("message", handler);
          clearTimeout(timer);
          reject(new Error(`trace load failed: ${data.error}`));
        }
      }
      worker.addEventListener("message", handler);
    });

    appendLog(`gateway: manifest=${loadResult.manifestStatus}, ranges=${loadResult.rangeStatuses.join(",")}`);
    for (const f of loadResult.files) {
      appendLog(`VFS: ${f.vfsPath} (${f.bytes} bytes, source=${f.source})`);
    }

    // -------------------------------------------------------------------
    // Step 2: Run the standard DAP handshake.
    // -------------------------------------------------------------------
    setStatus("Starting DAP server...", "pending");
    worker.postMessage({ type: "start" });
    await waitForMessage((d) => d === "ready", 10_000, "DAP ready");
    appendLog("DAP server started");

    setStatus("Sending DAP initialize...", "pending");
    const initResult = await sendDapRequest("initialize", {
      clientID: "codetracer-browser",
      clientName: "CodeTracer Browser",
      adapterID: "codetracer",
      linesStartAt1: true,
      columnsStartAt1: true,
      supportsRunInTerminalRequest: false,
    });
    appendLog(`initialize: ${safeStringify(initResult.response)}`);
    const initOk = !!(initResult.response && initResult.response.success);

    let launchOk = false;
    let configDoneOk = false;
    let stoppedEvent = null;
    let launchResponse = null;
    let configDoneResponse = null;
    if (initOk) {
      const launchResult = await sendDapRequest("launch", { traceFolder });
      appendLog(`launch: ${safeStringify(launchResult.response)}`);
      launchOk = !!(launchResult.response && launchResult.response.success);
      launchResponse = launchResult.response;

      const configResult = await sendDapRequest("configurationDone", {}, 5000);
      appendLog(`configurationDone: ${safeStringify(configResult.response)}`);
      configDoneOk = !!(configResult.response && configResult.response.success);
      configDoneResponse = configResult.response;
      stoppedEvent = configResult.events.find((e) => e.event === "stopped") || null;
    }

    // -------------------------------------------------------------------
    // Step 3 (F5): drive the rest of the DAP session so the test can
    // assert the user can examine real captured program state. We probe
    // threads -> stackTrace -> scopes -> variables, then set a
    // breakpoint at a recognizable line in the recorded source. All
    // results are surfaced on window.__replayTestResult so the
    // Playwright spec can hard-assert against them.
    //
    // The Rust db_backend WASM module (`src/db-backend`) implements all
    // of these requests in `dap_handler.rs`; see `dap_server.rs` for the
    // dispatch table. Executing them only makes sense when launch +
    // configurationDone both succeeded -- otherwise the trace isn't
    // mounted and threads()/stackTrace() will respond with default
    // empties at best, panic at worst (see produce_stack_frame's expect
    // on a valid step_id).
    // -------------------------------------------------------------------
    let threads = null;
    let stackFrames = null;
    let scopes = null;
    let variables = null;
    let breakpointVerified = false;
    let threadsResponse = null;
    let stackTraceResponse = null;
    let scopesResponse = null;
    let variablesResponse = null;
    let setBreakpointsResponse = null;
    let breakpointPath = null;
    let breakpointLine = null;

    if (launchOk && configDoneOk) {
      const threadsResult = await sendDapRequest("threads", {});
      threadsResponse = threadsResult.response;
      appendLog(`threads: ${safeStringify(threadsResult.response)}`);
      threads = (threadsResult.response && threadsResult.response.body && threadsResult.response.body.threads) || null;

      const firstThreadId = threads && threads.length > 0 ? threads[0].id : 1;
      const stackTraceResult = await sendDapRequest("stackTrace", {
        threadId: firstThreadId,
        startFrame: 0,
        levels: 64,
      });
      stackTraceResponse = stackTraceResult.response;
      appendLog(`stackTrace: ${safeStringify(stackTraceResult.response)}`);
      stackFrames =
        (stackTraceResult.response && stackTraceResult.response.body && stackTraceResult.response.body.stackFrames) ||
        null;

      const topFrame = stackFrames && stackFrames.length > 0 ? stackFrames[0] : null;
      if (topFrame) {
        const scopesResult = await sendDapRequest("scopes", { frameId: topFrame.id });
        scopesResponse = scopesResult.response;
        appendLog(`scopes: ${safeStringify(scopesResult.response)}`);
        scopes =
          (scopesResult.response && scopesResult.response.body && scopesResult.response.body.scopes) || null;

        const firstScope = scopes && scopes.length > 0 ? scopes[0] : null;
        if (firstScope) {
          const variablesResult = await sendDapRequest("variables", {
            variablesReference: firstScope.variablesReference,
          });
          variablesResponse = variablesResult.response;
          appendLog(`variables: ${safeStringify(variablesResult.response)}`);
          variables =
            (variablesResult.response && variablesResult.response.body && variablesResult.response.body.variables) ||
            null;
        }
      }

      // Pick a recognizable line for the breakpoint. Prefer the top stack
      // frame's source.path + the recorded line number (which is the
      // line the program is currently stopped at) -- that line is by
      // definition reachable in the recorded trace, so the WASM should
      // verify the breakpoint as set. We deliberately don't hard-code
      // the inventory_service.nim path because the recorded program may
      // be stopped inside an imported module (asynchttpserver, etc.); a
      // breakpoint at the top frame is always a frame the user could
      // visit while inspecting captured state.
      const breakpointSource =
        topFrame && topFrame.source && typeof topFrame.source.path === "string"
          ? topFrame.source.path
          : null;
      const breakpointLineCandidate =
        topFrame && typeof topFrame.line === "number" && topFrame.line > 0 ? topFrame.line : null;

      if (breakpointSource && breakpointLineCandidate) {
        breakpointPath = breakpointSource;
        breakpointLine = breakpointLineCandidate;
        const setBreakpointsResult = await sendDapRequest("setBreakpoints", {
          source: { path: breakpointSource, name: breakpointSource.split("/").pop() || breakpointSource },
          breakpoints: [{ line: breakpointLineCandidate }],
          lines: [breakpointLineCandidate],
        });
        setBreakpointsResponse = setBreakpointsResult.response;
        appendLog(`setBreakpoints: ${safeStringify(setBreakpointsResult.response)}`);
        const bps =
          (setBreakpointsResult.response &&
            setBreakpointsResult.response.body &&
            setBreakpointsResult.response.body.breakpoints) ||
          [];
        // The WASM marks every breakpoint with `verified: true` once it
        // resolves the source line; treat any verified entry as success.
        breakpointVerified = bps.some((b) => b && b.verified === true);
      } else {
        appendLog(
          `setBreakpoints: skipped (top frame has no usable source.path or line: path=${breakpointSource}, line=${breakpointLineCandidate})`,
        );
      }
    }

    // -------------------------------------------------------------------
    // M-Step-Stress: when launched in `mode=step-stress`, drive the
    // additional DAP step actions and capture a per-action stackTrace
    // snapshot. The Playwright spec asserts that the (file, line, frame
    // depth) tuple evolves as expected:
    //
    //   * `next` (step-over) — line advances within the same frame.
    //   * `stepIn` — frame depth grows or the top frame's name changes.
    //   * `stepOut` — frame depth shrinks (or top frame name reverts).
    //   * `continue` — halts at a breakpoint (or reports "no
    //     breakpoint hit" when no breakpoint is set after stepIn).
    //
    // Reverse step is intentionally exercised too — the EmulatorReplaySession
    // returns an error for reverse, and we surface that response so the
    // Playwright spec can assert the diagnostic surfaces cleanly.
    // -------------------------------------------------------------------
    const stepStressEnabled = testMode === "step-stress" && launchOk && configDoneOk;
    const stepStress = stepStressEnabled
      ? {
          enabled: true,
          actions: [],
        }
      : { enabled: false };

    if (stepStressEnabled) {
      const firstThreadId = (threads && threads.length > 0 && threads[0].id) || 1;
      const recordStep = async (label, command, reverse = false) => {
        appendLog(`step-stress: sending ${label}`);
        const response = await sendDapRequest(
          command,
          {
            threadId: firstThreadId,
            // `reverse` is what the DAP next/stepIn/stepOut/continue
            // schemas use for the reverse-execution variant; the
            // db-backend's `dap_handler.rs::step` reads `arg.reverse`.
            reverse,
            granularity: "line",
            singleThread: true,
          },
          // step requests can take longer on a real `.ct` because the
          // emulator may have to walk thousands of instructions.
          15_000,
        );
        const stResult = await sendDapRequest("stackTrace", {
          threadId: firstThreadId,
          startFrame: 0,
          levels: 64,
        });
        const stFrames =
          (stResult.response && stResult.response.body && stResult.response.body.stackFrames) || [];
        const top = stFrames[0] || null;
        stepStress.actions.push({
          label,
          command,
          reverse,
          responseSuccess: !!(response.response && response.response.success),
          responseMessage:
            (response.response && (response.response.message || (response.response.body && response.response.body.error))) ||
            null,
          stackDepth: stFrames.length,
          topFrameName: top ? top.name : null,
          topFrameLine: top ? top.line : null,
          topFramePath: top && top.source ? top.source.path : null,
        });
      };

      try {
        // 1. step-over (next).
        await recordStep("next", "next");
        // 2. step-in.
        await recordStep("stepIn", "stepIn");
        // 3. step-out.
        await recordStep("stepOut", "stepOut");
        // 4. continue. We rely on the breakpoint we already set above.
        //    The continue response from an emulator-backed session may
        //    report success even when no breakpoint is hit; the
        //    Playwright spec inspects the post-continue stackTrace to
        //    distinguish.
        await recordStep("continue", "continue");
        // 5. reverse step — must surface an error response so the
        //    DAP client knows reverse is unsupported on MCR.
        await recordStep("reverse-next", "next", true);
      } catch (stepErr) {
        appendLog(`step-stress: aborted with ${stepErr.message}`);
        stepStress.error = stepErr.message;
      }
    }

    const result = {
      success: initOk,
      gatewayBaseUrl,
      traceId,
      manifestStatus: loadResult.manifestStatus,
      rangeStatuses: loadResult.rangeStatuses,
      files: loadResult.files,
      initResponse: initResult.response,
      launchSucceeded: launchOk,
      launchResponse,
      configDoneSucceeded: configDoneOk,
      configDoneResponse,
      stoppedEvent,
      // F5 fields.
      threads,
      threadsResponse,
      stackFrames,
      stackTraceResponse,
      scopes,
      scopesResponse,
      variables,
      variablesResponse,
      breakpointVerified,
      setBreakpointsResponse,
      breakpointPath,
      breakpointLine,
      // M-Step-Stress fields.
      stepStress,
    };

    window.__replayTestResult = result;

    if (initOk) {
      setStatus(
        `Replay ready -- manifest=${loadResult.manifestStatus}, ` +
          `ranges=${loadResult.rangeStatuses.join(",")}, ` +
          `dap=ok, threads=${threads ? threads.length : 0}, frames=${stackFrames ? stackFrames.length : 0}, ` +
          `vars=${variables ? variables.length : 0}, bp=${breakpointVerified ? "verified" : "unverified"}`,
        "ok",
      );
    } else {
      setStatus("DAP initialize failed", "error");
    }
  } catch (err) {
    appendLog(`ERROR: ${err.message}`);
    setStatus(`Error: ${err.message}`, "error");
    window.__replayTestResult = { success: false, error: err.message };
  }
})();
