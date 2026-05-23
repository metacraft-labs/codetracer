import * as crypto from "node:crypto";
import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";
import { spawn, spawnSync, type ChildProcess } from "node:child_process";
import type { TestInfo } from "@playwright/test";

const REPO_ROOT = path.resolve(__dirname, "../../../../..");
const FIXTURE_SOURCE_ROOT = path.join(
  REPO_ROOT,
  "src",
  "db-backend",
  "test-programs",
  "reprobuild_hcr_in_codetracer",
);

export const PATCHABLE_FUNCTION = "reprobuild_hcr_patchable_value";
export const GEN0_BREAKPOINT = "REPROBUILD_HCR_GEN0_BREAKPOINT";
export const GEN0_STEP_START = "REPROBUILD_HCR_GEN0_STEP_START";
export const GEN0_STEP_NEXT = "REPROBUILD_HCR_GEN0_STEP_NEXT";
export const GEN1_BREAKPOINT = "REPROBUILD_HCR_GEN1_BREAKPOINT";
export const GEN1_STEP_START = "REPROBUILD_HCR_GEN1_STEP_START";
export const GEN1_STEP_NEXT = "REPROBUILD_HCR_GEN1_STEP_NEXT";

export interface HcrRunPaths {
  runRoot: string;
  projectDir: string;
  artifactsDir: string;
  socketPath: string;
  readyFile: string;
}

function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

function commandExists(command: string): boolean {
  if (command.includes(path.sep)) {
    return fs.existsSync(command);
  }
  const probe =
    process.platform === "win32"
      ? spawnSync("where", [command], { stdio: "ignore", windowsHide: true })
      : spawnSync("sh", ["-c", `command -v ${JSON.stringify(command)} >/dev/null 2>&1`], {
          stdio: "ignore",
        });
  return probe.status === 0;
}

function sha256(text: string): string {
  return crypto.createHash("sha256").update(text).digest("hex");
}

function readIfExists(filePath: string): string {
  return fs.existsSync(filePath) ? fs.readFileSync(filePath, "utf8") : "";
}

async function waitForProcessExit(
  proc: ChildProcess,
  timeoutMs: number,
): Promise<number | null> {
  if (proc.exitCode !== null) return proc.exitCode;

  return await new Promise<number | null>((resolve, reject) => {
    const timer = setTimeout(() => {
      cleanup();
      reject(new Error(`process ${proc.pid ?? "<unknown>"} did not exit in ${timeoutMs}ms`));
    }, timeoutMs);
    const cleanup = (): void => {
      clearTimeout(timer);
      proc.off("exit", onExit);
    };
    const onExit = (code: number | null): void => {
      cleanup();
      resolve(code);
    };
    proc.on("exit", onExit);
  });
}

export function createHcrRunPaths(): HcrRunPaths {
  const runRoot = fs.mkdtempSync(path.join(os.tmpdir(), "codetracer-hcr-gui-"));
  return {
    runRoot,
    projectDir: path.join(runRoot, "fixture"),
    artifactsDir: path.join(runRoot, "artifacts"),
    socketPath: path.join(runRoot, "hcr-agent.sock"),
    readyFile: path.join(runRoot, "target-ready"),
  };
}

export function exportHcrTargetEnv(paths: HcrRunPaths): void {
  process.env.REPRO_HCR_AGENT_SOCKET = paths.socketPath;
  process.env.RB_HCR_FIXTURE_READY_FILE = paths.readyFile;
  process.env.RB_HCR_FIXTURE_ITERATIONS =
    process.env.RB_HCR_FIXTURE_ITERATIONS ?? "1000";
}

export function clearHcrTargetEnv(): void {
  delete process.env.REPRO_HCR_AGENT_SOCKET;
  delete process.env.RB_HCR_FIXTURE_READY_FILE;
  delete process.env.RB_HCR_FIXTURE_ITERATIONS;
}

export class HcrFixtureDriver {
  readonly paths: HcrRunPaths;
  private reproProcess: ChildProcess | null = null;
  private reproLogStream: fs.WriteStream | null = null;

  constructor(paths: HcrRunPaths) {
    this.paths = paths;
  }

  get coordinatorLogPath(): string {
    return path.join(this.paths.artifactsDir, "repro-watch.log");
  }

  get coordinatorReportPath(): string {
    return path.join(this.paths.artifactsDir, "hcr-coordinator-report.json");
  }

  get patchBundleMetadataPath(): string {
    return path.join(this.paths.artifactsDir, "patch-bundle-metadata.json");
  }

  get binaryPath(): string {
    return path.join(this.paths.projectDir, "build", "hcr_target");
  }

  get patchableSourcePath(): string {
    return path.join(this.paths.projectDir, "src", "patchable.c");
  }

  get generationOneSourcePath(): string {
    return path.join(this.paths.projectDir, "generations", "patchable_gen1.c");
  }

  get generationZeroSnapshotPath(): string {
    return path.join(this.paths.artifactsDir, "source-generation0-patchable.c");
  }

  get generationOneSnapshotPath(): string {
    return path.join(this.paths.artifactsDir, "source-generation1-patchable.c");
  }

  static checkPrerequisites(): string[] {
    const missing: string[] = [];
    if (!fs.existsSync(FIXTURE_SOURCE_ROOT)) {
      missing.push(`missing HCR fixture: ${FIXTURE_SOURCE_ROOT}`);
    }
    const repro = process.env.CODETRACER_REPROBUILD_REPRO ?? "repro";
    if (!commandExists(repro)) {
      missing.push(`missing repro command: ${repro}`);
    }
    const reprobuildRoot =
      process.env.REPROBUILD_SOURCE_ROOT ?? path.resolve(REPO_ROOT, "..", "reprobuild");
    if (!fs.existsSync(path.join(reprobuildRoot, "libs", "repro_hcr_agent", "c"))) {
      missing.push(`REPROBUILD_SOURCE_ROOT does not point at reprobuild: ${reprobuildRoot}`);
    }
    return missing;
  }

  prepareProject(): void {
    fs.mkdirSync(this.paths.runRoot, { recursive: true });
    fs.mkdirSync(this.paths.artifactsDir, { recursive: true });
    fs.rmSync(this.paths.projectDir, { force: true, recursive: true });
    fs.cpSync(FIXTURE_SOURCE_ROOT, this.paths.projectDir, { recursive: true });
    fs.copyFileSync(this.patchableSourcePath, this.generationZeroSnapshotPath);
  }

  startReproWatch(): void {
    if (this.reproProcess !== null) {
      throw new Error("repro watch is already running");
    }

    fs.rmSync(this.paths.socketPath, { force: true });
    fs.mkdirSync(this.paths.artifactsDir, { recursive: true });
    const repro = process.env.CODETRACER_REPROBUILD_REPRO ?? "repro";
    const targetArg = `${this.paths.projectDir}#hcr-target`;
    const args = [
      "watch",
      targetArg,
      "--tool-provisioning=path",
      "--max-cycles=2",
      "--debounce-ms=100",
      `--hcr-agent-socket=${this.paths.socketPath}`,
      `--hcr-artifacts=${this.paths.artifactsDir}`,
      "--hcr-metadata=build/hcr-fixture-metadata.json",
    ];

    this.reproLogStream = fs.createWriteStream(this.coordinatorLogPath, {
      flags: "w",
    });
    const proc = spawn(repro, args, {
      cwd: this.paths.projectDir,
      detached: process.platform !== "win32",
      env: {
        ...process.env,
        REPROBUILD_SOURCE_ROOT:
          process.env.REPROBUILD_SOURCE_ROOT ?? path.resolve(REPO_ROOT, "..", "reprobuild"),
      },
      stdio: ["ignore", "pipe", "pipe"],
      windowsHide: true,
    });
    this.reproProcess = proc;
    proc.stdout?.pipe(this.reproLogStream);
    proc.stderr?.pipe(this.reproLogStream);
  }

  async waitForInitialBuild(): Promise<void> {
    await this.waitForLogContains(
      "repro watch: cycle 1 result exitCode=0",
      "initial repro watch build",
      60_000,
    );
    if (!fs.existsSync(this.binaryPath)) {
      throw new Error(`initial build did not produce ${this.binaryPath}`);
    }
  }

  async waitForAgentConnected(): Promise<void> {
    await this.waitForLogContains(
      "repro watch: hcr agent connected",
      "HCR agent connection",
      60_000,
    );
  }

  applyGenerationOneEdit(): void {
    const nextSource = fs.readFileSync(this.generationOneSourcePath, "utf8");
    fs.writeFileSync(this.patchableSourcePath, nextSource, "utf8");
    fs.writeFileSync(
      path.join(this.paths.projectDir, "build", "source-generation-1.sha256"),
      `${sha256(nextSource)}  ${this.patchableSourcePath}\n`,
      "utf8",
    );
    fs.copyFileSync(this.patchableSourcePath, this.generationOneSnapshotPath);
  }

  async waitForPatchApplied(): Promise<void> {
    await this.waitForLogContains(
      "repro watch: cycle 2 result exitCode=0",
      "repro watch rebuild",
      60_000,
    );
    await this.waitForFile(this.coordinatorReportPath, "HCR coordinator report", 30_000);
    const report = JSON.parse(fs.readFileSync(this.coordinatorReportPath, "utf8"));
    if (!report.patchApplied) {
      throw new Error(
        `coordinator report did not contain patchApplied: ${JSON.stringify(report)}`,
      );
    }
  }

  lineForMarker(snapshotPath: string, marker: string): number {
    const lines = fs.readFileSync(snapshotPath, "utf8").split(/\r?\n/);
    const index = lines.findIndex((line) => line.includes(marker));
    if (index < 0) {
      throw new Error(`marker ${marker} not found in ${snapshotPath}`);
    }
    return index + 1;
  }

  async stop(): Promise<void> {
    const proc = this.reproProcess;
    if (proc !== null && proc.exitCode === null) {
      try {
        if (process.platform !== "win32" && proc.pid) {
          process.kill(-proc.pid, "SIGTERM");
        } else {
          proc.kill("SIGTERM");
        }
      } catch {
        // already gone
      }
      try {
        await waitForProcessExit(proc, 2_000);
      } catch {
        try {
          if (process.platform !== "win32" && proc.pid) {
            process.kill(-proc.pid, "SIGKILL");
          } else {
            proc.kill("SIGKILL");
          }
        } catch {
          // already gone
        }
      }
    }
    this.reproProcess = null;
    this.reproLogStream?.end();
    this.reproLogStream = null;
  }

  async attachArtifacts(testInfo: TestInfo): Promise<void> {
    const artifactPaths = [
      this.coordinatorLogPath,
      this.coordinatorReportPath,
      this.patchBundleMetadataPath,
      this.generationZeroSnapshotPath,
      this.generationOneSnapshotPath,
      path.join(this.paths.projectDir, "build", "source-generation-1.sha256"),
    ];
    for (const filePath of artifactPaths) {
      if (!fs.existsSync(filePath)) continue;
      await testInfo.attach(path.basename(filePath), {
        body: fs.readFileSync(filePath),
        contentType: filePath.endsWith(".json") ? "application/json" : "text/plain",
      });
    }
  }

  private async waitForFile(
    filePath: string,
    description: string,
    timeoutMs: number,
  ): Promise<void> {
    const deadline = Date.now() + timeoutMs;
    while (Date.now() < deadline) {
      if (fs.existsSync(filePath)) return;
      await this.throwIfReproExited(description);
      await sleep(100);
    }
    throw new Error(`${description} was not created at ${filePath}`);
  }

  private async waitForLogContains(
    needle: string,
    description: string,
    timeoutMs: number,
  ): Promise<void> {
    const deadline = Date.now() + timeoutMs;
    while (Date.now() < deadline) {
      if (readIfExists(this.coordinatorLogPath).includes(needle)) return;
      await this.throwIfReproExited(description);
      await sleep(100);
    }
    throw new Error(
      `${description} timed out waiting for '${needle}' in ${this.coordinatorLogPath}\n` +
        readIfExists(this.coordinatorLogPath),
    );
  }

  private async throwIfReproExited(context: string): Promise<void> {
    if (this.reproProcess === null) return;
    if (this.reproProcess.exitCode !== null) {
      throw new Error(
        `repro watch exited during ${context} with code ${this.reproProcess.exitCode}\n` +
          readIfExists(this.coordinatorLogPath),
      );
    }
  }
}
