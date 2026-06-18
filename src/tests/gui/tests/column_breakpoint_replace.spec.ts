/**
 * Column-aware breakpoint replacement semantics — Playwright spec.
 *
 * Spec:
 *   codetracer-specs/Planned-Features/Column-Aware-Navigation.status.org
 *   §M1 (one column breakpoint per line) and §M6 (Alt+click affordance).
 *
 * What this spec proves (and is NOT covered by the existing M1/M6
 * specs):
 *
 *   1. The M1 invariant "one column breakpoint per `(path, line)` slot"
 *      holds when the user sets a column breakpoint at one column and
 *      then Alt+clicks the same line at a different column.  The
 *      Alt+click MUST replace the first breakpoint's column (not add
 *      a second one), and the bound column on
 *      `data.services.debugger.breakpointTable[path][line]` MUST be
 *      the column of the Alt+click.
 *
 *   2. Issuing Continue after the replacement halts at the SECOND
 *      column — proving the replacement was actually plumbed through
 *      DAP to the replay-engine column matcher (not just to the
 *      frontend's local view).  A regression where only the
 *      frontend state was updated (but the DAP message kept the old
 *      column) would surface here as the cursor landing at the
 *      first column instead.
 *
 * Why one programmatic + one Alt+click (instead of two Alt+clicks)?
 * The Alt+click pixel→column resolver round-trips through Monaco's
 * own `getOffsetForColumn` + `mousedown` IMouseTarget machinery,
 * which under Xvfb is reliably stable only at a handful of mid-line
 * columns (the M6 spec verifies column 12 — `var b`).  Using the M1
 * programmatic surface (`addColumnBreakpoint`) for the FIRST
 * breakpoint lets us pin its column exactly, then exercise the M6
 * Alt+click path for the REPLACEMENT — which is the part of the
 * contract this spec uniquely covers.
 *
 * Marker-decoration assertions are intentionally out of scope:
 * `column_breakpoint_gutter.spec.ts` already pins the M6 marker
 * render path.  This spec narrowly targets the replacement
 * semantics that no other spec exercises end-to-end.
 *
 * Fixture: reuses the M1 column-aware multi-statement JS recording
 * shape (three statements on line 1), recorded on demand by
 * `codetracer-js-recorder` — the pipeline already working in CI.
 */
import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";
import * as childProcess from "node:child_process";

import { test, expect, readyOnEntryTest as readyOnEntry } from "../lib/fixtures";
import { LayoutPage } from "../page-objects/layout-page";
import {
  addColumnBreakpoint,
  altClickAtColumn,
  getCurrentColumn,
  getCurrentLine,
  readBreakpoint,
} from "../lib/column-aware-helpers";

// ---------------------------------------------------------------------------
// Fixture preparation — same shape as `column_breakpoint_gutter.spec.ts`.
// pid-scoped tmpdir so this spec can run in parallel with the M6 spec
// without trace folder collisions.
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
  /** Column of `var a` (first statement) on line 1.  Acts as the
   *  INITIAL programmatic breakpoint target (set via the M1
   *  `addColumnBreakpoint` service — bypassing the M6 Alt+click
   *  pixel-resolution path so the precise column is locked in
   *  unambiguously). */
  firstStatementColumn: number;
  /** Column of `var b` (second statement) on line 1.  Acts as the
   *  REPLACEMENT Alt+click target — the same mid-line column the
   *  M6 GUI spec uses, known to round-trip correctly through
   *  Monaco's `mousedown` → IMouseTarget → column resolver under
   *  Xvfb. */
  laterStatementColumn: number;
}

const fixtureDir = path.join(os.tmpdir(), `ct-column-bp-replace-${process.pid}`);
const sourcePath = path.join(fixtureDir, "program.js");
const tracePath = path.join(fixtureDir, "trace");

// Three statements on line 1 so Monaco resolves two distinct columns
// at two distinct x-offsets — the regression matrix this spec needs.
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
  const traceSubdir = entries.find(
    (e) => e.isDirectory() && e.name.startsWith("trace-"),
  );
  if (!traceSubdir) {
    throw new Error(`recorder produced no trace-* dir under ${recorderOut}`);
  }
  fs.renameSync(path.join(recorderOut, traceSubdir.name), tracePath);

  const firstLine = PROGRAM.split("\n")[0];
  return {
    traceDir: tracePath,
    sourcePath,
    // `firstStatementColumn` is set via the M1 programmatic surface
    // (no Monaco round-trip).  `laterStatementColumn` is set via the
    // M6 Alt+click path — using `var b` (column 12), the same column
    // the M6 GUI spec validates as round-trippable through Monaco's
    // mouse-target resolver under Xvfb.
    firstStatementColumn: firstLine.indexOf("var a") + 1,
    laterStatementColumn: firstLine.indexOf("var b") + 1,
  };
}

const fixture = prepareFixture();

test.use({ sourcePath: fixture.traceDir, launchMode: "trace-folder" });
test.setTimeout(180_000);

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test.describe("M1/M6 — Column-aware breakpoint replacement on same line", () => {
  test("alt_click_replaces_existing_column_breakpoints_table_and_continue_target", async ({
    ctPage,
  }) => {
    await readyOnEntry(ctPage);
    const layout = new LayoutPage(ctPage);
    await layout.runToEntryButton().click();
    await expect(ctPage.locator(".location-path")).not.toHaveText(":0#0", {
      timeout: 30_000,
    });

    const editors = await layout.editorTabs(true);
    const editor = editors.find((e) => e.fileName === "program.js");
    expect(editor, "program.js editor tab should be open").toBeDefined();
    if (!editor) return;

    // ─── Step 1: programmatic M1 breakpoint at `var a` (column 1) ──
    //
    // Using `addColumnBreakpoint` directly pins the column to the
    // exact value we want without going through Monaco's pixel
    // resolver — the column-resolution drift only matters at the
    // Alt+click surface.
    await addColumnBreakpoint(editor, 1, fixture.firstStatementColumn);
    await expect
      .poll(async () => (await readBreakpoint(editor, 1))?.column ?? -1)
      .toBe(fixture.firstStatementColumn);

    // ─── Step 2: M6 Alt+click at `var b` on the SAME line ──────────
    //
    // The M1 contract says only ONE breakpoint per `(path, line)`
    // slot.  The Alt+click MUST overwrite the previous column
    // (not append a second breakpoint).  A regression that
    // appended would surface as the first column "winning" below.
    await altClickAtColumn(editor, 1, fixture.laterStatementColumn);

    await expect
      .poll(async () => (await readBreakpoint(editor, 1))?.column ?? -1)
      .toBe(fixture.laterStatementColumn);

    // ─── Step 3: Continue must halt at the REPLACED column ─────────
    //
    // End-to-end: the column replacement was plumbed all the way
    // through DAP `setBreakpoints` to the replay-server column
    // matcher.  A regression where only the frontend state was
    // updated (but the DAP message kept the old column) would
    // surface here as the cursor landing at
    // `fixture.firstStatementColumn`.
    await layout.continueButton().click();
    await expect.poll(async () => await getCurrentLine(editor)).toBe(1);
    await expect
      .poll(async () => await getCurrentColumn(editor))
      .toBe(fixture.laterStatementColumn);
  });
});
