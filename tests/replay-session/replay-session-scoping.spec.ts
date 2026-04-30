/**
 * M7: ReplaySession integration tests.
 *
 * Verifies that the ReplaySession abstraction is correctly wired up at
 * runtime by inspecting `window.data` from the browser context.
 *
 * Checks:
 *   1. At least one session exists and activeSessionIndex is valid.
 *   2. The active session holds trace, services, dapApi, and viewsApi.
 *   3. Nim forwarding templates produce the same values as direct session
 *      access (compile-time forwarding means `data.trace` in Nim becomes
 *      `data.sessions[data.activeSessionIndex].trace` in JS, so the Data
 *      object itself does not carry a `.trace` property -- we verify this).
 *   4. After stepping, the debugger service holds a valid location.
 */

import { test, expect } from "../../lib/fixtures";
import { LayoutPage } from "../../page-objects/layout-page";
import { retry } from "../../lib/retry-helpers";

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/**
 * Snapshot of the ReplaySession fields we care about, extracted from
 * `window.data` inside the browser context.
 */
interface SessionSnapshot {
  sessionCount: number;
  activeIndex: number;
  hasTrace: boolean;
  hasServices: boolean;
  hasDebugger: boolean;
  hasEditor: boolean;
  hasCalltrace: boolean;
  hasDapApi: boolean;
  hasViewsApi: boolean;
  /** True when `data` has an own property named "trace" (should be false). */
  dataHasOwnTrace: boolean;
}

/** Evaluate session state from the browser. Returns null when not ready. */
function evaluateSessionState(page: import("@playwright/test").Page): Promise<SessionSnapshot | null> {
  return page.evaluate(() => {
    const d = (window as any).data;
    if (!d || !d.sessions || d.sessions.length === 0) return null;

    const idx = d.activeSessionIndex ?? -1;
    const session = d.sessions[idx];
    if (!session) return null;

    return {
      sessionCount: d.sessions.length,
      activeIndex: idx,
      hasTrace: !!session.trace,
      hasServices: !!session.services,
      hasDebugger: !!session.services?.debugger,
      hasEditor: !!session.services?.editor,
      hasCalltrace: !!session.services?.calltrace,
      hasDapApi: !!session.dapApi,
      hasViewsApi: !!session.viewsApi,
      dataHasOwnTrace: Object.prototype.hasOwnProperty.call(d, "trace"),
    };
  });
}

// ---------------------------------------------------------------------------
// Suite
// ---------------------------------------------------------------------------

test.describe("ReplaySession scoping", () => {
  test.setTimeout(120_000);
  test.describe.configure({ retries: 2 });
  test.use({ sourcePath: "py_console_logs/main.py", launchMode: "trace" });

  // -------------------------------------------------------------------------
  // Test 1: activeSession exists and holds per-replay state
  // -------------------------------------------------------------------------

  test("activeSession exists and holds trace state", async ({ ctPage }) => {
    const layout = new LayoutPage(ctPage);
    await layout.waitForTraceLoaded();

    // The data object may be populated slightly after the title changes,
    // so retry until sessions are available.
    let snapshot: SessionSnapshot | null = null;
    await retry(
      async () => {
        snapshot = await evaluateSessionState(ctPage);
        return snapshot !== null && snapshot.hasTrace;
      },
      { maxAttempts: 30, delayMs: 1000 },
    );

    expect(snapshot).not.toBeNull();
    expect(snapshot!.sessionCount).toBeGreaterThanOrEqual(1);
    expect(snapshot!.activeIndex).toBeGreaterThanOrEqual(0);
    expect(snapshot!.hasTrace).toBe(true);
    expect(snapshot!.hasServices).toBe(true);
    expect(snapshot!.hasDebugger).toBe(true);
    expect(snapshot!.hasEditor).toBe(true);
    expect(snapshot!.hasCalltrace).toBe(true);
    expect(snapshot!.hasDapApi).toBe(true);
    expect(snapshot!.hasViewsApi).toBe(true);
    // Verify the compile-time forwarding: Data should not own .trace directly
    // because the Nim template expands inline at every call site.
    expect(snapshot!.dataHasOwnTrace).toBe(false);
  });

  // -------------------------------------------------------------------------
  // Test 2: session holds debugger location after stepping
  // -------------------------------------------------------------------------

  test("session holds debugger location after stepping", async ({ ctPage }) => {
    const layout = new LayoutPage(ctPage);
    await layout.waitForAllComponentsLoaded();

    // Step forward (F10 = step over)
    await ctPage.keyboard.press("F10");

    // Wait for the debugger location to update after the step.
    let location: { path: string; line: number; event: number } | null = null;
    await retry(
      async () => {
        const loc = await ctPage.evaluate(() => {
          const d = (window as any).data;
          if (!d) return null;
          const session = d.sessions?.[d.activeSessionIndex];
          const debuggerSvc = session?.services?.debugger;
          if (!debuggerSvc?.location) return null;
          return {
            path: String(debuggerSvc.location.path ?? ""),
            line: Number(debuggerSvc.location.line ?? -1),
            event: Number(debuggerSvc.location.event ?? -1),
          };
        });
        if (loc && loc.line > 0) {
          location = loc;
          return true;
        }
        return false;
      },
      { maxAttempts: 30, delayMs: 500 },
    );

    expect(location).not.toBeNull();
    expect(location!.line).toBeGreaterThan(0);
    expect(location!.path.length).toBeGreaterThan(0);
  });
});
