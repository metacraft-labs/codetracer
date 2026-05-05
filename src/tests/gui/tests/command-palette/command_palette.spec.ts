import { test, expect, testProgramsPath } from "../../lib/fixtures";
import { LayoutPage } from "../../page-objects/layout-page";

const NOIR_SOURCE_PATH = `${testProgramsPath}/noir_example/`;

test.describe("Command Palette", () => {
  test.setTimeout(90_000);
  test.use({ sourcePath: NOIR_SOURCE_PATH, launchMode: "trace" });

  test("omnibox finds filenames and menu items", async ({ ctPage }) => {
    const layout = new LayoutPage(ctPage);
    await layout.waitForAllComponentsLoaded();
    await layout.waitForTraceLoaded();

    await ctPage.keyboard.press("Control+KeyP");
    const input = ctPage.locator("#command-query-text");
    await expect(input).toBeVisible({ timeout: 10_000 });

    await input.fill("main.nr");
    const fileHit = ctPage
      .locator(".command-results .command-result.command-file")
      .filter({ hasText: "main.nr" })
      .first();
    await expect(fileHit).toBeVisible({ timeout: 10_000 });
    await fileHit.click();
    await expect
      .poll(async () => {
        const editors = await layout.editorTabs(true);
        return editors.some((editor) => editor.fileName === "main.nr");
      })
      .toBeTruthy();

    await ctPage.keyboard.press("Control+KeyP");
    await input.fill(":open");
    const menuHit = ctPage
      .locator(".command-results .command-result.command-command")
      .filter({ hasText: /open/i })
      .first();
    await expect(menuHit).toBeVisible({ timeout: 10_000 });
  });
});
