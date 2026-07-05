// replay-test.js — Main-thread driver for the client-side WASM replay test.
//
// This script:
//   1. Parses trace configuration from URL query parameters.
//   2. Creates a WebWorker (worker.js) that loads the WASM DAP server.
//   3. Tells the worker to fetch trace files from the HTTP server into the VFS.
//   4. Starts the DAP server and sends the full DAP initialization sequence.
//   5. Sends comprehensive DAP requests (threads, stackTrace, scopes, variables,
//      stepping, events) and collects results.
//   6. Reports results via window.__replayTestResult that Playwright can observe.
//
// The server is assumed to be a dumb static file server — no server-side
// logic, no WebSocket, no custom endpoints. The browser does everything.

// ---------------------------------------------------------------------------
// DOM helpers
// ---------------------------------------------------------------------------

const statusEl = document.getElementById("status");
const logEl = document.getElementById("log");

function setStatus(text, level = "pending") {
  statusEl.textContent = text;
  statusEl.className = `status ${level}`;
}

function appendLog(msg) {
  const line = `[${new Date().toISOString().slice(11, 23)}] ${msg}\n`;
  logEl.textContent += line;
  // Auto-scroll to bottom.
  logEl.scrollTop = logEl.scrollHeight;
  console.log(`[replay-test] ${msg}`);
}

/** Safely stringify a value for logging (handles undefined/null). */
function safeStringify(value, maxLen = 300) {
  const str = JSON.stringify(value ?? null);
  return str.length > maxLen ? str.slice(0, maxLen) + "..." : str;
}

// ---------------------------------------------------------------------------
// Configuration from query parameters
// ---------------------------------------------------------------------------

const params = new URLSearchParams(window.location.search);

// VFS folder name — trace files are written as `<traceFolder>/<filename>`.
const traceFolder = params.get("traceFolder") || "trace";

// Comma-separated list of file names to fetch from the server.
//
// Default: the canonical CTFS bundle layout — a single `trace.ct` file
// containing all metadata + events.  Per the CTFS migration directive
// (Trace-Files/CTFS-Migration-Guide.md §3e), `.ct` is the only supported
// materialized-trace format; the legacy `trace.json` /
// `trace_metadata.json` / `trace_paths.json` triplet is no longer used.
const fileNames = (params.get("files") || "trace.ct")
  .split(",")
  .map((s) => s.trim())
  .filter(Boolean);

// Base URL for trace files on the server. Defaults to /traces/ relative to
// the current origin.
const traceBaseUrl = params.get("traceBaseUrl") || "/traces/";

// Optional trace file name for the DAP launch request. This is needed when
// the VFS payload is a real fixture name such as `trace-portable.ct` rather
// than the canonical auto-detected `trace.ct`.
const traceFile = params.get("traceFile") || "";

// Mode: "basic" (original DAP init only) or "comprehensive" (full panel verification).
// Default: "comprehensive".
const testMode = params.get("mode") || "comprehensive";

appendLog(`traceFolder=${traceFolder}, files=[${fileNames.join(", ")}]`);
appendLog(`traceBaseUrl=${traceBaseUrl}, mode=${testMode}`);

// ---------------------------------------------------------------------------
// Worker lifecycle
// ---------------------------------------------------------------------------

const worker = new Worker(new URL("./worker.js", import.meta.url), {
  type: "module",
});

// Monotonically increasing DAP sequence number.
let nextSeq = 1;

// Track whether the worker has crashed.
let workerAlive = true;

/**
 * Wait for a specific message type from the worker.
 * Returns a promise that resolves with the message data.
 */
function waitForMessage(type, timeoutMs = 30_000) {
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => {
      worker.removeEventListener("message", handler);
      reject(
        new Error(
          `Timed out waiting for worker message type="${type}" after ${timeoutMs}ms`,
        ),
      );
    }, timeoutMs);

    function handler(event) {
      const data = event.data;
      // DAP responses come as plain strings (JSON).
      if (type === "dap-response" && typeof data === "string") {
        worker.removeEventListener("message", handler);
        clearTimeout(timer);
        resolve(JSON.parse(data));
        return;
      }
      if (data && data.type === type) {
        worker.removeEventListener("message", handler);
        clearTimeout(timer);
        resolve(data);
        return;
      }
      if (data && data.type === 'worker-error') {
        appendLog(`WORKER MESSAGE ERROR: ${safeStringify(data, 2000)}`);
      }
    }
    worker.addEventListener("message", handler);
  });
}

/**
 * Collect all worker messages for a given duration. Useful for DAP responses
 * where multiple messages arrive after a single request.
 */
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

/**
 * Send a DAP request and collect all responses/events within the timeout window.
 * Returns an object with the matching response and any events.
 */
async function sendDapRequest(command, args = {}, collectMs = 3000) {
  if (!workerAlive) {
    return {
      response: null,
      events: [],
      allMessages: [],
      seq: -1,
      workerDead: true,
    };
  }
  const seq = nextSeq++;
  const allMessages = [];
  const collector = new Promise((resolve) => {
    let settleTimer = null;
    const maxTimer = setTimeout(done, collectMs);

    function done() {
      worker.removeEventListener("message", handler);
      clearTimeout(maxTimer);
      if (settleTimer) {
        clearTimeout(settleTimer);
      }
      resolve(allMessages);
    }

    function scheduleSettle() {
      if (settleTimer) {
        clearTimeout(settleTimer);
      }
      settleTimer = setTimeout(done, 150);
    }

    function handler(event) {
      const data = event.data;
      let message = data;
      if (typeof data === "string") {
        try {
          message = JSON.parse(data);
        } catch {
          message = data;
        }
      }
      allMessages.push(message);
      if (
        message &&
        message.command === command &&
        message.type === "response" &&
        message.request_seq === seq
      ) {
        scheduleSettle();
      }
    }
    worker.addEventListener("message", handler);
  });
  worker.postMessage({
    seq,
    type: "request",
    command,
    arguments: args,
  });
  await collector;
  const responses = allMessages.filter(
    (r) => r.command === command && r.type === "response",
  );
  const response =
    responses.find((r) => r.success === false) ||
    responses[responses.length - 1] ||
    null;
  const events = allMessages.filter((r) => r.type === "event");
  return { response, events, allMessages, seq };
}

worker.onerror = (event) => {
  appendLog(`WORKER ERROR: ${event.message}`);
  workerAlive = false;
  setStatus("Worker error — see console", "error");
};

// ---------------------------------------------------------------------------
// Helper: query stack/scopes/variables at the current position
// ---------------------------------------------------------------------------

/**
 * Query the current stack trace, scopes, and variables.
 * Returns an object with all the collected data.
 */
async function queryCurrentState() {
  const state = {};

  // Stack trace
  const stackResult = await sendDapRequest("stackTrace", {
    threadId: 1,
    startFrame: 0,
    levels: 20,
  });
  state.stackTrace = stackResult.response?.body || null;
  appendLog(`stackTrace: ${safeStringify(state.stackTrace, 500)}`);

  // Scopes and variables (only if we have frames)
  if (state.stackTrace?.stackFrames?.length > 0) {
    const topFrameId = state.stackTrace.stackFrames[0].id;
    const scopesResult = await sendDapRequest("scopes", {
      frameId: topFrameId,
    });
    state.scopes = scopesResult.response?.body || null;
    appendLog(`scopes: ${safeStringify(state.scopes, 500)}`);

    if (state.scopes?.scopes?.length > 0) {
      const allVariables = [];
      for (const scope of state.scopes.scopes) {
        const varsResult = await sendDapRequest("variables", {
          variablesReference: scope.variablesReference,
        });
        const vars = varsResult.response?.body?.variables || [];
        appendLog(`variables for "${scope.name}": ${safeStringify(vars, 500)}`);
        allVariables.push({
          scopeName: scope.name,
          variablesReference: scope.variablesReference,
          variables: vars,
        });
      }
      state.variables = allVariables;
    }
  }

  return state;
}

function topFrameSignature(state) {
  const frame = state.stackTrace?.stackFrames?.[0];
  if (!frame) {
    return null;
  }
  return {
    name: frame.name || "",
    sourcePath: frame.source?.path || "",
    line: frame.line ?? null,
    column: frame.column ?? null,
    instructionPointerReference: frame.instructionPointerReference || "",
  };
}

function variableValue(state, name) {
  for (const scope of state.variables || []) {
    const found = (scope.variables || []).find(
      (variable) => variable.name === name,
    );
    if (found) {
      return found.value;
    }
  }
  return null;
}

function stateSignature(state) {
  return {
    topFrame: topFrameSignature(state),
    rip: variableValue(state, "rip"),
    rsp: variableValue(state, "rsp"),
  };
}

function signaturesEqual(left, right) {
  return JSON.stringify(left) === JSON.stringify(right);
}

function messageTicks(message) {
  const body = message?.body;
  return (
    body?.location?.rrTicks ??
    body?.location?.rr_ticks ??
    body?.rrTicks ??
    body?.rr_ticks ??
    null
  );
}

function latestTicksFromMessages(messages) {
  for (const message of [...messages].reverse()) {
    const ticks = messageTicks(message);
    if (typeof ticks === "number") {
      return ticks;
    }
  }
  return null;
}

// ---------------------------------------------------------------------------
// Main sequence
// ---------------------------------------------------------------------------

(async () => {
  try {
    // Step 1: Wait for WASM to load in the worker.
    setStatus("Loading WASM module...", "pending");
    await waitForMessage("wasm-loaded");
    appendLog("WASM module loaded in worker");

    // Step 2: Tell the worker to fetch trace files from the HTTP server.
    setStatus("Fetching trace files from server...", "pending");
    const filesToFetch = fileNames.map((name) => ({
      url: `${traceBaseUrl}${name}`,
      vfsPath: `${traceFolder}/${name}`,
    }));
    appendLog(
      `Requesting ${filesToFetch.length} file(s): ${filesToFetch.map((f) => f.url).join(", ")}`,
    );

    worker.postMessage({ type: "load-trace", files: filesToFetch });

    // Wait for either success or error from the worker.
    const loadResult = await new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        worker.removeEventListener("message", handler);
        reject(new Error("Timed out waiting for trace-loaded after 30s"));
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
          reject(new Error(`Trace load failed: ${data.error}`));
        }
      }
      worker.addEventListener("message", handler);
    });
    for (const f of loadResult.files) {
      appendLog(`VFS: ${f.vfsPath} (${f.bytes} bytes)`);
    }
    appendLog("All trace files loaded into VFS");

    // Step 3: Start the DAP server.
    setStatus("Starting DAP server...", "pending");
    worker.postMessage({ type: "start" });
    // wasm_start() posts the string "ready".
    await new Promise((resolve, reject) => {
      const timer = setTimeout(
        () => reject(new Error("DAP start timeout")),
        10_000,
      );
      function handler(event) {
        if (event.data === "ready") {
          worker.removeEventListener("message", handler);
          clearTimeout(timer);
          resolve();
        }
      }
      worker.addEventListener("message", handler);
    });
    appendLog("DAP server started (ready)");

    // Step 4: Send DAP initialize request.
    setStatus("Sending DAP initialize...", "pending");
    const initResult = await sendDapRequest("initialize", {
      clientID: "wasm-replay-test",
      clientName: "WASM Replay Test",
      adapterID: "codetracer",
      linesStartAt1: true,
      columnsStartAt1: true,
      supportsRunInTerminalRequest: false,
    });
    const initResponse = initResult.response;
    appendLog(`initialize: ${safeStringify(initResponse)}`);
    if (!initResponse || !initResponse.success) {
      throw new Error("DAP initialize failed: " + safeStringify(initResponse));
    }
    appendLog("DAP initialize succeeded");

    // Step 5: Send DAP launch request.
    setStatus("Sending DAP launch...", "pending");
    const launchArguments = {
      traceFolder: traceFolder,
    };
    if (traceFile) {
      launchArguments.trace_file = traceFile;
    }
    const launchResult = await sendDapRequest("launch", launchArguments);
    appendLog(`launch: ${safeStringify(launchResult.response)}`);
    if (!launchResult.response || !launchResult.response.success) {
      throw new Error(
        "DAP launch failed: " + safeStringify(launchResult.response),
      );
    }

    // Step 6: Send configurationDone — triggers VFS setup_from_vfs.
    setStatus("Sending DAP configurationDone...", "pending");
    const configResult = await sendDapRequest("configurationDone", {}, 5000);
    const configDoneResp = configResult.response;
    appendLog(`configurationDone: ${safeStringify(configDoneResp)}`);
    if (!configDoneResp || !configDoneResp.success) {
      throw new Error(
        "DAP configurationDone failed: " + safeStringify(configDoneResp),
      );
    }

    // Check for stopped event (indicates trace loaded and at entry point).
    const stoppedEvent = configResult.events.find((r) => r.event === "stopped");
    if (stoppedEvent) {
      appendLog(
        `Stopped event received (reason: ${stoppedEvent.body?.reason})`,
      );
    }

    // -----------------------------------------------------------------------
    // Basic result (always computed)
    // -----------------------------------------------------------------------
    const totalResponses =
      initResult.allMessages.length +
      launchResult.allMessages.length +
      configResult.allMessages.length;

    const result = {
      success: true,
      initResponse,
      launchResponse: launchResult.response,
      configDoneResponse: configDoneResp,
      stoppedEvent: stoppedEvent || null,
      totalResponses,
    };

    // -----------------------------------------------------------------------
    // Comprehensive panel verification (when mode=comprehensive or mode=seek)
    // -----------------------------------------------------------------------
    if (testMode === "comprehensive" || testMode === "seek") {
      setStatus("Running comprehensive panel verification...", "pending");

      // --- Threads ---
      appendLog("Requesting threads...");
      const threadsResult = await sendDapRequest("threads", {});
      result.threads = threadsResult.response?.body || null;
      appendLog(`threads: ${safeStringify(result.threads)}`);

      // --- Query state at entry point ---
      appendLog("Querying state at entry point...");
      const entryState = await queryCurrentState();
      result.stackTrace = entryState.stackTrace;
      result.scopes = entryState.scopes || null;
      result.variables = entryState.variables || null;

      // --- Step forward (stepIn) to advance into the trace ---
      // Use stepIn instead of next to ensure we move even if entry is
      // at a function call boundary. Step multiple times to reach a point
      // with variables.
      appendLog(
        "Stepping forward (stepIn x3) to reach a step with variables...",
      );
      let stepOk = true;
      let latestStepTicks = null;
      for (let i = 0; i < 3 && workerAlive; i++) {
        const stepResult = await sendDapRequest(
          "stepIn",
          { threadId: 1 },
          5000,
        );
        if (!stepResult.response?.success) {
          appendLog(
            `stepIn ${i + 1} failed or no response: ${safeStringify(stepResult.response)}`,
          );
          stepOk = false;
          break;
        }
        const stepTicks = latestTicksFromMessages(stepResult.allMessages);
        if (typeof stepTicks === "number") {
          latestStepTicks = stepTicks;
        }
        appendLog(`stepIn ${i + 1}: success`);
      }
      result.steppingSucceeded = stepOk;

      // --- Query state after stepping ---
      if (stepOk && workerAlive) {
        appendLog("Querying state after stepping...");
        const afterStepState = await queryCurrentState();
        result.stackTraceAfterStep = afterStepState.stackTrace;
        result.scopesAfterStep = afterStepState.scopes || null;
        result.variablesAfterStep = afterStepState.variables || null;

        if (testMode === "seek") {
          const earlyTicks = 0;
          const laterTicks = latestStepTicks;
          if (typeof laterTicks !== "number") {
            throw new Error("Could not determine tick reached by stepIn");
          }
          const earlySignature = stateSignature(entryState);
          const laterSignature = stateSignature(afterStepState);
          result.seek = {
            earlyTicks,
            laterTicks,
            earlySignature,
            laterSignature,
            laterDistinctFromEarly: !signaturesEqual(
              earlySignature,
              laterSignature,
            ),
          };

          appendLog(
            `seek early signature: ${safeStringify(earlySignature, 500)}`,
          );
          appendLog(
            `seek later signature: ${safeStringify(laterSignature, 500)}`,
          );

          appendLog(`Requesting ct/goto-ticks back to ${earlyTicks}...`);
          const seekBackResult = await sendDapRequest(
            "ct/goto-ticks",
            {
              threadId: 1,
              ticks: earlyTicks,
            },
            1000,
          );
          result.seek.backResponse = seekBackResult.response || null;
          result.seek.backCompleteMove =
            seekBackResult.events.find(
              (event) => event.event === "ct/complete-move",
            ) || null;
          result.seek.backMessages = seekBackResult.allMessages;
          appendLog(
            `ct/goto-ticks back: ${safeStringify(seekBackResult.response)}`,
          );

          const afterSeekBackState = await queryCurrentState();
          result.seek.afterBackSignature = stateSignature(afterSeekBackState);
          result.seek.backMatchesEarly = signaturesEqual(
            result.seek.afterBackSignature,
            earlySignature,
          );
          appendLog(
            `seek after back signature: ${safeStringify(result.seek.afterBackSignature, 500)}`,
          );

          appendLog(`Requesting ct/goto-ticks forward to ${laterTicks}...`);
          const seekForwardResult = await sendDapRequest(
            "ct/goto-ticks",
            {
              threadId: 1,
              ticks: laterTicks,
            },
            1000,
          );
          result.seek.forwardResponse = seekForwardResult.response || null;
          result.seek.forwardCompleteMove =
            seekForwardResult.events.find(
              (event) => event.event === "ct/complete-move",
            ) || null;
          result.seek.forwardMessages = seekForwardResult.allMessages;
          appendLog(
            `ct/goto-ticks forward: ${safeStringify(seekForwardResult.response)}`,
          );

          const afterSeekForwardState = await queryCurrentState();
          result.seek.afterForwardSignature = stateSignature(
            afterSeekForwardState,
          );
          result.seek.forwardMatchesLater = signaturesEqual(
            result.seek.afterForwardSignature,
            laterSignature,
          );
          appendLog(
            `seek after forward signature: ${safeStringify(result.seek.afterForwardSignature, 500)}`,
          );
        }
      }

      // --- Event log (ct/event-load) ---
      if (workerAlive) {
        appendLog("Requesting ct/event-load...");
        const eventResult = await sendDapRequest("ct/event-load", {}, 3000);
        result.eventLog = eventResult.response?.body || null;
        appendLog(`event-load: ${safeStringify(result.eventLog, 500)}`);
      }
    }

    // -----------------------------------------------------------------------
    // Final status
    // -----------------------------------------------------------------------
    if (stoppedEvent) {
      setStatus("DAP replay ready — trace loaded and stopped at entry", "ok");
    } else {
      setStatus("DAP initialized and configured — trace loaded", "ok");
    }

    // Expose results for Playwright assertions.
    window.__replayTestResult = result;
  } catch (err) {
    appendLog(`ERROR: ${err.message}`);
    setStatus(`Error: ${err.message}`, "error");
    window.__replayTestResult = { success: false, error: err.message };
  }
})();
