/**
 * Frontend startup budget — renderer script parse-and-execute.
 *
 * WHY THIS EXISTS
 * ---------------
 * `codetracer-specs/Testing/Performance-Targets.md` § Startup & Initialization
 * documents a **total cold setup** target of 3s and a hard limit of 10s, and
 * opens by stating that an operation significantly slower than its target "is
 * a bug".  Measurement (Value-Origin-Tracking M46, 2026-08-06) found that a
 * single phase of that budget — parsing and executing the renderer's two
 * synchronous scripts — was consuming 6.6s on its own, 55% of the launch,
 * while *fetching* them cost 28ms.  Nothing enforced that, because every
 * existing startup assertion is a wall-clock wait on a UI element and those
 * were all set wide enough to absorb it.
 *
 * WHAT IT MEASURES
 * ----------------
 * `ct:ui-done - ct:scripts-start`: the interval spanned by the renderer's
 * synchronous `<script>` tags, marked in `src/frontend/index.html`, split by
 * `ct:bundle-done` into the webpack bundle and the Nim-generated `ui.js`.
 *
 * That phase, and not wall clock to a visible element, because it:
 *
 *   - is **CPU-bound, not scheduler-bound**.  It contains no process round
 *     trips, no IPC, no DAP, no fetch of consequence (`responseEnd` for the
 *     document is ~28ms; the scripts come off the local filesystem).  It is
 *     V8 compiling and running a fixed amount of code.
 *   - is **owned entirely by the product**.  It moves when the bundle changes
 *     and does not move when the harness, the recorder or the backend change,
 *     so a failure here names its own cause.
 *   - is **the thing M46 measured**, so the numbers stay comparable.
 *
 * WHY IT IS NORMALIZED (and why not plain milliseconds)
 * -----------------------------------------------------
 * This suite runs on a shared developer host that carries its own CI and has
 * been observed at 1-minute load average 185 on 32 cores.  Being CPU-bound is
 * not enough on such a host: the *same* build measured here ranged from a
 * 2.70s median at load 9 to a 5.50s median at load 50.  A plain-millisecond
 * budget therefore cannot do both jobs at once — anything loose enough never
 * to fail at load 50 (~8s) is also loose enough to miss a 40% regression, and
 * anything tight enough to catch that regression fails whenever the developer
 * builds something.
 *
 * So each launch also runs a **calibration workload in the same renderer, on
 * the same thread, microseconds after the marks are read**: it compiles a
 * fixed, generated source with `new Function`.  That is deliberately the *same
 * kind of work* the measured phase is dominated by (see WHERE THE TIME GOES
 * below) — V8 parse and compile — so contention and hardware speed divide out
 * of the ratio almost exactly.  The asserted quantity is
 *
 *     normalizedScriptsMs = scriptsMs × (CALIBRATION_REFERENCE_MS / calibMs)
 *
 * i.e. "what this phase would have cost on the reference host with the machine
 * to itself".  It stays in milliseconds, so it is still directly comparable to
 * the documented targets.
 *
 * The raw milliseconds, the calibration and the load average are printed for
 * every launch, so a suspicious normalized figure can always be traced back to
 * what was actually measured.
 *
 * WHAT THE NORMALIZATION DOES **NOT** CORRECT FOR — measured, not assumed
 * ----------------------------------------------------------------------
 * It corrects for CPU *contention*.  It does not correct for core *count*, and
 * the two must not be confused.  The calibration is a single-threaded
 * `new Function` compile; the measured phase is not purely single-threaded
 * (Chromium parses and compiles off-thread, and the rest of Electron's start-up
 * runs beside it).  Pinning an otherwise identical run to 8 of this host's 32
 * cores with `taskset -c 0-7` moved:
 *
 *   normalized median   2669ms -> 3176ms   (+19%)
 *   calibration        209-231ms -> 216-235ms  (unchanged — it saw nothing)
 *
 * So the ceiling below is a **reference-class-host** ratchet, not a universal
 * constant.  On a materially smaller machine the normalized figure runs high
 * for reasons that have nothing to do with the bundle.  Two consequences:
 *
 *   - Do not read a failure on a small runner as a product regression without
 *     checking `nproc` and the raw/calibration figures this spec prints.
 *   - `CALIBRATION_REFERENCE_MS` and `SCRIPT_PHASE_CEILING_MS` were fixed
 *     together on one host; re-deriving one without the other is meaningless.
 *
 * Contention itself is corrected well in the median, but not in every single
 * launch, and the error goes both ways.  Under 48 synthetic spinners at load
 * 102-135 the normalized samples were 2446, 2741, 2763, 2838 and **4237**ms:
 * one launch in five landed above the ceiling on a known-good build, because
 * the calibration runs after the launch has settled and so under-reports the
 * contention the measured phase actually saw.  In a different run of the same
 * good build one launch's calibration instead caught a quiet window (150ms
 * against 212-237ms for its four siblings), which *inflated* that launch to
 * 3621ms.  Within-run spread on a known-good build has been seen at 1.48x.
 *
 * The median of `SAMPLES` absorbed all of that in every run taken so far — but
 * it is a real, measured flake path, which is why the structural assertion
 * below exists: it catches the specific regression this milestone fixed with
 * no launch, no statistics and no host dependence at all.
 *
 * WHERE THE TIME GOES (measured 2026-08-10)
 * -----------------------------------------
 * Of the bundle phase, only ~0.8s is module *execution* — instrumenting
 * webpack's module runtime showed 3562 of 3563 modules executing for 779ms of
 * self-time in total, with no hotspot (the largest single module is 30ms).
 * The rest is V8 compiling ~48MB of third-party source.  Several ways of
 * making that source smaller or later were measured, and rejected: the cost
 * is spread evenly across thousands of modules, so there is no hotspot to
 * split out or defer.
 *
 * FIXTURE
 * -------
 * A four-statement JavaScript program, recorded once when the spec loads and
 * then opened `SAMPLES` times with `launchMode: "trace-folder"`.  Recording is
 * deliberately kept out of the measured loop: the trace is produced once and
 * every launch afterwards opens the same bytes.  The program is trivial on
 * purpose — this budget is about the cost of the *frontend*, which is the same
 * whatever the trace holds.  Same fixture shape as
 * `tests/status-bar/status-bar-footer-contract.spec.ts`.
 *
 * No mocks: this drives the real Electron app against a real recorded trace.
 *
 * LANE
 * ----
 * Runs in the ordinary GUI lane — `just test-gui` / `just test-gui-prebuilt`
 * pick it up from `testDir: ./tests` like every other spec (there is a single
 * Playwright project, `chromium`).  Its only prerequisite is the
 * `codetracer-js-recorder` sibling, which `just build-siblings` (a `test-gui`
 * prerequisite) already builds for the `statement_step_*` and status-bar
 * specs.
 */

import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";
import * as childProcess from "node:child_process";

import {
  test,
  expect,
  readyOnEntryTest as readyOnEntry,
} from "../../lib/fixtures";

// ---------------------------------------------------------------------------
// Budget
// ---------------------------------------------------------------------------

/**
 * What `Performance-Targets.md` implies this phase may cost.
 *
 * Derived, not fitted.  The renderer's synchronous script phase is a strict
 * sub-phase of the document's **All components loaded** row, whose *target* is
 * 2s.  A single sub-phase that on its own costs more than the target for the
 * whole phase cannot be called within budget under any reading of the table,
 * so 2s is the loosest defensible target for it.
 *
 * **This target is not met today** (see `SCRIPT_PHASE_CEILING_MS`).  It is
 * kept here, and the shortfall printed on every run, so the gap stays visible
 * instead of being quietly absorbed into the ceiling below.
 */
export const SCRIPT_PHASE_TARGET_MS = 2_000;

/**
 * The asserted ceiling, in contention-normalized milliseconds.
 *
 * This is a **ratchet, not the target**.  Dropping webpack's `eval`
 * devtool is what made the phase cheap; this number locks that in so the next
 * regression is caught.  It sits between two measured populations:
 *
 *   normalized median, good build, 7 runs × 5 launches      2.52s - 3.17s
 *                                  (raw 2.60s - 4.82s, load 9 - 64)
 *   normalized median, `devtool: 'eval'` restored           3.998s
 *                                  (raw 4.15s, load 13)
 *
 * Re-run independently at load 77-82 on the same host, medians of 5 launches:
 *
 *   `devtool: 'cheap-source-map'` (shipped)   2646ms normalized, 5045ms raw
 *   `devtool: false`                          2669ms normalized, 4966ms raw
 *   `devtool: 'eval'`                         3779ms normalized, 6915ms raw
 *                                             -> assertion fails, as intended
 *
 * So the separation is real, but narrower on the regression side than on the
 * good side: 3_500ms is ~31% above the good median and only ~7% below the
 * `eval` median.  A regression appreciably smaller than the one this milestone
 * fixed will not trip it.  That is the accepted cost of a ratchet that must
 * not flake red; the structural assertion below is the sharp, noise-free half
 * of the same guard.
 *
 * Do not raise it to accommodate a regression; tighten it whenever the phase
 * gets cheaper.  The goal is `SCRIPT_PHASE_TARGET_MS`.
 */
export const SCRIPT_PHASE_CEILING_MS = 3_500;

/**
 * Time (ms) the calibration workload below takes on the reference host — the
 * 32-core developer machine these numbers were measured on — machine quiet.
 * Measured: 115-120ms at load average under 15.
 *
 * It exists only to give `normalizedScriptsMs` a unit; it cancels out of any
 * comparison between two runs on the same machine, and on different hardware
 * it rescales both terms together.
 *
 * HOW WELL THE NORMALIZATION WORKS, measured.  Two consecutive runs of this
 * spec, the same build, one at load 15-23 and one at load 39-59:
 *
 *   raw median         2912ms  ->  4820ms   (1.65x, i.e. useless as a budget)
 *   normalized median  2634ms  ->  2744ms   (1.04x)
 *
 * and under 48 synthetic spinners at load 55-64, raw 4946-5458ms normalized to
 * 2495-2890ms — the same band the quiet host reports.
 *
 * It is not perfect: the calibration runs after the launch has settled while
 * the measured phase runs during Electron's own start-up, so it slightly
 * under-reports the contention that phase saw, and a single launch can still
 * scatter (1990-3289ms observed).  That is what the median over `SAMPLES`
 * launches is for.
 */
const CALIBRATION_REFERENCE_MS = 118;

/** Launches to sample before taking the median. */
const SAMPLES = 5;

/**
 * Minimum samples that must have been collected for the ceiling assertion to
 * mean anything.  Below this the assertion fails rather than passing vacuously
 * on one lucky launch.
 */
const MIN_SAMPLES = 3;

// ---------------------------------------------------------------------------
// Fixture
// ---------------------------------------------------------------------------

const repoRoot = path.resolve(__dirname, "../../../../..");

function findJsRecorder(): string {
  const env = process.env.CODETRACER_JS_RECORDER_PATH;
  if (env && fs.existsSync(env)) return env;
  return path.resolve(
    repoRoot,
    "..",
    "codetracer-js-recorder",
    "packages",
    "cli",
    "dist",
    "index.js",
  );
}

const fixtureDir = path.join(
  os.tmpdir(),
  "ct-startup-budget-gui-" + process.pid,
);
const programPath = path.join(fixtureDir, "program.js");
const tracePath = path.join(fixtureDir, "trace");
const PROGRAM = "var a = 1; var b = 2; var c = a + b;\nvar d = c * 2;\n";

/** Record the fixture trace once, at module load. */
function prepareFixture(): { traceDir: string } {
  if (fs.existsSync(fixtureDir)) {
    fs.rmSync(fixtureDir, { recursive: true, force: true });
  }
  fs.mkdirSync(fixtureDir, { recursive: true });
  fs.writeFileSync(programPath, PROGRAM);

  const recorder = findJsRecorder();
  if (fs.existsSync(recorder)) {
    const recorderOut = path.join(fixtureDir, "rec-out");
    fs.mkdirSync(recorderOut, { recursive: true });
    childProcess.spawnSync("node", [
      recorder,
      "record",
      programPath,
      "--out-dir",
      recorderOut,
    ]);
    const entries = fs.readdirSync(recorderOut, { withFileTypes: true });
    const sub = entries.find(
      (e) => e.isDirectory() && e.name.startsWith("trace-"),
    );
    if (sub) fs.renameSync(path.join(recorderOut, sub.name), tracePath);
  }
  return { traceDir: tracePath };
}

const fixture = prepareFixture();

// ---------------------------------------------------------------------------
// Collected measurements
// ---------------------------------------------------------------------------

interface StartupSample {
  /** `ct:scripts-start` → `ct:bundle-done`: the webpack bundle. */
  bundleMs: number;
  /** `ct:bundle-done` → `ct:ui-done`: jstree + the Nim-generated `ui.js`. */
  uiMs: number;
  /** `ct:scripts-start` → `ct:ui-done`: raw wall clock of the whole phase. */
  scriptsMs: number;
  /** Cost of the calibration workload in this renderer, right now. */
  calibrationMs: number;
  /** `scriptsMs` scaled to reference-host, low-contention terms. */
  normalizedScriptsMs: number;
  /** Navigation-timing milestones, reported only. */
  responseEndMs: number;
  domInteractiveMs: number;
  loadEventEndMs: number;
  firstPaintMs: number;
  firstContentfulPaintMs: number;
  /** Wall clock of `readyOnEntryTest`, reported only. */
  readyOnEntryMs: number;
  /** 1-minute load average at the moment of measurement. */
  loadAvg: number;
}

const samples: StartupSample[] = [];

/**
 * Read the renderer's own Performance API, then calibrate the host.
 *
 * `readyOnEntryMs` is passed in rather than measured here: the caller has to
 * wait for the launch to complete before any of these marks exist, and that
 * wait *is* the wall-clock figure worth reporting.
 */
async function collectStartupSample(
  page: import("@playwright/test").Page,
  readyOnEntryMs: number,
): Promise<StartupSample> {
  const raw = await page.evaluate(() => {
    const nav = performance.getEntriesByType(
      "navigation",
    )[0] as PerformanceNavigationTiming | undefined;
    const markAt = (name: string): number => {
      const entries = performance.getEntriesByName(name, "mark");
      return entries.length > 0 ? entries[0].startTime : Number.NaN;
    };
    const paintAt = (name: string): number => {
      const entries = performance.getEntriesByName(name, "paint");
      return entries.length > 0 ? entries[0].startTime : Number.NaN;
    };

    // Calibration: compile a fixed, generated source and time it.  Compilation
    // — not execution — is what dominates the phase being measured, so this
    // competes for the same resource and stretches by the same factor when the
    // host is busy.  Deterministic: the source is generated from a counter, so
    // every renderer on every host compiles exactly the same text.
    //
    // Each repetition builds a *distinct* source so V8's compilation cache
    // cannot serve a later one from an earlier one.  The MEDIAN of the
    // repetitions is taken, not the minimum: the goal is to estimate the
    // contention the measured script phase actually experienced, and the
    // minimum systematically picks the least-interrupted window instead —
    // measured under 48 synthetic spinners, per-repetition times ranged
    // 134-231ms, so a minimum would have under-reported contention by up to
    // 1.7x and inflated the normalized figure by the same factor.
    const calibrationSource = (salt: number): string => {
      const parts: string[] = [`var s${salt} = 0;`];
      for (let i = 0; i < 20000; i += 1) {
        parts.push(
          `function f${salt}_${i}(a, b) { var t = a + b * ${i}; ` +
            `if (t > ${i}) { t -= ${i}; } else { t += ${i}; } return t; }`,
        );
      }
      return parts.join("\n");
    };
    const calibrationReps: number[] = [];
    for (let rep = 0; rep < 5; rep += 1) {
      const src = calibrationSource(rep);
      const t0 = performance.now();
      // eslint-disable-next-line no-new-func
      const compiled = new Function(src);
      calibrationReps.push(performance.now() - t0);
      // Keep a reference so nothing can be optimised away.
      (
        window as unknown as { __ctCalibrationSink?: unknown }
      ).__ctCalibrationSink = compiled;
    }
    calibrationReps.sort((a, b) => a - b);
    const calibrationMs = calibrationReps[Math.floor(calibrationReps.length / 2)];

    return {
      scriptsStart: markAt("ct:scripts-start"),
      bundleDone: markAt("ct:bundle-done"),
      uiDone: markAt("ct:ui-done"),
      responseEnd: nav ? nav.responseEnd : Number.NaN,
      domInteractive: nav ? nav.domInteractive : Number.NaN,
      loadEventEnd: nav ? nav.loadEventEnd : Number.NaN,
      firstPaint: paintAt("first-paint"),
      firstContentfulPaint: paintAt("first-contentful-paint"),
      calibrationMs,
    };
  });

  // A missing mark means `src/frontend/index.html` lost its instrumentation
  // (or the build is stale).  Fail loudly — silently degrading to NaN would
  // turn this budget into a no-op.
  for (const [name, value] of [
    ["ct:scripts-start", raw.scriptsStart],
    ["ct:bundle-done", raw.bundleDone],
    ["ct:ui-done", raw.uiDone],
  ] as const) {
    if (!Number.isFinite(value)) {
      throw new Error(
        `startup mark "${name}" is missing from the renderer.  ` +
          `src/frontend/index.html must emit it, and the build must be fresh ` +
          `(run 'just build-once').`,
      );
    }
  }
  if (!Number.isFinite(raw.calibrationMs) || raw.calibrationMs <= 0) {
    throw new Error(
      `host calibration produced ${raw.calibrationMs}ms, which cannot be used ` +
        `to normalize the measurement`,
    );
  }

  const scriptsMs = raw.uiDone - raw.scriptsStart;
  return {
    bundleMs: raw.bundleDone - raw.scriptsStart,
    uiMs: raw.uiDone - raw.bundleDone,
    scriptsMs,
    calibrationMs: raw.calibrationMs,
    normalizedScriptsMs:
      scriptsMs * (CALIBRATION_REFERENCE_MS / raw.calibrationMs),
    responseEndMs: raw.responseEnd,
    domInteractiveMs: raw.domInteractive,
    loadEventEndMs: raw.loadEventEnd,
    firstPaintMs: raw.firstPaint,
    firstContentfulPaintMs: raw.firstContentfulPaint,
    readyOnEntryMs,
    loadAvg: os.loadavg()[0],
  };
}

function report(index: number, s: StartupSample): void {
  const ms = (v: number) => (Number.isFinite(v) ? `${Math.round(v)}ms` : "n/a");
  console.log(
    `# startup sample ${index}: scripts ${ms(s.scriptsMs)} raw / ` +
      `${ms(s.normalizedScriptsMs)} normalized ` +
      `(bundle ${ms(s.bundleMs)} + jstree/ui.js ${ms(s.uiMs)}; ` +
      `calibration ${ms(s.calibrationMs)} vs ${CALIBRATION_REFERENCE_MS}ms ref) | ` +
      `responseEnd ${ms(s.responseEndMs)} ` +
      `first-paint ${ms(s.firstPaintMs)} ` +
      `domInteractive ${ms(s.domInteractiveMs)} ` +
      `FCP ${ms(s.firstContentfulPaintMs)} ` +
      `loadEventEnd ${ms(s.loadEventEndMs)} ` +
      `ready ${ms(s.readyOnEntryMs)} ` +
      `| load ${s.loadAvg.toFixed(2)}`,
  );
}

function median(values: number[]): number {
  const sorted = [...values].sort((a, b) => a - b);
  const mid = Math.floor(sorted.length / 2);
  return sorted.length % 2 === 1
    ? sorted[mid]
    : (sorted[mid - 1] + sorted[mid]) / 2;
}

// ---------------------------------------------------------------------------
// Suite
// ---------------------------------------------------------------------------

// NOTE: deliberately NOT `test.describe.serial` — that mode marks every
// remaining test as skipped once one fails, so a single unlucky launch would
// silently reduce the budget assertion to "did not run".  A plain describe
// still runs the launches in order in one worker (`fullyParallel: false`), and
// `MIN_SAMPLES` below is what guards against judging the budget on too few.
test.describe("Frontend startup budget", () => {
  test.use({ sourcePath: fixture.traceDir, launchMode: "trace-folder" });
  test.setTimeout(120_000);

  for (let i = 1; i <= SAMPLES; i += 1) {
    test(`collect renderer startup timings (launch ${i} of ${SAMPLES})`, async ({
      ctPage,
    }) => {
      // The launch fixture resolves as soon as Electron has a window — long
      // before the synchronous scripts have run.  Wait for the app to reach
      // its entry location first, both because that is when the marks exist
      // and because it is the wall-clock number M46 measured.
      const readyStarted = Date.now();
      await readyOnEntry(ctPage);
      const readyOnEntryMs = Date.now() - readyStarted;
      // Let the renderer settle before calibrating.  `.location-path`
      // becoming visible does not mean the main thread is idle — the app is
      // still finishing its first redraws — and calibration that competes
      // with the app's own work reports contention the measured script phase
      // never saw, which shows up as an implausibly LOW normalized figure.
      await ctPage.waitForTimeout(1_500);
      const sample = await collectStartupSample(ctPage, readyOnEntryMs);
      report(i, sample);
      samples.push(sample);
    });
  }

  /**
   * The noise-free half of the guard.
   *
   * The timing ceiling above is a statistic on a shared host, and the
   * normalization it rests on is only valid for a reference-class machine (see
   * the header).  This test asserts the same regression *structurally* — it
   * reads the emitted bundle and checks the two properties that made the
   * difference — so the finding survives on any host, at any load, in any CI
   * runner, and fails with a specific cause rather than a number.
   *
   * It does not launch anything and takes about a second.
   */
  test("the emitted bundle is not eval-wrapped and keeps its source map", async () => {
    // The bundle under test is not always the working tree's.  The nixos CI
    // leg runs a nix-built app via CODETRACER_E2E_CT_PATH, and
    // `nix/packages/default.nix` installs the bundle beside it as
    // `<prefix>/src/frontend_bundle.js`.  Check whichever one the app being
    // launched actually loads, preferring the packaged copy when there is one.
    const candidates: string[] = [];
    const ctPath = process.env.CODETRACER_E2E_CT_PATH ?? "";
    if (ctPath) {
      candidates.push(
        path.resolve(path.dirname(ctPath), "..", "src", "frontend_bundle.js"),
      );
    }
    const distBundle = path.resolve(
      repoRoot,
      "src",
      "public",
      "dist",
      "frontend_bundle.js",
    );
    candidates.push(distBundle);

    const bundlePath = candidates.find((c) => fs.existsSync(c));
    // No bundle anywhere means the app under test could not have started, and
    // the five launches above will already have failed loudly and specifically.
    // Do not add a second, less informative failure on top of that.
    test.skip(
      bundlePath === undefined,
      `no frontend_bundle.js found at any of: ${candidates.join(", ")}`,
    );

    const bundle = fs.readFileSync(bundlePath as string, "utf8");

    // `devtool: 'eval'` (webpack's default under `mode: 'development'`) emits
    // one `eval("...")` per module — 3565 of them for this bundle, against 0
    // for every non-eval devtool.  Anything in that neighbourhood means the
    // eval devtool is back and the renderer is paying seconds for it.
    const evalSites = (bundle.match(/eval\(/g) ?? []).length;
    expect(
      evalSites,
      `the bundle contains ${evalSites} eval() sites.  webpack's 'eval' ` +
        `devtool wraps every module in eval() of its source, which defeats ` +
        `V8's lazy pre-parse and costs ~2s of renderer startup.  See the ` +
        `devtool comment in webpack.config.js.`,
    ).toBeLessThan(100);

    // ...and the cheap fix for that must not be to throw away debuggability.
    // A non-eval devtool that emits a real map costs nothing at runtime (the
    // bundle body is byte-identical to `devtool: false`), so there is no
    // reason to ship without one.
    expect(
      bundle.trimEnd().endsWith("//# sourceMappingURL=frontend_bundle.js.map"),
      `the bundle does not end with a sourceMappingURL comment pointing at ` +
        `frontend_bundle.js.map, so the debugger has no way to map the ` +
        `renderer back to source.  webpack.config.js must keep a devtool ` +
        `that emits a separate map (see its devtool comment).`,
    ).toBe(true);

    // Only the working tree is expected to hold the map itself: packaging
    // copies `frontend_bundle.js` alone (appimage-scripts/build_appimage.sh,
    // nix/packages/default.nix), deliberately, so a release does not carry
    // 36 MB nobody reads.
    const mapPath = distBundle + ".map";
    let mapNote = "not checked (testing a packaged bundle)";
    if (bundlePath === distBundle) {
      expect(
        fs.existsSync(mapPath),
        `${mapPath} is missing even though the bundle references it; ` +
          `re-run 'just build-once'`,
      ).toBe(true);
      mapNote = `${(fs.statSync(mapPath).size / 1e6).toFixed(1)} MB`;
    }

    console.log(
      `# startup budget: bundle ${(fs.statSync(bundlePath as string).size / 1e6).toFixed(1)} MB ` +
        `at ${bundlePath}, ${evalSites} eval() sites, map ${mapNote}`,
    );
  });

  test("renderer script parse-and-execute stays within the startup budget", async () => {
    expect(
      samples.length,
      `only ${samples.length} of ${SAMPLES} launches produced a startup ` +
        `sample; the budget cannot be judged on fewer than ${MIN_SAMPLES}`,
    ).toBeGreaterThanOrEqual(MIN_SAMPLES);

    const normalized = samples.map((s) => s.normalizedScriptsMs);
    const medianNormalizedMs = median(normalized);
    const medianRawMs = median(samples.map((s) => s.scriptsMs));
    const medianBundleMs = median(samples.map((s) => s.bundleMs));
    const medianUiMs = median(samples.map((s) => s.uiMs));
    const loads = samples.map((s) => s.loadAvg);
    const calibrations = samples.map((s) => s.calibrationMs);

    console.log(
      `# startup budget: median ${Math.round(medianNormalizedMs)}ms ` +
        `normalized / ${SCRIPT_PHASE_CEILING_MS}ms ceiling ` +
        `(raw median ${Math.round(medianRawMs)}ms; ` +
        `bundle ${Math.round(medianBundleMs)}ms, ` +
        `jstree/ui.js ${Math.round(medianUiMs)}ms) over ${samples.length} ` +
        `launches; normalized samples ` +
        `${normalized.map((v) => Math.round(v)).join(", ")}ms; ` +
        `calibration ${Math.round(Math.min(...calibrations))}-` +
        `${Math.round(Math.max(...calibrations))}ms; ` +
        `load ${Math.min(...loads).toFixed(1)}-${Math.max(...loads).toFixed(1)}`,
    );

    // The documented target is not met.  Say so on every run rather than
    // letting the ceiling below stand in for it — the ceiling is a ratchet
    // against regression, not a statement that startup is fast enough.
    if (medianNormalizedMs > SCRIPT_PHASE_TARGET_MS) {
      console.warn(
        `# startup budget: STILL OVER the ${SCRIPT_PHASE_TARGET_MS}ms target ` +
          `derived from Performance-Targets.md § Startup & Initialization by ` +
          `${Math.round(medianNormalizedMs - SCRIPT_PHASE_TARGET_MS)}ms ` +
          `(${(medianNormalizedMs / SCRIPT_PHASE_TARGET_MS).toFixed(2)}x). ` +
          `See the "WHERE THE TIME GOES" note at the top of this file for ` +
          `what was measured and rejected.`,
      );
    }

    expect(
      medianNormalizedMs,
      `renderer script parse-and-execute (median of ${samples.length} ` +
        `launches: ${Math.round(medianNormalizedMs)}ms normalized, ` +
        `${Math.round(medianRawMs)}ms raw — bundle ` +
        `${Math.round(medianBundleMs)}ms, jstree+ui.js ` +
        `${Math.round(medianUiMs)}ms) exceeds the ${SCRIPT_PHASE_CEILING_MS}ms ` +
        `ceiling.  Something was added to the renderer's synchronous script ` +
        `path, or webpack's 'eval' devtool came back (see webpack.config.js).`,
    ).toBeLessThanOrEqual(SCRIPT_PHASE_CEILING_MS);
  });
});
