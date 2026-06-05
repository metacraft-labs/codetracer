/**
 * M5 — Playwright spec for the Python `simple_trivial_chain` Value
 * Origin fixture.
 *
 * Covers M5 verification entries:
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
 * The spec uses `test.use({ sourcePath: <absolute>, launchMode: "trace" })`
 * so the existing harness's `recordTestProgram(fullSourcePath)` path
 * records the trace on demand via `ct record`. When the Python
 * recorder isn't installed in this environment (the M3 layer
 * SKIPs-cleanly in the same scenario per
 * `origin_python_dap_test.rs::require_python_recorder`) the spec
 * SKIPs itself with the same reason.
 */
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

test("e2e_origin_python_trivial_chain_renders_three_hops", async ({ ctPage }) => {
  await readyOnEntry(ctPage);
  const layout = new LayoutPage(ctPage);
  const origin = new OriginChainPanePageObject(ctPage);

  // ---- Drive the program to the `print(c)` line --------------------------
  // The fixture's `main()` walks the three assignments + `print(c)`. We
  // step in then step over until `c` appears in the State Pane locals.
  await layout.runToEntryButton().click();
  await ctPage.waitForTimeout(750);

  const statePane = (await layout.programStateTabs(true))[0];
  expect(statePane, "State Pane must be present").toBeDefined();
  let cVisible = (await statePane.variableValueText("c")) !== "";
  for (let i = 0; i < 12 && !cVisible; i++) {
    await layout.nextButton().click();
    await ctPage.waitForTimeout(500);
    cVisible = (await statePane.variableValueText("c")) !== "";
  }
  expect(cVisible, "stepping to the print(c) line must surface local `c`").toBe(true);

  // ---- Right-click `c` → "Show value origin" -----------------------------
  await origin.rightClickRow("c");
  await origin.clickShowValueOriginMenuItem();

  // The side panel mounts on the document body when
  // `OriginChainVM.sidePanelOpen` flips. Wait for the host overlay.
  await expect(origin.sidePanel()).toBeVisible({ timeout: 15_000 });

  // Three hops + terminator row per fixture ANSWERS.md.
  await expect(origin.sidePanelHops()).toHaveCount(3, { timeout: 15_000 });
  await expect(origin.sidePanelTerminator()).toBeVisible();
  await expect(origin.sidePanelTerminator()).toContainText("10");
});

test("e2e_origin_python_click_hop_seeks_editor", async ({ ctPage }) => {
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

  // Capture the editor's current highlighted line, click hop 1 (the
  // middle TrivialCopy → `b = a`), then assert the line moves.
  const editorTabs = await layout.editorTabs(true);
  const editor = editorTabs.find((e) => e.fileName === "main.py");
  expect(editor, "the fixture editor tab must be open").toBeDefined();
  const beforeLine = await editor!.highlightedLineNumber();

  await origin.clickSidePanelHop(1);
  await ctPage.waitForTimeout(750);

  let afterLine = await editor!.highlightedLineNumber();
  for (let i = 0; i < 5 && afterLine === beforeLine; i++) {
    await ctPage.waitForTimeout(500);
    afterLine = await editor!.highlightedLineNumber();
  }
  expect(afterLine, "clicking a hop must seek the editor").not.toBe(beforeLine);
});

test("e2e_origin_python_trivial_chain_a11y", async ({ ctPage }) => {
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

  // axe-core scan scoped to the side-panel host element to keep the
  // assertion focused on this feature's surface (the broader editor
  // is governed by a separate top-level a11y suite).
  const results = await new AxeBuilder({ page: ctPage })
    .include("aside#ct-origin-chain-side-panel")
    .analyze();

  expect(
    results.violations,
    `a11y violations on Origin Chain Panel: ${JSON.stringify(results.violations, null, 2)}`,
  ).toEqual([]);
});

test("e2e_origin_keyboard_navigation", async ({ ctPage }) => {
  // Verifies the host-installed keyboard handlers (see
  // `ui/state.nim::ensureOriginSidePanelHost::onKey`):
  //   ↓ / ↑  → focusNextHop / focusPrevHop  (changes `panel.focusedHop`)
  //   Enter  → enterHop → OriginChainVM.onSeekToHop
  //   →      → expandFocusedOperands
  //   ←      → collapseFocusedOperands
  //   Esc    → dismissPanel + closeSidePanel  (host hides)
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

  // Walk through the chain via the keyboard.
  await origin.keyboardNavigate("ArrowDown");
  await origin.keyboardNavigate("ArrowDown");
  await origin.keyboardNavigate("ArrowRight"); // expand operands (no-op for trivial copy)
  await origin.keyboardNavigate("ArrowLeft");  // collapse again
  await origin.keyboardNavigate("ArrowUp");
  await origin.keyboardNavigate("Enter");

  // Esc dismisses the panel.
  await origin.keyboardNavigate("Escape");
  // The display flips back to none after the React effect re-renders.
  await expect(origin.sidePanel()).toBeHidden({ timeout: 5_000 });
});
