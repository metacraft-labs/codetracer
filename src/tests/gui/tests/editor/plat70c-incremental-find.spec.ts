/**
 * plat70c-incremental-find.spec.ts — PLAT-70 Part C (Find-And-Incremental-
 * Search.md §3, §4) on the desktop, where the CUA rows are Monaco's own
 * widget, in the real Electron app on a real recording of `calc`:
 *
 *   * `Ctrl+F` with the caret in a word opens Monaco's find widget seeded
 *     with it (§4.1, `seedSearchStringFromSelection: "always"`), through the
 *     key router (`find.open` → the editor's `onFindOrFilter`);
 *   * typing a query selects the first match after the caret and the count
 *     is shown; `Enter` walks;
 *   * `Escape` closes the widget and KEEPS the match selected (FS-5, the
 *     user's OQ-F1 — Monaco's `closeFindWidget`), read back off Monaco's
 *     selection;
 *   * the palette's **Find: Cancel and Return** (`find.cancel`) closes it and
 *     puts back the selection and both scroll offsets as they were when the
 *     find opened (FS-4), read back off Monaco;
 *   * none of it moves the debugger: the read-only Debug editor's pointer
 *     and tick stay.
 *
 * No mocks: a real `.ct` recording, the real `ct`, a real `replay-server`,
 * the real Electron app, real keyboard events.
 */

import * as fs from "fs";
import * as path from "path";

import { expect } from "@playwright/test";
import { test } from "../../lib/fixtures";
import { CommandPalette } from "../../page-objects/command-palette/command-palette";

const repoRoot = path.resolve(__dirname, "..", "..", "..", "..", "..");

function recording(prefix: string): string {
  const cache = path.join(repoRoot, "test-logs", "tui-fixtures");
  const hits = fs.existsSync(cache)
    ? fs.readdirSync(cache).filter((e) => e.startsWith(prefix + "-")).sort()
    : [];
  if (hits.length === 0) {
    throw new Error(
      `PLAT-70: the '${prefix}' recording is not in test-logs/tui-fixtures/; ` +
        "the tui lane records it on its first run.",
    );
  }
  return path.join(cache, hits[hits.length - 1]);
}

const prefix = process.env.PLAT70_DESKTOP_PREFIX ?? "";

test.setTimeout(400_000);

function where(page: any) {
  return page.evaluate(() => {
    const loc = (globalThis as any).data?.services?.debugger?.location;
    return { line: loc?.line ?? -1, ticks: Number(loc?.rrTicks ?? -1) };
  });
}

async function editorState(page: any) {
  return page.evaluate(() => {
    const w = globalThis as any;
    const data = w.data;
    const ed =
      data?.ui?.editors?.[data?.services?.editor?.active]?.monacoEditor ??
      w.monaco.editor.getEditors()[0];
    const sel = ed.getSelection();
    const model = ed.getModel();
    return {
      selected: model.getValueInRange(sel) as string,
      selection: [sel.startLineNumber, sel.startColumn, sel.endLineNumber, sel.endColumn],
      scrollTop: ed.getScrollTop() as number,
      scrollLeft: ed.getScrollLeft() as number,
    };
  });
}

async function placeCaret(page: any, line: number, column: number) {
  await page.waitForFunction(
    () =>
      typeof (globalThis as any).monaco !== "undefined" &&
      (globalThis as any).monaco.editor.getEditors().length > 0,
    { timeout: 60_000 },
  );
  // The caret placed by a real press on the text, so the editor component
  // takes the app's focus (`activeFocus`, which `find.open` acts on) as a
  // user's click gives it.
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

test.describe("PLAT-70 Part C: the desktop's find (Monaco's widget)", () => {
  test.use({
    sourcePath: recording("calc"),
    launchMode: "trace-folder",
    ...(prefix ? { codetracerPrefixOverride: prefix } : {}),
  });

  test("Ctrl+F seeds, typing finds, Enter walks, Escape keeps the match", async ({ ctPage }) => {
    const page = ctPage;
    await page.waitForSelector(".calltrace-view .call-text", { timeout: 120_000 });
    const start = await where(page);
    // calc's line 31: `    return left + right` — the caret inside `left`.
    await placeCaret(page, 31, 14);
    await page.keyboard.press("Control+KeyF");
    const widget = page.locator(".monaco-editor .find-widget.visible").first();
    await expect(widget).toBeVisible({ timeout: 20_000 });
    const input = widget.locator("textarea, input").first();
    await expect(input).toHaveValue("left");

    await page.keyboard.type("right");
    await expect(input).toHaveValue("right");
    await expect(widget.locator(".matchesCount")).toContainText(" of ", { timeout: 10_000 });
    await expect.poll(async () => (await editorState(page)).selected.toLowerCase()).toBe("right");
    const first = (await editorState(page)).selection;

    await page.keyboard.press("Enter");
    await expect.poll(async () => (await editorState(page)).selection).not.toEqual(first);
    const walked = await editorState(page);
    expect(walked.selected.toLowerCase()).toBe("right");

    // Escape closes and KEEPS the match (OQ-F1).
    await page.keyboard.press("Escape");
    await expect(page.locator(".monaco-editor .find-widget.visible")).toHaveCount(0);
    const kept = await editorState(page);
    expect(kept.selection).toEqual(walked.selection);
    expect(kept.selected.toLowerCase()).toBe("right");

    // The debugger did not move.
    expect((await where(page)).ticks).toBe(start.ticks);
  });

  test("Find: Cancel and Return restores the selection and the scroll (FS-4)", async ({ ctPage }) => {
    const page = ctPage;
    await page.waitForSelector(".calltrace-view .call-text", { timeout: 120_000 });
    const start = await where(page);
    await placeCaret(page, 31, 14);
    const before = await editorState(page);
    await page.keyboard.press("Control+KeyF");
    const widget = page.locator(".monaco-editor .find-widget.visible").first();
    await expect(widget).toBeVisible({ timeout: 20_000 });
    // A match far below: the editor scrolls to it.
    await page.keyboard.type("checksum");
    await expect.poll(async () => (await editorState(page)).scrollTop).not.toBe(before.scrollTop);

    const palette = new CommandPalette(page);
    await palette.executeCommand("Cancel and Return");
    await expect(page.locator(".monaco-editor .find-widget.visible")).toHaveCount(0);
    await expect.poll(async () => (await editorState(page)).selection).toEqual(before.selection);
    const after = await editorState(page);
    expect(after.scrollTop).toBe(before.scrollTop);
    expect(after.scrollLeft).toBe(before.scrollLeft);
    expect((await where(page)).ticks).toBe(start.ticks);
  });
});
