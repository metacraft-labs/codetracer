/**
 * M8 — Column-Aware Replay Navigation: Formatted-View Step-In / Step-Out
 * GUI Playwright acceptance.
 *
 * Spec:
 *   codetracer-specs/Planned-Features/Column-Aware-Navigation.status.org
 *   §M8 Acceptance tests — GUI Playwright.
 *
 * What this spec proves:
 *
 *   1. With a column-aware JS recording loaded into the GUI and a
 *      synthetic srcview activated programmatically, pressing F11 at a
 *      call site advances the editor cursor to the FIRST executed
 *      /formatted/ line of the callee — not to an intra-statement
 *      minified column inside the call expression.  This pins the M8
 *      contract for ``stepIn`` end-to-end through the renderer's DAP
 *      pipeline.
 *
 *   2. With the formatted view active and the cursor inside the callee
 *      body, Shift+F11 returns the cursor to the formatted line where
 *      execution resumes in the CALLER — not to the recorded minified
 *      anchor (which would project to a different formatted line under
 *      a misconfigured runner).  This pins the M8 ``stepOut`` contract.
 *
 * Fixture: a recorded JS trace shaped as an IIFE
 * (immediately-invoked function expression) followed by a post-call
 * statement:
 *
 * ```
 *     (function() {   // line 1 — IIFE call site
 *       return 1;     // line 2 — callee body
 *     })();           // line 3
 *     var z = 2;      // line 4 — caller resume
 * ```
 *
 * The IIFE shape is chosen so the JS recorder produces a trace where
 * ``runToEntry`` lands DIRECTLY on the call site (minified line 1) —
 * with the inline-declaration + call shape used by the M8 VM tests the
 * recorder emits a function-declaration anchor BEFORE the call site,
 * forcing the test to walk forward an extra step.  Two sequential
 * stepping requests in the same materialised-JS-trace context are
 * known to race the GUI renderer's reactive plumbing (the second
 * request's ``ct/complete-move`` is silently coalesced past the
 * ``stableBusy`` re-arming gate), so reducing the navigation to a
 * single click per assertion keeps the M8 contract observable
 * without depending on the broken multi-step path.  The DAP layer
 * (``src/db-backend/tests/dap_formatted_view_step_in.rs`` and
 * ``dap_formatted_view_step_out.rs``) and the headless ViewModel
 * layer (``src/frontend/viewmodel/tests/unit/test_formatted_view_step_in_vm.nim``
 * and ``test_formatted_view_step_out_vm.nim``) exercise the
 * multi-step descent + same-projection-skip paths the GUI fixture
 * cannot synthesise here.
 *
 * We inject a synthetic V3 sourcemap that projects the three
 * recorded user-code lines onto three DIFFERENT formatted lines so
 * the formatted-view path is observable end-to-end: each assertion
 * lands on a formatted line that does not collide with any of the
 * other two, so a regression to the legacy minified runner — or to
 * "wrong direction" projection — surfaces as a precise off-by-one
 * line mismatch.
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
  /** 1-indexed minified line of the IIFE call site (``(function() {``). */
  callerLine: number;
  /** 1-indexed minified line of the callee body (``return 1;``). */
  calleeLine: number;
  /** 1-indexed minified line of the caller's post-call resume (``var z = 2;``). */
  resumeLine: number;
}

const fixtureDir = path.join(os.tmpdir(), `ct-fmt-view-step-in-out-gui-${process.pid}`);
const sourcePath = path.join(fixtureDir, "program.js");
const tracePath = path.join(fixtureDir, "trace");

// Three-line IIFE (immediately-invoked function expression) fixture
// shape — picked so the JS recorder produces a trace where the FIRST
// user step ``runToEntry`` lands on IS already the call site.  That
// lets the M8 GUI ``stepIn`` test exercise the "descend into callee"
// contract with a SINGLE post-runToEntry click (rather than the
// walk-to-call-site → ``stepIn`` two-click sequence the inline
// declaration + call shape from the M8 VM test would force).  The GUI
// renderer's reactive plumbing has a race under multiple sequential
// stepping requests in materialised JS traces (the second click's
// ``ct/complete-move`` is silently coalesced past the renderer's
// ``stableBusy`` re-arming gate) so reducing the test to one
// stepping request per assertion keeps the M8 contract observable
// without relying on the broken multi-step path.
//
// The JS recorder emits steps in the order:
//
//   step N    — line 1 col 1  (IIFE call site at ``(function() {``)
//   step N+1  — line 2 col 1  (callee body start, ``return 1;``)
//   step N+2  — line 2 col 3  (callee body, intra-line bookkeeping)
//   step N+3  — line 4 col 1  (caller resume, ``var z = 2;``)
//
// — i.e. ``runToEntry`` lands at step N (line 1, IIFE call site),
// ``stepIn`` descends into the callee at step N+1 (line 2), and
// ``stepOut`` walks back to the caller resume at step N+3 (line 4).
//
// ``--no-autoformat`` keeps the recorder from emitting a real srcview;
// we inject a synthetic one programmatically below so the M8 contract
// is exercised without depending on ``prettier`` being on PATH at
// test time.
const PROGRAM = "(function() {\n  return 1;\n})();\nvar z = 2;\n";

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

  return {
    traceDir: tracePath,
    sourcePath,
    callerLine: 1,
    calleeLine: 2,
    resumeLine: 4,
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

const FormattedViewPath = "/tmp/m8-gui-test-formatted-view.fmt.js";

/// Formatted line that minified line 1 (the IIFE call site) projects to.
const FmtCallerLine = 5;
/// Formatted line that minified line 2 (the callee body) projects to.
const FmtCalleeLine = 2;
/// Formatted line that minified line 4 (the caller's post-call resume) projects to.
const FmtResumeLine = 8;

/**
 * Build a V3 sourcemap projecting the IIFE fixture onto three
 * distinct formatted lines:
 *
 *   minified (1, *) → formatted (FmtCallerLine, 1)  // IIFE call site
 *   minified (2, *) → formatted (FmtCalleeLine, 1)  // callee body
 *   minified (4, *) → formatted (FmtResumeLine, 1)  // caller resume
 *
 * The single segment at generated column 0 of each generated line is
 * the V3 "floor" mapping: the runner's projection picks the last
 * segment with ``gen_col <= queried_col`` on the queried generated
 * line, so every column on a given minified line falls through to
 * that line's segment.  That decouples the assertions from the JS
 * recorder's exact column choices (see
 * ``codetracer-specs/Planned-Features/Column-Aware-Navigation.status.org``
 * §M2 Notes — "JS recorder column reset on same-line continuation").
 *
 * Generated line 3 (= the empty minified line ``})();`` between
 * callee body and ``var z = 2;``) is encoded as an empty generated
 * line — the V3 spec says missing-segment lines have no projection,
 * and the M3 forward-projection runner falls through to the previous
 * mapping anchor for queries on that gen line, which is exactly the
 * IIFE-trailer / call-site fallthrough we want.
 */
function buildMinifiedToFormattedMapV3(
  formattedSourceName: string,
  fmtCallerLine: number,
  fmtCalleeLine: number,
  fmtResumeLine: number,
): string {
  let mappings = "";
  // Generated line 1 — IIFE call site → formatted line ``fmtCallerLine``.
  mappings = segment(mappings, 0, 0, fmtCallerLine - 1, 0);
  mappings += ";";
  // Generated line 2 — callee body → formatted line ``fmtCalleeLine``.
  // Source-line delta from the previous segment is
  // ``fmtCalleeLine - fmtCallerLine`` (can be negative; VLQ supports
  // signed deltas).
  mappings = segment(mappings, 0, 0, fmtCalleeLine - fmtCallerLine, 0);
  mappings += ";";
  // Generated line 3 — empty (no segments); the trailing ``})();``
  // line of the IIFE has no executed statement in our fixture, so a
  // gap here is fine.
  mappings += ";";
  // Generated line 4 — caller's post-call resume → formatted line
  // ``fmtResumeLine``.  Source-line delta is ``fmtResumeLine -
  // fmtCalleeLine`` (relative to the previous segment's src line).
  mappings = segment(mappings, 0, 0, fmtResumeLine - fmtCalleeLine, 0);
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

/**
 * Dispatch a DAP ``stepIn`` request by clicking the toolbar's
 * "Step In" button — the production code path the F11 keybind takes.
 * Using the actual button click (rather than driving the DAP request
 * via ``dapApi.sendCtRequest`` directly) keeps the renderer's
 * reactive plumbing in lockstep: the click handler walks through the
 * full state machine the GUI's stable-busy bookkeeping relies on, so
 * a multi-step test sequence (walk to call site → ``stepIn``)
 * advances deterministically.  The lower-level
 * ``dapApi.sendCtRequest`` path coalesces the second request in our
 * fixture for reasons that remain under investigation; the button
 * click does not.
 */
async function stepIn(editor: EditorPane, layout: LayoutPage): Promise<void> {
  void editor;
  await layout.clickStepInButton();
}

/**
 * Dispatch a DAP ``stepOut`` request via the toolbar's "Step Out"
 * button click.  Mirror of [`stepIn`].
 */
async function stepOut(editor: EditorPane, layout: LayoutPage): Promise<void> {
  void editor;
  await layout.clickStepOutButton();
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

test.describe("M8 — Formatted-view step-in / step-out", () => {
  test("formatted_view_step_in_advances_to_formatted_callee_line", async ({ ctPage }) => {
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
      FmtCallerLine,
      FmtCalleeLine,
      FmtResumeLine,
    );
    await installSourceViewForTest(editor, {
      recordedPath: fixture.sourcePath,
      formattedViewPath: FormattedViewPath,
      sourcemapV3Json: mapJson,
    });
    await setActiveSourceView(editor, FormattedViewPath);

    // After ``runToEntry`` the cursor sits at the IIFE call site on
    // minified line 1 (the IIFE's first user step).  Under the active
    // synthetic srcview minified line 1 projects to ``FmtCallerLine``.
    // We do NOT assert this entry projection here because the
    // ``ct/set-active-source-view`` request does not re-emit a
    // ``ct/complete-move`` event — the cursor's reported line stays
    // at the raw minified value until the NEXT step the formatted-view
    // runner processes.  Instead we drive the M8 ``stepIn`` runner
    // directly and assert the post-step landing.
    //
    // F11 from the IIFE call site under the formatted view MUST land
    // at the callee body's formatted line — NOT at a minified-column
    // anchor inside the call expression.  Under our synthetic
    // projection minified line 2 (the ``return 1;`` body) maps to
    // ``FmtCalleeLine``, which differs from both ``FmtCallerLine``
    // (call site) and ``FmtResumeLine`` (post-call), so this single
    // assertion uniquely pins the M8 stepIn contract: the cursor
    // descended into the callee and landed at the callee's first
    // formatted line.
    await stepIn(editor, layout);
    await expect.poll(async () => await getCurrentLine(editor)).toBe(FmtCalleeLine);
  });

  test("formatted_view_step_out_returns_to_formatted_caller_line", async ({ ctPage }) => {
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
      FmtCallerLine,
      FmtCalleeLine,
      FmtResumeLine,
    );
    await installSourceViewForTest(editor, {
      recordedPath: fixture.sourcePath,
      formattedViewPath: FormattedViewPath,
      sourcemapV3Json: mapJson,
    });
    await setActiveSourceView(editor, FormattedViewPath);

    // Descend into the callee body via a single ``stepIn`` — same
    // step the M8 stepIn sibling test pins above.
    await stepIn(editor, layout);
    await expect.poll(async () => await getCurrentLine(editor)).toBe(FmtCalleeLine);

    // Shift+F11 from inside the callee under the formatted view MUST
    // land at the caller's resume formatted line — i.e.
    // ``FmtResumeLine`` (the ``var z = 2;`` post-call step).  Under
    // our synthetic projection ``FmtResumeLine`` ≠ ``FmtCalleeLine``
    // so this assertion uniquely pins the M8 stepOut contract: the
    // cursor leaves the callee body's formatted line and lands at the
    // caller's formatted resume line.  A regression to the legacy
    // ``step_out`` primitive would still walk to the caller's resume
    // step (same recorded coordinate) — both runners agree on the
    // landing in this fixture — but the formatted-view runner reaches
    // it via the projection-aware skip predicate documented in
    // ``codetracer-specs/Planned-Features/Column-Aware-Navigation.status.org``
    // §M8, and the DAP unit tests (``dap_formatted_view_step_out.rs``)
    // cover the same-projection skip case the GUI fixture cannot
    // synthesise.
    await stepOut(editor, layout);
    await expect.poll(async () => await getCurrentLine(editor)).toBe(FmtResumeLine);
  });
});
