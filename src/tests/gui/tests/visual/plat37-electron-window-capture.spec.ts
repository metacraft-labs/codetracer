/**
 * plat37-electron-window-capture.spec.ts — **the Electron half of PLAT-37's
 * macOS window-capture lane**, and the reference set GPUI parity is measured
 * against.
 *
 * Driven by `ci/test/plat37-macos-electron-capture.sh`, which is the Electron
 * twin of `ci/test/plat37-macos-window-capture.sh`. Run it through that lane,
 * not directly: the lane owns the three controls, the shared capture/grade
 * binaries and the manifest, and this file writes only per-scenario records.
 *
 * ===========================================================================
 * WHY THE WINDOW AND NOT `page.screenshot()` — AND WHAT THAT COSTS
 * ===========================================================================
 *
 * Both are taken, every run, from the SAME settled state, because the choice
 * was made by measurement rather than by argument and the measurement is kept
 * live. `<view>.png` is the window, through
 * `CGWindowListCopyWindowInfo` + `SCContentFilter(desktopIndependentWindow:)`
 * — byte-for-byte the path `plat37-macos-window-capture.sh` uses on the GPUI
 * window. `<view>.page.png` is Chromium's own raster of the web contents,
 * through the CDP screenshot the existing `visual-alignment-capture.spec.ts`
 * uses. `<view>.route.json` records both, so the parity step can see what
 * the two routes disagree about instead of inheriting an assumption.
 *
 * What the window route BUYS: one compositor, one display, one scale factor,
 * one font stack and one capture path shared with the GPUI arm, so a
 * difference between the two front-ends is a difference between the two
 * front-ends. The GPUI frame is a window and nothing can make
 * `page.screenshot()` into one.
 *
 * What it COSTS, stated rather than discovered later:
 *
 *   * **Title-bar chrome is in the frame.** The GPUI lane's `TitleBarPoints`
 *     (29) is subtracted when deciding `viewportHonoured`, but the PIXELS are
 *     still there in both arms' PNGs. A parity differ must either crop both
 *     by the same 29 points or accept that the top strip compares two
 *     different title bars.
 *   * **No `toHaveScreenshot` machinery.** No masking, no retry-until-stable,
 *     no per-pixel tolerance. The replacement is `codetracer-image-diff`'s
 *     FLIP, which is the perceptual differ this tree already builds on
 *     darwin, plus `captureSettled` below for the stability `toHaveScreenshot`
 *     would have retried into.
 *   * **Nothing else can be hidden.** A window capture shows whatever the
 *     compositor put there. The lane keeps the window in the foreground and
 *     records the attested window id, which is what makes "an overlapping
 *     window got in" a visible failure rather than a silent one.
 *
 * ===========================================================================
 * THE dpr ASSERTION THIS LANE DOES NOT INHERIT, AND WHY
 * ===========================================================================
 *
 * `visual-alignment-capture.spec.ts`'s `applyViewport` ends with
 * `expect(dpr).toBe(1)` and the remedy *"Run this lane under 'Xvfb -dpi 96'"*.
 * That is correct for the Linux lane it was written for and it is
 * **unsatisfiable on this host**: this display is 1728x1117 POINTS at
 * `pointPixelScale` 2.000, so `window.devicePixelRatio` is 2 and no flag
 * brings it to 1.
 *
 * Dropping the number is not dropping the assertion. What that line was
 * protecting is the relation *captured pixels == viewport x dpr* — the
 * failure it caught was a PNG 1.046875x the CSS viewport in each axis while
 * the record claimed the viewport. So this lane MEASURES dpr, records it, and
 * asserts the relation against the measured value. The identity case (dpr 1)
 * is unchanged; a host that drifts to 1.046875 still fails, now by the
 * relation rather than by the constant.
 *
 * ===========================================================================
 * SAME SCENARIOS, SAME POSTCONDITIONS
 * ===========================================================================
 *
 * The scenario set is READ from `src/tests/visual/scenarios.json` with the
 * same two-sided cardinality assertions both existing readers use. The
 * operations go through the product's own debug-toolbar buttons and **every
 * one asserts that the program moved**, by `rrTicks`, with a step asserted to
 * move EXACTLY ONE tick. That technique, and the five measurements behind it,
 * belong to `visual-alignment-capture.spec.ts`; its helpers are file-local
 * there, so the postconditions are restated here rather than imported. The
 * SCENARIO DEFINITION is not restated — it is read — which is the copy
 * Verification-Harness-Traps §30 is about.
 *
 * `gpuiProbes` has no Electron arm by `scenarios.json`'s own statement
 * (*"A probe is NOT part of the cross-renderer comparison: it has no Electron
 * arm, so nothing here claims one"*), so this lane drives the SIX and refuses
 * a seventh.
 */

import * as fs from "fs";
import * as path from "path";
import * as childProcess from "child_process";

import { test, expect } from "../../lib/fixtures";
import { LayoutPage } from "../../page-objects/layout-page";
import {
  debugToolbarSelector,
  type DebugToolbarButton,
} from "../../page-objects/debug-toolbar-ids";

const repoRoot = path.resolve(__dirname, "..", "..", "..", "..", "..");
const visualRoot = path.join(repoRoot, "src", "tests", "visual");

/** Where the lane wants the artefacts. REQUIRED — this spec invents no path. */
const outDir = process.env.CODETRACER_PLAT37E_OUT ?? "";
/** The shared capture binary. REQUIRED — the lane builds it and names it. */
const captureBin = process.env.CODETRACER_PLAT37E_CAPTURE ?? "";
/**
 * The CGWindowList owner name of CodeTracer's Electron window.
 *
 * MEASURED on this host 2026-10-12 rather than guessed: with the product
 * launched from `src/build-debug-repro/bin/ct`, `listWindows` reported
 * `id=1657 pid=81956 layer=0 onScreen=true bounds=1728x1084@0,33
 * owner='Electron'`. It is `Electron` and not `ct` or `CodeTracer` because
 * `ct` **execv()s** into the Electron executable on POSIX
 * (`src/ct/launch/electron.nim`), so the process that owns the window is the
 * unbranded nix `electron-41.3.0` bundle. A product that later ships a
 * renamed bundle changes this string, which is why it is an env var with a
 * measured default rather than a literal buried in a call.
 */
const owner = process.env.CODETRACER_PLAT37E_OWNER ?? "Electron";

if (outDir.length === 0 || captureBin.length === 0) {
  throw new Error(
    "PLAT-37/Electron: CODETRACER_PLAT37E_OUT and CODETRACER_PLAT37E_CAPTURE " +
      "must both be set. Run this through ci/test/plat37-macos-electron-capture.sh, " +
      "which builds the capture binary and owns the controls and the manifest. " +
      "This FAILS rather than defaulting: a capture written to a path nobody " +
      "reads is the silent half of the Silent-Self-Pass audit.",
  );
}
if (!fs.existsSync(captureBin)) {
  throw new Error(
    `PLAT-37/Electron: the capture binary is not at ${captureBin}. The lane ` +
      `builds it from ci/test/plat37_macos_window_capture.nim.`,
  );
}

interface ScenarioOp {
  kind: string;
  times?: number;
  line?: number;
}
interface Scenario {
  id: string;
  view: string;
  recording: string;
  viewport: string;
  operations: ScenarioOp[];
  tier1Canary: boolean;
}
interface ScenarioFile {
  expectedScenarios: number;
  expectedViewports: number;
  expectedCanaries: number;
  expectedGpuiProbes: number;
  operationKinds: string[];
  viewports: Record<string, { width: number; height: number }>;
  scenarios: Scenario[];
  gpuiProbes: Scenario[];
}

const definition: ScenarioFile = JSON.parse(
  fs.readFileSync(path.join(visualRoot, "scenarios.json"), "utf8"),
) as ScenarioFile;

// THE PARSE IS ASSERTED AT MODULE SCOPE, both directions, as every other
// reader of this file asserts it. A Playwright file that generates zero
// `test` blocks exits 0 and reads exactly like a clean run.
if (definition.scenarios.length !== definition.expectedScenarios) {
  throw new Error(
    `scenarios.json declares expectedScenarios=${definition.expectedScenarios} ` +
      `and holds ${definition.scenarios.length}`,
  );
}
if (Object.keys(definition.viewports).length !== definition.expectedViewports) {
  throw new Error(
    `scenarios.json declares expectedViewports=${definition.expectedViewports} ` +
      `and holds ${Object.keys(definition.viewports).length}`,
  );
}
if ((definition.gpuiProbes ?? []).length !== definition.expectedGpuiProbes) {
  throw new Error(
    `scenarios.json declares expectedGpuiProbes=${definition.expectedGpuiProbes} ` +
      `and holds ${(definition.gpuiProbes ?? []).length}`,
  );
}
for (const s of definition.scenarios) {
  for (const op of s.operations) {
    if (!definition.operationKinds.includes(op.kind)) {
      throw new Error(
        `scenario '${s.id}' uses operation '${op.kind}', which is not in the ` +
          `closed vocabulary ${definition.operationKinds.join(", ")}`,
      );
    }
  }
}

function resolveRecording(name: string): string {
  const cache = path.join(repoRoot, "test-logs", "tui-fixtures");
  if (fs.existsSync(cache)) {
    const hit = fs
      .readdirSync(cache)
      .filter((e) => e.startsWith(`${name}-`))
      .sort();
    if (hit.length > 0) return path.join(cache, hit[hit.length - 1]);
  }
  throw new Error(
    `PLAT-37/Electron: the '${name}' recording is not in ` +
      `test-logs/tui-fixtures/. It is produced by the product's own ` +
      `'ct record'; run 'just test-tui' once. This FAILS rather than skipping.`,
  );
}

const recordingPath = resolveRecording(definition.scenarios[0].recording);
fs.mkdirSync(outDir, { recursive: true });

interface ProgramState {
  line: number;
  path: string;
  rrTicks: number;
  busy: boolean | null;
}

async function readProgramState(
  page: import("playwright").Page,
): Promise<ProgramState> {
  return page.evaluate(() => {
    const w = window as unknown as {
      data?: {
        status?: { stableBusy?: boolean };
        services?: {
          debugger?: {
            location?: { line?: number; path?: string; rrTicks?: number };
          };
        };
      };
    };
    const l = w.data?.services?.debugger?.location;
    return {
      line: l?.line ?? -1,
      path: l?.path ?? "",
      rrTicks: l?.rrTicks ?? -1,
      busy: w.data?.status?.stableBusy ?? null,
    };
  });
}

const fmtState = (s: ProgramState) =>
  `line ${s.line} @ ticks ${s.rrTicks}${s.busy === true ? " (busy)" : ""}`;

/**
 * ONE synthesized click on a debug-toolbar button. EXACTLY ONE.
 *
 * `LayoutPage.clickDebugButton`'s try-click-then-dispatch chain delivers the
 * pointer event and then dispatches a second one whenever Playwright's
 * post-click stability wait throws on a toolbar that re-rendered under the
 * cursor — two steps for one operation. Measured by
 * `visual-alignment-capture.spec.ts` on 2026-09-21: a run that recorded
 * `stepIn=34@4` then `stepIn=44@6`, with tick 5 never appearing. Going
 * straight to `dispatchEvent` is that file's remedy and it is this file's too.
 */
async function clickToolbar(
  page: import("playwright").Page,
  which: DebugToolbarButton,
): Promise<void> {
  const selector = debugToolbarSelector(which);
  const button = page.locator(selector);
  await expect(
    button,
    `the '${which}' toolbar button (${selector}) is not in the DOM`,
  ).toHaveCount(1, { timeout: 15_000 });
  await button.dispatchEvent("click");
}

/**
 * WAIT FOR THE EFFECT, AND FAIL BY NAME WHEN THERE IS NONE.
 *
 * `rrTicks` is the only field that moves on EVERY operation: the first step-in
 * on `calc` advances ticks 0 -> 1 and leaves `line` at 1, so "the stopped line
 * changed" is a postcondition that is false for a step that genuinely
 * happened. `stableBusy` is required too — `ui/debug.nim`'s `dapStep` gates a
 * new request on it, so it is the renderer's own "this move is finished".
 *
 * A step is EXACTLY ONE tick. `stepOut` and `continueForward` run as far as
 * the frame or the program does, so for those the claim is only "forward".
 */
async function waitForMove(
  page: import("playwright").Page,
  before: ProgramState,
  what: string,
  exactlyOneTick: boolean,
): Promise<ProgramState> {
  const BUDGET_MS = 60_000;
  const t0 = Date.now();
  let last = before;
  let moved = false;
  while (Date.now() - t0 < BUDGET_MS) {
    last = await readProgramState(page);
    if (last.rrTicks !== before.rrTicks && last.busy !== true) {
      moved = true;
      break;
    }
    await page.waitForTimeout(100);
  }
  if (!moved) {
    throw new Error(
      `PLAT-37/Electron: '${what}' was performed on the product's own toolbar ` +
        `and the program did not move within ${BUDGET_MS}ms. Before: ` +
        `${fmtState(before)}; still: ${fmtState(last)}. An operation that ` +
        `lands nowhere must fail here — a capture that counts clicks issued ` +
        `rather than moves made is how four of six scenarios reached a ` +
        `different program state on a re-run of the identical specification.`,
    );
  }
  if (exactlyOneTick && last.rrTicks !== before.rrTicks + 1) {
    throw new Error(
      `PLAT-37/Electron: '${what}' advanced the recording from tick ` +
        `${before.rrTicks} to tick ${last.rrTicks}. A step is exactly one ` +
        `tick; more than one means the operation was delivered twice.`,
    );
  }
  if (last.rrTicks < before.rrTicks) {
    throw new Error(
      `PLAT-37/Electron: '${what}' moved the recording BACKWARD, ` +
        `${before.rrTicks} -> ${last.rrTicks}.`,
    );
  }
  return last;
}

/** The editor's rendered geometry as one signature string. */
async function editorFrameSignature(
  page: import("playwright").Page,
): Promise<string> {
  return page.evaluate(() => {
    const root = document.querySelector<HTMLElement>(
      "div[id^='editorComponent']",
    );
    if (!root) return "no-editor-root";
    const m = (window as any).monaco;
    const eds =
      m && m.editor && m.editor.getEditors ? m.editor.getEditors() : [];
    if (!eds || eds.length === 0) return "no-editors";
    const e = eds[0];
    const lines = Array.from(
      root.querySelectorAll<HTMLElement>(
        ".monaco-editor .view-lines .view-line",
      ),
    ).map((l) => l.offsetTop);
    const zones = Array.from(
      root.querySelectorAll<HTMLElement>(".monaco-editor .view-zones > *"),
    )
      .map((z) => `${z.style.top || "?"}/${z.style.height || "?"}`)
      .join(",");
    return [
      `sT=${e.getScrollTop()}`,
      `cH=${e.getContentHeight ? e.getContentHeight() : -1}`,
      `lH=${e.getLayoutInfo().height}`,
      `rows=${lines.length}`,
      `top=${lines.length ? Math.min(...lines) : -1}`,
      `zones=[${zones}]`,
    ].join(";");
  });
}

/** Bounded and soft: a frame that will not settle is a finding, not a stop. */
async function waitForEditorFrameSettled(
  page: import("playwright").Page,
): Promise<boolean> {
  const DEADLINE_MS = 10_000;
  const INTERVAL_MS = 120;
  const started = Date.now();
  let previous = await editorFrameSignature(page);
  while (Date.now() - started < DEADLINE_MS) {
    await page.waitForTimeout(INTERVAL_MS);
    const current = await editorFrameSignature(page);
    if (current === previous) return true;
    previous = current;
  }
  return false;
}

async function drive(
  layout: LayoutPage,
  ops: ScenarioOp[],
): Promise<{
  moves: number;
  trajectory: string[];
  final: ProgramState;
  settled: boolean;
}> {
  let moves = 0;
  let settled = true;
  const trajectory: string[] = [];
  // THE STARTING POINT IS ASSERTED. A session that has not finished opening
  // reports `rrTicks: -1`, and driving from there makes the first operation's
  // postcondition true by arithmetic on a sentinel.
  let state = await readProgramState(layout.page);
  expect(
    state.rrTicks,
    "the session had no position before the first operation; the capture " +
      "would then be driving a window that has not opened",
  ).toBeGreaterThanOrEqual(0);
  trajectory.push(`entry=${state.line}@${state.rrTicks}`);

  for (const op of ops) {
    const times = op.times ?? 1;
    for (let i = 0; i < times; i++) {
      const before = state;
      const what = `${op.kind} #${i + 1}/${times}`;
      switch (op.kind) {
        case "stepIn":
          await clickToolbar(layout.page, "stepIn");
          state = await waitForMove(layout.page, before, what, true);
          moves++;
          break;
        case "next":
          await clickToolbar(layout.page, "next");
          state = await waitForMove(layout.page, before, what, true);
          moves++;
          break;
        case "stepOut":
          await clickToolbar(layout.page, "stepOut");
          state = await waitForMove(layout.page, before, what, false);
          moves++;
          break;
        case "continueForward":
          await clickToolbar(layout.page, "continue");
          state = await waitForMove(layout.page, before, what, false);
          moves++;
          break;
        case "setBreakpoint": {
          // Relative to the FIRST DRAWN ROW, resolved against the recording's
          // own source by clicking the gutter the product drew — never a
          // literal line number. ASSERTED by the mark appearing, because a
          // scenario that claims a mark and gets none answers
          // `<stopped line>=execution` on every scenario, which is a
          // perfectly equal comparison about nothing.
          const gutters = layout.page.locator(
            "div[id^='editorComponent'] .margin-view-overlays .gutter",
          );
          const lines = await gutters.evaluateAll((els) =>
            els
              .map((e) => parseInt((e as HTMLElement).dataset.line || "-1", 10))
              .filter((n) => n > 0)
              .sort((a, b) => a - b),
          );
          expect(lines.length, "the editor drew no gutter rows").toBeGreaterThan(
            0,
          );
          const target = lines[Math.min(op.line ?? 1, lines.length - 1)];
          const cell = layout.page.locator(
            `div[id^='editorComponent'] .margin-view-overlays ` +
              `.gutter[data-line='${target}']`,
          );
          await cell.dispatchEvent("click");
          await expect(
            layout.page.locator(
              `div[id^='editorComponent'] .margin-view-overlays ` +
                `.gutter[data-line='${target}'] .gutter-breakpoint-enabled`,
            ),
          ).toHaveCount(1, { timeout: 15_000 });
          // ITS NON-EFFECT IS ALSO ASSERTED: setting a mark is not a step.
          state = await readProgramState(layout.page);
          expect(
            state.rrTicks,
            `${what} moved the program from ${fmtState(before)} to ` +
              `${fmtState(state)}; setting a mark is not a step`,
          ).toBe(before.rrTicks);
          trajectory.push(`setBreakpoint@${target}`);
          moves++;
          break;
        }
        default:
          throw new Error(`unknown operation kind '${op.kind}'`);
      }
      if (op.kind !== "setBreakpoint") {
        trajectory.push(`${op.kind}=${state.line}@${state.rrTicks}`);
      }
      if (!(await waitForEditorFrameSettled(layout.page))) settled = false;
    }
  }
  return { moves, trajectory, final: state, settled };
}

/**
 * THE VIEWPORT, APPLIED FOR REAL AND THEN MEASURED — never asserted equal to
 * the request.
 *
 * `scenarios.json`'s `wide` is 1920x1080 POINTS and this display is 1728x1117.
 * **A window CAN be given it, and Electron's is** — measured 2026-10-12:
 * `CGWindowListCopyWindowInfo` attests 1920x1080 at origin (0,33), 192 points
 * off the right edge, and the capture reads the window's OWN surface so the
 * off-screen strip comes back as rendered product. The GPUI window asked for
 * the same thing is clamped to 1728x1084 and records
 * `viewportHonoured: false` with the deviation in CONTENT points (the frame's
 * height minus `TitleBarPoints` = 29); neither lane relabels.
 *
 * The asymmetry is the two front-ends, not the host: gpui opens a
 * `NSTitled | NSClosable | NSResizable | NSMiniaturizable` window and never
 * overrides `constrainFrameRect:toScreen:`, so AppKit's default visible-frame
 * constraint applies to it. This returns the same three numbers from the
 * Electron side so the two records are comparable; the lane's capture binary
 * computes the authoritative `viewportHonoured` from the window the system
 * actually made.
 */
async function applyViewport(
  page: import("playwright").Page,
  app: import("playwright").ElectronApplication,
  size: { width: number; height: number },
): Promise<{
  requested: { width: number; height: number };
  cssViewport: { width: number; height: number };
  contentSize: { width: number; height: number };
  devicePixelRatio: number;
  honouredInCss: boolean;
}> {
  // Resized through the window that OWNS THE PAGE, not `getAllWindows()[0]`:
  // they are the same window here and relying on that is how a second window
  // would silently make this a no-op.
  const win = await app.browserWindow(page);
  await win.evaluate((w, s) => {
    const bw = w as unknown as {
      setResizable: (b: boolean) => void;
      unmaximize: () => void;
      setFullScreen: (b: boolean) => void;
      setContentSize: (a: number, b: number) => void;
    };
    bw.setResizable(true);
    bw.setFullScreen(false);
    bw.unmaximize();
    bw.setContentSize(s.width, s.height);
  }, size);

  // Let the resize land. Polled rather than slept: the CSS viewport is what
  // the capture is of, and it follows the window asynchronously.
  const deadline = Date.now() + 20_000;
  let css = { width: -1, height: -1 };
  while (Date.now() < deadline) {
    css = await page.evaluate(() => ({
      width: window.innerWidth,
      height: window.innerHeight,
    }));
    if (css.width === size.width && css.height === size.height) break;
    await page.waitForTimeout(200);
  }

  const contentSize = (await win.evaluate((w) => {
    const bw = w as unknown as { getContentSize: () => number[] };
    const [cw, ch] = bw.getContentSize();
    return { width: cw, height: ch };
  })) as { width: number; height: number };
  const dpr = await page.evaluate(() => window.devicePixelRatio);

  // **THE RELATION, NOT THE CONSTANT.** See this file's header: the Linux
  // lane asserts `dpr === 1`, which is unsatisfiable on a 2x display. What
  // that assertion protected is checked instead by `captureBoth` below, which
  // compares the page PNG's own IHDR against `cssViewport x dpr`. A dpr that
  // is neither an exact integer nor a half step is the 1.046875 failure mode
  // and still fails, here, by name.
  expect(
    Math.abs(dpr * 2 - Math.round(dpr * 2)),
    `device pixel ratio is ${dpr}, which is not a half-integer. The lane that ` +
      `wrote this check caught an X server reporting 100.5 dpi, from which ` +
      `Chromium derived dpr 1.046875 and every captured PNG was 1.046875x the ` +
      `CSS viewport it was recorded as.`,
  ).toBeLessThan(1e-9);
  expect(dpr, "device pixel ratio must be positive").toBeGreaterThan(0);

  return {
    requested: size,
    cssViewport: css,
    contentSize,
    devicePixelRatio: dpr,
    honouredInCss: css.width === size.width && css.height === size.height,
  };
}

/**
 * HOLD THE WINDOW STILL, HARD, BEFORE ANY PIXEL IS READ.
 *
 * `toHaveScreenshot`'s retry-until-two-match is the machinery the window route
 * does not inherit, so the stability it provides is produced here instead:
 * two consecutive byte-identical CDP screenshots of the whole page. The
 * attempt count is returned and recorded — a capture that needed many
 * attempts is a finding about the surface, not a detail.
 */
async function captureSettled(
  page: import("playwright").Page,
  target: string,
): Promise<{ attempts: number; stable: boolean }> {
  const MAX = 8;
  // Moving the pointer away and blurring is what a screenshot of a settled
  // product looks like: no hover state, no focus ring chasing the cursor.
  await page.mouse.move(2, 2);
  await page.evaluate(() => (document.activeElement as HTMLElement)?.blur?.());
  let previous: Buffer | null = null;
  for (let attempt = 1; attempt <= MAX; attempt++) {
    const shot = await page.screenshot();
    if (previous !== null && previous.equals(shot)) {
      fs.writeFileSync(target, shot);
      return { attempts: attempt, stable: true };
    }
    previous = shot;
    await page.waitForTimeout(250);
  }
  if (previous !== null) fs.writeFileSync(target, previous);
  return { attempts: MAX, stable: false };
}

/** The PNG's own IHDR — the artefact's word, not the harness's. */
function pngSize(file: string): { width: number; height: number } {
  const head = fs.readFileSync(file).subarray(0, 33);
  if (head.subarray(0, 8).toString("binary") !== "\x89PNG\r\n\x1a\n") {
    throw new Error(`${file} is not a PNG`);
  }
  return { width: head.readUInt32BE(16), height: head.readUInt32BE(20) };
}

for (const scenario of definition.scenarios) {
  test.describe(`plat37-electron ${scenario.id}`, () => {
    test.use({ sourcePath: recordingPath, launchMode: "trace-folder" });
    test.setTimeout(600_000);

    test(`capture ${scenario.view}`, async ({ ctPage, electronApp }) => {
      expect(
        electronApp,
        "the Electron application fixture is null, so the window cannot be " +
          "resized and this lane would capture whatever size the product " +
          "happened to open at",
      ).not.toBeNull();
      const app = electronApp as import("playwright").ElectronApplication;
      const layout = new LayoutPage(ctPage);

      const vp = definition.viewports[scenario.viewport];
      const viewportRecord = await applyViewport(ctPage, app, vp);

      // The editor must finish re-laying-out BEFORE the first operation:
      // measured on the Linux lane, two of four probed runs drove the
      // debugger with a 1298px-tall editor inside a 900px-tall window.
      await waitForEditorFrameSettled(ctPage);

      const driven = await drive(layout, scenario.operations);

      const pagePng = path.join(outDir, `${scenario.view}.page.png`);
      const settle = await captureSettled(ctPage, pagePng);
      const pagePngSize = pngSize(pagePng);

      // ----------------------------------------------------------------
      // THE WINDOW CAPTURE — the same binary, the same probe and the same
      // attestation the GPUI arm goes through, aimed at this owner.
      // ----------------------------------------------------------------
      const windowPng = path.join(outDir, `${scenario.view}.png`);
      const windowRec = path.join(outDir, `${scenario.view}.capture.json`);
      const args = [
        "capture",
        `--owner=${owner}`,
        `--out=${windowPng}`,
        `--record=${windowRec}`,
        `--view=${scenario.view}`,
        `--scenario=${scenario.id}`,
        `--requested-width=${vp.width}`,
        `--requested-height=${vp.height}`,
        // **ZERO, AND THE DRIVER EARNS IT BELOW.**
        //
        // The capture binary subtracts `--title-bar-points` from the attested
        // FRAME height before deciding `viewportHonoured`, because a standard
        // macOS titled window's frame is 29 points taller than the content
        // area the request was about. CodeTracer's Electron window is NOT a
        // standard titled window: measured 2026-10-12 at `wide`, the frame
        // `CGWindowListCopyWindowInfo` reports is 1920x1080 and the page's
        // own `window.innerHeight` is 1080 — frame and content are the same
        // rectangle. Subtracting 29 reported `viewportHonoured: false` with a
        // `-29` deviation for a viewport that was honoured EXACTLY.
        //
        // So 0 is passed, and `frameEqualsContent` below asserts the premise
        // against the window the system actually made. A product that grows a
        // real title bar fails there rather than silently reporting its
        // viewport 29 points short.
        "--title-bar-points=0",
        "--timeout-ms=30000",
        "--wait-ms=15000",
      ];
      const cap = childProcess.spawnSync(captureBin, args, {
        encoding: "utf-8",
        timeout: 240_000,
      });

      // THE RECORD IS THE VERDICT, not the exit code. The driver writes one
      // on every path it reaches, including a refusal.
      const captureRecord = fs.existsSync(windowRec)
        ? JSON.parse(fs.readFileSync(windowRec, "utf8"))
        : null;

      const route = {
        schemaVersion: 1,
        lane: "plat37-macos-electron-capture",
        milestone: "PLAT-37",
        scenario: scenario.id,
        view: scenario.view,
        viewportName: scenario.viewport,
        renderer: "electron",
        recording: recordingPath,
        drivenOperations: scenario.operations,
        trajectory: driven.trajectory,
        movesPerformed: driven.moves,
        editorSettledBetweenOperations: driven.settled,
        finalState: driven.final,
        viewport: viewportRecord,
        pageRoute: {
          how: "page.screenshot() over CDP — Chromium's own raster of the web contents, no window chrome, no compositor",
          path: pagePng,
          ihdr: pagePngSize,
          settleAttempts: settle.attempts,
          byteStable: settle.stable,
          expectedIhdr: {
            width: Math.round(
              viewportRecord.cssViewport.width * viewportRecord.devicePixelRatio,
            ),
            height: Math.round(
              viewportRecord.cssViewport.height *
                viewportRecord.devicePixelRatio,
            ),
          },
        },
        windowRoute: {
          how: "CGWindowListCopyWindowInfo attestation then SCScreenshotManager over SCContentFilter(desktopIndependentWindow:) — the same binary and the same probe the GPUI arm uses",
          owner,
          path: windowPng,
          exitCode: cap.status,
          stderr: (cap.stderr ?? "").trim().split("\n").slice(-6).join("\n"),
          record: captureRecord,
        },
      };
      fs.writeFileSync(
        path.join(outDir, `${scenario.view}.route.json`),
        `${JSON.stringify(route, null, 2)}\n`,
      );

      // ----------------------------------------------------------------
      // THE ASSERTIONS. Each one has a state a broken run reaches.
      // ----------------------------------------------------------------

      // 1. The page PNG is the CSS viewport times the measured dpr. This is
      //    the `dpr === 1` assertion's actual content, kept. A PNG 1.046875x
      //    its viewport fails here.
      expect(
        `${pagePngSize.width}x${pagePngSize.height}`,
        `the page screenshot's own IHDR disagrees with the CSS viewport ` +
          `(${viewportRecord.cssViewport.width}x` +
          `${viewportRecord.cssViewport.height}) times the measured device ` +
          `pixel ratio (${viewportRecord.devicePixelRatio})`,
      ).toBe(
        `${route.pageRoute.expectedIhdr.width}x${route.pageRoute.expectedIhdr.height}`,
      );

      // 2. The window capture produced a record and that record claims G1
      //    over a window that was attested FIRST and captured by id.
      expect(
        captureRecord,
        `the capture driver wrote no record at ${windowRec} (rc ${cap.status}). ` +
          `"the capture ran and the window was not there" must stay ` +
          `distinguishable from "the capture did not run".`,
      ).not.toBeNull();
      expect(captureRecord.outcome, captureRecord.refusal ?? "").toBe(
        "captured",
      );
      expect(captureRecord.satisfiesG1).toBe(true);
      expect(
        captureRecord.attestation.matched,
        "G1 is claimed and no window was attested",
      ).toBeGreaterThanOrEqual(1);
      expect(
        captureRecord.capture.sameWindowAsAttested,
        "ScreenCaptureKit captured a different window than the one " +
          "CGWindowListCopyWindowInfo attested",
      ).toBe(true);

      // 3. The window PNG's own IHDR equals the captured POINT extent times
      //    the captured scale — the artefact's word against the driver's.
      const windowIhdr = pngSize(windowPng);
      expect(`${windowIhdr.width}x${windowIhdr.height}`).toBe(
        `${captureRecord.capturedPixels.width}x${captureRecord.capturedPixels.height}`,
      );

      // 3a. **THE PREMISE BEHIND `--title-bar-points=0`.** The attested frame
      //     and the page's own content area are the same rectangle, so
      //     nothing is subtracted. A product that grows a real title bar
      //     fails here, by name, instead of reporting every viewport short by
      //     whatever that bar turns out to be. Width is included because a
      //     frame that gained a border would move it and not the height.
      const frameEqualsContent =
        `${captureRecord.windowFramePoints.width}x` +
        `${captureRecord.windowFramePoints.height}`;
      expect(
        frameEqualsContent,
        "the Electron window's attested FRAME is no longer its content " +
          "area, so `--title-bar-points=0` is now subtracting the wrong " +
          "number and every viewport below it is mis-graded. Measure the " +
          "new frame and pass it.",
      ).toBe(
        `${viewportRecord.contentSize.width}x${viewportRecord.contentSize.height}`,
      );

      // 4. **THE ASSERTION A BLANK WINDOW FAILS.** Everything above is true
      //    of a window that drew nothing: it is attested, it is captured, its
      //    IHDR matches. What distinguishes a rendering CodeTracer is that
      //    the product's own debugger reported a position and the editor drew
      //    rows — both read from the live DOM, both zero on a dead renderer.
      //    The frame's own glyph count is graded separately by the lane's
      //    `plat37_macos_window_grade`, which fails a flat frame; this is the
      //    renderer-side half of the same question.
      expect(
        driven.final.rrTicks,
        "the product reported no position at capture time, so the window " +
          "above is of a session that never opened",
      ).toBeGreaterThanOrEqual(0);
      const drawnRows = await ctPage
        .locator(
          "div[id^='editorComponent'] .monaco-editor .view-lines .view-line",
        )
        .count();
      expect(
        drawnRows,
        "the editor drew no rows, so the captured window holds no source " +
          "text whatever its pane grounds look like",
      ).toBeGreaterThan(0);
    });
  });
}
