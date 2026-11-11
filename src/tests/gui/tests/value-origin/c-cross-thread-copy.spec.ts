/**
 * M11 — Playwright spec for the multi-threaded C `cross_thread_copy`
 * Value Origin fixture against an RR-backed trace.
 *
 * Covers M11 verification entry:
 *
 *   - e2e_origin_c_cross_thread_copy_in_codetracer_gui
 *
 * Fixture: `src/db-backend/tests/fixtures/origin/c/cross_thread_copy/main.c`.
 * ANSWERS.md asserts at least one hop in the returned chain carries
 * `kind=CrossThreadCopy` and `confidence == 0.6`, with the chain panel
 * rendering the cross-thread icon and the confidence badge "0.6".
 */
import { expect, readyOnEntryTest as readyOnEntry, test } from "../../lib/fixtures";
import { LayoutPage } from "../../page-objects/layout-page";
import { OriginChainPanePageObject } from "../../page-objects/originChainPane";
import {
  cRrSpecSkipReason,
  originFixturePath,
} from "../../lib/value-origin-fixtures";

const fixtureSource = originFixturePath("c", "cross_thread_copy");

// Recorded with rr, as the skip gate above it assumes (`cRrSpecSkipReason`
// checks the rr toolchain): the cross-thread hop is the M11 rr algorithm's
// (it switches the replay to the writing thread). The default backend is
// MCR, and MCR cannot replay this program yet: `ct-mcr debugserver` refuses
// a recording of more than one thread ("a multi-threaded recording needs
// multi-threaded emulator replay (XMR-B1) first"), so no stop was ever
// reported and the entry readiness wait timed out.
test.use({ sourcePath: fixtureSource, launchMode: "trace", recordBackend: "rr" });
test.setTimeout(240_000);

test.beforeAll(() => {
  const reason = cRrSpecSkipReason();
  test.skip(reason !== null, reason ?? "");
});

test("e2e_origin_c_cross_thread_copy_in_codetracer_gui", async ({ ctPage }) => {
  await readyOnEntry(ctPage);
  const layout = new LayoutPage(ctPage);
  const origin = new OriginChainPanePageObject(ctPage);

  // Step to the printf line: until `local` holds the 99 the writer thread
  // stored (listed is not enough — it is listed, as 0, before the load).
  await layout.runToEntryButton().click();
  await ctPage.waitForTimeout(750);
  const statePane = (await layout.programStateTabs(true))[0];
  expect(statePane, "State Pane must be present").toBeDefined();
  let localLoaded = (await statePane.variableValue("local")) === "99";
  for (let i = 0; i < 30 && !localLoaded; i++) {
    await layout.nextButton().click();
    await ctPage.waitForTimeout(500);
    localLoaded = (await statePane.variableValue("local")) === "99";
  }
  expect(localLoaded, "stepping must reach the load of `local` (99)").toBe(true);

  // Right-click `local` → "Show value origin": the chain expands under the
  // row (Value-Origin-Tracking.md §3.1, §3.2.1). The cross-thread hop
  // carries its classification icon (§3.2.2), and the terminator is the
  // writer's literal.
  await origin.showValueOriginInPlace("local");
  await expect(
    origin.expandedChainHops("local").locator(".ct-origin-icon-cross-thread"),
    "the chain has a cross-thread hop",
  ).toHaveCount(1, { timeout: 30_000 });
  await expect(origin.inlineChainTerminator("local")).toContainText("99");

  // In the side panel the hop says what it is in its accessible name
  // (§13.0, `hopAriaLabel`), and shows its confidence (spec §6.3
  // "Cross-thread guard": 0.6) as text, as §13.0 requires of a
  // low-confidence hop. The side panel draws no confidence yet: that half
  // stays red until it does (codetracer-pm issue
  // `2026-11-12-desktop-origin-side-panel-shows-no-hop-confidence`). It used
  // to look for `data-testid="origin-hop-cross-thread"`, which nothing
  // renders.
  await origin.openInSidePanel("local");
  const crossThreadHop = origin.sidePanel()
    .locator('section > ol > li.ct-origin-hop[aria-label*="cross-thread copy"]');
  await expect(crossThreadHop).toHaveCount(1, { timeout: 30_000 });
  await expect(crossThreadHop).toContainText("0.6");
});
