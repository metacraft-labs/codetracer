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

/**
 * Locate the codetracer-beam-recorder sibling repo. The precedence is:
 *   1. CODETRACER_BEAM_RECORDER_PATH env var (explicit override).
 *   2. Legacy CODETRACER_ELIXIR_RECORDER_PATH env var (deprecation alias).
 *   3. Sibling next to the codetracer repo (../codetracer-beam-recorder/).
 *   4. Workspace root layout used by the metacraft repo manifest.
 *
 * Failing to find the recorder is intentionally a hard error rather than a
 * skip — see plan:M15 deliverable "fixture-prep script must fail loudly".
 */
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

/**
 * Run prepare-beam-fixtures.sh once per test process and return the resolved
 * Elixir CTFS bundle directory. Both spec files (elixir/erlang) call this and
 * then pick the language they care about, so the recording cost is paid at
 * most once per Playwright worker.
 */
function prepareBeamFixtures(): { elixirDir: string; erlangDir: string } {
  const recorderRepo = resolveRecorderRepo();
  const script = path.join(recorderRepo, "scripts", "prepare-beam-fixtures.sh");
  // The fixture generator is a bash script. On Windows a `.sh` path is not
  // directly executable, so invoke it through `bash` (present on PATH via
  // the dev shell on every platform the suite runs on).
  const result = childProcess.spawnSync("bash", [script, elixirOutDir, erlangOutDir], {
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
  return { elixirDir: elixirOutDir, erlangDir: erlangOutDir };
}

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
  // and ends with final_result == 94. Step until those bindings appear.
  await layout.stepInButton().click();
  await ctPage.waitForTimeout(750);

  for (let i = 0; i < 12; i++) {
    const stateText = await ctPage.locator("div[id^='stateComponent-']").first().textContent();
    if (stateText?.includes("final_result") && stateText.includes("94")) {
      break;
    }
    await layout.nextButton().click();
    await ctPage.waitForTimeout(750);
  }

  const stateText = (
    await ctPage.locator("div[id^='stateComponent-']").first().textContent()
  )?.replace(/ /g, " ");
  for (const expected of ["a", "b", "sum_val", "doubled", "final_result", "94"]) {
    expect(stateText).toContain(expected);
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
