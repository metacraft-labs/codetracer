/**
 * Strip layout verification — captures screenshots to confirm:
 *   1. Left strip is BESIDE GL (GL content starts after the strip, no overlap)
 *   2. Bottom labels are IN the status bar footer (not a separate strip)
 *   3. GL container shrinks when strips have tabs
 *
 * No mocks: a real JavaScript recording opened by the real Electron app.  The
 * strips and their standalone panes are built by `layout.nim` identically for
 * every recorded language — see `lib/js-trace-fixture.ts`.
 */
import { test, expect } from "../../lib/fixtures";
import { recordChromeTraceFixture } from "../../lib/js-trace-fixture";
import { LayoutPage } from "../../page-objects/layout-page";
import {
  BOTTOM_STRIP_IN_FOOTER_SELECTOR,
  DEFAULT_BOTTOM_TAB_COUNT,
  bottomStripTabs,
  waitForDefaultBottomTabs,
} from "../../page-objects/auto-hide-strip";

const DIR = "/tmp/strip-layout-verify";
const wait = (ms: number) => new Promise(r => setTimeout(r, ms));

// Helper: pin via JS (avoids dropdown blur race)
async function pinToEdge(
  page: import("@playwright/test").Page,
  edge: string,
  stackIndex: number,
) {
  const stacks = page.locator(".lm_stack");
  const stack = stacks.nth(stackIndex);
  const toggle = stack.locator(".layout-buttons-container").first();
  await toggle.click();
  await wait(300);
  await page.evaluate(
    ([e, idx]) => {
      const stacks = document.querySelectorAll(".lm_stack");
      const s = stacks[Number(idx)];
      if (!s) return;
      for (const item of s.querySelectorAll(".layout-dropdown-node")) {
        if (item.textContent?.trim() === `Pin to ${e}`) {
          (item as HTMLElement).click();
          return;
        }
      }
    },
    [edge, String(stackIndex)],
  );
  await wait(1500);
}

const fixture = recordChromeTraceFixture("strip-layout-verify");

test.describe("Strip layout verification", () => {
  test.setTimeout(120_000);
  test.use({ sourcePath: fixture.traceDir, launchMode: "trace-folder" });

  // Was marked FAILING (2026-05-01) with "after `pinToEdge(\"Left\", 0)` the
  // strip's `has-tabs` class is set but the strip is empty / zero-width".
  // That note is retired: this test passes.  It could not have been observed
  // failing for that reason after the status-bar redesign, because the file
  // could not run at all — it recorded `py_console_logs/main.py` and needed
  // the Python recorder.  It now records through `lib/js-trace-fixture.ts`.
  test("strips tile with GL, bottom tabs in status bar", async ({ ctPage }) => {
    const layout = new LayoutPage(ctPage);
    await layout.waitForAllComponentsLoaded();
    await layout.waitForTraceLoaded();
    await wait(1000);

    // Force collapsed mode OFF before pinning.  Under Xvfb the heuristic
    // in `updateCollapsedMode` (layout.nim ~880) thinks the window is
    // maximized (Xvfb's virtual display matches the Electron window
    // size, so `window.outerWidth >= screen.availWidth - 8` is true).
    // That puts the auto-hide strip into the 1px collapsed-mode
    // rendering instead of the 28px text-tab strip this test asserts
    // on.  See same pattern in comprehensive-v2.spec.ts Screen 6.
    await ctPage.evaluate(() => {
      const f = (window as any).__ctForceCollapsedMode;
      if (typeof f === "function") f(false);
    });
    await wait(200);

    // --- Baseline: no strips, capture initial GL width ---
    const rootBefore = await ctPage.evaluate(() => {
      const el = document.getElementById("ROOT");
      return el ? el.getBoundingClientRect() : null;
    });
    expect(rootBefore).toBeTruthy();

    await ctPage.screenshot({ path: `${DIR}/01-baseline-no-strips.png` });

    // --- Pin a panel to the LEFT edge ---
    await pinToEdge(ctPage, "Left", 0);

    // Verify left strip has the "has-tabs" class (width > 0).
    const leftStrip = ctPage.locator("#auto-hide-strip-left");
    await expect(leftStrip).toHaveClass(/has-tabs/, { timeout: 5_000 });

    // Measure: left strip should be ~28px wide and GL should have shrunk.
    const leftStripBox = await leftStrip.boundingBox();
    expect(leftStripBox).toBeTruthy();
    expect(leftStripBox!.width).toBeGreaterThanOrEqual(20);
    expect(leftStripBox!.width).toBeLessThanOrEqual(40);

    const rootAfterLeft = await ctPage.evaluate(() => {
      const el = document.getElementById("ROOT");
      return el ? el.getBoundingClientRect() : null;
    });
    expect(rootAfterLeft).toBeTruthy();

    // KEY CHECK: GL container (ROOT) should be narrower after left strip appears.
    // The left strip should be to the left of ROOT (no overlap).
    expect(rootAfterLeft!.width).toBeLessThan(rootBefore!.width);
    expect(rootAfterLeft!.x).toBeGreaterThanOrEqual(
      leftStripBox!.x + leftStripBox!.width - 1, // allow 1px rounding
    );

    await ctPage.screenshot({ path: `${DIR}/02-left-strip-beside-gl.png` });

    // --- Pin another panel to the BOTTOM edge ---
    //
    // Take the baseline BEFORE pinning.  The strip already carries the
    // standalone BUILD / PROBLEMS / SEARCH RESULTS panes that `layout.nim`
    // registers at boot, so "how many tabs are there afterwards" is only
    // meaningful against a settled starting point.  The previous
    // `>= 1` assertion was written when the strip's tabs lived inside the
    // wrapper element the status-bar redesign removed (named by
    // `RETIRED_BOTTOM_TABS_SELECTOR` in `page-objects/auto-hide-strip.ts`),
    // so it was counting the children of an element that no longer exists.
    await waitForDefaultBottomTabs(ctPage);
    const bottomTabItems = bottomStripTabs(ctPage);
    const tabsBeforePin = await bottomTabItems.count();

    await pinToEdge(ctPage, "Bottom", 0);

    // Verify the bottom strip is inside #status-base (the footer), per
    // Auto-Hide-Panes.md §3.1.
    const bottomTabs = ctPage.locator(BOTTOM_STRIP_IN_FOOTER_SELECTOR);
    await expect(bottomTabs).toBeVisible({ timeout: 5_000 });

    // Pinning one panel to the bottom edge adds exactly one tab to the
    // strip's standalone panes.
    await expect(bottomTabItems).toHaveCount(tabsBeforePin + 1, {
      timeout: 5_000,
    });
    expect(
      tabsBeforePin,
      "the standalone bottom panes are the strip's baseline",
    ).toBe(DEFAULT_BOTTOM_TAB_COUNT);

    // Verify there is NO separate .auto-hide-strip-bottom element.
    const oldBottomStrip = ctPage.locator(".auto-hide-strip-bottom");
    await expect(oldBottomStrip).toHaveCount(0);

    // Measure: bottom tabs should be within the status bar bounds.
    const statusBar = ctPage.locator("#status-base");
    const statusBox = await statusBar.boundingBox();
    const bottomTabsBox = await bottomTabs.boundingBox();
    expect(statusBox).toBeTruthy();
    expect(bottomTabsBox).toBeTruthy();
    // Bottom tabs should be vertically inside the status bar.
    expect(bottomTabsBox!.y).toBeGreaterThanOrEqual(statusBox!.y - 1);
    expect(bottomTabsBox!.y + bottomTabsBox!.height).toBeLessThanOrEqual(
      statusBox!.y + statusBox!.height + 1,
    );

    await ctPage.screenshot({
      path: `${DIR}/03-bottom-tabs-in-status-bar.png`,
    });

    // --- Final screenshot showing both strips active ---
    await ctPage.screenshot({
      path: `${DIR}/04-both-strips-active.png`,
    });

    console.log(`Screenshots saved to ${DIR}/`);
  });
});
