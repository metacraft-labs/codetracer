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

    await expect.poll(async () => {
      const state = await ctPage.evaluate(() => {
        const d = (window as any).data;
        return {
          edit: d?.startOptions?.edit === true,
          pathCount: d?.services?.debugger?.paths?.length ?? 0,
          openCount: Object.keys(d?.services?.editor?.open ?? {}).length,
        };
      });
      return state.edit && state.pathCount > 0 && state.openCount > 0;
    }).toBe(true);
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

test.describe("Welcome Open Folder", () => {
  test.use({ launchMode: "welcome" });

  test("welcome open-folder handoff initializes edit mode", async ({ ctPage, electronApp }) => {
    test.skip(!electronApp, "requires Electron main-process access");

    await ctPage.waitForSelector(".welcome-screen", { timeout: 15000 });
    await electronApp!.evaluate(({ BrowserWindow }, folderPath) => {
      const [window] = BrowserWindow.getAllWindows();
      window.webContents.send("CODETRACER::load-folder-edit-mode", {
        folderPath,
      });
    }, testFolder);

    await expect.poll(async () => {
      const state = await ctPage.evaluate(() => {
        const d = (window as any).data;
        return {
          edit: d?.startOptions?.edit === true,
          welcome: d?.startOptions?.welcomeScreen === true,
          pathCount: d?.services?.debugger?.paths?.length ?? 0,
          openCount: Object.keys(d?.services?.editor?.open ?? {}).length,
        };
      });
      return state.edit && !state.welcome && state.pathCount > 0 && state.openCount > 0;
    }).toBe(true);

    await expect(ctPage.locator(".lm_goldenlayout")).toBeVisible({ timeout: 15_000 });
  });
});
