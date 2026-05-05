import { test, expect, testProgramsPath } from "../../lib/fixtures";

function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

const testFolder = testProgramsPath;

async function visibleEditorText(ctPage: any): Promise<string> {
  return await ctPage.evaluate(() => {
    return Array.from(document.querySelectorAll(".monaco-editor .view-lines"))
      .map((node) => (node as HTMLElement).innerText)
      .join("\n");
  });
}

test.describe("Edit Mode", () => {
  test.use({ launchMode: "edit", editFolderPath: testFolder });

  test("edit mode loads the main UI", async ({ ctPage }) => {
    await ctPage.waitForSelector(".lm_goldenlayout", { timeout: 15000 });

    const layout = ctPage.locator(".lm_goldenlayout");
    await expect(layout).toBeVisible();

    await expect.poll(async () => {
      return await ctPage.evaluate(() => document.querySelectorAll(".monaco-editor").length);
    }).toBeGreaterThan(0);

    await expect.poll(async () => visibleEditorText(ctPage), { timeout: 10_000 })
      .toMatch(/proc|def|fn|import|class|module|func|contract|use|echo|print/i);
  });

  test("edit mode shows populated file system panel and opens clicked files", async ({ ctPage }) => {
    await ctPage.waitForSelector(".lm_goldenlayout", { timeout: 15000 });

    const filesystem = ctPage.locator(".filesystem").first();
    await expect(filesystem).toBeVisible({ timeout: 10_000 });

    const mainFile = filesystem.locator(".jstree-anchor", { hasText: "main.py" }).first();
    await expect(mainFile).toBeVisible({ timeout: 10_000 });
    await mainFile.click();

    await expect.poll(async () => visibleEditorText(ctPage), { timeout: 10_000 })
      .toMatch(/print|def|import/);
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

test.describe("Edit Mode CLI", () => {
  test.use({
    launchMode: "edit",
    editFolderPath: ".",
    editWorkingDirectory: testFolder,
  });

  test("ct edit dot launches edit mode from the process cwd", async ({ ctPage }) => {
    await ctPage.waitForSelector(".lm_goldenlayout", { timeout: 15000 });

    const state = await ctPage.evaluate(() => {
      return {
        monacoCount: document.querySelectorAll(".monaco-editor").length,
      };
    });
    expect(state.monacoCount).toBeGreaterThan(0);

    await expect.poll(async () => visibleEditorText(ctPage), { timeout: 10_000 })
      .toMatch(/proc|def|fn|import|class|module|func|contract|use|echo|print/i);
  });
});

test.describe("Welcome Open Folder", () => {
  test.use({ launchMode: "welcome" });

  test("welcome open-folder handoff initializes edit mode", async ({ ctPage }) => {
    await ctPage.waitForSelector(".welcome-screen", { timeout: 15000 });

    await ctPage.evaluate((folderPath) => {
      const d = (window as any).data;
      const originalSend = d.ipc.send.bind(d.ipc);
      d.ipc.send = (channel: string, payload?: unknown) => {
        if (channel === "CODETRACER::open-folder-dialog") {
          originalSend("CODETRACER::init-edit-mode", { folder: folderPath });
          return;
        }
        originalSend(channel, payload);
      };
    }, testFolder);

    await ctPage.locator(".start-option.open-folder").click();

    await expect.poll(async () => {
      const state = await ctPage.evaluate(() => {
        return {
          welcomeVisible: document.querySelector(".welcome-screen") !== null &&
            getComputedStyle(document.querySelector(".welcome-screen") as Element).display !== "none",
          monacoCount: document.querySelectorAll(".monaco-editor").length,
        };
      });
      return !state.welcomeVisible && state.monacoCount > 0;
    }).toBe(true);

    await expect(ctPage.locator(".lm_goldenlayout")).toBeVisible({ timeout: 15_000 });
  });
});
