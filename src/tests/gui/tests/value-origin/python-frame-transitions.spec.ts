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

  // Open the origin chain for `local`: right-click → "Show value origin"
  // expands it under the row (Value-Origin-Tracking.md §3.1, §3.2.1). The
  // chain crosses the call: `local = p`, the parameter bind, `value = 7`.
  await origin.showValueOriginInPlace("local");
  await expect(origin.expandedChainHops("local").first()).toHaveText("local = p", { timeout: 15_000 });
  await expect(origin.inlineChainTerminator("local")).toHaveText("7");

  // The breadcrumbs live in the side panel: "Show in side panel" (§3.2.2).
  await origin.openInSidePanel("local");
  await expect(origin.breadcrumbChips()).toHaveCount(1, { timeout: 15_000 });
  const initialCrumbs = await origin.breadcrumbChips().count();

  // ---- A second query pushes another breadcrumb --------------------------
  // Seek to the chain's first hop (`local = p`) from the side panel, then
  // ask for the origin of the parameter `p` there, through its row's
  // in-place chain and "Show in side panel": every side-panel query pushes
  // one breadcrumb (§3.3).
  await origin.clickSidePanelHop(0);
  await expect.poll(() => statePane.variableValue("p"), {
    message: "the hop's step is inside `receive`, where `p` is 7",
    timeout: 15_000,
  }).toBe("7");
  await origin.showValueOriginInPlace("p");
  await origin.openInSidePanel("p");
  await expect.poll(() => origin.breadcrumbChips().count(), {
    message: "navigating into another origin pushes a breadcrumb",
    timeout: 15_000,
  }).toBe(initialCrumbs + 1);
  const deeperCrumbs = initialCrumbs + 1;

  // ---- Press Back (Esc + re-open via the previous breadcrumb chip) -----
  // The breadcrumb chips are <button> elements per
  // `ui/isonim_origin_chain.nim::renderPanelDom`; clicking the second-to-
  // last chip pops the LIFO stack via OriginChainVM.onPopBreadcrumb.
  await origin.breadcrumbChips().nth(deeperCrumbs - 2).click();
  await expect.poll(() => origin.breadcrumbChips().count(), {
    message: "clicking a previous breadcrumb chip pops the LIFO stack down to that depth",
    timeout: 15_000,
  }).toBe(deeperCrumbs - 1);
});
