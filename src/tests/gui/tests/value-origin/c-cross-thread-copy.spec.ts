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

test.use({ sourcePath: fixtureSource, launchMode: "trace" });
test.setTimeout(240_000);

test.beforeAll(() => {
  const reason = cRrSpecSkipReason();
  test.skip(reason !== null, reason ?? "");
});

test("e2e_origin_c_cross_thread_copy_in_codetracer_gui", async ({ ctPage }) => {
  await readyOnEntry(ctPage);
  const layout = new LayoutPage(ctPage);
  const origin = new OriginChainPanePageObject(ctPage);

  // Step to the printf line.
  await layout.runToEntryButton().click();
  await ctPage.waitForTimeout(750);
  const statePane = (await layout.programStateTabs(true))[0];
  expect(statePane, "State Pane must be present").toBeDefined();
  let localVisible = (await statePane.variableValueText("local")) !== "";
  for (let i = 0; i < 30 && !localVisible; i++) {
    await layout.nextButton().click();
    await ctPage.waitForTimeout(500);
    localVisible = (await statePane.variableValueText("local")) !== "";
  }
  expect(localVisible, "stepping must surface local `local`").toBe(true);

  // Right-click `local` → "Show value origin".
  await origin.rightClickRow("local");
  await origin.clickShowValueOriginMenuItem();
  await expect(origin.sidePanel()).toBeVisible({ timeout: 30_000 });

  // The cross-thread hop must be rendered with the icon. Locate it via
  // the test-id the renderer exposes (the M2 chain renderer assigns
  // `data-testid="origin-hop-cross-thread"` to CrossThreadCopy hops).
  const crossThreadHop = origin.sidePanel().locator(
    '[data-testid="origin-hop-cross-thread"], [data-origin-kind="CrossThreadCopy"]',
  );
  await expect(crossThreadHop.first()).toBeVisible({ timeout: 30_000 });

  // Confidence badge "0.6" must be visible on the cross-thread hop.
  await expect(crossThreadHop.first()).toContainText("0.6");
});
