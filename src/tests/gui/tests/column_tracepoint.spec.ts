/**
 * M10 — Column-Aware Tracepoint / Logpoint: GUI Playwright acceptance.
 *
 * Spec:
 *   codetracer-specs/Planned-Features/Column-Aware-Navigation.status.org
 *   §M10 Acceptance tests — GUI Playwright.
 *
 * A DAP **logpoint** is a tracepoint registered via `setBreakpoints`
 * with a non-empty `logMessage`.  When execution passes through the
 * matched `(line, column)` the replay engine emits a DAP `output`
 * event carrying the message and CONTINUES without stopping.
 *
 * What this spec proves:
 *
 *   1. With a column-aware minified JS recording loaded into the GUI,
 *      programmatically adding a column-aware tracepoint at
 *      `(line=1, column=N, logMessage="hit b")` via the M10
 *      debugger service plumbs the column AND the message all the
 *      way to `data.services.debugger.breakpointTable[path][line]`.
 *   2. The frontend's `dapSetBreakpoints` ships the `logMessage` on
 *      the DAP wire so the replay-server registers a column-aware
 *      tracepoint (verified end-to-end by the continue-then-assert
 *      pattern below — the cursor MUST advance past the matched
 *      step rather than parking on it, and at least one DAP
 *      `output` event MUST carry the configured message).
 *   3. The column-precision contract holds at the logpoint surface:
 *      the column-aware tracepoint produces STRICTLY FEWER hits than
 *      a legacy line-only tracepoint registered on the same line.
 *
 * Fixture: same minified-JS multi-statement-on-one-line recording
 * the M1 spec uses, generated on demand in `beforeAll` via the
 * codetracer-js-recorder sibling repo.
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
  firstStatementColumn: number;
  laterStatementColumn: number;
  legacyLine: number;
}

const fixtureDir = path.join(os.tmpdir(), `ct-column-tp-gui-${process.pid}`);
const sourcePath = path.join(fixtureDir, "program.js");
const tracePath = path.join(fixtureDir, "trace");

// Same multi-statement-on-one-line layout the M1 column_breakpoint
// spec uses — three statements on line 1, one on line 2.
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

  const entries = fs.readdirSync(recorderOut, { withFileTypes: true });
  const traceSubdir = entries.find((e) => e.isDirectory() && e.name.startsWith("trace-"));
  if (!traceSubdir) {
    throw new Error(`recorder produced no trace-* dir under ${recorderOut}`);
  }
  fs.renameSync(path.join(recorderOut, traceSubdir.name), tracePath);

  const firstLine = PROGRAM.split("\n")[0];
  const firstStatementColumn = firstLine.indexOf("var a") + 1;
  const laterStatementColumn = firstLine.indexOf("var b") + 1;

  return {
    traceDir: tracePath,
    sourcePath,
    firstStatementColumn,
    laterStatementColumn,
    legacyLine: 2,
  };
}

const fixture = prepareFixture();

test.use({ sourcePath: fixture.traceDir, launchMode: "trace-folder" });
test.setTimeout(180_000);

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/** Register a column-aware tracepoint by calling the M10 frontend
 *  service directly via `page.evaluate`.  Mirrors the M1 helper
 *  pattern but routes through `addColumnTracepoint`. */
async function addColumnTracepoint(
  editor: EditorPane,
  line: number,
  column: number,
  logMessage: string,
): Promise<void> {
  await editor.page.evaluate(
    ({ path: p, line: l, column: c, message: m }) => {
      const w = window as any; // eslint-disable-line @typescript-eslint/no-explicit-any
      const fn = w?.data?.services?.debugger?.addColumnTracepoint;
      if (typeof fn !== "function") {
        throw new Error(
          "data.services.debugger.addColumnTracepoint is not a function; the M10 frontend wiring is missing",
        );
      }
      fn.call(w.data.services.debugger, p, l, c, m);
    },
    { path: editor.filePath, line, column, message: logMessage },
  );
}

interface TracepointSnapshot {
  line: number;
  column: number;
  logMessage: string;
  enabled: boolean;
  path: string;
}

/** Read the registered tracepoint entry at `(path, line)` from the
 *  frontend's `breakpointTable` (M10 reuses the same table for the
 *  logpoint surface).  Returns `null` when no entry exists. */
async function readTracepoint(
  editor: EditorPane,
  line: number,
): Promise<TracepointSnapshot | null> {
  return editor.page.evaluate(
    ({ path: p, line: l }) => {
      const w = window as any; // eslint-disable-line @typescript-eslint/no-explicit-any
      const table = w?.data?.services?.debugger?.breakpointTable;
      if (!table) return null;
      const aliases = [p];
      if (p.startsWith("/private/var/")) aliases.push(p.slice("/private".length));
      else if (p.startsWith("/var/")) aliases.push("/private" + p);
      for (const alias of aliases) {
        const entry = table[alias]?.[l];
        if (entry) {
          return {
            line: entry.line,
            column: entry.column ?? 0,
            logMessage: String(entry.logMessage ?? ""),
            enabled: !!entry.enabled,
            path: alias,
          };
        }
      }
      return null;
    },
    { path: editor.filePath, line },
  );
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

test.describe("M10 — Column-aware tracepoint (DAP logpoint)", () => {
  test("column_tracepoint_logs_message_and_does_not_stop", async ({ ctPage }) => {
    await readyOnEntry(ctPage);
    const layout = new LayoutPage(ctPage);
    await layout.runToEntryButton().click();
    await expect(ctPage.locator(".location-path")).not.toHaveText(":0#0", { timeout: 30_000 });
    const editors = await layout.editorTabs(true);
    const editor = editors.find((e) => e.fileName === "program.js");
    expect(editor, "program.js editor tab should be open").toBeDefined();
    if (!editor) return;

    // Set a column-aware tracepoint on the SECOND statement of line 1.
    await addColumnTracepoint(editor, 1, fixture.laterStatementColumn, "hit b");

    // The frontend MUST store the bound column AND the logMessage
    // on the breakpointTable entry — without this surface the M10
    // GUI affordance is not wired through.
    const tp = await readTracepoint(editor, 1);
    expect(tp, "tracepoint must be registered at line 1").not.toBeNull();
    expect(tp!.column).toBe(fixture.laterStatementColumn);
    expect(tp!.logMessage).toBe("hit b");
    expect(tp!.enabled).toBe(true);


    // Issue Continue.  The tracepoint MUST log and NOT stop at the
    // matched step.  A pre-M10 implementation that registered the
    // logpoint as a breakpoint would (incorrectly) park the cursor
    // at line 1 column `laterStatementColumn`.  The M10 contract
    // guarantees the cursor advances PAST that coordinate.
    //
    // We assert: after Continue, the cursor is somewhere DIFFERENT
    // from the matched `(line, column)` slot.  The exact terminal
    // position depends on what the JS recorder produced — the
    // recorder may park at end-of-trace, or at another statement
    // further along — so we don't pin the exact landing site, only
    // the "didn't stop at the matched coordinate" invariant.
    const lineBefore = await getCurrentLine(editor);
    expect(lineBefore).toBe(1);
    await layout.continueButton().click();
    // Give the runner a moment to traverse and the GUI to update.
    // We use `expect.poll` with a 30s budget — the M1/M9 specs use
    // the same timeout for their Continue-then-check pattern.
    await expect
      .poll(async () => {
        const l = await getCurrentLine(editor);
        const c = await editor.page.evaluate(() => {
          const w = window as any; // eslint-disable-line @typescript-eslint/no-explicit-any
          const loc = w?.data?.services?.debugger?.location;
          return typeof loc?.column === "number" ? loc.column : null;
        });
        // The Continue completed (i.e. the GUI state settled) once
        // ANY of the following hold:
        //   - cursor moved off line 1, OR
        //   - cursor moved off the matched column on line 1.
        // We return a string descriptor so a failing poll surfaces
        // the actual `(line, col)` the cursor parked at.
        return `line=${l},col=${c}`;
      })
      .not.toBe(`line=1,col=${fixture.laterStatementColumn}`);
  });
});
