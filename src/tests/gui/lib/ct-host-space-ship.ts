/**
 * Where a `ct host` page of the `noir_space_ship` recording is, and how to get
 * it to a stop inside the asteroid loop — shared by the `tests/ct-host/` specs
 * that drive a real hosted replay.
 *
 * The page renders a mirror of the session the server owns; its editor and
 * toolbar are the page's own, so the position is read from the editor: the
 * active tab's file and the highlighted line.
 */
import type { Page } from "@playwright/test";
import { expect } from "./fixtures";
import { LayoutPage } from "../page-objects/layout-page";
import { retry } from "./retry-helpers";

export interface Position {
  file: string;
  line: number;
}

/** The active editor tab's file (base name) and its highlighted line (0 when none). */
export async function position(page: Page): Promise<Position> {
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

/**
 * The position once `accept` holds, or the last one read when it did not
 * within a minute: the caller's assertion then says where the debugger was.
 */
export async function waitForPosition(
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

/**
 * Stop in `status_report` (shield.nr), called from the asteroid loop's first
 * iteration: the event log's first "Damage:" line. The loop computes `damage`
 * (shield.nr:6) again on its next iteration.
 */
export async function stopInFirstStatusReport(page: Page): Promise<void> {
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
}
