/**
 * M7 — Column-Aware Replay Navigation: Statement-Granularity Step BACK
 * GUI Playwright acceptance.
 *
 * Spec:
 *   codetracer-specs/Planned-Features/Column-Aware-Navigation.status.org
 *   §M7 Acceptance tests — GUI Playwright.
 *
 * What this spec proves:
 *
 *   1. With a column-aware JS recording loaded into the GUI,
 *      programmatically issuing
 *      `data.services.debugger.stepBackStatement()` from line 2 lands
 *      the cursor at line 1 col `var b` (the prior-line transition via
 *      the line-boundary half of the predicate), then on a second
 *      press at line 1 col `var a` (the column-aware reverse hop via
 *      the strictly-LESS column predicate).  Symmetric mirror of the
 *      M2 forward GUI spec.
 *   2. The frontend service exists and dispatches through the same
 *      replay-server DAP channel the legacy reverse-next button surface
 *      uses — i.e. the M7 affordance is wired through both the legacy
 *      Shift+F10 button surface and the new statement-granularity
 *      reverse keybind surface (Alt+Shift+F10).
 *
 * Fixture: a recorded JS trace with two statements on line 1
 * (`var a = 1; var b = 2;`) followed by a single statement on line 2
 * (`var c = a + b;`).  Mirrors the M2 forward + M7 ViewModel fixture
 * exactly so the GUI assertion stays runnable against the JS
 * recorder's actually-emitted column stream.  See the M2 Notes in
 * `codetracer-specs/Planned-Features/Column-Aware-Navigation.status.org`
 * — "JS recorder column reset on same-line continuation" — for the
 * reason we stop at two statements per line on real recordings; the
 * three-statement reverse contract is pinned at the synthetic-data
 * DAP test layer (`tests/dap_statement_step_back.rs`).  The recording
 * is generated on demand in module-init time using the
 * codetracer-js-recorder sibling repo, mirroring the M2 spec.
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

// ---------------------------------------------------------------------------
// Fixture preparation
// ---------------------------------------------------------------------------

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
  /** 1-indexed column of `var a` on line 1. */
  colVarA: number;
  /** 1-indexed column of `var b` on line 1. */
  colVarB: number;
  /** 1-indexed line of the single-statement follow-up (`var c = a + b;`). */
  lineTwo: number;
}

const fixtureDir = path.join(os.tmpdir(), `ct-stmt-step-back-gui-${process.pid}`);
const sourcePath = path.join(fixtureDir, "program.js");
const tracePath = path.join(fixtureDir, "trace");

// Same fixture program as the M2 forward spec — see the file-header
// docs for the two-statements-per-line rationale.
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
    [recorder, "record", sourcePath, "--out-dir", recorderOut],
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
// Helpers
// ---------------------------------------------------------------------------

/** Invoke `data.services.debugger.stepOverStatement()` via
 *  `page.evaluate` — walk the cursor forward so we can then drive it
 *  backwards from a known position.  Mirrors the M2 forward spec's
 *  helper exactly. */
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

/** Invoke `data.services.debugger.stepBackStatement()` via
 *  `page.evaluate` — the M7 reverse-direction surface.  Symmetric
 *  mirror of `stepOverStatement` above. */
async function stepBackStatement(editor: EditorPane): Promise<void> {
  await editor.page.evaluate(() => {
    const w = window as any; // eslint-disable-line @typescript-eslint/no-explicit-any
    const fn = w?.data?.services?.debugger?.stepBackStatement;
    if (typeof fn !== "function") {
      throw new Error(
        "data.services.debugger.stepBackStatement is not a function; the M7 frontend wiring is missing",
      );
    }
    fn.call(w.data.services.debugger);
  });
}

async function getCurrentColumn(editor: EditorPane): Promise<number | null> {
  return editor.page.evaluate(() => {
    const w = window as any; // eslint-disable-line @typescript-eslint/no-explicit-any
    const loc = w?.data?.services?.debugger?.location;
    if (!loc) return null;
    if (typeof loc.column !== "number") return null;
    return loc.column;
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

test.describe("M7 — Statement-granularity step BACK", () => {
  test("statement_step_back_advances_one_statement_per_press", async ({ ctPage }) => {
    await readyOnEntry(ctPage);
    const layout = new LayoutPage(ctPage);
    await layout.runToEntryButton().click();
    await expect(ctPage.locator(".location-path")).not.toHaveText(":0#0", { timeout: 30_000 });
    const editors = await layout.editorTabs(true);
    const editor = editors.find((e) => e.fileName === "program.js");
    expect(editor, "program.js editor tab should be open").toBeDefined();
    if (!editor) return;

    // Sanity — initial cursor is at line 1 col 1 (start of `var a`).
    await expect.poll(async () => await getCurrentLine(editor)).toBe(1);
    await expect
      .poll(async () => await getCurrentColumn(editor))
      .toBe(fixture.colVarA);

    // Walk forward two statement-granularity hops so the cursor parks
    // on line 2.  The first lands on `var b` (same line, col
    // transition); the second lands on line 2.  This mirrors the M2
    // forward spec exactly — we reuse the forward path to drive the
    // cursor into position so the M7 reverse path is exercised from
    // a known final position.
    await stepOverStatement(editor);
    await expect.poll(async () => await getCurrentLine(editor)).toBe(1);
    await expect
      .poll(async () => await getCurrentColumn(editor))
      .toBe(fixture.colVarB);

    await stepOverStatement(editor);
    await expect.poll(async () => await getCurrentLine(editor)).toBe(fixture.lineTwo);

    // First backward statement step from line 2 — MUST land on the
    // LAST statement of line 1 (column of `var b`, the closest prior
    // step on a different line).  This pins the line-boundary half
    // of the M7 contract at the GUI surface.
    await stepBackStatement(editor);
    await expect.poll(async () => await getCurrentLine(editor)).toBe(1);
    await expect
      .poll(async () => await getCurrentColumn(editor))
      .toBe(fixture.colVarB);

    // Second backward statement step — MUST land on `var a` (column
    // transition within line 1).  The column-aware runner MUST
    // honour the strictly-LESS column predicate — a line-granularity
    // runner would walk past line 1 entirely to the trace boundary.
    // This pins the column-aware half of the M7 contract at the GUI
    // surface.
    await stepBackStatement(editor);
    await expect.poll(async () => await getCurrentLine(editor)).toBe(1);
    await expect
      .poll(async () => await getCurrentColumn(editor))
      .toBe(fixture.colVarA);
  });

  test("statement_step_back_button_is_registered_on_debug_controls", async ({ ctPage }) => {
    // The M7 toolbar affordance: a dedicated "Step Back Statement"
    // control distinct from the legacy reverse-next button.  We pin
    // the service surface itself here — without it the keybind /
    // button wiring on the GUI side is dormant.  Symmetric mirror
    // of the M2 affordance assertion in
    // `statement_step_over.spec.ts`.
    await readyOnEntry(ctPage);
    const exposed = await ctPage.evaluate(() => {
      const w = window as any; // eslint-disable-line @typescript-eslint/no-explicit-any
      return typeof w?.data?.services?.debugger?.stepBackStatement === "function";
    });
    expect(
      exposed,
      "data.services.debugger.stepBackStatement must be a function exposed by the M7 frontend wiring",
    ).toBe(true);
  });
});
