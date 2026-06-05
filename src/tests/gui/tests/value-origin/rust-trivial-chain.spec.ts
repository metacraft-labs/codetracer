/**
 * M11 — Playwright spec for the Rust `simple_trivial_chain` Value
 * Origin fixture against an RR-backed trace.
 *
 * Covers M11 verification entry:
 *
 *   - e2e_origin_rust_in_codetracer_gui
 *
 * Fixture: `src/db-backend/tests/fixtures/origin/rust/simple_trivial_chain/main.rs`.
 * ANSWERS.md asserts the chain for `c` at the `println!("{}", c)` line
 * walks `c -> b -> a -> Literal(10)`.
 *
 * The spec mirrors the M5 `python-trivial-chain.spec.ts` pattern but
 * requires the full RR toolchain (rr + ct-native-replay + rustc). When
 * any of those is missing the spec SKIPs cleanly via
 * `rustRrSpecSkipReason()`.
 */
import { expect, readyOnEntryTest as readyOnEntry, test } from "../../lib/fixtures";
import { LayoutPage } from "../../page-objects/layout-page";
import { OriginChainPanePageObject } from "../../page-objects/originChainPane";
import {
  originFixturePath,
  rustRrSpecSkipReason,
} from "../../lib/value-origin-fixtures";

const fixtureSource = originFixturePath("rust", "simple_trivial_chain");

test.use({ sourcePath: fixtureSource, launchMode: "trace" });
test.setTimeout(240_000);

test.beforeAll(() => {
  const reason = rustRrSpecSkipReason();
  test.skip(reason !== null, reason ?? "");
});

test("e2e_origin_rust_in_codetracer_gui", async ({ ctPage }) => {
  await readyOnEntry(ctPage);
  const layout = new LayoutPage(ctPage);
  const origin = new OriginChainPanePageObject(ctPage);

  // Step the program to the `println!` line where `c` is in scope.
  await layout.runToEntryButton().click();
  await ctPage.waitForTimeout(750);
  const statePane = (await layout.programStateTabs(true))[0];
  expect(statePane, "State Pane must be present").toBeDefined();
  let cVisible = (await statePane.variableValueText("c")) !== "";
  for (let i = 0; i < 20 && !cVisible; i++) {
    await layout.nextButton().click();
    await ctPage.waitForTimeout(500);
    cVisible = (await statePane.variableValueText("c")) !== "";
  }
  expect(cVisible, "stepping to the println! line must surface local `c`").toBe(true);

  // Right-click `c` → "Show value origin"
  await origin.rightClickRow("c");
  await origin.clickShowValueOriginMenuItem();

  // The side panel mounts on the document body when the M11 algorithm
  // returns its chain.
  await expect(origin.sidePanel()).toBeVisible({ timeout: 30_000 });

  // ANSWERS.md asserts three TrivialCopy hops + Literal(10) terminator
  // for `c -> b -> a -> 10`.
  await expect(origin.sidePanelHops()).toHaveCount(3, { timeout: 30_000 });
  await expect(origin.sidePanelTerminator()).toBeVisible();
  await expect(origin.sidePanelTerminator()).toContainText("10");
});
