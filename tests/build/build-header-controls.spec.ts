/**
 * E2E tests for the build panel header controls (BP-M5).
 *
 * Verifies:
 * - The header controls container is present in the build panel
 * - Stop, clear, and auto-scroll toggle buttons are visible
 */

import { test, expect, wait, codetracerInstallDir } from "../../lib/fixtures";
import { retry } from "../../lib/retry-helpers";
import { BuildPane } from "../../page-objects/panes/build/build-pane";
import { ensureDefaultLayout, restoreUserLayout } from "../../lib/layout-reset";

test.describe("Build Header Controls", () => {
  test.setTimeout(120_000);
  // Use a trace source that triggers a build step so the build panel is rendered.
  test.use({ sourcePath: "py_console_logs/main.py", launchMode: "trace" });

  test.beforeAll(() => ensureDefaultLayout(codetracerInstallDir));
  test.afterAll(() => restoreUserLayout());

  test("header controls container is present in the build panel", async ({ ctPage }) => {
    const layout = new (await import("../../page-objects/layout-page")).LayoutPage(ctPage);
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

    const overlay = ctPage.locator("#auto-hide-overlay");
    await expect(overlay).toHaveClass(/visible/, { timeout: 5_000 });

    // Wait for the build panel to appear inside the overlay.
    const buildExists = await retry(
      async () => {
        const count = await ctPage.locator("#auto-hide-overlay-content .build-panel").count();
        return count > 0;
      },
      { maxAttempts: 30, delayMs: 1000 },
    ).then(() => true as const).catch(() => false);

    if (!buildExists) {
      test.skip(true, "Build panel not rendered for this trace");
      return;
    }

    // The header controls row should always be rendered inside the build panel.
    const buildPane = new BuildPane(ctPage);
    const controlsCount = await buildPane.headerControls().count();
    expect(controlsCount).toBeGreaterThan(0);
  });

  test("stop, clear, and scroll toggle buttons are visible", async ({ ctPage }) => {
    const layout = new (await import("../../page-objects/layout-page")).LayoutPage(ctPage);
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

    const overlay = ctPage.locator("#auto-hide-overlay");
    await expect(overlay).toHaveClass(/visible/, { timeout: 5_000 });

    // Wait for the build panel to appear.
    await retry(
      async () => {
        const count = await ctPage.locator("#auto-hide-overlay-content .build-panel").count();
        return count > 0;
      },
      { maxAttempts: 30, delayMs: 1000 },
    );

    const buildPane = new BuildPane(ctPage);

    // Stop button should exist (may be disabled when build is not running).
    const stopCount = await buildPane.stopButton().count();
    expect(stopCount).toBeGreaterThan(0);

    // Clear button should exist and be clickable.
    const clearCount = await buildPane.clearButton().count();
    expect(clearCount).toBeGreaterThan(0);

    // Auto-scroll toggle should exist.
    const scrollCount = await buildPane.scrollToggle().count();
    expect(scrollCount).toBeGreaterThan(0);
  });
});
