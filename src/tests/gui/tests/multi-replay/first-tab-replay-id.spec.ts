/**
 * The window's first tab knows the replay the main process started for it at
 * startup, and Stop and close in that tab end THAT replay.
 *
 * The defect
 * ----------
 * `index/startup.init` starts the startup trace's replay
 * (`traces.startReplayForTrace`), which sent `CODETRACER::dap-replay-selected`
 * — the one message that tells a tab its replay id — BEFORE `started()`, the
 * handshake that waits for the renderer to be listening. The renderer was not
 * listening yet, so the message was lost: tab 0's `ReplaySession.replayId`
 * stayed -1 for the life of the window. Nothing showed it while the main
 * process selected replays by the TAB's id (tab 0 and replay 0 coincide), but
 *
 *   * Stop in tab 0 found "no replay running" and sent no
 *     `CODETRACER::close-replay-session` (`ui/stop_command.nim`), so the replay
 *     outlived the session the user stopped;
 *   * closing tab 0 sent `close-replay-session` with `replayId: -1`, which the
 *     main process ignores, so the replay leaked;
 *   * once the main process selects a request's replay by the replay id the
 *     tab names (codetracer-pm
 *     `issues/2026-10-23-a-tab-opened-after-closing-a-middle-tab-reuses-a-live-tabs-session-id.md`,
 *     `GUI/Multi-Window-Tab-Management.md` §Tab Behavior rule 8), tab 0 named
 *     none, and its requests could not be routed at all.
 *
 * What this asserts
 * -----------------
 *   After the startup trace has loaded, tab 0's `replayId` — on the session
 *   and on its `DapApi`, which names it on every request — is the replay the
 *   session manager started for it: 0, the first replay a fresh session
 *   manager starts (each `ctPage` launches its own). The id lives in renderer
 *   state no user sees, so this stays a lower-tier test. What a user sees of
 *   the defect — Stop, and closing tab 0 beside a second tab, ending the
 *   startup replay — are scenarios now
 *   (src/tests/scenarios/multi-replay/stop-ends-the-first-tabs-replay.yaml,
 *   closing-the-first-tab-keeps-the-second.yaml).
 */

import { test, expect } from "../../lib/fixtures";
import type { Page } from "@playwright/test";
import { LayoutPage } from "../../page-objects/layout-page";
import { retry } from "../../lib/retry-helpers";

const STARTUP_REPLAY = 0;

async function firstTabReplay(page: Page): Promise<{ session: number; dap: number; hasReplay: boolean } | null> {
  return page.evaluate(() => {
    const d = (window as any).data;
    const s = d?.sessions?.[0];
    if (!s || !s.dapApi) return null;
    return { session: Number(s.replayId), dap: Number(s.dapApi.replayId), hasReplay: Boolean(s.dapApi.hasReplay) };
  });
}

async function waitForFirstTabReady(page: Page): Promise<void> {
  const layout = new LayoutPage(page);
  await layout.waitForTraceLoaded();
  await layout.waitForAllComponentsLoaded();
}

test.describe("the window's first tab knows its startup replay", () => {
  test.setTimeout(180_000);
  test.use({ sourcePath: "py_console_logs/main.py", launchMode: "trace" });

  test("tab 0 holds the replay started for it at startup", async ({ ctPage }) => {
    await waitForFirstTabReady(ctPage);
    let seen: Awaited<ReturnType<typeof firstTabReplay>> = null;
    try {
      await retry(async () => {
        seen = await firstTabReplay(ctPage);
        return seen !== null && seen.session === STARTUP_REPLAY;
      }, { maxAttempts: 20, delayMs: 500 });
    } catch {
      // Asserted below, with what was seen.
    }
    expect(seen, "tab 0's replay after startup").toEqual({
      session: STARTUP_REPLAY, dap: STARTUP_REPLAY, hasReplay: true,
    });
  });
});
