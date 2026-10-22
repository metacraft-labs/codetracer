/**
 * plat68b-desktop-text-fields.spec.ts — the desktop key router leaves a text
 * field's own keys to the field.
 *
 * Base-Keymaps-And-Layer-Stack.md §6.2: the desktop's scope path is read off
 * the DOM focus chain, and a focused text field (an `<input>` that takes
 * text, a `<textarea>`, a contenteditable element) is an `input` element of
 * that path whether or not its view stamped it
 * (`scope_path.withNativeTextField`). Its table is `input`, whose
 * rows the element performs itself (`key_router.NativeTables`), so the
 * router lets `Enter` through to the field's own `keydown` listener. Before
 * the fix the Call Trace search box was not on the path at all: `Enter`
 * resolved to the pane's `list.activate`, and the router's
 * `preventDefault` + `stopImmediatePropagation` kept the box's listener
 * (`isonim_calltrace_view.wireSearchForm`) from ever running
 * (codetracer-pm issue 2026-10-21-desktop-key-router-swallows-enter-in-the-
 * call-trace-search-box).
 *
 *   * the CONTROL: submitting the box's `<form>` runs the same listener's
 *     sibling and searches. It proves that the recording answers a search,
 *     so a failure of the next case is the key's, not the backend's;
 *   * a real `Enter` in the box searches: it resolves to the field's
 *     `input.commit`, never the pane's `list.activate`;
 *   * letters typed into the box with real key presses are characters: the
 *     router runs nothing for them and the box holds what was typed (before
 *     the fix CUA's letters stepped the debugger and took the focus away —
 *     the box kept one letter of `report_total`);
 *   * the same holds for the fields INSIDE the editor element that are not
 *     the editor's own text area: Monaco's find widget and a tracepoint
 *     editor. Before, their path ended at the read-only editor, so a letter
 *     typed into the find widget ran the editor's letter (CUA's `f`,
 *     `debugger.step-out`, which took the focus away) and `Enter` opened a
 *     tracepoint editor instead of finding the next match.
 *
 * WHAT IS READ: `window.__ctKeyTrace` (every operation the router ran) and
 * the search results the box renders. No mocks: the real app, a real Python
 * recording, a real `replay-server`.
 */

import type { Locator, Page } from "@playwright/test";
import { test, expect } from "../../lib/fixtures";
import { LayoutPage } from "../../page-objects/layout-page";
import type { CallTracePane } from "../../page-objects/panes/call-trace/call-trace-pane";

const Query = "report_total";

async function keyTrace(page: Page): Promise<string[]> {
  return page.evaluate(() => ((globalThis as any).__ctKeyTrace ?? []).slice());
}

async function clearTrace(page: Page) {
  await page.evaluate(() => { (globalThis as any).__ctKeyTrace = []; });
}

async function openCallTrace(page: Page): Promise<CallTracePane> {
  const layout = new LayoutPage(page);
  await layout.waitForAllComponentsLoaded();
  const callTrace = (await layout.callTraceTabs())[0];
  await callTrace.clickTab();
  await page.waitForSelector(".calltrace-view .call-text", { timeout: 120_000 });
  return callTrace;
}

async function focusBox(page: Page, box: Locator) {
  await box.click();
  await expect.poll(() => page.evaluate(() =>
    (document.activeElement as HTMLElement | null)?.classList
      .contains("calltrace-search-input") ?? false)).toBe(true);
}

/** The editor holding the focus, read through the renderer's `data`. */
function activeEditorHandle(page: Page) {
  return page.evaluate(() => {
    const d = (globalThis as any).data;
    return d?.services?.editor?.active ?? null;
  });
}

/**
 * The caret in the read-only editor. Through Monaco's own `focus()`, not a
 * click: what this spec tests is the keys, and where a click on a view line
 * lands depends on the layout (plat68b-desktop-keys.spec.ts's
 * `caretInEditor` has to compute a point inside the editor's content box).
 */
async function caretInEditor(page: Page) {
  const layout = new LayoutPage(page);
  await layout.waitForAllComponentsLoaded();
  await expect.poll(() => activeEditorHandle(page), { timeout: 120_000 }).not.toBeNull();
  await page.evaluate(() => {
    const d = (globalThis as any).data;
    d.ui.editors[d.services.editor.active].monacoEditor.focus();
  });
  await expect.poll(() => page.evaluate(() => {
    const d = (globalThis as any).data;
    return !!d.ui.editors[d.services.editor.active].monacoEditor.hasTextFocus();
  })).toBe(true);
}

function activeIsInside(page: Page, selector: string) {
  return page.evaluate((sel) => !!document.activeElement?.closest(sel), selector);
}

function searchResults(callTrace: CallTracePane) {
  return callTrace.searchResultsContainer().locator(".search-result");
}

// A cold launch records the program and starts the engine before the first
// assertion; plat68b-desktop-keys.spec.ts allows the same.
test.setTimeout(300_000);

test.describe("PLAT-68: a text field's own keys reach the field", () => {
  test.use({ sourcePath: "py_calltrace_collapse/main.py", launchMode: "trace" });

  test("control: submitting the Call Trace search form searches", async ({ ctPage }) => {
    const callTrace = await openCallTrace(ctPage);
    const box = callTrace.searchInput();
    await box.fill(Query);
    await box.evaluate((el) => (el as HTMLInputElement).form!.requestSubmit());
    await expect.poll(async () => searchResults(callTrace).count(),
                      { timeout: 30_000 }).toBeGreaterThan(0);
  });

  test("a real Enter in the Call Trace search box searches", async ({ ctPage }) => {
    const callTrace = await openCallTrace(ctPage);
    const box = callTrace.searchInput();
    await box.fill(Query);
    await focusBox(ctPage, box);
    await clearTrace(ctPage);
    await ctPage.keyboard.press("Enter");
    // `Enter` resolved to the field's own `input.commit`, which the router
    // traces and leaves to the element — never the pane's `list.activate`.
    await expect.poll(() => keyTrace(ctPage)).toEqual(["input.commit"]);
    await expect.poll(async () => searchResults(callTrace).count(),
                      { timeout: 30_000 }).toBeGreaterThan(0);
  });

  test("letters typed into the Call Trace search box are characters", async ({ ctPage }) => {
    const callTrace = await openCallTrace(ctPage);
    const box = callTrace.searchInput();
    await focusBox(ctPage, box);
    await clearTrace(ctPage);
    // Real key presses, one per character: a letter the router took as a
    // pane or global binding (CUA's letters, Base-Keymaps §10.1) would run
    // an operation and be missing from the box.
    await ctPage.keyboard.type(Query, { delay: 20 });
    await expect(box).toHaveValue(Query);
    expect(await keyTrace(ctPage)).toEqual([]);
  });
});

test.describe("PLAT-68: a field inside the editor element is a field", () => {
  test.use({ sourcePath: "py_calltrace_collapse/main.py", launchMode: "trace" });

  test("Monaco's find widget takes its letters and its Enter", async ({ ctPage }) => {
    await caretInEditor(ctPage);
    await ctPage.evaluate(() => {
      const d = (globalThis as any).data;
      d.ui.editors[d.services.editor.active].monacoEditor.trigger("keyboard", "actions.find", {});
    });
    await expect.poll(() => activeIsInside(ctPage, ".find-widget")).toBe(true);
    const tracepoints = await ctPage.locator(".trace").count();
    await clearTrace(ctPage);
    await ctPage.keyboard.type("def", { delay: 20 });
    // `f` is CUA's `debugger.step-out` in the read-only editor; in the field
    // it is a character, and the focus stays in the widget.
    expect(await keyTrace(ctPage)).toEqual([]);
    expect(await activeIsInside(ctPage, ".find-widget")).toBe(true);
    expect(await ctPage.evaluate(() =>
      (document.activeElement as HTMLTextAreaElement | HTMLInputElement).value)).toBe("def");
    await ctPage.keyboard.press("Enter");
    // The field's `input.commit`, left to Monaco (find next) — not the
    // read-only editor's `editor.toggle-tracepoint`.
    expect(await keyTrace(ctPage)).toEqual(["input.commit"]);
    expect(await activeIsInside(ctPage, ".find-widget")).toBe(true);
    await ctPage.waitForTimeout(1_000);
    expect(await ctPage.locator(".trace").count()).toBe(tracepoints);
  });

  test("a tracepoint editor takes its letters and its Enter", async ({ ctPage }) => {
    await caretInEditor(ctPage);
    // `Enter` in the editor's own text area opens the tracepoint editor on
    // the caret's line, and the tracepoint editor takes the focus.
    await clearTrace(ctPage);
    await ctPage.keyboard.press("Enter");
    expect(await keyTrace(ctPage)).toEqual(["editor.toggle-tracepoint"]);
    await expect.poll(() => activeIsInside(ctPage, ".trace"), { timeout: 20_000 }).toBe(true);
    // The caret in the tracepoint editor's text, as a click there puts it:
    // the editor opens with the focus on Monaco's read-only IME textarea,
    // which takes no typing whatever the router does.
    await ctPage.evaluate(() => {
      const d = (globalThis as any).data;
      const host = document.activeElement?.closest(".trace");
      const ed = (d.ui.traceMonacoEditors ?? []).find((e: any) => host?.contains(e.getDomNode()));
      // Kept for `value` below: after an edit the tracepoint editor moves
      // the focus back to its IME textarea, where the instance no longer
      // reports the text focus.
      (globalThis as any).__plat68TracepointEditor = ed;
      ed?.focus();
    });
    await expect.poll(() => ctPage.evaluate(() => {
      const d = (globalThis as any).data;
      return (d.ui.traceMonacoEditors ?? []).some((e: any) => e.hasTextFocus());
    })).toBe(true);
    const value = () => ctPage.evaluate(() => {
      const ed = (globalThis as any).__plat68TracepointEditor;
      return ed ? String(ed.getValue()) : null;
    });
    await clearTrace(ctPage);
    await ctPage.keyboard.type("fn", { delay: 20 });
    expect(await keyTrace(ctPage)).toEqual([]);
    await expect.poll(value).toBe("fn");
    await ctPage.keyboard.press("Enter");
    expect(await keyTrace(ctPage)).toEqual(["input.commit"]);
    // Monaco performed it: a new line in the tracepoint's expression, the
    // tracepoint editor still open and focused.
    await expect.poll(value).toBe("fn\n");
    expect(await activeIsInside(ctPage, ".trace")).toBe(true);
  });
});
