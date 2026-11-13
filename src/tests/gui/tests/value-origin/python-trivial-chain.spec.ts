/**
 * M5 — Playwright spec for the Python `simple_trivial_chain` Value
 * Origin fixture.
 *
 * The three-hop chain, the hop that seeks the editor and the side panel's
 * keys are the scenarios `src/tests/scenarios/value-origin/python-chain-*`
 * and `python-side-panel-keyboard.yaml`; the axe-core scan stays here, a
 * privileged observation no scenario step can make.
 *
 * Covered M5 verification entries:
 *
 *   - e2e_origin_python_trivial_chain_renders_three_hops
 *   - e2e_origin_python_click_hop_seeks_editor
 *   - e2e_origin_python_trivial_chain_a11y
 *   - e2e_origin_keyboard_navigation
 *
 * Fixture: `src/db-backend/tests/fixtures/origin/python/simple_trivial_chain/main.py`.
 * ANSWERS.md asserts the chain for `c` at the `print(c)` line walks
 * `c -> b -> a -> Literal(10)`.
 *
 * Right-click → "Show value origin" expands the chain IN PLACE under the
 * row (Value-Origin-Tracking.md §3.1, §3.2.1; until 2026-10-29 it opened
 * the side panel). The side panel is reached from the expanded chain's
 * "Show in side panel" (§3.2.2), which the a11y and keyboard cases use.
 *
 * The spec uses `test.use({ sourcePath: <absolute>, launchMode: "trace" })`
 * so the existing harness's `recordTestProgram(fullSourcePath)` path
 * records the trace on demand via `ct record`. When the Python
 * recorder isn't installed in this environment (the M3 layer
 * SKIPs-cleanly in the same scenario per
 * `origin_python_dap_test.rs::require_python_recorder`) the spec
 * SKIPs itself with the same reason.
 */
import type { Page } from "@playwright/test";
import { AxeBuilder } from "@axe-core/playwright";
import { expect, readyOnEntryTest as readyOnEntry, test } from "../../lib/fixtures";
import { LayoutPage } from "../../page-objects/layout-page";
import { OriginChainPanePageObject } from "../../page-objects/originChainPane";
import {
  originFixturePath,
  pythonSpecSkipReason,
} from "../../lib/value-origin-fixtures";

const fixtureSource = originFixturePath("python", "simple_trivial_chain");

test.use({ sourcePath: fixtureSource, launchMode: "trace" });
test.setTimeout(180_000);

// Honest deferral: when the recorder + build aren't both available,
// SKIP rather than throwing from `recordTestProgram`.
test.beforeAll(() => {
  const reason = pythonSpecSkipReason();
  test.skip(reason !== null, reason ?? "");
});

/** ANSWERS.md, as the in-row chain draws it (`lhs = rhs` per hop, newest
 *  first, then the terminator). */
const EXPECTED_HOPS = ["c = b", "b = a", "a = 10"];

/** Run to the entry, then step until the State Pane shows local `c` (the
 *  `print(c)` line). */
async function stepToPrintC(page: Page, layout: LayoutPage): Promise<void> {
  await layout.runToEntryButton().click();
  await page.waitForTimeout(750);
  const statePane = (await layout.programStateTabs(true))[0];
  expect(statePane, "State Pane must be present").toBeDefined();
  // Until `c` holds its value, not merely until it is listed: a local can be
  // listed before its assignment runs (uninitialised in Rust), and its
  // origin there is not the chain.
  let cVisible = (await statePane.variableValue("c")) === "10";
  for (let i = 0; i < 12 && !cVisible; i++) {
    await layout.nextButton().click();
    await page.waitForTimeout(500);
    cVisible = (await statePane.variableValue("c")) === "10";
  }
  expect(cVisible, "stepping to the print(c) line must surface local `c`").toBe(true);
}

test("e2e_origin_python_trivial_chain_a11y", async ({ ctPage }) => {
  await readyOnEntry(ctPage);
  const layout = new LayoutPage(ctPage);
  const origin = new OriginChainPanePageObject(ctPage);
  await stepToPrintC(ctPage, layout);

  await origin.showValueOriginInPlace("c");
  await expect(origin.expandedChainHops("c")).toHaveText(EXPECTED_HOPS, { timeout: 15_000 });

  // axe-core scan scoped to this feature's surfaces (the broader editor
  // is governed by a separate top-level a11y suite): first the chain
  // under the row, then the side panel its "Show in side panel" opens.
  // Legacy mode: the default mode finishes the run in a new blank page,
  // and Electron refuses to create one (`Target.createTarget: Not
  // supported`). Legacy mode runs axe inside this page.
  const inPlace = await new AxeBuilder({ page: ctPage })
    .setLegacyMode(true)
    .include('[data-variable-name="c"] .ct-origin-inline-chain')
    .analyze();
  expect(
    inPlace.violations,
    `a11y violations on the in-row origin chain: ${JSON.stringify(inPlace.violations, null, 2)}`,
  ).toEqual([]);

  await origin.openInSidePanel("c");
  await expect(origin.sidePanelHops()).toHaveCount(3, { timeout: 15_000 });
  const results = await new AxeBuilder({ page: ctPage })
    .setLegacyMode(true)
    .include("aside#ct-origin-chain-side-panel")
    .analyze();
  expect(
    results.violations,
    `a11y violations on Origin Chain Panel: ${JSON.stringify(results.violations, null, 2)}`,
  ).toEqual([]);
});

