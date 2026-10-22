/**
 * A RIGHT CLICK ON A BREAKPOINT'S GUTTER MARKER IS THE TOGGLE, AND NOTHING ELSE.
 *
 * Spec: `codetracer-pm/spec/GUI/Core-Panes/Editor-Pane.md`, "On the gutter",
 * gesture 8 — a right click in the glyph column toggles the breakpoint's
 * enabled state, and "No menu appears."
 *
 * Reported (codetracer-pm issue 2026-10-04-desktop-editor-menu-offers-disable-
 * for-a-just-disabled-breakpoint): after a right click on a breakpoint's
 * marker had disabled it, the FIRST right click on the line's text showed a
 * menu offering "Disable breakpoint"; only the second offered "Enable
 * breakpoint".
 *
 * WHY THE FIRST MENU WAS WRONG. The one press reached two listeners in
 * `src/frontend/ui/editor.nim`. Monaco's `onContextMenu` listens on Monaco's
 * own DOM node, a descendant of the editor container, so it ran FIRST: it
 * built the editor's menu while the breakpoint was still enabled ("Disable
 * breakpoint") and showed it. Only then did the container's `contextmenu`
 * listener toggle the breakpoint. A menu built from the state before the
 * toggle was left open, and the next right click on the text read it instead
 * of opening a fresh one.
 *
 * WHAT IS ASSERTED, in both directions so that neither a menu that always
 * says "Enable" nor one that always says "Disable" can pass:
 *
 *   1. a click on line 31's `.gutter-line` adds an enabled breakpoint;
 *   2. a right click on its `.gutter-breakpoint-enabled` marker disables it —
 *      the marker turns `.gutter-breakpoint-disabled`, the frontend's
 *      `breakpointTable` holds it `enabled: false` — and NO menu is open;
 *   3. the first right click on line 31's text offers "Enable breakpoint" and
 *      not "Disable breakpoint";
 *   4. the mirror: a right click on the now-disabled marker re-enables it,
 *      opens no menu, and the first text menu offers "Disable breakpoint" and
 *      not "Enable breakpoint";
 *   5. a right click on line 31's NUMBER (`.gutter-line`) is not the toggle:
 *      it opens the editor's menu for the line ("A right click on the line
 *      numbers opens the editor's context menu", the same section), built
 *      from the current state ("Disable breakpoint"), and the breakpoint
 *      stays enabled. Toggling there as well as opening the menu would build
 *      the menu before the toggle, which is this defect again;
 *   6. a right click on the EMPTY glyph slot of line 36 (`return left -
 *      right`, code and no breakpoint), the transparent
 *      `.gutter-no-breakpoint` placeholder `trace.editorLineNumber` draws
 *      where a marker would be, does nothing ("On a line without a
 *      breakpoint it does nothing", gesture 8): no menu opens, no marker
 *      appears on the line and `breakpointTable` gains no entry for it.
 *      Until `isGutterToggleTarget` matched the placeholder, Monaco's
 *      listener took the press for an ordinary margin right click and opened
 *      the editor's menu.
 *
 * No mocks: the real Electron app (`src/build-debug/bin/ct`, this checkout's
 * build), a real `replay-server`, and a real `.ct` recording — the terminal
 * lanes' `calc` fixture under `test-logs/tui-fixtures/`, the same one
 * `tests/visual/plat50-desktop-capture.spec.ts` opens.
 */

import * as fs from "node:fs";
import * as path from "node:path";

import { expect, type Page } from "@playwright/test";
import { test } from "../../lib/fixtures";

const repoRoot = path.resolve(__dirname, "..", "..", "..", "..", "..");

/** The cached `calc` recording, recorded by `just test-tui` (or by
 *  `scripts/plat50-capture-electron.sh`) the first time either runs. */
function recording(): string {
  const cache = path.join(repoRoot, "test-logs", "tui-fixtures");
  const hits = fs.existsSync(cache)
    ? fs.readdirSync(cache).filter((e) => e.startsWith("calc-")).sort()
    : [];
  if (hits.length === 0) {
    throw new Error(
      "the 'calc' recording is not in test-logs/tui-fixtures/; run 'just test-tui' once to record it.",
    );
  }
  return path.join(cache, hits[hits.length - 1]);
}

test.use({
  sourcePath: recording(),
  launchMode: "trace-folder",
});
test.setTimeout(300_000);

/** `calc/main.py` line 31, `return left + right`: a line with code on it. */
const LINE = 31;
const LINE_TEXT = "return left + right";

const MENU = "#context-menu-container";
const gutterOf = (page: Page) =>
  page.locator(`.monaco-editor .margin-view-overlays .gutter[data-line='${LINE}']`).first();

/** `calc/main.py` line 36, `return left - right`: a line with code on it that
 *  no step of this test puts a breakpoint on (step 6). */
const EMPTY_LINE = 36;
const emptyGutterOf = (page: Page) =>
  page.locator(`.monaco-editor .margin-view-overlays .gutter[data-line='${EMPTY_LINE}']`).first();

/** The breakpoint `breakpointTable` holds on `line` (default 31) of any
 *  `main.py`, or null. */
async function breakpointOnLine(page: Page, line: number = LINE): Promise<{ enabled: boolean } | null> {
  return page.evaluate((line) => {
    const table = (globalThis as any).data?.services?.debugger?.breakpointTable ?? {};
    for (const file of Object.keys(table)) {
      if (!file.endsWith("main.py")) continue;
      const bp = table[file]?.[line];
      if (bp) return { enabled: !!bp.enabled };
    }
    return null;
  }, line);
}

/** Brings `line` (default 31) to the editor's centre. Once the debugger has
 *  moved, the editor can have scrolled the line under Monaco's sticky-scroll
 *  header (`.overlayWidgets`), which then takes a press aimed at the line. */
async function centreLine(page: Page, line: number = LINE): Promise<void> {
  await page.evaluate((line) => {
    const editors = (globalThis as any).data?.ui?.editors ?? {};
    for (const key of Object.keys(editors)) {
      editors[key]?.monacoEditor?.revealLineInCenter?.(line);
    }
  }, line);
  await page.waitForTimeout(300);
}

/** The labels of the open context menu, which is then closed. */
async function openMenuLabels(page: Page): Promise<string[]> {
  const items = page.locator(`${MENU} .context-menu-item`);
  const labels: string[] = [];
  for (const item of await items.all()) {
    const label = item.locator(".ct-menu-item-label");
    const text = (await label.count()) > 0 ? await label.first().innerText() : await item.innerText();
    if (text.trim().length > 0) labels.push(text.trim().split("\n")[0]);
  }
  await page.keyboard.press("Escape");
  await page.locator(MENU).waitFor({ state: "hidden", timeout: 5_000 }).catch(() => undefined);
  return labels;
}

/** Right-clicks line 31's text near the line's start and returns the menu.
 *  Near the start, not at the `.view-line`'s centre: the line is as wide as
 *  the editor's widest line, so its centre can lie right of any text. */
async function textMenu(page: Page): Promise<string[]> {
  await centreLine(page);
  await page.locator(".monaco-editor .view-line", { hasText: LINE_TEXT }).first()
    .click({ button: "right", position: { x: 60, y: 8 } });
  await page.locator(MENU).waitFor({ state: "visible", timeout: 10_000 });
  return openMenuLabels(page);
}

/** Right-clicks line 31's line number (`.gutter-line`) and returns the menu
 *  that press opened. */
async function numberMenu(page: Page): Promise<string[]> {
  await centreLine(page);
  await gutterOf(page).locator(".gutter-line").first().click({ button: "right" });
  await page.locator(MENU).waitFor({ state: "visible", timeout: 10_000 });
  // Long enough for a toggle the press made to have reached the table, so
  // the caller's "still enabled" reading is not taken before it.
  await page.waitForTimeout(500);
  return openMenuLabels(page);
}

/** Right-clicks line 31's breakpoint marker in state `from` and waits for the
 *  toggle to reach the marker and the breakpoint table. Returns the labels of
 *  any menu the press left open (the defect), or null when none is. */
async function toggleByMarker(page: Page, from: "enabled" | "disabled"): Promise<string[] | null> {
  const to = from === "enabled" ? "disabled" : "enabled";
  await centreLine(page);
  await gutterOf(page).locator(`.gutter-breakpoint-${from}`).first().click({ button: "right" });
  await expect(gutterOf(page).locator(`.gutter-breakpoint-${to}`)).toHaveCount(1, { timeout: 10_000 });
  await expect.poll(() => breakpointOnLine(page), { timeout: 10_000 })
    .toEqual({ enabled: to === "enabled" });
  // Long enough for a menu the press opened to have appeared: the stale one
  // was shown synchronously by Monaco's listener, before the toggle above.
  await page.waitForTimeout(500);
  return (await page.locator(MENU).isVisible()) ? openMenuLabels(page) : null;
}

test("a right click on a breakpoint's gutter marker toggles it and opens no menu", async ({ ctPage }) => {
  await ctPage.waitForSelector(".calltrace-view .call-text", { timeout: 120_000 });
  await centreLine(ctPage);
  await expect(gutterOf(ctPage)).toHaveCount(1, { timeout: 30_000 });

  // 1. A breakpoint on line 31.
  await gutterOf(ctPage).locator(".gutter-line").first().click();
  await expect(gutterOf(ctPage).locator(".gutter-breakpoint-enabled")).toHaveCount(1, { timeout: 10_000 });
  await expect.poll(() => breakpointOnLine(ctPage), { timeout: 10_000 }).toEqual({ enabled: true });

  // 2. Disabled by the marker's right click, with no menu.
  const leftOpenOnDisable = await toggleByMarker(ctPage, "enabled");
  expect(leftOpenOnDisable, "the marker's right click (disable) left a context menu open").toBeNull();

  // 3. The first text menu reads the disabled state.
  const afterDisable = await textMenu(ctPage);
  expect(afterDisable).toContain("Enable breakpoint");
  expect(afterDisable).not.toContain("Disable breakpoint");

  // 4. The mirror: re-enabled by the marker, no menu, the first text menu
  //    reads the enabled state.
  const leftOpenOnEnable = await toggleByMarker(ctPage, "disabled");
  expect(leftOpenOnEnable, "the marker's right click (enable) left a context menu open").toBeNull();
  const afterEnable = await textMenu(ctPage);
  expect(afterEnable).toContain("Disable breakpoint");
  expect(afterEnable).not.toContain("Enable breakpoint");

  // 5. The line number opens the menu, from the current state, and toggles
  //    nothing.
  const onNumber = await numberMenu(ctPage);
  expect(onNumber).toContain("Disable breakpoint");
  expect(onNumber).not.toContain("Enable breakpoint");
  await expect(gutterOf(ctPage).locator(".gutter-breakpoint-enabled")).toHaveCount(1);
  expect(await breakpointOnLine(ctPage)).toEqual({ enabled: true });

  // 6. The empty glyph slot of a line with no breakpoint does nothing: no
  //    menu opens and no breakpoint appears.
  await centreLine(ctPage, EMPTY_LINE);
  const placeholder = emptyGutterOf(ctPage).locator(".gutter-no-breakpoint");
  await expect(placeholder).toHaveCount(1, { timeout: 10_000 });
  expect(await breakpointOnLine(ctPage, EMPTY_LINE), "line 36 had a breakpoint before step 6").toBeNull();
  await placeholder.first().click({ button: "right" });
  // Long enough for a menu the press opened to have appeared (Monaco shows
  // its menu synchronously) and for a breakpoint it added to have reached the
  // table and the gutter.
  await ctPage.waitForTimeout(500);
  const leftOpenOnEmpty = (await ctPage.locator(MENU).isVisible()) ? await openMenuLabels(ctPage) : null;
  expect(leftOpenOnEmpty, "the empty glyph slot's right click opened a context menu").toBeNull();
  await expect(emptyGutterOf(ctPage).locator("[class*='gutter-breakpoint-']")).toHaveCount(0);
  expect(await breakpointOnLine(ctPage, EMPTY_LINE), "the empty glyph slot's right click added a breakpoint")
    .toBeNull();
});
