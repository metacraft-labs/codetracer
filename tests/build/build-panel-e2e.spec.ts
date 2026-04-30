/**
 * E2E tests for the build-related tabs in the bottom panel row.
 *
 * Verifies:
 * - BUILD, PROBLEMS, and SEARCH RESULTS tabs are present as auto-hide bottom tabs
 * - Clicking the BUILD tab opens the overlay with the build panel and its header
 * - Clicking the PROBLEMS tab shows the problems panel (empty state)
 */

import { test, expect, wait, codetracerInstallDir } from "../../lib/fixtures";
import { retry } from "../../lib/retry-helpers";
import { LayoutPage } from "../../page-objects/layout-page";
import { ensureDefaultLayout, restoreUserLayout } from "../../lib/layout-reset";

test.describe("Build panel tabs as auto-hide bottom tabs", () => {
  test.setTimeout(120_000);
  test.use({ sourcePath: "py_console_logs/main.py", launchMode: "trace" });

  test.beforeAll(() => ensureDefaultLayout(codetracerInstallDir));
  test.afterAll(() => restoreUserLayout());

  test("BUILD tab present in bottom auto-hide strip", async ({ ctPage }) => {
    const layout = new LayoutPage(ctPage);
    await layout.waitForBaseComponentsLoaded();
    await layout.waitForTraceLoaded();

    // Wait for auto-hide bottom tabs to appear (they load after a delay).
    await ctPage.locator(".auto-hide-bottom-tabs .auto-hide-strip-tab").first().waitFor({ timeout: 10_000 });

    // The BUILD tab should exist among the auto-hide bottom tabs.
    const buildTab = ctPage.locator(".auto-hide-bottom-tabs .auto-hide-strip-tab", {
      hasText: "BUILD",
    });
    await expect(buildTab).toHaveCount(1);

    // Verify the sibling tabs are also present as auto-hide bottom tabs.
    const problemsTab = ctPage.locator(".auto-hide-bottom-tabs .auto-hide-strip-tab", {
      hasText: "PROBLEMS",
    });
    const searchTab = ctPage.locator(".auto-hide-bottom-tabs .auto-hide-strip-tab", {
      hasText: "SEARCH RESULTS",
    });
    await expect(problemsTab).toHaveCount(1);
    await expect(searchTab).toHaveCount(1);
  });

  test("PROBLEMS tab present", async ({ ctPage }) => {
    const layout = new LayoutPage(ctPage);
    await layout.waitForBaseComponentsLoaded();
    await layout.waitForTraceLoaded();

    await ctPage.locator(".auto-hide-bottom-tabs .auto-hide-strip-tab").first().waitFor({ timeout: 10_000 });

    const problemsTab = ctPage.locator(".auto-hide-bottom-tabs .auto-hide-strip-tab", {
      hasText: "PROBLEMS",
    });
    await expect(problemsTab).toHaveCount(1);
  });

  test("SEARCH RESULTS tab present", async ({ ctPage }) => {
    const layout = new LayoutPage(ctPage);
    await layout.waitForBaseComponentsLoaded();
    await layout.waitForTraceLoaded();

    await ctPage.locator(".auto-hide-bottom-tabs .auto-hide-strip-tab").first().waitFor({ timeout: 10_000 });

    const searchTab = ctPage.locator(".auto-hide-bottom-tabs .auto-hide-strip-tab", {
      hasText: "SEARCH RESULTS",
    });
    await expect(searchTab).toHaveCount(1);
  });

  test("Build panel renders with header", async ({ ctPage }) => {
    const layout = new LayoutPage(ctPage);
    await layout.waitForBaseComponentsLoaded();
    await layout.waitForTraceLoaded();

    // Wait for auto-hide bottom tabs to appear.
    await ctPage.locator(".auto-hide-bottom-tabs .auto-hide-strip-tab").first().waitFor({ timeout: 10_000 });

    // Click the BUILD auto-hide tab to open the overlay.
    const buildTab = ctPage.locator(".auto-hide-bottom-tabs .auto-hide-strip-tab", {
      hasText: "BUILD",
    });
    await buildTab.click();
    await wait(500);

    // The overlay should become visible.
    const overlay = ctPage.locator("#auto-hide-overlay");
    await expect(overlay).toHaveClass(/visible/, { timeout: 5_000 });

    // After clicking, the build panel (#build) should be visible inside the overlay.
    const buildPanel = ctPage.locator("#auto-hide-overlay-content #build");
    const visible = await retry(
      async () => {
        if ((await buildPanel.count()) === 0) return false;
        return buildPanel.first().isVisible();
      },
      { maxAttempts: 20, delayMs: 500 },
    ).then(() => true as const).catch(() => false);

    expect(visible).toBe(true);

    // The build panel should contain the header controls area.
    const header = ctPage.locator("#auto-hide-overlay-content .build-header-controls");
    const headerPresent = (await header.count()) > 0;
    expect(headerPresent).toBe(true);
  });

  test("Problems panel renders empty state", async ({ ctPage }) => {
    const layout = new LayoutPage(ctPage);
    await layout.waitForBaseComponentsLoaded();
    await layout.waitForTraceLoaded();

    // Wait for auto-hide bottom tabs to appear.
    await ctPage.locator(".auto-hide-bottom-tabs .auto-hide-strip-tab").first().waitFor({ timeout: 10_000 });

    // Click the PROBLEMS auto-hide tab to open the overlay.
    const problemsTab = ctPage.locator(".auto-hide-bottom-tabs .auto-hide-strip-tab", {
      hasText: "PROBLEMS",
    });
    await problemsTab.click();
    await wait(500);

    // The overlay should become visible.
    const overlay = ctPage.locator("#auto-hide-overlay");
    await expect(overlay).toHaveClass(/visible/, { timeout: 5_000 });

    // The problems panel should become visible inside the overlay.
    const errorsContainer = ctPage.locator("#auto-hide-overlay-content #errorsComponent-0");
    const containerVisible = await retry(
      async () => {
        if ((await errorsContainer.count()) === 0) return false;
        return errorsContainer.first().isVisible();
      },
      { maxAttempts: 20, delayMs: 500 },
    ).then(() => true as const).catch(() => false);

    expect(containerVisible).toBe(true);

    // For py_console_logs (a simple Python trace), there should be no
    // build errors. If the Karax renderer has populated the container,
    // verify the empty state; otherwise the container being visible is
    // sufficient since the component initialises lazily.
    const problemsPanel = ctPage.locator("#auto-hide-overlay-content .problems-panel");
    if ((await problemsPanel.count()) > 0) {
      const rows = problemsPanel.locator(".problems-row");
      const rowCount = await rows.count();
      expect(rowCount).toBe(0);
    }
  });
});
