import { test, expect } from "../../lib/fixtures";

function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

test.describe("Welcome Screen", () => {
  test.use({ launchMode: "welcome" });

  test("welcome screen is displayed", async ({ ctPage }) => {
    await ctPage.waitForSelector(".welcome-screen", { timeout: 15000 });

    const welcomeScreen = ctPage.locator(".welcome-screen");
    await expect(welcomeScreen).toBeVisible();
  });

  test("welcome screen has left and right panels", async ({ ctPage }) => {
    await ctPage.waitForSelector(".welcome-screen", { timeout: 10000 });

    const leftPanel = ctPage.locator(".welcome-left-panel");
    await expect(leftPanel).toBeVisible();

    const rightPanel = ctPage.locator(".welcome-right-panel");
    await expect(rightPanel).toBeVisible();
  });

  test("welcome screen has start options buttons", async ({ ctPage }) => {
    await ctPage.waitForSelector(".welcome-screen", { timeout: 10000 });

    const openFolderButton = ctPage
      .locator(".start-option")
      .filter({ hasText: /folder/i })
      .first();
    await expect(openFolderButton).toBeVisible();

    const newRecordingButton = ctPage
      .locator(".start-option")
      .filter({ hasText: /record/i })
      .first();
    await expect(newRecordingButton).toBeVisible();
  });

  test("recent traces section is visible", async ({ ctPage }) => {
    await ctPage.waitForSelector(".welcome-screen", { timeout: 10000 });

    const recentTraces = ctPage.locator(".recent-traces");
    await expect(recentTraces).toBeVisible();

    const title = ctPage.locator(".recent-traces-title");
    await expect(title).toBeVisible();
  });

  test("recent folders section is visible", async ({ ctPage }) => {
    await ctPage.waitForSelector(".welcome-screen", { timeout: 10000 });

    const recentFolders = ctPage.locator(".recent-folders");
    await expect(recentFolders).toBeVisible();
  });

  test("trace entries show time ago format", async ({ ctPage }) => {
    await ctPage.waitForSelector(".welcome-screen", { timeout: 10000 });

    const traceEntries = ctPage.locator(".recent-trace");
    const count = await traceEntries.count();

    if (count > 0) {
      const firstTrace = traceEntries.first();
      const timeAgo = firstTrace.locator(".recent-trace-title-time");
      await expect(timeAgo).toBeVisible();

      const timeText = await timeAgo.textContent();
      expect(timeText).toBeTruthy();
    }
  });

  test("trace tooltip appears on hover", async ({ ctPage }) => {
    await ctPage.waitForSelector(".welcome-screen", { timeout: 10000 });

    const traceEntries = ctPage.locator(".recent-trace");
    const count = await traceEntries.count();

    if (count > 0) {
      const firstTrace = traceEntries.first();
      const tooltip = firstTrace.locator(".recent-trace-tooltip");

      await expect(tooltip).toBeHidden();

      await firstTrace.hover();
      await sleep(700);

      await expect(tooltip).toBeVisible();
    }
  });
});
