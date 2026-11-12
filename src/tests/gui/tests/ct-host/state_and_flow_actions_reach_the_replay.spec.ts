// Two actions of a `ct host` page that must reach the replay: opening a
// variable's value history in the state pane, and "Jump to value" on a flow
// value.
//
// Under `ct host` the server owns the client's session and the page renders a
// mirror of it (Shared-DOM-Front-Ends, "Server-managed sessions"), whose own
// backend is inert.
//
// * VALUE HISTORY. The state pane's "Toggle history value" asks the replay for
//   the variable's history (`ct/load-history`). The page's ViewModel sent it
//   through the mirror's inert backend, so the row opened and stayed empty.
//   The toggle is now relayed to the server's session, which loads the
//   history over its connection to the replay and publishes it to the page
//   (`mirror_session.hostedPageRelays`, `debugger_session.markReady`). The
//   headless half is `test_session_mirroring.nim`, "a value history opened on
//   the page is loaded by the server's session".
// * JUMP TO VALUE. The flow's value jump is debounced on a timer
//   (`ui/flow.afterJump`), which added a JS Number to a BigInt and threw
//   "Cannot mix BigInt and other types" before it could jump: neither a click
//   on a flow value nor its menu's "Jump to value" moved the debugger. The
//   flow is the page's, so this is not specific to `ct host`; this page is
//   where it was found.
//
// Both start from the same stop: the event log's first "Damage:" line stops in
// `status_report`, and a step out lands in `iterate_asteroids`, after the
// loop's first iteration computed `damage` (shield.nr:6) and `remaining_shield`.
//
// No stand-ins: the real `ct host`, a real replay, a real browser.

import type { Page } from "@playwright/test";
import { test, expect } from "../../lib/fixtures";
import { LayoutPage } from "../../page-objects/layout-page";
import { ContextMenu } from "../../page-objects/components/context-menu";
import { FlowValue } from "../../page-objects/panes/editor/flow-value";
import { retry } from "../../lib/retry-helpers";

test.use({ sourcePath: "noir_space_ship/", launchMode: "trace", deploymentMode: "web" });
// Starting a ct host and its replay takes minutes on a loaded host.
test.setTimeout(360_000);

/** The line `damage` is computed on, in test-programs/noir_space_ship/src/shield.nr. */
const DAMAGE_LINE = 6;
/** The line `iterate_asteroids` calls `status_report` on. */
const STATUS_REPORT_CALL_LINE = 14;

interface Position {
  file: string;
  line: number;
}

/** The active editor tab's file (base name) and its highlighted line (0 when none). */
async function position(page: Page): Promise<Position> {
  return await page.evaluate(() => {
    // A tab is titled by the file's path in the recording ("src/shield.nr").
    const title =
      [...document.querySelectorAll(".lm_tab.lm_active .lm_title")]
        .map((e) => e.textContent ?? "")
        .find((t) => t.endsWith(".nr")) ?? "";
    const file = title.split("/").pop() ?? "";
    const active = document.querySelector(
      ".monaco-editor .margin .line-numbers.active-line-number",
    );
    return { file, line: Number(active?.textContent ?? "0") || 0 };
  });
}

async function waitForPosition(
  page: Page,
  accept: (p: Position) => boolean,
): Promise<Position> {
  let at: Position = { file: "", line: 0 };
  try {
    await retry(
      async () => {
        at = await position(page);
        return accept(at);
      },
      { maxAttempts: 120, delayMs: 500 },
    );
  } catch {
    // Fall through: the caller's assertion says where the debugger was.
  }
  return at;
}

function stateRow(page: Page, name: string) {
  return page.locator(`div[id^='stateComponent'] [data-variable-name="${name}"]`).first();
}

/**
 * Stop in `iterate_asteroids` after its first iteration's `status_report`
 * call: the event log's first "Damage:" line, then a step out.
 */
async function stopAfterFirstStatusReport(page: Page): Promise<void> {
  const layout = new LayoutPage(page);
  await layout.waitForAllComponentsLoaded();
  // The server's session has reached the page: its call trace is shown.
  await retry(
    async () =>
      (await page.locator("div[id^='calltraceComponent'] .calltrace-call-line").count()) > 0,
    { maxAttempts: 240, delayMs: 500 },
  );

  const damageEvent = page
    .locator("div[id^='eventLogComponent'] .eventLog-dense-table tbody tr")
    .filter({ hasText: "Damage:" })
    .first();
  await damageEvent.waitFor({ state: "visible", timeout: 60_000 });
  await damageEvent.click({ force: true });
  const inReport = await waitForPosition(page, (p) => p.file === "shield.nr" && p.line > 50);
  expect(inReport.file, JSON.stringify(inReport)).toBe("shield.nr");

  await layout.clickStepOutButton();
  const back = await waitForPosition(
    page,
    (p) => p.file === "shield.nr" && p.line === STATUS_REPORT_CALL_LINE,
  );
  expect(back, "the step out returns to the status_report call").toEqual({
    file: "shield.nr",
    line: STATUS_REPORT_CALL_LINE,
  });
}

test("a variable's value history loads in a ct host page", async ({ ctPage }) => {
  await stopAfterFirstStatusReport(ctPage);

  const row = stateRow(ctPage, "remaining_shield");
  await row.waitFor({ state: "visible", timeout: 60_000 });
  await row.locator("#value-history").first().click({ force: true });

  // The history: one row per value the variable held, each a navigation row
  // carrying the tick it was recorded at and the value.
  const historyRows = row.locator(".ct-history-inline-row");
  await expect
    .poll(async () => await historyRows.count(), { timeout: 60_000 })
    .toBeGreaterThan(0);
  await expect(row.locator(".ct-history-inline-container").first()).toBeVisible();
  const first = (await historyRows.first().innerText()).trim();
  expect(first.length, "a history row shows its tick and value").toBeGreaterThan(0);
});

test("a flow value's 'Jump to value' moves the debugger to its step", async ({ ctPage }) => {
  await stopAfterFirstStatusReport(ctPage);

  const damage = ctPage
    .locator(`#flow-parallel-value-${DAMAGE_LINE} .flow-parallel-value-box[id$='-damage']`)
    .first();
  await damage.waitFor({ state: "visible", timeout: 60_000 });

  const errors: string[] = [];
  ctPage.on("pageerror", (e) => errors.push(String(e)));

  const value = new FlowValue(damage, new ContextMenu(ctPage));
  await value.selectContextMenuOption("Jump to value");

  const landed = await waitForPosition(
    ctPage,
    (p) => p.file === "shield.nr" && p.line === DAMAGE_LINE,
  );
  expect(landed, `page errors: ${JSON.stringify(errors)}`).toEqual({
    file: "shield.nr",
    line: DAMAGE_LINE,
  });
  expect(errors.filter((e) => e.includes("BigInt"))).toEqual([]);
});
