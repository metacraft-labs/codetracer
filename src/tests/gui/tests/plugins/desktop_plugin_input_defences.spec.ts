// The input defences on the DESKTOP (Extensibility-Model.md §11.7), through
// Electron's real keyboard and pointer: a plugin that pushes a window layer
// over every printable key cannot make the window unusable.
//
//   * a key the layer takes and never acknowledges is dropped and said on the
//     status bar; the next falls through to the page, and after three keys
//     the breaker is open and the layer gone (§11.7.4, §11.7.5);
//   * a key acknowledged under the deadline is no strike, and its latency is
//     recorded;
//   * a plugin killed while it holds the keyboard loses its layer at once,
//     the next key is the page's, and its fault notification's Re-enable
//     button brings it back (§11.6.5);
//   * half-open after the backoff, one strike reopens it, and the third
//     opening latches until Re-enable;
//   * a press on a row of its docked pane is a view event, and the plugin
//     answers it (§11.4.4).
//
// No stand-ins: the real Electron app, a real recording of
// `test-programs/calc/main.py` made by the real recorder, a real replay, and
// the real `acme-tools` plugin package (a native executable built with the
// plugin SDK, `lib/plugin-processes.ts`), in its `swallow-input` and
// `slow-ack` modes. The one test-only input is
// `CODETRACER_PLUGIN_TEST_THRESHOLDS` in the half-open case, which shortens
// the breaker's 30 s backoff (`index/plugin_sessions.applyTestThresholds`).

import { test, expect } from "../../lib/fixtures";
import { CommandPalette } from "../../page-objects/command-palette/command-palette";
import {
  installAcmeTools, pluginEnv, pluginPids, pluginState, pluginOf, paneText,
  pluginStatusItem, countBodyKeys, bodyKeys, type PluginHome,
} from "../../lib/plugin-processes";

test.setTimeout(480_000);

const METRICS = "acme-tools.metrics";
const FLAME = "acme-tools.flame";
const FLAME_PANE = "acme-tools.flame/flame";

async function grantBoth(page: any): Promise<void> {
  await expect.poll(async () => (await pluginState(page))?.awaitingConsent ?? [],
    { timeout: 180_000 }).toEqual([METRICS, FLAME]);
  const palette = new CommandPalette(page);
  for (const id of [METRICS, FLAME]) {
    await palette.executeCommand(`Plugins - Review ${id}`);
    const dialog = page.locator("[data-ct-plugin-dialog]");
    await expect(dialog.locator(".plugin-dialog-title")).toHaveText(`GRANT ${id}?`, { timeout: 30_000 });
    await dialog.locator(`button[data-plugin-verb="grant ${id}"]`).click();
  }
}

async function layerHeld(page: any): Promise<void> {
  await expect.poll(async () => {
    const st = await pluginState(page);
    return pluginOf(st, FLAME)?.state === "running" &&
      (st?.layerLabel ?? "").includes("FLAME MODE (acme-tools.flame)");
  }, { timeout: 180_000, message: "flame running, holding its window layer" }).toBe(true);
}

async function press(page: any, key: string): Promise<void> {
  await page.evaluate(() => (document.activeElement as any)?.blur?.());
  await page.keyboard.press(key);
}

const flameOf = async (page: any) => pluginOf(await pluginState(page), FLAME);

/** Three unanswered keys, each waited out: the breaker opens on the third. */
async function threeMissedKeys(page: any, keys: string[]): Promise<void> {
  for (const [i, k] of keys.entries()) {
    await press(page, `Key${k.toUpperCase()}`);
    await expect.poll(async () => (await flameOf(page))?.strikes ?? 0,
      { timeout: 60_000, message: `strike ${i + 1} for \`${k}\`` }).toBeGreaterThanOrEqual(i + 1);
  }
}

test.describe("desktop: a layer that never answers", () => {
  let home: PluginHome;
  test.beforeAll(() => {
    home = installAcmeTools({ plugins: { [FLAME]: { settings: { mode: "swallow-input" } } } }, true);
  });
  test.use({
    sourcePath: "calc/main.py",
    launchMode: "trace",
    launchEnv: async ({}, use) => { await use(pluginEnv(home)); },
  });

  test("the first key is dropped and said, the next falls through, the third opens the breaker", async ({ ctPage }) => {
    await grantBoth(ctPage);
    await layerHeld(ctPage);
    await countBodyKeys(ctPage);

    // `j`: the layer takes it and never answers. Dropped after the 500 ms
    // deadline, never replayed, and the status bar says which plugin.
    await press(ctPage, "KeyJ");
    await expect.poll(async () => await pluginStatusItem(ctPage), { timeout: 60_000 })
      .toContain("`j` went to acme-tools.flame, which did not answer");
    expect(await bodyKeys(ctPage), "a dropped key is not replayed to the page").not.toContain("j");
    expect((await flameOf(ctPage)).strikes, "one strike").toBe(1);

    // `k`: the suspect plugin's layer is transparent until its next ack, so
    // the key reaches the page — and passing it is the second strike.
    await press(ctPage, "KeyK");
    await expect.poll(async () => await bodyKeys(ctPage), { timeout: 30_000 }).toContain("k");
    await expect.poll(async () => (await flameOf(ctPage))?.strikes ?? 0,
      { timeout: 60_000 }).toBeGreaterThanOrEqual(2);

    // `l`: the third strike in the window opens the breaker; the layer goes.
    await press(ctPage, "KeyL");
    await expect.poll(async () => (await flameOf(ctPage))?.breaker, { timeout: 60_000 }).toBe("open");
    await expect.poll(async () => (await pluginState(ctPage))?.layerLabel ?? "x",
      { timeout: 30_000 }).toBe("");
    await press(ctPage, "KeyM");
    await expect.poll(async () => await bodyKeys(ctPage), { timeout: 30_000 }).toContain("m");
    // Its sibling is not touched.
    expect((await pluginState(ctPage)).plugins.find((p: any) => p.id === METRICS).state).toBe("running");
  });
});

test.describe("desktop: a key answered under the deadline", () => {
  let home: PluginHome;
  test.beforeAll(() => {
    home = installAcmeTools({ plugins: { [FLAME]: { settings: { mode: "slow-ack", ackDelayMs: 300 } } } }, true);
  });
  test.use({
    sourcePath: "calc/main.py",
    launchMode: "trace",
    launchEnv: async ({}, use) => { await use(pluginEnv(home)); },
  });

  test("is no strike, and its latency is recorded", async ({ ctPage }) => {
    await grantBoth(ctPage);
    await layerHeld(ctPage);
    await countBodyKeys(ctPage);
    for (const k of ["KeyJ", "KeyK"]) {
      await press(ctPage, k);
      await ctPage.waitForTimeout(100);
    }
    // Both acknowledged (300 ms each, under the 500 ms deadline): latencies
    // recorded, no strike, the layer still held, and the keys were the
    // layer's (never the page's).
    await expect.poll(async () => (await flameOf(ctPage))?.ackP50 ?? 0,
      { timeout: 60_000, message: "the acknowledgement latency is recorded" }).toBeGreaterThanOrEqual(250);
    const flame = await flameOf(ctPage);
    expect(flame.strikes, "no strike").toBe(0);
    expect(flame.breaker).toBe("closed");
    expect((await pluginState(ctPage)).layerLabel).toContain("FLAME MODE");
    expect(await bodyKeys(ctPage)).not.toContain("j");
  });
});

test.describe("desktop: a plugin killed while it holds the keyboard", () => {
  let home: PluginHome;
  test.beforeAll(() => {
    home = installAcmeTools({ plugins: { [FLAME]: { settings: { mode: "swallow-input" } } } }, true);
  });
  test.use({
    sourcePath: "calc/main.py",
    launchMode: "trace",
    launchEnv: async ({}, use) => { await use(pluginEnv(home)); },
  });

  test("loses the layer at once; its fault notification's Re-enable brings it back", async ({ ctPage }) => {
    await grantBoth(ctPage);
    await layerHeld(ctPage);
    const pid = (await flameOf(ctPage)).pid;
    expect(pid, "flame runs in a process of its own").toBeGreaterThan(0);
    expect(pid, "a window-capturing plugin is apart from its sibling")
      .not.toBe(pluginOf(await pluginState(ctPage), METRICS).pid);

    await countBodyKeys(ctPage);
    process.kill(pid, "SIGKILL");
    // A crash while holding an input layer opens the breaker at once: the
    // layer is gone and the next key is the page's.
    await expect.poll(async () => (await pluginState(ctPage))?.layerLabel ?? "x",
      { timeout: 30_000 }).toBe("");
    await press(ctPage, "KeyX");
    await expect.poll(async () => await bodyKeys(ctPage), { timeout: 30_000 }).toContain("x");
    expect((await flameOf(ctPage)).breaker).toBe("open");

    // THE FAULT NOTIFICATION, with its actions as buttons.
    const note = ctPage.locator("#active-notifications .status-notification",
                                { hasText: "Plugin 'acme-tools.flame' was stopped" });
    await expect(note).toBeVisible({ timeout: 30_000 });
    for (const label of ["Re-enable", "Disable", "Show log"]) {
      await expect(note.locator(".notification-action-button", { hasText: `${label} ${FLAME}` }))
        .toBeVisible();
    }
    await note.locator(".notification-action-button", { hasText: `Re-enable ${FLAME}` }).click();
    await expect.poll(async () => (await flameOf(ctPage))?.state ?? "", { timeout: 120_000 })
      .toBe("running (on probation)");
    expect(pluginPids(home).length, "a new process for flame").toBeGreaterThanOrEqual(2);
  });
});

test.describe("desktop: half-open, reopen and latch", () => {
  let home: PluginHome;
  test.beforeAll(() => {
    home = installAcmeTools({ plugins: { [FLAME]: { settings: { mode: "swallow-input" } } } }, true);
  });
  test.use({
    sourcePath: "calc/main.py",
    launchMode: "trace",
    launchEnv: async ({}, use) => {
      await use(pluginEnv(home, {
        CODETRACER_PLUGIN_TEST_THRESHOLDS: JSON.stringify({
          breakerBackoffMs: 3_000, breakerBackoffCapMs: 3_000, openingsToLatch: 3,
        }),
      }));
    },
  });

  test("after the backoff it runs again, one strike reopens it, the third opening latches until Re-enable", async ({ ctPage }) => {
    await grantBoth(ctPage);
    await layerHeld(ctPage);
    await threeMissedKeys(ctPage, ["j", "k", "l"]);
    await expect.poll(async () => (await flameOf(ctPage))?.breaker, { timeout: 60_000 }).toBe("open");

    for (let opening = 2; opening <= 3; opening++) {
      // Half-open after the backoff: running again, on probation, its layer back.
      await expect.poll(async () => (await flameOf(ctPage))?.state ?? "", { timeout: 120_000 })
        .toBe("running (on probation)");
      await expect.poll(async () => (await pluginState(ctPage))?.layerLabel ?? "",
        { timeout: 60_000 }).toContain("FLAME MODE");
      // One strike on probation reopens it.
      await press(ctPage, "KeyJ");
      await expect.poll(async () => (await flameOf(ctPage))?.breaker, { timeout: 60_000 }).toBe("open");
    }
    // The third opening latches: no half-open after the backoff.
    await expect.poll(async () => (await flameOf(ctPage))?.state ?? "", { timeout: 30_000 })
      .toBe("stopped until re-enabled");
    await ctPage.waitForTimeout(6_000);
    expect((await flameOf(ctPage)).state, "still latched past the backoff").toBe("stopped until re-enabled");
    expect((await flameOf(ctPage)).latched).toBe(true);

    // Re-enable, from the palette's entries for a stopped plugin.
    await new CommandPalette(ctPage).executeCommand(`Plugins - Re-enable ${FLAME}`);
    await expect.poll(async () => (await flameOf(ctPage))?.state ?? "", { timeout: 120_000 })
      .toBe("running (on probation)");
  });
});

test.describe("desktop: a press on a plugin pane's row", () => {
  let home: PluginHome;
  test.beforeAll(() => { home = installAcmeTools(); });
  test.use({
    sourcePath: "calc/main.py",
    launchMode: "trace",
    launchEnv: async ({}, use) => { await use(pluginEnv(home)); },
  });

  test("is a view event, and the plugin answers it", async ({ ctPage }) => {
    await grantBoth(ctPage);
    await expect.poll(async () => (await flameOf(ctPage))?.state ?? "", { timeout: 180_000 }).toBe("running");
    await new CommandPalette(ctPage).executeCommand(`Show pane - Flame (${FLAME_PANE})`);
    const pane = ctPage.locator(`.lm_goldenlayout [data-contributed-pane="${FLAME_PANE}"]`);
    await expect(pane).toBeVisible({ timeout: 30_000 });
    await expect.poll(async () => await paneText(ctPage, FLAME_PANE), { timeout: 60_000 }).toContain("work 40%");
    await pane.locator('[data-option-index="1"]').click();
    await expect.poll(async () => await paneText(ctPage, FLAME_PANE), { timeout: 60_000 })
      .toContain("work 40% (activated)");
  });
});

test.describe("desktop: a plugin's marks in the editor", () => {
  let home: PluginHome;
  test.beforeAll(() => { home = installAcmeTools(); });
  test.use({
    sourcePath: "calc/main.py",
    launchMode: "trace",
    launchEnv: async ({}, use) => { await use(pluginEnv(home)); },
  });

  test("its decoration is drawn after the current line's code and its marker in the glyph margin", async ({ ctPage }) => {
    await grantBoth(ctPage);
    await expect.poll(async () => pluginOf(await pluginState(ctPage), METRICS)?.state ?? "",
      { timeout: 180_000 }).toBe("running");
    // metrics decorates and marks the line the debugger is on (`hotspot`).
    const line = async () => (await pluginState(ctPage))?.editorMarks?.decorations?.[0]?.line ?? 0;
    await expect.poll(line, { timeout: 60_000 }).toBeGreaterThan(0);
    const decoration = ctPage.locator(".monaco-editor .ct-plugin-decoration");
    await expect(decoration.first()).toBeVisible({ timeout: 60_000 });
    await expect(decoration.first()).toContainText(/metrics:\s+line\s+\d+/);
    await expect(decoration.first()).toContainText(METRICS);
    await expect(ctPage.locator(".monaco-editor .glyph-margin .ct-plugin-marker, .monaco-editor .ct-plugin-marker").first())
      .toBeAttached({ timeout: 60_000 });
    // A plugin that is off draws none.
    await new CommandPalette(ctPage).executeCommand("Plugins - Disable all for this session");
    await expect(decoration).toHaveCount(0, { timeout: 60_000 });
    await expect(ctPage.locator(".monaco-editor .ct-plugin-marker")).toHaveCount(0, { timeout: 60_000 });
  });
});
