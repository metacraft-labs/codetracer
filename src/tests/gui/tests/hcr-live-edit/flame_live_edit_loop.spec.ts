/**
 * `e2e_flame_live_hcr_edit_reshapes_without_restart` — the GUI half.
 *
 * Milestone: `codetracer-specs/Marketing/Home-Demo-Screencast.milestones.org`, H5.
 * Scene:     Scene 1 — "I'm editing the particle system that draws this flame
 *            — and it updates as I type. No rebuild. No restart."
 *
 * H4 proved an edit invoked from the command palette hot-reloads a running
 * flame. That is one patch, and Scene 1 is not one patch: it is a LOOP, and the
 * loop is the part that was structurally impossible before this milestone. The
 * in-target agent dials OUT exactly once, at process start, so a coordinator
 * that closes its connection after the first patch has thrown away the only
 * route into that process there will ever be. H5 makes the session outlive the
 * patch, and this spec drives that session from the product's own widget.
 *
 * WHAT IS ASSERTED, and against what:
 *
 *   1. THE WIDGET IS SURFACED. "Live Edit (HCR)…" is findable and clickable in
 *      the command palette, which the product builds by walking its own menu
 *      tree — so this asserts the Build-menu entry too.
 *
 *   2. TYPING PUBLISHES. Three values are typed into the field, one after
 *      another, into ONE running flame. The panel's status line must read
 *      `applied` after each — and that is what the PRODUCT said, never the
 *      verdict.
 *
 *   3. THE FLAME RESHAPED THREE TIMES, WITHOUT RESTARTING. The verdict is the
 *      flame demo's own `verify_hcr5_live_edit_loop.py`: three plateaus in
 *      three DISJOINT bands predicted from the source constants, a frame column
 *      that runs 1..N with no reset, and the coordinator session's own
 *      `patchesRequested` agreeing with the provider's per-site generations.
 *      A run in which only the first edit landed fails it, which is the whole
 *      difference between this spec and H4's.
 *
 * WHY THE FLAME IS LAUNCHED BY THE HARNESS HERE. The demo launches the target
 * under CodeTracer (`The-Flame-Demo-Spec.md` §2.5, clarified 2026-09-16); live
 * attach to an already-running process is out of scope and is not what this
 * tests. In this spec the harness plays the launcher's part — it starts the
 * session coordinator and then the flame — because CodeTracer's own
 * launch-a-target-under-HCR path is not built yet. That gap is recorded in the
 * milestone; it is not papered over here.
 *
 * GATED, and it skips LOUDLY, naming the first missing prerequisite.
 */
import { spawn, type ChildProcess } from "node:child_process";
import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";
import { spawnSync } from "node:child_process";
import { test, expect } from "../../lib/fixtures";
import { LayoutPage } from "../../page-objects/layout-page";
import { resolveFlamePaths, runFlame, waitForFile, type FlamePaths } from "../hcr-apply-edit/flame-hcr-driver";

const CODETRACER_REPO = path.resolve(__dirname, "../../../../..");
const PY_PROGRAM = "py_console_logs/main.py";

/**
 * The three edits, and the bands they predict.
 *
 * Steady population goes as `1/rise_speed` — every term read out of
 * `advanceExisting()` and `emit()` in the shipped source, which is where the
 * apply-edit command derives its own prediction from too. The bands are
 * DISJOINT, and the verdict refuses a table whose bands overlap: "the flame
 * moved" cannot tell one edit from another, and the claim here is that it moved
 * to a DIFFERENT place each time.
 */
const ARMS = [
  { edit: "rise_speed=2.7", predicted: 0.6667, band: "0.61:0.73" },
  { edit: "rise_speed=5.4", predicted: 0.3333, band: "0.28:0.38" },
  { edit: "rise_speed=9.0", predicted: 0.2, band: "0.16:0.24" },
];
/**
 * Frames per run, and the plateau budget per arm.
 *
 * Far longer than the headless gate's 540 and for a measured reason: through
 * the product's own widget, one edit takes about 365 frames from keypress to
 * the panel showing `applied`, against about 25 when the same command is
 * invoked directly. Three arms, each needing its publication latency plus
 * `SETTLE` frames of transient plus `PLATEAU` frames of steady state, do not
 * fit in 540 — the first run of this spec fired all three within sixty frames
 * of each other for exactly that reason.
 */
const FRAMES = 2400;
const FIRST_EDIT_AT = 120;
const SETTLE = 60;
const PLATEAU = 120;

const resolved = resolveFlamePaths(CODETRACER_REPO);
let unavailable = typeof resolved === "string" ? resolved : null;
const flame = typeof resolved === "string" ? null : (resolved as FlamePaths);

/**
 * The session-capable driver, which is NOT the same binary H4 uses.
 *
 * Named and checked separately on purpose. A driver without `--session-dir`
 * predates the live-edit loop; used here it would fall back to one-shot
 * behaviour and this spec would measure H4 three times while looking like H5.
 * The check reads the driver's own usage text rather than its path.
 */
const SESSION_DRIVER =
  process.env.CODETRACER_HCR_SESSION_DRIVER ??
  (flame !== null
    ? path.join(flame.flameRepo, "artifacts", "h5-driver", "hcr_patch_driver")
    : "");
if (unavailable === null) {
  if (!fs.existsSync(SESSION_DRIVER)) {
    unavailable = `the session-capable HCR coordinator driver is missing: ${SESSION_DRIVER}`;
  } else {
    const usage = spawnSync(SESSION_DRIVER, ["--help"], { encoding: "utf8" });
    if (!`${usage.stdout ?? ""}${usage.stderr ?? ""}`.includes("--session-dir")) {
      unavailable =
        `${SESSION_DRIVER} does not support --session-dir; it predates the live-edit loop`;
    }
  }
}
if (unavailable === null && flame !== null) {
  const verify = path.join(flame.flameRepo, "scripts", "verify_hcr5_live_edit_loop.py");
  if (!fs.existsSync(verify)) unavailable = `the H5 verdict script is missing: ${verify}`;
}

const WORK =
  flame !== null
    ? path.join(flame.flameRepo, "artifacts", "h5-gui-e2e")
    : fs.mkdtempSync(path.join(os.tmpdir(), "ct-h5-"));
fs.mkdirSync(WORK, { recursive: true });
const SESSION_DIR = path.join(WORK, "session");
// /tmp, because AF_UNIX caps a socket path at 108 bytes in the KERNEL and a
// repo-relative artifacts path plus a name crosses it easily.
const SOCKET = path.join("/tmp", `ct-h5-${process.pid}.sock`);
const TICKS = path.join(WORK, "ticks-patched.log");
const CONTROL_TICKS = path.join(WORK, "ticks-control.log");
const REPORT = path.join(WORK, "apply-edit-report.json");

// Set at MODULE SCOPE: `makeCleanEnv` in lib/fixtures.ts snapshots
// `process.env` when it launches Electron, so a variable set inside a test body
// reaches nothing.
if (flame !== null) {
  process.env.CODETRACER_HCR_APPLY_EDIT_CMD = flame.applyEdit;
  process.env.CODETRACER_HCR_SESSION_DIR = SESSION_DIR;
  process.env.CODETRACER_HCR_REPORT = REPORT;
  // Deliberately CLEARED. The main process refuses a session configured
  // alongside a socket/driver by name, and leaving one of H4's variables in the
  // environment of this run would produce that refusal in a spec about
  // something else entirely.
  delete process.env.CODETRACER_HCR_SOCKET;
  delete process.env.CODETRACER_HCR_DRIVER;
  delete process.env.CODETRACER_HCR_EDIT;
  delete process.env.CODETRACER_HCR_WAIT_FOR;
  delete process.env.CODETRACER_HCR_MARKER;
}

const COMMAND_LABEL = "Live Edit (HCR)…";

/** Wait until the flame's own flushed tick file shows a frame at least `want`. */
async function waitForFrame(want: number, timeoutMs: number): Promise<number> {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    if (fs.existsSync(TICKS)) {
      const text = fs.readFileSync(TICKS, "utf8");
      const matches = [...text.matchAll(/frame=(\d+)/g)];
      const last = matches.length > 0 ? Number(matches[matches.length - 1][1]) : 0;
      if (last >= want) return last;
    }
    await new Promise((resolve) => setTimeout(resolve, 50));
  }
  throw new Error(`the flame never reached frame ${want} within ${timeoutMs} ms`);
}

function currentFrame(): number {
  if (!fs.existsSync(TICKS)) return 0;
  const matches = [...fs.readFileSync(TICKS, "utf8").matchAll(/frame=(\d+)/g)];
  return matches.length > 0 ? Number(matches[matches.length - 1][1]) : 0;
}

test.describe("H5 — the Scene-1 live-edit loop", () => {
  test.setTimeout(900_000);
  test.use({ sourcePath: PY_PROGRAM, launchMode: "trace" });

  test("typing successive values reshapes ONE running flame, three times, with no restart", async ({
    ctPage,
  }) => {
    test.skip(unavailable !== null, `the H5 prerequisites are not present: ${unavailable ?? ""}`);
    const paths = flame as FlamePaths;

    const layout = new LayoutPage(ctPage);
    await layout.waitForAllComponentsLoaded();
    await layout.waitForTraceLoaded();

    // --- the CONTROL run: same scene, same engine, no agent -----------------
    // FlameSim is seeded and fixed-timestep, so this is both the trajectory the
    // patched run must reproduce before the first edit and the denominator of
    // every plateau ratio afterwards.
    const control = await runFlameFrames(paths, CONTROL_TICKS, null, 300_000);
    expect(control.code, `the control flame exited ${control.code}: ${control.stderr.slice(-400)}`).toBe(0);
    expect(control.stdout).toContain("CT_H2_DONE");

    // --- the session coordinator, then the flame ----------------------------
    fs.rmSync(SESSION_DIR, { recursive: true, force: true });
    fs.mkdirSync(SESSION_DIR, { recursive: true });
    fs.rmSync(SOCKET, { force: true });
    fs.rmSync(TICKS, { force: true });
    fs.writeFileSync(TICKS, "");

    const driverLog = fs.openSync(path.join(WORK, "driver.log"), "w");
    const coordinator: ChildProcess = spawn(
      SESSION_DRIVER,
      [
        "--socket", SOCKET,
        "--target-symbol", "_ZN5flame8FlameSim15advanceExistingEv",
        "--session", "--session-dir", SESSION_DIR,
        "--session-idle-timeout-ms", "600000",
      ],
      { stdio: ["ignore", driverLog, driverLog] },
    );
    await waitForFile(SOCKET, 60_000, "the live-edit session's coordinator socket");

    const patchedRun = runFlameFrames(paths, TICKS, SOCKET, 600_000);
    // `ready` is written after the HANDSHAKE, not after the accept. Publishing
    // on the strength of a connected socket would send a patch request into a
    // session that had not negotiated.
    await waitForFile(path.join(SESSION_DIR, "ready"), 120_000, "the live-edit session becoming ready");

    // --- the widget ---------------------------------------------------------
    await ctPage.keyboard.press("Control+KeyP");
    const query = ctPage.locator("#command-query-text");
    await expect(query).toBeVisible({ timeout: 15_000 });
    await query.fill(":Live Edit");
    const hit = ctPage
      .locator(".command-results .command-result.command-command")
      .filter({ hasText: COMMAND_LABEL })
      .first();
    await expect(hit).toBeVisible({ timeout: 15_000 });
    await hit.click();

    const panel = ctPage.locator(".hcr-live-edit-panel");
    await expect(panel).toBeVisible({ timeout: 15_000 });
    const input = panel.locator("[data-hcr-live-edit-input]");
    const status = panel.locator("[data-hcr-live-edit-status]");
    const detail = panel.locator("[data-hcr-live-edit-detail]");
    await expect(status).toHaveText("waiting", { timeout: 10_000 });

    // --- three edits, typed, into one running flame -------------------------
    //
    // PACED BY THE PREVIOUS EDIT'S ANSWER, not by a fixed frame per arm, and
    // that is a correction rather than a preference. Driven through the
    // product, one edit takes ~365 frames from keypress to the panel showing
    // `applied` — the Electron IPC round trip, a real clang++ invocation and
    // the publication — so three arms pinned to frames 90/240/390 all fired
    // within 60 frames of each other while the flame ran on. Waiting for the
    // previous plateau to be established makes the spacing a property of what
    // actually happened rather than of a guess about how fast this host is.
    const appliedAt: number[] = [];
    const submittedAt: number[] = [];
    for (let i = 0; i < ARMS.length; i += 1) {
      const arm = ARMS[i];
      const due = i === 0 ? FIRST_EDIT_AT : appliedAt[i - 1] + SETTLE + PLATEAU;
      await waitForFrame(due, 600_000);
      // The frame the edit is HANDED OVER at. The patch cannot have landed
      // before this, so it is what the verdict uses as the boundary for "the
      // two runs were identical beforehand". Recorded BEFORE the keypress.
      submittedAt.push(currentFrame());
      // `fill` then Enter. Enter publishes without waiting out the debounce,
      // so the arm's timing is not also a measurement of a timer in the
      // renderer.
      await input.fill(arm.edit);
      await input.press("Enter");
      // The panel's status line is where the answer STAYS. The notifications
      // are transient and auto-dismiss — trap 21, recorded by H4's own GUI arm
      // — so a loop that publishes repeatedly needs a non-expiring surface, and
      // this is the assertion that the product has one.
      await expect(status).toHaveText("applied", { timeout: 300_000 });
      await expect(detail).toContainText("no restart", { timeout: 10_000 });
      // And the frame the answer came BACK at. The patch has certainly landed
      // by now, so this is where the verdict starts measuring the plateau.
      appliedAt.push(currentFrame());
    }

    // --- close the session and let the flame finish -------------------------
    fs.writeFileSync(path.join(SESSION_DIR, "stop"), "");
    const patched = await patchedRun;
    expect(patched.code, `the patched flame exited ${patched.code}: ${patched.stderr.slice(-400)}`).toBe(0);
    await new Promise<void>((resolve) => {
      if (coordinator.exitCode !== null) return resolve();
      coordinator.on("close", () => resolve());
      setTimeout(() => resolve(), 30_000);
    });
    fs.closeSync(driverLog);

    // --- the session's own account of itself --------------------------------
    // Read before the flame verdict, because it is the claim the flame cannot
    // make: that THREE patches went down ONE connection. `patchesRequested`
    // comes from the coordinator's protocol state machine, not from a counter
    // in this file.
    const sessionPath = path.join(SESSION_DIR, "session.json");
    await waitForFile(sessionPath, 60_000, "the live-edit session's summary");
    const session = JSON.parse(fs.readFileSync(sessionPath, "utf8"));
    expect(session.patchesRequested, JSON.stringify(session)).toBe(ARMS.length);
    expect(session.applied).toBe(ARMS.length);
    expect(new Set(session.patchIds).size).toBe(ARMS.length);

    // --- the verdict, from the flame's own output ---------------------------
    const armsJson = path.join(WORK, "arms.json");
    const armArgs: string[] = [];
    ARMS.forEach((arm, i) => {
      armArgs.push(
        "--arm",
        `${i + 1}|${arm.edit}|${arm.predicted}|${arm.band}|${appliedAt[i]}|${path.join(
          SESSION_DIR,
          `cmd-${i + 1}.json`,
        )}|${submittedAt[i]}|${submittedAt[i]}`,
      );
    });
    // The arm table's `report` column points at the command's INDEXED report
    // (`cmd-<n>.json`, written beside the coordinator's `res-<n>.json`) rather
    // than at `--json-out`. The main process is configured once and passes one
    // `--json-out` for every edit, so after three edits that file holds only
    // the third verdict and the first two exist nowhere readable.
    const written = spawnSync(
      "python3",
      [path.join(paths.flameRepo, "scripts", "hcr5_arms_json.py"), "--out", armsJson, ...armArgs],
      { encoding: "utf8" },
    );
    expect(written.status, `${written.stdout}${written.stderr}`).toBe(0);

    const verdict = spawnSync(
      "python3",
      [
        path.join(paths.flameRepo, "scripts", "verify_hcr5_live_edit_loop.py"),
        "--control", CONTROL_TICKS,
        "--patched", TICKS,
        "--arms", armsJson,
        "--session", sessionPath,
        "--frames", String(FRAMES),
        "--settle", String(SETTLE),
        "--json-out", path.join(WORK, "verdict.json"),
      ],
      { encoding: "utf8" },
    );
    const summary = `${verdict.stdout ?? ""}\n${verdict.stderr ?? ""}`;
    expect(summary, summary).toContain("are identical in both runs");
    expect(verdict.status, `the flame verdict failed:\n${summary}`).toBe(0);
    expect(summary).toContain("verdict: pass");
  });
});

/**
 * The flame, run for H5's frame count.
 *
 * `runFlame` in the H4 driver hardcodes H4's 360 frames, and H5 needs 540 —
 * three plateaus plus their settling transients do not fit in 360. Rather than
 * change H4's constant (its recorded measurement is against 360) the frame
 * count is set here and everything else is the same spawn.
 */
function runFlameFrames(
  paths: FlamePaths,
  tickFile: string,
  agentSocket: string | null,
  timeoutMs: number,
): Promise<{ code: number | null; stdout: string; stderr: string }> {
  const env: NodeJS.ProcessEnv = {
    ...process.env,
    CT_H2_FRAMES: String(FRAMES),
    CT_H2_TICKFILE: tickFile,
  };
  delete env.CT_H2_CAPTURE;
  if (agentSocket !== null) {
    env.REPRO_HCR_AGENT_SOCKET = agentSocket;
  } else {
    // The CONTROL run must have no agent at all, or the identity comparison
    // underneath this gate is comparing a run with itself.
    delete env.REPRO_HCR_AGENT_SOCKET;
  }
  return new Promise((resolve, reject) => {
    const child = spawn(
      paths.engine,
      ["--headless", "--path", paths.flameRepo, "--scene", "res://scenes/hcr2_probe.tscn"],
      { env, cwd: paths.flameRepo },
    );
    let stdout = "";
    let stderr = "";
    const timer = setTimeout(() => {
      child.kill("SIGKILL");
      reject(new Error(`the flame did not finish ${FRAMES} frames within ${timeoutMs} ms`));
    }, timeoutMs);
    child.stdout.on("data", (chunk) => (stdout += chunk.toString()));
    child.stderr.on("data", (chunk) => (stderr += chunk.toString()));
    child.on("error", (err) => {
      clearTimeout(timer);
      reject(err);
    });
    child.on("close", (code) => {
      clearTimeout(timer);
      resolve({ code, stdout, stderr });
    });
  });
}
