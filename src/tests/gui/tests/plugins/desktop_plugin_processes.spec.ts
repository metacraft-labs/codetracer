// Installed plugins on the DESKTOP (Extensibility-Model.md §11.2.1): the
// Electron main process discovers them, holds them to the user's consent,
// starts ONE plugin-host process per package beside the tab's replay session,
// and the renderer shows what they push — a contributed pane in the
// GoldenLayout layout, the status item, the palette's entries — and routes
// their keys in the turn a key arrives (§11.7.1).
//
// The session the plugins mirror is the renderer's own (`ui/plugin_panes`
// hosts it as a sync primary; `index/plugin_sessions` mirrors it), so a
// plugin's step is a step of the tab on screen.
//
// No stand-ins: the real Electron app, a real recording of
// `test-programs/calc/main.py` made by the real recorder, a real replay, and
// the real `acme-tools` plugin package (a native executable built with the
// plugin SDK, `lib/plugin-processes.ts`).

import { test, expect } from "../../lib/fixtures";
import { CommandPalette } from "../../page-objects/command-palette/command-palette";
import {
  installAcmeTools, pluginEnv, pluginPids, describePids, pluginState, pluginOf, paneText,
  pluginStatusItem, countBodyKeys, bodyKeys, pressRecoveryChord, type PluginHome,
} from "../../lib/plugin-processes";

// Recording, starting the replay and building the plugin package take
// minutes on a loaded host.
test.setTimeout(480_000);

const METRICS = "acme-tools.metrics";
const FLAME = "acme-tools.flame";
const OVERVIEW = "acme-tools.metrics/overview";

async function grantBoth(page: any): Promise<void> {
  // Both must be offered first: the palette runs its best fuzzy match, so a
  // `Review` entry that is not there yet would open the other plugin's screen.
  await expect.poll(async () => (await pluginState(page))?.awaitingConsent ?? [],
    { timeout: 180_000 }).toEqual([METRICS, FLAME]);
  const palette = new CommandPalette(page);
  for (const id of [METRICS, FLAME]) {
    await palette.executeCommand(`Plugins - Review ${id}`);
    const dialog = page.locator("[data-ct-plugin-dialog]");
    await expect(dialog.locator(".plugin-dialog-title")).toHaveText(`GRANT ${id}?`, { timeout: 30_000 });
    await expect(dialog).toContainText("runs the native program", { timeout: 30_000 });
    await dialog.locator(`button[data-plugin-verb="grant ${id}"]`).click();
  }
}

async function waitRunning(page: any, ids: string[]): Promise<void> {
  await expect.poll(async () => {
    const st = await pluginState(page);
    return ids.every((id) => pluginOf(st, id)?.state === "running");
  }, { timeout: 180_000, message: `${ids.join(", ")} running` }).toBe(true);
}

test.describe("desktop: installed plugins run beside the session", () => {
  let home: PluginHome;
  test.beforeAll(() => { home = installAcmeTools(); });
  test.use({
    sourcePath: "calc/main.py",
    launchMode: "trace",
    launchEnv: async ({}, use) => { await use(pluginEnv(home)); },
  });

  test("consent, one process for two plugins, the pane, the status item, a key and a crash", async ({ ctPage }) => {
    // INSTALLING IS NOT ACCEPTING: both wait, nothing runs.
    await expect.poll(async () => (await pluginState(ctPage))?.awaitingConsent ?? [],
      { timeout: 180_000 }).toEqual([METRICS, FLAME]);
    { const pids = pluginPids(home); expect(pids, `no plugin process before consent:\n${describePids(pids)}`).toEqual([]); }
    await expect.poll(async () => await pluginStatusItem(ctPage)).toContain("waits for your consent");

    // GRANTED through the grant screen: ONE process hosts both.
    await grantBoth(ctPage);
    await waitRunning(ctPage, [METRICS, FLAME]);
    const st = await pluginState(ctPage);
    const pid = pluginOf(st, METRICS).pid;
    expect(pid, "metrics has a process").toBeGreaterThan(0);
    expect(pluginOf(st, FLAME).pid, "flame runs in the same process").toBe(pid);
    expect(pluginPids(home), "one plugin process").toEqual([pid]);

    // THE STATUS ITEM and THE PANE, opened from the palette into the layout.
    await expect.poll(async () => await pluginStatusItem(ctPage)).toContain("metrics ok");
    await new CommandPalette(ctPage).executeCommand(`Show pane - Metrics (${OVERVIEW})`);
    await expect(ctPage.locator(`.lm_goldenlayout [data-contributed-pane="${OVERVIEW}"]`))
      .toBeVisible({ timeout: 30_000 });
    await expect.poll(async () => await paneText(ctPage, OVERVIEW), { timeout: 60_000 })
      .toMatch(/line main\.py:\d+/);
    const positionOf = (text: string) => Number((/position (\d+)/.exec(text) ?? ["", "-1"])[1]);
    const before = positionOf(await paneText(ctPage, OVERVIEW));
    expect(before, "the pane is stamped with a position").toBeGreaterThan(0);

    // A PLUGIN KEY, decided in the keydown: Ctrl+Alt+M is metrics' binding
    // (when its `ready` context key holds). The key never reaches the page,
    // and the plugin's step runs on THIS tab's session: its pane follows.
    await countBodyKeys(ctPage);
    await ctPage.evaluate(() => (document.activeElement as any)?.blur?.());
    await ctPage.keyboard.press("Control+Alt+KeyM");
    await expect.poll(async () => positionOf(await paneText(ctPage, OVERVIEW)), { timeout: 60_000 })
      .toBeGreaterThan(before);
    expect(await bodyKeys(ctPage), "the plugin's key was consumed in the router").not.toContain("m");

    // A CRASH: SIGKILL. Restarted, both plugins back, the pane redrawn.
    process.kill(pid, "SIGKILL");
    await expect.poll(() => {
      const now = pluginPids(home);
      return now.length === 1 && now[0] !== pid;
    }, { timeout: 180_000, message: "restarted" }).toBe(true);
    await waitRunning(ctPage, [METRICS, FLAME]);
    await expect.poll(async () => await paneText(ctPage, OVERVIEW), { timeout: 60_000 })
      .toMatch(/line main\.py:\d+/);
  });
});

test.describe("desktop: a plugin layer and the recovery chord", () => {
  let home: PluginHome;
  test.beforeAll(() => {
    home = installAcmeTools({ plugins: { [FLAME]: { settings: { mode: "swallow-input" } } } }, true);
  });
  test.use({
    sourcePath: "calc/main.py",
    launchMode: "trace",
    launchEnv: async ({}, use) => { await use(pluginEnv(home)); },
  });

  test("a window layer takes the keys; three Escapes pop it and open the recovery dialog", async ({ ctPage }) => {
    await grantBoth(ctPage);
    await waitRunning(ctPage, [METRICS, FLAME]);
    await expect.poll(async () => (await pluginState(ctPage))?.layerLabel ?? "",
      { timeout: 60_000 }).toContain("FLAME MODE (acme-tools.flame)");
    await expect.poll(async () => await pluginStatusItem(ctPage)).toContain("FLAME MODE");

    // THE LAYER takes `x`: stopped in the router, never on the page.
    await countBodyKeys(ctPage);
    await ctPage.evaluate(() => (document.activeElement as any)?.blur?.());
    await ctPage.keyboard.press("KeyX");
    await ctPage.waitForTimeout(300);
    expect(await bodyKeys(ctPage), "the layer took the key").not.toContain("x");

    // THE CHORD: three Escapes within a second. The layer goes at once, and
    // the recovery dialog names the plugin that held the keyboard.
    await pressRecoveryChord(ctPage);
    const dialog = ctPage.locator("[data-ct-plugin-dialog]");
    await expect(dialog).toContainText("RECOVER INPUT", { timeout: 30_000 });
    await expect(dialog).toContainText(FLAME);
    await dialog.locator("button", { hasText: "Close" }).click();
    await expect.poll(async () => (await pluginState(ctPage))?.layerLabel ?? "x",
      { timeout: 30_000 }).toBe("");

    // The next key is the page's again.
    await ctPage.evaluate(() => (document.activeElement as any)?.blur?.());
    await ctPage.keyboard.press("KeyX");
    await expect.poll(async () => await bodyKeys(ctPage)).toContain("x");
  });
});

test.describe("desktop: --no-extensions", () => {
  let home: PluginHome;
  test.beforeAll(() => { home = installAcmeTools(); });
  test.use({
    sourcePath: "calc/main.py",
    launchMode: "trace",
    launchEnv: async ({}, use) => {
      await use(pluginEnv(home, { CODETRACER_NO_EXTENSIONS: "1" }));
    },
  });

  test("starts no plugin process, and the debugger works", async ({ ctPage }) => {
    await expect.poll(async () => (await pluginState(ctPage))?.extensionsEnabled,
      { timeout: 180_000 }).toBe(false);
    expect((await pluginState(ctPage)).awaitingConsent, "nothing is even discovered").toEqual([]);
    await ctPage.waitForTimeout(2_000);
    { const pids = pluginPids(home); expect(pids, `no plugin process:\n${describePids(pids)}`).toEqual([]); }
    await expect(ctPage.locator(".lm_goldenlayout")).toBeVisible();
  });
});
