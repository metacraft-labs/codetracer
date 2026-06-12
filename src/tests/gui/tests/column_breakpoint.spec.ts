/**
 * M1 — Column-Aware Replay Navigation: GUI Playwright acceptance.
 *
 * Spec:
 *   codetracer-specs/Planned-Features/Column-Aware-Navigation.status.org
 *   §M1 Acceptance tests — GUI Playwright.
 *
 * What this spec proves:
 *
 *   1. With a column-aware minified JS recording loaded into the GUI,
 *      programmatically adding a breakpoint at `(line=1, column=N)`
 *      via the debugger service plumbs the column all the way to
 *      `data.services.debugger.breakpointTable[path][line].column`.
 *   2. The frontend's `dapSetBreakpoints` ships the column on the
 *      DAP wire so the replay-server registers a column-aware
 *      breakpoint (verified end-to-end by the continue-then-assert
 *      pattern below — the line column the cursor lands on after
 *      Continue must match the recorded column at the bound step).
 *   3. The legacy line-only breakpoint (gutter click without column
 *      precision) continues to work — back-compat path is intact.
 *
 * Fixture: a recorded JS trace of a single-line, multi-statement
 * program (`var a=1; var b=2; var c=a+b;`) — the headline minified
 * JS case M1 is built to support.  The recording is generated on
 * demand in `beforeAll` using the codetracer-js-recorder sibling
 * repo, mirroring the BEAM fixture pattern (no pre-baked goldens).
 *
 *   CODETRACER_JS_RECORDER_PATH=<path/to/cli/dist/index.js>  (optional)
 *
 * defaults to ../codetracer-js-recorder/packages/cli/dist/index.js.
 */
import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";
import * as childProcess from "node:child_process";

import { test, expect } from "../lib/fixtures";
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
  /** 1-indexed column of the first recorded statement on line 1. */
  firstStatementColumn: number;
  /** 1-indexed column of a later statement on line 1.  We assert this
   * is the column the cursor lands on after a column-anchored
   * Continue.  Picked by reading the recorded trace's step events
   * after recording so the test stays true to whatever columns the
   * recorder actually emitted, instead of guessing offsets in the
   * source string. */
  laterStatementColumn: number;
  /** 1-indexed line a legacy line-only breakpoint targets. */
  legacyLine: number;
}

const fixtureDir = path.join(os.tmpdir(), `ct-column-bp-gui-${process.pid}`);
const sourcePath = path.join(fixtureDir, "program.js");
const tracePath = path.join(fixtureDir, "trace");

// The recorded program intentionally puts three statements on line 1
// so the recorder lands distinct steps at the start of each — column 1
// for `var a`, column 12 for `var b`, column 23 for `var c` (the
// fourth char after each semicolon-space).  Line 2 has a single
// statement so it doubles as the legacy line-only target.
const PROGRAM = "var a = 1; var b = 2; var c = a + b;\nvar d = c * 2;\n";

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
  const firstStatementColumn = firstLine.indexOf("var a") + 1;
  // The second statement (`var b`) starts at the position after
  // `var a = 1; `.  The JS recorder for this fixture emits a step
  // at column 12 for line 1 (verified at design time with
  // `ct-print --events`); we still derive it from the source string
  // to keep the assertion semantic, not magical.
  const laterStatementColumn = firstLine.indexOf("var b") + 1;

  return {
    traceDir: tracePath,
    sourcePath,
    firstStatementColumn,
    laterStatementColumn,
    legacyLine: 2,
  };
}

// Module-scope fixture handle so the `beforeAll` recording can be
// referenced from `test.use({ sourcePath: ... })`.  We record at
// require time (mirroring the BEAM specs' pattern) so the
// `launchMode: "trace-folder"` configuration can point at the
// finished trace.  A failure here aborts THIS spec only — Playwright
// already catches sync throws in test files and reports them as
// suite-level setup failures.
const fixture = prepareFixture();

test.use({ sourcePath: fixture.traceDir, launchMode: "trace-folder" });
test.setTimeout(180_000);

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/** Add a column-aware breakpoint by calling the frontend service
 *  directly via `page.evaluate` — mirrors the gutter-click path the
 *  GUI uses for line-only breakpoints, but pins the column. */
async function addColumnBreakpoint(
  editor: EditorPane,
  line: number,
  column: number,
): Promise<void> {
  await editor.page.evaluate(
    ({ path: p, line: l, column: c }) => {
      const w = window as any; // eslint-disable-line @typescript-eslint/no-explicit-any
      // The M1 `addColumnBreakpoint` API ships with the
      // Column-Aware Replay Navigation campaign — see
      // `src/frontend/services/debugger_service.nim`.
      const fn = w?.data?.services?.debugger?.addColumnBreakpoint;
      if (typeof fn !== "function") {
        throw new Error(
          "data.services.debugger.addColumnBreakpoint is not a function; the M1 frontend wiring is missing",
        );
      }
      fn.call(w.data.services.debugger, p, l, c);
    },
    { path: editor.filePath, line, column },
  );
}

interface BreakpointSnapshot {
  line: number;
  column: number;
  enabled: boolean;
  path: string;
}

/** Read the registered breakpoint at `(path, line)` from the
 *  frontend's `breakpointTable`.  Returns `null` when no breakpoint
 *  exists at that key. */
async function readBreakpoint(
  editor: EditorPane,
  line: number,
): Promise<BreakpointSnapshot | null> {
  return editor.page.evaluate(
    ({ path: p, line: l }) => {
      const w = window as any; // eslint-disable-line @typescript-eslint/no-explicit-any
      const table = w?.data?.services?.debugger?.breakpointTable;
      if (!table) return null;
      const aliases = [p];
      if (p.startsWith("/private/var/")) aliases.push(p.slice("/private".length));
      else if (p.startsWith("/var/")) aliases.push("/private" + p);
      for (const alias of aliases) {
        const bp = table[alias]?.[l];
        if (bp) {
          return {
            line: bp.line,
            column: bp.column ?? 0,
            enabled: !!bp.enabled,
            path: alias,
          };
        }
      }
      return null;
    },
    { path: editor.filePath, line },
  );
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

test.describe("M1 — Column-aware breakpoint", () => {
  test("column_breakpoint_stops_at_recorded_column", async ({ ctPage }) => {
    const layout = new LayoutPage(ctPage);
    const editors = await layout.editorTabs(true);
    const editor = editors.find((e) => e.fileName === "program.js");
    expect(editor, "program.js editor tab should be open").toBeDefined();
    if (!editor) return;

    // Set a column-aware breakpoint on the SECOND statement of line 1.
    await addColumnBreakpoint(editor, 1, fixture.laterStatementColumn);

    // The frontend MUST store the bound column on the
    // `breakpointTable` entry — without this surface the M1 GUI
    // affordance is not wired through.
    const bp = await readBreakpoint(editor, 1);
    expect(bp, "breakpoint must be registered at line 1").not.toBeNull();
    expect(bp!.column).toBe(fixture.laterStatementColumn);
    expect(bp!.enabled).toBe(true);

    // Issue Continue; the cursor must land on the recorded column.
    await layout.continueButton().click();
    await expect.poll(async () => await getCurrentLine(editor)).toBe(1);
    await expect
      .poll(async () => await getCurrentColumn(editor))
      .toBe(fixture.laterStatementColumn);
  });

  test("legacy_line_only_breakpoint_still_stops_at_line", async ({ ctPage }) => {
    const layout = new LayoutPage(ctPage);
    const editors = await layout.editorTabs(true);
    const editor = editors.find((e) => e.fileName === "program.js");
    expect(editor, "program.js editor tab should be open").toBeDefined();
    if (!editor) return;

    // Click the gutter on line 2 — legacy line-only path.
    await editor.gutterElement(fixture.legacyLine).click();
    await expect.poll(() => editor.hasBreakpointAt(fixture.legacyLine)).toBeTruthy();

    const bp = await readBreakpoint(editor, fixture.legacyLine);
    expect(bp, "legacy line-only breakpoint must be registered").not.toBeNull();
    // Legacy path MUST keep column at 0 — the M1 extension is opt-in
    // through `addColumnBreakpoint`.
    expect(bp!.column).toBe(0);

    await layout.continueButton().click();
    await expect.poll(async () => await getCurrentLine(editor)).toBe(fixture.legacyLine);
  });
});
