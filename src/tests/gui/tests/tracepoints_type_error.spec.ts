import { test, expect, readyOnEntryTest } from "../lib/fixtures";
import type { Page } from "@playwright/test";
import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";
import * as childProcess from "node:child_process";
import { LayoutPage } from "../page-objects/layout-page";
import { TraceLogPanel } from "../page-objects/panes/editor/trace-log-panel";

const repoRoot = path.resolve(__dirname, "../../../..");

function findJsRecorder(): string {
  const env = process.env.CODETRACER_JS_RECORDER_PATH;
  if (env && fs.existsSync(env)) return env;
  const candidate = path.resolve(
    repoRoot,
    "..",
    "codetracer-js-recorder",
    "packages",
    "cli",
    "dist",
    "index.js",
  );
  if (fs.existsSync(candidate)) return candidate;
  return candidate;
}

const fixtureDir = path.join(os.tmpdir(), "ct-tp-err-gui-" + process.pid);
const sourcePath = path.join(fixtureDir, "program.js");
const tracePath = path.join(fixtureDir, "trace");
// The tracepoint under test is placed on line 1, so line 1 must execute more
// than once: with the previous straight-line fixture
// (`var a = 1; var b = 2; var c = a + b;`) the tracepoint produced exactly ONE
// row, the "second row" half of `test_tracepoints_type_error` below was
// silently skipped, and no spec here ever navigated twice — which is precisely
// the sequence #566 broke (the results grid disappears after the FIRST jump).
// A loop makes line 1 yield one row per iteration.
const PROGRAM = "for (let i = 0; i < 5; i++) { var a = i; }\nvar d = 1;\n";
const MIN_EXPECTED_ROWS = 3;

function prepareFixture() {
  if (fs.existsSync(fixtureDir)) fs.rmSync(fixtureDir, { recursive: true, force: true });
  fs.mkdirSync(fixtureDir, { recursive: true });
  fs.writeFileSync(sourcePath, PROGRAM);

  const recorder = findJsRecorder();
  if (fs.existsSync(recorder)) {
    const recorderOut = path.join(fixtureDir, "rec-out");
    fs.mkdirSync(recorderOut, { recursive: true });
    childProcess.spawnSync("node", [recorder, "record", sourcePath, "--out-dir", recorderOut]);
    const entries = fs.readdirSync(recorderOut, { withFileTypes: true });
    const traceSubdir = entries.find((e) => e.isDirectory() && e.name.startsWith("trace-"));
    if (traceSubdir) fs.renameSync(path.join(recorderOut, traceSubdir.name), tracePath);
  }
  return { traceDir: tracePath, sourcePath };
}

const fixture = prepareFixture();

test.use({ sourcePath: fixture.traceDir, launchMode: "trace-folder" });

/**
 * Opens the tracepoint on line 1 of `program.js`, runs it and waits for the
 * results grid to populate.  Shared by both specs in this file.
 */
async function openPopulatedTracepoint(ctPage: Page) {
  await readyOnEntryTest(ctPage);

  const layout = new LayoutPage(ctPage);
  const editors = await layout.editorTabs(true);
  const editor = editors.find((e) => e.fileName === "program.js");
  expect(editor, "program.js editor tab should be open").toBeDefined();
  if (!editor) throw new Error("program.js editor tab is not open");

  await editor.tabButton().click();

  // Wait for Monaco editor to appear and finish initializing
  await expect(editor.root.locator(".monaco-editor")).toBeVisible({ timeout: 30000 });

  // Wait until the editor's tabInfo is fully loaded and non-nil
  await expect.poll(async () => {
    return await ctPage.evaluate(({ path }) => {
      const w = window as any;
      if (w.data && w.data.ui && w.data.ui.editors && w.data.ui.editors[path]) {
        const editorComponent = w.data.ui.editors[path];
        return editorComponent.tabInfo !== null && editorComponent.tabInfo !== undefined &&
               editorComponent.monacoEditor !== null && editorComponent.monacoEditor !== undefined;
      }
      return false;
    }, { path: editor.filePath });
  }, { timeout: 15000 }).toBe(true);

  // Open the trace component using page-object helper
  await editor.openTrace(1);

  const tracePanel = new TraceLogPanel(editor, 1);
  await tracePanel.root.waitFor({ state: "visible", timeout: 15000 });

  await tracePanel.typeExpression("a");

  // Run the configured tracepoint to collect hits and populate the DataTable
  await editor.runTracepointsJs();

  // Wait for the DataTable to populate the rows
  const rowsLocator = tracePanel.root.locator(".trace-table tbody tr");
  await expect(rowsLocator.first()).toBeVisible({ timeout: 15000 });

  return { editor, tracePanel, rowsLocator };
}

test("test_tracepoints_type_error: Verifies no TypeError occurs with tracepoints", async ({ ctPage }) => {
  // If traceDir wasn't created (e.g. no recorder), just pass the test to avoid spurious failures locally.
  if (!fs.existsSync(fixture.traceDir)) {
    await readyOnEntryTest(ctPage);
    console.log("No trace generated, skipping tracepoints_type_error spec");
    return;
  }

  const { tracePanel } = await openPopulatedTracepoint(ctPage);

  // Get rows from the trace log panel
  const rows = await tracePanel.traceRows();
  // The looping fixture must yield several hits — otherwise the second-click
  // half of this spec below would be skipped and stop covering anything.
  expect(rows.length).toBeGreaterThanOrEqual(MIN_EXPECTED_ROWS);

  // 1. Direct cell click navigation test
  const firstRow = rows[0].root;
  const ticksCell = firstRow.locator("td.direct-location-rr-ticks");
  const ticksText = await ticksCell.textContent();
  expect(ticksText).toBeTruthy();
  const expectedTicks = parseInt(ticksText!.trim(), 10);

  await ticksCell.click();

  // Verify debugger navigated to expectedTicks
  await expect.poll(async () => {
    return await ctPage.evaluate(() => (window as any).data.services.debugger.location.rrTicks);
  }).toBe(expectedTicks);

  // 2. Nested element click navigation test
  const secondRow = rows[1].root;
  const secondTicksCell = secondRow.locator("td.direct-location-rr-ticks");
  const secondTicksText = await secondTicksCell.textContent();
  const secondExpectedTicks = parseInt(secondTicksText!.trim(), 10);

  const traceValuesCell = secondRow.locator("td.trace-values");
  const nestedElement = traceValuesCell.locator("*").first();
  if (await nestedElement.count() > 0) {
    await nestedElement.first().click();
  } else {
    await traceValuesCell.click();
  }

  // Verify debugger navigated to secondExpectedTicks
  await expect.poll(async () => {
    return await ctPage.evaluate(() => (window as any).data.services.debugger.location.rrTicks);
  }).toBe(secondExpectedTicks);
});

/**
 * Regression test for issue #566 — "the tracepoint results table disappears
 * after the first jump".
 *
 * Clicking a result row emits `CtTraceJump`; the completed move that follows
 * used to make `editorAfterRedraw` call `refreshTraceViewZoneDom()` for every
 * expanded tracepoint, wiping the view zone's `innerHTML`.  That detached the
 * `<table>` the live jQuery-DataTables instance was bound to while leaving
 * `dataTable.context` non-nil, so `renderTableResults` refused to rebuild it
 * and the `.chart-table` container stayed `hidden`: the grid vanished and no
 * second jump was possible.
 */
test("test_tracepoint_table_survives_jump: results grid stays live after navigating from it", async ({ ctPage }) => {
  if (!fs.existsSync(fixture.traceDir)) {
    await readyOnEntryTest(ctPage);
    console.log("No trace generated, skipping tracepoint_table_survives_jump spec");
    return;
  }

  const { editor, tracePanel, rowsLocator } = await openPopulatedTracepoint(ctPage);

  const rowsBefore = await tracePanel.traceRows();
  expect(rowsBefore.length).toBeGreaterThanOrEqual(MIN_EXPECTED_ROWS);

  const chartTable = tracePanel.root.locator(".chart-table");
  await expect(chartTable).not.toHaveClass(/(^|\s)hidden(\s|$)/);

  // --- first jump: click a row, exactly as a user would -------------------
  const firstTicksCell = rowsBefore[0].root.locator("td.direct-location-rr-ticks");
  const firstTicks = parseInt((await firstTicksCell.textContent())!.trim(), 10);
  await firstTicksCell.click();

  await expect.poll(async () => {
    return await ctPage.evaluate(() => (window as any).data.services.debugger.location.rrTicks);
  }, { timeout: 15000 }).toBe(firstTicks);

  // The grid must still be visible, still populated, and the DataTables
  // instance must still be attached to a table that is in the document.
  await expect(chartTable).not.toHaveClass(/(^|\s)hidden(\s|$)/);
  await expect(chartTable).toBeVisible();
  await expect(rowsLocator).toHaveCount(rowsBefore.length);

  const dataTableAlive = await ctPage.evaluate(
    ({ path, line }) => {
      const w = window as any; // eslint-disable-line @typescript-eslint/no-explicit-any
      const editorComponent = w.data?.ui?.editors?.[path];
      const trace = editorComponent?.traces?.[line];
      const context = trace?.dataTable?.context;
      if (!context) return "no-datatable-context";
      const node = context.table().node();
      if (!node) return "no-table-node";
      return document.body.contains(node) ? "attached" : "detached";
    },
    { path: editor.filePath, line: 1 },
  );
  expect(dataTableAlive).toBe("attached");

  // --- second jump: the grid must still be usable -------------------------
  const rowsAfter = await tracePanel.traceRows();
  expect(rowsAfter.length).toBe(rowsBefore.length);

  const secondTicksCell = rowsAfter[1].root.locator("td.direct-location-rr-ticks");
  const secondTicks = parseInt((await secondTicksCell.textContent())!.trim(), 10);
  expect(secondTicks).not.toBe(firstTicks);
  await secondTicksCell.click();

  await expect.poll(async () => {
    return await ctPage.evaluate(() => (window as any).data.services.debugger.location.rrTicks);
  }, { timeout: 15000 }).toBe(secondTicks);

  await expect(chartTable).not.toHaveClass(/(^|\s)hidden(\s|$)/);
  await expect(rowsLocator).toHaveCount(rowsBefore.length);
});
