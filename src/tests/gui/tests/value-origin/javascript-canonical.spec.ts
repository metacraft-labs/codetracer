/**
 * M5 — Playwright spec for the JavaScript `simple_trivial_chain`
 * fixture.
 *
 * Covers M5 verification entry:
 *
 *   - e2e_origin_javascript_canonical_chain
 *
 * Fixture: `src/db-backend/tests/fixtures/origin/javascript/simple_trivial_chain/main.js`.
 * ANSWERS.md asserts the chain for `c` walks `c -> b -> a ->
 * Literal(Number, 10)`.
 */
import { expect, readyOnEntryTest as readyOnEntry, test } from "../../lib/fixtures";
import { LayoutPage } from "../../page-objects/layout-page";
import { OriginChainPanePageObject } from "../../page-objects/originChainPane";
import {
  javascriptSpecSkipReason,
  originFixturePath,
} from "../../lib/value-origin-fixtures";

const fixtureSource = originFixturePath("javascript", "simple_trivial_chain");

test.use({ sourcePath: fixtureSource, launchMode: "trace" });
test.setTimeout(180_000);

test.beforeAll(() => {
  const reason = javascriptSpecSkipReason();
  test.skip(reason !== null, reason ?? "");
});

test("e2e_origin_javascript_canonical_chain", async ({ ctPage }) => {
  await readyOnEntry(ctPage);
  const layout = new LayoutPage(ctPage);
  const origin = new OriginChainPanePageObject(ctPage);

  await layout.runToEntryButton().click();
  await ctPage.waitForTimeout(750);
  const statePane = (await layout.programStateTabs(true))[0];
  for (let i = 0; i < 12; i++) {
    if ((await statePane.variableValueText("c")) !== "") {
      break;
    }
    await layout.nextButton().click();
    await ctPage.waitForTimeout(500);
  }

  await origin.rightClickRow("c");
  await origin.clickShowValueOriginMenuItem();
  await expect(origin.sidePanel()).toBeVisible({ timeout: 15_000 });

  await expect(origin.sidePanelHops()).toHaveCount(3, { timeout: 15_000 });
  await expect(origin.sidePanelTerminator()).toContainText("10");
});
