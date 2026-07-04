import { test, expect } from "../../lib/fixtures";
import * as helpers from "../../lib/language-smoke-test-helpers";
import { LayoutPage } from "../../page-objects/layout_page";

test.describe("OmniscienceEyeIcon", () => {
  test.use({ sourcePath: "c_sudoku_solver/main.c", launchMode: "trace" });

  test("test_omniscience_eye_icon", async ({ ctPage }) => {
    const layout = new LayoutPage(ctPage);
    await layout.waitForBaseComponentsLoaded();

    // Step until the `test_boards` flow value is visible
    await helpers.assertFlowValueVisible(ctPage, "test_boards");

    // The value container for `test_boards`
    const flowSelector = `span[id*="-test_boards"][class*="flow-parallel-value-box"]`;
    const valueBox = ctPage.locator(flowSelector).first();

    // The parent ct-omni-value should have the view-more button
    const viewMoreButton = valueBox.locator("..").locator(".flow-view-more-button").first();

    await expect(viewMoreButton).toBeVisible();

    // 1. Initial state: shown collapsed (max-width: 50ch) and eye icon is 'flow-hide-content'
    await expect(valueBox).toHaveCSS("max-width", "50ch");
    await expect(viewMoreButton).toHaveClass(/flow-hide-content/);

    // 2. Click to expand
    await viewMoreButton.click();
    await expect(valueBox).toHaveCSS("max-width", "none");
    await expect(viewMoreButton).toHaveClass(/flow-show-content/);

    // 3. Click to collapse
    await viewMoreButton.click();
    await expect(valueBox).toHaveCSS("max-width", "50ch");
    await expect(viewMoreButton).toHaveClass(/flow-hide-content/);
  });
});
