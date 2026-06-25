import { test, expect } from "../lib/fixtures";
import { LayoutPage } from "../page-objects/layout-page";
import * as helpers from "../lib/language-smoke-test-helpers";
import { retry } from "../lib/retry-helpers";

test.describe("CallTrace Move Sync", () => {
  test.use({ sourcePath: "c_sudoku_solver/main.c", launchMode: "trace" });

  test("test_calltrace_move_sync: Verifies state stays synchronized during CallTrace moves", async ({ ctPage }) => {
    const layout = new LayoutPage(ctPage);
    await layout.waitForBaseComponentsLoaded();

    const callTrace = (await layout.callTraceTabs())[0];
    await callTrace.tabButton().dispatchEvent("click");
    callTrace.invalidateEntries();

    const entry = await callTrace.navigateToEntry("main");
    await entry.activate();

    await retry(
      async () => {
        const text = await ctPage.evaluate(() => {
          const sel = document.querySelector(".calltrace-call-line.event-selected");
          return sel ? sel.textContent : "";
        });
        return text?.includes("main") || false;
      },
      { maxAttempts: 30, delayMs: 1000 }
    );

    await layout.clickNextButton();

    await retry(
      async () => {
        const status = ctPage.locator("#stable-status");
        const className = (await status.getAttribute("class")) ?? "";
        return className.includes("ready-status");
      },
      { maxAttempts: 30, delayMs: 1000 }
    );

    const selectedText = await ctPage.evaluate(() => {
      const sel = document.querySelector(".calltrace-call-line.event-selected");
      return sel ? sel.textContent : "";
    });

    expect(selectedText).toBeTruthy();
  });
});
