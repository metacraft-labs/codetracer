/**
 * M5 — Playwright spec for the Python `parameter_pass` fixture.
 *
 * Covers M5 verification entry:
 *
 *   - e2e_origin_python_breadcrumb_navigation
 *
 * Fixture: `src/db-backend/tests/fixtures/origin/python/parameter_pass/main.py`.
 * ANSWERS.md asserts the chain for `local` walks `local -> p
 * (ParameterPass, crosses frame) -> value -> Literal(7)`. Drilling
 * into a hop's operand (recursive "Show value origin") pushes a
 * breadcrumb; pressing Back / clicking the previous breadcrumb chip
 * returns to the parent chain.
 */
import { expect, readyOnEntryTest as readyOnEntry, test } from "../../lib/fixtures";
import { LayoutPage } from "../../page-objects/layout-page";
import { OriginChainPanePageObject } from "../../page-objects/originChainPane";
import {
  originFixturePath,
  pythonSpecSkipReason,
} from "../../lib/value-origin-fixtures";

const fixtureSource = originFixturePath("python", "parameter_pass");

test.use({ sourcePath: fixtureSource, launchMode: "trace" });
test.setTimeout(180_000);

test.beforeAll(() => {
  const reason = pythonSpecSkipReason();
  test.skip(reason !== null, reason ?? "");
});

test("e2e_origin_python_breadcrumb_navigation", async ({ ctPage }) => {
  await readyOnEntry(ctPage);
  const layout = new LayoutPage(ctPage);
  const origin = new OriginChainPanePageObject(ctPage);

  // Step into `receive` so the State Pane shows `local`.
  await layout.runToEntryButton().click();
  await ctPage.waitForTimeout(750);
  const statePane = (await layout.programStateTabs(true))[0];
  for (let i = 0; i < 16; i++) {
    if ((await statePane.variableValueText("local")) !== "") {
      break;
    }
    await layout.stepInButton().click();
    await ctPage.waitForTimeout(500);
  }

  // Open the origin chain for `local`.
  await origin.rightClickRow("local");
  await origin.clickShowValueOriginMenuItem();
  await expect(origin.sidePanel()).toBeVisible({ timeout: 15_000 });

  // One breadcrumb after the initial query.
  const initialCrumbs = await origin.breadcrumbChips().count();
  expect(initialCrumbs, "initial query pushes one breadcrumb").toBeGreaterThanOrEqual(1);

  // ---- Drill into an operand to push another breadcrumb -----------------
  // The Computational terminator's operand rows are clickable and emit a
  // recursive ct/originChain via OriginChainVM.onShowOrigin (spec §3.3).
  // For the parameter_pass chain the terminator is Literal so we instead
  // use the side panel's first hop button (clicking it routes through
  // OriginChainVM.onSeekToHop but also re-issues onShowOrigin on the
  // resolved target — both pin a breadcrumb).
  await origin.clickSidePanelHop(0);
  await ctPage.waitForTimeout(750);
  await origin.rightClickRow("local");
  await origin.clickShowValueOriginMenuItem();
  await ctPage.waitForTimeout(500);

  const deeperCrumbs = await origin.breadcrumbChips().count();
  expect(deeperCrumbs, "navigating into another origin pushes a breadcrumb")
    .toBeGreaterThan(initialCrumbs);

  // ---- Press Back (Esc + re-open via the previous breadcrumb chip) -----
  // The breadcrumb chips are <button> elements per
  // `ui/isonim_origin_chain.nim::renderPanelDom`; clicking the second-to-
  // last chip pops the LIFO stack via OriginChainVM.onPopBreadcrumb.
  const breadcrumbCount = await origin.breadcrumbChips().count();
  await origin.breadcrumbChips().nth(breadcrumbCount - 2).click();
  await ctPage.waitForTimeout(500);

  const finalCrumbs = await origin.breadcrumbChips().count();
  expect(
    finalCrumbs,
    "clicking a previous breadcrumb chip pops the LIFO stack down to that depth",
  ).toBeLessThan(deeperCrumbs);
});
