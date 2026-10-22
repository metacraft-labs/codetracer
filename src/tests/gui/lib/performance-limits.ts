/**
 * Hard performance limits for CodeTracer operations.
 *
 * These limits define the maximum acceptable duration for each operation.
 * Tests assert against these limits to catch performance regressions.
 *
 * See: codetracer-specs/Testing/Performance-Targets.md
 */

import {
  contentionAdjustedMs,
  contentionBetween,
  sampleProcessTree,
} from "./process-contention";

// ---------------------------------------------------------------------------
// Startup & initialization (milliseconds)
// ---------------------------------------------------------------------------

/** Electron app launch: from _electron.launch() to process ready. */
export const LIMIT_ELECTRON_LAUNCH_MS = 15_000;

/** First window: from app ready to firstWindow() resolving. */
export const LIMIT_FIRST_WINDOW_MS = 10_000;

/** All UI components visible (GoldenLayout + Editor + EventLog + ...).
 * Includes waiting for event log data to finish loading.
 * Under parallel worker load, event log loading can take 10-13s.
 * Nim 2.2 JS codegen is slower than 1.6, requiring more headroom. */
export const LIMIT_COMPONENTS_LOADED_MS = 45_000;

/** Trace data populated in UI after window ready. */
export const LIMIT_TRACE_LOADED_MS = 25_000;

/** Total cold setup: record + launch + window + components. */
export const LIMIT_TOTAL_SETUP_MS = 30_000;

// ---------------------------------------------------------------------------
// Recording
// ---------------------------------------------------------------------------

/** Cached recording lookup (already recorded, no recompilation). */
export const LIMIT_CACHED_RECORDING_MS = 500;

/** Small program recording (< 100 lines).
 * Baseline (warm cache, idle host) is well under 1s, but the first
 * recording in a worker process pays ct/recorder startup cost and
 * can collide with concurrent host activity (background builds,
 * Nix evaluations) for several seconds. 15s catches a regression
 * (small program should never take that long) while absorbing
 * cold-start + realistic noise. */
export const LIMIT_SMALL_RECORDING_MS = 15_000;

/** RR recording: compile + rr record. Ranges from 8s (C) to 60s+ (Crystal, Lean).
 * TTD (Windows) recording has much higher overhead than RR.  Compute-heavy
 * programs like sudoku solvers can take 4-10+ minutes under TTD. */
export const LIMIT_RR_RECORDING_MS = process.platform === "win32" ? 900_000 : 90_000;

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
/**
 * `CODETRACER_PERF_LIMIT_SCALE` multiplies every limit `timed` enforces. It is
 * for lanes whose subject is NOT performance — the visual captures
 * (`just plat35-capture-electron`) — run on a host they do not have to
 * themselves: on 2026-10-17 a 32-core workstation at load 53 from other
 * sessions' builds failed all six captures on "base components loaded"
 * (81 s against 45 s), which says nothing about the frames they take. A lane
 * that gates performance must never set it. Unset, or not a number >= 1,
 * means 1.
 */
const limitScale = (() => {
  const v = Number(process.env.CODETRACER_PERF_LIMIT_SCALE ?? "1");
  return Number.isFinite(v) && v >= 1 ? v : 1;
})();

/**
 * The limit is graded against the CONTENTION-ADJUSTED duration, not raw wall
 * clock: the time this process tree (the test runner and everything it
 * launched) spent runnable but waiting for a CPU is taken out first, see
 * `lib/process-contention.ts`. A shared host's load otherwise decides the
 * verdict — at load 33-48 on 24 cores a clean tree measured `first window` at
 * 10.3 s against 10 s and failed its own `tests/build/` specs (codetracer-pm
 * issue `2026-10-17-electron-build-specs-fail-on-clean-agents-under-host-load`).
 * On an idle host there is no run-queue wait and the adjusted duration IS the
 * wall clock; off Linux it is always the wall clock. The adjustment never
 * takes off more than the measured wait, and more work still grades longer:
 * under contention it is scaled by the same factor as the rest (see
 * `contentionAdjustedMs` for what a loaded host can still discount).
 *
 * The returned `durationMs` stays the raw wall clock, which is what callers
 * print and compare between steps.
 */
export async function timed<T>(
  label: string,
  rawLimitMs: number,
  fn: () => Promise<T>,
): Promise<{ result: T; durationMs: number }> {
  const limitMs = rawLimitMs * limitScale;
  // Sampled outside the timed interval so reading /proc is not part of it.
  const before = sampleProcessTree();
  const t0 = Date.now();
  const result = await fn();
  const durationMs = Date.now() - t0;
  const contention = contentionBetween(before, sampleProcessTree());
  const gradedMs = Math.round(contentionAdjustedMs(durationMs, contention));
  const pct = Math.round((gradedMs / limitMs) * 100);
  const status = gradedMs > limitMs ? "EXCEEDED" : pct > 70 ? "SLOW" : "ok";
  // Print the raw figure and both scheduler totals whenever they differ, so a
  // graded number can always be traced back to what was measured.
  const detail = gradedMs === durationMs
    ? `${durationMs}ms`
    : `${gradedMs}ms adjusted (wall ${durationMs}ms, cpu ${Math.round(contention.cpuMs)}ms, ` +
      `run-queue wait ${Math.round(contention.waitMs)}ms)`;
  console.log(
    `# timing: ${label}: ${detail} / ${limitMs}ms (${pct}%) [${status}]`,
  );
  if (gradedMs > limitMs) {
    throw new Error(
      `Performance limit exceeded: "${label}" took ${detail} (limit: ${limitMs}ms)`,
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
