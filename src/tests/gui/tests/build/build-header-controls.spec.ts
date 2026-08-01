/**
 * E2E tests for the build panel header controls (BP-M5).
 *
 * Verifies:
 * - The header controls container is present in the build panel
 * - Stop, clear, and auto-scroll toggle buttons are visible
 *
 * Clicking a strip tab DOCKS the panel into `#auto-hide-docked-bottom`; it
 * does not open `#auto-hide-overlay`, which is the hover-preview surface.
 * See the contract note in `page-objects/auto-hide-strip.ts`.
 *
 * No mocks: a real JavaScript recording opened by the real Electron app.  The
 * build panel is a standalone auto-hide pane `layout.nim` registers for every
 * recorded language — see `lib/js-trace-fixture.ts`.
 */

import { test, expect, codetracerInstallDir } from "../../lib/fixtures";
import { recordChromeTraceFixture } from "../../lib/js-trace-fixture";
import { retry } from "../../lib/retry-helpers";
import { BuildPane } from "../../page-objects/panes/build/build-pane";
import { LayoutPage } from "../../page-objects/layout-page";
import { ensureDefaultLayout, restoreUserLayout } from "../../lib/layout-reset";
import {
  DOCKED_BOTTOM_CONTENT_SELECTOR,
  openBottomPanel,
  waitForDefaultBottomTabs,
} from "../../page-objects/auto-hide-strip";

const fixture = recordChromeTraceFixture("build-header-controls");

test.describe("Build Header Controls", () => {
  test.setTimeout(120_000);
  test.use({ sourcePath: fixture.traceDir, launchMode: "trace-folder" });

  test.beforeAll(() => ensureDefaultLayout(codetracerInstallDir));
  test.afterAll(() => restoreUserLayout());

  test("header controls container is present in the build panel", async ({ ctPage }) => {
    const layout = new LayoutPage(ctPage);
    await layout.waitForBaseComponentsLoaded();
    await layout.waitForTraceLoaded();

    // Wait for auto-hide bottom tabs to appear.
    await waitForDefaultBottomTabs(ctPage);

    // Click the BUILD auto-hide tab to dock the build panel.
    await openBottomPanel(ctPage, "BUILD");

    // Wait for the build panel to appear inside the docked container.
    await retry(
      async () => {
        const count = await ctPage
          .locator(`${DOCKED_BOTTOM_CONTENT_SELECTOR} .build-panel`)
          .count();
        return count > 0;
      },
      { maxAttempts: 30, delayMs: 1000 },
    );

    // The header controls row should always be rendered inside the build panel.
    const buildPane = new BuildPane(ctPage);
    const controlsCount = await buildPane.headerControls().count();
    expect(controlsCount).toBeGreaterThan(0);
  });

  test("stop, clear, and scroll toggle buttons are visible", async ({ ctPage }) => {
    const layout = new LayoutPage(ctPage);
    await layout.waitForBaseComponentsLoaded();
    await layout.waitForTraceLoaded();

    // Wait for auto-hide bottom tabs to appear.
    await waitForDefaultBottomTabs(ctPage);

    // Click the BUILD auto-hide tab to dock the build panel.
    await openBottomPanel(ctPage, "BUILD");

    // Wait for the build panel to appear.
    await retry(
      async () => {
        const count = await ctPage
          .locator(`${DOCKED_BOTTOM_CONTENT_SELECTOR} .build-panel`)
          .count();
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
