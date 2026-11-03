/**
 * ESC CLOSES AN OPEN DROPDOWN, WHEREVER THE FOCUS IS (docs/UI-Design-Decisions.md, D-21).
 *
 * The key router's listener runs before every other one. With the focus on a
 * pane, it resolved Esc to the pane's `list.clear-selection` and stopped the
 * event, so the Filter dropdown's own Esc handler never ran, and the Columns
 * menu stayed open after a click on a column name, which moves the focus from
 * the menu to the panel behind it.
 *
 * WHAT IS ASSERTED:
 *   - each dropdown closes on Esc, after each way of using it;
 *   - the router runs no operation for that Esc (`__ctKeyTrace`), so the key
 *     does not also clear the list's selection.
 *
 * CONTROLS, because each assertion is vacuous without one:
 *   - each dropdown is asserted open before Esc is pressed;
 *   - with nothing open, Esc on the pane must still run `list.clear-selection`,
 *     or "the router ran nothing" would also pass with a router that lost Esc.
 */

import type { Locator, Page } from "@playwright/test";
import { test, expect } from "../../lib/fixtures";
import { LayoutPage } from "../../page-objects/layout-page";

test.use({ sourcePath: "py_long_event_log/main.py", launchMode: "trace" });
test.setTimeout(300_000);

/** Press Esc and return the operations the key router ran for it. */
async function pressEscape(page: Page): Promise<string[]> {
  await page.evaluate(() => {
    (window as unknown as { __ctKeyTrace: string[] }).__ctKeyTrace = [];
  });
  await page.keyboard.press("Escape");
  return page.evaluate(() => (window as unknown as { __ctKeyTrace: string[] }).__ctKeyTrace);
}

async function expectEscapeCloses(page: Page, list: Locator): Promise<void> {
  await expect(list).toBeVisible();
  expect(await pressEscape(page)).toEqual([]);
  await expect(list).toBeHidden();
}

test("Esc closes the Event Log's dropdowns, wherever the focus is", async ({ ctPage }) => {
  const layout = new LayoutPage(ctPage);
  await layout.waitForEventLogLoaded();
  await (await layout.eventLogTabs())[0].clickTab();

  const columnsButton = ctPage.locator(".eventLog-columns-button").first();
  const columnsMenu = ctPage.locator(".eventLog-columns-menu").first();

  await test.step("Columns, straight after opening", async () => {
    await columnsButton.click();
    await expectEscapeCloses(ctPage, columnsMenu);
    await expect(columnsButton).toBeFocused();
  });

  await test.step("Columns, after clicking a column name", async () => {
    await columnsButton.click();
    const title = columnsMenu.locator(".eventLog-column-title").nth(1);
    await title.click();
    await title.click(); // back as it was
    await expectEscapeCloses(ctPage, columnsMenu);
    await expect(columnsButton).toBeFocused();
  });

  await test.step("Columns, after clicking its background", async () => {
    await columnsButton.click();
    const box = await columnsMenu.boundingBox();
    if (box === null) throw new Error("the Columns menu has no box");
    await ctPage.mouse.click(box.x + box.width - 3, box.y + 2);
    await expectEscapeCloses(ctPage, columnsMenu);
  });

  await test.step("Columns, key-focus is on the row, even in a menu the mouse opened (D-23)", async () => {
    await ctPage.mouse.move(0, 0);
    await columnsButton.click();
    await expect(columnsMenu).toBeVisible();
    const row = columnsMenu.locator(".eventLog-column-option").nth(1);
    await ctPage.keyboard.press("ArrowDown");
    await expect(row.locator(".eventLog-column-check")).toBeFocused();
    await expect(row).toHaveCSS("outline-style", "solid");
    await expect(row.locator(".eventLog-column-check")).toHaveCSS("outline-style", "none");
    await ctPage.keyboard.press("ArrowRight");
    await expect(row.locator(".eventLog-column-handle")).toHaveCSS("outline-style", "solid");
    await expect(row).toHaveCSS("outline-style", "none");
    await ctPage.keyboard.press("Escape");
    await expect(columnsMenu).toBeHidden();
  });

  await test.step("Filter", async () => {
    await ctPage.locator(".eventLog #category-image").first().click();
    await expectEscapeCloses(ctPage, ctPage.locator("#category-image-list"));
  });

  await test.step("control: with nothing open, Esc is still the pane's", async () => {
    await ctPage.locator(".eventLog").first().focus();
    expect(await pressEscape(ctPage)).toContain("list.clear-selection");
  });
});
