import { test, expect } from "../lib/fixtures";
import { LayoutPage } from "../page-objects/layout-page";
import * as helpers from "../lib/language-smoke-test-helpers";
import { retry } from "../lib/retry-helpers";
import { moveAndSettle } from "../lib/operation-settled";

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

    // Awaited by the position the Next reaches: `#stable-status` is drawn
    // only while busy, so it cannot say "done" (`lib/operation-settled.ts`).
    await moveAndSettle(ctPage, () => layout.clickNextButton());

    const selectedText = await ctPage.evaluate(() => {
      const sel = document.querySelector(".calltrace-call-line.event-selected");
      return sel ? sel.textContent : "";
    });

    expect(selectedText).toBeTruthy();
  });
});
