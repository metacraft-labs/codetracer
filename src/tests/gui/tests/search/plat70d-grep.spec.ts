/**
 * PLAT-70 Part D: `Ctrl+Shift+F` and `:grep` alone on the desktop
 * (Find-And-Incremental-Search.md §5.2).
 *
 * Verifies, on the real app and a real recording:
 *   - with a word selected in the editor, `Ctrl+Shift+F` reveals the FIND IN
 *     FILES panel and focuses ITS field (not the palette), seeded with the
 *     selection and the whole text selected, so typing replaces it;
 *   - `Enter` in the field runs the search: the rows are the lines an oracle
 *     this spec computes from the program's sources itself (FS-7's result
 *     set, the one the terminal's and GPUI's cases grade against);
 *   - `:grep` alone in the omnibox is `Ctrl+Shift+F`: the palette closes and
 *     the panel's field opens on the editor's selection, selected.
 *
 * No mocks: a `multi_root` recording made by the real Python recorder through
 * `ct record`, opened by the real Electron app.
 */

import * as fs from "node:fs";
import * as path from "node:path";

import { test, expect, codetracerInstallDir } from "../../lib/fixtures";
import { LayoutPage } from "../../page-objects/layout-page";
import { CommandPalette } from "../../page-objects/command-palette/command-palette";

const PROGRAM = "multi_root/app/main.py";

/** Every line of every source of `multi_root` containing `pattern`, any case. */
function oracle(pattern: string): { file: string; line: number }[] {
  const root = path.join(codetracerInstallDir, "test-programs", "multi_root");
  const files: string[] = [];
  const walk = (dir: string) => {
    for (const name of fs.readdirSync(dir).sort()) {
      if (name.startsWith(".")) continue;
      const p = path.join(dir, name);
      const st = fs.lstatSync(p);
      if (st.isDirectory()) walk(p);
      else if (st.isFile() && name.endsWith(".py")) files.push(p);
    }
  };
  walk(root);
  const rows: { file: string; line: number }[] = [];
  for (const f of files) {
    fs.readFileSync(f, "utf8").split("\n").forEach((text, i) => {
      if (text.toLowerCase().includes(pattern.toLowerCase())) {
        rows.push({ file: f, line: i + 1 });
      }
    });
  }
  return rows;
}

/** The active Monaco editor's selected text. */
async function editorSelection(page: any): Promise<string> {
  return page.evaluate(() => {
    const w = globalThis as any;
    const data = w.data;
    const ed =
      data?.ui?.editors?.[data?.services?.editor?.active]?.monacoEditor ??
      w.monaco.editor.getEditors()[0];
    return ed.getModel().getValueInRange(ed.getSelection()) as string;
  });
}

/** The caret placed by a real press on the text of `line`, `column` (as
 *  `plat70c-incremental-find.spec.ts` places it), so the editor takes the
 *  app's focus as a user's click gives it. */
async function placeCaret(page: any, line: number, column: number) {
  await page.waitForFunction(
    () =>
      typeof (globalThis as any).monaco !== "undefined" &&
      (globalThis as any).monaco.editor.getEditors().length > 0,
    { timeout: 60_000 },
  );
  const at = await page.evaluate(
    ([l, c]: number[]) => {
      const w = globalThis as any;
      const data = w.data;
      const ed =
        data?.ui?.editors?.[data?.services?.editor?.active]?.monacoEditor ??
        w.monaco.editor.getEditors()[0];
      ed.revealLineInCenter(l);
      const p = ed.getScrolledVisiblePosition({ lineNumber: l, column: c });
      const r = ed.getDomNode().getBoundingClientRect();
      return { x: r.left + p.left + 2, y: r.top + p.top + p.height / 2 };
    },
    [line, column],
  );
  await page.mouse.click(at.x, at.y);
  await page.waitForTimeout(300);
}

/** The field's value and its selected range, read from the DOM. */
async function fieldState(page: import("@playwright/test").Page) {
  return page.evaluate(() => {
    const el = document.querySelector("#fif-input") as HTMLInputElement | null;
    if (!el) return null;
    return {
      value: el.value,
      start: el.selectionStart,
      end: el.selectionEnd,
      focused: document.activeElement === el,
    };
  });
}

test.describe("Find in Files' field (PLAT-70 Part D)", () => {
  test.setTimeout(240_000);
  test.use({ sourcePath: PROGRAM, launchMode: "trace" });

  test("Ctrl+Shift+F opens the panel's field on the selection; :grep alone too", async ({ ctPage }) => {
    const layout = new LayoutPage(ctPage);
    await layout.waitForBaseComponentsLoaded();
    await layout.waitForTraceLoaded();

    // `scale` selected in the editor: Monaco's find, then `Escape`, which
    // keeps the match selected (OQ-F1).
    // main.py's line 26, `    scaled = extra.scale(total, 4)`: the caret
    // in `scale`; Monaco's widget seeds it, `Enter` selects a match.
    await placeCaret(ctPage, 26, 22);
    await ctPage.keyboard.press("Control+KeyF");
    const widget = ctPage.locator(".monaco-editor .find-widget.visible").first();
    await expect(widget).toBeVisible({ timeout: 20_000 });
    await ctPage.keyboard.press("Enter");
    await ctPage.keyboard.press("Escape");
    await expect.poll(() => editorSelection(ctPage), { timeout: 10_000 })
      .toBe("scale");

    // `Ctrl+Shift+F`: the panel's own field, seeded and selected.
    await ctPage.keyboard.press("Control+Shift+F");
    const panel = ctPage.locator(".search-results:visible").first();
    await expect(panel, "Ctrl+Shift+F reveals the panel").toBeVisible({ timeout: 20_000 });
    await expect.poll(async () => (await fieldState(ctPage))?.focused,
      { message: "the panel's field has the focus", timeout: 10_000 }).toBe(true);
    await expect.poll(async () => (await fieldState(ctPage))?.value,
      { message: "the field holds the editor's selection", timeout: 10_000 }).toBe("scale");
    await expect.poll(async () => {
      const f = await fieldState(ctPage);
      return [f?.start, f?.end];
    }, { message: "the field's text is selected", timeout: 10_000 }).toEqual([0, 5]);
    // The palette did not open on `:grep `.
    await expect(ctPage.locator("#command-query-text")).toHaveValue("");

    // Typing replaces the seed; `Enter` runs the search.
    await ctPage.keyboard.type("factor");
    await expect(panel.locator("#fif-input")).toHaveValue("factor");
    await ctPage.keyboard.press("Enter");
    const expected = oracle("factor");
    expect(expected.length).toBeGreaterThanOrEqual(2);
    const rows = panel.locator(".search-results-match-row");
    await expect(rows).toHaveCount(expected.length, { timeout: 30_000 });
    for (let i = 0; i < expected.length; i++) {
      await expect(rows.nth(i).locator(".fif-line-number")).toHaveText(`${expected[i].line}`);
    }

    // `:grep` alone in the omnibox: the palette closes and the field opens
    // on the editor's selection (still `scale`), selected.
    const palette = new CommandPalette(ctPage);
    await palette.open();
    const input = ctPage.locator("#command-query-text");
    await input.fill(":grep");
    await input.press("Enter");
    await expect(ctPage.locator(".command-container")).toHaveClass(/hidden/,
      { timeout: 10_000 });
    await expect.poll(() => fieldState(ctPage),
      { message: "`:grep` alone opens the field on the selection, selected", timeout: 10_000 })
      .toEqual({ value: "scale", start: 0, end: 5, focused: true });
    // Nothing was searched: the rows are still `factor`'s.
    await expect(rows).toHaveCount(expected.length);
  });
});
