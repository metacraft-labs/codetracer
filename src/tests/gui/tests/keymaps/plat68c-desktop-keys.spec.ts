/**
 * plat68c-desktop-keys.spec.ts — the desktop's half of the base-keymap
 * milestone's real-stack boxes, through REAL KeyboardEvents into the real
 * Electron front-end, on a real recording with a real `replay-server`:
 *
 *   * the stepping F-keys (`F10`, `Shift+F10`, `F11`, `Shift+F11`,
 *     CUA-Keymap.md §3.9) dispatch ONCE each, with the caret in the editor
 *     AND with the focus outside it — each a single router operation, and the
 *     reverse step lands back where the forward one started (a key run twice
 *     would not);
 *   * a user row rebinding `debugger.step-over` (and `F10` removed) works,
 *     and EVERY surface that shows its chord shows the new one: the Debug
 *     menu item, the toolbar's tooltip, the shortcuts dialog's stepping rows
 *     and its shortcut reference;
 *   * the letters under CUA (OQ-1): in the read-only editor `n` steps and `p`
 *     steps back; with the call trace focused `n` steps; `Ctrl+E` makes the
 *     editor writable and `n` then types an `n` and the debugger stays;
 *     `Ctrl+E` again and `n` steps; in Monaco's find field `n` is typed into
 *     the query;
 *   * VS Code's precedence through input (Base-Keymaps §5.1, KL-11): a user
 *     `Enter` with no `when` takes `Enter` from the call trace's base row,
 *     and the shortcut reference lists the base row as shadowed by it; two
 *     user rows for one chord — the later fires, and swapping their order in
 *     the file swaps the result;
 *   * the layer stack through input: the find widget stays open when
 *     `Escape` is pressed in the call trace, and closes when it is pressed
 *     back in the editor; a `Ctrl+K` prefix waits past 1000 ms under CUA;
 *   * a key inert in this product mode says so (Mode-Transitions.md §8.1):
 *     `F12` in Edit mode puts the reason on the status bar.
 *
 * WHAT IS READ: `window.__ctKeyTrace` (every operation the router ran, in
 * order), `window.__ctInertNotes`, the debugger's location and the DOM.
 *
 * THE ONE STAND-IN: in the layer-stack case the focus is moved to the call
 * trace with the product's own `focusCalltrace` — the function `Alt+C`
 * (`layout.focus-pane(call-trace)`) runs — because while the find widget is
 * open `Alt+C` is the widget's own toggle-case key (CUA-Keymap.md §3.5), so
 * no key can move the focus there without closing or changing the find. It
 * is not a mock: the real function, on the real layout. No mocks otherwise:
 * the real app, the real `ct`, a real engine, a real `keybindings.json`.
 */

import * as fs from "fs";
import * as os from "os";
import * as path from "path";
import { ctUserConfigDir } from "../../lib/ct-home";

import { expect } from "@playwright/test";
import { test } from "../../lib/fixtures";

const repoRoot = path.resolve(__dirname, "..", "..", "..", "..", "..");
const prefix = process.env.PLAT68_DESKTOP_PREFIX ?? "";

function recording(prefixName: string): string {
  const cache = process.env.PLAT68_FIXTURES_DIR ??
    path.join(repoRoot, "test-logs", "tui-fixtures");
  const hits = fs.existsSync(cache)
    ? fs.readdirSync(cache).filter((e) => e.startsWith(prefixName + "-")).sort()
    : [];
  if (hits.length === 0) {
    throw new Error(
      `the '${prefixName}' recording is not in test-logs/tui-fixtures/; ` +
        "run the tui lane once (its fixture provider records it).",
    );
  }
  return path.join(cache, hits[hits.length - 1]);
}

const keybindingsFile = () =>
  process.env.CODETRACER_KEYBINDINGS ?? path.join(ctUserConfigDir(), "keybindings.json");

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

async function settle(page: any) {
  // A second dispatch of the same key would land after the first: give it
  // the time to.
  await page.waitForTimeout(1_500);
  return where(page);
}

async function waitMoved(page: any, from: { ticks: number }) {
  const deadline = Date.now() + 60_000;
  let now = await where(page);
  while (Date.now() < deadline && now.ticks === from.ticks) {
    await page.waitForTimeout(200);
    now = await where(page);
  }
  return settle(page);
}

async function waitAt(page: any, ticks: number) {
  const deadline = Date.now() + 60_000;
  let now = await where(page);
  while (Date.now() < deadline && now.ticks !== ticks) {
    await page.waitForTimeout(200);
    now = await where(page);
  }
  return settle(page);
}

async function keyTrace(page: any): Promise<string[]> {
  return page.evaluate(() => ((globalThis as any).__ctKeyTrace ?? []).slice());
}

async function clearTrace(page: any) {
  await page.evaluate(() => { (globalThis as any).__ctKeyTrace = []; });
}

async function ready(page: any) {
  await page.waitForSelector(".calltrace-view .call-text", { timeout: 120_000 });
}

async function caretInEditor(page: any) {
  // As plat68b-desktop-keys.spec.ts: a real click on a point the editor
  // shows, just inside a line's intersection with the content area.
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

async function focusOutside(page: any) {
  // Nothing focused below the window: the scope path is the window alone.
  await page.evaluate(() => (document.activeElement as HTMLElement | null)?.blur());
  await page.waitForFunction(() => document.activeElement === document.body,
                             undefined, { timeout: 10_000 });
}

async function focusCallTrace(page: any) {
  // `Alt+C` — CUA's `layout.focus-pane(call-trace)`, through the router.
  await clearTrace(page);
  await page.keyboard.press("Alt+KeyC");
  expect(await keyTrace(page)).toEqual(["layout.focus-pane(call-trace)"]);
  await page.waitForFunction(() => {
    const a = document.activeElement as HTMLElement | null;
    return !!a && !!a.closest("[data-scope-kind='pane'][data-scope-id='calltrace']");
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

async function editorReadOnly(page: any): Promise<boolean> {
  return page.evaluate(() => {
    const d = (globalThis as any).data;
    const name = d?.services?.editor?.active;
    const ed = name ? d.ui.editors[name] : null;
    const m = (globalThis as any).monaco;
    if (!ed?.monacoEditor || !m) return true;
    return !!ed.monacoEditor.getOption(m.editor.EditorOption.readOnly);
  });
}

async function openShortcutsDialog(page: any) {
  await clearTrace(page);
  await page.keyboard.press("Control+KeyK");
  await page.keyboard.press("Control+KeyS");
  await page.waitForSelector("#keyboard-shortcuts-dialog", { timeout: 20_000 });
  expect(await keyTrace(page)).toEqual(["help.keyboard-shortcuts"]);
}

async function closeShortcutsDialog(page: any) {
  await page.locator("#keyboard-shortcuts-dialog [data-kb-close]").click();
  await expect(page.locator("#keyboard-shortcuts-dialog")).toHaveCount(0);
}

test.setTimeout(400_000);

test.describe("the stepping F-keys dispatch once, in the editor and outside it", () => {
  test.use({
    sourcePath: recording("calc"),
    launchMode: "trace-folder",
    codetracerPrefixOverride: prefix,
  });
  test.beforeAll(() => writeKeybindings(null));

  for (const focus of ["the caret in the editor", "the focus outside the editor"]) {
    test(`F10 / Shift+F10 / F11 / Shift+F11 with ${focus}`, async ({ ctPage }) => {
      await ready(ctPage);
      const place = async () => {
        if (focus.startsWith("the caret")) await caretInEditor(ctPage);
        else await focusOutside(ctPage);
      };
      await place();
      const start = await where(ctPage);
      for (const [forward, reverse, fOp, rOp] of [
        ["F10", "Shift+F10", "debugger.step-over", "debugger.reverse-step-over"],
        ["F11", "Shift+F11", "debugger.step-into", "debugger.reverse-step-into"],
      ]) {
        await place();
        await clearTrace(ctPage);
        await ctPage.keyboard.press(forward);
        const moved = await waitMoved(ctPage, start);
        expect(await keyTrace(ctPage), forward).toEqual([fOp]);
        expect(moved.ticks, forward).not.toBe(start.ticks);
        await place();
        await clearTrace(ctPage);
        await ctPage.keyboard.press(reverse);
        const back = await waitAt(ctPage, start.ticks);
        expect(await keyTrace(ctPage), reverse).toEqual([rOp]);
        // ONE forward step undone by ONE reverse step: the start again.
        expect(back.ticks, reverse).toBe(start.ticks);
      }
    });
  }
});

test.describe("a rebound step-over: the keys and every surface that shows its chord", () => {
  test.use({
    sourcePath: recording("calc"),
    launchMode: "trace-folder",
    codetracerPrefixOverride: prefix,
  });
  test.beforeAll(() => writeKeybindings(`[
  { "key": "ctrl+alt+n", "command": "debugger.step-over" },
  { "key": "f10", "command": "-debugger.step-over" },
]`));
  test.afterAll(() => writeKeybindings(null));

  test("Ctrl+Alt+N steps, F10 does not, and the menu, tooltip and dialog say Ctrl+Alt+N", async ({ ctPage }) => {
    await ready(ctPage);
    await caretInEditor(ctPage);
    // The file arrives from the main process after start-up.
    await ctPage.waitForTimeout(2_500);
    await caretInEditor(ctPage);
    const start = await where(ctPage);
    await clearTrace(ctPage);
    await ctPage.keyboard.press("F10");
    expect((await settle(ctPage)).ticks).toBe(start.ticks);
    expect(await keyTrace(ctPage)).toEqual([]);
    await ctPage.keyboard.press("Control+Alt+KeyN");
    const moved = await waitMoved(ctPage, start);
    expect(await keyTrace(ctPage)).toEqual(["debugger.step-over"]);
    expect(moved.ticks).not.toBe(start.ticks);

    // 1. The Debug menu item.
    await ctPage.evaluate(() => (globalThis as any).__ctMenuVM.open());
    await ctPage.locator("#menu-elements").getByText("Debug", { exact: true }).first()
      .click({ force: true });
    await expect.poll(() => ctPage.evaluate(() => document.body.innerText),
                      { timeout: 20_000 }).toContain("\nStep Over\nCtrl+Alt+N\n");
    expect(await ctPage.evaluate(() => document.body.innerText))
      .not.toContain("\nStep Over\nF10\n");
    await ctPage.evaluate(() => (globalThis as any).__ctMenuVM.close());

    // 2. The toolbar's tooltip.
    await ctPage.locator("#next-image").hover();
    await expect(ctPage.locator("body")).toContainText("Ctrl+Alt+N", { timeout: 20_000 });
    await ctPage.mouse.move(0, 0);

    // 3. The shortcuts dialog: its stepping row, and the reference.
    await caretInEditor(ctPage);
    await openShortcutsDialog(ctPage);
    const dialog = ctPage.locator("#keyboard-shortcuts-dialog");
    await expect(dialog.locator("[data-kb-action='forwardNext'] .kb-chord"))
      .toHaveText("Ctrl+Alt+N");
    const userRow = dialog.locator(
      "[data-kb-ref-operation='debugger.step-over'][data-kb-ref-layer^='user:']");
    await expect(userRow).toHaveCount(1);
    await expect(userRow).toHaveAttribute("data-kb-ref-key", /ctrl\+alt\+n|Ctrl\+Alt\+N/);
    // The removed base row is not live here, so it is not listed.
    await expect(dialog.locator(
      "[data-kb-ref-operation='debugger.step-over'][data-kb-ref-key='F10']"))
      .toHaveCount(0);
    await closeShortcutsDialog(ctPage);
  });
});

test.describe("the letters under CUA (OQ-1)", () => {
  test.use({
    sourcePath: recording("calc"),
    launchMode: "trace-folder",
    codetracerPrefixOverride: prefix,
  });
  test.beforeAll(() => writeKeybindings(null));

  test("n / p in the read-only editor, n in the call trace, typed once writable, typed in find", async ({ ctPage }) => {
    await ready(ctPage);
    await caretInEditor(ctPage);
    const text = await editorText(ctPage);
    const start = await where(ctPage);

    // Read-only editor: n steps, p steps back.
    await clearTrace(ctPage);
    await ctPage.keyboard.press("n");
    const stepped = await waitMoved(ctPage, start);
    expect(await keyTrace(ctPage)).toEqual(["debugger.step-over"]);
    expect(stepped.ticks).not.toBe(start.ticks);
    await caretInEditor(ctPage);
    await clearTrace(ctPage);
    await ctPage.keyboard.press("p");
    expect((await waitAt(ctPage, start.ticks)).ticks).toBe(start.ticks);
    expect(await keyTrace(ctPage)).toEqual(["debugger.reverse-step-over"]);
    expect(await editorText(ctPage)).toBe(text);

    // A list pane: n steps.
    await focusCallTrace(ctPage);
    await clearTrace(ctPage);
    const inList = await where(ctPage);
    await ctPage.keyboard.press("n");
    const listStepped = await waitMoved(ctPage, inList);
    expect(await keyTrace(ctPage)).toEqual(["debugger.step-over"]);
    expect(listStepped.ticks).not.toBe(inList.ticks);

    // Ctrl+E: the editor is writable, and n is a character.
    await caretInEditor(ctPage);
    await clearTrace(ctPage);
    await ctPage.keyboard.press("Control+KeyE");
    expect(await keyTrace(ctPage)).toEqual(["editor.toggle-read-only"]);
    await expect.poll(() => editorReadOnly(ctPage), { timeout: 20_000 }).toBe(false);
    await caretInEditor(ctPage);
    const before = await where(ctPage);
    const written = await editorText(ctPage);
    await clearTrace(ctPage);
    await ctPage.keyboard.press("n");
    expect((await settle(ctPage)).ticks).toBe(before.ticks);
    expect(await keyTrace(ctPage)).toEqual([]);
    await expect.poll(() => editorText(ctPage), { timeout: 10_000 })
      .toHaveLength(written.length + 1);

    // Ctrl+E again: read-only, and n steps again.
    await clearTrace(ctPage);
    await ctPage.keyboard.press("Control+KeyE");
    await expect.poll(() => editorReadOnly(ctPage), { timeout: 20_000 }).toBe(true);
    await caretInEditor(ctPage);
    await clearTrace(ctPage);
    await ctPage.keyboard.press("n");
    const again = await waitMoved(ctPage, before);
    expect(await keyTrace(ctPage)).toEqual(["debugger.step-over"]);
    expect(again.ticks).not.toBe(before.ticks);

    // Monaco's find field: n is typed into the query, nothing steps.
    await caretInEditor(ctPage);
    await clearTrace(ctPage);
    await ctPage.keyboard.press("Control+KeyF");
    await ctPage.waitForSelector(".monaco-editor .find-widget.visible", { timeout: 20_000 });
    const inFind = await where(ctPage);
    await clearTrace(ctPage);
    await ctPage.keyboard.press("n");
    expect((await settle(ctPage)).ticks).toBe(inFind.ticks);
    expect(await keyTrace(ctPage)).toEqual([]);
    expect(await ctPage.evaluate(() =>
      (document.activeElement as HTMLTextAreaElement | null)?.value ?? "")).toContain("n");
  });
});

test.describe("VS Code's precedence, through input", () => {
  test.use({
    sourcePath: recording("calc"),
    launchMode: "trace-folder",
    codetracerPrefixOverride: prefix,
  });
  test.afterAll(() => writeKeybindings(null));

  test.describe("a user Enter with no when", () => {
    test.beforeAll(() => writeKeybindings(
      `[ { "key": "enter", "command": "debugger.step-over" } ]`));

    test("takes Enter from the call trace's base row; the reference lists the shadow", async ({ ctPage }) => {
      await ready(ctPage);
      await ctPage.waitForTimeout(2_500);
      await focusCallTrace(ctPage);
      const start = await where(ctPage);
      await clearTrace(ctPage);
      await ctPage.keyboard.press("Enter");
      const moved = await waitMoved(ctPage, start);
      expect(await keyTrace(ctPage)).toEqual(["debugger.step-over"]);
      expect(moved.ticks).not.toBe(start.ticks);
      await focusCallTrace(ctPage);
      await openShortcutsDialog(ctPage);
      const dialog = ctPage.locator("#keyboard-shortcuts-dialog");
      await expect(dialog.locator(".kb-reference")).toHaveAttribute("data-kb-scope", /calltrace/);
      const shadowed = dialog.locator(
        "[data-kb-ref-key='Enter'][data-kb-ref-operation='list.activate']");
      await expect(shadowed).toHaveCount(1);
      await expect(shadowed).toHaveAttribute("data-kb-ref-shadowed-by", "your row 1");
      await expect(shadowed).toContainText("shadowed by your row 1");
      await closeShortcutsDialog(ctPage);
    });
  });

  test.describe("two user rows for one chord", () => {
    test.beforeAll(() => writeKeybindings(`[
  { "key": "ctrl+alt+j", "command": "debugger.step-over" },
  { "key": "ctrl+alt+j", "command": "debugger.step-into" },
]`));

    test("the later fires, and swapping their order swaps the result", async ({ ctPage }) => {
      await ready(ctPage);
      await ctPage.waitForTimeout(2_500);
      await caretInEditor(ctPage);
      await clearTrace(ctPage);
      await ctPage.keyboard.press("Control+Alt+KeyJ");
      await settle(ctPage);
      expect(await keyTrace(ctPage)).toEqual(["debugger.step-into"]);
      writeKeybindings(`[
  { "key": "ctrl+alt+j", "command": "debugger.step-into" },
  { "key": "ctrl+alt+j", "command": "debugger.step-over" },
]`);
      // fs.watchFile polls every 500 ms; the renderer re-keys on arrival.
      await ctPage.waitForTimeout(2_500);
      await caretInEditor(ctPage);
      await clearTrace(ctPage);
      await ctPage.keyboard.press("Control+Alt+KeyJ");
      await settle(ctPage);
      expect(await keyTrace(ctPage)).toEqual(["debugger.step-over"]);
    });
  });
});

test.describe("the layer stack, through input", () => {
  test.use({
    sourcePath: recording("calc"),
    launchMode: "trace-folder",
    codetracerPrefixOverride: prefix,
  });
  test.beforeAll(() => writeKeybindings(null));

  test("Escape in the call trace leaves find open; back in the editor it closes find", async ({ ctPage }) => {
    await ready(ctPage);
    await caretInEditor(ctPage);
    await ctPage.keyboard.press("Control+KeyF");
    const find = ctPage.locator(".monaco-editor .find-widget.visible");
    await expect(find).toHaveCount(1, { timeout: 20_000 });
    // The stand-in (see the header): the function Alt+C runs.
    await ctPage.evaluate(() => {
      const d = (globalThis as any).data;
      d.functions.focusCalltrace(d);
    });
    await ctPage.waitForFunction(() => {
      const a = document.activeElement as HTMLElement | null;
      return !!a && !!a.closest("[data-scope-kind='pane'][data-scope-id='calltrace']");
    }, undefined, { timeout: 20_000 });
    await ctPage.keyboard.press("Escape");
    await ctPage.waitForTimeout(500);
    await expect(find).toHaveCount(1);
    // Back in the editor (`Alt+V`, `layout.focus-pane(editor)`): Escape
    // closes it.
    await clearTrace(ctPage);
    await ctPage.keyboard.press("Alt+KeyV");
    expect(await keyTrace(ctPage)).toEqual(["layout.focus-pane(editor)"]);
    await ctPage.waitForFunction(() => {
      const a = document.activeElement as HTMLElement | null;
      return !!a && !!a.closest("[data-scope-kind='editor']");
    }, undefined, { timeout: 20_000 });
    await ctPage.keyboard.press("Escape");
    await expect(find).toHaveCount(0, { timeout: 10_000 });
  });

  test("a Ctrl+K prefix waits past 1000 ms under CUA", async ({ ctPage }) => {
    await ready(ctPage);
    await caretInEditor(ctPage);
    await clearTrace(ctPage);
    await ctPage.keyboard.press("Control+KeyK");
    await ctPage.waitForTimeout(1_600);
    await ctPage.keyboard.press("Control+KeyS");
    await ctPage.waitForSelector("#keyboard-shortcuts-dialog", { timeout: 20_000 });
    expect(await keyTrace(ctPage)).toEqual(["help.keyboard-shortcuts"]);
    await closeShortcutsDialog(ctPage);
  });
});

test.describe("a key inert in this product mode says so (Mode-Transitions.md §8.1)", () => {
  const folder = fs.mkdtempSync(path.join(os.tmpdir(), "plat68c-edit-"));
  fs.writeFileSync(path.join(folder, "main.py"), "answer = 42\nprint(answer)\n");
  test.use({
    launchMode: "edit",
    editFolderPath: folder,
    codetracerPrefixOverride: prefix,
  });
  test.beforeAll(() => writeKeybindings(null));
  test.afterAll(() => fs.rmSync(folder, { recursive: true, force: true }));

  test("F12 in Edit mode puts its reason on the status bar", async ({ ctPage }) => {
    await ctPage.waitForSelector(".monaco-editor .view-line", { timeout: 120_000 });
    await ctPage.locator(".monaco-editor .view-line").first().click();
    await clearTrace(ctPage);
    await ctPage.evaluate(() => { (globalThis as any).__ctInertNotes = []; });
    await ctPage.keyboard.press("F12");
    const notes = () => ctPage.evaluate(() =>
      ((globalThis as any).__ctInertNotes ?? []).slice() as string[]);
    await expect.poll(notes, { timeout: 10_000 }).toHaveLength(1);
    const note = (await notes())[0];
    expect(note).toContain("needs a replay session");
    expect(await keyTrace(ctPage)).toEqual([]);
    await expect(ctPage.locator("body")).toContainText("needs a replay session",
                                                       { timeout: 10_000 });
  });
});
