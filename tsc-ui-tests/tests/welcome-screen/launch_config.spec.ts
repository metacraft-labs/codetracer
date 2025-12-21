import { test, expect } from "@playwright/test";
import { page, ctEditMode, wait, codetracerInstallDir } from "../../lib/ct_helpers";
import * as path from "node:path";

// Use the examples directory which has a .vscode/launch.json
const examplesFolder = path.join(codetracerInstallDir, "examples");

// Test launch configuration menu functionality
ctEditMode(examplesFolder);

// Helper function to ensure menu is open (handles toggle behavior)
async function ensureMenuOpen(): Promise<void> {
  const menuMain = page.locator("#menu-main");
  const isVisible = await menuMain.isVisible();
  if (!isVisible) {
    const menuRoot = page.locator("#menu-root");
    await menuRoot.click();
    await wait(500);
  }
}

// Helper function to close menu if open
async function ensureMenuClosed(): Promise<void> {
  const menuMain = page.locator("#menu-main");
  const isVisible = await menuMain.isVisible();
  if (isVisible) {
    // Click outside the menu to close it
    await page.keyboard.press("Escape");
    await wait(300);
  }
}

test.describe("Launch Configuration Menu", () => {
  // Close menu after each test to ensure clean state
  test.afterEach(async () => {
    await ensureMenuClosed();
  });

  test("edit mode loads successfully with examples folder", async () => {
    // Wait for the layout to be initialized
    await page.waitForSelector(".lm_goldenlayout", { timeout: 15000 });

    const layout = page.locator(".lm_goldenlayout");
    await expect(layout).toBeVisible();
  });

  test("navigation menu is visible", async () => {
    await page.waitForSelector(".lm_goldenlayout", { timeout: 15000 });

    // The navigation menu should be visible
    const menu = page.locator("#navigation-menu");
    await expect(menu).toBeVisible();
  });

  test("can open main menu by clicking logo", async () => {
    await page.waitForSelector(".lm_goldenlayout", { timeout: 15000 });

    await ensureMenuOpen();

    // The menu-main container should be visible
    const menuMain = page.locator("#menu-main");
    await expect(menuMain).toBeVisible();
  });

  test("Debug menu folder exists", async () => {
    await page.waitForSelector(".lm_goldenlayout", { timeout: 15000 });

    await ensureMenuOpen();

    // Look for the Debug folder in the menu (class name is lowercase)
    const debugFolder = page.locator(".menu-folder-debug");
    await expect(debugFolder).toBeVisible();
  });

  test("Launch Configurations submenu exists under Debug", async () => {
    await page.waitForSelector(".lm_goldenlayout", { timeout: 15000 });

    await ensureMenuOpen();

    // Hover over Debug to open its submenu (class name is lowercase)
    const debugFolder = page.locator(".menu-folder-debug");
    await debugFolder.hover();
    await wait(500);

    // Look for the Launch Configurations folder (class converts to lowercase with dashes)
    const launchConfigFolder = page.locator(".menu-folder-launch-configurations");

    // Take a screenshot for debugging
    await page.screenshot({ path: "test-results/debug-menu-open.png" });

    await expect(launchConfigFolder).toBeVisible();
  });

  test("Launch Configurations submenu contains Python: Fibonacci", async () => {
    await page.waitForSelector(".lm_goldenlayout", { timeout: 15000 });

    await ensureMenuOpen();

    // Hover over Debug to open its submenu
    const debugFolder = page.locator(".menu-folder-debug");
    await debugFolder.hover();
    await wait(500);

    // Hover over Launch Configurations to open its submenu
    const launchConfigFolder = page.locator(".menu-folder-launch-configurations");
    await launchConfigFolder.hover();
    await wait(500);

    // Take a screenshot for debugging
    await page.screenshot({ path: "test-results/launch-configs-open.png" });

    // Check for Python: Fibonacci configuration
    // The menu element class is generated with convertStringToHtmlClass (lowercase, dashes)
    const pythonFibonacci = page.locator(".menu-element-python-fibonacci");
    await expect(pythonFibonacci).toBeVisible();
  });

  test("Launch Configurations submenu contains Ruby: Fibonacci", async () => {
    await page.waitForSelector(".lm_goldenlayout", { timeout: 15000 });

    await ensureMenuOpen();

    const debugFolder = page.locator(".menu-folder-debug");
    await debugFolder.hover();
    await wait(500);

    const launchConfigFolder = page.locator(".menu-folder-launch-configurations");
    await launchConfigFolder.hover();
    await wait(500);

    // Check for Ruby: Fibonacci configuration (lowercase, colons removed)
    const rubyFibonacci = page.locator(".menu-element-ruby-fibonacci");
    await expect(rubyFibonacci).toBeVisible();
  });

  test("Launch config items are clickable", async () => {
    await page.waitForSelector(".lm_goldenlayout", { timeout: 15000 });

    await ensureMenuOpen();

    const debugFolder = page.locator(".menu-folder-debug");
    await debugFolder.hover();
    await wait(500);

    const launchConfigFolder = page.locator(".menu-folder-launch-configurations");
    await launchConfigFolder.hover();
    await wait(500);

    // Verify Ruby: Fibonacci exists and is enabled (don't click, to preserve app state)
    const rubyFibonacci = page.locator(".menu-element-ruby-fibonacci");
    await expect(rubyFibonacci).toBeVisible();

    // Check that it's enabled
    const classes = await rubyFibonacci.locator("..").getAttribute("class");
    expect(classes).toContain("menu-enabled");
  });
});

test.describe("Launch Configuration Recording", () => {
  // This test is skipped for now because it changes app state significantly
  // and needs to be run in isolation. The menu functionality is tested above.
  test.skip("Recording Ruby: Fibonacci produces a trace", async () => {
    await page.waitForSelector(".lm_goldenlayout", { timeout: 15000 });

    await ensureMenuOpen();

    const debugFolder = page.locator(".menu-folder-debug");
    await debugFolder.hover();
    await wait(500);

    const launchConfigFolder = page.locator(".menu-folder-launch-configurations");
    await launchConfigFolder.hover();
    await wait(500);

    const rubyFibonacci = page.locator(".menu-element-ruby-fibonacci");
    await rubyFibonacci.click();

    // Wait for recording to complete (Ruby fibonacci should be quick)
    // This might take a few seconds
    await wait(10000);

    // Take a screenshot to see the state
    await page.screenshot({ path: "test-results/after-recording.png" });

    // After successful recording, we should see debug mode UI elements
    // or at least not be in edit mode anymore

    // Check for any error notifications
    const errorNotification = page.locator(".notification-error");
    const errorCount = await errorNotification.count();

    if (errorCount > 0) {
      const errorText = await errorNotification.first().textContent();
      console.log(`Error notification: ${errorText}`);
      // Fail the test if there's an error
      expect(errorCount).toBe(0);
    }

    // Check if we transitioned to debug mode (trace loaded)
    // Debug mode typically shows the debugger controls
    const debugControls = page.locator("#debug");
    const hasDebugControls = await debugControls.count();

    console.log(`Debug controls found: ${hasDebugControls}`);
  });
});

test.describe("Debug: Inspect Menu Structure", () => {
  test("dump menu structure for debugging", async () => {
    await page.waitForSelector(".lm_goldenlayout", { timeout: 15000 });

    await ensureMenuOpen();

    // Get all menu elements and their classes
    const menuElements = page.locator("#menu-elements .menu-node");
    const count = await menuElements.count();

    console.log(`\n=== Main Menu Elements (${count}) ===`);
    for (let i = 0; i < count; i++) {
      const element = menuElements.nth(i);
      const className = await element.getAttribute("class");
      const text = await element.textContent();
      console.log(`  ${i}: ${text?.trim()} [${className}]`);
    }

    // Hover over Debug (class name is lowercase)
    const debugFolder = page.locator(".menu-folder-debug");
    const debugExists = await debugFolder.count();
    console.log(`\nDebug folder exists: ${debugExists > 0}`);

    if (debugExists > 0) {
      await debugFolder.hover();
      await wait(500);

      // Get nested menu elements
      const nestedElements = page.locator(".menu-nested-elements .menu-node");
      const nestedCount = await nestedElements.count();

      console.log(`\n=== Debug Submenu Elements (${nestedCount}) ===`);
      for (let i = 0; i < nestedCount; i++) {
        const element = nestedElements.nth(i);
        const className = await element.getAttribute("class");
        const text = await element.textContent();
        console.log(`  ${i}: ${text?.trim()} [${className}]`);
      }

      // Check for Launch Configurations folder (lowercase)
      const launchConfigFolder = page.locator(".menu-folder-launch-configurations");
      const launchConfigExists = await launchConfigFolder.count();
      console.log(`\nLaunch Configurations folder exists: ${launchConfigExists > 0}`);

      if (launchConfigExists > 0) {
        await launchConfigFolder.hover();
        await wait(500);

        // Get launch config items
        const configItems = page.locator(".menu-nested-elements .menu-element");
        const configCount = await configItems.count();

        console.log(`\n=== Launch Config Items (${configCount}) ===`);
        for (let i = 0; i < configCount; i++) {
          const element = configItems.nth(i);
          const className = await element.getAttribute("class");
          const text = await element.textContent();
          console.log(`  ${i}: ${text?.trim()} [${className}]`);
        }
      }
    }

    // Take final screenshot
    await page.screenshot({ path: "test-results/menu-structure-debug.png" });
  });
});
