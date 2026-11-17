/**
 * plat68b-desktop-keys.spec.ts — PLAT-68 Phase B, the desktop's column: the
 * user's `keybindings.json` changed ON DISK while the window is open, on a
 * real recording with a real `replay-server`:
 *
 *   * a change to the file changes the chord the program menu shows (the
 *     menu remembers its items' chords between redraws, #784);
 *   * a change to the file takes effect in the keys without a restart.
 *
 * The rest of this file's cases are scenarios now (`src/tests/scenarios/
 * keymaps/plat68b-*.yaml`: F10 once, a letter and Enter in the read-only
 * editor, Alt+E, Ctrl+B, Alt and Alt+D, a user row added and one removed).
 * These two stay here because a scenario cannot change a file once its
 * steps have begun: its stage runs before the first step.
 *
 * WHAT IS READ: `window.__ctKeyTrace` — every operation the router ran, in
 * order — beside the product's own state (the debugger's location, the DOM).
 * No mocks: the real app, the real `ct`, a real engine.
 */

import * as fs from "fs";
import * as path from "path";
import { ctUserConfigDir } from "../../lib/ct-home";

import { expect } from "@playwright/test";
import { test } from "../../lib/fixtures";

const repoRoot = path.resolve(__dirname, "..", "..", "..", "..", "..");
const prefix = process.env.PLAT68_DESKTOP_PREFIX ?? "";

function recording(prefixName: string): string {
  // `PLAT68_FIXTURES_DIR`: a recording set the built desktop backend reads
  // (the prefix runs a built variant's `ct` and `replay-server`, which must
  // understand the recording's container version).
  const cache = process.env.PLAT68_FIXTURES_DIR ??
    path.join(repoRoot, "test-logs", "tui-fixtures");
  const hits = fs.existsSync(cache)
    ? fs.readdirSync(cache).filter((e) => e.startsWith(prefixName + "-")).sort()
    : [];
  if (hits.length === 0) {
    throw new Error(
      `PLAT-68: the '${prefixName}' recording is not in test-logs/tui-fixtures/; ` +
        "run the tui lane once (its fixture provider records it).",
    );
  }
  return path.join(cache, hits[hits.length - 1]);
}

const keybindingsFile = () => path.join(ctUserConfigDir(), "keybindings.json");

function writeKeybindings(text: string | null) {
  const f = keybindingsFile();
  if (text === null) {
    try { fs.unlinkSync(f); } catch { /* absent */ }
    return;
  }
  fs.mkdirSync(path.dirname(f), { recursive: true });
  fs.writeFileSync(f, text);
}

function where(page: any) {
  return page.evaluate(() => {
    const loc = (globalThis as any).data?.services?.debugger?.location;
    return { line: loc?.line ?? -1, ticks: Number(loc?.rrTicks ?? -1) };
  });
}

async function waitMoved(page: any, from: { ticks: number }) {
  const deadline = Date.now() + 60_000;
  let now = await where(page);
  while (Date.now() < deadline && now.ticks === from.ticks) {
    await page.waitForTimeout(200);
    now = await where(page);
  }
  // Settle: a second step that a double dispatch would add lands after the
  // first; give it the time to.
  await page.waitForTimeout(1_500);
  return where(page);
}

async function keyTrace(page: any): Promise<string[]> {
  return page.evaluate(() => ((globalThis as any).__ctKeyTrace ?? []).slice());
}

async function clearTrace(page: any) {
  await page.evaluate(() => { (globalThis as any).__ctKeyTrace = []; });
}

async function caretInEditor(page: any) {
  // A REAL click, because what these tests exercise is real input — but on a
  // point the editor actually shows.  A `.view-line` is as wide as the
  // file's longest line (6575 px for `calc/main.py` in a 455 px editor), so
  // its centre, where `locator.click()` aims by default, lies far outside the
  // editor's visible content box; Playwright then reported whatever covered
  // that point (the State pane's watch field, its Globals tab, the gutter)
  // as intercepting the click, and every test died here.  The point used is
  // just inside the left edge of a line's intersection with its editor's
  // `.monaco-scrollable-element` (the content area, right of the gutter),
  // vertically centred, given relative to the line as `click` takes it.
  //
  // Waits for such a line rather than taking the first `.view-line` as it
  // is: right after launch the editor may not have laid out yet, and Monaco
  // keeps line nodes in DOM order, not screen order.
  const target = await page.waitForFunction(() => {
    const lines = Array.from(
      document.querySelectorAll(".monaco-editor .view-lines > .view-line"),
    ) as HTMLElement[];
    for (let index = 0; index < lines.length; index++) {
      const lineBox = lines[index].getBoundingClientRect();
      const content = lines[index].closest(".monaco-editor")
        ?.querySelector(".monaco-scrollable-element")
        ?.getBoundingClientRect();
      if (!content) continue;
      const left = Math.max(lineBox.left, content.left);
      const right = Math.min(lineBox.right, content.right);
      const top = Math.max(lineBox.top, content.top);
      const bottom = Math.min(lineBox.bottom, content.bottom);
      // Whole line height inside the content box, and room to click.
      if (right - left < 2 || bottom - top < lineBox.height - 0.5) continue;
      return {
        index,
        x: left + Math.min(8, (right - left) / 2) - lineBox.left,
        y: (top + bottom) / 2 - lineBox.top,
      };
    }
    return null;
  }, undefined, { timeout: 120_000 });
  const { index, x, y } = await target.jsonValue();
  await page
    .locator(".monaco-editor .view-lines > .view-line")
    .nth(index)
    .click({ position: { x, y } });
  await page.waitForFunction(() => {
    const a = document.activeElement as HTMLElement | null;
    return !!a && !!a.closest("[data-scope-kind='editor']");
  }, undefined, { timeout: 20_000 });
}

test.setTimeout(300_000);

test.describe("PLAT-68: the user's keybindings.json on the desktop", () => {
  test.use({
    sourcePath: recording("calc"),
    launchMode: "trace-folder",
    codetracerPrefixOverride: prefix,
  });

  test.beforeAll(() => writeKeybindings(`// a user keymap, JSONC
[
  { "key": "ctrl+alt+n", "command": "debugger.step-over" },
  { "key": "f10", "command": "-debugger.step-over" },
]
`));
  test.afterAll(() => writeKeybindings(null));

  // The program menu's chords are remembered between redraws (the menu asks
  // for every item's chord on every move, #784), so a reloaded file must
  // replace what the menu shows, not only what the keys do. Read through the
  // open Debug folder rather than a key press, so the check does not depend
  // on where the keyboard focus is.
  test("a change to the file on disk changes the chord the menu shows", async ({ ctPage }) => {
    await ctPage.waitForSelector(".calltrace-view .call-text", { timeout: 120_000 });
    // The open Debug folder's text, or "" when the menu was re-rendering
    // under the click (a reload rebuilds it), so `expect.poll` asks again
    // instead of failing on a transient miss.
    const debugFolder = async (): Promise<string> => {
      try {
        await ctPage.evaluate(() => (globalThis as any).__ctMenuVM.open());
        const folder = ctPage.locator("#menu-elements").getByText("Debug", { exact: true }).first();
        await folder.waitFor({ state: "visible", timeout: 5_000 });
        await folder.click({ force: true, timeout: 5_000 });
        await ctPage.waitForFunction(
          () => document.body.innerText.includes("Reverse Step Over"),
          undefined, { timeout: 5_000 });
        return await ctPage.evaluate(() => document.body.innerText);
      } catch {
        return "";
      } finally {
        await ctPage.evaluate(() => (globalThis as any).__ctMenuVM.close());
        await expect.poll(async () => await ctPage.evaluate(() =>
          JSON.parse((globalThis as any).__ctMenuVM.state()).isOpen),
                          { timeout: 10_000 }).toBe(false);
      }
    };
    // The describe's file: Step Over is the user's Ctrl+Alt+N, F10 removed.
    await expect.poll(debugFolder, { timeout: 30_000 }).toContain("\nStep Over\nCtrl+Alt+N\n");
    writeKeybindings(`[ { "key": "ctrl+alt+j", "command": "debugger.step-over" } ]`);
    await expect.poll(debugFolder, { timeout: 30_000 }).toContain("\nStep Over\nCtrl+Alt+J\n");
    expect(await debugFolder()).not.toContain("\nStep Over\nCtrl+Alt+N\n");
  });

  test("a change to the file on disk takes effect without a restart", async ({ ctPage }) => {
    await ctPage.waitForSelector(".calltrace-view .call-text", { timeout: 120_000 });
    await caretInEditor(ctPage);
    writeKeybindings(`[ { "key": "ctrl+alt+j", "command": "debugger.step-over" } ]`);
    // fs.watchFile polls every 500 ms; the renderer re-keys on arrival.
    await ctPage.waitForTimeout(2_500);
    await caretInEditor(ctPage);
    await clearTrace(ctPage);
    const start = await where(ctPage);
    await ctPage.keyboard.press("Control+Alt+KeyJ");
    await waitMoved(ctPage, start);
    expect(await keyTrace(ctPage)).toEqual(["debugger.step-over"]);
  });
});
