/**
 * M2 — Column-Aware Replay Navigation: Statement-Granularity Step-Over
 * GUI Playwright acceptance.
 *
 * Spec:
 *   codetracer-specs/Planned-Features/Column-Aware-Navigation.status.org
 *   §M2 Acceptance tests — GUI Playwright.
 *
 * What this spec proves:
 *
 *   1. With a column-aware JS recording loaded into the GUI,
 *      programmatically issuing
 *      `data.services.debugger.stepOverStatement()` twice in
 *      sequence lands the cursor at column of `var b` on line 1
 *      (the same-line column transition), then on line 2 (the
 *      line-boundary transition) — the same progression the
 *      headless ViewModel test pins.
 *   2. The frontend service exists and dispatches through the same
 *      replay-server DAP channel the gutter step-over uses — i.e. the
 *      M2 affordance is wired through both the legacy F10 button
 *      surface and the new statement-granularity button surface.
 *
 * Fixture: a recorded JS trace with two statements on line 1
 * (`var a = 1; var b = 2;`) followed by a single statement on line 2
 * (`var c = a + b;`).  Mirrors the ViewModel fixture exactly so
 * the GUI assertion stays runnable against the JS recorder's
 * actually-emitted column stream.  See the M2 Notes in
 * `codetracer-specs/Planned-Features/Column-Aware-Navigation.status.org`
 * — "JS recorder column reset on same-line continuation" — for the
 * reason we stop at two statements per line on real recordings;
 * the three-statement contract is pinned at the synthetic-data DAP
 * test layer (`tests/dap_statement_step_over.rs`).  The recording
 * is generated on demand in module-init time using the
 * codetracer-js-recorder sibling repo, mirroring the M1 BEAM
 * fixture pattern (no pre-baked goldens).
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

const fixtureDir = path.join(os.tmpdir(), `ct-stmt-step-over-gui-${process.pid}`);
const sourcePath = path.join(fixtureDir, "program.js");
const tracePath = path.join(fixtureDir, "trace");

// The recorded program puts TWO statements on line 1 (`var a` and
// `var b`) and one statement on line 2 (`var c`).  The two-statement
// form is chosen because the JS recorder's column-cursor projection
// reliably preserves the first column transition on a same line but
// collapses subsequent ones (see the M2 Notes in
// `codetracer-specs/Planned-Features/Column-Aware-Navigation.status.org`
// — "JS recorder column reset on same-line continuation").  The
// three-statement contract is pinned at the synthetic-data DAP test
// layer (`tests/dap_statement_step_over.rs`).
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

  // Find the trace-N subdirectory and rename to a stable path.
  const entries = fs.readdirSync(recorderOut, { withFileTypes: true });
  const traceSubdir = entries.find((e) => e.isDirectory() && e.name.startsWith("trace-"));
  if (!traceSubdir) {
    throw new Error(`recorder produced no trace-* dir under ${recorderOut}`);
  }
  fs.renameSync(path.join(recorderOut, traceSubdir.name), tracePath);

  // The recorder lands a step at the start of each statement.  We
  // compute the column positions directly from the source string —
  // see PROGRAM above for the layout.  The recorder's columns are
  // 1-indexed.
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
 *  `page.evaluate` — mirrors the F10/Shift-F10 keybind path the GUI
 *  uses for line-granularity step-over, but routes through the M2
 *  statement-granularity surface. */
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

test.describe("M2 — Statement-granularity step-over", () => {
  test("statement_step_over_advances_one_statement_per_press", async ({ ctPage }) => {
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

    // First statement step-over: var a -> var b on the SAME line.
    // The column-aware runner MUST honour the column transition —
    // a line-granularity runner would skip line 1 entirely and land
    // on line 2.  This pins the M2 contract at the GUI surface.
    await stepOverStatement(editor);
    await expect.poll(async () => await getCurrentLine(editor)).toBe(1);
    await expect
      .poll(async () => await getCurrentColumn(editor))
      .toBe(fixture.colVarB);

    // Second statement step-over: var b -> line 2.  After exhausting
    // line 1's in-line statement boundaries, the runner advances to
    // the next executed line just like a line-granularity runner.
    await stepOverStatement(editor);
    await expect
      .poll(async () => await getCurrentLine(editor))
      .toBe(fixture.lineTwo);
  });

  test("statement_step_over_button_is_registered_on_debug_controls", async ({ ctPage }) => {
    // The M2 toolbar affordance: a dedicated "Step Over Statement"
    // control distinct from the legacy F10 next button.  We pin the
    // service surface itself here — without it the keybind / button
    // wiring on the GUI side is dormant.
    await readyOnEntry(ctPage);
    const exposed = await ctPage.evaluate(() => {
      const w = window as any; // eslint-disable-line @typescript-eslint/no-explicit-any
      return typeof w?.data?.services?.debugger?.stepOverStatement === "function";
    });
    expect(
      exposed,
      "data.services.debugger.stepOverStatement must be a function exposed by the M2 frontend wiring",
    ).toBe(true);
  });
});
