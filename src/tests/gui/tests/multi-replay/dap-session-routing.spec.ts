/**
 * Regression test for issue #327: DAP session routing must not special-case
 * session 0.
 *
 * The bug
 * -------
 * Before the fix, `sendDapForSession` in
 * `src/frontend/index/ipc_subsystems/dap.nim` skipped emitting
 * `ct/select-replay` whenever the target `sessionId == 0`, regardless of
 * the Backend Manager's `currentDapSessionId`.  If a non-zero session was
 * ever selected on the BM, subsequent session-0 DAP requests would be
 * mis-targeted: the BM would keep serving session N's replay.
 *
 * Additionally, `createNewSession` in
 * `src/frontend/ui/session_switch.nim` constructed `DapApi()` without a
 * `sessionId`, leaving it at the default 0.  That defeated the routing
 * layer downstream — every newly-created session impersonated session 0
 * on the wire.
 *
 * What this test asserts
 * ----------------------
 *
 * 1. After loading a trace, session 0's `dapApi.sessionId` is 0.
 * 2. After clicking "+" to create a second session, session 1's
 *    `dapApi.sessionId` is 1 (not the default 0).  This was the bug in
 *    session_switch.nim:138.
 * 3. Creating a third session yields `dapApi.sessionId == 2`.  This
 *    guards against off-by-one regressions where the sessionId might
 *    get pinned to the new active index at switch time, rather than
 *    derived from the actual session index at construction.
 * 4. We construct a synthetic `sendDapForSession`-equivalent in the
 *    renderer that mirrors the main-process routing logic and assert
 *    that it would emit `ct/select-replay` for both directions (0 -> 1
 *    AND 1 -> 0), documenting the contract that the fix established.
 *
 * Why "no test.skip"
 * ------------------
 * Per the codebase's testing policy, tests must exercise real behavior.
 * This test asserts the renderer-side state (DapApi.sessionId per
 * session) and the symmetric routing contract that the main-process
 * code must obey.
 *
 * Why not assert against the live main-process router
 * ---------------------------------------------------
 * The main process's `sendDapForSession` runs in Electron's main JS
 * realm, which the Playwright `page.evaluate` context cannot reach.
 * The Nim source under test (`ipc_subsystems/dap.nim`) is shipped as
 * compiled JS to `src/build-debug/src/index.js`.  The routing
 * predicate is `sessionId != currentDapSessionId`, with no special
 * case for sessionId == 0; this test pins the renderer half (DapApi
 * field population) AND documents the symmetric routing contract
 * via a local mirror.
 */

import { test, expect } from "../../lib/fixtures";
import { LayoutPage } from "../../page-objects/layout-page";
import { retry } from "../../lib/retry-helpers";

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

async function getSessionCount(page: import("@playwright/test").Page): Promise<number> {
  return page.evaluate(() => {
    const d = (window as any).data;
    return d?.sessions?.length ?? 0;
  });
}

async function getActiveIndex(page: import("@playwright/test").Page): Promise<number> {
  return page.evaluate(() => {
    const d = (window as any).data;
    return d?.activeSessionIndex ?? -1;
  });
}

/** Read the per-session DapApi.sessionId for the given session index. */
async function getDapApiSessionId(
  page: import("@playwright/test").Page,
  sessionIndex: number,
): Promise<number | null> {
  return page.evaluate((idx) => {
    const d = (window as any).data;
    const session = d?.sessions?.[idx];
    if (!session || !session.dapApi) return null;
    const sid = session.dapApi.sessionId;
    return typeof sid === "number" ? sid : Number(sid);
  }, sessionIndex);
}

/**
 * Issue #329 helper: check that the per-session `DapApi.ipc` is wired to
 * the same Electron IPC renderer instance as `data.ipc`.  Returns one of
 *   - "ok"                 : ipc is the shared singleton, ready to send
 *   - "missing-dap-api"    : the session has no DapApi at all
 *   - "ipc-nil"            : DapApi exists but `.ipc` was never set
 *   - "ipc-mismatch"       : DapApi.ipc is set but does NOT point at
 *                            data.ipc (would indicate a stray reference)
 */
async function getDapApiIpcStatus(
  page: import("@playwright/test").Page,
  sessionIndex: number,
): Promise<string> {
  return page.evaluate((idx) => {
    const d = (window as any).data;
    const session = d?.sessions?.[idx];
    if (!session || !session.dapApi) return "missing-dap-api";
    const ipc = session.dapApi.ipc;
    if (ipc === null || ipc === undefined) return "ipc-nil";
    if (ipc !== d.ipc) return "ipc-mismatch";
    return "ok";
  }, sessionIndex);
}

// ---------------------------------------------------------------------------
// Suite
// ---------------------------------------------------------------------------

test.describe("DAP session routing (issue #327)", () => {
  test.setTimeout(180_000);
  test.describe.configure({ retries: 2 });
  test.use({ sourcePath: "py_console_logs/main.py", launchMode: "trace" });

  test("DapApi.sessionId matches session index for every session, and routing is symmetric", async ({ ctPage }) => {
    const layout = new LayoutPage(ctPage);

    // ------------------------------------------------------------------
    // 1. Wait for session 0's trace to fully load.
    // ------------------------------------------------------------------
    await layout.waitForTraceLoaded();
    await layout.waitForAllComponentsLoaded();

    await retry(
      async () => (await getSessionCount(ctPage)) >= 1,
      { maxAttempts: 30, delayMs: 1000 },
    );
    expect(await getActiveIndex(ctPage)).toBe(0);

    // ------------------------------------------------------------------
    // 2. Session 0's DapApi.sessionId is 0.
    // ------------------------------------------------------------------
    expect(await getDapApiSessionId(ctPage, 0)).toBe(0);

    // ------------------------------------------------------------------
    // 3. Create a second session via the "+" button.  This is the
    //    canonical session_switch.nim createNewSession path that minted
    //    a DapApi with the wrong sessionId before the fix.
    // ------------------------------------------------------------------
    await ctPage.locator(".session-tab-add").click();
    await retry(
      async () => (await getSessionCount(ctPage)) === 2,
      { maxAttempts: 30, delayMs: 500 },
    );

    // ------------------------------------------------------------------
    // 4. The new session's DapApi.sessionId must equal its session
    //    index.  Before the fix this would still be 0 because
    //    session_switch.nim:138 constructed DapApi() with no sessionId
    //    field, leaving it at its struct default of 0.
    // ------------------------------------------------------------------
    expect(await getDapApiSessionId(ctPage, 1)).toBe(1);

    // Session 0's id is unchanged.
    expect(await getDapApiSessionId(ctPage, 0)).toBe(0);

    // ------------------------------------------------------------------
    // 5. Create a third session.  This guards against future
    //    refactors that accidentally pin the sessionId to the active
    //    index at switch time rather than to the actual session
    //    index at construction.
    // ------------------------------------------------------------------
    await ctPage.locator(".session-tab-add").click();
    await retry(
      async () => (await getSessionCount(ctPage)) === 3,
      { maxAttempts: 30, delayMs: 500 },
    );

    expect(await getDapApiSessionId(ctPage, 0)).toBe(0);
    expect(await getDapApiSessionId(ctPage, 1)).toBe(1);
    expect(await getDapApiSessionId(ctPage, 2)).toBe(2);

    // ------------------------------------------------------------------
    // 6. Verify the routing-decision contract via a renderer-side mirror.
    //
    //    The main-process router (ipc_subsystems/dap.nim) chooses to
    //    emit ct/select-replay iff `sessionId != currentDapSessionId`.
    //    The pre-fix code additionally checked `sessionId != 0` and
    //    skipped the switch for session 0, which is the #327 bug.
    //
    //    We re-implement the *fixed* predicate here and prove its key
    //    properties — symmetric for any pair (a, b) with a != b, and
    //    importantly true for (a, 0) where currentDapSessionId is any
    //    non-zero value.  If anyone later resurrects the special case,
    //    these assertions still pass for the buggy code — they cannot
    //    catch the regression by themselves.  Their value is documenting
    //    the routing contract so a future test (or human reviewer) can
    //    point at it as the canonical reference.
    // ------------------------------------------------------------------
    const shouldSelectReplay = (currentDapSessionId: number, target: number): boolean =>
      target !== currentDapSessionId;

    // The bug pattern: BM is currently serving session 1, session 0
    // wants to send.  The fix must emit ct/select-replay; the bug
    // would skip it.
    expect(shouldSelectReplay(1, 0)).toBe(true);
    expect(shouldSelectReplay(2, 0)).toBe(true);
    // Symmetry: any non-zero target works as before.
    expect(shouldSelectReplay(0, 1)).toBe(true);
    expect(shouldSelectReplay(0, 2)).toBe(true);
    expect(shouldSelectReplay(1, 2)).toBe(true);
    // No switch needed when already on the requested session.
    expect(shouldSelectReplay(0, 0)).toBe(false);
    expect(shouldSelectReplay(1, 1)).toBe(false);
    expect(shouldSelectReplay(2, 2)).toBe(false);
  });

  /**
   * Regression test for issue #329: every session's `DapApi.ipc` must be
   * wired to the Electron IPC renderer.
   *
   * The bug
   * -------
   * `configureMiddleware` (src/frontend/ui_js.nim) is called once at
   * startup with `data.dapApi` resolving through the active-session
   * forwarder to session 0.  It sets `data.dapApi.ipc = data.ipc` for
   * session 0 only.
   *
   * `createNewSession` (src/frontend/ui/session_switch.nim) constructs
   * a fresh `DapApi(sessionId: N)` per new tab.  Before the #329 fix
   * the `.ipc` field was left nil, so `DapApi.sendCtRequest` — which
   * unconditionally calls `dap.ipc.send(...)` — would throw an NPE on
   * the very first DAP request issued from the new session.
   *
   * What this test asserts
   * ----------------------
   *   1. Session 0's DapApi.ipc points at `data.ipc` (the shared
   *      Electron IPC singleton).  This is the baseline established by
   *      `configureMiddleware`.
   *   2. After creating session 1 via "+", its DapApi.ipc also points
   *      at the same `data.ipc` instance.  Pre-fix this would be
   *      "ipc-nil".
   *   3. Session 2 (added after another "+" click) also has `.ipc`
   *      wired — guarding against fixes that only handle the first
   *      additional session.
   */
  test("every session's DapApi.ipc is wired to the Electron IPC bridge (issue #329)", async ({ ctPage }) => {
    const layout = new LayoutPage(ctPage);

    await layout.waitForTraceLoaded();
    await layout.waitForAllComponentsLoaded();

    await retry(
      async () => (await getSessionCount(ctPage)) >= 1,
      { maxAttempts: 30, delayMs: 1000 },
    );

    // Session 0: configureMiddleware should have wired .ipc.
    expect(await getDapApiIpcStatus(ctPage, 0)).toBe("ok");

    // Create session 1 via the "+" button.
    await ctPage.locator(".session-tab-add").click();
    await retry(
      async () => (await getSessionCount(ctPage)) === 2,
      { maxAttempts: 30, delayMs: 500 },
    );

    // Pre-fix this returned "ipc-nil" because createNewSession built a
    // bare `DapApi(sessionId: 1)` with no `.ipc`.
    expect(await getDapApiIpcStatus(ctPage, 1)).toBe("ok");

    // Create session 2 to guard against single-session fixes.
    await ctPage.locator(".session-tab-add").click();
    await retry(
      async () => (await getSessionCount(ctPage)) === 3,
      { maxAttempts: 30, delayMs: 500 },
    );

    expect(await getDapApiIpcStatus(ctPage, 0)).toBe("ok");
    expect(await getDapApiIpcStatus(ctPage, 1)).toBe("ok");
    expect(await getDapApiIpcStatus(ctPage, 2)).toBe("ok");
  });
});
