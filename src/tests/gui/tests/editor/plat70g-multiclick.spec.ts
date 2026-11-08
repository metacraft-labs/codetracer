/**
 * Multi-click selection, the glyph column, Alt+click and Shift+F9 on the desktop
 * (Editor-Pane.md MC.1 – MC.7, § Inline breakpoints), read back from Monaco on the
 * real app, a real `replay-server` and a real recording. No mocks.
 */
import { expect, test } from "../../lib/fixtures";
import { glyphCentre, glyphMarksOn, placeCaret, pressGlyph } from "../../lib/glyph-column";
import { originFixturePath, pythonSpecSkipReason } from "../../lib/value-origin-fixtures";

test.use({ sourcePath: originFixturePath("python", "simple_trivial_chain"), launchMode: "trace" });
test.setTimeout(240_000);

test.beforeAll(() => {
  const reason = pythonSpecSkipReason();
  test.skip(reason !== null, reason ?? "");
});

type Page = import("@playwright/test").Page;

async function editorReady(page: Page): Promise<void> {
  await page.waitForSelector(".monaco-editor .view-line", { timeout: 120_000 });
  await page.waitForFunction(() => {
    const d = (globalThis as any).data;
    return !!d?.ui?.editors?.[d?.services?.editor?.active]?.monacoEditor?.getModel?.();
  }, undefined, { timeout: 60_000 });
}

const selections = (page: Page) => page.evaluate(() => {
  const d = (globalThis as any).data;
  const e = d.ui.editors[d.services.editor.active].monacoEditor;
  return e.getSelections().map((s: any) => e.getModel().getValueInRange(s) as string);
});

const breakpointCount = (page: Page) => page.evaluate(() => {
  const w = globalThis as any;
  return (w.ctBreakpointRows ? w.ctBreakpointRows() : []).length as number;
});

/** A window position inside `line`'s text at `column`. */
const textAt = (page: Page, line: number, column: number) => page.evaluate(({ line, column }) => {
  const d = (globalThis as any).data;
  const e = d.ui.editors[d.services.editor.active].monacoEditor;
  e.revealLineInCenterIfOutsideViewport(line);
  const box = e.getDomNode().getBoundingClientRect();
  const v = e.getScrolledVisiblePosition({ lineNumber: line, column });
  return { x: box.left + v.left + 2, y: box.top + v.top + v.height / 2 };
}, { line, column });

const numberAt = async (page: Page, line: number) => {
  const box = await page.evaluate(() => {
    const d = (globalThis as any).data;
    const e = d.ui.editors[d.services.editor.active].monacoEditor;
    const l = e.getLayoutInfo();
    return { x: e.getDomNode().getBoundingClientRect().left + l.lineNumbersLeft + l.lineNumbersWidth / 2 };
  });
  const g = await glyphCentre(page, line);
  return { x: box.x, y: g.y };
};

const targetType = (page: Page) => page.evaluate(() => (globalThis as any).__ct70gTarget as number);
const watchTarget = (page: Page) => page.evaluate(() => {
  const d = (globalThis as any).data;
  const e = d.ui.editors[d.services.editor.active].monacoEditor;
  e.onMouseDown((ev: any) => { (globalThis as any).__ct70gTarget = ev.target.type; });
});

const longestWordLine = (page: Page) => page.evaluate(() => {
  const d = (globalThis as any).data;
  const m = d.ui.editors[d.services.editor.active].monacoEditor.getModel();
  for (let i = 1; i <= m.getLineCount(); i++) {
    if (/^[a-z_]{3,}/.test(m.getLineContent(i).trim()) && m.getLineContent(i).length > 8) return i;
  }
  return 1;
});

test("each count selects its unit, read-only", async ({ ctPage: page }) => {
  await editorReady(page);
  const line = await longestWordLine(page);
  const p = await textAt(page, line, 3);
  await page.mouse.click(p.x, p.y);
  expect(await selections(page)).toEqual([""]);
  await page.waitForTimeout(500);
  await page.mouse.click(p.x, p.y, { clickCount: 2 });
  const word = (await selections(page))[0];
  expect(word.length).toBeGreaterThan(0);
  expect(word).not.toContain(" ");
  await page.waitForTimeout(500);
  await page.mouse.click(p.x, p.y, { clickCount: 3 });
  expect((await selections(page))[0].endsWith("\n")).toBe(true);
});

test("Alt+click adds a cursor in the read-only editor and no breakpoint", async ({ ctPage: page }) => {
  await editorReady(page);
  const line = await longestWordLine(page);
  const a = await textAt(page, line, 2);
  const b = await textAt(page, line, 6);
  await page.mouse.click(a.x, a.y);
  await page.waitForTimeout(500);
  const before = await breakpointCount(page);
  await page.keyboard.down("Alt");
  await page.mouse.click(b.x, b.y);
  await page.keyboard.up("Alt");
  await page.waitForTimeout(600);
  expect((await selections(page)).length).toBe(2);
  expect(await breakpointCount(page)).toBe(before);
});

test("Ctrl+double-click ends with no selection: the jump collapses Monaco's word", async ({ ctPage: page }) => {
  await editorReady(page);
  const line = await longestWordLine(page);
  const p = await textAt(page, line, 3);
  await page.keyboard.down("Control");
  await page.mouse.click(p.x, p.y, { clickCount: 2 });
  await page.keyboard.up("Control");
  await page.waitForTimeout(500);
  expect(await selections(page)).toEqual([""]);
});

test("the glyph column toggles on the press; the numbers select the line", async ({ ctPage: page }) => {
  await editorReady(page);
  await watchTarget(page);
  const line = await longestWordLine(page);
  const g = await glyphCentre(page, line);
  // The press, not the release: a press, a drag off and a release has toggled.
  await page.mouse.move(g.x, g.y);
  await page.mouse.down();
  expect(await targetType(page)).toBe(2); // GUTTER_GLYPH_MARGIN
  await expect.poll(() => glyphMarksOn(page, line), { timeout: 10_000 }).toEqual(["gutter-glyph-breakpoint"]);
  await page.mouse.move(g.x + 300, g.y + 200);
  await page.mouse.up();
  // A right press disables and opens no menu; a second enables.
  await pressGlyph(page, line, { button: "right" });
  await expect.poll(() => glyphMarksOn(page, line), { timeout: 10_000 }).toEqual(["gutter-glyph-breakpoint-disabled"]);
  await expect(page.locator("#context-menu-container")).toBeHidden();
  await pressGlyph(page, line, { button: "right" });
  await expect.poll(() => glyphMarksOn(page, line), { timeout: 10_000 }).toEqual(["gutter-glyph-breakpoint"]);
  const count = await breakpointCount(page);
  // A number selects the line, target GUTTER_LINE_NUMBERS, and toggles nothing.
  const n = await numberAt(page, line);
  await page.mouse.click(n.x, n.y);
  expect(await targetType(page)).toBe(3);
  expect((await selections(page))[0].endsWith("\n")).toBe(true);
  await page.waitForTimeout(300);
  expect(await breakpointCount(page)).toBe(count);
  // A double press on the glyph toggles twice and selects nothing new.
  await pressGlyph(page, line);
  await pressGlyph(page, line);
  await expect.poll(() => glyphMarksOn(page, line), { timeout: 10_000 }).toEqual(["gutter-glyph-breakpoint"]);
});

test("the hint is a glyph decoration on the hovered unmarked line only", async ({ ctPage: page }) => {
  await editorReady(page);
  const line = await longestWordLine(page);
  const g = await glyphCentre(page, line);
  await page.mouse.move(g.x, g.y);
  await expect.poll(() => glyphMarksOn(page, line), { timeout: 5_000 }).toEqual(["gutter-glyph-hint"]);
  const t = await textAt(page, line, 3);
  await page.mouse.move(t.x, t.y);
  await expect.poll(() => glyphMarksOn(page, line), { timeout: 5_000 }).toEqual([]);
});

test("Shift+F9 and the menu entry; the hints", async ({ ctPage: page }) => {
  await editorReady(page);
  const line = await longestWordLine(page);
  await placeCaret(page, line, 3);
  await page.keyboard.press("Shift+F9");
  const held = () => page.evaluate((line) => {
    const w = globalThis as any;
    return (w.ctBreakpointRows ? w.ctBreakpointRows() : [])
      .filter((r: any) => r.line === line).map((r: any) => r.column as number);
  }, line);
  await expect.poll(held, { timeout: 10_000 }).toEqual([3]);
  expect(await glyphMarksOn(page, line)).toEqual(["gutter-glyph-breakpoint"]);
  await page.keyboard.press("Shift+F9");
  await expect.poll(held, { timeout: 10_000 }).toEqual([]);
  // Column 1 is a line breakpoint.
  await placeCaret(page, line, 1);
  await page.keyboard.press("Shift+F9");
  await expect.poll(held, { timeout: 10_000 }).toEqual([0]);
  await page.keyboard.press("Shift+F9");
  await expect.poll(held, { timeout: 10_000 }).toEqual([]);
  // The menu at a press: its chord, and the glyph column named by where it is.
  const p = await textAt(page, line, 3);
  await page.mouse.click(p.x, p.y, { button: "right" });
  const menu = page.locator("#context-menu-container");
  await expect(menu).toBeVisible({ timeout: 10_000 });
  await expect(menu).toContainText("Add Inline Breakpoint");
  await expect(menu).toContainText("Shift+F9");
  await expect(menu).toContainText("<click left of the line number>");
  await menu.locator(".context-menu-item", { hasText: "Add Inline Breakpoint" }).click();
  await expect.poll(held, { timeout: 10_000 }).toHaveLength(1);
  await page.mouse.click(p.x, p.y, { button: "right" });
  await expect(menu).toContainText("Remove Inline Breakpoint");
  await menu.locator(".context-menu-item", { hasText: "Remove Inline Breakpoint" }).click();
  await expect.poll(held, { timeout: 10_000 }).toEqual([]);
});
