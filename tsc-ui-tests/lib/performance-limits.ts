/**
 * Hard performance limits for CodeTracer operations.
 *
 * These limits define the maximum acceptable duration for each operation.
 * Tests assert against these limits to catch performance regressions.
 *
 * See: codetracer-specs/Testing/Performance-Targets.md
 */

// ---------------------------------------------------------------------------
// Startup & initialization (milliseconds)
// ---------------------------------------------------------------------------

/** Electron app launch: from _electron.launch() to process ready. */
export const LIMIT_ELECTRON_LAUNCH_MS = 5_000;

/** First window: from app ready to firstWindow() resolving. */
export const LIMIT_FIRST_WINDOW_MS = 3_000;

/** All UI components visible (GoldenLayout + Editor + EventLog + ...).
 * Includes waiting for event log data to finish loading. */
export const LIMIT_COMPONENTS_LOADED_MS = 8_000;

/** Trace data populated in UI after window ready. */
export const LIMIT_TRACE_LOADED_MS = 3_000;

/** Total cold setup: record + launch + window + components. */
export const LIMIT_TOTAL_SETUP_MS = 10_000;

// ---------------------------------------------------------------------------
// Recording
// ---------------------------------------------------------------------------

/** Cached recording lookup (already recorded, no recompilation). */
export const LIMIT_CACHED_RECORDING_MS = 500;

/** Small program recording (< 100 lines). */
export const LIMIT_SMALL_RECORDING_MS = 5_000;

// ---------------------------------------------------------------------------
// UI interactions (with loaded trace)
// ---------------------------------------------------------------------------

/** Single debugger step (next/step-in/step-out). */
export const LIMIT_STEP_MS = 500;

/** Navigate to line/event (click event log row, call trace entry). */
export const LIMIT_NAVIGATE_MS = 1_000;

/** Event log fully populated after trace load. */
export const LIMIT_EVENT_LOG_POPULATE_MS = 2_000;

/** Tab switch (GoldenLayout tab activation). */
export const LIMIT_TAB_SWITCH_MS = 300;

/** Context menu open. */
export const LIMIT_CONTEXT_MENU_MS = 300;

/** Scratchpad update after adding a value. */
export const LIMIT_SCRATCHPAD_UPDATE_MS = 500;

/** Program state variables panel populated. */
export const LIMIT_STATE_DISPLAY_MS = 1_000;

// ---------------------------------------------------------------------------
// Web mode (ct host)
// ---------------------------------------------------------------------------

/** ct host server startup. */
export const LIMIT_CT_HOST_STARTUP_MS = 5_000;

/** Browser page load (initial HTML/JS/CSS). */
export const LIMIT_BROWSER_PAGE_LOAD_MS = 5_000;

/** Socket.io connection (WebSocket upgrade). */
export const LIMIT_SOCKET_CONNECT_MS = 2_000;

/** Full page reload + IPC rebind cycle. */
export const LIMIT_RELOAD_RECONNECT_MS = 8_000;

// ---------------------------------------------------------------------------
// Timing utilities
// ---------------------------------------------------------------------------

/**
 * Measures execution time and asserts it's within the hard limit.
 * Returns the result of the operation.
 *
 * Usage:
 *   const layout = await timed("components loaded", LIMIT_COMPONENTS_LOADED_MS, async () => {
 *     await layout.waitForAllComponentsLoaded();
 *   });
 */
export async function timed<T>(
  label: string,
  limitMs: number,
  fn: () => Promise<T>,
): Promise<{ result: T; durationMs: number }> {
  const t0 = Date.now();
  const result = await fn();
  const durationMs = Date.now() - t0;
  const pct = Math.round((durationMs / limitMs) * 100);
  const status = durationMs > limitMs ? "EXCEEDED" : pct > 70 ? "SLOW" : "ok";
  console.log(
    `# timing: ${label}: ${durationMs}ms / ${limitMs}ms (${pct}%) [${status}]`,
  );
  if (durationMs > limitMs) {
    throw new Error(
      `Performance limit exceeded: "${label}" took ${durationMs}ms (limit: ${limitMs}ms)`,
    );
  }
  return { result, durationMs };
}

/**
 * Like `timed()` but for void operations.
 */
export async function timedVoid(
  label: string,
  limitMs: number,
  fn: () => Promise<void>,
): Promise<number> {
  const { durationMs } = await timed(label, limitMs, fn);
  return durationMs;
}
