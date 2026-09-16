/**
 * HWG-M6 Windows GUI gate.
 *
 * allowed_mocks: none. The command-palette action is the only publisher. It
 * drives the real Python apply-edit command, MSVC, the production Windows
 * coordinator/agent, and a running patchable Godot/Flame process. The UI
 * notification is asserted, but the behavioural verdict comes from the
 * flame's own deterministic frame log against a no-agent control.
 */
import { spawn, spawnSync } from "node:child_process";
import * as fs from "node:fs";
import * as path from "node:path";
import { test, expect } from "../../lib/fixtures";
import { LayoutPage } from "../../page-objects/layout-page";

const CODETRACER_REPO = path.resolve(__dirname, "../../../../..");
const WORKSPACE = path.dirname(CODETRACER_REPO);
const FLAME = process.env.CODETRACER_FLAME_DEMO_REPO ?? path.join(WORKSPACE, "codetracer-flame-demo");
const ENGINE = path.join(
  WORKSPACE,
  "codetracer-engine-godot",
  "bin",
  "godot.windows.template_debug.x86_64.hcrwin.exe",
);
const EXTENSION = path.join(FLAME, "bin", "flamefield.windows.template_debug.dll");
const EXTENSION_PDB = path.join(FLAME, "bin", "flamefield.windows.template_debug.pdb");
const APPLY_WORK = path.join(FLAME, "build", "hcr-windows-apply-edit");
const AGENT = path.join(APPLY_WORK, "agent", "repro_hcr_agent.dll");
const DRIVER = path.join(APPLY_WORK, "hcr_patch_driver_windows.exe");
const APPLY_EDIT = path.join(FLAME, "scripts", "ct_hcr_apply_edit.py");
const VERIFY = path.join(FLAME, "scripts", "verify_hcr2_flame_patch.py");
const WORK = path.join(FLAME, "build", "hcr-windows-gui-apply-edit");
const TICKS = path.join(WORK, "ticks-patched.log");
const CONTROL_TICKS = path.join(WORK, "ticks-control.log");
const PID_FILE = path.join(WORK, "target.pid");
const RELEASE = path.join(WORK, "patch.release");
const REPORT = path.join(WORK, "apply-edit-report.json");
const DRIVER_REPORT = path.join(WORK, "patch-result.json");
const FRAMES = 200;
const PATCH_AT = 60;
const EDIT = "rise_speed=5.4,retire_height=0.45";
const COMMAND_LABEL = "Apply Edit & Hot-Reload";
const PY_PROGRAM = "py_console_logs/main.py";

const required = [ENGINE, EXTENSION, EXTENSION_PDB, AGENT, DRIVER, APPLY_EDIT, VERIFY];
const unavailable =
  process.platform !== "win32"
    ? "the HWG-M6 GUI gate requires Windows"
    : required.find((candidate) => !fs.existsSync(candidate));

fs.mkdirSync(WORK, { recursive: true });
if (unavailable === undefined) {
  process.env.CODETRACER_HCR_APPLY_EDIT_CMD = APPLY_EDIT;
  process.env.CODETRACER_HCR_APPLY_EDIT_INTERPRETER = "python";
  process.env.CODETRACER_HCR_PLATFORM = "windows";
  process.env.CODETRACER_HCR_PID_FILE = PID_FILE;
  process.env.CODETRACER_HCR_DRIVER = DRIVER;
  process.env.CODETRACER_HCR_TARGET_IMAGE = EXTENSION;
  process.env.CODETRACER_HCR_TARGET_PDB = EXTENSION_PDB;
  process.env.CODETRACER_HCR_FIRST_INSTRUCTION_LENGTH = "2";
  process.env.CODETRACER_HCR_EDIT = EDIT;
  process.env.CODETRACER_HCR_WAIT_FOR = TICKS;
  process.env.CODETRACER_HCR_MARKER = `CT_H2 frame=${PATCH_AT} `;
  process.env.CODETRACER_HCR_MARKER_TIMEOUT_MS = "180000";
  process.env.CODETRACER_HCR_RELEASE_FILE = RELEASE;
  process.env.CODETRACER_HCR_REPORT = REPORT;
  delete process.env.CODETRACER_HCR_SOCKET;
  delete process.env.CODETRACER_HCR_SESSION_DIR;
}

interface RunResult {
  code: number | null;
  output: string;
  pid: number;
}

function runFlame(ticks: string, agent: boolean): { pid: number; done: Promise<RunResult> } {
  const env: NodeJS.ProcessEnv = {
    ...process.env,
    CT_H2_FRAMES: String(FRAMES),
    CT_H2_MAX_FPS: "60",
    CT_H2_TICKFILE: ticks,
  };
  delete env.CT_H2_CAPTURE;
  if (agent) {
    env.REPRO_HCR_AGENT_DLL = AGENT;
    env.CT_H2_PATCH_RELEASE_FILE = RELEASE;
    env.CT_H2_PATCH_HOLD_AFTER = String(PATCH_AT);
  } else {
    delete env.REPRO_HCR_AGENT_DLL;
    delete env.CT_H2_PATCH_RELEASE_FILE;
    delete env.CT_H2_PATCH_HOLD_AFTER;
  }
  const child = spawn(
    ENGINE,
    ["--headless", "--path", FLAME, "--scene", "res://scenes/hcr2_probe.tscn"],
    { cwd: FLAME, env },
  );
  let output = "";
  child.stdout.on("data", (chunk) => (output += chunk.toString()));
  child.stderr.on("data", (chunk) => (output += chunk.toString()));
  const done = new Promise<RunResult>((resolve, reject) => {
    const timer = setTimeout(() => {
      child.kill();
      reject(new Error(`Godot PID ${child.pid} did not finish ${FRAMES} frames`));
    }, 120_000);
    child.on("error", (error) => {
      clearTimeout(timer);
      reject(error);
    });
    child.on("close", (code) => {
      clearTimeout(timer);
      resolve({ code, output, pid: child.pid ?? 0 });
    });
  });
  return { pid: child.pid ?? 0, done };
}

async function waitForText(file: string, text: string, timeoutMs: number): Promise<void> {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    if (fs.existsSync(file) && fs.readFileSync(file, "utf8").includes(text)) return;
    await new Promise((resolve) => setTimeout(resolve, 50));
  }
  throw new Error(`timed out waiting for ${JSON.stringify(text)} in ${file}`);
}

async function paletteAction(ctPage: import("@playwright/test").Page) {
  await ctPage.keyboard.press("Control+KeyP");
  const input = ctPage.locator("#command-query-text");
  await expect(input).toBeVisible({ timeout: 15_000 });
  await input.fill(":Apply Edit");
  return ctPage
    .locator(".command-results .command-result.command-command")
    .filter({ hasText: COMMAND_LABEL })
    .first();
}

test.describe("HWG-M6 — Windows in-app apply edit", () => {
  test.setTimeout(600_000);
  test.use({ sourcePath: PY_PROGRAM, launchMode: "trace" });

  test("the command palette changes the running Windows flame", async ({ ctPage }) => {
    test.skip(unavailable !== undefined, `Windows HCR prerequisites are missing: ${unavailable}`);
    for (const artifact of [TICKS, CONTROL_TICKS, PID_FILE, RELEASE, REPORT, DRIVER_REPORT]) {
      fs.rmSync(artifact, { force: true });
    }

    const layout = new LayoutPage(ctPage);
    await layout.waitForAllComponentsLoaded();
    await layout.waitForTraceLoaded();

    const control = runFlame(CONTROL_TICKS, false);
    const controlResult = await control.done;
    expect(controlResult.code, controlResult.output.slice(-1000)).toBe(0);

    const patched = runFlame(TICKS, true);
    expect(patched.pid).toBeGreaterThan(0);
    fs.writeFileSync(PID_FILE, `${patched.pid}\n`);
    await waitForText(TICKS, "CT_H2_READY", 30_000);

    const hit = await paletteAction(ctPage);
    await expect(hit).toBeVisible({ timeout: 15_000 });
    await hit.click();
    await expect(
      ctPage.locator(".status-notification").filter({ hasText: "Apply Edit & Hot-Reload: applied" }),
    ).toBeVisible({ timeout: 180_000 });

    const patchedResult = await patched.done;
    expect(patchedResult.code, patchedResult.output.slice(-1000)).toBe(0);
    const report = JSON.parse(fs.readFileSync(REPORT, "utf8"));
    expect(report.status).toBe("applied");
    expect(report.platform).toBe("windows");
    expect(report.targetPid).toBe(patched.pid);
    expect(report.patchObject).toMatch(/\.obj$/);
    expect(report.publicationTier).toBe(2);

    const verdictPath = path.join(WORK, "verdict.json");
    const verdict = spawnSync(
      "python",
      [
        VERIFY,
        "--control", CONTROL_TICKS,
        "--patched", TICKS,
        "--patch-at", String(PATCH_AT),
        "--frames", String(FRAMES),
        "--mode", "inapp-gui-windows",
        "--expect", "change",
        "--live-ratio", "0.07:0.17",
        "--driver-json", DRIVER_REPORT,
        "--json-out", verdictPath,
      ],
      { cwd: FLAME, encoding: "utf8" },
    );
    expect(verdict.status, `${verdict.stdout}\n${verdict.stderr}`).toBe(0);
    const measured = JSON.parse(fs.readFileSync(verdictPath, "utf8"));
    expect(measured.firstDivergentFrame).toBeGreaterThan(PATCH_AT);
    expect(measured.firstDivergentFrame).toBeLessThanOrEqual(PATCH_AT + 10);
  });
});
