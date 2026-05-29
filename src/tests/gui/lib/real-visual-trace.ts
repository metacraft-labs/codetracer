import * as childProcess from "node:child_process";
import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";

interface RealVisualTrace {
  tracePath: string;
  recordedFallback: boolean;
  tempRoot?: string;
  cleanupRegistered?: boolean;
}

type GlobalWithRealVisualTrace = typeof globalThis & {
  __codetracerRealVisualTrace?: RealVisualTrace;
};

const repoRoot = path.resolve(__dirname, "..", "..", "..", "..");
const workspaceRoot = path.dirname(repoRoot);

const visualReplayRepo = process.env.VISUAL_REPLAY_REPO
  ?? path.join(workspaceRoot, "codetracer-visual-replay");
const nativeRecorderRepo = process.env.NATIVE_RECORDER_REPO
  ?? path.join(workspaceRoot, "codetracer-native-recorder");
const nativeTestProgramsRepo = process.env.NATIVE_TEST_PROGRAMS_REPO
  ?? path.join(workspaceRoot, "codetracer-native-test-programs");

const ctMcr = process.env.CODETRACER_CT_MCR_CMD
  ?? path.join(nativeRecorderRepo, "ct_cli", "ct_cli");
const gfxPlayer = process.env.CODETRACER_CT_GFX_PLAYER_CMD
  ?? path.join(visualReplayRepo, "ct_gfx_player");
const ctNativeReplay = process.env.CODETRACER_CT_NATIVE_REPLAY_CMD
  ?? path.join(visualReplayRepo, "ct-native-replay");
const glScene = path.join(nativeTestProgramsRepo, "gl", "gl_scene");
const glSceneSource = `${glScene}.c`;
const requiredGfxArtifacts = [
  "gfx_commands.dat",
  "gfx_bulkdata.dat",
  "gfx_commands.idx",
  "gfx_frames.idx",
];

function isExecutable(filePath: string): boolean {
  try {
    fs.accessSync(filePath, fs.constants.X_OK);
    return true;
  } catch {
    return false;
  }
}

function requireExecutable(filePath: string, description: string, action: string): void {
  if (!isExecutable(filePath)) {
    throw new Error(
      `Missing executable ${description}: ${filePath}\n${action}`,
    );
  }
}

function requireCtTrace(tracePath: string): string {
  const resolvedTracePath = path.resolve(tracePath);
  if (!fs.existsSync(resolvedTracePath)) {
    throw new Error(
      `CODETRACER_REAL_VISUAL_TRACE must point to an existing recorded .ct trace.\n`
      + `Missing path: ${resolvedTracePath}`,
    );
  }
  if (path.extname(resolvedTracePath) !== ".ct") {
    throw new Error(
      `CODETRACER_REAL_VISUAL_TRACE must point to a recorded .ct trace.\n`
      + `Path does not end in .ct: ${resolvedTracePath}`,
    );
  }
  return resolvedTracePath;
}

function buildGlSceneFixtureIfNeeded(): void {
  if (isExecutable(glScene)) {
    return;
  }

  if (!fs.existsSync(glSceneSource)) {
    requireExecutable(
      glScene,
      "GL scene fixture",
      "Set CODETRACER_REAL_VISUAL_TRACE to an existing visual .ct trace or build codetracer-native-test-programs.",
    );
  }

  const glDir = path.dirname(glScene);
  const args = ["-o", path.basename(glScene), path.basename(glSceneSource), "-lEGL", "-lGLESv2", "-lm"];
  console.log(`# building fallback GL scene fixture: ${formatCommand("cc", args)}`);
  const result = childProcess.spawnSync("cc", args, {
    cwd: glDir,
    encoding: "utf-8",
    maxBuffer: 20 * 1024 * 1024,
  });

  if (result.error) {
    throw new Error(
      `Failed to build fallback GL scene fixture.\n`
      + `Command: ${formatCommand("cc", args)}\n`
      + `Working directory: ${glDir}\n`
      + `Error: ${result.error.message}`,
    );
  }
  if (result.status !== 0) {
    throw new Error(
      `Failed to build fallback GL scene fixture; compiler exited with status ${result.status}.\n`
      + `Command: ${formatCommand("cc", args)}\n`
      + `Working directory: ${glDir}\n`
      + `stdout:\n${compactOutput(result.stdout)}\n`
      + `stderr:\n${compactOutput(result.stderr)}`,
    );
  }
  if (!fs.existsSync(glScene)) {
    throw new Error(
      `GL scene fixture build completed but did not create the expected binary.\n`
      + `Expected path: ${glScene}\n`
      + `Command: ${formatCommand("cc", args)}\n`
      + `Working directory: ${glDir}`,
    );
  }

  fs.chmodSync(glScene, fs.statSync(glScene).mode | 0o111);
  requireExecutable(
    glScene,
    "GL scene fixture",
    `Compiler produced a non-executable binary at ${glScene}.`,
  );
}

function extractGfxStreamForAvailability(tracePath: string, tempRoot: string): void {
  const gfxStreamDir = path.join(tempRoot, "gfx_stream");
  const args = ["extract-gfx", "--ctfs-visual-streams", "-o", gfxStreamDir, tracePath];

  console.log(`# extracting fallback visual replay stream: ${gfxStreamDir}`);
  const result = childProcess.spawnSync(ctMcr, args, {
    encoding: "utf-8",
    maxBuffer: 20 * 1024 * 1024,
  });

  if (result.error) {
    throw new Error(
      `Failed to extract fallback visual replay stream.\n`
      + `Command: ${formatCommand(ctMcr, args)}\n`
      + `Error: ${result.error.message}`,
    );
  }
  if (result.status !== 0) {
    throw new Error(
      `Failed to extract fallback visual replay stream; MCR exited with status ${result.status}.\n`
      + `Command: ${formatCommand(ctMcr, args)}\n`
      + `stdout:\n${compactOutput(result.stdout)}\n`
      + `stderr:\n${compactOutput(result.stderr)}`,
    );
  }

  const missingArtifacts = requiredGfxArtifacts.filter(
    (artifact) => !fs.existsSync(path.join(gfxStreamDir, artifact)),
  );
  if (missingArtifacts.length > 0) {
    throw new Error(
      `Fallback visual replay stream extraction completed but did not create required artifacts.\n`
      + `Missing: ${missingArtifacts.join(", ")}\n`
      + `Output directory: ${gfxStreamDir}\n`
      + `Command: ${formatCommand(ctMcr, args)}`,
    );
  }

  const ctfsSidecar = `${gfxStreamDir}.ctfs`;
  if (!fs.existsSync(ctfsSidecar)) {
    throw new Error(
      `Fallback visual replay stream extraction completed but did not create the CTFS visual sidecar.\n`
      + `Missing: ${ctfsSidecar}\n`
      + `Command: ${formatCommand(ctMcr, args)}`,
    );
  }
}

function stageTraceWithExtractedGfxStream(tracePath: string): RealVisualTrace {
  const tempRoot = fs.mkdtempSync(path.join(os.tmpdir(), "ct-real-visual-trace-"));
  const stagedTracePath = path.join(tempRoot, "trace.ct");

  try {
    fs.copyFileSync(tracePath, stagedTracePath);
    extractGfxStreamForAvailability(stagedTracePath, tempRoot);
    return { tracePath: stagedTracePath, recordedFallback: false, tempRoot };
  } catch (ex) {
    fs.rmSync(tempRoot, { recursive: true, force: true });
    throw ex;
  }
}

function parseGeneratedEnvFile(envFile: string): Record<string, string> {
  const values: Record<string, string> = {};
  if (!fs.existsSync(envFile)) {
    return values;
  }

  for (const rawLine of fs.readFileSync(envFile, "utf-8").split(/\r?\n/)) {
    const line = rawLine.trim();
    if (!line.startsWith("export ")) {
      continue;
    }
    const assignment = line.slice("export ".length);
    const separator = assignment.indexOf("=");
    if (separator < 1) {
      continue;
    }
    const name = assignment.slice(0, separator);
    let value = assignment.slice(separator + 1);
    if (
      value.length >= 2
      && value.startsWith("'")
      && value.endsWith("'")
    ) {
      value = value.slice(1, -1);
    }
    values[name] = value;
  }

  return values;
}

function configureVisualReplayTestLicense(tempRoot: string): void {
  requireExecutable(
    ctNativeReplay,
    "visual replay license helper",
    "Set CODETRACER_CT_NATIVE_REPLAY_CMD or build codetracer-visual-replay.",
  );

  const licenseFile = path.join(tempRoot, "visual-replay-test.license.dat");
  const envFile = path.join(tempRoot, "visual-replay-test.env");
  const args = [
    "license",
    "generate-visual-replay-test-license",
    "--license-file",
    licenseFile,
    "--env-file",
    envFile,
  ];

  console.log(`# generating visual replay test license: ${licenseFile}`);
  const result = childProcess.spawnSync(ctNativeReplay, args, {
    encoding: "utf-8",
    maxBuffer: 20 * 1024 * 1024,
  });

  if (result.error) {
    throw new Error(
      `Failed to generate visual replay test license.\n`
      + `Command: ${formatCommand(ctNativeReplay, args)}\n`
      + `Error: ${result.error.message}`,
    );
  }
  if (result.status !== 0) {
    throw new Error(
      `Failed to generate visual replay test license; helper exited with status ${result.status}.\n`
      + `Command: ${formatCommand(ctNativeReplay, args)}\n`
      + `stdout:\n${compactOutput(result.stdout)}\n`
      + `stderr:\n${compactOutput(result.stderr)}`,
    );
  }
  if (!fs.existsSync(licenseFile)) {
    throw new Error(
      `Visual replay test license generation completed but did not create a license file.\n`
      + `Expected path: ${licenseFile}\n`
      + `Command: ${formatCommand(ctNativeReplay, args)}`,
    );
  }

  const generatedEnv = parseGeneratedEnvFile(envFile);
  process.env.CODETRACER_LICENSE_FILE =
    generatedEnv.CODETRACER_LICENSE_FILE ?? licenseFile;
  if (generatedEnv.CODETRACER_DEV_LICENSE_VERIFYING_KEY_BASE64) {
    process.env.CODETRACER_DEV_LICENSE_VERIFYING_KEY_BASE64 =
      generatedEnv.CODETRACER_DEV_LICENSE_VERIFYING_KEY_BASE64;
  }
}

function configureVisualReplayToolEnv(visualTrace: RealVisualTrace): void {
  requireExecutable(
    ctMcr,
    "MCR command",
    "Set CODETRACER_CT_MCR_CMD or build codetracer-native-recorder.",
  );
  requireExecutable(
    gfxPlayer,
    "visual replay player",
    "Set CODETRACER_CT_GFX_PLAYER_CMD or build codetracer-visual-replay.",
  );
  process.env.CODETRACER_CT_MCR_CMD = ctMcr;
  process.env.CODETRACER_CT_GFX_PLAYER_CMD = gfxPlayer;
  process.env.CODETRACER_CT_GFX_PLAYER_BACKEND ??= "software";
  if (visualTrace.tempRoot) {
    configureVisualReplayTestLicense(visualTrace.tempRoot);
  }
}

function formatCommand(command: string, args: string[]): string {
  return [command, ...args].map((part) => JSON.stringify(part)).join(" ");
}

function compactOutput(output: string | undefined): string {
  const text = output?.trim() ?? "";
  if (text.length <= 4_000) {
    return text;
  }
  return `${text.slice(0, 1_500)}\n...\n${text.slice(-2_500)}`;
}

function recordGlFixtureTrace(): RealVisualTrace {
  requireExecutable(
    ctMcr,
    "MCR command",
    "Set CODETRACER_CT_MCR_CMD or build codetracer-native-recorder.",
  );
  requireExecutable(
    gfxPlayer,
    "visual replay player",
    "Set CODETRACER_CT_GFX_PLAYER_CMD or build codetracer-visual-replay.",
  );
  buildGlSceneFixtureIfNeeded();

  const tempRoot = fs.mkdtempSync(path.join(os.tmpdir(), "ct-real-visual-trace-"));
  const tracePath = path.join(tempRoot, "trace.ct");
  const frameOutputBase = path.join(tempRoot, "gl_scene");
  const args = ["record", "--use-interpose", "-o", tracePath, "--", glScene, frameOutputBase];
  const timeoutMs = Number(process.env.CODETRACER_REAL_VISUAL_TRACE_RECORD_TIMEOUT_MS ?? "180000");

  console.log(`# recording fallback visual trace: ${tracePath}`);
  const result = childProcess.spawnSync(ctMcr, args, {
    encoding: "utf-8",
    env: {
      ...process.env,
      LIBGL_ALWAYS_SOFTWARE: process.env.LIBGL_ALWAYS_SOFTWARE ?? "1",
      LP_NUM_THREADS: process.env.LP_NUM_THREADS ?? "1",
    },
    maxBuffer: 20 * 1024 * 1024,
    timeout: timeoutMs,
  });

  if (result.error) {
    fs.rmSync(tempRoot, { recursive: true, force: true });
    throw new Error(
      `Failed to record fallback visual trace.\n`
      + `Command: ${formatCommand(ctMcr, args)}\n`
      + `Error: ${result.error.message}`,
    );
  }
  if (result.status !== 0) {
    fs.rmSync(tempRoot, { recursive: true, force: true });
    throw new Error(
      `Failed to record fallback visual trace; MCR exited with status ${result.status}.\n`
      + `Command: ${formatCommand(ctMcr, args)}\n`
      + `stdout:\n${compactOutput(result.stdout)}\n`
      + `stderr:\n${compactOutput(result.stderr)}`,
    );
  }
  if (!fs.existsSync(tracePath)) {
    fs.rmSync(tempRoot, { recursive: true, force: true });
    throw new Error(
      `MCR recording completed but did not create the expected .ct trace.\n`
      + `Expected path: ${tracePath}\n`
      + `Command: ${formatCommand(ctMcr, args)}`,
    );
  }

  try {
    extractGfxStreamForAvailability(tracePath, tempRoot);
    process.env.CODETRACER_REAL_VISUAL_TRACE = tracePath;
    return { tracePath, recordedFallback: true, tempRoot };
  } catch (ex) {
    fs.rmSync(tempRoot, { recursive: true, force: true });
    throw ex;
  }
}

function resolveRealVisualTrace(): RealVisualTrace {
  const configuredTracePath = process.env.CODETRACER_REAL_VISUAL_TRACE?.trim() ?? "";
  if (configuredTracePath) {
    const tracePath = requireCtTrace(configuredTracePath);
    const visualTrace = stageTraceWithExtractedGfxStream(tracePath);
    configureVisualReplayToolEnv(visualTrace);
    return visualTrace;
  }

  const visualTrace = recordGlFixtureTrace();
  configureVisualReplayToolEnv(visualTrace);
  return visualTrace;
}

export function resolveRealVisualTracePath(): string {
  const globalState = globalThis as GlobalWithRealVisualTrace;
  globalState.__codetracerRealVisualTrace ??= resolveRealVisualTrace();

  if (
    globalState.__codetracerRealVisualTrace.tempRoot
    && !globalState.__codetracerRealVisualTrace.cleanupRegistered
  ) {
    const tempRoot = globalState.__codetracerRealVisualTrace.tempRoot;
    globalState.__codetracerRealVisualTrace.cleanupRegistered = true;
    process.once("exit", () => {
      if (tempRoot) {
        fs.rmSync(tempRoot, { recursive: true, force: true });
      }
    });
  }

  return globalState.__codetracerRealVisualTrace.tracePath;
}
