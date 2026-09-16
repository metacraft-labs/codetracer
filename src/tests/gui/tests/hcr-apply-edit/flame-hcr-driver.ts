/**
 * Orchestration for the in-app apply-edit → HCR reload GUI E2E.
 *
 * This driver is a SEQUENCING AID and nothing else. It starts the flame, waits
 * for files to appear, and afterwards runs the flame demo's own verdict script.
 * It never decides whether the patch applied, never parses the command's report
 * into an assertion, and never tells CodeTracer what happened — the product's
 * own notification is the UI claim, and `verify_hcr2_flame_patch.py` comparing
 * two runs of the flame is the behavioural one. (`Live-HCR-GUI-E2E-Test-Design.md`
 * states the rule this follows: if the test passes only because the driver
 * taught the product what happened, the test is invalid.)
 *
 * WHY THE FLAME STARTS AFTER THE COMMAND IS INVOKED, which is worth stating
 * plainly because it looks like the wrong way round. On this wire the
 * COORDINATOR LISTENS and the TARGET DIALS OUT: the in-target agent connects
 * once, at process start, with a bounded retry (500 × 10 ms ≈ 5 s in
 * `repro_hcr_agent.c`). So a flame that has been running for a minute has long
 * since given up, and nothing a command does later can reach it. The patch
 * still lands in a RUNNING process and still involves no restart — publication
 * happens at frame ~122 of a 360-frame run, after the coordinator has READ the
 * flame's own frame-120 line — but the process cannot have been started before
 * the command was. Post-launch attach is its own piece of work
 * (`Recording-Backends/Multi-Core-Recorder/MCR-Post-Launch-Attach.md`) and is
 * not this milestone's.
 *
 * CLARIFIED 2026-09-16: that ordering is no longer a shortfall to apologise
 * for. The demo LAUNCHES the target program under CodeTracer and live attach to
 * an already-running process is out of scope
 * (`codetracer-specs/Marketing/The-Flame-Demo-Spec.md` §2.5), so "the
 * coordinator must exist before the process it patches" is what the demo
 * requires rather than something it works around. The sequencing below is
 * unchanged; only the reading of it is.
 */
import { spawn, spawnSync } from "node:child_process";
import * as fs from "node:fs";
import * as path from "node:path";

export const FRAMES = 360;
export const PATCH_AT = 120;
export const MARKER = `CT_H2 frame=${PATCH_AT} `;
export const SCENE = "res://scenes/hcr2_probe.tscn";

/** The predicted steady live-particle ratio band for `rise_speed=5.4`. */
export const EDIT = "rise_speed=5.4";
export const LIVE_RATIO_BAND = "0.28:0.38";

export interface FlamePaths {
  workspace: string;
  flameRepo: string;
  engine: string;
  driver: string;
  applyEdit: string;
  verify: string;
}

/** Everything this test needs, or the first thing that is missing, by name. */
export function resolveFlamePaths(codetracerRepo: string): FlamePaths | string {
  const workspace = path.dirname(codetracerRepo);
  const flameRepo =
    process.env.CODETRACER_FLAME_DEMO_REPO ?? path.join(workspace, "codetracer-flame-demo");
  const engineRepo = path.join(workspace, "codetracer-engine-godot");
  const engines = [
    path.join(engineRepo, "bin", "godot.linuxbsd.template_debug.x86_64.hcrq"),
    path.join(engineRepo, "bin", "godot.linuxbsd.template_debug.x86_64.hcrgpu"),
  ];
  const engine = engines.find((candidate) => fs.existsSync(candidate));
  if (engine === undefined) {
    return `no patchable Godot engine under ${engineRepo}/bin (looked for ${engines.join(", ")})`;
  }
  const paths: FlamePaths = {
    workspace,
    flameRepo,
    engine,
    driver:
      process.env.CODETRACER_HCR_DRIVER ??
      path.join(flameRepo, "artifacts", "h3-driver", "hcr_patch_driver"),
    applyEdit: path.join(flameRepo, "scripts", "ct_hcr_apply_edit.py"),
    verify: path.join(flameRepo, "scripts", "verify_hcr2_flame_patch.py"),
  };
  for (const [what, where] of [
    ["the flame demo checkout", paths.flameRepo],
    ["the imported Godot project (run `just import` in the flame demo)", path.join(paths.flameRepo, ".godot")],
    ["the patchable FlameField GDExtension (run `just gdext-hcr`)", path.join(paths.flameRepo, "bin", "libflamefield.macos.template_debug.so")],
    ["the prebuilt HCR coordinator driver", paths.driver],
    ["the apply-edit command", paths.applyEdit],
    ["the flame verdict script", paths.verify],
  ] as const) {
    if (!fs.existsSync(where)) return `${what} is missing: ${where}`;
  }
  return paths;
}

interface RunResult {
  code: number | null;
  stdout: string;
  stderr: string;
}

/** Run the flame headless for `FRAMES` frames and return its output. */
export function runFlame(
  paths: FlamePaths,
  tickFile: string,
  agentSocket: string | null,
  timeoutMs: number,
): Promise<RunResult> {
  const env: NodeJS.ProcessEnv = {
    ...process.env,
    CT_H2_FRAMES: String(FRAMES),
    CT_H2_TICKFILE: tickFile,
  };
  delete env.CT_H2_CAPTURE;
  if (agentSocket !== null) {
    env.REPRO_HCR_AGENT_SOCKET = agentSocket;
  } else {
    // The CONTROL run must have no agent at all. Inheriting one from the test
    // runner's environment would make the control the same run as the patched
    // one, and the identity comparison underneath this whole gate would be
    // comparing a run with itself.
    delete env.REPRO_HCR_AGENT_SOCKET;
  }
  return new Promise((resolve, reject) => {
    const child = spawn(
      paths.engine,
      ["--headless", "--path", paths.flameRepo, "--scene", SCENE],
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

export async function waitForFile(target: string, timeoutMs: number, what: string): Promise<void> {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    if (fs.existsSync(target)) return;
    await new Promise((resolve) => setTimeout(resolve, 100));
  }
  throw new Error(`${what} never appeared at ${target} within ${timeoutMs} ms`);
}

/**
 * The flame demo's own verdict, unchanged.
 *
 * Two runs of the same seeded, fixed-timestep scene must agree frame for frame
 * on live particle count until the patch lands, diverge afterwards, stay
 * diverged, and diverge by the magnitude this edit predicts. The agent's
 * success report contributes nothing to it, and neither does anything the UI
 * displayed.
 */
export function runVerdict(
  paths: FlamePaths,
  controlLog: string,
  patchedLog: string,
  jsonOut: string,
): RunResult {
  const result = spawnSync(
    "python3",
    [
      paths.verify,
      "--control", controlLog,
      "--patched", patchedLog,
      "--patch-at", String(PATCH_AT),
      "--frames", String(FRAMES),
      "--mode", "inapp-gui",
      "--expect", "change",
      "--live-ratio", LIVE_RATIO_BAND,
      "--json-out", jsonOut,
    ],
    { encoding: "utf8" },
  );
  return { code: result.status, stdout: result.stdout ?? "", stderr: result.stderr ?? "" };
}
