/**
 * watch-expressions-in-browser.spec.ts — a user types a watch expression
 * into the running product, in a browser, and sees a correct value.
 *
 * WHY THIS SPEC EXISTS
 * --------------------
 * Watch expressions were present in four independent places and worked in
 * none of them, and every one of those four read as success from the
 * others' point of view:
 *
 *   1. `db-backend/src/db.rs` took `watchExpressions` off the wire and
 *      dropped it with a `warn!`.
 *   2. `state_vm.nim`'s `currentVariables` memo returned a literal empty
 *      seq for the Watches tab.
 *   3. `isonim_state_view.nim`'s WebRenderer rendered no tab strip, so
 *      the Watches tab was unreachable by gesture in the browser — the
 *      surface this report came from.
 *   4. The input form wrote `StateVM.addWatch` while the request whose
 *      response the product paints read `StateComponent.watchExpressions`,
 *      a field written only by a proc with no call sites.
 *
 * Any test that drove the ViewModel directly would have passed against
 * all four. So everything below is a GESTURE: a click on the product's
 * own tab button, and keystrokes into the product's own input.
 *
 * WHAT IT ASSERTS, and why each assertion can fail for its own reason
 * -------------------------------------------------------------------
 * A NAMED expression at a NAMED step with a KNOWN value. The values are
 * not read off the pane and compared to themselves — they are the inputs
 * in `test-programs/noir_space_ship/Prover.toml`:
 *
 *     initial_shield            = "10000"
 *     asteroid_masses_positive  = ["100", "2000", "200", ...]
 *
 * so `asteroid_masses_positive[1]` is 2000 and nothing else, and an
 * indexed watch that silently returned the whole array, the first
 * element, or the locals list cannot satisfy it.
 *
 * AND THE REFUSAL PATH, which is the half this pane keeps getting wrong.
 * A pane whose two states are "a value" and "nothing" is exactly the
 * defect being fixed, so an expression that CANNOT be evaluated has its
 * own assertion: it must produce a row, and that row must carry a stated
 * reason. `initial_shield + 1` is refused because the sum was never
 * recorded — a replay cannot compute it — and the pane has to say so
 * rather than showing an empty Watches tab.
 */

import { test, expect } from "../../lib/fixtures";
import { VariableStatePane } from "../../page-objects/panes/variable-state/variable-state-pane";
import type { Page } from "@playwright/test";

/** The inputs this program was recorded with — see `Prover.toml`. */
const INITIAL_SHIELD = "10000";
const ASTEROID_MASS_AT_1 = "2000";

function statePane(page: Page): VariableStatePane {
  return new VariableStatePane(page, page.locator("#stateComponent-0"), "STATE");
}

/**
 * Everything the Watches tab is showing, as `name` -> rendered text.
 *
 * Read from the rows the product painted rather than from a ViewModel,
 * and returned WHOLE so a failure can print what the pane actually held.
 * "The expected row is missing" and "the pane has no rows at all" need
 * different fixes and a bare `toBe` cannot tell them apart.
 */
async function watchRows(page: Page): Promise<Record<string, string>> {
  return page.evaluate(() => {
    const out: Record<string, string> = {};
    const pane = document.getElementById("stateComponent-0");
    if (!pane) return out;
    for (const row of pane.querySelectorAll("[data-variable-name]")) {
      const name = row.getAttribute("data-variable-name") || "";
      // The row's own text, with the name stripped off the front so the
      // value is comparable on its own.
      const text = (row as HTMLElement).innerText || row.textContent || "";
      out[name] = text.replace(/\s+/g, " ").trim();
    }
    return out;
  });
}

test.describe("watch expressions — typed into the product, in a browser", () => {
  test.use({
    sourcePath: "noir_space_ship/",
    launchMode: "trace",
    deploymentMode: "web",
  });

  test("a typed watch shows a correct value, and an unanswerable one says why", async ({
    ctPage,
  }) => {
    const pane = statePane(ctPage);

    // The pane itself has to be there before any of this means anything.
    await ctPage.locator("#stateComponent-0").waitFor({ state: "visible", timeout: 60_000 });

    // ---- THE TAB STRIP EXISTS AND THE WATCHES TAB IS REACHABLE -------
    //
    // Asserted separately and FIRST, because it was absent from the web
    // renderer entirely. Without it every assertion below would fail for
    // the same single reason and the report would not say which layer
    // was broken.
    await expect(
      pane.stateTabButton("watches"),
      "the Watches tab button must exist in the browser renderer, not only in the Mock one",
    ).toBeVisible({ timeout: 30_000 });

    await pane.selectStateTab("watches");

    // ---- AN EMPTY WATCHES TAB SAYS IT IS EMPTY OF WATCHES ------------
    //
    // Not "No local variables are present…", which is what every tab used
    // to say. An empty state that names the wrong thing is how a user
    // concludes the feature is broken when it is merely unused.
    await expect(
      ctPage.locator("#stateComponent-0 .empty-overlay"),
      "the empty Watches tab must describe ITS emptiness, not the Locals tab's",
    ).toContainText("No watch expressions yet", { timeout: 15_000 });

    // ---- A BARE NAME ------------------------------------------------
    await pane.addWatchExpression("initial_shield");
    await expect
      .poll(async () => (await watchRows(ctPage))["initial_shield"] ?? "", {
        timeout: 45_000,
        message: "the watch `initial_shield` never produced a row in the Watches tab",
      })
      .toContain(INITIAL_SHIELD);

    // ---- AN INDEXED ELEMENT, which is the discriminating case --------
    //
    // `asteroid_masses_positive[1]` is 2000 while `[0]` is 100 and the
    // whole array contains both. An implementation that answered with
    // the array, with the wrong element, or by name-matching the
    // expression against the locals list (which is what the Python
    // bridge does) cannot produce 2000 here and only 2000.
    await pane.addWatchExpression("asteroid_masses_positive[1]");
    await expect
      .poll(async () => (await watchRows(ctPage))["asteroid_masses_positive[1]"] ?? "", {
        timeout: 45_000,
        message:
          "the indexed watch `asteroid_masses_positive[1]` never produced a row; " +
          "an index that resolves to nothing is the silent-drop defect returning",
      })
      .toContain(ASTEROID_MASS_AT_1);

    // It must be THAT element, not the array printed whole. The array
    // text contains "2000" too, so `toContain` above is not enough on
    // its own — the row must not also carry a neighbouring element.
    const rowsAfterIndex = await watchRows(ctPage);
    expect(
      rowsAfterIndex["asteroid_masses_positive[1]"],
      `the indexed watch must be the ELEMENT, not the whole array; row was: ${rowsAfterIndex["asteroid_masses_positive[1]"]}`,
    ).not.toContain("100");

    // ---- THE REFUSAL PATH, with its own assertion --------------------
    //
    // A recording holds the values that were recorded; the sum was not
    // one of them. The requirement is not that this fails — it is that
    // the user is TOLD, in the pane, with a reason. A missing row here
    // is the original defect exactly.
    await pane.addWatchExpression("initial_shield + 1");
    await expect
      .poll(async () => (await watchRows(ctPage))["initial_shield + 1"] ?? "", {
        timeout: 45_000,
        message:
          "an unanswerable watch produced NO ROW — the pane's two states are " +
          "'a value' and 'nothing', which is the defect this spec exists for",
      })
      .toContain("cannot evaluate");

    const rowsAfterRefusal = await watchRows(ctPage);
    expect(
      rowsAfterRefusal["initial_shield + 1"],
      "the refusal must say WHY a recording cannot answer it, not merely that it failed",
    ).toContain("only holds the values that were actually recorded");

    // A refusal must not have cost the working watches their rows.
    expect(
      rowsAfterRefusal["initial_shield"],
      "a refused watch must not disturb the watches that resolve",
    ).toContain(INITIAL_SHIELD);

    await ctPage.screenshot({
      path: "test-logs/watch-expressions-in-browser.png",
      fullPage: false,
    });
  });
});
