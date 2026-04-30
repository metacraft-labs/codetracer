import { test, expect, readyOnEntryTest as readyOnEntry, loadedEventLog } from "../../lib/fixtures";
import { StatusBar } from "../../page-objects/status_bar";
import { StatePanel } from "../../page-objects/state";
import { LayoutPage } from "../../page-objects/layout-page";
import { retry } from "../../lib/retry-helpers";

// Entry point: first executable line in main() is `let x = 3;` at line 11.
const ENTRY_LINE = 11;

// Each describe block gets its own fixture scope (each test records + launches independently).

test.describe("wasm example — basic layout", () => {
  test.setTimeout(90_000);
  test.use({ sourcePath: "wasm_example/", launchMode: "trace" });

  test("we can access the browser window, not just dev tools", async ({ ctPage }) => {
    const title = await ctPage.title();
    expect(title).toContain("CodeTracer");
    await ctPage.focus("div");
  });

  test("correct entry status path/line", async ({ ctPage }) => {
    await readyOnEntry(ctPage);

    const statusBar = new StatusBar(ctPage, ctPage.locator("#status-base"));
    const simpleLocation = await statusBar.location();
    expect(simpleLocation.path.endsWith("main.rs")).toBeTruthy();
    expect(simpleLocation.line).toBe(ENTRY_LINE);
  });
});

test.describe("wasm example — state and navigation", () => {
  test.setTimeout(90_000);
  test.use({ sourcePath: "wasm_example/", launchMode: "trace" });

  // BUG: The event log footer row count stays at 0 for DB-based traces (WASM, blockchain).
  // The trace data exists (34 events, 8 steps) but the frontend DataTables component
  // does not populate the footer count for DB trace types. This is a frontend bug
  // in the event log population code path, not a backend or recorder issue.
  test.fixme("expected event count", async ({ ctPage }) => {
    await loadedEventLog(ctPage);

    let count = 0;
    await retry(
      async () => {
        const raw = await ctPage.$eval(
          ".data-tables-footer-rows-count",
          (el) => el.textContent ?? "",
        );
        const match = raw.match(/(\d+)/);
        if (!match) return false;
        count = parseInt(match[1], 10);
        return count > 0;
      },
      { maxAttempts: 30, delayMs: 500 },
    );
    expect(count).toBeGreaterThanOrEqual(1);
  });

  test("state panel loaded initially", async ({ ctPage }) => {
    await readyOnEntry(ctPage);
    const statePanel = new StatePanel(ctPage);
    // Wait for the code state line to be populated before asserting
    await retry(
      async () => {
        const text = await statePanel.codeStateLine().textContent();
        return text !== null && text.includes(`${ENTRY_LINE} | `);
      },
      { maxAttempts: 20, delayMs: 300 },
    );
    await expect(statePanel.codeStateLine()).toContainText(`${ENTRY_LINE} | `);
  });

  test("state panel supports integer values", async ({ ctPage }) => {
    await readyOnEntry(ctPage);
    const layout = new LayoutPage(ctPage);
    const statusBar = new StatusBar(ctPage, ctPage.locator("#status-base"));

    // Step forward twice (next) to move past `let x = 3;` and `let y = 4;`
    // so both variables are assigned. Entry is at line 11; after two nexts
    // we should be at line 13 (`let result = add(x, y);`).
    for (let i = 0; i < 2; i++) {
      await layout.nextButton().click();
      await retry(
        async () => {
          const status = ctPage.locator("#stable-status");
          const className = (await status.getAttribute("class")) ?? "";
          return className.includes("ready-status");
        },
        { maxAttempts: 60, delayMs: 500 },
      );
    }

    const statePanel = new StatePanel(ctPage);
    const values = await statePanel.values();
    expect(values.x.text).toBe("3");
    expect(values.x.typeText).toBe("i32");

    expect(values.y.text).toBe("4");
    expect(values.y.typeText).toBe("i32");
  });

  test("continue", async ({ ctPage }) => {
    await readyOnEntry(ctPage);
    const statusBar = new StatusBar(ctPage, ctPage.locator("#status-base"));
    const layout = new LayoutPage(ctPage);
    await layout.continueButton().click();
    await retry(
      async () => {
        const status = ctPage.locator("#stable-status");
        const className = (await status.getAttribute("class")) ?? "";
        return className.includes("ready-status");
      },
      { maxAttempts: 60, delayMs: 500 },
    );
    const newLocation = await statusBar.location();
    expect(newLocation.line).toBeGreaterThanOrEqual(1);
  });

  test("next", async ({ ctPage }) => {
    await readyOnEntry(ctPage);
    const statusBar = new StatusBar(ctPage, ctPage.locator("#status-base"));
    const initialLocation = await statusBar.location();
    const layout = new LayoutPage(ctPage);

    // First next may stay on the same line (function entry in WASM traces)
    await layout.nextButton().click();
    await retry(
      async () => {
        const status = ctPage.locator("#stable-status");
        const className = (await status.getAttribute("class")) ?? "";
        return className.includes("ready-status");
      },
      { maxAttempts: 60, delayMs: 500 },
    );

    // Second next should advance to a different line
    await layout.nextButton().click();
    await retry(
      async () => {
        const status = ctPage.locator("#stable-status");
        const className = (await status.getAttribute("class")) ?? "";
        return className.includes("ready-status");
      },
      { maxAttempts: 60, delayMs: 500 },
    );

    const newLocation = await statusBar.location();
    expect(newLocation.line).toBeGreaterThanOrEqual(1);
    // Line should have changed after two steps
    expect(newLocation.line).not.toBe(initialLocation.line);
  });
});
