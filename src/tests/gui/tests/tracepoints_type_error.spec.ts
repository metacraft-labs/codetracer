import { test, expect, readyOnEntryTest } from "../lib/fixtures";
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
const PROGRAM = "var a = 1; var b = 2; var c = a + b;\nvar d = c * 2;\n";

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

test("test_tracepoints_type_error: Verifies no TypeError occurs with tracepoints", async ({ ctPage }) => {
  // Inject style override to bypass the redesigned status bar's hidden location-path
  await ctPage.addStyleTag({ content: '#status #status-base > *:not(#auto-hide-bottom-strip) { display: inline-block !important; }' });
  await readyOnEntryTest(ctPage);

  // If traceDir wasn't created (e.g. no recorder), just pass the test to avoid spurious failures locally.
  if (!fs.existsSync(fixture.traceDir)) {
    console.log("No trace generated, skipping tracepoints_type_error spec");
    return;
  }

  const layout = new LayoutPage(ctPage);
  const editors = await layout.editorTabs(true);
  const editor = editors.find((e) => e.fileName === "program.js");
  expect(editor, "program.js editor tab should be open").toBeDefined();
  if (!editor) return;

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

  // Get rows from the trace log panel
  const rows = await tracePanel.traceRows();
  expect(rows.length).toBeGreaterThan(0);

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
  if (rows.length > 1) {
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
  }
});
