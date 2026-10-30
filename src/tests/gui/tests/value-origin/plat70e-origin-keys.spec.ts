/**
 * PLAT-70 Part E: value origin from the keyboard on the desktop
 * (Variable-State-Pane.md § Value origin from the keyboard).
 *
 * Verifies, on the real app and a real recording:
 *   - with a variable of the Variables pane focused (a press on its value),
 *     `Ctrl+Shift+O` shows its value origin as the row's menu entry "Show
 *     value origin" (K28) and its badge (K41) do: the chain expands in place
 *     under the row, the side panel stays closed, and the recording does not
 *     move; again closes it;
 *   - the application key (`ContextMenu`, the `Menu` chord) opens the
 *     focused row's own menu, which offers "Show value origin";
 *   - in Debug mode, `Ctrl+K Shift+F10` opens the same menu, while
 *     `Shift+F10` alone stays reverse step over.
 *
 * No mocks: the `simple_trivial_chain` program recorded by the real Python
 * recorder through `ct record`, opened by the real Electron app.
 */
import { expect, test } from "../../lib/fixtures";
import { LayoutPage } from "../../page-objects/layout-page";
import { OriginChainPanePageObject } from "../../page-objects/originChainPane";
import {
  originFixturePath,
  pythonSpecSkipReason,
} from "../../lib/value-origin-fixtures";

const fixtureSource = originFixturePath("python", "simple_trivial_chain");

test.use({ sourcePath: fixtureSource, launchMode: "trace" });
test.setTimeout(240_000);

test.beforeAll(() => {
  const reason = pythonSpecSkipReason();
  test.skip(reason !== null, reason ?? "");
});

/** The status bar's position — the recording's place, which must not move
 *  (read from the DOM: the readout is hidden, its text is current). */
async function position(page: import("@playwright/test").Page): Promise<string> {
  return (await page.locator(".location-path").first().textContent()) ?? "";
}

/** A menu opened by the keys: the row menu's "Show value origin" entry. */
function showOriginEntry(page: import("@playwright/test").Page) {
  return page.locator("text=Show value origin").first();
}

test("Ctrl+Shift+O, the Menu key and Ctrl+K Shift+F10 on a focused variable", async ({ ctPage }) => {
  const layout = new LayoutPage(ctPage);
  // `waitForTraceLoaded`, not `readyOnEntry`: the status bar's location
  // readout is hidden on purpose for now (status_bar.styl), and
  // `readyOnEntry` waits for it to be visible.
  await layout.waitForBaseComponentsLoaded();
  await layout.waitForTraceLoaded();
  const origin = new OriginChainPanePageObject(ctPage);

  // ---- To the `print(c)` line, where `c` has an origin -------------------
  await layout.runToEntryButton().click();
  await ctPage.waitForTimeout(750);
  const statePane = (await layout.programStateTabs(true))[0];
  expect(statePane, "State Pane must be present").toBeDefined();
  let cVisible = (await statePane.variableValueText("c")) !== "";
  for (let i = 0; i < 12 && !cVisible; i++) {
    await layout.nextButton().click();
    await ctPage.waitForTimeout(500);
    cVisible = (await statePane.variableValueText("c")) !== "";
  }
  expect(cVisible, "stepping to the print(c) line must surface local `c`").toBe(true);

  // ---- Focus `c`: a press on its value ----------------------------------
  const value = ctPage.locator('[data-ct-cell="variables|c|value"]').first();
  await value.click();
  await ctPage.waitForTimeout(300);
  const before = await position(ctPage);
  const badgeShown = await origin.badge("c").isVisible();

  // ---- Ctrl+Shift+O: the chain under the row, as the row menu's "Show
  // value origin" and the badge show it (in place; the side panel stays
  // closed, one press away in the chain itself) ---------------------------
  await ctPage.keyboard.press("Control+Shift+O");
  await expect(origin.inlineChain("c"), "the chain under the row").toBeVisible({ timeout: 15_000 });
  if (badgeShown) {
    await expect(origin.expandedChainHops("c").first()).toBeVisible({ timeout: 15_000 });
  }
  await expect(origin.sidePanel(), "no side panel").toBeHidden();
  // Again closes it, as the menu entry does.
  await value.click();
  await ctPage.keyboard.press("Control+Shift+O");
  await expect(origin.inlineChain("c")).toBeHidden({ timeout: 15_000 });
  expect(await position(ctPage), "the recording did not move").toBe(before);

  // ---- The Menu key: the row's own menu ----------------------------------
  await value.click();
  await ctPage.keyboard.press("ContextMenu");
  await expect(showOriginEntry(ctPage), "Menu opens the row menu").toBeVisible({ timeout: 10_000 });
  await ctPage.keyboard.press("Escape");
  await expect(showOriginEntry(ctPage)).toBeHidden({ timeout: 10_000 });

  // ---- Debug mode: Ctrl+K Shift+F10 opens it; Shift+F10 steps back ------
  await value.click();
  await ctPage.keyboard.press("Control+KeyK");
  await ctPage.keyboard.press("Shift+F10");
  await expect(showOriginEntry(ctPage), "Ctrl+K Shift+F10 opens the row menu").toBeVisible({ timeout: 10_000 });
  await ctPage.keyboard.press("Escape");
  await expect(showOriginEntry(ctPage)).toBeHidden({ timeout: 10_000 });
  const atC = await position(ctPage);
  await value.click();
  await ctPage.keyboard.press("Shift+F10");
  await expect.poll(() => position(ctPage), {
    message: "Shift+F10 alone is reverse step over in Debug mode", timeout: 20_000,
  }).not.toBe(atC);
  await expect(showOriginEntry(ctPage)).toBeHidden();
});
