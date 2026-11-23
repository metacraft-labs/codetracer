// Installed plugins under `ct host` (Extensibility-Model.md §11.2.1: "on the
// server, beside the primary session … one plugin-host process per primary
// session"). The server holds each client's session; it runs that session's
// plugins beside it and sends their state to that client's page alone, which
// shows the contributed pane and the status item as any mirror shows the
// session.
//
// Two clients, two sessions, two plugin processes: a plugin of one client's
// session never sees the other's — a step in one page moves that page's pane
// and not the other's, and killing one client's plugin process leaves the
// other's running.
//
// No stand-ins: the real `ct host`, real replays of a real recording of
// `test-programs/calc/main.py`, real browser pages, and the real `acme-tools`
// plugin package (`lib/plugin-processes.ts`).

import { test, expect } from "../../lib/fixtures";
import { CommandPalette } from "../../page-objects/command-palette/command-palette";
import {
  installAcmeTools, pluginEnv, pluginPids, describePids, pluginState, pluginOf, paneText,
  pluginStatusItem, type PluginHome,
} from "../../lib/plugin-processes";

test.setTimeout(600_000);

const METRICS = "acme-tools.metrics";
const FLAME = "acme-tools.flame";
const OVERVIEW = "acme-tools.metrics/overview";

const positionOf = (text: string) => Number((/position (\d+)/.exec(text) ?? ["", "-1"])[1]);

async function waitRunning(page: any): Promise<number> {
  await expect.poll(async () => {
    const st = await pluginState(page);
    return pluginOf(st, METRICS)?.state === "running" && pluginOf(st, FLAME)?.state === "running";
  }, { timeout: 240_000, message: "both plugins running" }).toBe(true);
  return pluginOf(await pluginState(page), METRICS).pid;
}

async function showOverview(page: any): Promise<void> {
  await new CommandPalette(page).executeCommand(`Show pane - Metrics (${OVERVIEW})`);
  await expect(page.locator(`[data-contributed-pane="${OVERVIEW}"]`)).toBeVisible({ timeout: 60_000 });
  await expect.poll(async () => await paneText(page, OVERVIEW), { timeout: 120_000 })
    .toMatch(/line main\.py:\d+/);
}

test.describe("ct host: each client's session has its own plugins", () => {
  let home: PluginHome;
  test.beforeAll(() => { home = installAcmeTools(); });
  test.use({
    sourcePath: "calc/main.py",
    launchMode: "trace",
    deploymentMode: "web",
    launchEnv: async ({}, use) => { await use(pluginEnv(home)); },
  });

  test("a client grants and sees its plugins; a second client's plugins are its own", async ({ ctPage }) => {
    // CONSENT, on the page: nothing runs before it.
    await expect.poll(async () => (await pluginState(ctPage))?.awaitingConsent ?? [],
      { timeout: 240_000 }).toEqual([METRICS, FLAME]);
    { const pids = pluginPids(home); expect(pids, `no plugin process before consent:\n${describePids(pids)}`).toEqual([]); }
    const palette = new CommandPalette(ctPage);
    for (const id of [METRICS, FLAME]) {
      await palette.executeCommand(`Plugins - Review ${id}`);
      const dialog = ctPage.locator("[data-ct-plugin-dialog]");
      await expect(dialog.locator(".plugin-dialog-title")).toHaveText(`GRANT ${id}?`, { timeout: 30_000 });
      await expect(dialog).toContainText("runs the native program", { timeout: 30_000 });
      await dialog.locator(`button[data-plugin-verb="grant ${id}"]`).click();
    }
    const pidA = await waitRunning(ctPage);
    expect(pluginPids(home), "one process for the first client's session").toEqual([pidA]);

    // THE MIRROR SHOWS what the server's plugins pushed.
    await expect.poll(async () => await pluginStatusItem(ctPage), { timeout: 60_000 })
      .toContain("metrics ok");
    await showOverview(ctPage);

    // A SECOND CLIENT: its own session on the server, its own plugin process
    // (the grant is the user's, so it starts at once).
    const browser = ctPage.context().browser();
    expect(browser, "the page runs in a browser").not.toBeNull();
    const other = await browser!.newContext();
    const pageB = await other.newPage();
    await pageB.goto(ctPage.url());
    const pidB = await waitRunning(pageB);
    expect(pidB, "client B's plugins run in a process of their own").not.toBe(pidA);
    expect(pluginPids(home).sort(), "one process per client session").toEqual([pidA, pidB].sort());
    await showOverview(pageB);

    // ISOLATION: A's plugin key steps A's session; B's pane does not move.
    const beforeA = positionOf(await paneText(ctPage, OVERVIEW));
    const beforeB = positionOf(await paneText(pageB, OVERVIEW));
    await ctPage.evaluate(() => (document.activeElement as any)?.blur?.());
    await ctPage.keyboard.press("Control+Alt+KeyM");
    await expect.poll(async () => positionOf(await paneText(ctPage, OVERVIEW)), { timeout: 120_000 })
      .toBeGreaterThan(beforeA);
    await ctPage.waitForTimeout(2_000);
    expect(positionOf(await paneText(pageB, OVERVIEW)), "B's plugin never saw A's step").toBe(beforeB);

    // A's process killed: A's plugins restart; B's process is untouched.
    process.kill(pidA, "SIGKILL");
    await expect.poll(() => pluginPids(home).filter((p) => p !== pidA && p !== pidB).length,
      { timeout: 240_000, message: "A's plugins restarted" }).toBe(1);
    expect(pluginPids(home), "B's process kept running").toContain(pidB);
    expect(pluginOf(await pluginState(pageB), METRICS).pid).toBe(pidB);
    await other.close();
  });
});
