/**
 * Playwright UI smoke test for the recorder-owned Elixir canonical_flow trace.
 *
 * This is one of the M15 deliverables in the BEAM Materialized Trace Recorder
 * milestones plan. Companion to erlang-canonical-flow.spec.ts. The two specs
 * verify that the CodeTracer GUI does not choke on real Elixir/Erlang CTFS
 * bundles produced by the codetracer-beam-recorder; deeper data-semantics
 * coverage lives in the M14 DAP integration tests
 * (src/db-backend/tests/elixir_flow_dap_test.rs).
 *
 * The fixture is generated on demand by
 * codetracer-beam-recorder/scripts/prepare-beam-fixtures.sh — per the M15
 * "regenerate from source in CI" decision, no pre-baked goldens are stored
 * in this repo.
 */
import { test, expect, readyOnEntryTest as readyOnEntry } from "../lib/fixtures";
import { elixirOutDir, prepareBeamFixtures } from "../lib/beam-fixtures";
import { LayoutPage } from "../page-objects/layout_page";

// The Elixir CTFS bundle directory is a deterministic path, so test.use()
// can reference it up front.  The actual recording (which shells out to the
// codetracer-beam-recorder sibling) is performed in beforeAll() rather than
// at module scope: a throw at module-evaluation time aborts Playwright's
// collection of the *entire* suite, whereas a throw inside beforeAll fails
// only this spec.  This still fails loudly per the M15 design — it just
// contains the blast radius to the BEAM specs.
test.use({ sourcePath: elixirOutDir, launchMode: "trace-folder" });
test.setTimeout(180_000);

test.beforeAll(() => {
  prepareBeamFixtures();
});

test("e2e_playwright_elixir_trace_smoke", async ({ ctPage }) => {
  await readyOnEntry(ctPage);
  const layout = new LayoutPage(ctPage);

  // ---- Stepping controls render ---------------------------------------------
  // Smoke check that the debugger toolbar exists. If any of these are missing
  // the UI is fundamentally broken for BEAM traces — fail fast.
  await expect(layout.continueButton()).toBeVisible();
  await expect(layout.nextButton()).toBeVisible();
  await expect(layout.stepInButton()).toBeVisible();
  await expect(layout.reverseNextButton()).toBeVisible();
  await expect(layout.runToEntryButton()).toBeVisible();

  // ---- Editor loads canonical_flow.ex with the current line indicator ------
  await layout.runToEntryButton().click();
  await expect(ctPage.locator(".location-path")).not.toHaveText(":0#0", { timeout: 30_000 });
  await expect(ctPage.locator(".location-path")).toContainText("canonical_flow.ex");

  const editors = await layout.editorTabs(true);
  const canonicalEditor = editors.find((editor) => editor.fileName === "canonical_flow.ex");
  expect(canonicalEditor, "canonical_flow.ex editor tab should be open").toBeDefined();
  expect(await canonicalEditor!.highlightedLineNumber()).toBeGreaterThan(0);

  const visibleRows = await canonicalEditor!.visibleTextRows();
  const visibleText = (
    await Promise.all(visibleRows.map((row) => row.root.textContent()))
  ).join("\n").replace(/ /g, " ");
  expect(visibleText).toContain("def ");

  // ---- Calltrace lists CanonicalFlow.* entries ------------------------------
  await expect(ctPage.locator(".calltrace-call-line").filter({ hasText: "CanonicalFlow" }).first())
    .toBeVisible({ timeout: 30_000 });

  // ---- Event log has at least one entry -------------------------------------
  const eventLogs = await layout.eventLogTabs(true);
  expect(eventLogs.length).toBeGreaterThan(0);
  const eventRows = ctPage.locator(".eventLog-dense-table tbody tr");
  await expect(eventRows.first()).toBeVisible({ timeout: 30_000 });
  expect(await eventRows.count()).toBeGreaterThan(0);

  // ---- State pane reflects fixture variables --------------------------------
  // The canonical_flow program walks `a, b, sum_val, doubled, final_result`
  // and ends with final_result == 94. The materialized trace records each
  // binding at the step that introduced it, so the state pane shows the
  // step-local variable rather than the whole function's cumulative
  // scope. Step through `compute/0` and accumulate every state-pane
  // snapshot — each of the five bindings (and the final value 94) must
  // surface at some step of the walk.
  await layout.stepInButton().click();
  await ctPage.waitForTimeout(750);

  let accumulatedState = await ctPage
    .locator("div[id^='stateComponent-']")
    .first()
    .textContent() ?? "";
  for (let i = 0; i < 12; i++) {
    if (accumulatedState.includes("final_result") && accumulatedState.includes("94")) {
      break;
    }
    await layout.nextButton().click();
    await ctPage.waitForTimeout(750);
    accumulatedState += "\n" + (await ctPage
      .locator("div[id^='stateComponent-']")
      .first()
      .textContent() ?? "");
  }

  const normalizedState = accumulatedState.replace(/ /g, " ");
  for (const expected of ["a", "b", "sum_val", "doubled", "final_result", "94"]) {
    expect(normalizedState).toContain(expected);
  }

  // ---- Stepping controls actually move the program counter ------------------
  // The plan calls out this assertion explicitly: step over once and observe
  // the highlighted line in the editor change.
  const beforeStepLine = await (await layout.editorTabs(true))
    .find((editor) => editor.fileName === "canonical_flow.ex")!
    .highlightedLineNumber();
  let afterStepLine = beforeStepLine;
  for (let i = 0; i < 3 && afterStepLine === beforeStepLine; i++) {
    await layout.nextButton().click();
    await ctPage.waitForTimeout(750);
    afterStepLine = await (await layout.editorTabs(true))
      .find((editor) => editor.fileName === "canonical_flow.ex")!
      .highlightedLineNumber();
  }
  expect(afterStepLine).toBeGreaterThan(0);
  expect(afterStepLine).not.toBe(beforeStepLine);
});
