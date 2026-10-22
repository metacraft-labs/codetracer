import { test, expect } from "../../lib/fixtures";
import type { Locator, Page } from "@playwright/test";
import * as helpers from "../../lib/language-smoke-test-helpers";
import { LayoutPage } from "../../page-objects/layout-page";
import { retry } from "../../lib/retry-helpers";

/**
 * Assert the value box is capped at `FLOW_VALUE_LIMIT` (30) `ch`.
 *
 * `toHaveCSS("max-width", "30ch")` can never pass: it compares against
 * `getComputedStyle`, which resolves `ch` to pixels (`"256.765px"` for this
 * chip). So this checks the two things that together mean "capped at 30ch":
 *
 * 1. the inline declaration `ui/flow.nim` writes (`FLOW_VALUE_MAX_WIDTH`) is
 *    exactly `30ch`, and
 * 2. the resolved `max-width` equals 30 × the `ch` of the box's OWN font,
 *    measured by a probe placed inside the box so it inherits that font.
 *    This catches a stylesheet rule that overrides the inline cap.
 *
 * An uncapped box fails both: its inline value is `""` and its computed
 * `max-width` is `none`, which `parseFloat` turns into `NaN`.
 */
async function expectCappedAt30ch(valueBox: Locator): Promise<void> {
  const cap = await valueBox.evaluate((el) => {
    const box = el as HTMLElement;
    const probe = document.createElement("span");
    probe.style.cssText =
      "display:inline-block;position:absolute;visibility:hidden;width:30ch;padding:0;border:0";
    box.appendChild(probe);
    const expectedPx = probe.getBoundingClientRect().width;
    probe.remove();
    return {
      inline: box.style.maxWidth,
      resolvedPx: parseFloat(getComputedStyle(box).maxWidth),
      expectedPx,
    };
  });
  expect(cap.inline).toBe("30ch");
  expect(cap.expectedPx).toBeGreaterThan(0);
  expect(cap.resolvedPx).toBeCloseTo(cap.expectedPx, 0);
}

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
 * about containment. Both are made on overflowing text; see the first test
 * for why that text cannot be the real chip's own.
 */

/**
 * Bring the `test_boards` flow chip on screen and return its parts.
 *
 * `assertFlowValueVisible` is not enough on its own: it also succeeds when
 * the variable appears in the STATE PANE, and it clicks that pane's tab to
 * look. It can therefore return while the chip is not rendered yet, or while
 * it sits in an editor tab the state pane has pushed to the background. Both
 * were measured: one run found no chip in the DOM 3 s after it returned, and
 * another measured the chip's width as 0 before the eye click. So each
 * editor tab is brought forward until the chip is visible.
 */
async function showTestBoardsChip(
  ctPage: Page,
): Promise<{ valueBox: Locator; pill: Locator; viewMoreButton: Locator }> {
  const layout = new LayoutPage(ctPage);
  await layout.waitForBaseComponentsLoaded();

  await helpers.assertFlowValueVisible(ctPage, "test_boards");

  const flowSelector = `span[id*="-test_boards"][class*="flow-parallel-value-box"]`;
  const valueBox = ctPage.locator(flowSelector).first();
  await retry(
    async () => {
      for (const editor of await layout.editorTabs(true)) {
        await editor.clickTab();
        if (await valueBox.isVisible()) {
          return true;
        }
      }
      return false;
    },
    { maxAttempts: 30, delayMs: 1000 },
  );
  await expect(valueBox).toBeVisible();

  const pill = valueBox.locator("..");
  const viewMoreButton = pill.locator(".flow-view-more-button").first();
  return { valueBox, pill, viewMoreButton };
}

test.describe("OmniscienceEyeIcon", () => {
  test.use({ sourcePath: "c_sudoku_solver/main.c", launchMode: "trace" });

  test("test_omniscience_value_is_clipped_to_the_pill", async ({ ctPage }) => {
    const { valueBox, pill, viewMoreButton } = await showTestBoardsChip(ctPage);
    await expect(viewMoreButton).toBeVisible();

    // The cap is applied inline by `ui/flow.nim` for values over
    // FLOW_VALUE_LIMIT (30) characters.
    await expectCappedAt30ch(valueBox);

    // The chip is clipped, not wrapped: these three declarations are what the
    // design-system rewrite (a69766dd) dropped.
    await expect(valueBox).toHaveCSS("white-space", "nowrap");
    await expect(valueBox).toHaveCSS("overflow-x", "hidden");
    await expect(valueBox).toHaveCSS("text-overflow", "ellipsis");

    const lineHeight = await valueBox.evaluate((el) =>
      parseFloat(getComputedStyle(el).lineHeight || "19"),
    );

    // The real chip occupies a single line.
    const pillHeight = await pill.evaluate(
      (el) => el.getBoundingClientRect().height,
    );
    expect(pillHeight).toBeLessThanOrEqual(lineHeight * 1.6);

    // THE regression assertion, on text that is guaranteed to overflow.
    //
    // The real chip's text can no longer overflow on its own: since
    // b723bde4c ("render every value through one presenter") `flowValue`
    // truncates it to `FlowBudget` (FLOW_VALUE_LIMIT = 30 cells), so it fills
    // the 30ch cap exactly (measured: scrollWidth == clientWidth == 257px).
    // An assertion that the REAL chip overflows therefore fails on a correct
    // tree, and the single-line check above passes even with the clipping
    // rules deleted. So the clip is exercised on a clone of the box — same
    // classes, same inline cap, same parent, so the same stylesheet rules
    // apply — given four times the text.
    //
    // Height is read from `scrollHeight`, the height of the CONTENT, not from
    // the bounding box: the chip is a flex item stretched to its row, so its
    // box stays one line tall even when its text wraps onto several. Measured
    // with the clipping declarations overridden on the clone, the box was
    // 18px tall while `scrollWidth == clientWidth` — wrapped, not clipped.
    const clone = await valueBox.evaluate((el) => {
      const copy = el.cloneNode(true) as HTMLElement;
      copy.removeAttribute("id");
      copy.textContent = (el.textContent ?? "").repeat(4);
      el.after(copy);
      const result = {
        textLength: copy.textContent.length,
        scrollWidth: copy.scrollWidth,
        clientWidth: copy.clientWidth,
        contentHeight: copy.scrollHeight,
      };
      copy.remove();
      return result;
    });
    // CONTROL: the clone's text really is longer than the cap.
    expect(clone.textLength).toBeGreaterThan(30 * 2);
    expect(clone.scrollWidth).toBeGreaterThan(clone.clientWidth);
    expect(clone.contentHeight).toBeLessThanOrEqual(lineHeight * 1.6);
  });

  test("test_omniscience_eye_icon_opens_typed_value_popup", async ({
    ctPage,
  }) => {
    const { valueBox, viewMoreButton } = await showTestBoardsChip(ctPage);

    const widthBefore = await valueBox.evaluate(
      (el) => el.getBoundingClientRect().width,
    );
    // CONTROL: a box that is not laid out measures 0 before AND after, and
    // the "did not grow" assertion below would pass on it whatever happened.
    expect(widthBefore).toBeGreaterThan(0);

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

    // The popup was opened by a click, so it must stay open once the pointer
    // leaves the eye button, and close on a press outside it. This does NOT
    // tell `trigger: "manual"` from tippy's default hover trigger: an
    // instance shown with `.show()` under the default trigger also stays
    // open here, because the pointer never entered its anchor and so never
    // leaves it (measured 2026-10-22 by building `displayTooltip` without the
    // manual trigger; this test still passed).
    await ctPage.mouse.move(1, 1);
    await expect(popup).toBeVisible();

    // And the chip itself did NOT grow: opening the full value must not
    // un-cap the box. This is the specific behaviour that was removed.
    const widthAfter = await valueBox.evaluate(
      (el) => el.getBoundingClientRect().width,
    );
    expect(widthAfter).toBeCloseTo(widthBefore, 0);
    await expectCappedAt30ch(valueBox);

    await ctPage.mouse.click(1, 1);
    await expect(ctPage.locator("[data-tippy-root]")).toHaveCount(0);
  });
});
