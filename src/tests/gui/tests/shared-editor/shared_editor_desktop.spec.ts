/**
 * The shared editor on the desktop (the `sharedEditor` developer setting):
 * the editor pane, the setting's switch, and the shared key router reaching
 * the editing core. Real app, real `replay-server`, real recording or a real
 * project folder; trusted input; no mocks.
 *
 *   * the setting picks the editor at launch (`CODETRACER_SHARED_EDITOR`),
 *     and the palette's "Developer: Toggle Shared Editor" switches a running
 *     window — Monaco and back — keeping the caret's line;
 *   * in Debug mode the stepping keys still reach the debugger, the arrows
 *     move the shared editor's caret, and typing changes nothing (read-only);
 *   * the right-click menu is the CodeTracer menu;
 *   * in Edit mode the keys are the document's: CUA typing and Ctrl+S
 *     saving the file to disk, and the Vim and Kakoune keymaps' modes, which
 *     Monaco cannot run (the palette's `:Keymap: <base>`).
 */
import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";
import { expect, test } from "../../lib/fixtures";
import { activeEditorIsShared, editorReady } from "../../lib/editor-differential";
import { CommandPalette } from "../../page-objects/command-palette/command-palette";
import { ContextMenu } from "../../page-objects/components/context-menu";
import { originFixturePath, pythonSpecSkipReason } from "../../lib/value-origin-fixtures";

type Page = import("@playwright/test").Page;

const caret = (page: Page) => page.evaluate(() => {
  const d = (globalThis as any).data;
  const p = d.ui.editors[d.services.editor.active].monacoEditor.getPosition();
  return { line: p.lineNumber as number, column: p.column as number };
});

const textOf = (page: Page) => page.evaluate(() => {
  const d = (globalThis as any).data;
  return d.ui.editors[d.services.editor.active].monacoEditor.getValue() as string;
});

const executionLine = (page: Page) => page.evaluate(() => {
  const loc = (globalThis as any).data?.services?.debugger?.location;
  return { line: loc?.line ?? -1, ticks: Number(loc?.rrTicks ?? -1) };
});

const mode = (page: Page) => page.evaluate(() => {
  const d = (globalThis as any).data;
  const root = d.ui.editors[d.services.editor.active].monacoEditor.getDomNode();
  return root?.getAttribute("data-ct-mode") ?? "";
});

async function clickLine(page: Page, line: number, column: number) {
  const p = await page.evaluate(({ line, column }) => {
    const d = (globalThis as any).data;
    const e = d.ui.editors[d.services.editor.active].monacoEditor;
    e.revealLineInCenterIfOutsideViewport(line);
    const box = e.getDomNode().getBoundingClientRect();
    const v = e.getScrolledVisiblePosition({ lineNumber: line, column });
    return { x: box.left + v.left + 2, y: box.top + v.top + v.height / 2 };
  }, { line, column });
  await page.mouse.click(p.x, p.y);
  await page.waitForTimeout(400);
}

test.describe("Debug mode, the shared editor", () => {
  test.setTimeout(300_000);
  test.use({ sourcePath: originFixturePath("python", "simple_trivial_chain"),
             launchMode: "trace", launchEnv: { CODETRACER_SHARED_EDITOR: "1" } });
  test.beforeAll(() => {
    const reason = pythonSpecSkipReason();
    test.skip(reason !== null, reason ?? "");
  });

  test("the setting draws the shared editor, and the palette switches a running window",
    async ({ ctPage: page }) => {
      await editorReady(page);
      expect(await activeEditorIsShared(page)).toBe(true);
      await clickLine(page, 10, 5);
      const before = await caret(page);
      expect(before.line).toBe(10);
      const palette = new CommandPalette(page);
      await palette.executeCommand("Developer: Toggle Shared Editor");
      await expect.poll(() => activeEditorIsShared(page), { timeout: 20_000 }).toBe(false);
      await editorReady(page);
      expect((await caret(page)).line).toBe(10);
      await palette.executeCommand("Developer: Toggle Shared Editor");
      await expect.poll(() => activeEditorIsShared(page), { timeout: 20_000 }).toBe(true);
      await editorReady(page);
      expect((await caret(page)).line).toBe(10);
    });

  test("stepping keys reach the debugger; the arrows move the caret; typing changes nothing",
    async ({ ctPage: page }) => {
      await editorReady(page);
      await clickLine(page, 9, 5);
      const start = await executionLine(page);
      await page.keyboard.press("F10");
      await expect.poll(async () => (await executionLine(page)).ticks,
                        { timeout: 60_000 }).not.toBe(start.ticks);
      await clickLine(page, 9, 5);
      await page.keyboard.press("ArrowDown");
      expect((await caret(page)).line).toBe(10);
      const text = await textOf(page);
      await page.keyboard.type("zz");
      expect(await textOf(page)).toBe(text);
    });

  test("the right-click menu is CodeTracer's", async ({ ctPage: page }) => {
    await editorReady(page);
    const line = page.locator(".monaco-editor[data-ct-shared-editor] .view-line").nth(2);
    await expect(line).toBeVisible({ timeout: 30_000 });
    const box = await line.boundingBox();
    expect(box).not.toBeNull();
    await page.mouse.click(box!.x + 20, box!.y + box!.height / 2, { button: "right" });
    const menu = new ContextMenu(page);
    await menu.waitForVisible();
    const names = await page.evaluate(() => Array.from(
      document.querySelectorAll("#context-menu-container .context-menu-item"))
      .map((r) => (r.textContent ?? "").trim()));
    expect(names.some((n) => n.startsWith("Jump to line"))).toBe(true);
  });
});

test.describe("Edit mode, the shared editor", () => {
  test.setTimeout(300_000);
  const folder = fs.mkdtempSync(path.join(os.tmpdir(), "shared-editor-edit-"));
  const file = path.join(folder, "main.py");
  fs.writeFileSync(file, "answer = 42\nprint(answer)\nthird = 3\n");
  test.use({ launchMode: "edit", editFolderPath: folder,
             launchEnv: { CODETRACER_SHARED_EDITOR: "1" } });
  test.afterAll(() => fs.rmSync(folder, { recursive: true, force: true }));

  test("CUA: typing goes into the document and Ctrl+S writes the file",
    async ({ ctPage: page }) => {
      await editorReady(page);
      expect(await activeEditorIsShared(page)).toBe(true);
      await clickLine(page, 1, 1);
      // One keystroke, so one undo step whatever the machine's load: two
      // keystrokes more than the history's 500 ms apart are two steps, as
      // in Monaco and CodeMirror.
      await page.keyboard.type("#");
      expect((await textOf(page)).startsWith("#answer = 42")).toBe(true);
      await page.keyboard.press("Control+KeyZ");
      expect((await textOf(page)).startsWith("answer = 42")).toBe(true);
      await page.keyboard.type("x");
      await page.keyboard.press("Control+KeyS");
      await expect.poll(() => fs.readFileSync(file, "utf8"), { timeout: 20_000 })
        .toBe("xanswer = 42\nprint(answer)\nthird = 3\n");
    });

  test("Vim on the desktop: normal-mode motions, insert, Escape", async ({ ctPage: page }) => {
    await editorReady(page);
    const palette = new CommandPalette(page);
    await palette.executeCommand("Keymap: Vim");
    await expect.poll(() => page.evaluate(() => {
      const d = (globalThis as any).data;
      return d.ui.editors[d.services.editor.active].monacoEditor.getDomNode()
        .getAttribute("data-ct-keymap");
    })).toBe("vim");
    await clickLine(page, 1, 1);
    await expect.poll(() => mode(page), { timeout: 10_000 }).toBe("normal");
    await page.keyboard.press("j");
    expect((await caret(page)).line).toBe(2);
    await page.keyboard.press("i");
    await expect.poll(() => mode(page)).toBe("insert");
    await page.keyboard.type("v");
    await page.keyboard.press("Escape");
    await expect.poll(() => mode(page)).toBe("normal");
    expect((await textOf(page)).split("\n")[1].startsWith("vprint")).toBe(true);
    await page.keyboard.press("d");
    await page.keyboard.press("d");
    expect((await textOf(page)).includes("print(answer)")).toBe(false);
    await palette.executeCommand("Keymap: CUA");
  });

  test("Kakoune on the desktop: select then act", async ({ ctPage: page }) => {
    await editorReady(page);
    const palette = new CommandPalette(page);
    await palette.executeCommand("Keymap: Kakoune");
    await expect.poll(() => page.evaluate(() => {
      const d = (globalThis as any).data;
      return d.ui.editors[d.services.editor.active].monacoEditor.getDomNode()
        .getAttribute("data-ct-keymap");
    })).toBe("kakoune");
    await clickLine(page, 3, 1);
    await expect.poll(() => mode(page), { timeout: 10_000 }).toBe("normal");
    await page.keyboard.press("w");
    const selected = await page.evaluate(() => {
      const d = (globalThis as any).data;
      const e = d.ui.editors[d.services.editor.active].monacoEditor;
      return e.getModel().getValueInRange(e.getSelection()) as string;
    });
    expect(selected.length).toBeGreaterThan(0);
    await page.keyboard.press("d");
    expect((await textOf(page)).includes("third")).toBe(false);
    // Kakoune's own Ctrl+P (extend-jump-back) is the editor's while it has
    // the keys, as in the terminal; the palette is reached from outside it.
    await page.evaluate(() => (document.activeElement as HTMLElement | null)?.blur());
    await palette.executeCommand("Keymap: CUA");
  });
});
