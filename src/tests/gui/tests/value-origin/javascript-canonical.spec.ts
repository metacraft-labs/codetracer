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

/** ANSWERS.md, as the in-row chain draws it: `lhs = rhs` per hop, newest
 *  first; the terminator is the literal. */
const EXPECTED_HOPS = ["c = b", "b = a", "a = 10"];

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
    // Until `c` holds its value, not merely until it is listed: a local can
    // be listed before its assignment runs, and its origin there is not the
    // chain.
    if ((await statePane.variableValue("c")) === "10") {
      break;
    }
    await layout.nextButton().click();
    await ctPage.waitForTimeout(500);
  }
  expect(await statePane.variableValue("c"), "stepping must reach `c`'s assignment").toBe("10");

  // Right-click → "Show value origin" expands the chain under the row
  // (Value-Origin-Tracking.md §3.1, §3.2.1). Three hops + Literal(10), per
  // the fixture's ANSWERS.md.
  await origin.showValueOriginInPlace("c");
  await expect(origin.expandedChainHops("c")).toHaveText(EXPECTED_HOPS, { timeout: 15_000 });
  await expect(origin.inlineChainTerminator("c")).toHaveText("10");
});
