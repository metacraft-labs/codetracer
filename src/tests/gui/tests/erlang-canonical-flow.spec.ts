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
import * as childProcess from "node:child_process";
import * as fs from "node:fs";
import * as path from "node:path";

import { test, expect, readyOnEntryTest as readyOnEntry } from "../lib/fixtures";
import { LayoutPage } from "../page-objects/layout_page";

// This spec lives at src/tests/gui/tests/ — four levels below the codetracer
// repo root.  (The suite moved from the old one-level-deep tsc-ui-tests/ and
// this constant was not updated, so the codetracer-beam-recorder sibling
// lookup and the target/ fixture dir resolved under src/tests/ instead.)
const repoRoot = path.resolve(__dirname, "../../../..");
const elixirOutDir = path.join(repoRoot, "target", "beam-ui-fixtures", "elixir-canonical-flow");
const erlangOutDir = path.join(repoRoot, "target", "beam-ui-fixtures", "erlang-canonical-flow");

function resolveRecorderRepo(): string {
  const explicit = process.env.CODETRACER_BEAM_RECORDER_PATH ?? process.env.CODETRACER_ELIXIR_RECORDER_PATH;
  if (explicit) {
    if (!fs.existsSync(path.join(explicit, "scripts", "prepare-beam-fixtures.sh"))) {
      throw new Error(
        `CODETRACER_BEAM_RECORDER_PATH does not point to a recorder repo with prepare-beam-fixtures.sh: ${explicit}`,
      );
    }
    return explicit;
  }

  const candidates = [
    path.resolve(repoRoot, "..", "codetracer-beam-recorder"),
    path.resolve(repoRoot, "..", "..", "..", "metacraft", "codetracer-beam-recorder"),
  ];
  for (const candidate of candidates) {
    if (fs.existsSync(path.join(candidate, "scripts", "prepare-beam-fixtures.sh"))) {
      return candidate;
    }
  }

  throw new Error(
    "codetracer-beam-recorder repo not found; set CODETRACER_BEAM_RECORDER_PATH",
  );
}

function prepareBeamFixtures(): { erlangDir: string } {
  const recorderRepo = resolveRecorderRepo();
  const script = path.join(recorderRepo, "scripts", "prepare-beam-fixtures.sh");
  const result = childProcess.spawnSync(script, [elixirOutDir, erlangOutDir], {
    cwd: recorderRepo,
    encoding: "utf-8",
    stdio: "pipe",
    env: {
      ...process.env,
      FORCE: process.env.CI ? "1" : process.env.FORCE ?? "0",
      TMPDIR: process.env.TMPDIR ?? path.join(repoRoot, "target", ".tmp"),
    },
    timeout: 240_000,
  });

  if (result.error || result.status !== 0) {
    throw new Error(
      `BEAM fixture preparation failed: error=${result.error}; status=${result.status}\n` +
        `stdout:\n${result.stdout}\nstderr:\n${result.stderr}`,
    );
  }
  return { erlangDir: erlangOutDir };
}

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
