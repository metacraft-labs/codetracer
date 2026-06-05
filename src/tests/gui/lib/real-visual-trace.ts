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

interface SoftwareGlConfig {
  enabled: boolean;
  env: Record<string, string>;
  checkpointIntervalMs: number;
}

/**
 * Resolve the Mesa software-GL configuration for the visual-replay fixture.
 *
 * Opt-in via ``CODETRACER_VISUAL_REPLAY_SOFTWARE_GL=1`` (typically set in
 * the project's ``.env`` so direnv loads it).  When unset (the default on
 * any GPU-equipped host), this returns ``enabled: false`` and the harness
 * runs unchanged — there is NO automatic forcing of software rendering,
 * so real-GPU coverage is never silently lost.
 *
 * When opt-in, the user must also point ``CODETRACER_MESA_ROOT`` at a
 * Mesa derivation (e.g. the active nix-store path).  We derive the four
 * standard Mesa env vars (``LIBGL_DRIVERS_PATH``, ``LD_LIBRARY_PATH``,
 * ``__EGL_VENDOR_LIBRARY_DIRS``, ``EGL_PLATFORM=surfaceless``) from that
 * root and inject them into ct_cli + gl_scene subprocess spawns.  An
 * explicit override of any individual variable in the environment still
 * wins (last-write-wins semantics, no surprise overwrites).
 *
 * Software shader execution generates an order of magnitude more events
 * than hardware-rendered scenes, so the recorder's ring buffer overflows
 * with the default checkpoint interval.  When opt-in we also add
 * ``--checkpoint-interval <ms>`` (250 ms is enough headroom for the
 * gl_scene fixture per local validation) to keep the recorder under
 * its trace-writer budget.
 *
 * See ``.env.example`` for the documented opt-in template.
 */
function resolveSoftwareGlConfig(): SoftwareGlConfig {
  const enabled = isTruthy(process.env.CODETRACER_VISUAL_REPLAY_SOFTWARE_GL);
  if (!enabled) {
    return { enabled: false, env: {}, checkpointIntervalMs: 0 };
  }
  const mesaRoot = process.env.CODETRACER_MESA_ROOT?.trim() ?? "";
  if (mesaRoot.length === 0) {
    throw new Error(
      `CODETRACER_VISUAL_REPLAY_SOFTWARE_GL is enabled but CODETRACER_MESA_ROOT is not set.\n`
      + `Set CODETRACER_MESA_ROOT to a Mesa derivation (e.g. /nix/store/<hash>-mesa-X.Y.Z) `
      + `in .env so the harness can derive LIBGL_DRIVERS_PATH, LD_LIBRARY_PATH, and `
      + `__EGL_VENDOR_LIBRARY_DIRS.  See .env.example for the template.`,
    );
  }
  const driversPath = path.join(mesaRoot, "lib", "dri");
  const libPath = path.join(mesaRoot, "lib");
  const vendorDir = path.join(mesaRoot, "share", "glvnd", "egl_vendor.d");
  for (const required of [driversPath, libPath, vendorDir]) {
    if (!fs.existsSync(required)) {
      throw new Error(
        `CODETRACER_MESA_ROOT=${mesaRoot} does not look like a Mesa derivation.\n`
        + `Missing expected directory: ${required}\n`
        + `Hint: run \`ls /nix/store/ | grep '^[a-z0-9]\\{32\\}-mesa-'\` to find the right path.`,
      );
    }
  }
  const env: Record<string, string> = {
    LIBGL_ALWAYS_SOFTWARE: process.env.LIBGL_ALWAYS_SOFTWARE ?? "1",
    EGL_PLATFORM: process.env.EGL_PLATFORM ?? "surfaceless",
    LIBGL_DRIVERS_PATH: process.env.LIBGL_DRIVERS_PATH ?? driversPath,
    __EGL_VENDOR_LIBRARY_DIRS:
      process.env.__EGL_VENDOR_LIBRARY_DIRS ?? vendorDir,
  };
  // LD_LIBRARY_PATH must be prepended, not overwritten — other libraries
  // may already be on the path (e.g. test fixtures linking against
  // sibling artifacts).
  const existingLdPath = process.env.LD_LIBRARY_PATH ?? "";
  env.LD_LIBRARY_PATH = existingLdPath.split(":").includes(libPath)
    ? existingLdPath
    : (existingLdPath.length > 0 ? `${libPath}:${existingLdPath}` : libPath);
  const intervalRaw = process.env.CODETRACER_VISUAL_REPLAY_RECORDER_CHECKPOINT_MS;
  const checkpointIntervalMs = intervalRaw && intervalRaw.length > 0
    ? Number(intervalRaw)
    : 250;
  if (Number.isNaN(checkpointIntervalMs) || checkpointIntervalMs <= 0) {
    throw new Error(
      `CODETRACER_VISUAL_REPLAY_RECORDER_CHECKPOINT_MS must be a positive number, got: ${intervalRaw}`,
    );
  }
  return { enabled: true, env, checkpointIntervalMs };
}

function isTruthy(value: string | undefined): boolean {
  if (value === undefined) return false;
  const trimmed = value.trim().toLowerCase();
  return trimmed === "1" || trimmed === "true" || trimmed === "yes" || trimmed === "on";
}

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
  // Propagate the software-GL env to subsequent process spawns
  // (Electron → ct_gfx_player).  ``configureVisualReplayToolEnv`` is the
  // last surface that touches process.env before the Playwright runner
  // launches Electron, so mutating it here is sufficient for the player
  // to inherit Mesa's surfaceless EGL configuration.  On GPU hosts (opt-in
  // unset) this is a no-op.
  const softwareGl = resolveSoftwareGlConfig();
  if (softwareGl.enabled) {
    for (const [key, value] of Object.entries(softwareGl.env)) {
      if (process.env[key] === undefined) {
        process.env[key] = value;
      }
    }
  }
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
  const softwareGl = resolveSoftwareGlConfig();
  // Software shader execution generates far more memcpy/syscall events
  // than hardware rendering, which overflows the trace-writer ring buffer
  // unless the recorder checkpoints often.  Only inject the extra flag
  // when the software-GL opt-in is active so GPU hosts keep their
  // current, unchanged recording profile.
  const ctMcrArgs = softwareGl.enabled
    ? ["record", "--use-interpose", "--checkpoint-interval", String(softwareGl.checkpointIntervalMs), "-o", tracePath, "--", glScene, frameOutputBase]
    : ["record", "--use-interpose", "-o", tracePath, "--", glScene, frameOutputBase];
  const args = ctMcrArgs;
  const timeoutMs = Number(process.env.CODETRACER_REAL_VISUAL_TRACE_RECORD_TIMEOUT_MS ?? "180000");

  if (softwareGl.enabled) {
    console.log(
      `# software-GL opt-in active (CODETRACER_VISUAL_REPLAY_SOFTWARE_GL=1); `
      + `injecting Mesa env + checkpoint-interval=${softwareGl.checkpointIntervalMs}ms`,
    );
  }
  console.log(`# recording fallback visual trace: ${tracePath}`);
  const result = childProcess.spawnSync(ctMcr, args, {
    encoding: "utf-8",
    env: {
      ...process.env,
      LIBGL_ALWAYS_SOFTWARE: process.env.LIBGL_ALWAYS_SOFTWARE ?? "1",
      LP_NUM_THREADS: process.env.LP_NUM_THREADS ?? "1",
      ...softwareGl.env,
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
