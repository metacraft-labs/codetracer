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
//   5. Drives the DAP initialize / launch / configurationDone handshake and
//      surfaces a hard-asserted result on `window.__replayTestResult` for
//      Playwright (and any future codetracer-ci integration test) to inspect.
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

async function sendDapRequest(command, args = {}, collectMs = 3000) {
  if (!workerAlive) {
    return { response: null, events: [], allMessages: [], seq: -1, workerDead: true };
  }
  const seq = nextSeq++;
  const collector = collectMessages(collectMs);
  worker.postMessage({ seq, type: "request", command, arguments: args });
  const allMessages = await collector;
  const response = allMessages.find((m) => m && m.command === command && m.type === "response") || null;
  const events = allMessages.filter((m) => m && m.type === "event");
  return { response, events, allMessages, seq };
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
    if (initOk) {
      const launchResult = await sendDapRequest("launch", { traceFolder });
      appendLog(`launch: ${safeStringify(launchResult.response)}`);
      launchOk = !!(launchResult.response && launchResult.response.success);

      const configResult = await sendDapRequest("configurationDone", {}, 5000);
      appendLog(`configurationDone: ${safeStringify(configResult.response)}`);
      configDoneOk = !!(configResult.response && configResult.response.success);
      stoppedEvent = configResult.events.find((e) => e.event === "stopped") || null;
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
      configDoneSucceeded: configDoneOk,
      stoppedEvent,
    };

    window.__replayTestResult = result;

    if (initOk) {
      setStatus(
        `Replay ready -- manifest=${loadResult.manifestStatus}, ` +
          `ranges=${loadResult.rangeStatuses.join(",")}, ` +
          `dap=ok`,
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
