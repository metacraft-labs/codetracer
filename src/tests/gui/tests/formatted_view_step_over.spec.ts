/**
 * M3 — Column-Aware Replay Navigation: Formatted-View Step-Over
 * GUI Playwright acceptance.
 *
 * Spec:
 *   codetracer-specs/Planned-Features/Column-Aware-Navigation.status.org
 *   §M3 Acceptance tests — GUI Playwright.
 *
 * What this spec proves:
 *
 *   1. With a column-aware JS recording loaded into the GUI and a
 *      synthetic srcview activated programmatically, pressing F10
 *      advances the editor cursor by one /formatted line/ — not by
 *      one minified line.  Every recorded step in the fixture sits on
 *      the same minified line, so a regression to the legacy minified
 *      runner would skip the entire program on one press.
 *
 *   2. Without the formatted view activated, the same F10 press behaves
 *      exactly like M1/M2 — advancing by minified line.  This pins the
 *      back-compat half of the M3 contract.
 *
 *   3. With the formatted view active, Shift+F10 (statement granularity)
 *      composes cleanly with M3 — the cursor lands at the next formatted
 *      statement, mirroring M2's column-aware predicate but applied to
 *      the formatted-side projection.
 *
 * Fixture: a recorded JS trace with two statements on minified line 1
 * (`var a = 1; var b = 2;`) plus one statement on minified line 2 — the
 * same two-statements-per-line shape the M2 GUI spec uses.  A synthetic
 * srcview V3 map injected at runtime via `data.services.debugger.
 * installSourceViewForTest` projects each minified column to a distinct
 * formatted line so the F10 transitions are observable.
 *
 *   CODETRACER_JS_RECORDER_PATH=<path/to/cli/dist/index.js>  (optional)
 *
 * defaults to ../codetracer-js-recorder/packages/cli/dist/index.js.
 */
import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";
import * as childProcess from "node:child_process";

import { test, expect, readyOnEntryTest as readyOnEntry } from "../lib/fixtures";
import { LayoutPage } from "../page-objects/layout-page";
import { EditorPane } from "../page-objects/panes/editor/editor-pane";

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
  throw new Error(
    "codetracer-js-recorder not found; set CODETRACER_JS_RECORDER_PATH or " +
      "build the sibling repo (npm run build).",
  );
}

interface RecordedFixture {
  traceDir: string;
  sourcePath: string;
  colVarA: number;
  colVarB: number;
  lineTwo: number;
}

const fixtureDir = path.join(os.tmpdir(), `ct-fmt-view-step-over-gui-${process.pid}`);
const sourcePath = path.join(fixtureDir, "program.js");
const tracePath = path.join(fixtureDir, "trace");

// Two statements on line 1 + one statement on line 2 — same shape as
// the M2 GUI spec.  `--no-autoformat` keeps the recorder from emitting
// a real srcview; we inject a synthetic one programmatically below so
// the M3 contract is exercised without depending on `prettier` on PATH.
const PROGRAM = "var a = 1; var b = 2;\nvar c = a + b;\n";

function prepareFixture(): RecordedFixture {
  if (fs.existsSync(fixtureDir)) {
    fs.rmSync(fixtureDir, { recursive: true, force: true });
  }
  fs.mkdirSync(fixtureDir, { recursive: true });
  fs.writeFileSync(sourcePath, PROGRAM);

  const recorder = findJsRecorder();
  const recorderOut = path.join(fixtureDir, "rec-out");
  fs.mkdirSync(recorderOut, { recursive: true });
  const result = childProcess.spawnSync(
    "node",
    [recorder, "record", "--no-autoformat", sourcePath, "--out-dir", recorderOut],
    { encoding: "utf-8", timeout: 60_000 },
  );
  if (result.status !== 0) {
    throw new Error(
      `JS recorder failed: status=${result.status}\nstdout:\n${result.stdout}\nstderr:\n${result.stderr}`,
    );
  }

  const entries = fs.readdirSync(recorderOut, { withFileTypes: true });
  const traceSubdir = entries.find((e) => e.isDirectory() && e.name.startsWith("trace-"));
  if (!traceSubdir) {
    throw new Error(`recorder produced no trace-* dir under ${recorderOut}`);
  }
  fs.renameSync(path.join(recorderOut, traceSubdir.name), tracePath);

  const firstLine = PROGRAM.split("\n")[0];
  const colVarA = firstLine.indexOf("var a") + 1;
  const colVarB = firstLine.indexOf("var b") + 1;

  return {
    traceDir: tracePath,
    sourcePath,
    colVarA,
    colVarB,
    lineTwo: 2,
  };
}

const fixture = prepareFixture();

test.use({ sourcePath: fixture.traceDir, launchMode: "trace-folder" });
test.setTimeout(180_000);

// ---------------------------------------------------------------------------
// Synthetic srcview V3 mapping helper
// ---------------------------------------------------------------------------

function vlqEncode(value: number): string {
  let z = value < 0 ? ((-value) << 1) | 1 : value << 1;
  const alphabet =
    "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
  let out = "";
  do {
    let digit = z & 0x1f;
    z >>>= 5;
    if (z !== 0) digit |= 0x20;
    out += alphabet[digit];
  } while (z !== 0);
  return out;
}

function segment(
  out: string,
  dGenCol: number,
  dSrcIdx: number,
  dSrcLine: number,
  dSrcCol: number,
): string {
  return out + vlqEncode(dGenCol) + vlqEncode(dSrcIdx) + vlqEncode(dSrcLine) + vlqEncode(dSrcCol);
}

const FormattedViewPath = "/tmp/m3-gui-test-formatted-view.fmt.js";
const FmtLine1 = 1;
const FmtLine2 = 3;

function buildMinifiedToFormattedMapV3(
  formattedSourceName: string,
  colS1: number,
  colS2: number,
  fmtLine1: number,
  fmtLine2: number,
): string {
  let mappings = "";
  mappings = segment(mappings, colS1 - 1, 0, fmtLine1 - 1, 0);
  mappings += ",";
  mappings = segment(mappings, colS2 - colS1, 0, fmtLine2 - fmtLine1, 0);
  mappings += ";";
  mappings = segment(mappings, 0, 0, 3, 0);
  return JSON.stringify({
    version: 3,
    file: "program.js",
    sources: [formattedSourceName],
    names: [],
    mappings,
  });
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

async function installSourceViewForTest(
  editor: EditorPane,
  args: { recordedPath: string; formattedViewPath: string; sourcemapV3Json: string },
): Promise<void> {
  await editor.page.evaluate((a) => {
    const w = window as any; // eslint-disable-line @typescript-eslint/no-explicit-any
    const fn = w?.data?.services?.debugger?.installSourceViewForTest;
    if (typeof fn !== "function") {
      throw new Error(
        "data.services.debugger.installSourceViewForTest is not a function; the M3 frontend wiring is missing",
      );
    }
    fn.call(w.data.services.debugger, a.recordedPath, a.formattedViewPath, a.sourcemapV3Json);
  }, args);
}

async function setActiveSourceView(editor: EditorPane, viewPath: string | null): Promise<void> {
  await editor.page.evaluate((p) => {
    const w = window as any; // eslint-disable-line @typescript-eslint/no-explicit-any
    const fn = w?.data?.services?.debugger?.setActiveSourceView;
    if (typeof fn !== "function") {
      throw new Error(
        "data.services.debugger.setActiveSourceView is not a function; the M3 frontend wiring is missing",
      );
    }
    fn.call(w.data.services.debugger, p);
  }, viewPath);
}

async function stepOver(editor: EditorPane): Promise<void> {
  // Send a plain DAP `next` request through the same `dapApi.sendCtRequest`
  // pipeline the M2 `stepOverStatement` path uses.  This exercises the
  // exact DAP code path the M3 runner hooks into, without depending on
  // the legacy `services.debugger.step(action, actionEnum)` numeric
  // enum signature.  The frontend's F10 binding ultimately lands on the
  // same DAP `next` request; we're just bypassing the GUI keybind
  // layer and dispatching the request programmatically.
  await editor.page.evaluate(() => {
    const w = window as any; // eslint-disable-line @typescript-eslint/no-explicit-any
    const dapApi = w?.data?.dapApi;
    if (dapApi && typeof dapApi.sendCtRequest === "function") {
      // `DapNext` is the CtEventKind whose string mapping in
      // `dap.nim` is "next" — sending it dispatches the legacy
      // line-granularity step the M3 runner intercepts on active-view
      // toggle.
      //
      // The ordinal value is derived from
      // ``src/common/ct_event.nim``'s ``CtEventKind`` enum (declared
      // in source-order, no explicit values, so ordinals follow
      // declaration order starting at 0).  Counting through the
      // enum: ``CtUpdateTable=0 ... DapStepIn=18, DapStepInResponse=19,
      // DapStepOut=20, DapStepOutResponse=21, DapNext=22``.  Earlier
      // revisions of this test hard-coded ``24``, which is actually
      // ``DapContinue`` — that ran the trace to the end and (with the
      // formatted-view active) projected the final minified step
      // ``(2, 1)`` onto formatted line ``FmtLine2 + 3 = 6``, exactly
      // the value the failing assertion reported.  The legacy-view
      // sibling test ``minified_view_step_over_preserves_legacy_line_granularity``
      // green-lit the same bug only because Continue happens to land
      // on the last user-source line, which equals ``fixture.lineTwo``.
      // Sending DapNext (22) drives the formatted-view runner the
      // M3 contract pins this test on.
      dapApi.sendCtRequest(/* DapNext */ 22, { threadId: 1 });
      return;
    }
    // Fallback for harnesses that surface `stepForward` on the
    // debugger service directly (also a DAP `next` dispatcher).
    const stepFwd = w?.data?.services?.debugger?.stepForward;
    if (typeof stepFwd === "function") {
      stepFwd.call(w.data.services.debugger);
      return;
    }
    throw new Error(
      "Neither dapApi.sendCtRequest nor services.debugger.stepForward is reachable; cannot drive the M3 step",
    );
  });
}

async function stepOverStatement(editor: EditorPane): Promise<void> {
  await editor.page.evaluate(() => {
    const w = window as any; // eslint-disable-line @typescript-eslint/no-explicit-any
    const fn = w?.data?.services?.debugger?.stepOverStatement;
    if (typeof fn !== "function") {
      throw new Error(
        "data.services.debugger.stepOverStatement is not a function; the M2 frontend wiring is missing",
      );
    }
    fn.call(w.data.services.debugger);
  });
}

async function getCurrentLine(editor: EditorPane): Promise<number | null> {
  return editor.page.evaluate(() => {
    const w = window as any; // eslint-disable-line @typescript-eslint/no-explicit-any
    const loc = w?.data?.services?.debugger?.location;
    if (!loc) return null;
    if (typeof loc.line !== "number") return null;
    return loc.line;
  });
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test.describe("M3 — Formatted-view step-over", () => {
  test("formatted_view_step_over_advances_one_formatted_line", async ({ ctPage }) => {
    await readyOnEntry(ctPage);
    const layout = new LayoutPage(ctPage);
    await layout.runToEntryButton().click();
    await expect(ctPage.locator(".location-path")).not.toHaveText(":0#0", { timeout: 30_000 });
    const editors = await layout.editorTabs(true);
    const editor = editors.find((e) => e.fileName === "program.js");
    expect(editor, "program.js editor tab should be open").toBeDefined();
    if (!editor) return;

    const mapJson = buildMinifiedToFormattedMapV3(
      FormattedViewPath,
      fixture.colVarA,
      fixture.colVarB,
      FmtLine1,
      FmtLine2,
    );
    await installSourceViewForTest(editor, {
      recordedPath: fixture.sourcePath,
      formattedViewPath: FormattedViewPath,
      sourcemapV3Json: mapJson,
    });
    await setActiveSourceView(editor, FormattedViewPath);

    await expect.poll(async () => await getCurrentLine(editor)).toBe(FmtLine1);

    // F10 under the formatted view must land at the next formatted
    // line, not at the next minified column.
    await stepOver(editor);
    await expect.poll(async () => await getCurrentLine(editor)).toBe(FmtLine2);
  });

  test("minified_view_step_over_preserves_legacy_line_granularity", async ({ ctPage }) => {
    await readyOnEntry(ctPage);
    const layout = new LayoutPage(ctPage);
    await layout.runToEntryButton().click();
    await expect(ctPage.locator(".location-path")).not.toHaveText(":0#0", { timeout: 30_000 });
    const editors = await layout.editorTabs(true);
    const editor = editors.find((e) => e.fileName === "program.js");
    expect(editor, "program.js editor tab should be open").toBeDefined();
    if (!editor) return;

    // No active source view — legacy minified mode.  F10 must advance
    // directly past the same-minified-line column delta to line 2.
    await expect.poll(async () => await getCurrentLine(editor)).toBe(1);
    await stepOver(editor);
    await expect.poll(async () => await getCurrentLine(editor)).toBe(fixture.lineTwo);
  });

  test("formatted_view_step_over_statement_composes_with_m2", async ({ ctPage }) => {
    await readyOnEntry(ctPage);
    const layout = new LayoutPage(ctPage);
    await layout.runToEntryButton().click();
    await expect(ctPage.locator(".location-path")).not.toHaveText(":0#0", { timeout: 30_000 });
    const editors = await layout.editorTabs(true);
    const editor = editors.find((e) => e.fileName === "program.js");
    expect(editor, "program.js editor tab should be open").toBeDefined();
    if (!editor) return;

    const mapJson = buildMinifiedToFormattedMapV3(
      FormattedViewPath,
      fixture.colVarA,
      fixture.colVarB,
      FmtLine1,
      FmtLine2,
    );
    await installSourceViewForTest(editor, {
      recordedPath: fixture.sourcePath,
      formattedViewPath: FormattedViewPath,
      sourcemapV3Json: mapJson,
    });
    await setActiveSourceView(editor, FormattedViewPath);

    await expect.poll(async () => await getCurrentLine(editor)).toBe(FmtLine1);
    await stepOverStatement(editor);
    await expect.poll(async () => await getCurrentLine(editor)).toBe(FmtLine2);
  });

  test("formatted_view_service_surfaces_are_registered", async ({ ctPage }) => {
    // Pin that both the M3 service surfaces are present on the
    // ``DebuggerService`` instance the GUI surfaces.  Without them
    // the F10 / Shift+F10 wiring in the editor pane has no way to
    // toggle the formatted view, and the runner falls back to
    // minified coordinates unconditionally.
    await readyOnEntry(ctPage);
    const surfaces = await ctPage.evaluate(() => {
      const w = window as any; // eslint-disable-line @typescript-eslint/no-explicit-any
      return {
        setActive: typeof w?.data?.services?.debugger?.setActiveSourceView === "function",
        installForTest: typeof w?.data?.services?.debugger?.installSourceViewForTest === "function",
      };
    });
    expect(surfaces.setActive, "setActiveSourceView surface must be present").toBe(true);
    expect(surfaces.installForTest, "installSourceViewForTest surface must be present").toBe(true);
  });
});
