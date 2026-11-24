// The `ct-lens` plugin package (`src/plugins/ct-lens/`) on the DESKTOP
// (Extensibility-Model.md §11): its three plugins as the Electron main
// process runs them beside the tab's replay session, and what the renderer
// shows of them.
//
//   * ct-lens.history and ct-lens.watch share one plugin-host process;
//     ct-lens.jump captures the window's keys, so it runs in its own.
//   * The line-history pane draws the history of the function the debugger
//     is in, and its status item reaches the status bar.
//   * F7 is ct-lens.watch's binding while a step changed something not yet
//     watched: pressed after a step that changed one value, it watches it,
//     and the command is then disabled with its reason.
//   * Shift+F7 opens ct-lens.jump's mode (a window layer, named by the
//     status bar); a digit jumps through the calltrace and closes it, the
//     jump pane says where, and the history pane follows the debugger there.
//   * Opened again, three Escapes take the keyboard back and the recovery
//     dialog names the plugin.
//
// No stand-ins: the real Electron app, a real recording of
// `test-programs/calc/main.py`, a real replay, and the real ct-lens package
// built with the plugin SDK (`lib/plugin-processes.ts`, `installCtLens`).
// When the recording's source is not in a git repository on this machine,
// the history pane says why it has no commits; the function it names is
// still read from the session.

import { test, expect } from "../../lib/fixtures";
import { CommandPalette } from "../../page-objects/command-palette/command-palette";
import {
  installCtLens, pluginEnv, pluginPids, describePids, pluginState, pluginOf, paneText,
  pluginStatusItem, countBodyKeys, bodyKeys, LensExecutablePattern, type PluginHome,
} from "../../lib/plugin-processes";

test.setTimeout(600_000);

const HISTORY = "ct-lens.history";
const WATCH = "ct-lens.watch";
const JUMP = "ct-lens.jump";
const LENS = [HISTORY, JUMP, WATCH];
const HISTORY_PANE = "ct-lens.history/history";
const CALLS_PANE = "ct-lens.jump/calls";

function statusText(st: any, plugin: string, item: string): string {
  const it = (st?.status ?? []).find((s: any) => s.plugin === plugin && s.item === item);
  return it ? String(it.text) : "";
}

/** The tab's debugger line, for a red run's message ("?" before a stop). */
async function debuggerLine(page: any): Promise<string> {
  return await page.evaluate(() => {
    const d = (window as any).data;
    const loc = d?.sessions?.[d.activeSessionIndex]?.services?.debugger?.location;
    return loc ? `line ${loc.line}` : "?";
  });
}

function commandOf(st: any, plugin: string, op: string): any {
  return (st?.commands ?? []).find((c: any) => c.plugin === plugin && c.op === op) ?? null;
}

async function grantLens(page: any): Promise<void> {
  // All three must be offered first: the palette runs its best fuzzy match.
  await expect.poll(async () => [...((await pluginState(page))?.awaitingConsent ?? [])].sort(),
    { timeout: 240_000 }).toEqual(LENS);
  const palette = new CommandPalette(page);
  for (const id of LENS) {
    await palette.executeCommand(`Plugins - Review ${id}`);
    const dialog = page.locator("[data-ct-plugin-dialog]");
    await expect(dialog.locator(".plugin-dialog-title")).toHaveText(`GRANT ${id}?`, { timeout: 30_000 });
    await dialog.locator(`button[data-plugin-verb="grant ${id}"]`).click();
  }
  await expect.poll(async () => {
    const st = await pluginState(page);
    return LENS.every((id) => pluginOf(st, id)?.state === "running");
  }, { timeout: 240_000, message: "the three ct-lens plugins running" }).toBe(true);
}

test.describe("desktop: the ct-lens plugins", () => {
  let home: PluginHome;
  test.beforeAll(() => { home = installCtLens(); });
  test.use({
    sourcePath: "calc/main.py",
    launchMode: "trace",
    launchEnv: async ({}, use) => { await use(pluginEnv(home)); },
  });

  test("two processes, the history pane, F7 watches, Shift+F7 jumps, three Escapes", async ({ ctPage }) => {
    await expect.poll(async () => (await pluginState(ctPage))?.awaitingConsent?.length ?? 0,
      { timeout: 240_000 }).toBe(3);
    { const pids = pluginPids(home, LensExecutablePattern); expect(pids, `no plugin process before consent:\n${describePids(pids)}`).toEqual([]); }
    await grantLens(ctPage);

    // TWO PROCESSES: history and watch share one; jump, which captures the
    // window's keys, has its own.
    const st = await pluginState(ctPage);
    const shared = pluginOf(st, HISTORY).pid;
    expect(shared).toBeGreaterThan(0);
    expect(pluginOf(st, WATCH).pid, "watch shares history's process").toBe(shared);
    expect(pluginOf(st, JUMP).pid, "jump has a process of its own").not.toBe(shared);
    expect(pluginPids(home, LensExecutablePattern).sort()).toEqual([shared, pluginOf(st, JUMP).pid].sort());

    // THE HISTORY PANE, from the palette into the layout, and its status item.
    await new CommandPalette(ctPage).executeCommand(`Show pane - Line history (${HISTORY_PANE})`);
    await expect(ctPage.locator(`.lm_goldenlayout [data-contributed-pane="${HISTORY_PANE}"]`))
      .toBeVisible({ timeout: 30_000 });
    await expect.poll(async () => await paneText(ctPage, HISTORY_PANE), { timeout: 90_000 })
      .toContain("History of ");
    await expect.poll(async () => await pluginStatusItem(ctPage), { timeout: 60_000 })
      .toContain("history: ");

    // F7: step until ct-lens.watch's status item names ONE changed value,
    // then F7 watches it. The key is decided in the keydown and never
    // reaches the page.
    let changed = "";
    const seen: string[] = [];
    for (let i = 0; i < 25 && changed === ""; i++) {
      // F10 is the window's step over (no plugin binds it).
      await ctPage.keyboard.press("F10");
      // The item is pushed when the plugin read the new stop's changes; "…"
      // is its reading before it knows them.
      const deadline = Date.now() + 10_000;
      let text = "";
      while (Date.now() < deadline) {
        text = statusText(await pluginState(ctPage), WATCH, "watch.status");
        if (text.startsWith("changed: ") && text !== "changed: …") break;
        await ctPage.waitForTimeout(300);
      }
      seen.push(`${await debuggerLine(ctPage)}: ${text}`);
      const m = /^changed: ([^,\s…]+)$/.exec(text);
      if (m && m[1] !== "none") changed = m[1];
    }
    expect(changed, `a step changed exactly one value; the status item read: ${seen.join(" | ")}`).not.toBe("");
    await expect.poll(async () => commandOf(await pluginState(ctPage), WATCH, "watch.add-changed")?.enabled,
      { timeout: 30_000 }).toBe(true);
    await countBodyKeys(ctPage);
    await ctPage.evaluate(() => (document.activeElement as any)?.blur?.());
    await ctPage.keyboard.press("F7");
    await expect.poll(async () => commandOf(await pluginState(ctPage), WATCH, "watch.add-changed")?.reason ?? "",
      { timeout: 60_000 }).toBe("every changed value is already watched");
    expect(await bodyKeys(ctPage), "F7 was the plugin's").not.toContain("F7");

    // SHIFT+F7: the jump mode, a window layer named on the status bar.
    await new CommandPalette(ctPage).executeCommand(`Show pane - Jump to call (${CALLS_PANE})`);
    await expect.poll(async () => await paneText(ctPage, CALLS_PANE), { timeout: 60_000 })
      .toContain("Jump to call");
    await expect.poll(async () => commandOf(await pluginState(ctPage), JUMP, "jump.open")?.enabled,
      { timeout: 60_000 }).toBe(true);
    await ctPage.evaluate(() => (document.activeElement as any)?.blur?.());
    await ctPage.keyboard.press("Shift+F7");
    await expect.poll(async () => (await pluginState(ctPage))?.layerLabel ?? "", { timeout: 60_000 })
      .toBe("JUMP MODE (ct-lens.jump)");
    const listed = statusText(await pluginState(ctPage), JUMP, "jump.status");
    const pick = /(?:^|\s)2 (\S+)/.exec(listed);
    expect(pick, `the mode numbers the calls: ${listed}`).not.toBeNull();
    const picked = pick![1];
    // A digit in the mode jumps through the calltrace and closes it.
    await ctPage.keyboard.press("2");
    await expect.poll(async () => (await pluginState(ctPage))?.layerLabel ?? "x", { timeout: 60_000 })
      .toBe("");
    await expect.poll(async () => await paneText(ctPage, CALLS_PANE), { timeout: 60_000 })
      .toContain(`jumped to ${picked} `);
    await expect.poll(async () => await paneText(ctPage, HISTORY_PANE), { timeout: 90_000 })
      .toContain(`History of ${picked} `);

    // Opened again: three Escapes take the keyboard back from it.
    await ctPage.keyboard.press("Shift+F7");
    await expect.poll(async () => (await pluginState(ctPage))?.layerLabel ?? "", { timeout: 60_000 })
      .toBe("JUMP MODE (ct-lens.jump)");
    for (let i = 0; i < 3; i++) await ctPage.keyboard.press("Escape");
    const dialog = ctPage.locator("[data-ct-plugin-dialog]");
    await expect(dialog).toContainText("RECOVER INPUT", { timeout: 30_000 });
    await expect(dialog).toContainText(JUMP);
    await dialog.locator("button", { hasText: "Close" }).click();
    await expect.poll(async () => (await pluginState(ctPage))?.layerLabel ?? "x", { timeout: 30_000 })
      .toBe("");
    // The healthy plugin keeps running.
    expect(pluginOf(await pluginState(ctPage), JUMP)?.state).toBe("running");
  });
});
