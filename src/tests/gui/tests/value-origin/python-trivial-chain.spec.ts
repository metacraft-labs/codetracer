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
import * as fs from "node:fs";
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

/** The source lines of the fixture, 1-based: the hop lines are found by
 *  their text, not hard-coded, so an edit to the comment header cannot
 *  silently move them. */
const fixtureLines = fs.readFileSync(fixtureSource, "utf-8").split("\n");
function lineOf(text: string): number {
  const index = fixtureLines.findIndex((l) => l.trim() === text);
  if (index < 0) throw new Error(`fixture has no line \`${text}\``);
  return index + 1;
}

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

async function fixtureEditor(layout: LayoutPage) {
  const editorTabs = await layout.editorTabs(true);
  const editor = editorTabs.find((e) => e.fileName === "main.py");
  expect(editor, "the fixture editor tab must be open").toBeDefined();
  return editor!;
}

test("e2e_origin_python_trivial_chain_renders_three_hops", async ({ ctPage }) => {
  await readyOnEntry(ctPage);
  const layout = new LayoutPage(ctPage);
  const origin = new OriginChainPanePageObject(ctPage);
  await stepToPrintC(ctPage, layout);

  // ---- Right-click `c` → "Show value origin": the chain under the row ----
  await origin.showValueOriginInPlace("c");

  // Three hops + the terminator, per fixture ANSWERS.md.
  await expect(origin.expandedChainHops("c")).toHaveText(EXPECTED_HOPS, { timeout: 15_000 });
  await expect(origin.inlineChainTerminator("c")).toBeVisible();
  await expect(origin.inlineChainTerminator("c")).toHaveText("10");

  // The same entry again collapses it.
  await origin.rightClickRow("c");
  await origin.clickShowValueOriginMenuItem();
  await expect(origin.inlineChain("c")).toBeHidden({ timeout: 15_000 });
});

test("e2e_origin_python_click_hop_seeks_editor", async ({ ctPage }) => {
  await readyOnEntry(ctPage);
  const layout = new LayoutPage(ctPage);
  const origin = new OriginChainPanePageObject(ctPage);
  await stepToPrintC(ctPage, layout);

  await origin.showValueOriginInPlace("c");
  await expect(origin.expandedChainHops("c")).toHaveText(EXPECTED_HOPS, { timeout: 15_000 });

  // Click hop 1 (`b = a`): the editor's execution line moves to that
  // assignment.
  const editor = await fixtureEditor(layout);
  const beforeLine = await editor.highlightedLineNumber();
  expect(beforeLine, "at the print(c) line").toBe(lineOf("print(c)"));
  await origin.clickHop("c", 1);
  await expect.poll(() => editor.highlightedLineNumber(), {
    message: "clicking hop `b = a` seeks the editor to its line",
    timeout: 15_000,
  }).toBe(lineOf("b = a"));
});

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

test("e2e_origin_keyboard_navigation", async ({ ctPage }) => {
  // Verifies the host-installed keyboard handlers of the side panel (see
  // `ui/state.nim::ensureOriginSidePanelHost::onKey`):
  //   ↓ / ↑  → focusNextHop / focusPrevHop  (changes `panel.focusedHop`)
  //   Enter  → enterHop → OriginChainVM.onSeekToHop
  //   →      → expandFocusedOperands
  //   ←      → collapseFocusedOperands
  //   Esc    → dismissPanel + closeSidePanel  (host hides)
  // The panel is opened the way the State Pane opens it: the row's
  // in-place chain, then its "Show in side panel".
  await readyOnEntry(ctPage);
  const layout = new LayoutPage(ctPage);
  const origin = new OriginChainPanePageObject(ctPage);
  await stepToPrintC(ctPage, layout);

  await origin.showValueOriginInPlace("c");
  await origin.openInSidePanel("c");
  await expect(origin.sidePanelHops()).toHaveCount(3, { timeout: 15_000 });
  await expect(origin.sidePanelTerminator()).toContainText("10");

  const editor = await fixtureEditor(layout);
  expect(await editor.highlightedLineNumber(), "at the print(c) line").toBe(lineOf("print(c)"));

  // Walk the chain: ↓ ↓ focuses hop 1, → / ← expand and collapse its
  // operands (none on a trivial copy), ↑ focuses hop 0, Enter seeks it —
  // hop 0 is `c = b`, so the editor moves to that line.
  await origin.keyboardNavigate("ArrowDown");
  await origin.keyboardNavigate("ArrowDown");
  await origin.keyboardNavigate("ArrowRight");
  await origin.keyboardNavigate("ArrowLeft");
  await origin.keyboardNavigate("ArrowUp");
  await origin.keyboardNavigate("Enter");
  await expect.poll(() => editor.highlightedLineNumber(), {
    message: "Enter on the focused hop (`c = b`) seeks the editor to it",
    timeout: 15_000,
  }).toBe(lineOf("c = b"));

  // Esc dismisses the panel.
  await origin.keyboardNavigate("Escape");
  await expect(origin.sidePanel()).toBeHidden({ timeout: 5_000 });
});
