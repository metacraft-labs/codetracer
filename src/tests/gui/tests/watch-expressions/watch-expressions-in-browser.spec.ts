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
 * THE VALUE IS COMPARED AS A NUMBER, read from the row's VALUE CELL. These
 * inputs are Noir `Field`s, which the tracer records as `0x` + 64 hex digits
 * (`noir/tooling/tracer`'s `field_to_hex`) and the one presenter renders
 * with the padding stripped — `0x2710` — adding the decimal only on a
 * surface that has room for both, `0x2710 (10000)` (PLAT-2,
 * `src/common/value_presentation_test.nim`). Which base the pane writes is
 * the presenter's decision; which number it is is this spec's. So the cell
 * must be exactly one rendering of the number — decimal, hex, or the
 * annotated pair with both halves equal — and that number must be the
 * input. A substring test on the whole row (`toContain("10000")`) could
 * not tell a cell reading `0x2710` from a missing one, and passed for any
 * row that happened to contain the digits.
 *
 * ROWS ARE READ BY `data-variable-name`, which names a ROW and nothing
 * inside it (Live-HCR-GUI-E2E-Test-Design.md, "Semantic Test Selectors").
 * Until codetracer-pm issue 2026-10-22 the row's origin badge repeated the
 * attribute, so this reader ended on the badge's empty text and reported a
 * drawn, answered watch as "never produced a row". The reader therefore
 * also asserts the name is unique: a second element by a row's name is a
 * failure of its own, not something to step around.
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
const INITIAL_SHIELD = 10000n;
const ASTEROID_MASS_AT_1 = 2000n;

function statePane(page: Page): VariableStatePane {
  return new VariableStatePane(page, page.locator("#stateComponent-0"), "STATE");
}

/** One row of the pane, as painted. */
interface PaintedRow {
  /** The row's whole text, whitespace collapsed. */
  text: string;
  /** The row's value cell (`.value-expanded-text`) alone. */
  value: string;
  /** How many elements in the pane carry this row's name. Must be 1. */
  elementsNamed: number;
}

/**
 * Everything the Watches tab is showing, as `name` -> painted row.
 *
 * Read from the rows the product painted rather than from a ViewModel,
 * and returned WHOLE so a failure can print what the pane actually held.
 * "The expected row is missing" and "the pane has no rows at all" need
 * different fixes and a bare `toBe` cannot tell them apart.
 *
 * ONLY WHILE THE WATCHES TAB IS THE ONE SHOWN. `initial_shield` is also a
 * LOCAL of `main`, so the Locals tab holds a row by that name with the same
 * value: a reader that did not check the tab passed on the Locals row while
 * the pane had fallen back to Locals and the watch was nowhere on screen
 * (measured under `ct host`, codetracer-pm issue 2026-10-22). When the
 * Watches tab is not the active one this returns no rows.
 */
async function watchRows(page: Page): Promise<Record<string, PaintedRow>> {
  return page.evaluate(() => {
    const out: Record<string, { text: string; value: string; elementsNamed: number }> = {};
    const pane = document.getElementById("stateComponent-0");
    if (!pane) return out;
    if (!pane.querySelector(".state-tabs .tab-watches.active")) return out;
    for (const row of pane.querySelectorAll("[data-variable-name]")) {
      const name = row.getAttribute("data-variable-name") || "";
      const collapse = (s: string) => s.replace(/\s+/g, " ").trim();
      const text = (row as HTMLElement).innerText || row.textContent || "";
      const cell = row.querySelector(".value-expanded-text");
      const seen = out[name];
      out[name] = {
        // The FIRST element by the name is the row (document order puts a
        // row before anything inside it); a later one only counts.
        text: seen ? seen.text : collapse(text),
        value: seen ? seen.value : collapse(cell ? cell.textContent || "" : ""),
        elementsNamed: (seen ? seen.elementsNamed : 0) + 1,
      };
    }
    return out;
  });
}

/**
 * The number a value cell shows, or `null` when the cell is not exactly
 * one rendering of one number.
 *
 * Accepted: a decimal integer (`10000`), a hex literal (`0x2710`), and the
 * annotated pair the presenter writes on a surface with room for both
 * (`0x2710 (10000)`, `306 (0x132)`) — only when its two halves are the SAME
 * number. Anything else (an array, a struct, a refusal, text around the
 * number) is `null`, so it cannot equal an expected value.
 */
function shownNumber(cell: string): bigint | null {
  const one = (s: string): bigint | null =>
    /^-?(0x[0-9a-fA-F]+|[0-9]+)$/.test(s)
      ? s.startsWith("-")
        ? -BigInt(s.slice(1))
        : BigInt(s)
      : null;
  const pair = cell.match(/^(\S+) \((\S+)\)$/);
  if (pair) {
    const a = one(pair[1]);
    const b = one(pair[2]);
    return a !== null && a === b ? a : null;
  }
  return one(cell);
}

/** `shownNumber` of the named row's value cell, as text for `expect.poll`. */
async function watchNumber(page: Page, name: string): Promise<string> {
  const watchesShown = await page
    .locator("#stateComponent-0 .state-tabs .tab-watches.active")
    .count();
  if (watchesShown === 0) return "<the Watches tab is not the one shown>";
  const row = (await watchRows(page))[name];
  if (!row) return "<no row>";
  if (row.elementsNamed !== 1) return `<${row.elementsNamed} elements named ${name}>`;
  const n = shownNumber(row.value);
  return n === null ? `<not one number: ${JSON.stringify(row.value)}>` : n.toString();
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
    // No wait for the editor: the user may type as soon as the pane is
    // there, while the first stop's editor tab is still opening. That tab
    // puts the caret on the stop's line from a timer, and it used to take
    // the keyboard with it, so `asteroid_masses_positive[1]` was submitted
    // as `ast` (`ui/editor_focus`, codetracer-pm issue 2026-10-22).

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
      .poll(async () => watchNumber(ctPage, "initial_shield"), {
        timeout: 45_000,
        message: "the watch `initial_shield` never produced a row showing its value in the Watches tab",
      })
      .toBe(INITIAL_SHIELD.toString());

    // ---- AN INDEXED ELEMENT, which is the discriminating case --------
    //
    // `asteroid_masses_positive[1]` is 2000 while `[0]` is 100 and the
    // whole array contains both. An implementation that answered with
    // the array, with the wrong element, or by name-matching the
    // expression against the locals list (which is what the Python
    // bridge does) cannot produce 2000 here and only 2000.
    await pane.addWatchExpression("asteroid_masses_positive[1]");
    await expect
      .poll(async () => watchNumber(ctPage, "asteroid_masses_positive[1]"), {
        timeout: 45_000,
        message:
          "the indexed watch `asteroid_masses_positive[1]` never produced a row showing " +
          "one number; an index that resolves to nothing is the silent-drop defect returning",
      })
      .toBe(ASTEROID_MASS_AT_1.toString());

    // It must be THAT element, not the array printed whole. `shownNumber`
    // already refuses a cell holding more than one number; the row as a
    // whole must not carry a neighbouring element either (`[0]` is 100,
    // `0x64` as the presenter writes a field element).
    const rowsAfterIndex = await watchRows(ctPage);
    const indexedRow = rowsAfterIndex["asteroid_masses_positive[1]"]?.text ?? "";
    expect(
      indexedRow,
      `the indexed watch must be the ELEMENT, not the whole array; row was: ${indexedRow}`,
    ).not.toMatch(/\b(100|0x64)\b/);

    // ---- THE REFUSAL PATH, with its own assertion --------------------
    //
    // A recording holds the values that were recorded; the sum was not
    // one of them. The requirement is not that this fails — it is that
    // the user is TOLD, in the pane, with a reason. A missing row here
    // is the original defect exactly.
    await pane.addWatchExpression("initial_shield + 1");
    await expect
      .poll(async () => (await watchRows(ctPage))["initial_shield + 1"]?.text ?? "", {
        timeout: 45_000,
        message:
          "an unanswerable watch produced NO ROW — the pane's two states are " +
          "'a value' and 'nothing', which is the defect this spec exists for",
      })
      .toContain("cannot evaluate");

    const rowsAfterRefusal = await watchRows(ctPage);
    expect(
      rowsAfterRefusal["initial_shield + 1"]?.text ?? "",
      "the refusal must say WHY a recording cannot answer it, not merely that it failed",
    ).toContain("only holds the values that were actually recorded");

    // A refusal must not have cost the working watches their rows.
    expect(
      await watchNumber(ctPage, "initial_shield"),
      "a refused watch must not disturb the watches that resolve",
    ).toBe(INITIAL_SHIELD.toString());

    await ctPage.screenshot({
      path: "test-logs/watch-expressions-in-browser.png",
      fullPage: false,
    });
  });
});
