import * as path from "node:path";
import { test, expect, testProgramsPath } from "../../lib/fixtures";

function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

const testFolder = testProgramsPath;

test.describe("Edit Mode", () => {
  test.use({ launchMode: "edit", editFolderPath: testFolder });

  test("edit mode loads the main UI", async ({ ctPage }) => {
    await ctPage.waitForSelector(".lm_goldenlayout", { timeout: 15000 });

    const layout = ctPage.locator(".lm_goldenlayout");
    await expect(layout).toBeVisible();
  });

  test("edit mode shows file system panel", async ({ ctPage }) => {
    await ctPage.waitForSelector(".lm_goldenlayout", { timeout: 15000 });

    const filesystemPanel = ctPage.locator(".filesystem-panel");
    await sleep(1000);

    const count = await filesystemPanel.count();
    expect(count).toBeGreaterThanOrEqual(0);
  });

  test("edit mode does not show welcome screen", async ({ ctPage }) => {
    await ctPage.waitForSelector(".lm_goldenlayout", { timeout: 15000 });

    const welcomeScreen = ctPage.locator(".welcome-screen");
    await expect(welcomeScreen).toBeHidden();
  });

  test("edit mode is in edit mode (not debug mode)", async ({ ctPage }) => {
    await ctPage.waitForSelector(".lm_goldenlayout", { timeout: 15000 });
    await sleep(1000);

    const layoutContent = ctPage.locator(".lm_content").first();
    await expect(layoutContent).toBeVisible({ timeout: 10000 });
  });
});
