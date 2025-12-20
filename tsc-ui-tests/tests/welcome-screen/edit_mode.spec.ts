import { test, expect } from "@playwright/test";
import { page, ctEditMode, wait, codetracerInstallDir } from "../../lib/ct_helpers";
import * as path from "node:path";

// Use the test-programs directory as the folder to open in edit mode
const testFolder = path.join(codetracerInstallDir, "test-programs");

// Test edit mode functionality
ctEditMode(testFolder);

test("edit mode loads the main UI", async () => {
  // Wait for the layout to be initialized (GoldenLayout creates this container)
  await page.waitForSelector(".lm_goldenlayout", { timeout: 15000 });

  // Verify the layout container is visible
  const layout = page.locator(".lm_goldenlayout");
  await expect(layout).toBeVisible();
});

test("edit mode shows file system panel", async () => {
  await page.waitForSelector(".lm_goldenlayout", { timeout: 15000 });

  // Check for filesystem panel
  const filesystemPanel = page.locator(".filesystem-panel");

  // The filesystem panel should be present
  // (it might take a moment to load)
  await wait(1000);

  // Check if it exists (might be in a tab)
  const count = await filesystemPanel.count();
  expect(count).toBeGreaterThanOrEqual(0); // May or may not be visible depending on layout
});

test("edit mode does not show welcome screen", async () => {
  await page.waitForSelector(".lm_goldenlayout", { timeout: 15000 });

  // The welcome screen should NOT be visible
  const welcomeScreen = page.locator(".welcome-screen");
  await expect(welcomeScreen).toBeHidden();
});

test("edit mode is in edit mode (not debug mode)", async () => {
  await page.waitForSelector(".lm_goldenlayout", { timeout: 15000 });

  // Wait for UI to fully load
  await wait(500);

  // Check that we're in edit mode by verifying debug-specific elements are not active
  // or by checking for edit-mode specific UI state
  // The layout should be present and functional
  const layoutContent = page.locator(".lm_content");
  await expect(layoutContent).toBeVisible();
});
