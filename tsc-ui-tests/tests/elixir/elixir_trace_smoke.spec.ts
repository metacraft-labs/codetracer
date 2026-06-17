import * as childProcess from "node:child_process";
import * as fs from "node:fs";
import * as path from "node:path";

import { test, expect, readyOnEntryTest as readyOnEntry } from "../../lib/fixtures";
import { LayoutPage } from "../../page-objects/layout_page";

const repoRoot = path.resolve(__dirname, "../../..");
const traceDir = path.join(repoRoot, "target", "elixir-ui-fixtures", "playwright-canonical-flow");

function resolveRecorderRepo(): string {
  const explicit = process.env.CODETRACER_ELIXIR_RECORDER_PATH;
  if (explicit) {
    if (!fs.existsSync(path.join(explicit, "scripts", "prepare-elixir-fixture.sh"))) {
      throw new Error(`CODETRACER_ELIXIR_RECORDER_PATH does not point to the recorder repo: ${explicit}`);
    }
    return explicit;
  }

  const candidates = [
    path.resolve(repoRoot, "..", "codetracer-elixir-recorder"),
    path.resolve(repoRoot, "..", "..", "..", "metacraft", "codetracer-elixir-recorder"),
  ];
  for (const candidate of candidates) {
    if (fs.existsSync(path.join(candidate, "scripts", "prepare-elixir-fixture.sh"))) {
      return candidate;
    }
  }

  throw new Error(
    "codetracer-elixir-recorder repo not found; set CODETRACER_ELIXIR_RECORDER_PATH",
  );
}

function prepareElixirTraceFixture(): string {
  const recorderRepo = resolveRecorderRepo();
  const script = path.join(recorderRepo, "scripts", "prepare-elixir-fixture.sh");
  const result = childProcess.spawnSync(script, [traceDir], {
    cwd: recorderRepo,
    encoding: "utf-8",
    stdio: "pipe",
    env: {
      ...process.env,
      FORCE: process.env.CI ? "1" : process.env.FORCE ?? "0",
      TMPDIR: process.env.TMPDIR ?? path.join(repoRoot, "target", ".tmp"),
    },
    timeout: 120_000,
  });

  if (result.error || result.status !== 0) {
    throw new Error(
      `Elixir fixture preparation failed: error=${result.error}; status=${result.status}\n` +
        `stdout:\n${result.stdout}\nstderr:\n${result.stderr}`,
    );
  }
  return traceDir;
}

const preparedTraceDir = prepareElixirTraceFixture();

test.use({ sourcePath: preparedTraceDir, launchMode: "trace-folder" });
test.setTimeout(120_000);

test("e2e_playwright_elixir_trace_smoke", async ({ ctPage }) => {
  await readyOnEntry(ctPage);
  const layout = new LayoutPage(ctPage);

  await expect(layout.continueButton()).toBeVisible();
  await expect(layout.nextButton()).toBeVisible();
  await expect(layout.stepInButton()).toBeVisible();
  await expect(layout.reverseNextButton()).toBeVisible();
  await expect(layout.runToEntryButton()).toBeVisible();

  await layout.runToEntryButton().click();
  await expect(ctPage.locator(".location-path")).not.toHaveText(":0#0", { timeout: 20_000 });
  await expect(ctPage.locator(".location-path")).toContainText("canonical_flow.ex");

  const editors = await layout.editorTabs(true);
  const canonicalEditor = editors.find((editor) => editor.fileName === "canonical_flow.ex");
  expect(canonicalEditor, "canonical_flow.ex editor tab should be open").toBeDefined();
  expect(await canonicalEditor!.highlightedLineNumber()).toBeGreaterThan(0);

  const visibleRows = await canonicalEditor!.visibleTextRows();
  const visibleText = (
    await Promise.all(visibleRows.map((row) => row.root.textContent()))
  ).join("\n").replace(/\u00a0/g, " ");
  expect(visibleText).toContain("def ");

  await expect(ctPage.locator(".calltrace-call-line").filter({ hasText: "CanonicalFlow" }).first())
    .toBeVisible({ timeout: 20_000 });

  const eventLogs = await layout.eventLogTabs(true);
  expect(eventLogs.length).toBeGreaterThan(0);
  const eventRows = ctPage.locator(".eventLog-dense-table tbody tr");
  await expect(eventRows.first()).toBeVisible({ timeout: 20_000 });
  expect(await eventRows.count()).toBeGreaterThan(0);

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
  )?.replace(/\u00a0/g, " ");
  for (const expected of ["a", "b", "sum_val", "doubled", "final_result", "94"]) {
    expect(stateText).toContain(expected);
  }

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
