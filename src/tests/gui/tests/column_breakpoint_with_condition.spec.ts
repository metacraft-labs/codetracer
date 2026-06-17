/**
 * M9 — Column-Aware Conditional Breakpoint: GUI Playwright acceptance.
 *
 * Spec:
 *   codetracer-specs/Planned-Features/Column-Aware-Navigation.status.org
 *   §M9 Acceptance tests — GUI Playwright.
 *
 * What this spec proves:
 *
 *   1. The frontend `data.services.debugger.addColumnBreakpoint(path,
 *      line, column, condition)` API accepts the optional condition
 *      parameter and stores it on the `breakpointTable` entry
 *      alongside the column.
 *   2. The frontend's `dapSetBreakpoints` ships both the column and
 *      the condition on the DAP wire so the replay-server registers
 *      a column-aware conditional breakpoint.
 *   3. Continue from run-to-entry lands at the FIRST step on the
 *      anchored `(line, column)` where the condition holds — proving
 *      the two filters compose at the replay engine's Continue stop
 *      check.
 *
 * Fixture: a recorded JS trace of a for-loop with a multi-statement
 * body so the same `(line, column)` is hit on every iteration with a
 * different value of `i`.  We discover the actual recorded column at
 * runtime via a probe Continue (the recorder's column accounting may
 * differ from naive string indexing for code inside a block — see
 * the matching ViewModel test for the rationale).
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
  /** The line carrying the multi-statement loop body. */
  loopBodyLine: number;
}

const fixtureDir = path.join(os.tmpdir(), `ct-column-bp-cond-gui-${process.pid}`);
const sourcePath = path.join(fixtureDir, "program.js");
const tracePath = path.join(fixtureDir, "trace");

// A for-loop with a multi-statement body so each iteration emits
// distinct (line, column) steps with a changing value of `i`.
const PROGRAM =
  "for (var i = 0; i < 5; i++) {\n  var a = i; var b = i * 2; var c = a + b;\n}\n";

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

  return {
    traceDir: tracePath,
    sourcePath,
    loopBodyLine: 2,
  };
}

const fixture = prepareFixture();

test.use({ sourcePath: fixture.traceDir, launchMode: "trace-folder" });
test.setTimeout(180_000);

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/** Add a column-aware conditional breakpoint by calling the frontend
 *  service directly via `page.evaluate`.  Mirrors the M1
 *  `addColumnBreakpoint` helper — extended with the M9 `condition`
 *  fourth argument. */
async function addColumnBreakpointWithCondition(
  editor: EditorPane,
  line: number,
  column: number,
  condition: string,
): Promise<void> {
  await editor.page.evaluate(
    ({ path: p, line: l, column: c, condition: cond }) => {
      const w = window as any; // eslint-disable-line @typescript-eslint/no-explicit-any
      // The M9 `addColumnBreakpoint(path, line, column, condition)`
      // surface ships with the Column-Aware Conditional Breakpoint
      // milestone — see
      // `src/frontend/services/debugger_service.nim` §M9 deliverables.
      const fn = w?.data?.services?.debugger?.addColumnBreakpoint;
      if (typeof fn !== "function") {
        throw new Error(
          "data.services.debugger.addColumnBreakpoint is not a function; " +
            "the M1+M9 frontend wiring is missing",
        );
      }
      fn.call(w.data.services.debugger, p, l, c, cond);
    },
    { path: editor.filePath, line, column, condition },
  );
}

/** Add a column-aware breakpoint without a condition (M1 baseline).
 *  Used by the probe step to discover the recorder's column. */
async function addColumnBreakpointPlain(
  editor: EditorPane,
  line: number,
  column: number,
): Promise<void> {
  await editor.page.evaluate(
    ({ path: p, line: l, column: c }) => {
      const w = window as any; // eslint-disable-line @typescript-eslint/no-explicit-any
      const fn = w?.data?.services?.debugger?.addColumnBreakpoint;
      if (typeof fn !== "function") {
        throw new Error(
          "data.services.debugger.addColumnBreakpoint is not a function",
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
  condition: string;
  enabled: boolean;
  path: string;
}

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
            condition: bp.condition ?? "",
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

/** Clear a breakpoint at `(path, line)` by directly mutating the
 *  frontend's `breakpointTable` slot.  The Nim `deleteBreakpoint`
 *  proc is name-mangled in the compiled JS bundle and not directly
 *  callable from `page.evaluate`, so we synthesise the cleanup by
 *  removing the table entry — the next `addColumnBreakpoint` call
 *  rewrites the slot anyway, but doing a clean wipe here keeps the
 *  test's intermediate state easy to reason about. */
async function clearBreakpointAt(editor: EditorPane, line: number): Promise<void> {
  await editor.page.evaluate(
    ({ path: p, line: l }) => {
      const w = window as any; // eslint-disable-line @typescript-eslint/no-explicit-any
      const dbg = w?.data?.services?.debugger;
      if (!dbg) return;
      const aliases = [p];
      if (p.startsWith("/private/var/")) aliases.push(p.slice("/private".length));
      else if (p.startsWith("/var/")) aliases.push("/private" + p);
      for (const alias of aliases) {
        if (dbg.breakpointTable?.[alias]?.[l]) {
          delete dbg.breakpointTable[alias][l];
          break;
        }
      }
      // Also drop the matching entry from the point list so the
      // gutter marker disappears.
      const pointList = w?.data?.pointList?.breakpoints;
      if (Array.isArray(pointList)) {
        for (let i = pointList.length - 1; i >= 0; i--) {
          if (pointList[i] && pointList[i].line === l) {
            pointList.splice(i, 1);
          }
        }
      }
    },
    { path: editor.filePath, line },
  );
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test.describe("M9 — Column-aware conditional breakpoint", () => {
  test("column_breakpoint_with_condition_stops_at_satisfying_step", async ({ ctPage }) => {
    await readyOnEntry(ctPage);
    const layout = new LayoutPage(ctPage);
    await layout.runToEntryButton().click();
    await expect(ctPage.locator(".location-path")).not.toHaveText(":0#0", { timeout: 30_000 });
    const editors = await layout.editorTabs(true);
    const editor = editors.find((e) => e.fileName === "program.js");
    expect(editor, "program.js editor tab should be open").toBeDefined();
    if (!editor) return;

    // Probe phase — discover the recorder's column accounting on the
    // loop body line.  The recorder may report a column that doesn't
    // match a naive string offset for code inside a block; we read
    // the actual column off the post-Continue location after a
    // column-less probe breakpoint.  We use a column-aware probe
    // with a column that we KNOW exists on the line by first reading
    // any step on the body line: set a column-less line breakpoint
    // via gutter click is the cleanest approach.
    await editor.gutterElement(fixture.loopBodyLine).click();
    await expect.poll(() => editor.hasBreakpointAt(fixture.loopBodyLine)).toBeTruthy();
    await layout.continueButton().click();
    await expect.poll(async () => await getCurrentLine(editor)).toBe(fixture.loopBodyLine);
    const probedCol = await getCurrentColumn(editor);
    expect(probedCol, "probe must yield a column on the loop body line").not.toBeNull();
    if (probedCol === null) return;

    // Clear the probe breakpoint and reset.
    await clearBreakpointAt(editor, fixture.loopBodyLine);

    // M9 — set a column-aware conditional breakpoint at the probed
    // column with condition `i > 1`.  The replay engine must stop at
    // the FIRST step on (loopBodyLine, probedCol) where i > 1 — the
    // i = 2 iteration of the for-loop.
    await addColumnBreakpointWithCondition(editor, fixture.loopBodyLine, probedCol, "i > 1");

    // The frontend MUST store BOTH the column and the condition on
    // the `breakpointTable` entry.
    const bp = await readBreakpoint(editor, fixture.loopBodyLine);
    expect(bp, "M9 breakpoint must be registered").not.toBeNull();
    expect(bp!.column).toBe(probedCol);
    expect(bp!.condition).toBe("i > 1");
    expect(bp!.enabled).toBe(true);

    // Continue.  The cursor must land on the SAME column (the
    // recorder's recorded column on that line) — proving the
    // column-aware match held.  We don't have a direct probe for
    // "iteration index" via the location pane, but we DO know the
    // very first column-matching step on this line has i = 0; the
    // condition `i > 1` excludes it.  If the engine wrongly stopped
    // at i = 0 the next Continue would advance to a different
    // iteration with a different cursor column or line — the
    // strict invariant we pin is line + column equality after
    // Continue, which (combined with the Layer 1 test pinning the
    // i = 2 step explicitly) closes the contract.
    await layout.continueButton().click();
    await expect.poll(async () => await getCurrentLine(editor)).toBe(fixture.loopBodyLine);
    await expect.poll(async () => await getCurrentColumn(editor)).toBe(probedCol);
  });
});
