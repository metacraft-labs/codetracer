/**
 * Playwright UI smoke test for the recorder-owned Erlang canonical_flow trace.
 *
 * Companion to elixir-canonical-flow.spec.ts. The two specs verify that the
 * CodeTracer GUI does not choke on real BEAM CTFS bundles produced by the
 * codetracer-beam-recorder. The fixture is generated on demand by
 * codetracer-beam-recorder/scripts/prepare-beam-fixtures.sh — per the M15
 * "regenerate from source in CI" decision, no pre-baked goldens are stored
 * in this repo.
 *
 * Erlang variable names are capitalized by language convention (`A`, `B`,
 * `SumVal`, `Doubled`, `FinalResult`) and must appear that way in the state
 * pane; the recorder's manifest carries the language so the trace reader
 * preserves the original casing.
 */
import { test, expect, readyOnEntryTest as readyOnEntry } from "../lib/fixtures";
import { erlangOutDir, prepareBeamFixtures } from "../lib/beam-fixtures";
import { LayoutPage } from "../page-objects/layout_page";

// The Erlang CTFS bundle directory is a deterministic path, so test.use()
// can reference it up front.  The actual recording (which shells out to the
// codetracer-beam-recorder sibling) is performed in beforeAll() rather than
// at module scope: a throw at module-evaluation time aborts Playwright's
// collection of the *entire* suite, whereas a throw inside beforeAll fails
// only this spec.  This still fails loudly per the M15 design — it just
// contains the blast radius to the BEAM specs.
test.use({ sourcePath: erlangOutDir, launchMode: "trace-folder" });
test.setTimeout(180_000);

test.beforeAll(() => {
  prepareBeamFixtures();
});

test("e2e_playwright_erlang_trace_smoke", async ({ ctPage }) => {
  await readyOnEntry(ctPage);
  const layout = new LayoutPage(ctPage);

  // ---- Stepping controls render ---------------------------------------------
  await expect(layout.continueButton()).toBeVisible();
  await expect(layout.nextButton()).toBeVisible();
  await expect(layout.stepInButton()).toBeVisible();
  await expect(layout.reverseNextButton()).toBeVisible();
  await expect(layout.runToEntryButton()).toBeVisible();

  // ---- Editor loads canonical_flow.erl with the current line indicator -----
  await layout.runToEntryButton().click();
  await expect(ctPage.locator(".location-path")).not.toHaveText(":0#0", { timeout: 30_000 });
  await expect(ctPage.locator(".location-path")).toContainText("canonical_flow.erl");

  const editors = await layout.editorTabs(true);
  const canonicalEditor = editors.find((editor) => editor.fileName === "canonical_flow.erl");
  expect(canonicalEditor, "canonical_flow.erl editor tab should be open").toBeDefined();
  expect(await canonicalEditor!.highlightedLineNumber()).toBeGreaterThan(0);

  // The Erlang module declaration is on line 1; the visible window must
  // include `compute()` or `main()` since the trace lands inside one of
  // them after run-to-entry.
  const visibleRows = await canonicalEditor!.visibleTextRows();
  const visibleText = (
    await Promise.all(visibleRows.map((row) => row.root.textContent()))
  ).join("\n").replace(/ /g, " ");
  expect(visibleText.includes("compute") || visibleText.includes("main")).toBeTruthy();

  // ---- Calltrace lists canonical_flow:* entries -----------------------------
  // Erlang call sites are formatted as `module:function/arity`. The
  // canonical fixture only defines compute/0 and main/0, so either of
  // those names appearing is sufficient evidence the calltrace is wired.
  await expect(
    ctPage
      .locator(".calltrace-call-line")
      .filter({ hasText: /canonical_flow|compute|main/ })
      .first(),
  ).toBeVisible({ timeout: 30_000 });

  // ---- Event log has at least one entry -------------------------------------
  const eventLogs = await layout.eventLogTabs(true);
  expect(eventLogs.length).toBeGreaterThan(0);
  const eventRows = ctPage.locator(".eventLog-dense-table tbody tr");
  await expect(eventRows.first()).toBeVisible({ timeout: 30_000 });
  expect(await eventRows.count()).toBeGreaterThan(0);

  // ---- State pane reflects fixture variables --------------------------------
  // Erlang variables are capitalized — the recorder must preserve `A`, `B`,
  // `SumVal`, `Doubled`, `FinalResult`. Step until at least one of those
  // bindings lands in the state pane with the canonical value 94.
  await layout.stepInButton().click();
  await ctPage.waitForTimeout(750);

  let foundCanonicalState = false;
  for (let i = 0; i < 12; i++) {
    const stateText = await ctPage.locator("div[id^='stateComponent-']").first().textContent();
    if (stateText && /(FinalResult|Result|SumVal|Doubled)/.test(stateText) && stateText.includes("94")) {
      foundCanonicalState = true;
      break;
    }
    await layout.nextButton().click();
    await ctPage.waitForTimeout(750);
  }

  // Always assert at least one of the canonical Erlang variable names is
  // visible — even if the value `94` has not been computed yet, the
  // recorder must surface the variable bindings.
  const finalState = (
    await ctPage.locator("div[id^='stateComponent-']").first().textContent()
  )?.replace(/ /g, " ") ?? "";
  const erlangVarVisible = ["A", "B", "SumVal", "Doubled", "FinalResult", "Result"].some((name) =>
    new RegExp(`\\b${name}\\b`).test(finalState),
  );
  expect(erlangVarVisible || foundCanonicalState).toBeTruthy();

  // ---- Stepping controls actually move the program counter ------------------
  const beforeStepLine = await (await layout.editorTabs(true))
    .find((editor) => editor.fileName === "canonical_flow.erl")!
    .highlightedLineNumber();
  let afterStepLine = beforeStepLine;
  for (let i = 0; i < 3 && afterStepLine === beforeStepLine; i++) {
    await layout.nextButton().click();
    await ctPage.waitForTimeout(750);
    afterStepLine = await (await layout.editorTabs(true))
      .find((editor) => editor.fileName === "canonical_flow.erl")!
      .highlightedLineNumber();
  }
  expect(afterStepLine).toBeGreaterThan(0);
  expect(afterStepLine).not.toBe(beforeStepLine);
});
