import type { Page } from "@playwright/test";
import * as path from "node:path";
import { test, expect, codetracerInstallDir } from "../../lib/fixtures";

function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

const examplesFolder = path.join(codetracerInstallDir, "examples");

async function ensureMenuOpen(page: Page): Promise<void> {
  const menuMain = page.locator("#menu-main");
  const isVisible = await menuMain.isVisible();
  if (!isVisible) {
    const menuRoot = page.locator("#menu-root");
    await menuRoot.click();
    await sleep(500);
  }
}

async function ensureMenuClosed(page: Page): Promise<void> {
  const menuMain = page.locator("#menu-main");
  const isVisible = await menuMain.isVisible();
  if (isVisible) {
    await page.keyboard.press("Escape");
    await sleep(300);
  }
}

test.describe("Launch Configuration Menu", () => {
  test.use({ launchMode: "edit", editFolderPath: examplesFolder });

  test.afterEach(async ({ ctPage }) => {
    await ensureMenuClosed(ctPage);
  });

  test("edit mode loads successfully with examples folder", async ({ ctPage }) => {
    await ctPage.waitForSelector(".lm_goldenlayout", { timeout: 15000 });

    const layout = ctPage.locator(".lm_goldenlayout");
    await expect(layout).toBeVisible();
  });

  test("navigation menu is visible", async ({ ctPage }) => {
    await ctPage.waitForSelector(".lm_goldenlayout", { timeout: 15000 });

    const menu = ctPage.locator("#navigation-menu");
    await expect(menu).toBeVisible();
  });

  test("can open main menu by clicking logo", async ({ ctPage }) => {
    await ctPage.waitForSelector(".lm_goldenlayout", { timeout: 15000 });

    await ensureMenuOpen(ctPage);

    const menuMain = ctPage.locator("#menu-main");
    await expect(menuMain).toBeVisible();
  });

  test("Debug menu folder exists", async ({ ctPage }) => {
    await ctPage.waitForSelector(".lm_goldenlayout", { timeout: 15000 });

    await ensureMenuOpen(ctPage);

    const debugFolder = ctPage.locator(".menu-folder-debug");
    await expect(debugFolder).toBeVisible();
  });

  test("Launch Configurations submenu exists under Debug", async ({ ctPage }) => {
    await ctPage.waitForSelector(".lm_goldenlayout", { timeout: 15000 });

    await ensureMenuOpen(ctPage);

    const debugFolder = ctPage.locator(".menu-folder-debug");
    await debugFolder.hover();
    await sleep(500);

    const launchConfigFolder = ctPage.locator(
      ".menu-folder-launch-configurations",
    );

    await ctPage.screenshot({ path: "test-results/debug-menu-open.png" });

    await expect(launchConfigFolder).toBeVisible();
  });

  test("Launch Configurations submenu contains Python: Fibonacci", async ({
    ctPage,
  }) => {
    await ctPage.waitForSelector(".lm_goldenlayout", { timeout: 15000 });

    await ensureMenuOpen(ctPage);

    const debugFolder = ctPage.locator(".menu-folder-debug");
    await debugFolder.hover();
    await sleep(500);

    const launchConfigFolder = ctPage.locator(
      ".menu-folder-launch-configurations",
    );
    await launchConfigFolder.hover();
    await sleep(500);

    await ctPage.screenshot({ path: "test-results/launch-configs-open.png" });

    const pythonFibonacci = ctPage.locator(".menu-element-python-fibonacci");
    await expect(pythonFibonacci).toBeVisible();
  });

  test("Launch Configurations submenu contains Ruby: Fibonacci", async ({
    ctPage,
  }) => {
    await ctPage.waitForSelector(".lm_goldenlayout", { timeout: 15000 });

    await ensureMenuOpen(ctPage);

    const debugFolder = ctPage.locator(".menu-folder-debug");
    await debugFolder.hover();
    await sleep(500);

    const launchConfigFolder = ctPage.locator(
      ".menu-folder-launch-configurations",
    );
    await launchConfigFolder.hover();
    await sleep(500);

    const rubyFibonacci = ctPage.locator(".menu-element-ruby-fibonacci");
    await expect(rubyFibonacci).toBeVisible();
  });

  test("Launch config items are clickable", async ({ ctPage }) => {
    await ctPage.waitForSelector(".lm_goldenlayout", { timeout: 15000 });

    await ensureMenuOpen(ctPage);

    const debugFolder = ctPage.locator(".menu-folder-debug");
    await debugFolder.hover();
    await sleep(500);

    const launchConfigFolder = ctPage.locator(
      ".menu-folder-launch-configurations",
    );
    await launchConfigFolder.hover();
    await sleep(500);

    const rubyFibonacci = ctPage.locator(".menu-element-ruby-fibonacci");
    await expect(rubyFibonacci).toBeVisible();

    const classes = await rubyFibonacci.locator("..").getAttribute("class");
    expect(classes).toContain("menu-enabled");
  });
});

test.describe("Launch Configuration Recording", () => {
  test.use({ launchMode: "edit", editFolderPath: examplesFolder });

  test.skip("Recording Ruby: Fibonacci produces a trace", async ({ ctPage }) => {
    await ctPage.waitForSelector(".lm_goldenlayout", { timeout: 15000 });

    await ensureMenuOpen(ctPage);

    const debugFolder = ctPage.locator(".menu-folder-debug");
    await debugFolder.hover();
    await sleep(500);

    const launchConfigFolder = ctPage.locator(
      ".menu-folder-launch-configurations",
    );
    await launchConfigFolder.hover();
    await sleep(500);

    const rubyFibonacci = ctPage.locator(".menu-element-ruby-fibonacci");
    await rubyFibonacci.click();

    await sleep(10000);

    await ctPage.screenshot({ path: "test-results/after-recording.png" });

    const errorNotification = ctPage.locator(".notification-error");
    const errorCount = await errorNotification.count();

    if (errorCount > 0) {
      const errorText = await errorNotification.first().textContent();
      console.log(`Error notification: ${errorText}`);
      expect(errorCount).toBe(0);
    }

    const debugControls = ctPage.locator("#debug");
    const hasDebugControls = await debugControls.count();
    console.log(`Debug controls found: ${hasDebugControls}`);
  });
});

test.describe("Debug: Inspect Menu Structure", () => {
  test.use({ launchMode: "edit", editFolderPath: examplesFolder });

  test("dump menu structure for debugging", async ({ ctPage }) => {
    await ctPage.waitForSelector(".lm_goldenlayout", { timeout: 15000 });

    await ensureMenuOpen(ctPage);

    const menuElements = ctPage.locator("#menu-elements .menu-node");
    const count = await menuElements.count();

    console.log(`\n=== Main Menu Elements (${count}) ===`);
    for (let i = 0; i < count; i++) {
      const element = menuElements.nth(i);
      const className = await element.getAttribute("class");
      const text = await element.textContent();
      console.log(`  ${i}: ${text?.trim()} [${className}]`);
    }

    const debugFolder = ctPage.locator(".menu-folder-debug");
    const debugExists = await debugFolder.count();
    console.log(`\nDebug folder exists: ${debugExists > 0}`);

    if (debugExists > 0) {
      await debugFolder.hover();
      await sleep(500);

      const nestedElements = ctPage.locator(
        ".menu-nested-elements .menu-node",
      );
      const nestedCount = await nestedElements.count();

      console.log(`\n=== Debug Submenu Elements (${nestedCount}) ===`);
      for (let i = 0; i < nestedCount; i++) {
        const element = nestedElements.nth(i);
        const className = await element.getAttribute("class");
        const text = await element.textContent();
        console.log(`  ${i}: ${text?.trim()} [${className}]`);
      }

      const launchConfigFolder = ctPage.locator(
        ".menu-folder-launch-configurations",
      );
      const launchConfigExists = await launchConfigFolder.count();
      console.log(
        `\nLaunch Configurations folder exists: ${launchConfigExists > 0}`,
      );

      if (launchConfigExists > 0) {
        await launchConfigFolder.hover();
        await sleep(500);

        const configItems = ctPage.locator(
          ".menu-nested-elements .menu-element",
        );
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

    await ctPage.screenshot({ path: "test-results/menu-structure-debug.png" });
  });
});
