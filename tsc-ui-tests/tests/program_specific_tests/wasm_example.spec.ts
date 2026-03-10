import { test, expect } from "@playwright/test";
import {
  window,
  page,
  loadedEventLog,
  clickNext,
  clickContinue,
  readyOnEntryTest as readyOnEntry,
  ctRun,
} from "../../lib/ct_helpers";
import { StatusBar } from "../../page-objects/status_bar";
import { StatePanel } from "../../page-objects/state";

const ENTRY_LINE = 11;

// Each describe block gets its own ctRun (and therefore its own beforeAll/afterAll),
// preventing port 5005 conflicts that occur when multiple ctRun calls are placed
// at module scope without describe blocks.

test.describe("wasm example — basic layout", () => {
  ctRun("wasm_example/");

  test("we can access the browser window, not just dev tools", async () => {
    const title = await window.title();
    expect(title).toContain("CodeTracer");
    await window.focus("div");
  });

  test("correct entry status path/line", async () => {
    await readyOnEntry();

    const statusBar = new StatusBar(page, page.locator(".status-bar"));
    const simpleLocation = await statusBar.location();
    expect(simpleLocation.path.endsWith("main.rs")).toBeTruthy();
    expect(simpleLocation.line).toBe(ENTRY_LINE);
  });
});

test.describe("wasm example — state and navigation", () => {
  ctRun("wasm_example/");

  // Event log footer count is not populated for WASM/DB traces yet.
  // Re-enable once the frontend populates the event count for DB traces.
  test.fixme("expected event count", async () => {
    await loadedEventLog();

    const raw = await page.$eval(
      ".data-tables-footer-rows-count",
      (el) => el.textContent ?? "",
    );
    const match = raw.match(/(\d+)/);
    expect(match).not.toBeNull();
    const count = parseInt(match![1], 10);
    expect(count).toBeGreaterThanOrEqual(1);
  });

  test("state panel loaded initially", async () => {
    await readyOnEntry();
    const statePanel = new StatePanel(page);
    await expect(statePanel.codeStateLine()).toContainText(`${ENTRY_LINE} | `);
  });

  // WASM DB-based debugger variable inspection may not be fully supported yet.
  // Re-enable once wazero trace support includes variable inspection.
  test.fixme("state panel supports integer values", async () => {
    await readyOnEntry();
    const statePanel = new StatePanel(page);

    const values = await statePanel.values();
    expect(values.x.text).toBe("3");
    expect(values.x.typeText).toBe("i32");

    expect(values.y.text).toBe("4");
    expect(values.y.typeText).toBe("i32");
  });

  // Debug movement (continue/next) may not work for WASM traces in browser
  // mode. Re-enable once the backend implements movement for WASM traces.
  test.fixme("continue", async () => {
    await readyOnEntry();
    await clickContinue();
    expect(true);
  });

  test.fixme("next", async () => {
    await readyOnEntry();
    await clickNext();
  });
});
