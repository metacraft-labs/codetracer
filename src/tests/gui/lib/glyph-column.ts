/**
 * The editor's glyph column (Editor-Pane.md MC.5): Monaco's glyph margin, left of
 * the line numbers. Its marks are decorations, so a mark has no element keyed by
 * its line: these read them from the model and press where Monaco lays the line.
 */
import type { Page } from "@playwright/test";

/** The active editor's glyph classes on `line` (`gutter-glyph-*`). */
export async function glyphMarksOn(page: Page, line: number): Promise<string[]> {
  return page.evaluate((line) => {
    const data = (globalThis as any).data;
    const editor = data?.ui?.editors?.[data?.services?.editor?.active]?.monacoEditor;
    const decorations = editor?.getModel?.()?.getLineDecorations?.(line) ?? [];
    return decorations
      .map((d: any) => d.options?.glyphMarginClassName as string | undefined)
      .filter((c: string | undefined) => !!c && c.includes("gutter-glyph"))
      .flatMap((c: string) => c.trim().split(/\s+/))
      .filter((c: string) => c.startsWith("gutter-glyph"));
  }, line);
}

/** The window position of the centre of `line`'s glyph cell. */
export async function glyphCentre(page: Page, line: number): Promise<{ x: number; y: number }> {
  const at = await page.evaluate((line) => {
    const data = (globalThis as any).data;
    const editor = data?.ui?.editors?.[data?.services?.editor?.active]?.monacoEditor;
    editor.revealLineInCenterIfOutsideViewport(line);
    const box = editor.getDomNode().getBoundingClientRect();
    const layout = editor.getLayoutInfo();
    return {
      x: box.left + layout.glyphMarginLeft + layout.glyphMarginWidth / 2,
      y: box.top + editor.getTopForLineNumber(line) - editor.getScrollTop() +
        editor.getOption((globalThis as any).monaco.editor.EditorOption.lineHeight) / 2,
    };
  }, line);
  await page.waitForTimeout(100);
  return at;
}

/** Press `line`'s glyph cell. */
export async function pressGlyph(
  page: Page,
  line: number,
  options: { button?: "left" | "right" } = {},
): Promise<void> {
  const { x, y } = await glyphCentre(page, line);
  await page.mouse.click(x, y, { button: options.button ?? "left" });
}

/** Put the active editor's caret at `line:column` and take the focus. */
export async function placeCaret(page: Page, line: number, column: number): Promise<void> {
  await page.evaluate(({ line, column }) => {
    const data = (globalThis as any).data;
    const editor = data?.ui?.editors?.[data?.services?.editor?.active]?.monacoEditor;
    editor.setPosition({ lineNumber: line, column });
    editor.focus();
  }, { line, column });
}
