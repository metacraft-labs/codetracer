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
 *   1. After the startup trace has loaded, tab 0's `replayId` — on the
 *      session and on its `DapApi`, which names it on every request — is the
 *      replay the session manager started for it: 0, the first replay a fresh
 *      session manager starts (each `ctPage` launches its own).
 *   2. Stop (SHIFT+F5) in tab 0 sends `close-replay-session` for that replay.
 *   3. Closing tab 0 (beside a second tab) sends `close-replay-session` for
 *      that replay.
 *
 * The renderer's outgoing IPC is observed by wrapping `data.ipc.send` in the
 * page — the main process's realm is not reachable from `page.evaluate`. The
 * wrapper records and forwards; the message still reaches the main process.
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

async function recordIpc(page: Page): Promise<void> {
  await page.evaluate(() => {
    const d = (window as any).data;
    const w = window as any;
    w.__ctSent = [];
    const original = d.ipc.send.bind(d.ipc);
    d.ipc.send = (channel: string, payload: any) => {
      w.__ctSent.push({ channel: String(channel), payload: JSON.parse(JSON.stringify(payload ?? null)) });
      return original(channel, payload);
    };
  });
}

async function closeReplayIds(page: Page): Promise<number[]> {
  return page.evaluate(() =>
    ((window as any).__ctSent ?? [])
      .filter((m: any) => m.channel === "CODETRACER::close-replay-session")
      .map((m: any) => Number(m.payload?.replayId)),
  );
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

  test("Stop in tab 0 ends the replay started for it", async ({ ctPage }) => {
    await waitForFirstTabReady(ctPage);
    await recordIpc(ctPage);
    await ctPage.locator("body").click({ position: { x: 5, y: 5 } }).catch(() => {});
    await ctPage.keyboard.press("Shift+F5");
    let ids: number[] = [];
    try {
      await retry(async () => {
        ids = await closeReplayIds(ctPage);
        return ids.length > 0;
      }, { maxAttempts: 20, delayMs: 500 });
    } catch {
      // Asserted below.
    }
    expect(ids, "close-replay-session sent by Stop in tab 0").toEqual([STARTUP_REPLAY]);
  });

  test("closing tab 0 ends the replay started for it", async ({ ctPage }) => {
    await waitForFirstTabReady(ctPage);
    await ctPage.locator(".session-tab-add").click();
    await retry(async () => (await ctPage.locator(".session-tab").count()) >= 2,
      { maxAttempts: 30, delayMs: 250 });
    await recordIpc(ctPage);
    await ctPage.locator("#session-tab-0 .session-tab-close").click();
    let ids: number[] = [];
    try {
      await retry(async () => {
        ids = await closeReplayIds(ctPage);
        return ids.length > 0;
      }, { maxAttempts: 20, delayMs: 500 });
    } catch {
      // Asserted below.
    }
    expect(ids, "close-replay-session sent by closing tab 0").toEqual([STARTUP_REPLAY]);
  });
});
