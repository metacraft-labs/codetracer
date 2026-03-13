import { test, expect, readyOnEntryTest as readyOnEntry, loadedEventLog } from "../../lib/fixtures";
import { StatusBar } from "../../page-objects/status_bar";
import { StatePanel } from "../../page-objects/state";
import { retry } from "../../lib/retry-helpers";

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

  // WASM backend does not send CtCompleteMove on trace load, so .location-path
  // never appears. Re-enable once the WASM db-backend supports initial location.
  test.fixme("correct entry status path/line", async ({ ctPage }) => {
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

  // Event log footer count is not populated for WASM/DB traces yet.
  // Re-enable once the frontend populates the event count for DB traces.
  test.fixme("expected event count", async ({ ctPage }) => {
    await loadedEventLog(ctPage);

    const raw = await ctPage.$eval(
      ".data-tables-footer-rows-count",
      (el) => el.textContent ?? "",
    );
    const match = raw.match(/(\d+)/);
    expect(match).not.toBeNull();
    const count = parseInt(match![1], 10);
    expect(count).toBeGreaterThanOrEqual(1);
  });

  // WASM backend does not send CtCompleteMove on trace load, so readyOnEntry
  // times out. Re-enable once the WASM db-backend supports initial location.
  test.fixme("state panel loaded initially", async ({ ctPage }) => {
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

  // WASM DB-based debugger variable inspection may not be fully supported yet.
  // Re-enable once wazero trace support includes variable inspection.
  test.fixme("state panel supports integer values", async ({ ctPage }) => {
    await readyOnEntry(ctPage);
    const statePanel = new StatePanel(ctPage);

    const values = await statePanel.values();
    expect(values.x.text).toBe("3");
    expect(values.x.typeText).toBe("i32");

    expect(values.y.text).toBe("4");
    expect(values.y.typeText).toBe("i32");
  });

  // Debug movement (continue/next) may not work for WASM traces in browser
  // mode. Re-enable once the backend implements movement for WASM traces.
  test.fixme("continue", async () => {
    // Requires debug movement counter support in WASM backend.
  });

  test.fixme("next", async () => {
    // Requires debug movement counter support in WASM backend.
  });
});
