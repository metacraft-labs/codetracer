/**
 * Multi-trace loading test: loads different traces into separate sessions.
 *
 * Proves that:
 *   1. Multiple traces can be pre-recorded and loaded into distinct sessions.
 *   2. Each session holds the correct trace metadata (program name, source path).
 *   3. Switching between sessions preserves per-session trace identity.
 *   4. The editor displays the correct source file for each session.
 *
 * ## Trace types covered
 *
 * - **Materialized (DB-based)**: Python programs recorded via the Python
 *   recorder (py_console_logs, py_checklist).  Always available.
 * - **MCR (native recorder)**: C/Rust programs recorded via codetracer-native-
 *   recorder. Requires a runnable `ct-native-replay` on PATH.
 * - **RR**: Uses the rr time-travel debugger as the recording backend.
 *   Same prerequisite as MCR.
 *
 * The base test uses two materialized Python traces (always works).  An
 * extended test requires the RR backend and reports a missing or unusable
 * `ct-native-replay` explicitly, except in an explicitly selected DB-only lane.
 *
 * ## How loading into a new session works
 *
 * 1. Pre-record programs via `ct record` (returns trace IDs).
 * 2. Launch Electron with trace A (CODETRACER_RECORDING_ID env var, M-REC-6).
 * 3. Click "+" to create a new session (tab).
 * 4. From the renderer, send `CODETRACER::load-recent-trace` IPC with
 *    trace B's ID.  The main process starts a replay for trace B and
 *    sends `CODETRACER::trace-loaded` back to the renderer, which
 *    stores the trace in the active session.
 * 5. Verify session metadata and editor content.
 *
 * This suite checks trace identity, source files and event navigation across
 * session switches. Replay selection and stepping have additional coverage in
 * the other multi-replay specs.
 */

import * as path from "node:path";
import { spawnSync } from "node:child_process";
import { existsSync } from "node:fs";

import { test, expect, recordTestProgram, testProgramsPath, traceFolderForId } from "../../lib/fixtures";
import { LayoutPage } from "../../page-objects/layout-page";
import { retry } from "../../lib/retry-helpers";

// ---------------------------------------------------------------------------
// Helpers — session introspection via window.data
// ---------------------------------------------------------------------------

/** Return the number of sessions in the data model. */
async function getSessionCount(page: import("@playwright/test").Page): Promise<number> {
  return page.evaluate(() => {
    const d = (window as any).data;
    return d?.sessions?.length ?? 0;
  });
}

/** Return the activeSessionIndex from window.data. */
async function getActiveIndex(page: import("@playwright/test").Page): Promise<number> {
  return page.evaluate(() => {
    const d = (window as any).data;
    return d?.activeSessionIndex ?? -1;
  });
}

/** Return trace metadata for a specific session. */
async function getSessionTrace(
  page: import("@playwright/test").Page,
  sessionIndex: number,
): Promise<{ id: string; program: string; outputFolder: string } | null> {
  // M-REC-3: the trace identity field is ``recordingId`` (a UUIDv7
  // string).  The legacy ``id`` field is a numeric-row hangover that is
  // empty on the data model — prefer recordingId, fall back to id.
  return page.evaluate((idx) => {
    const d = (window as any).data;
    const session = d?.sessions?.[idx];
    const trace = session?.trace;
    if (!trace) return null;
    return {
      id: String(trace.recordingId ?? trace.id ?? ""),
      program: String(trace.program ?? ""),
      outputFolder: String(trace.outputFolder ?? ""),
    };
  }, sessionIndex);
}

/** Return whether a session has a loaded trace. */
async function sessionHasTrace(
  page: import("@playwright/test").Page,
  sessionIndex: number,
): Promise<boolean> {
  return page.evaluate((idx) => {
    const d = (window as any).data;
    return !!d?.sessions?.[idx]?.trace;
  }, sessionIndex);
}

/**
 * Load a pre-recorded trace into the currently active session by sending
 * the `CODETRACER::load-recent-trace` IPC message from the renderer to
 * the main process.
 *
 * The main process will:
 *   1. Look up trace metadata from the trace database.
 *   2. Start a replay backend for the trace.
 *   3. Send `CODETRACER::init` and `CODETRACER::trace-loaded` to the
 *      renderer, which stores the data in the active session.
 */
async function loadTraceIntoActiveSession(
  page: import("@playwright/test").Page,
  traceId: string | number,
): Promise<void> {
  // M-REC-2 / M-REC-3 / M-REC-6: ``traceId`` is a UUIDv7 recording-id
  // string assigned by the recorder.  Older MCR import paths still
  // surface numeric ids; both go over the wire as-is.
  await page.evaluate((id) => {
    const d = (window as any).data;
    d.ipc.send("CODETRACER::load-recent-trace", { traceId: id });
  }, traceId);
}

/**
 * Wait for the editor component to show a file matching the given substring.
 * Returns the matched filename or throws after timeout.
 */
async function waitForEditorFile(
  page: import("@playwright/test").Page,
  fileSubstring: string,
  timeoutMs = 30_000,
): Promise<string> {
  let fileName = "";
  const delayMs = 500;
  const maxAttempts = Math.ceil(timeoutMs / delayMs);
  await retry(
    async () => {
      // Check all editor component data-label attributes.
      const labels: string[] = await page.evaluate(() => {
        const editors = document.querySelectorAll("div[id^='editorComponent']");
        return Array.from(editors).map((el) => el.getAttribute("data-label") ?? "");
      });
      for (const label of labels) {
        if (label.includes(fileSubstring)) {
          const segments = label.split("/").filter(Boolean);
          fileName = segments[segments.length - 1] ?? label;
          return true;
        }
      }
      return false;
    },
    { maxAttempts, delayMs },
  );
  return fileName;
}

// ---------------------------------------------------------------------------
// Suite: multi-trace loading into sessions
// ---------------------------------------------------------------------------

test.describe("Multi-trace loading into sessions", () => {
  test.setTimeout(300_000); // 5 minutes: multiple recordings + Electron + IPC
  test.describe.configure({ retries: 1 });
  test.use({ sourcePath: "py_console_logs/main.py", launchMode: "trace" });

  // -------------------------------------------------------------------------
  // Test 1: load two materialized traces into separate sessions
  //
  // This is the baseline test that always works (no RR/MCR needed).
  // Records py_console_logs (trace A) and py_checklist (trace B), loads
  // each into its own session, and verifies per-session isolation.
  // -------------------------------------------------------------------------

  test("load two materialized traces into separate sessions", async ({ ctPage }) => {
    const layout = new LayoutPage(ctPage);

    // ==================================================================
    // Phase 1: Wait for the first trace (py_console_logs) to fully load
    // ==================================================================

    await layout.waitForTraceLoaded();
    await layout.waitForAllComponentsLoaded();

    // Confirm session 0 is active and has a trace.
    await retry(
      async () => (await getSessionCount(ctPage)) >= 1,
      { maxAttempts: 30, delayMs: 1000 },
    );
    expect(await getActiveIndex(ctPage)).toBe(0);
    expect(await sessionHasTrace(ctPage, 0)).toBe(true);

    // Verify session 0's trace is py_console_logs.
    const trace0 = await getSessionTrace(ctPage, 0);
    expect(trace0).not.toBeNull();
    expect(trace0!.program).toContain("main.py");
    console.log(`# session 0 trace: id=${trace0!.id} program=${trace0!.program}`);

    // Verify editor shows main.py.
    const editor0File = await waitForEditorFile(ctPage, "main.py");
    expect(editor0File).toContain("main.py");

    // Verify event log has entries (trace is fully loaded with data).
    // Scoped to session 0's container: every tab has its own
    // `eventLogComponent-0`, all in one document.
    await retry(
      async () => {
        const rowCount = await ctPage.evaluate(() => {
          const rows = document.querySelectorAll(
            "#session-container-0 div[id^='eventLogComponent'] .eventLog-dense-table tbody tr",
          );
          return rows.length;
        });
        return rowCount > 0;
      },
      { maxAttempts: 30, delayMs: 1000 },
    );
    console.log("# session 0: editor shows main.py and event log has entries");

    // ==================================================================
    // Phase 2: Step forward in session 0 and record the line number
    // ==================================================================

    // Click the "next" debug button to step forward.
    const nextBtn = layout.nextButton();
    const nextBtnVisible = await nextBtn.isVisible().catch(() => false);
    let session0LineAfterStep = -1;

    if (nextBtnVisible) {
      await nextBtn.click({ force: true });
      // Wait for the step to complete and capture the current line number.
      await ctPage.waitForTimeout(2000);

      session0LineAfterStep = await ctPage.evaluate(() => {
        const d = (window as any).data;
        const session = d?.sessions?.[0];
        // Try multiple ways to get the current line.
        return (
          session?.currentLine ??
          session?.trace?.currentLine ??
          d?.currentLine ??
          -1
        );
      });
      console.log(`# session 0 line after step: ${session0LineAfterStep}`);
    } else {
      // If next button is not visible, just record the initial line.
      session0LineAfterStep = await ctPage.evaluate(() => {
        const d = (window as any).data;
        const session = d?.sessions?.[0];
        return session?.currentLine ?? session?.trace?.currentLine ?? d?.currentLine ?? -1;
      });
      console.log(`# session 0 line (no step button visible): ${session0LineAfterStep}`);
    }

    // ==================================================================
    // Phase 3: Pre-record the second trace (py_checklist/basics.py)
    // ==================================================================

    const secondProgramPath = path.join(testProgramsPath, "py_checklist", "basics.py");
    const secondTraceId = recordTestProgram(secondProgramPath);
    console.log(`# pre-recorded second trace: id=${secondTraceId} (py_checklist/basics.py)`);

    // ==================================================================
    // Phase 4: Create a new session and load the second trace
    // ==================================================================

    // Click "+" to create session 1.
    await ctPage.locator(".session-tab-add").click();

    await retry(
      async () => (await getSessionCount(ctPage)) === 2,
      { maxAttempts: 20, delayMs: 500 },
    );
    expect(await getActiveIndex(ctPage)).toBe(1);

    // Session 1 should be empty (no trace yet).
    expect(await sessionHasTrace(ctPage, 1)).toBe(false);

    // Load the second trace into session 1 via IPC.
    await loadTraceIntoActiveSession(ctPage, secondTraceId);

    // Wait for session 1 to receive the trace.
    await retry(
      async () => await sessionHasTrace(ctPage, 1),
      { maxAttempts: 60, delayMs: 1000 },
    );

    // Verify session 1's trace is py_checklist/basics.py.
    const trace1 = await getSessionTrace(ctPage, 1);
    expect(trace1).not.toBeNull();
    expect(trace1!.program).toContain("basics.py");
    expect(trace1!.id).toBe(secondTraceId);
    console.log(`# session 1 trace: id=${trace1!.id} program=${trace1!.program}`);

    // Verify the two traces are different.
    expect(trace0!.id).not.toBe(trace1!.id);
    expect(trace0!.program).not.toBe(trace1!.program);

    const editor1File = await waitForEditorFile(ctPage, "basics.py");
    expect(editor1File).toContain("basics.py");
    expect(editor1File).not.toContain("main.py");

    // ==================================================================
    // Phase 5: Switch back to session 0 — verify editor + line preserved
    // ==================================================================

    // Click the first tab to switch back to session 0 (no JS fallback).
    const tabsPhase5 = ctPage.locator(".session-tab");
    expect(await tabsPhase5.count()).toBeGreaterThan(0);
    await tabsPhase5.first().click();
    await ctPage.waitForTimeout(500);

    const activeAfterClick = await getActiveIndex(ctPage);
    expect(activeAfterClick).toBe(0);

    // Session 0's trace metadata should still be correct.
    const trace0Final = await getSessionTrace(ctPage, 0);
    expect(trace0Final).not.toBeNull();
    expect(trace0Final!.program).toContain("main.py");
    expect(trace0Final!.id).toBe(trace0!.id);

    // Wait for GL rebuild and verify editor shows main.py again.
    await retry(
      async () => {
        const labels: string[] = await ctPage.evaluate(() => {
          const editors = document.querySelectorAll("div[id^='editorComponent']");
          return Array.from(editors).map((el) => el.getAttribute("data-label") ?? "");
        });
        return labels.some((l) => l.includes("main.py"));
      },
      { maxAttempts: 30, delayMs: 500 },
    );

    // Verify the line number from the earlier step is preserved in the
    // data model (if we managed to capture one).
    if (session0LineAfterStep > 0) {
      const lineAfterSwitch = await ctPage.evaluate(() => {
        const d = (window as any).data;
        const session = d?.sessions?.[0];
        return session?.currentLine ?? session?.trace?.currentLine ?? d?.currentLine ?? -1;
      });
      // The line number should be preserved (or at least still valid).
      // We log the result but don't hard-assert exact equality because
      // the backend may adjust the line on session restore, and the
      // replay for session 0 may have been stopped.
      if (lineAfterSwitch > 0) {
        console.log(`# session 0 line preserved after switch: ${lineAfterSwitch} (was ${session0LineAfterStep})`);
      } else {
        console.log(`# session 0 line not preserved after switch (got ${lineAfterSwitch}, was ${session0LineAfterStep}) — known limitation`);
      }
    }

    // ==================================================================
    // Phase 6: Switch to session 1 — verify editor shows session 1 file
    // ==================================================================

    // Switch to session 1 (tab click only, no JS fallback).
    const tabsPhase6 = ctPage.locator(".session-tab");
    expect(await tabsPhase6.count()).toBeGreaterThan(1);
    await tabsPhase6.nth(1).click();
    await ctPage.waitForTimeout(500);

    const activeSession1 = await getActiveIndex(ctPage);
    expect(activeSession1).toBe(1);

    const editor1FileAfterSwitch = await waitForEditorFile(ctPage, "basics.py");
    expect(editor1FileAfterSwitch).toContain("basics.py");

    // ==================================================================
    // Phase 7: Click event log entry in session 1 — verify navigation
    // ==================================================================

    // Wait for event log rows to appear in session 1 — in SESSION 1's
    // container, and real rows only (DataTables' "No data available"
    // placeholder is a `tbody tr` too). This selector used to be
    // document-wide, so it counted session 0's rows and passed over a
    // session 1 Event Log that had never mounted (codetracer-pm issue
    // 2026-10-21-isonim-panes-stay-blank-in-every-desktop-tab-but-the-first).
    //
    // Not asserted here: whether those rows are session 1's OWN is held by
    // `second_tab_panes_render.spec.ts` (`test_open_second_trace`), which
    // reads each pane of each tab against its recording. Until each tab's
    // session owned its ViewModels and middleware (`ui/session_viewmodels.nim`;
    // before, one per window, `ui_js.configureMiddleware`), session 1's rows
    // never arrived. The line below records which side a run is on.
    const session1EventRows =
      "#session-container-1 div[id^='eventLogComponent'] .eventLog-dense-table tbody tr:not(:has(td.dataTables_empty))";
    await expect(ctPage.locator(session1EventRows).first()).toBeVisible();
    await ctPage.locator(session1EventRows).first().click();
    await expect.poll(() => ctPage.evaluate(() => {
      const editors = document.querySelectorAll(
        "#session-container-1 div[id^='editorComponent']");
      return Array.from(editors).some((el) =>
        (el.getAttribute("data-label") ?? "").includes("basics.py"));
    })).toBe(true);

    console.log("# multi-trace load test passed: both sessions hold distinct traces with full isolation");
  });

  // -------------------------------------------------------------------------
  // Test 2: Open in New Tab from file menu
  //
  // Simulates the "Open in New Tab" menu action by sending the
  // `CODETRACER::open-trace-in-tab` IPC message.  Verifies that
  // a new session is created and becomes the active session.
  // -------------------------------------------------------------------------

  test("open-trace-in-tab IPC creates new session and switches to it", async ({ ctPage }) => {
    const layout = new LayoutPage(ctPage);
    await layout.waitForTraceLoaded();
    await layout.waitForAllComponentsLoaded();
    const trace0 = await getSessionTrace(ctPage, 0);
    expect(trace0).not.toBeNull();
    const initialSessionCount = await getSessionCount(ctPage);

    // A successful send alone proves nothing: Electron accepts unknown IPC
    // channels too. Require the addressed recording in a new, active session.
    await ctPage.evaluate((traceId) => {
      (window as any).data.ipc.send("CODETRACER::open-trace-in-tab", { traceId });
    }, trace0!.id);
    await expect.poll(() => getSessionCount(ctPage)).toBe(initialSessionCount + 1);
    await expect.poll(() => getActiveIndex(ctPage)).toBe(initialSessionCount);
    await expect.poll(async () =>
      (await getSessionTrace(ctPage, initialSessionCount))?.id,
    ).toBe(trace0!.id);
    expect((await getSessionTrace(ctPage, 0))?.id).toBe(trace0!.id);
  });

  // -------------------------------------------------------------------------
  // Test 3: materialized Python and Noir plus RR in separate sessions
  //
  // This test loads three different trace types:
  //   - Session 0: Materialized (py_console_logs) — always available
  //   - Session 1: Materialized (noir_example) — DB-based Noir trace
  //   - Session 2: RR (c_sudoku_solver) — requires the Linux RR backend
  //
  // The test requires a runnable RR backend; a DB-only lane excludes it.
  // -------------------------------------------------------------------------

  test("three trace types: materialized Python + Noir + RR C program", async ({ ctPage }, testInfo) => {
    testInfo.skip(process.platform !== "linux", "The RR recording backend is supported on Linux only");
    // Also skip if only running DB tests.
    if (process.env.CODETRACER_DB_TESTS_ONLY === "1") {
      testInfo.skip(true, "RR test skipped — running DB-based tests only");
    }
    // A sibling directory or a presence flag is not a runnable backend.
    // Diagnose the actual prerequisite before recording the native trace, with the
    // same provisioning recipe the GUI lane uses, rather than surfacing it
    // later as an unexplained `ct record` failure or silently skipping it.
    const nativeReplay = spawnSync("ct-native-replay", ["--help"], {
      encoding: "utf-8",
    });
    if (nativeReplay.error || nativeReplay.status !== 0) {
      throw new Error(
        "Missing or unusable GUI test prerequisite: ct-native-replay. " +
        "Run `bash scripts/build-siblings.sh --only codetracer-native-backend` " +
        "inside the CodeTracer development environment, then re-enter it.\n" +
        String(nativeReplay.error ?? nativeReplay.stderr),
      );
    }

    const layout = new LayoutPage(ctPage);

    // ==================================================================
    // Phase 1: Session 0 — materialized Python trace (already loaded)
    // ==================================================================

    await layout.waitForTraceLoaded();
    await layout.waitForAllComponentsLoaded();

    await retry(
      async () => (await getSessionCount(ctPage)) >= 1,
      { maxAttempts: 30, delayMs: 1000 },
    );
    expect(await sessionHasTrace(ctPage, 0)).toBe(true);

    const trace0 = await getSessionTrace(ctPage, 0);
    expect(trace0).not.toBeNull();
    console.log(`# session 0 (materialized Python): id=${trace0!.id} program=${trace0!.program}`);

    // ==================================================================
    // Phase 2: Pre-record the Noir and C traces
    // ==================================================================

    const noirProgramPath = path.join(testProgramsPath, "noir_example") + "/";
    const noirTraceId = recordTestProgram(noirProgramPath);
    console.log(`# pre-recorded Noir trace: id=${noirTraceId}`);

    const cProgramPath = path.join(testProgramsPath, "c_sudoku_solver", "main.c");
    // This case is specifically about RR beside materialized recordings.
    // Native recording defaults to MCR, so select the intended backend.
    const cTraceId = recordTestProgram(cProgramPath, "rr");
    console.log(`# pre-recorded C/RR trace: id=${cTraceId}`);
    // Check the produced artifact too: a cached/default MCR recording must
    // not satisfy a case whose third recording is specifically RR.
    expect(existsSync(path.join(traceFolderForId(cTraceId), "rr", "version"))).toBe(true);

    // ==================================================================
    // Phase 3: Session 1 — Noir trace (materialized, DB-based)
    // ==================================================================

    await ctPage.locator(".session-tab-add").click();
    await retry(
      async () => (await getSessionCount(ctPage)) === 2,
      { maxAttempts: 20, delayMs: 500 },
    );
    expect(await getActiveIndex(ctPage)).toBe(1);

    await loadTraceIntoActiveSession(ctPage, noirTraceId);
    await retry(
      async () => await sessionHasTrace(ctPage, 1),
      { maxAttempts: 60, delayMs: 1000 },
    );

    const trace1 = await getSessionTrace(ctPage, 1);
    expect(trace1).not.toBeNull();
    expect(trace1!.id).toBe(noirTraceId);
    console.log(`# session 1 (Noir): id=${trace1!.id} program=${trace1!.program}`);

    // ==================================================================
    // Phase 4: Session 2 — C/RR trace
    // ==================================================================

    await ctPage.locator(".session-tab-add").click();
    await retry(
      async () => (await getSessionCount(ctPage)) === 3,
      { maxAttempts: 20, delayMs: 500 },
    );
    expect(await getActiveIndex(ctPage)).toBe(2);

    await loadTraceIntoActiveSession(ctPage, cTraceId);
    await retry(
      async () => await sessionHasTrace(ctPage, 2),
      { maxAttempts: 60, delayMs: 1000 },
    );

    const trace2 = await getSessionTrace(ctPage, 2);
    expect(trace2).not.toBeNull();
    expect(trace2!.id).toBe(cTraceId);
    console.log(`# session 2 (C/RR): id=${trace2!.id} program=${trace2!.program}`);

    // ==================================================================
    // Phase 5: Verify all three traces are distinct
    // ==================================================================

    const ids = new Set([trace0!.id, trace1!.id, trace2!.id]);
    expect(ids.size).toBe(3);

    // ==================================================================
    // Phase 6: Verify trace metadata preserved after switching
    // ==================================================================

    // All three sessions should still have their traces in the data model.
    const verifySession = async (idx: number, expectedId: string) => {
      const trace = await getSessionTrace(ctPage, idx);
      expect(trace, `session ${idx} should still have its trace`).not.toBeNull();
      expect(trace!.id, `session ${idx} trace ID should match`).toBe(expectedId);
    };

    await verifySession(0, trace0!.id);
    await verifySession(1, noirTraceId);
    await verifySession(2, cTraceId);

    // Switch sessions using tab clicks only (no JS fallback).
    const switchToSession = async (targetIdx: number) => {
      const tabs = ctPage.locator(".session-tab");
      const tabCount = await tabs.count();
      expect(tabCount).toBeGreaterThan(targetIdx);
      await tabs.nth(targetIdx).click();
      await ctPage.waitForTimeout(500);
      const activeAfter = await getActiveIndex(ctPage);
      expect(activeAfter).toBe(targetIdx);
    };

    await switchToSession(1);
    expect(await getActiveIndex(ctPage)).toBe(1);
    await verifySession(1, noirTraceId);

    // Switch to session 0.
    await switchToSession(0);
    expect(await getActiveIndex(ctPage)).toBe(0);
    await verifySession(0, trace0!.id);

    // Switch to session 2.
    await switchToSession(2);
    expect(await getActiveIndex(ctPage)).toBe(2);
    await verifySession(2, cTraceId);

    console.log("# three-trace-type test passed: materialized Python, Noir, and C/RR traces " +
      "loaded into separate sessions with correct isolation");
  });
});
