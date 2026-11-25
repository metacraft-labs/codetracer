// The `ct-lens` plugin package (`src/plugins/ct-lens/`) under `ct host`
// (Extensibility-Model.md §11.2.1: "on the server, beside the primary session
// … one plugin-host process per primary session"): the server runs a client
// tab's plugins beside the session it holds for that tab, and they read the
// session through a mirror of it.
//
// What this suite proves is that the mirror is the WHOLE session, not just
// its position. `ct-lens.history` reads only the stop; `ct-lens.watch` reads
// the state pane's change set (`StateVM.valueChanges`) and the locals. The
// server's session builds its panel ViewModels when the replay first stops
// (`sync/hosted_primary`), so a mirror whose publisher was made before then
// carried the store alone: the debugger moved, the history pane followed it,
// and the watch status read `changed: …` (the change set unknown) at every
// stop of the recording. And once the mirror did carry the change set, the
// first batch with a module's locals in it (`__builtins__` among them) was
// larger than the server's JavaScript could frame (`plugin_host/byte_append`):
// it was never sent, and the plugin's mirror refused every batch after the
// gap. The `acme-tools` package, which reads only the position and pushes
// small frames, could not see either, which is why this suite exists beside
// `ct_host_plugin_processes.spec.ts`.
//
//   * The history pane names the function the debugger is in.
//   * Stepping, ct-lens.watch's status item names what a step changed.
//   * F7 watches it (a relayed `addWatch` on the server's session), and the
//     command is then disabled with its reason.
//
// No stand-ins: the real `ct host`, a real replay of a real recording of
// `test-programs/calc/main.py`, a real browser page, and the real ct-lens
// package built with the plugin SDK (`lib/plugin-processes.ts`,
// `installCtLens`).

import { test, expect } from "../../lib/fixtures";
import { CommandPalette } from "../../page-objects/command-palette/command-palette";
import {
  installCtLens, pluginEnv, pluginPids, describePids, pluginState, pluginOf, paneText,
  pluginStatusItem, LensExecutablePattern, commandOf, stepUntilOneChange, type PluginHome,
} from "../../lib/plugin-processes";

test.setTimeout(600_000);

const HISTORY = "ct-lens.history";
const WATCH = "ct-lens.watch";
const JUMP = "ct-lens.jump";
const LENS = [HISTORY, JUMP, WATCH];
const HISTORY_PANE = "ct-lens.history/history";

test.describe("ct host: the ct-lens plugins read the client's whole session", () => {
  let home: PluginHome;
  test.beforeAll(() => { home = installCtLens(); });
  test.use({
    sourcePath: "calc/main.py",
    launchMode: "trace",
    deploymentMode: "web",
    launchEnv: async ({}, use) => { await use(pluginEnv(home)); },
  });

  test("the history pane follows the stop; the watch status names what a step changed; F7 watches it", async ({ ctPage }) => {
    // CONSENT, on the page: nothing runs before it. All three must be offered
    // first: the palette runs its best fuzzy match.
    await expect.poll(async () => [...((await pluginState(ctPage))?.awaitingConsent ?? [])].sort(),
      { timeout: 240_000 }).toEqual(LENS);
    { const pids = pluginPids(home, LensExecutablePattern); expect(pids, `no plugin process before consent:\n${describePids(pids)}`).toEqual([]); }
    const palette = new CommandPalette(ctPage);
    for (const id of LENS) {
      await palette.executeCommand(`Plugins - Review ${id}`);
      const dialog = ctPage.locator("[data-ct-plugin-dialog]");
      await expect(dialog.locator(".plugin-dialog-title")).toHaveText(`GRANT ${id}?`, { timeout: 30_000 });
      await dialog.locator(`button[data-plugin-verb="grant ${id}"]`).click();
    }
    await expect.poll(async () => {
      const st = await pluginState(ctPage);
      return LENS.every((id) => pluginOf(st, id)?.state === "running");
    }, { timeout: 240_000, message: "the three ct-lens plugins running" }).toBe(true);

    // THE STOP: the history pane names the function the debugger is in.
    await new CommandPalette(ctPage).executeCommand(`Show pane - Line history (${HISTORY_PANE})`);
    await expect(ctPage.locator(`[data-contributed-pane="${HISTORY_PANE}"]`)).toBeVisible({ timeout: 60_000 });
    await expect.poll(async () => await paneText(ctPage, HISTORY_PANE), { timeout: 90_000 })
      .toContain("History of ");
    await expect.poll(async () => await pluginStatusItem(ctPage), { timeout: 60_000 })
      .toContain("history: ");

    // WHAT A STEP CHANGED: step until ct-lens.watch's status item names ONE
    // changed value. "changed: …" is its reading while the mirrored change
    // set is unknown; read at every stop, the mirror never learned it.
    // Each reading is of the stop the step landed on and of its locals
    // (`stepUntilOneChange`).
    const { changed, seen } = await stepUntilOneChange(ctPage, WATCH, "watch.status", "watch.add-changed");
    expect(changed, `a step changed exactly one value; the status item read: ${seen.join(" | ")}`).not.toBe("");

    // F7 WATCHES IT: the plugin's relayed `addWatch` runs on the server's
    // session, and the change set it reads says nothing is left to watch.
    await expect.poll(async () => commandOf(await pluginState(ctPage), WATCH, "watch.add-changed")?.enabled,
      { timeout: 30_000 }).toBe(true);
    await ctPage.evaluate(() => (document.activeElement as any)?.blur?.());
    await ctPage.keyboard.press("F7");
    await expect.poll(async () => commandOf(await pluginState(ctPage), WATCH, "watch.add-changed")?.reason ?? "",
      { timeout: 60_000 }).toBe("every changed value is already watched");
  });
});
