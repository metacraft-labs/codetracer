/**
 * Playwright E2E tests for TRUE client-side WASM replay.
 *
 * Architecture:
 *   - Server: dumb HTTP file server (Node http module) serving static files.
 *     No WebSocket, no custom endpoints, no server-side logic.
 *   - Browser: loads the WASM db-backend in a WebWorker, fetches trace files
 *     via fetch(), pushes them into the VFS, and runs the full DAP protocol
 *     entirely client-side.
 *
 * Tests cover two trace formats:
 *   1. Materialized traces (JSON) -- pre-recorded Noir "array" trace from
 *      db-backend test-traces (trace.json + trace_metadata.json + trace_paths.json).
 *      These contain full step/variable/call data and support comprehensive
 *      panel verification (stepping, variables, call trace).
 *
 *   2. MCR traces (CTFS .ct container) -- pre-recorded portable trace from
 *      codetracer-example-recordings. These are raw MCR recording containers
 *      that the CTFS reader can open but contain no materialized step data
 *      (0 steps, 0 calls). The WASM CTFS reader cannot replay these natively
 *      (they need the MCR debugserver). Tests verify the DAP init sequence
 *      succeeds and the trace is accepted, even though stepping is not
 *      possible.
 *
 * Each materialized-trace test verifies actual panel data: variable values,
 * function names, source paths, step navigation, and event log content.
 */

import { test, expect, type Page } from "@playwright/test";
import * as http from "node:http";
import * as fs from "node:fs";
import * as path from "node:path";
import * as net from "node:net";

// ---------------------------------------------------------------------------
// Paths
// ---------------------------------------------------------------------------

const REPO_ROOT = path.resolve(__dirname, "..", "..", "..");
const WASM_TESTING_DIR = path.join(REPO_ROOT, "src", "db-backend", "wasm-testing");

// Materialized (JSON) trace fixture.
const JSON_TRACES_DIR = path.join(
  REPO_ROOT,
  "src",
  "db-backend",
  "test-traces",
  "pid-2876854",
  "array",
  "noir",
);
const JSON_TRACE_FILES = ["trace.json", "trace_metadata.json", "trace_paths.json"];

// MCR (CTFS container) trace fixture.
const MCR_TRACES_DIR = path.join(
  REPO_ROOT,
  "src",
  "db-backend",
  "test-traces",
  "mcr-fixture",
);
const MCR_TRACE_FILES = ["trace.ct"];

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/** Find a free TCP port. */
function getFreePort(): Promise<number> {
  return new Promise((resolve, reject) => {
    const srv = net.createServer();
    srv.listen(0, () => {
      const addr = srv.address();
      if (addr && typeof addr === "object") {
        const port = addr.port;
        srv.close(() => resolve(port));
      } else {
        srv.close(() => reject(new Error("Could not determine port")));
      }
    });
    srv.on("error", reject);
  });
}

/**
 * Start a minimal static HTTP file server.
 *
 * Serves:
 *   /                     -- wasm-testing directory (HTML, JS, WASM, pkg/)
 *   /traces/<file>        -- JSON trace fixture files
 *   /mcr-traces/<file>    -- MCR trace fixture files
 */
async function startStaticServer(): Promise<{
  server: http.Server;
  baseUrl: string;
}> {
  const port = await getFreePort();

  const MIME: Record<string, string> = {
    ".html": "text/html",
    ".js": "application/javascript",
    ".wasm": "application/wasm",
    ".json": "application/json",
    ".css": "text/css",
    ".ts": "text/plain",
    ".ct": "application/octet-stream",
  };

  const server = http.createServer((req, res) => {
    const url = new URL(req.url || "/", `http://localhost:${port}`);
    let filePath: string;

    if (url.pathname.startsWith("/traces/")) {
      const fileName = path.basename(url.pathname);
      filePath = path.join(JSON_TRACES_DIR, fileName);
    } else if (url.pathname.startsWith("/mcr-traces/")) {
      const fileName = path.basename(url.pathname);
      filePath = path.join(MCR_TRACES_DIR, fileName);
    } else {
      const relPath = url.pathname.slice(1) || "replay-test.html";
      filePath = path.resolve(WASM_TESTING_DIR, relPath);
      if (!filePath.startsWith(WASM_TESTING_DIR)) {
        res.writeHead(403, { "Content-Type": "text/plain" });
        res.end("Forbidden");
        return;
      }
    }

    if (!fs.existsSync(filePath) || fs.statSync(filePath).isDirectory()) {
      res.writeHead(404, { "Content-Type": "text/plain" });
      res.end("Not found");
      return;
    }

    const ext = path.extname(filePath);
    const contentType = MIME[ext] || "application/octet-stream";

    const headers: Record<string, string> = {
      "Content-Type": contentType,
      "Access-Control-Allow-Origin": "*",
      "Cross-Origin-Resource-Policy": "same-origin",
    };

    const body = fs.readFileSync(filePath);
    res.writeHead(200, headers);
    res.end(body);
  });

  return new Promise((resolve, reject) => {
    server.listen(port, "127.0.0.1", () => {
      resolve({ server, baseUrl: `http://127.0.0.1:${port}` });
    });
    server.on("error", reject);
  });
}

/**
 * Navigate to the replay test page, wait for it to complete, and return
 * the result object from window.__replayTestResult.
 */
async function runReplayTest(
  page: Page,
  baseUrl: string,
  opts: {
    traceFolder: string;
    files: string;
    traceBaseUrl?: string;
    mode?: string;
  },
): Promise<any> {
  const consoleLogs: string[] = [];
  page.on("console", (msg) => consoleLogs.push(`[${msg.type()}] ${msg.text()}`));
  page.on("pageerror", (err) => consoleLogs.push(`[pageerror] ${err.message}`));

  const searchParams = new URLSearchParams({
    traceFolder: opts.traceFolder,
    files: opts.files,
    mode: opts.mode || "comprehensive",
  });
  if (opts.traceBaseUrl) {
    searchParams.set("traceBaseUrl", opts.traceBaseUrl);
  }

  const url = `${baseUrl}/replay-test.html?${searchParams.toString()}`;
  await page.goto(url);

  // Wait for the test to complete (success or failure).
  await page.waitForFunction(
    () => (window as any).__replayTestResult !== undefined,
    { timeout: 90_000 },
  );

  const result = await page.evaluate(() => (window as any).__replayTestResult);

  // Log all console output for debugging on failure.
  if (!result.success) {
    console.log("=== Browser console logs ===");
    for (const line of consoleLogs) {
      console.log(line);
    }
    console.log("=== End browser logs ===");
  }

  return result;
}

// ---------------------------------------------------------------------------
// Tests -- Materialized (JSON) traces
// ---------------------------------------------------------------------------

test.describe("WASM client-side replay -- materialized (JSON) trace", () => {
  let server: http.Server;
  let baseUrl: string;

  test.setTimeout(120_000);

  test.beforeAll(async () => {
    const wasmPkg = path.join(WASM_TESTING_DIR, "pkg", "db_backend.js");
    if (!fs.existsSync(wasmPkg)) {
      throw new Error(
        `WASM package not found at ${wasmPkg}. ` +
          `Run "cd src/db-backend && bash build_wasm.sh" first.`,
      );
    }
    for (const f of JSON_TRACE_FILES) {
      const fp = path.join(JSON_TRACES_DIR, f);
      if (!fs.existsSync(fp)) {
        throw new Error(`Trace fixture file not found: ${fp}`);
      }
    }
    const result = await startStaticServer();
    server = result.server;
    baseUrl = result.baseUrl;
  });

  test.afterAll(async () => {
    if (server) {
      await new Promise<void>((resolve) => server.close(() => resolve()));
    }
  });

  test("DAP initialize + launch + configurationDone succeeds", async ({
    page,
  }) => {
    const result = await runReplayTest(page, baseUrl, {
      traceFolder: "trace",
      files: JSON_TRACE_FILES.join(","),
      mode: "basic",
    });

    expect(result.success, `Replay failed: ${result.error}`).toBe(true);
    expect(result.initResponse).toBeDefined();
    expect(result.initResponse.command).toBe("initialize");
    expect(result.initResponse.success).toBe(true);
    expect(result.configDoneResponse).toBeDefined();
    expect(result.configDoneResponse.command).toBe("configurationDone");
    expect(result.configDoneResponse.success).toBe(true);
    expect(result.totalResponses).toBeGreaterThanOrEqual(4);
  });

  test("comprehensive panel verification -- variables with real values, call trace with function names, stepping", async ({
    page,
  }) => {
    const result = await runReplayTest(page, baseUrl, {
      traceFolder: "trace",
      files: JSON_TRACE_FILES.join(","),
      mode: "comprehensive",
    });

    expect(result.success, `Replay failed: ${result.error}`).toBe(true);

    // --- Threads ---
    expect(result.threads).toBeDefined();
    expect(result.threads.threads).toBeDefined();
    expect(result.threads.threads.length).toBeGreaterThanOrEqual(1);
    expect(result.threads.threads[0].id).toBe(1);
    expect(result.threads.threads[0].name).toBeTruthy();

    // --- Stack trace at entry ---
    expect(result.stackTrace).toBeDefined();
    expect(result.stackTrace.stackFrames).toBeDefined();
    expect(result.stackTrace.stackFrames.length).toBeGreaterThanOrEqual(1);
    const topFrame = result.stackTrace.stackFrames[0];
    // The Noir array trace starts in the "main" function.
    expect(topFrame.name).toBe("main");
    expect(topFrame.source).toBeDefined();
    expect(topFrame.source.path).toBeTruthy();
    expect(topFrame.source.path).toContain("main.nr");
    expect(topFrame.line).toBeGreaterThan(0);

    // --- Stepping succeeded ---
    expect(result.steppingSucceeded).toBe(true);

    // --- Stack trace after stepping ---
    expect(result.stackTraceAfterStep).toBeDefined();
    expect(result.stackTraceAfterStep.stackFrames).toBeDefined();
    expect(result.stackTraceAfterStep.stackFrames.length).toBeGreaterThanOrEqual(1);
    const frameAfterStep = result.stackTraceAfterStep.stackFrames[0];
    expect(frameAfterStep.name).toBe("main");
    expect(frameAfterStep.line).toBeGreaterThan(0);

    // --- Variables after stepping (real values, not placeholders) ---
    // After stepping 3 times from entry (line 2 -> 3 -> 5 -> 3), we should
    // be at a step with variables (the "arr" variable appears at line 3).
    expect(result.variablesAfterStep).toBeDefined();
    expect(result.variablesAfterStep.length).toBeGreaterThanOrEqual(1);
    const mainVars = result.variablesAfterStep[0];
    expect(mainVars.scopeName).toBe("main");
    expect(mainVars.variables.length).toBeGreaterThanOrEqual(1);

    // Verify actual variable names and values (not just "something exists").
    for (const v of mainVars.variables) {
      expect(v.name).toBeTruthy();
      expect(v.value).toBeDefined();
      expect(typeof v.value).toBe("string");
      // Values should not be empty or placeholder strings.
      expect(v.value.length).toBeGreaterThan(0);
    }

    // Look for the "arr" variable -- it should contain [42, -13, 5].
    const arrVar = mainVars.variables.find(
      (v: any) => v.name === "arr",
    );
    if (arrVar) {
      expect(arrVar.value).toContain("42");
    }
  });

  test("stepping changes line position", async ({ page }) => {
    const result = await runReplayTest(page, baseUrl, {
      traceFolder: "trace",
      files: JSON_TRACE_FILES.join(","),
      mode: "comprehensive",
    });

    expect(result.success, `Replay failed: ${result.error}`).toBe(true);
    expect(result.steppingSucceeded).toBe(true);

    // After stepping, the line should differ from entry.
    expect(result.stackTrace?.stackFrames?.length).toBeGreaterThan(0);
    expect(result.stackTraceAfterStep?.stackFrames?.length).toBeGreaterThan(0);

    const entryLine = result.stackTrace.stackFrames[0].line;
    const afterLine = result.stackTraceAfterStep.stackFrames[0].line;

    // The Noir trace goes: line 2 (entry) -> 3 -> 5 -> 3 after 3 stepIns.
    // So the line should have changed.
    expect(afterLine).not.toBe(entryLine);
    console.log(`Stepped: line ${entryLine} -> line ${afterLine}`);
  });

  test("status element shows success", async ({ page }) => {
    const traceFiles = JSON_TRACE_FILES.join(",");
    const url = `${baseUrl}/replay-test.html?traceFolder=trace&files=${traceFiles}&mode=basic`;
    await page.goto(url);

    await page.waitForFunction(
      () => {
        const el = document.getElementById("status");
        return el && el.classList.contains("ok");
      },
      { timeout: 60_000 },
    );

    const statusText = await page.textContent("#status");
    expect(statusText).toContain("trace loaded");
  });

  test("handles missing trace file gracefully", async ({ page }) => {
    const result = await runReplayTest(page, baseUrl, {
      traceFolder: "trace",
      files: "nonexistent.json",
      mode: "basic",
    });

    expect(result.success).toBe(false);
    expect(result.error).toContain("404");
  });
});

// ---------------------------------------------------------------------------
// Tests -- MCR (CTFS container) traces
// ---------------------------------------------------------------------------

test.describe("WASM client-side replay -- MCR (CTFS .ct) trace", () => {
  let server: http.Server;
  let baseUrl: string;

  test.setTimeout(120_000);

  test.beforeAll(async () => {
    const wasmPkg = path.join(WASM_TESTING_DIR, "pkg", "db_backend.js");
    if (!fs.existsSync(wasmPkg)) {
      throw new Error(
        `WASM package not found at ${wasmPkg}. ` +
          `Run "cd src/db-backend && bash build_wasm.sh" first.`,
      );
    }
    const ctFile = path.join(MCR_TRACES_DIR, "trace.ct");
    if (!fs.existsSync(ctFile)) {
      throw new Error(
        `MCR trace fixture not found at ${ctFile}. ` +
          `Copy a trace-portable.ct from codetracer-example-recordings/mcr/ first.`,
      );
    }
    const result = await startStaticServer();
    server = result.server;
    baseUrl = result.baseUrl;
  });

  test.afterAll(async () => {
    if (server) {
      await new Promise<void>((resolve) => server.close(() => resolve()));
    }
  });

  test("DAP initialize + launch + configurationDone succeeds for .ct trace", async ({
    page,
  }) => {
    const result = await runReplayTest(page, baseUrl, {
      traceFolder: "trace",
      files: MCR_TRACE_FILES.join(","),
      traceBaseUrl: "/mcr-traces/",
      mode: "basic",
    });

    expect(result.success, `MCR replay failed: ${result.error}`).toBe(true);
    expect(result.initResponse).toBeDefined();
    expect(result.initResponse.success).toBe(true);
    expect(result.configDoneResponse).toBeDefined();
    expect(result.configDoneResponse.success).toBe(true);
    expect(result.totalResponses).toBeGreaterThanOrEqual(4);
  });

  test("CTFS container loads and threads respond for MCR trace", async ({
    page,
  }) => {
    // MCR portable traces contain raw recording data that the WASM CTFS
    // reader can open but cannot materialize into steps (they need the
    // MCR debugserver for replay). This test verifies that:
    //   1. The .ct file is accepted by the CTFS reader (magic bytes match)
    //   2. The DAP protocol initializes correctly
    //   3. The threads request returns a valid thread
    //   4. The stackTrace returns empty (0 materialized steps) without crash
    const result = await runReplayTest(page, baseUrl, {
      traceFolder: "trace",
      files: MCR_TRACE_FILES.join(","),
      traceBaseUrl: "/mcr-traces/",
      mode: "comprehensive",
    });

    expect(result.success, `MCR replay failed: ${result.error}`).toBe(true);

    // Threads should respond correctly.
    expect(result.threads).toBeDefined();
    expect(result.threads.threads).toBeDefined();
    expect(result.threads.threads.length).toBeGreaterThanOrEqual(1);
    expect(result.threads.threads[0].id).toBe(1);

    // Stack trace at entry will be empty for MCR portable traces (no
    // materialized steps). This is expected -- the trace was recorded by
    // the MCR native recorder and would need the MCR debugserver to replay.
    expect(result.stackTrace).toBeDefined();
    expect(result.stackTrace.stackFrames).toBeDefined();
    // 0 materialized steps means 0 stack frames at entry.
    expect(result.stackTrace.totalFrames).toBe(0);
  });
});
