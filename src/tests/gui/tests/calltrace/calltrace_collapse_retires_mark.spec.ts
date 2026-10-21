// Collapsing an ancestor of the current call retires the call-trace mark
// (codetracer#811).
//
// Click-Navigation.md §3.3: "A row that is no longer present retires the mark
// rather than leaving the previous one standing", and "Expanding or collapsing
// a row is not activating it". The mark is the row's `event-selected` class,
// the `call-current` child box and the toggle icon's `active` class; all three
// are drawn on the row whose index is `CalltraceVM.selectedEntry`.
//
// `py_calltrace_collapse/main.py` is `<module>` -> `main` -> `assert_in_range`,
// then `report_total` and `report_done` at the top level. Before the fix, the
// mark was a row INDEX: collapsing `main` moved `report_total` up into
// `assert_in_range`'s old row, and the mark stood on it.
//
// No fakes: a real Python recording replayed in the Electron app.

import { test, expect } from "../../lib/fixtures";
import type { Page } from "@playwright/test";
import { LayoutPage } from "../../page-objects/layout-page";
import { retry } from "../../lib/retry-helpers";

/** The text of every visible call-trace row that carries any part of the mark. */
async function markedRows(page: Page): Promise<string[]> {
  return page.evaluate(() => {
    const rows = Array.from(document.querySelectorAll(".calltrace-call-line"));
    return rows
      .filter(
        (row) =>
          row.classList.contains("event-selected") ||
          row.querySelector(".call-child-box.call-current") !== null ||
          row.querySelector(".toggle-call .active") !== null,
      )
      .map((row) => (row.querySelector(".call-text")?.textContent ?? "").trim());
  });
}

test.describe("CallTrace collapse retires the current-call mark", () => {
  test.use({ sourcePath: "py_calltrace_collapse/main.py", launchMode: "trace" });

  test("collapsing the parent of the current call leaves no row marked (#811)", async ({ ctPage }) => {
    const layout = new LayoutPage(ctPage);
    await layout.waitForAllComponentsLoaded();

    const callTrace = (await layout.callTraceTabs())[0];
    await callTrace.clickTab();
    callTrace.invalidateEntries();

    // Stop inside the nested call; the mark is on its row.
    const nested = await callTrace.navigateToEntry("assert_in_range");
    await nested.activate();
    await retry(
      async () => {
        const marked = await markedRows(ctPage);
        return marked.length === 1 && marked[0].startsWith("assert_in_range");
      },
      { maxAttempts: 30, delayMs: 1000 },
    );

    // Collapse `main`, the parent of the current call. The mark coming back
    // when `main` is expanded again is covered headlessly, in
    // calltrace_vm_test.nim, "re-expanding restores the mark on the call at
    // its new index (#811)".
    callTrace.invalidateEntries();
    const parent = await callTrace.findEntry("main", true);
    expect(parent).not.toBeNull();
    await parent!.collapseChildren();

    // Wait for the reloaded section: the nested call is gone and the
    // top-level call after `main` is visible.
    await retry(
      async () => {
        callTrace.invalidateEntries();
        const hidden = (await callTrace.findEntry("assert_in_range", true)) === null;
        const shifted = (await callTrace.findEntry("report_total", true)) !== null;
        return hidden && shifted;
      },
      { maxAttempts: 30, delayMs: 500 },
    );

    // Give a stale mark every chance to be (re)drawn before asserting.
    await ctPage.waitForTimeout(1000);
    expect(await markedRows(ctPage)).toEqual([]);
  });
});
