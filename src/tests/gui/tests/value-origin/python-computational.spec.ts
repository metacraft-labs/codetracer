/**
 * M5 — Playwright spec for the Python `computational_origin` fixture.
 *
 * Covers M5 verification entries:
 *
 *   - e2e_origin_python_computational_expand_operands
 *   - e2e_origin_python_pin_to_scratchpad
 *
 * Fixture: `src/db-backend/tests/fixtures/origin/python/computational_origin/main.py`.
 * ANSWERS.md asserts the chain for `result` is a single Computational
 * hop with operand snapshots `a = 10` and `b = 32` terminating at
 * `Computational(expr="a + b")`.
 */
import { expect, readyOnEntryTest as readyOnEntry, test } from "../../lib/fixtures";
import { LayoutPage } from "../../page-objects/layout-page";
import { OriginChainPanePageObject } from "../../page-objects/originChainPane";
import {
  originFixturePath,
  pythonSpecSkipReason,
} from "../../lib/value-origin-fixtures";

const fixtureSource = originFixturePath("python", "computational_origin");

test.use({ sourcePath: fixtureSource, launchMode: "trace" });
test.setTimeout(180_000);

test.beforeAll(() => {
  const reason = pythonSpecSkipReason();
  test.skip(reason !== null, reason ?? "");
});

test("e2e_origin_python_computational_expand_operands", async ({ ctPage }) => {
  await readyOnEntry(ctPage);
  const layout = new LayoutPage(ctPage);
  const origin = new OriginChainPanePageObject(ctPage);

  // ---- Drive to `print(result)` -----------------------------------------
  await layout.runToEntryButton().click();
  await ctPage.waitForTimeout(750);
  const statePane = (await layout.programStateTabs(true))[0];
  for (let i = 0; i < 12; i++) {
    if ((await statePane.variableValueText("result")) !== "") {
      break;
    }
    await layout.nextButton().click();
    await ctPage.waitForTimeout(500);
  }

  // ---- Show origin via the right-click menu -----------------------------
  await origin.rightClickRow("result");
  await origin.clickShowValueOriginMenuItem();
  await expect(origin.sidePanel()).toBeVisible({ timeout: 15_000 });

  // Single hop + terminator per ANSWERS.md.
  await expect(origin.sidePanelHops()).toHaveCount(1, { timeout: 15_000 });

  // ---- Expand operands on the Computational hop -------------------------
  await origin.expandComputationalOperands(0);
  const operandText = (await origin.operandRows(0).allTextContents()).join(" ");
  expect(operandText, "operand snapshots must include a=10 and b=32").toContain("a");
  expect(operandText).toContain("b");
  // The pre-rendered value strings carry the integer literal.
  expect(operandText).toContain("10");
  expect(operandText).toContain("32");
});

test("e2e_origin_python_pin_to_scratchpad", async ({ ctPage }) => {
  await readyOnEntry(ctPage);
  const layout = new LayoutPage(ctPage);
  const origin = new OriginChainPanePageObject(ctPage);

  await layout.runToEntryButton().click();
  await ctPage.waitForTimeout(750);
  const statePane = (await layout.programStateTabs(true))[0];
  for (let i = 0; i < 12; i++) {
    if ((await statePane.variableValueText("result")) !== "") {
      break;
    }
    await layout.nextButton().click();
    await ctPage.waitForTimeout(500);
  }

  await origin.rightClickRow("result");
  await origin.clickShowValueOriginMenuItem();
  await expect(origin.sidePanel()).toBeVisible({ timeout: 15_000 });

  await origin.pinChain();

  // ---- Assert the chain landed in the Scratchpad pane -------------------
  // Production wiring: `ui/state.nim::wireOriginChainBridges` →
  // `OriginChainVM.onPinChainProc` invokes `ScratchpadVM.addChain`,
  // which renders a `.scratchpad-chain-entry` block in the panel.
  const scratchpadChain = ctPage.locator(".scratchpad-chain-entry");
  await expect(scratchpadChain.first()).toBeVisible({ timeout: 15_000 });
  await expect(scratchpadChain).toHaveCount(1);
});
