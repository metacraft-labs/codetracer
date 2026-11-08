/**
 * The pointer's shape on the desktop (Pointer-Affordances.md §4; PA-1, PA-2's
 * desktop half), and a click on a hop row.
 *
 * Verifies, on the real app and a real recording: the computed `cursor` of each
 * element kind equals the table, because its `data-pointer` came from the
 * shared function; and a click anywhere on a hop of a row's origin chain moves
 * the recording, as `Enter` on it does on the native front-ends.
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

async function position(page: import("@playwright/test").Page): Promise<string> {
  return (await page.locator(".location-path").first().textContent()) ?? "";
}

test("each element kind's computed cursor comes from the shared function", async ({ ctPage }) => {
  const skip = pythonSpecSkipReason();
  test.skip(skip !== null, skip ?? "");
  const layout = new LayoutPage(ctPage);
  await layout.waitForBaseComponentsLoaded();
  await layout.waitForTraceLoaded();

  // A selector this engine refuses is dropped, and counted here.
  await expect(ctPage.locator("html")).toHaveAttribute("data-pointer-refused", "0");

  const shapes: Array<[string, string]> = [
    [".lm_splitter:not(.lm_vertical)", "col-resize"],
    [".lm_splitter.lm_vertical", "row-resize"],
    [".lm_tab .lm_close_tab", "pointer"],
    ["button:disabled", "not-allowed"],
  ];
  for (const [selector, shape] of shapes) {
    const element = ctPage.locator(selector).first();
    if ((await element.count()) === 0) continue;
    await expect(element, `${selector} carries the shape`).toHaveAttribute("data-pointer", shape);
    const computed = await element.evaluate((e) => getComputedStyle(e).cursor);
    expect(computed, selector).toBe(shape);
  }
});

test("the gesture's shape holds on the body while a divider is held", async ({ ctPage }) => {
  const skip = pythonSpecSkipReason();
  test.skip(skip !== null, skip ?? "");
  const layout = new LayoutPage(ctPage);
  await layout.waitForBaseComponentsLoaded();
  await layout.waitForTraceLoaded();
  const splitter = ctPage.locator(".lm_splitter:not(.lm_vertical)").first();
  const box = await splitter.boundingBox();
  expect(box).not.toBeNull();
  await ctPage.mouse.move(box!.x + box!.width / 2, box!.y + box!.height / 2);
  await ctPage.mouse.down();
  await expect(ctPage.locator("body")).toHaveAttribute("data-pointer-gesture", "col-resize");
  const elsewhere = await ctPage.locator(".lm_tab").first()
    .evaluate((e) => getComputedStyle(e).cursor);
  expect(elsewhere).toBe("col-resize");
  await ctPage.mouse.up();
  await expect(ctPage.locator("body")).not.toHaveAttribute("data-pointer-gesture", /.*/);
});

test("a click on a hop of the chain under the row moves the recording", async ({ ctPage }) => {
  const skip = pythonSpecSkipReason();
  test.skip(skip !== null, skip ?? "");
  const layout = new LayoutPage(ctPage);
  await layout.waitForBaseComponentsLoaded();
  await layout.waitForTraceLoaded();
  const origin = new OriginChainPanePageObject(ctPage);
  await layout.runToEntryButton().click();
  await ctPage.waitForTimeout(750);
  const statePane = (await layout.programStateTabs(true))[0];
  let cVisible = (await statePane.variableValueText("c")) !== "";
  for (let i = 0; i < 12 && !cVisible; i++) {
    await layout.nextButton().click();
    await ctPage.waitForTimeout(500);
    cVisible = (await statePane.variableValueText("c")) !== "";
  }
  expect(cVisible, "stepping to the print(c) line must surface local `c`").toBe(true);
  const value = ctPage.locator('[data-ct-cell="variables|c|value"]').first();
  await expect(value).toBeVisible({ timeout: 30_000 });
  await value.click();
  await ctPage.keyboard.press("Control+Shift+O");
  await expect(origin.inlineChain("c")).toBeVisible({ timeout: 15_000 });
  const hop = origin.expandedChainHops("c").first();
  await expect(hop).toBeVisible({ timeout: 15_000 });
  await expect(hop).toHaveAttribute("data-pointer", "pointer");
  const before = await position(ctPage);
  await hop.click();
  await expect.poll(() => position(ctPage), { timeout: 30_000 }).not.toBe(before);
});
