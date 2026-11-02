/**
 * The eye icon and the hover popup on a chip that shows a value BEFORE and
 * AFTER its line (`BeforeAndAfterValueMode`, "dual" mode).
 *
 * `ui/flow.nim` draws dual mode whenever a line changes the value, so it is
 * the common case, not a corner. `omniscience_eye_icon.spec.ts` covers the
 * single-value chip; this file covers the dual one, which failed separately:
 * the two value boxes were given SPACE-SEPARATED two-token ids
 * (`…-readings-after flow-…-readings`), and both the eye button and the hover
 * popup found their box with a `#<id>` selector. With a space that selector
 * is a DESCENDANT selector, matched nothing, and tippy silently attached no
 * popup — so in dual mode neither the eye icon nor hovering opened anything.
 *
 * Fixture: `test-programs/noir_flow_dual_value`, whose `readings` array
 * changes on two consecutive lines. Twelve elements render far past the
 * 30-cell chip budget, so those chips carry the eye icon. It is a Noir program
 * because the trace must produce flow chips: the C sudoku fixture the
 * single-value spec uses draws exactly one chip, and the JavaScript recorder
 * produced none for an equivalent program (both measured 2026-10-22). It is
 * recorded by `nargo`; when that is absent the suite skips with a reason.
 *
 * No mocks: the real recorder, the real Electron app and real tippy popups.
 */
import * as path from "node:path";

import { test, expect } from "../../lib/fixtures";
import type { Locator, Page } from "@playwright/test";
import { LayoutPage } from "../../page-objects/layout-page";
import { retry } from "../../lib/retry-helpers";
import { hasNargo } from "../../lib/noir-recorder";

const repoRoot = path.resolve(__dirname, "..", "..", "..", "..", "..");
const fixtureDir = path.join(repoRoot, "test-programs", "noir_flow_dual_value");

/** Lines of `fn main` in test-programs/noir_flow_dual_value/src/main.nr. */
const MAIN_FIRST_LINE = 6;
const MAIN_LAST_LINE = 10;

/** Where the debugger currently is, as the frontend sees it. */
async function debuggerLine(ctPage: Page): Promise<number> {
  return await ctPage.evaluate(() => {
    const w = window as any; // eslint-disable-line @typescript-eslint/no-explicit-any
    return Number(w.data?.services?.debugger?.location?.line ?? -1);
  });
}

/**
 * Open `main.nr`, step into `main` (the flow is computed for the function the
 * debugger is stopped in) and return the first dual-mode `readings` chip.
 */
async function showDualReadingsChip(ctPage: Page): Promise<{
  beforeBox: Locator;
  afterBox: Locator;
  viewMoreButton: Locator;
}> {
  const layout = new LayoutPage(ctPage);
  await layout.waitForTraceLoaded();
  await layout.waitForEditorLoaded();

  let editor: Awaited<ReturnType<LayoutPage["editorTabs"]>>[number] | undefined;
  await retry(
    async () => {
      const tabs = await layout.editorTabs(true);
      editor = tabs.find((t) => t.tabButtonText.toLowerCase().includes("main.nr"));
      return Boolean(editor);
    },
    { maxAttempts: 60, delayMs: 1000 },
  );
  if (!editor) throw new Error("main.nr editor tab is not open");
  await editor.tabButton().click();
  await expect(editor.root.locator(".monaco-editor")).toBeVisible({ timeout: 30_000 });

  await retry(
    async () => {
      const line = await debuggerLine(ctPage);
      if (line >= MAIN_FIRST_LINE && line <= MAIN_LAST_LINE) return true;
      await layout.clickStepInButton();
      return false;
    },
    { maxAttempts: 40, delayMs: 500 },
  );

  // The dual chip: its first value box carries `flow-dual-value-before`.
  // Located by class and by the `-readings` id substring, not by the full
  // id, so the test does not restate the id scheme it is checking.
  const beforeBox = ctPage
    .locator('[id*="-readings"].flow-dual-value-before')
    .first();
  await expect(beforeBox).toBeVisible({ timeout: 60_000 });
  const pill = beforeBox.locator("..");
  const afterBox = pill
    .locator('[class*="flow-parallel-value-box"]:not(.flow-dual-value-before)')
    .first();
  const viewMoreButton = pill.locator(".flow-view-more-button").first();
  await expect(afterBox).toBeVisible();
  // CONTROL: the value is long enough for the chip to carry the eye icon.
  await expect(viewMoreButton).toBeVisible();
  return { beforeBox, afterBox, viewMoreButton };
}

/** Assert the open popup is drawn by the TYPED value renderer. */
async function expectTypedPopup(ctPage: Page): Promise<void> {
  const popup = ctPage.locator("[data-tippy-root]").first();
  await expect(popup).toBeVisible();
  // `.value-expanded-text` + `.value-type` only exist on `ui/value.nim`'s
  // typed renderer output; a `textContent` check would pass on a string.
  await expect(popup.locator(".value-expanded-text").first()).toBeVisible();
  await expect(popup.locator(".value-type").first()).toBeVisible();
}

test.describe("OmniscienceEyeIconDual", () => {
  test.setTimeout(240_000);
  test.skip(
    !hasNargo(),
    "requires the Noir recorder (`nargo`), which is not on PATH — see the " +
      "spec header for why this fixture is a Noir program",
  );
  test.use({ sourcePath: fixtureDir, launchMode: "trace" });

  test("test_dual_chip_eye_icon_opens_typed_value_popup", async ({ ctPage }) => {
    const { afterBox, viewMoreButton } = await showDualReadingsChip(ctPage);

    await viewMoreButton.click();
    await expectTypedPopup(ctPage);

    // The eye opens the AFTER value, so its popup belongs to the after box.
    const anchoredOnAfterBox = await afterBox.evaluate(
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
      (el) => Boolean((el as any)._tippy?.state?.isVisible),
    );
    expect(anchoredOnAfterBox).toBe(true);

    // A press outside closes it.
    await ctPage.mouse.click(1, 1);
    await expect(ctPage.locator("[data-tippy-root]")).toHaveCount(0);
  });

  test("test_dual_chip_hover_opens_typed_value_popup", async ({ ctPage }) => {
    const { beforeBox, afterBox } = await showDualReadingsChip(ctPage);

    // Both halves: each value box hovers its own value.
    for (const box of [beforeBox, afterBox]) {
      await box.hover();
      await expectTypedPopup(ctPage);
      // Leaving the box hides a hover popup.
      await ctPage.mouse.move(1, 1);
      await expect(ctPage.locator("[data-tippy-root]")).toHaveCount(0);
    }
  });
});
