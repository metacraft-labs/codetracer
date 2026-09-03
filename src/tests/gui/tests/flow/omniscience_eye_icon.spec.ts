import { test, expect } from "../../lib/fixtures";
import * as helpers from "../../lib/language-smoke-test-helpers";
import { LayoutPage } from "../../page-objects/layout_page";

/**
 * The omniscience/flow value chip must CLIP, and the eye icon must open the
 * full value in a popup drawn by the typed value renderer.
 *
 * What this file used to assert, and why it was wrong
 * ---------------------------------------------------
 * The previous version asserted that clicking the eye icon set
 * `max-width: none` on the value box, and that clicking again restored
 * `50ch`. That *was* the implementation, and it is exactly the reported
 * defect: un-capping the box lets a long value draw outside the chip and
 * over the source lines beneath it. (The `50ch` in the old assertion had
 * also gone stale — `FLOW_VALUE_LIMIT` is 30, so the cap is `30ch`.)
 *
 * The trap in the obvious assertion
 * ---------------------------------
 * "The pill's box contains the text's box" PASSES on the broken tree, and is
 * therefore worthless as a regression check. The failure was never the text
 * escaping horizontally: with `max-width: 30ch` and no `white-space: nowrap`,
 * the text WRAPPED inside the narrowed box and the box itself grew downward.
 * Measured on the real compiled stylesheet, the chip was 45px tall — nearly
 * two and a half 19px editor lines — while still "containing" its text.
 *
 * So the load-bearing assertion is about HEIGHT (the chip occupies one line)
 * and about the clip actually engaging (`scrollWidth > clientWidth`), not
 * about containment.
 */
test.describe("OmniscienceEyeIcon", () => {
  test.use({ sourcePath: "c_sudoku_solver/main.c", launchMode: "trace" });

  test("test_omniscience_value_is_clipped_to_the_pill", async ({ ctPage }) => {
    const layout = new LayoutPage(ctPage);
    await layout.waitForBaseComponentsLoaded();

    await helpers.assertFlowValueVisible(ctPage, "test_boards");

    const flowSelector = `span[id*="-test_boards"][class*="flow-parallel-value-box"]`;
    const valueBox = ctPage.locator(flowSelector).first();
    const pill = valueBox.locator("..");

    const viewMoreButton = pill.locator(".flow-view-more-button").first();
    await expect(viewMoreButton).toBeVisible();

    // The cap is applied inline by `ui/flow.nim` for values over
    // FLOW_VALUE_LIMIT (30) characters.
    await expect(valueBox).toHaveCSS("max-width", "30ch");

    // CONTROL: this value must actually be long enough to overflow, or every
    // assertion below is vacuous — a short value is trivially "clipped".
    const metrics = await valueBox.evaluate((el) => ({
      scrollWidth: el.scrollWidth,
      clientWidth: el.clientWidth,
      height: el.getBoundingClientRect().height,
    }));
    expect(metrics.scrollWidth).toBeGreaterThan(metrics.clientWidth);

    // The chip is clipped, not wrapped: these three declarations are what the
    // design-system rewrite (a69766dd) dropped.
    await expect(valueBox).toHaveCSS("white-space", "nowrap");
    await expect(valueBox).toHaveCSS("overflow-x", "hidden");
    await expect(valueBox).toHaveCSS("text-overflow", "ellipsis");

    // THE regression assertion: the chip occupies a single line. On the
    // broken tree this was ~2.4 lines and the excess drew over the code.
    const pillHeight = await pill.evaluate(
      (el) => el.getBoundingClientRect().height,
    );
    const lineHeight = await valueBox.evaluate((el) =>
      parseFloat(getComputedStyle(el).lineHeight || "19"),
    );
    expect(pillHeight).toBeLessThanOrEqual(lineHeight * 1.6);
  });

  test("test_omniscience_eye_icon_opens_typed_value_popup", async ({
    ctPage,
  }) => {
    const layout = new LayoutPage(ctPage);
    await layout.waitForBaseComponentsLoaded();

    await helpers.assertFlowValueVisible(ctPage, "test_boards");

    const flowSelector = `span[id*="-test_boards"][class*="flow-parallel-value-box"]`;
    const valueBox = ctPage.locator(flowSelector).first();
    const pill = valueBox.locator("..");
    const viewMoreButton = pill.locator(".flow-view-more-button").first();

    const widthBefore = await valueBox.evaluate(
      (el) => el.getBoundingClientRect().width,
    );

    await viewMoreButton.click();

    // The popup is a tippy instance appended to document.body.
    const popup = ctPage.locator("[data-tippy-root]").first();
    await expect(popup).toBeVisible();

    // It renders the TYPED visualisation — the same `ui/value.nim`
    // `renderValueDom` markup the value tree uses elsewhere — rather than a
    // bare string. `.value-expanded-text` + `.value-type` only exist on the
    // typed renderer's output; a `textContent` check would pass on a string.
    await expect(popup.locator(".value-expanded-text").first()).toBeVisible();
    await expect(popup.locator(".value-type").first()).toBeVisible();

    // And the chip itself did NOT grow: opening the full value must not
    // un-cap the box. This is the specific behaviour that was removed.
    const widthAfter = await valueBox.evaluate(
      (el) => el.getBoundingClientRect().width,
    );
    expect(widthAfter).toBeCloseTo(widthBefore, 0);
    await expect(valueBox).toHaveCSS("max-width", "30ch");
  });
});
