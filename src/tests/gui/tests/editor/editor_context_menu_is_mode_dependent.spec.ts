/**
 * THE EDITOR'S RIGHT-CLICK MENU IS THE MODE'S.
 *
 * Reported against noirstudio.dev: "I noticed that the right click menu content
 * over the editor area is not context dependent (Edit vs Debug). Most of the
 * entries are debug operations."
 *
 * Both halves of that sentence were true, and they had different causes.
 * `createContextMenuItems` (`src/frontend/ui/editor.nim`) built ten replay
 * commands and gated none of them on `data.ui.mode`, so Edit mode offered
 * "Run to Cursor" with no session to run in. And it offered NOTHING ELSE:
 * `contextmenu: false` on the Monaco options switched off Monaco's own menu —
 * that was the fix for the earlier "I see both menus" report — and nothing
 * replaced the cut/copy/paste it used to carry. The surviving menu was not the
 * union of the two menus. It was one of them, and it was the debugger's.
 *
 * WHY THIS TEST IS PER-ENTRY AND PER-MODE AND IN BOTH DIRECTIONS
 * -------------------------------------------------------------
 * "The menu differs between the modes" cannot fail for its own reason — a menu
 * that differs by one row differs. "The menu is non-empty" is worse. So every
 * assertion below names ONE entry and ONE mode and says either present or
 * absent, and both directions are asserted in both modes: an entry that
 * belongs is there, and an entry that does not is GONE rather than greyed.
 *
 * ABSENT, NOT DISABLED, is the decision this test enforces. A greyed-out list
 * of ten debug operations is still a menu about debugging and fails the report
 * just as squarely. Disabled-with-a-reason is reserved for an entry that
 * genuinely applies in this mode and cannot run right now — in this menu that
 * is Cut/Paste against a read-only Edit-mode editor, and Paste on a browser
 * that will not let a page read the clipboard. Where it is used, the reason is
 * asserted to be non-empty and on the row.
 *
 * ONE FILE, TWO MODES. The same editor and the same line are right-clicked in
 * both modes, so "the menus differ" cannot be satisfied by having clicked
 * somewhere else. `#run-image` and `#stop-image` are the product's own
 * transitions, the same two the toolbar offers.
 */

import * as path from "node:path";

import { test, expect, codetracerInstallDir } from "../../lib/fixtures";
import { ContextMenu } from "../../page-objects/components/context-menu";

const testFolder = path.join(codetracerInstallDir, "test-programs");

/** Entries that must exist in Edit mode and must NOT exist in Debug mode. */
const EDIT_ONLY = ["Cut", "Paste", "Replace"];

/** Entries that must exist in Debug mode and must NOT exist in Edit mode. */
const DEBUG_ONLY = [
  "Jump to line",
  "Run to Cursor",
  "Jump backward to line",
  "Jump to call",
  "Jump forward to call",
  "Jump backward to call",
  "Add tracepoint",
  "Delete tracepoint",
  "Enable tracepoint",
  "Disable tracepoint",
];

/** Entries that must exist in BOTH modes. */
const BOTH = ["Copy", "Find"];

/**
 * Breakpoint rows are in both menus by decision, not by omission:
 * `Mode-Transitions.md` §5 lists breakpoints among the things a transition
 * preserves because "they belong to the project, not to the session". Only one
 * of each pair is on screen at a time, so the assertion is on the PAIR.
 */
const BREAKPOINT_PAIR = ["Add breakpoint", "Delete breakpoint"];

async function openEditorMenu(page: any) {
  await page.evaluate(() => {
    const c = document.querySelector("#context-menu-container") as HTMLElement | null;
    if (c) {
      c.style.display = "none";
      c.innerHTML = "";
    }
  });

  const lines = page.locator(".view-line");
  await expect(
    lines.first(),
    "no rendered code to right-click; the menu checks would measure nothing",
  ).toBeVisible({ timeout: 60_000 });

  // THE SAME LINE IN BOTH MODES. Index 2 rather than 0 so the click lands in
  // the body of the file rather than on a leading comment or a blank line.
  const target = lines.nth(2);
  const box = await target.boundingBox();
  expect(box, "the code line has no painted box").not.toBeNull();
  const x = box!.x + Math.min(30, box!.width / 2);
  const y = box!.y + box!.height / 2;
  await page.mouse.move(x, y);
  await page.mouse.click(x, y, { button: "right" });

  const menu = new ContextMenu(page);
  await menu.waitForVisible();
  return menu;
}

/**
 * The rows, with the two facts each assertion needs: the name, and whether the
 * row is disabled and why.
 *
 * Read from the DOM of the menu that was actually opened. Never from the
 * compiled `ui.js` — Nim's JS backend emits some string literals as bare
 * char-code arrays, so a text search over the bundle is not a presence test.
 */
async function readRows(page: any) {
  return page.evaluate(() => {
    const container = document.querySelector("#context-menu-container");
    if (!container) return [];
    return Array.from(container.querySelectorAll(".context-menu-item")).map((row) => {
      const label = row.querySelector(".ct-menu-item-label");
      const sub = row.querySelector(".ct-menu-item-sublabel");
      const r = (row as HTMLElement).getBoundingClientRect();
      return {
        name: ((label ? label.textContent : row.textContent) || "").trim(),
        sublabel: ((sub ? sub.textContent : "") || "").trim(),
        disabled: (row as HTMLElement).classList.contains("ct-menu-item--disabled"),
        painted: r.width > 0 && r.height > 0,
      };
    });
  });
}

type Row = { name: string; sublabel: string; disabled: boolean; painted: boolean };

function names(rows: Row[]): string[] {
  return rows.map((r) => r.name);
}

test.describe("The editor context menu follows the mode", () => {
  test.setTimeout(300_000);
  test.use({
    launchMode: "edit",
    editFolderPath: testFolder,
    deploymentMode: "web",
  });

  test("edit mode offers editing commands and no replay commands", async ({
    ctPage,
  }) => {
    await ctPage.waitForSelector(".lm_goldenlayout", { timeout: 60_000 });
    await ctPage.waitForSelector(".view-line", { timeout: 90_000 });

    // ---- EDIT --------------------------------------------------------------
    await openEditorMenu(ctPage);
    const editRows: Row[] = await readRows(ctPage);
    const editNames = names(editRows);

    // NON-VACUITY FIRST. Every absence assertion below would hold of an empty
    // menu, and an empty menu is a different defect wearing this one's clothes.
    expect(
      editRows.length,
      "the Edit-mode menu came up empty, so every 'absent' check below is vacuous",
    ).toBeGreaterThan(2);
    expect(
      editRows.every((r) => r.painted),
      `an Edit-mode row has no painted box: ${JSON.stringify(editRows)}`,
    ).toBe(true);

    for (const entry of [...EDIT_ONLY, ...BOTH]) {
      expect(
        editNames,
        `'${entry}' is missing from the Edit-mode menu, which reads ${JSON.stringify(editNames)}`,
      ).toContain(entry);
    }

    for (const entry of DEBUG_ONLY) {
      expect(
        editNames,
        `'${entry}' is a replay command and it is offered in EDIT mode. ` +
          `The whole Edit-mode menu reads ${JSON.stringify(editNames)}. ` +
          `This is the reported defect: "most of the entries are debug operations".`,
      ).not.toContain(entry);
    }

    expect(
      editNames.some((n) => BREAKPOINT_PAIR.includes(n)),
      `no breakpoint row in Edit mode; breakpoints belong to the project, not ` +
        `to the session (Mode-Transitions.md §5). Menu: ${JSON.stringify(editNames)}`,
    ).toBe(true);

    // EVERY DISABLED ROW SAYS WHY. A disabled row with an empty reason is the
    // defect EMT-D14 names: "an action whose absence cannot be explained is one
    // whose absence was a guess".
    for (const row of editRows.filter((r) => r.disabled)) {
      expect(
        row.sublabel.length,
        `the Edit-mode row '${row.name}' is disabled and carries no reason`,
      ).toBeGreaterThan(0);
    }

    // The hint column is text, rendered with `textContent`. An HTML entity in
    // it reaches the user as the entity — `&lt;click line number gutter&gt;`
    // was on screen until the literals were unescaped.
    for (const row of editRows) {
      expect(
        `${row.name} ${row.sublabel}`,
        `an Edit-mode row prints a raw HTML entity: ${JSON.stringify(row)}`,
      ).not.toMatch(/&(lt|gt|amp);/);
    }

    await ctPage.keyboard.press("Escape");

    // ---- DEBUG -------------------------------------------------------------
    await ctPage.locator("#run-image").click({ timeout: 30_000 });
    await ctPage.waitForSelector(".isonim-debug-controls", { timeout: 180_000 });
    await ctPage.waitForSelector(".view-line", { timeout: 60_000 });

    await openEditorMenu(ctPage);
    const debugRows: Row[] = await readRows(ctPage);
    const debugNames = names(debugRows);

    expect(
      debugRows.length,
      "the Debug-mode menu came up empty",
    ).toBeGreaterThan(2);

    for (const entry of [...DEBUG_ONLY.slice(0, 3), ...BOTH]) {
      // The first three DEBUG_ONLY entries are the line jumps, which are
      // unconditional in Debug mode. The call jumps and the tracepoint rows
      // depend on the token under the cursor and on whether a tracepoint is
      // already on the line, so they are asserted only in the negative above.
      expect(
        debugNames,
        `'${entry}' is missing from the Debug-mode menu, which reads ${JSON.stringify(debugNames)}`,
      ).toContain(entry);
    }

    for (const entry of EDIT_ONLY) {
      expect(
        debugNames,
        `'${entry}' edits the buffer and the Debug-mode editor is read-only, ` +
          `yet it is offered. Menu: ${JSON.stringify(debugNames)}`,
      ).not.toContain(entry);
    }

    expect(
      debugNames.some((n) => BREAKPOINT_PAIR.includes(n)),
      `no breakpoint row in Debug mode. Menu: ${JSON.stringify(debugNames)}`,
    ).toBe(true);

    for (const row of debugRows.filter((r) => r.disabled)) {
      expect(
        row.sublabel.length,
        `the Debug-mode row '${row.name}' is disabled and carries no reason`,
      ).toBeGreaterThan(0);
    }

    // THE TWO MENUS ARE DIFFERENT MENUS, asserted after the per-entry checks
    // rather than instead of them. On its own this cannot fail for its own
    // reason; here it catches the case where both lists were somehow satisfied
    // by one menu carrying everything.
    expect(
      debugNames,
      "the Debug menu is identical to the Edit menu",
    ).not.toEqual(editNames);

    await ctPage.keyboard.press("Escape");

    // ---- BACK TO EDIT ------------------------------------------------------
    //
    // The round trip, because a menu built from a mode read once would be right
    // on the first switch and wrong afterwards — the failure shape the per-mode
    // layout register exists to stop having.
    await ctPage.locator("#stop-image").click({ timeout: 30_000 });
    await ctPage.waitForSelector(".edit-mode-toolbar", { timeout: 180_000 });
    await ctPage.waitForSelector(".view-line", { timeout: 60_000 });

    await openEditorMenu(ctPage);
    const editAgain = names(await readRows(ctPage));

    for (const entry of DEBUG_ONLY) {
      expect(
        editAgain,
        `after a round trip through Debug mode, '${entry}' is back in the ` +
          `Edit-mode menu: ${JSON.stringify(editAgain)}`,
      ).not.toContain(entry);
    }
    expect(
      editAgain,
      `the Edit-mode menu did not come back the same after a visit to Debug ` +
        `mode: ${JSON.stringify(editNames)} -> ${JSON.stringify(editAgain)}`,
    ).toEqual(editNames);
  });
});
