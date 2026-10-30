/**
 * plat58-requests-capture.spec.ts — PLAT-58, the desktop's column: the
 * REFERENCE the terminal's and the GPUI window's Requests panes are measured
 * against.
 *
 * Spec: codetracer-pm `spec/GUI/Core-Panes/Request-Panel.md` § "The terminal
 * and the GPUI window (PLAT-58)".
 *
 * The real Electron front-end on the RS-M4 demo session — a real `.ct`
 * container with eight request spans over a recorded timeline, written by
 * the canonical writer (`src/tools/demo_request_session`, the producer `just
 * demo-request-panel` runs; `just plat58-capture-electron` writes it and
 * names it in `PLAT58_DEMO_TRACE`) — its REQUESTS panel read from the DOM:
 *
 *   * the panel, docked by itself (RS-M4), lists every request: `#`,
 *     method, URL, status, duration, size, each status's class and colour;
 *   * the filter bar's words; the header's;
 *   * a row's right-click menu (PLAT-58 added it): its entries and which are
 *     disabled;
 *   * Filter by Method from that menu narrows the rows; Clear Filters
 *     restores them;
 *   * a double click on a row moves the debugger to the request's handler:
 *     the location's line and step afterwards.
 *
 * Written to `src/tests/visual/answers/plat58-requests.electron.json`, which
 * `src/frontend/tui/tests/test_plat58_requests.nim` and
 * `src/frontend/gpui/tests/test_plat58_gpui_requests.nim` assert the native
 * panes against.
 *
 * No mocks: a real container, the real `ct` import, the real Electron app and
 * its real `replay-server`.
 */
import { test, expect } from "../../lib/fixtures";
import * as fs from "node:fs";
import * as path from "node:path";

const repoRoot = path.resolve(__dirname, "..", "..", "..", "..", "..");
const answersDir = path.join(repoRoot, "src", "tests", "visual", "answers");
const answersFile = path.join(answersDir, "plat58-requests.electron.json");
const demo = process.env.PLAT58_DEMO_TRACE || "";

/** Every request row the panel lists, as a reader of the DOM sees it. */
async function readRows(ctPage: any) {
  return await ctPage.evaluate(() => {
    const text = (n: Element | null) => (n ? (n.textContent || "").trim() : "");
    return Array.from(document.querySelectorAll(".request-panel .request-row")).map((row) => {
      const status = row.querySelector(".request-col-status span") as HTMLElement;
      return {
        cells: [
          text(row.querySelector(".request-col-id")),
          text(row.querySelector(".request-col-method")),
          text(row.querySelector(".request-col-url")),
          text(row.querySelector(".request-col-status")),
          text(row.querySelector(".request-col-duration")),
          text(row.querySelector(".request-col-size")),
        ],
        statusClass: status ? status.className : "",
        statusColor: status ? getComputedStyle(status).color : "",
      };
    });
  });
}

/** The open context menu's entries (label, disabled), or [] when none opened. */
async function contextMenuEntries(ctPage: any) {
  try {
    await ctPage.locator("#context-menu-container").waitFor({ state: "visible", timeout: 5_000 });
    return await ctPage.evaluate(() =>
      Array.from(document.querySelectorAll("#context-menu-container .context-menu-item")).map(
        (e) => ({
          label: ((e.querySelector(".ct-menu-item-label") || e).textContent || "").trim(),
          disabled: e.classList.contains("ct-menu-item--disabled"),
        }),
      ),
    );
  } catch {
    return [];
  }
}

async function chooseMenu(ctPage: any, label: string) {
  await ctPage
    .locator("#context-menu-container .context-menu-item", { hasText: label })
    .first()
    .click();
}

async function location(ctPage: any) {
  return await ctPage.evaluate(() => {
    const loc = (window as any)?.data?.services?.debugger?.location;
    return loc ? { line: loc.line, rrTicks: Number(loc.rrTicks) } : null;
  });
}

test.describe("PLAT-58: the desktop's REQUESTS panel, captured", () => {
  test.skip(!demo, "PLAT58_DEMO_TRACE names the demo session (just plat58-capture-electron)");
  test.use({ launchMode: "trace-folder", sourcePath: demo });
  test.setTimeout(300_000);

  test("rows, filter bar, a row's menu, a filter from it, a double click", async ({ ctPage }) => {
    const rows = ctPage.locator(".request-panel .request-row");
    // The panel docks ITSELF: the demo session serves requests, so RS-M4's
    // reveal brings the REQUESTS panel on screen with no click. Clicking its
    // strip label here would be wrong twice over — it would hide a revealed
    // panel (the label toggles a docked panel) and it would mask a reveal
    // that never happened.
    await expect(ctPage.locator(".lm_goldenlayout")).toBeVisible({ timeout: 120_000 });
    await expect(rows).toHaveCount(8, { timeout: 120_000 });
    const listed = await readRows(ctPage);
    const filterBar = await ctPage.evaluate(() => ({
      search: (document.querySelector(".request-filter-search") as HTMLInputElement)?.placeholder || "",
      pickers: Array.from(document.querySelectorAll(".request-panel .ct-picker-label")).map(
        (e) => (e.textContent || "").trim(),
      ),
      header: Array.from(document.querySelectorAll(".request-table-header > div")).map(
        (e) => (e.textContent || "").trim(),
      ),
    }));

    // A ROW'S MENU (PLAT-58): request 08, PUT /api/orders/7, 500.
    await rows.nth(6).click({ button: "right" });
    const rowMenu = await contextMenuEntries(ctPage);
    await chooseMenu(ctPage, "Filter by Method: PUT");
    await expect(rows).toHaveCount(1, { timeout: 30_000 });
    const filtered = await readRows(ctPage);
    await rows.first().click({ button: "right" });
    const filteredMenu = await contextMenuEntries(ctPage);
    await chooseMenu(ctPage, "Clear Filters");
    await expect(rows).toHaveCount(8, { timeout: 30_000 });

    // A DOUBLE CLICK: request 04's handler, without re-aiming between the
    // first selection (which opens the detail) and the second press.
    const before = await location(ctPage);
    await rows.nth(2).dblclick();
    await expect.poll(async () => (await location(ctPage))?.rrTicks, { timeout: 60_000 }).not.toBe(
      before?.rrTicks,
    );
    const after = await location(ctPage);

    const out = {
      _comment: [
        "PLAT-58 — the desktop's REQUESTS panel on the RS-M4 demo session, read from the real Electron app.",
        "Produced by src/tests/gui/tests/request-panel/plat58-requests-capture.spec.ts",
        "(`just plat58-capture-electron`).",
      ],
      rows: listed,
      filterBar,
      rowMenu,
      filteredByMethod: filtered,
      filteredMenu,
      doubleClick: { request: "04", before, after },
    };
    fs.mkdirSync(answersDir, { recursive: true });
    fs.writeFileSync(answersFile, JSON.stringify(out, null, 1) + "\n");

    expect(listed.map((r: any) => r.cells[0])).toEqual(["02", "03", "04", "05", "06", "07", "08", "09"]);
    expect(rowMenu.map((e: any) => e.label)).toEqual([
      "Go to Handler",
      "Copy URL",
      "Filter by Method: PUT",
      "Filter by Status: 5xx",
      "Clear Filters",
    ]);
    expect(filtered.map((r: any) => r.cells[0])).toEqual(["08"]);
    expect(after?.line).toBe(13);
    expect(after?.rrTicks).toBe(6 + 7 * 2);
  });
});
