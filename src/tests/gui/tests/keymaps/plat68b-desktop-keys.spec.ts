/**
 * plat68b-desktop-keys.spec.ts — PLAT-68 Phase B, the desktop's column: the
 * real Electron front-end's keys go through ONE capture-phase listener and
 * the shared router (`src/frontend/ui/key_router.nim`), on a real recording
 * with a real `replay-server`.
 *
 *   * `F10` runs `debugger.step-over` ONCE (the Mousetrap table and the
 *     Monaco `commands` table each used to answer it), and the stop it reaches
 *     is the toolbar's Step Over's;
 *   * with the caret in the read-only editor a LETTER steps (`n`) and types
 *     nothing; `Enter` opens the tracepoint editor on the caret's line;
 *   * `Alt+E` focuses the Event Log with the caret IN the editor too (it used
 *     to toggle macro expansion there — the two-actions-by-focus issue);
 *   * `Ctrl+B` toggles the side panels (pinned to their edges, and back —
 *     the layout's shape restored, not one stack per panel);
 *     `Ctrl+Shift+B` is `build.run`;
 *   * the program menu from the keyboard: `Alt` pressed and released alone
 *     opens it (and the open menu owns the arrows), `Alt+D` opens Debug, the
 *     access keys are underlined — the default bindings, nothing planted;
 *   * the user's `keybindings.json`, read by the main process and sent to the
 *     renderer: a user row adds a chord, a `-` row removes the base's, and the
 *     chord the menu shows is the router's; a change to the file on disk takes
 *     effect without a restart, in the keys and in the chords the menu shows.
 *
 * WHAT IS READ: `window.__ctKeyTrace` — every operation the router ran, in
 * order (the desktop's counterpart of the terminal's status line and GPUI's
 * gesture trace) — beside the product's own state (the debugger's location,
 * the DOM). No mocks: the real app, the real `ct`, a real engine.
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

async function editorText(page: any): Promise<string> {
  return page.evaluate(() => {
    const d = (globalThis as any).data;
    const name = d?.services?.editor?.active;
    const ed = name ? d.ui.editors[name] : null;
    return ed?.monacoEditor ? String(ed.monacoEditor.getValue()) : "";
  });
}

test.setTimeout(300_000);

test.describe("PLAT-68: the desktop's keys through the one router", () => {
  test.use({
    sourcePath: recording("calc"),
    launchMode: "trace-folder",
    noUserLayout: true,
    codetracerPrefixOverride: prefix,
  });

  test.beforeAll(() => writeKeybindings(null));

  test("F10 steps ONCE, to the toolbar's Step Over stop", async ({ ctPage }) => {
    await ctPage.waitForSelector(".calltrace-view .call-text", { timeout: 120_000 });
    await caretInEditor(ctPage);
    const start = await where(ctPage);
    await clearTrace(ctPage);
    await ctPage.keyboard.press("F10");
    const byKey = await waitMoved(ctPage, start);
    expect(await keyTrace(ctPage)).toEqual(["debugger.step-over"]);
    expect(byKey.ticks).not.toBe(start.ticks);
    // Back to the entry, then the toolbar's own Step Over: the same stop —
    // one step, not two.
    await ctPage.locator("#run-to-entry-image").click();
    const back = await waitMoved(ctPage, byKey);
    expect(back.ticks).toBe(start.ticks);
    await ctPage.locator("#next-image").click();
    const byButton = await waitMoved(ctPage, back);
    expect(byButton.ticks).toBe(byKey.ticks);
  });

  test("a letter steps in the read-only editor, and types nothing", async ({ ctPage }) => {
    await ctPage.waitForSelector(".calltrace-view .call-text", { timeout: 120_000 });
    await caretInEditor(ctPage);
    const text = await editorText(ctPage);
    const start = await where(ctPage);
    await clearTrace(ctPage);
    await ctPage.keyboard.press("n");
    const moved = await waitMoved(ctPage, start);
    expect(await keyTrace(ctPage)).toEqual(["debugger.step-over"]);
    expect(moved.ticks).not.toBe(start.ticks);
    expect(await editorText(ctPage)).toBe(text);
  });

  test("Enter opens the tracepoint editor on the caret's line", async ({ ctPage }) => {
    await ctPage.waitForSelector(".calltrace-view .call-text", { timeout: 120_000 });
    await caretInEditor(ctPage);
    await clearTrace(ctPage);
    const before = await ctPage.locator(".trace").count();
    await ctPage.keyboard.press("Enter");
    expect(await keyTrace(ctPage)).toEqual(["editor.toggle-tracepoint"]);
    await expect.poll(async () => ctPage.locator(".trace").count(),
                      { timeout: 20_000 }).toBeGreaterThan(before);
  });

  test("Alt+E focuses the Event Log with the caret in the editor", async ({ ctPage }) => {
    await ctPage.waitForSelector(".calltrace-view .call-text", { timeout: 120_000 });
    await caretInEditor(ctPage);
    await clearTrace(ctPage);
    await ctPage.keyboard.press("Alt+KeyE");
    expect(await keyTrace(ctPage)).toEqual(["layout.focus-pane(event-log)"]);
    await ctPage.waitForFunction(() => {
      const a = document.activeElement as HTMLElement | null;
      return !!a && !!a.closest(".eventLog");
    }, undefined, { timeout: 20_000 });
  });

  test("Ctrl+B toggles the side panels; Ctrl+Shift+B is build.run", async ({ ctPage }) => {
    await ctPage.waitForSelector(".calltrace-view .call-text", { timeout: 120_000 });
    await caretInEditor(ctPage);
    const stacks = () => ctPage.locator(".lm_goldenlayout .lm_stack").count();
    // The layout's SHAPE — rows, columns, stacks and their tab titles in
    // order: the second press must put the panels back where and as they
    // were, not merely as many stacks.
    const shape = () => ctPage.evaluate(() => {
      const walk = (el: Element): string => {
        const kids = Array.from(el.children).filter((c) => c.classList.contains("lm_item"));
        if (el.classList.contains("lm_stack")) {
          const tabs = Array.from(el.querySelectorAll(":scope > .lm_header .lm_title"))
            .map((t) => (t.textContent ?? "").trim());
          return `stack[${tabs.join(",")}]`;
        }
        const kind = el.classList.contains("lm_row") ? "row"
          : el.classList.contains("lm_column") ? "column" : "item";
        return `${kind}(${kids.map(walk).join(" ")})`;
      };
      const root = document.querySelector(".lm_goldenlayout > .lm_item");
      return root ? walk(root) : "";
    });
    const before = await stacks();
    const shapeBefore = await shape();
    await clearTrace(ctPage);
    await ctPage.keyboard.press("Control+KeyB");
    await expect.poll(stacks, { timeout: 20_000 }).toBeLessThan(before);
    await ctPage.keyboard.press("Control+KeyB");
    await expect.poll(stacks, { timeout: 20_000 }).toBe(before);
    expect(await shape()).toBe(shapeBefore);
    await ctPage.keyboard.press("Control+Shift+KeyB");
    expect(await keyTrace(ctPage)).toEqual([
      "layout.toggle-side-panels", "layout.toggle-side-panels", "build.run"]);
  });
});

test.describe("PLAT-68: the program menu from the keyboard (CUA-Keymap.md §3.8)", () => {
  test.use({
    sourcePath: recording("calc"),
    launchMode: "trace-folder",
    noUserLayout: true,
    codetracerPrefixOverride: prefix,
  });

  const menuState = (page: any) => page.evaluate(() =>
    JSON.parse((globalThis as any).__ctMenuVM.state()));

  test("Alt pressed and released alone opens the menu; the keys walk it", async ({ ctPage }) => {
    await ctPage.waitForSelector(".calltrace-view .call-text", { timeout: 120_000 });
    await caretInEditor(ctPage);
    await clearTrace(ctPage);
    await ctPage.keyboard.press("Alt");
    expect(await keyTrace(ctPage)).toEqual(["menu.toggle"]);
    await expect.poll(async () => (await menuState(ctPage)).isOpen,
                      { timeout: 10_000 }).toBe(true);
    // Every top-level folder's access key, underlined.
    expect(await ctPage.locator("#menu-elements .ct-menu-mnemonic").allInnerTexts())
      .toEqual(["F", "i", "w", "B", "R", "D", "H"]);
    // The open menu owns the arrows (not the editor under it).
    const before = (await menuState(ctPage)).highlight;
    await ctPage.keyboard.press("ArrowDown");
    expect((await menuState(ctPage)).highlight).not.toBe(before);
    // A second Alt closes it.
    await ctPage.keyboard.press("Alt");
    await expect.poll(async () => (await menuState(ctPage)).isOpen,
                      { timeout: 10_000 }).toBe(false);
  });

  test("Alt+D opens the Debug folder; Alt held through a chord is no tap", async ({ ctPage }) => {
    await ctPage.waitForSelector(".calltrace-view .call-text", { timeout: 120_000 });
    await caretInEditor(ctPage);
    await clearTrace(ctPage);
    await ctPage.keyboard.press("Alt+KeyD");
    expect(await keyTrace(ctPage)).toEqual(["menu.open-folder(debug)"]);
    const state = await menuState(ctPage);
    expect(state.isOpen).toBe(true);
    expect(state.path.length).toBe(1);
    await expect(ctPage.locator("body")).toContainText("Reverse Step Over");
    await ctPage.keyboard.press("Escape");
    await ctPage.keyboard.press("Escape");
    await expect.poll(async () => (await menuState(ctPage)).isOpen,
                      { timeout: 10_000 }).toBe(false);
  });
});

test.describe("PLAT-68: the user's keybindings.json on the desktop", () => {
  test.use({
    sourcePath: recording("calc"),
    launchMode: "trace-folder",
    noUserLayout: true,
    codetracerPrefixOverride: prefix,
  });

  test.beforeAll(() => writeKeybindings(`// a user keymap, JSONC
[
  { "key": "ctrl+alt+n", "command": "debugger.step-over" },
  { "key": "f10", "command": "-debugger.step-over" },
]
`));
  test.afterAll(() => writeKeybindings(null));

  test("a user row adds a chord, a removal takes the base's; the menu shows the router's", async ({ ctPage }) => {
    await ctPage.waitForSelector(".calltrace-view .call-text", { timeout: 120_000 });
    await caretInEditor(ctPage);
    // The file arrives from the main process after start-up.
    await ctPage.waitForFunction(() => {
      const vm = (globalThis as any).__ctMenuVM;
      return !!vm && typeof vm.shortcutFor === "function";
    }, undefined, { timeout: 60_000 }).catch(() => undefined);
    await clearTrace(ctPage);
    const start = await where(ctPage);
    await ctPage.keyboard.press("F10");
    await ctPage.waitForTimeout(1_500);
    expect(await keyTrace(ctPage)).toEqual([]);
    expect((await where(ctPage)).ticks).toBe(start.ticks);
    await ctPage.keyboard.press("Control+Alt+KeyN");
    const moved = await waitMoved(ctPage, start);
    expect(await keyTrace(ctPage)).toEqual(["debugger.step-over"]);
    expect(moved.ticks).not.toBe(start.ticks);
    // The toolbar's Next tooltip names the chord that runs it now.
    await ctPage.locator("#next-image").hover();
    await expect(ctPage.locator("body")).toContainText("Ctrl+Alt+N", { timeout: 20_000 });
  });

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
