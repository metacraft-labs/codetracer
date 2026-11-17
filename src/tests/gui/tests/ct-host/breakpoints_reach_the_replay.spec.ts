// A breakpoint set in a `ct host` page's editor stops the replay, and a
// cleared one does not.
//
// Under `ct host` the server owns the client's session and the page renders a
// mirror of it (Shared-DOM-Front-Ends, "Server-managed sessions"), whose own
// backend is inert. A press on a line's glyph cell holds the breakpoint in the
// page's store and sends the file's set to the replay (`sdk/breakpoints`). The
// page sent it through the mirror's inert backend: the gutter showed the
// breakpoint, the replay never received it, and Continue ran to the end of
// `main`. The change is now relayed to the server's session, which sends it
// over its connection to the replay the page's Continue runs
// (`mirror_session.hostedPageRelays`, `action_relay`'s `breakpoints` arm). The
// headless half is `test_session_mirroring.nim`, "a breakpoint set on the page
// is sent to the replay by the server's session".
//
// The stop: the event log's first "Damage:" line stops in `status_report`
// (shield.nr), called from the asteroid loop's first iteration; the loop's next
// iteration computes `damage` on shield.nr:6 again.
//
// No stand-ins: the real `ct host`, a real replay, a real browser.

import type { Page } from "@playwright/test";
import { test, expect } from "../../lib/fixtures";
import { LayoutPage } from "../../page-objects/layout-page";
import { glyphMarksOn, pressGlyph } from "../../lib/glyph-column";
import { stopInFirstStatusReport, waitForPosition } from "../../lib/ct-host-space-ship";
import { retry } from "../../lib/retry-helpers";

test.use({ sourcePath: "noir_space_ship/", launchMode: "trace", deploymentMode: "web" });
// Starting a ct host and its replay takes minutes on a loaded host.
test.setTimeout(360_000);

/** The line `damage` is computed on, in test-programs/noir_space_ship/src/shield.nr. */
const DAMAGE_LINE = 6;

/**
 * How far the page's breakpoint on shield.nr:`line` has got (`ctBreakpointRows`):
 * `requested` while only the page holds it, `verified` once the engine bound it
 * and the server's session published the row; "" when there is none.
 */
async function resolutionOn(page: Page, line: number): Promise<string> {
  return await page.evaluate((line) => {
    const rows = (globalThis as any).ctBreakpointRows?.() ?? [];
    const row = rows.find((r: any) => String(r.path).endsWith("shield.nr") && r.line === line);
    return row ? String(row.resolution) : "";
  }, line);
}

test("a breakpoint set on a ct host page stops Continue, and a cleared one does not", async ({
  ctPage,
}) => {
  await stopInFirstStatusReport(ctPage);
  const layout = new LayoutPage(ctPage);

  // SET: the gutter shows it, the engine binds it, and Continue stops on it.
  await pressGlyph(ctPage, DAMAGE_LINE);
  await retry(
    async () =>
      (await glyphMarksOn(ctPage, DAMAGE_LINE)).some((m) => m.includes("breakpoint")),
    { maxAttempts: 60, delayMs: 250 },
  );
  // Bound by the replay: the row the server's session holds once the engine
  // answered. Before the fix it stayed `requested` — no request reached the
  // replay.
  await expect
    .poll(async () => await resolutionOn(ctPage, DAMAGE_LINE), { timeout: 60_000 })
    .toBe("verified");
  await layout.clickContinueButton();
  const stopped = await waitForPosition(
    ctPage,
    (p) => p.file === "shield.nr" && p.line === DAMAGE_LINE,
  );
  expect(stopped, "Continue stops on the breakpoint").toEqual({
    file: "shield.nr",
    line: DAMAGE_LINE,
  });

  // CLEAR: the gutter drops it, and Continue runs past the line to the end of
  // `main` — the loop computes `damage` again on later iterations. The clear
  // and the Continue leave the page in that order over its one socket, and the
  // server writes both to the Backend Manager over its one connection
  // (`index/hosted_session`), so the replay has the empty set before it runs.
  await pressGlyph(ctPage, DAMAGE_LINE);
  await retry(
    async () =>
      !(await glyphMarksOn(ctPage, DAMAGE_LINE)).some((m) => m.includes("breakpoint")),
    { maxAttempts: 60, delayMs: 250 },
  );
  expect(await resolutionOn(ctPage, DAMAGE_LINE)).toBe("");
  await layout.clickContinueButton();
  const ran = await waitForPosition(ctPage, (p) => p.file === "main.nr");
  expect(ran.file, `Continue runs past the cleared breakpoint: ${JSON.stringify(ran)}`).toBe(
    "main.nr",
  );
});
