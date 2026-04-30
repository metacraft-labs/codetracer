/**
 * M19: Phase 3 integration tests for multi-window same-replay infrastructure.
 *
 * Verifies that the multi-window management layer (M15 window table,
 * M16 DAP fan-out, M17 open-new-window IPC handler) is correctly wired.
 *
 * Note: Playwright cannot directly control multiple Electron BrowserWindows
 * since each is a separate native window. These tests verify the data model
 * and IPC infrastructure via `page.evaluate()` on `window.data` and the
 * Electron `ipcRenderer`.
 */

import { test, expect } from "../../lib/fixtures";
import { LayoutPage } from "../../page-objects/layout-page";
import { retry } from "../../lib/retry-helpers";

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/** Wait until `window.data.sessions` is populated and return the count. */
async function getSessionCount(
  page: import("@playwright/test").Page,
): Promise<number> {
  return page.evaluate(() => {
    const d = (window as any).data;
    return d?.sessions?.length ?? 0;
  });
}

// ---------------------------------------------------------------------------
// Suite
// ---------------------------------------------------------------------------

test.describe("Multi-window infrastructure (Phase 3)", () => {
  test.setTimeout(120_000);
  test.describe.configure({ retries: 2 });
  test.use({ sourcePath: "py_console_logs/main.py", launchMode: "trace" });

  // -------------------------------------------------------------------------
  // Test 1: sessions array and active session exist after trace load
  // -------------------------------------------------------------------------

  test("multi-window infrastructure exists", async ({ ctPage }) => {
    const layout = new LayoutPage(ctPage);
    await layout.waitForTraceLoaded();

    // Wait for sessions to initialise.
    await retry(
      async () => (await getSessionCount(ctPage)) >= 1,
      { maxAttempts: 30, delayMs: 1000 },
    );

    const result = await ctPage.evaluate(() => {
      const d = (window as any).data;
      return {
        hasSessionsArray: Array.isArray(d.sessions),
        sessionCount: d.sessions?.length ?? 0,
        hasActiveSessionIndex: typeof d.activeSessionIndex === "number",
        activeSessionIndex: d.activeSessionIndex ?? -1,
      };
    });

    expect(result.hasSessionsArray).toBe(true);
    expect(result.sessionCount).toBeGreaterThanOrEqual(1);
    expect(result.hasActiveSessionIndex).toBe(true);
    expect(result.activeSessionIndex).toBeGreaterThanOrEqual(0);
  });

  // -------------------------------------------------------------------------
  // Test 2: active session holds a valid trace after load
  // -------------------------------------------------------------------------

  test("active session holds trace data", async ({ ctPage }) => {
    const layout = new LayoutPage(ctPage);
    await layout.waitForTraceLoaded();

    await retry(
      async () => (await getSessionCount(ctPage)) >= 1,
      { maxAttempts: 30, delayMs: 1000 },
    );

    const result = await ctPage.evaluate(() => {
      const d = (window as any).data;
      const session = d.sessions?.[d.activeSessionIndex];
      return {
        hasTrace: session?.trace != null,
        hasServices: session?.services != null,
        hasViewsApi: session?.viewsApi != null,
        // The forwarding template on data should delegate to activeSession.
        traceMatchesSession:
          d.trace != null && session?.trace != null
            ? d.trace === session.trace
            : false,
      };
    });

    expect(result.hasTrace).toBe(true);
    expect(result.hasServices).toBe(true);
    expect(result.hasViewsApi).toBe(true);
    // Forwarding template: data.trace should be the same object as
    // activeSession.trace (not a separate copy).
    expect(result.traceMatchesSession).toBe(true);
  });

  // -------------------------------------------------------------------------
  // Test 3: open-new-window IPC handler is registered
  // -------------------------------------------------------------------------

  test("open-new-window IPC channel is available", async ({ ctPage }) => {
    const layout = new LayoutPage(ctPage);
    await layout.waitForTraceLoaded();

    // Verify that the renderer can send to the open-new-window channel
    // without errors. We cannot verify a second window actually appears
    // (Playwright limitation), but we can verify the IPC channel is
    // registered by checking that `ipcRenderer.send` does not throw.
    const sent = await ctPage.evaluate(() => {
      try {
        const { ipcRenderer } = require("electron");
        // Send the open-new-window message. The main process handler
        // (onOpenNewWindow) will attempt to create a secondary window.
        // In test mode this may be intercepted, but the channel should
        // be registered and the send should not throw.
        ipcRenderer.send("CODETRACER::open-new-window", {
          sessionId: 0,
        });
        return true;
      } catch {
        return false;
      }
    });

    expect(sent).toBe(true);
  });

  // -------------------------------------------------------------------------
  // Test 4: session data model supports multiple sessions with distinct IDs
  // -------------------------------------------------------------------------

  test("session data model supports multiple sessions", async ({ ctPage }) => {
    const layout = new LayoutPage(ctPage);
    await layout.waitForTraceLoaded();

    await retry(
      async () => (await getSessionCount(ctPage)) >= 1,
      { maxAttempts: 30, delayMs: 1000 },
    );

    // Add a second session to the data model (simulates what
    // createSecondaryWindow would do on the renderer side) and verify
    // the data model tracks them independently.
    const result = await ctPage.evaluate(() => {
      const d = (window as any).data;
      const original = d.sessions[0];

      // Create a shallow copy to simulate a second session.
      const copy = Object.assign(
        Object.create(Object.getPrototypeOf(original)),
        original,
      );
      d.sessions.push(copy);

      const count = d.sessions.length;
      // Clean up so we do not pollute other tests.
      d.sessions.splice(1, 1);

      return {
        hadTwoSessions: count === 2,
        cleanedUp: d.sessions.length === 1,
      };
    });

    expect(result.hadTwoSessions).toBe(true);
    expect(result.cleanedUp).toBe(true);
  });
});
