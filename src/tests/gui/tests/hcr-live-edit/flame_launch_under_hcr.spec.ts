/**
 * `e2e_codetracer_launches_flame_under_hcr` — CODETRACER starts the program.
 *
 * Milestone: `codetracer-specs/Marketing/Home-Demo-Screencast.milestones.org`, H6.
 * Authority:  `Marketing/The-Flame-Demo-Spec.md` §2.5 — "CodeTracer launches the
 *             flame client… attaching to a flame that is already running is
 *             explicitly out of scope."
 *
 * WHAT THIS ADDS TO H5, which already proved the loop. H5's gate measures three
 * edits reshaping one running flame, and that verdict is SILENT ON WHO STARTED
 * THE FLAME — it is satisfied exactly as well by the shell harness starting the
 * coordinator and the engine. This gate is about the other half: the product
 * reads the project's own `.vscode/launch.json` and follows the transport's
 * required order. Linux is coordinator-first; Windows is target-first because
 * its agent owns a named pipe derived from the new target PID.
 *
 * THE ORDER IS THE FEATURE, not an implementation detail. On Linux the
 * in-target agent dials OUT once at process start, so its coordinator must
 * already be listening. On Windows the agent owns a named pipe derived from
 * the new target PID, so CodeTracer must start the target first and give that
 * PID to the coordinator.
 *
 * HOW IT DISTINGUISHES "CODETRACER LAUNCHED IT" FROM "SOMETHING LAUNCHED IT".
 * Three witnesses, and the second is the one the product cannot author:
 *
 *   1. the product's own launch record (`hcr-launch.json`) naming its pid, the
 *      coordinator's pid, the target's pid and the two timestamps;
 *   2. an OS process-table sample taken while the target was ALIVE: the target's
 *      parent is the launcher, the launcher is a DESCENDANT of this test
 *      process, and the launcher is NOT this test process;
 *   3. the coordinator's own `session.json`, so the session described is the
 *      session that served the patches.
 *
 * Falsifier arm `harness-launches` is the arm those exist for: it reproduces
 * H5's arrangement exactly — the harness starts the coordinator and the flame,
 * the panel publishes three edits, every session signal fires and the flame
 * reshapes — and this gate must still refuse to call it a pass.
 *
 * ARMS. `CT_H6_ARM` selects one; the default is `green`. Every arm writes
 * `observations.json`, and `scripts/hcr6_discrimination_matrix.py` in the flame
 * demo grades the SET of them: each arm must satisfy its own expectation and
 * must FAIL every other arm's, which is what "these arms discriminate" means
 * and is not something a single run can show.
 *
 * IT DOES NOT SKIP. A missing prerequisite fails the test by name. A gate that
 * returns early when its subject is absent is counted as passed, which is the
 * whole subject of `Testing/Silent-Self-Pass-Audit-2026-08-23.md`.
 *
 * The independent parentage witness is procfs on Linux and Win32_Process CIM
 * on Windows. It is never replaced by the product's own launch record.
 */
import { spawn, spawnSync, type ChildProcess } from "node:child_process";
import * as crypto from "node:crypto";
import * as fs from "node:fs";
import * as path from "node:path";
import { test, expect } from "../../lib/fixtures";
import {
  resolveFlamePaths,
  waitForFile,
  type FlamePaths,
} from "../hcr-apply-edit/flame-hcr-driver";

const CODETRACER_REPO = path.resolve(__dirname, "../../../../..");
const WORKSPACE = path.dirname(CODETRACER_REPO);
const IS_WINDOWS = process.platform === "win32";
const PYTHON = IS_WINDOWS ? "python" : "python3";

type Arm =
  | "green"
  | "no-hcr-block"
  | "harness-launches"
  | "coordinator-not-a-coordinator"
  | "target-exits-immediately"
  | "agent-never-dials";

const ARM = (process.env.CT_H6_ARM ?? "green") as Arm;
const KNOWN_ARMS: Arm[] = [
  "green",
  "no-hcr-block",
  "harness-launches",
  "coordinator-not-a-coordinator",
  "target-exits-immediately",
  "agent-never-dials",
];
if (!KNOWN_ARMS.includes(ARM)) {
  throw new Error(`unknown CT_H6_ARM=${ARM}; one of ${KNOWN_ARMS.join(", ")}`);
}
/** Arms in which a session is expected to open and edits are expected to land. */
const ARM_EDITS_THREE = ARM === "green" || ARM === "harness-launches";

/**
 * The three edits, and the bands they predict — H5's table, unchanged.
 *
 * Steady population goes as `1/rise_speed`, every term read out of
 * `advanceExisting()`'s own source. The bands are DISJOINT and the flame
 * verdict refuses a table whose bands overlap: "the flame moved" cannot tell
 * one edit from another.
 */
const ARMS_TABLE = [
  { edit: "rise_speed=2.7", predicted: 0.6667, band: "0.61:0.73" },
  { edit: "rise_speed=5.4", predicted: 0.3333, band: "0.28:0.38" },
  { edit: "rise_speed=9.0", predicted: 0.2, band: "0.16:0.24" },
];
const FRAMES = 2400;
const FIRST_EDIT_AT = 120;
const SETTLE = 60;
const PLATEAU = 120;

// ---------------------------------------------------------------------------
// Prerequisites — resolved at module scope, because `test.use` needs the
// scratch workspace before any test body runs. A failure here is re-raised
// inside the test so Playwright reports it as a failing test rather than as a
// collection error nobody reads.
// ---------------------------------------------------------------------------

const windowsFlameRepo =
  process.env.CODETRACER_FLAME_DEMO_REPO ??
  path.join(WORKSPACE, "codetracer-flame-demo");
const windowsWork = path.join(
  windowsFlameRepo,
  "build",
  "hcr-windows-live-edit-loop",
);
const WINDOWS_AGENT = path.join(windowsWork, "agent", "repro_hcr_agent.dll");
const WINDOWS_EXTENSION = path.join(
  windowsFlameRepo,
  "bin",
  "flamefield.windows.template_debug.dll",
);
const WINDOWS_EXTENSION_PDB = path.join(
  windowsFlameRepo,
  "bin",
  "flamefield.windows.template_debug.pdb",
);

let unavailable: string | null =
  process.platform === "linux" || IS_WINDOWS
    ? null
    : `H6's launch path requires Linux or Windows; this is ${process.platform}`;
const resolved = IS_WINDOWS
  ? ({
      workspace: WORKSPACE,
      flameRepo: windowsFlameRepo,
      engine: path.join(
        WORKSPACE,
        "codetracer-engine-godot",
        "bin",
        "godot.windows.template_debug.x86_64.hcrwin.exe",
      ),
      driver: path.join(windowsWork, "hcr_patch_driver_windows.exe"),
      applyEdit: path.join(windowsFlameRepo, "scripts", "ct_hcr_apply_edit.py"),
      verify: path.join(
        windowsFlameRepo,
        "scripts",
        "verify_hcr2_flame_patch.py",
      ),
    } as FlamePaths)
  : unavailable === null
    ? resolveFlamePaths(CODETRACER_REPO)
    : "unsupported platform";
if (unavailable === null && typeof resolved === "string")
  unavailable = resolved;
const flame = typeof resolved === "string" ? null : (resolved as FlamePaths);
if (IS_WINDOWS && flame !== null) {
  for (const [what, where] of [
    ["the patchable Windows Godot engine", flame.engine],
    ["the patchable Windows FlameField DLL", WINDOWS_EXTENSION],
    ["the matching Windows FlameField PDB", WINDOWS_EXTENSION_PDB],
    ["the Windows HCR agent", WINDOWS_AGENT],
    ["the Windows session coordinator", flame.driver],
    ["the apply-edit command", flame.applyEdit],
  ] as const) {
    if (!fs.existsSync(where)) {
      unavailable = `${what} is missing: ${where}`;
      break;
    }
  }
}

/** The session-capable driver. One without `--session-dir` predates the loop. */
const SESSION_DRIVER =
  flame !== null
    ? IS_WINDOWS
      ? flame.driver
      : path.join(flame.flameRepo, "artifacts", "h5-driver", "hcr_patch_driver")
    : "";
if (unavailable === null) {
  if (!fs.existsSync(SESSION_DRIVER)) {
    unavailable = `the session-capable HCR coordinator driver is missing: ${SESSION_DRIVER}`;
  } else {
    const usage = spawnSync(SESSION_DRIVER, ["--help"], { encoding: "utf8" });
    if (
      !`${usage.stdout ?? ""}${usage.stderr ?? ""}`.includes("--session-dir")
    ) {
      unavailable = `${SESSION_DRIVER} does not support --session-dir; it predates the live-edit loop`;
    }
  }
}

const CHECKED_IN_LAUNCH_JSON =
  flame !== null ? path.join(flame.flameRepo, ".vscode", "launch.json") : "";
if (unavailable === null && !fs.existsSync(CHECKED_IN_LAUNCH_JSON)) {
  unavailable = `the demo's launch configuration is missing: ${CHECKED_IN_LAUNCH_JSON}`;
}

const WORK =
  flame !== null
    ? path.join(flame.flameRepo, "artifacts", "h6-launch", ARM)
    : path.join(
        process.env.TEMP ?? process.env.TMPDIR ?? "/tmp",
        `ct-h6-${ARM}`,
      );
fs.mkdirSync(WORK, { recursive: true });

const SCRATCH_WORKSPACE = path.join(WORK, "workspace");
const SESSION_DIR = path.join(WORK, "session");
const TICKS = path.join(WORK, "ticks-patched.log");
const CONTROL_TICKS = path.join(WORK, "ticks-control.log");
const OBSERVATIONS = path.join(WORK, "observations.json");
const PPID_SAMPLE = path.join(WORK, "ppid-sample.json");

/**
 * The launch configuration the product will read, derived from the CHECKED-IN
 * one rather than written from scratch.
 *
 * `${workspaceFolder}` is pre-substituted to the flame repo, because the folder
 * CodeTracer opens here is this scratch directory and the demo's paths are
 * relative to the demo. Only three values are overridden — the session
 * directory and the two output paths — so that six arms can run in sequence
 * without reading each other's artifacts, and the override list is recorded in
 * `observations.json` so nobody has to take that sentence on trust. Everything
 * that decides BEHAVIOUR — program, args, cwd, coordinator, target symbol,
 * apply-edit command — is the demo's own.
 */
interface DerivedConfig {
  raw: any;
  sha256OfCheckedIn: string;
  overridden: string[];
}

/** Write an executable `/bin/sh` stub into this arm's work dir, and return it. */
function writeStub(name: string, body: string): string {
  const target = path.join(WORK, name);
  fs.writeFileSync(target, `#!/bin/sh\n${body}`);
  fs.chmodSync(target, 0o755);
  return target;
}

function deriveLaunchJson(): DerivedConfig | null {
  if (flame === null) return null;
  const text = fs.readFileSync(CHECKED_IN_LAUNCH_JSON, "utf8");
  const sha = crypto.createHash("sha256").update(text).digest("hex");
  const parsed = JSON.parse(text);
  const substituteWorkspace = (value: any): any => {
    if (typeof value === "string") {
      return value.split("${workspaceFolder}").join(flame.flameRepo);
    }
    if (Array.isArray(value)) return value.map(substituteWorkspace);
    if (value !== null && typeof value === "object") {
      for (const key of Object.keys(value))
        value[key] = substituteWorkspace(value[key]);
    }
    return value;
  };
  substituteWorkspace(parsed);
  const wantedPlatform = IS_WINDOWS ? "win32" : "linux";
  const cfg = parsed.configurations.find(
    (candidate: any) => candidate.hcr?.platform === wantedPlatform,
  );
  if (cfg === undefined) {
    throw new Error(
      `checked-in launch.json has no HCR configuration for ${wantedPlatform}`,
    );
  }
  // The scratch project contains just this host's real configuration. This
  // makes the no-hcr-block arm remove the only HCR config rather than relying
  // on the resolver to ignore another platform's entry.
  parsed.configurations = [cfg];
  const overridden: string[] = [];
  cfg.env.CT_H2_TICKFILE = TICKS;
  cfg.env.CT_H2_OUT = path.join(WORK, "shots");
  overridden.push("env.CT_H2_TICKFILE", "env.CT_H2_OUT");
  if (cfg.hcr !== undefined) {
    cfg.hcr.sessionDir = SESSION_DIR;
    overridden.push("hcr.sessionDir");
  }

  // --- the arm's mutation, and nothing else -------------------------------
  switch (ARM) {
    case "green":
    case "harness-launches":
      break;
    case "no-hcr-block":
      // The configuration is a perfectly good "run this program" entry and is
      // simply not an HCR one. The product must say which file it looked in.
      delete cfg.hcr;
      overridden.push("ARM:deleted hcr");
      break;
    case "coordinator-not-a-coordinator":
      // A real executable that is not the protocol coordinator. The product
      // must start it, notice negotiation cannot happen, and clean up according
      // to the platform's startup order.
      //
      // Written here rather than pointed at `/bin/true`: this workspace is
      // Nix-managed and `/bin` holds only `sh`, so the arm would have tested
      // `hcr-coordinator-missing` — a different refusal entirely, and one the
      // arm does not claim. Measured on the first sweep.
      cfg.hcr.coordinator = IS_WINDOWS
        ? (process.env.ComSpec ?? "C:\\Windows\\System32\\cmd.exe")
        : writeStub("not-a-coordinator.sh", "exit 3\n");
      overridden.push(
        IS_WINDOWS
          ? "ARM:hcr.coordinator=ComSpec (not an HCR coordinator)"
          : "ARM:hcr.coordinator=a stub that exits 3",
      );
      break;
    case "target-exits-immediately":
      if (IS_WINDOWS) {
        cfg.program = process.env.ComSpec ?? "C:\\Windows\\System32\\cmd.exe";
        cfg.args = ["/d", "/c", "exit", "7"];
      } else {
        cfg.program = writeStub("exits-immediately.sh", "exit 7\n");
        cfg.args = [];
      }
      overridden.push("ARM:program=a stub that exits 7");
      break;
    case "agent-never-dials":
      // A real program that stays up and has no HCR agent in it. The product
      // must bound the wait and say the agent never connected — not spin.
      if (IS_WINDOWS) {
        cfg.program = process.env.ComSpec ?? "C:\\Windows\\System32\\cmd.exe";
        cfg.args = ["/d", "/s", "/c", "ping -n 46 127.0.0.1 > nul"];
      } else {
        cfg.program = writeStub("never-dials.sh", "sleep 45\n");
        cfg.args = [];
      }
      cfg.hcr.readyTimeoutMs = 8000;
      overridden.push(
        "ARM:program=a stub that sleeps",
        "ARM:hcr.readyTimeoutMs=8000",
      );
      break;
  }
  return { raw: parsed, sha256OfCheckedIn: sha, overridden };
}

let derived: DerivedConfig | null = null;
try {
  fs.rmSync(SCRATCH_WORKSPACE, { recursive: true, force: true });
  fs.mkdirSync(path.join(SCRATCH_WORKSPACE, ".vscode"), { recursive: true });
  if (unavailable === null) {
    derived = deriveLaunchJson();
    fs.writeFileSync(
      path.join(SCRATCH_WORKSPACE, ".vscode", "launch.json"),
      JSON.stringify(derived!.raw, null, 2),
    );
  } else {
    // The fixture still needs a real folder so the test body can report the
    // NAMED missing prerequisite instead of Electron failing first on ENOENT.
    fs.writeFileSync(
      path.join(SCRATCH_WORKSPACE, ".vscode", "launch.json"),
      JSON.stringify({ version: "0.2.0", configurations: [] }, null, 2),
    );
  }
  // Edit mode opens a folder; it needs something to show.
  fs.writeFileSync(
    path.join(SCRATCH_WORKSPACE, "README.md"),
    "H6 scratch workspace — holds only the derived .vscode/launch.json.\n",
  );
} catch (err) {
  unavailable = `could not prepare the scratch workspace: ${String(err)}`;
}

// The environment the Electron app is launched with. `makeCleanEnv` snapshots
// `process.env` at launch, so this must happen at module scope.
//
// Every H4/H5 variable is CLEARED for every arm except `harness-launches`,
// which is precisely the arm that configures the product the old way. With
// them set, the green arm could pass on a session the harness opened and the
// gate would be measuring H5 again.
delete process.env.CODETRACER_HCR_APPLY_EDIT_CMD;
delete process.env.CODETRACER_HCR_APPLY_EDIT_INTERPRETER;
delete process.env.CODETRACER_HCR_SESSION_DIR;
delete process.env.CODETRACER_HCR_SOCKET;
delete process.env.CODETRACER_HCR_DRIVER;
delete process.env.CODETRACER_HCR_EDIT;
delete process.env.CODETRACER_HCR_WAIT_FOR;
delete process.env.CODETRACER_HCR_MARKER;
delete process.env.CODETRACER_HCR_PLATFORM;
delete process.env.CODETRACER_HCR_REPORT;
delete process.env.CODETRACER_HCR_PID;
delete process.env.CODETRACER_HCR_PID_FILE;
delete process.env.CODETRACER_HCR_TARGET_IMAGE;
delete process.env.CODETRACER_HCR_TARGET_PDB;
delete process.env.CODETRACER_HCR_FIRST_INSTRUCTION_LENGTH;
/** The socket the `harness-launches` arm's coordinator listens on. */
const HARNESS_SOCKET = path.join("/tmp", `ct-h6-harness-${process.pid}.sock`);
if (ARM === "harness-launches" && flame !== null) {
  process.env.CODETRACER_HCR_APPLY_EDIT_CMD = flame.applyEdit;
  if (IS_WINDOWS) process.env.CODETRACER_HCR_APPLY_EDIT_INTERPRETER = "python";
  process.env.CODETRACER_HCR_SESSION_DIR = SESSION_DIR;
  process.env.CODETRACER_HCR_REPORT = path.join(WORK, "apply-edit-report.json");
}

const LAUNCH_COMMAND_LABEL = "Launch Under Live Edit (HCR)…";
const PANEL_COMMAND_LABEL = "Live Edit (HCR)…";

// ---------------------------------------------------------------------------
// Small helpers over the flame's flushed tick file and the host process table.
// ---------------------------------------------------------------------------

function currentFrame(tickFile: string): number {
  if (!fs.existsSync(tickFile)) return 0;
  const matches = [
    ...fs.readFileSync(tickFile, "utf8").matchAll(/frame=(\d+)/g),
  ];
  return matches.length > 0 ? Number(matches[matches.length - 1][1]) : 0;
}

async function waitForFrame(
  tickFile: string,
  want: number,
  timeoutMs: number,
): Promise<number> {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    const last = currentFrame(tickFile);
    if (last >= want) return last;
    await new Promise((resolve) => setTimeout(resolve, 50));
  }
  throw new Error(
    `the flame never reached frame ${want} within ${timeoutMs} ms`,
  );
}

/** `/proc/<pid>/stat` field 4 — the parent pid — or -1 if the process is gone. */
function procPpid(pid: number): number {
  try {
    const stat = fs.readFileSync(`/proc/${pid}/stat`, "utf8");
    // The comm field is parenthesised and may contain spaces; everything after
    // the last ')' is positional from field 3.
    const after = stat.slice(stat.lastIndexOf(")") + 2).split(" ");
    return Number(after[1]);
  } catch {
    return -1;
  }
}

function procAlive(pid: number): boolean {
  if (pid <= 0) return false;
  if (!IS_WINDOWS) return fs.existsSync(`/proc/${pid}`);
  try {
    process.kill(pid, 0);
    return true;
  } catch {
    return false;
  }
}

function procCmdline(pid: number): string {
  try {
    return fs
      .readFileSync(`/proc/${pid}/cmdline`, "utf8")
      .split("\0")
      .join(" ")
      .trim();
  } catch {
    return "";
  }
}

/** The chain of parents above `pid`, nearest first, bounded. */
function procAncestors(pid: number): number[] {
  const chain: number[] = [];
  let current = procPpid(pid);
  for (let i = 0; i < 32 && current > 1; i += 1) {
    chain.push(current);
    current = procPpid(current);
  }
  return chain;
}

interface ProcessRow {
  ProcessId: number;
  ParentProcessId: number;
  CommandLine: string | null;
}

/** One independent OS process-tree observation for the provenance verdict. */
function processWitness(pid: number): any {
  if (!IS_WINDOWS) {
    const ppid = procPpid(pid);
    return {
      source: "linux-procfs",
      targetPid: pid,
      ppid,
      alive: procAlive(pid),
      sampledAtMs: Date.now(),
      testProcessPid: process.pid,
      launcherAncestors: [ppid, ...procAncestors(ppid)],
      launcherCmdline: procCmdline(ppid),
    };
  }

  const query = spawnSync(
    "powershell.exe",
    [
      "-NoProfile",
      "-NonInteractive",
      "-Command",
      "Get-CimInstance Win32_Process | " +
        "Select-Object ProcessId,ParentProcessId,CommandLine | " +
        "ConvertTo-Json -Compress",
    ],
    { encoding: "utf8", windowsHide: true, maxBuffer: 16 * 1024 * 1024 },
  );
  if (query.status !== 0) {
    throw new Error(
      `Win32_Process query failed: ${query.stderr ?? query.stdout}`,
    );
  }
  const decoded = JSON.parse((query.stdout ?? "").trim());
  const rows = (Array.isArray(decoded) ? decoded : [decoded]) as ProcessRow[];
  const byPid = new Map(rows.map((row) => [Number(row.ProcessId), row]));
  const target = byPid.get(pid);
  if (target === undefined) {
    return {
      source: "windows-cim",
      targetPid: pid,
      ppid: -1,
      alive: false,
      sampledAtMs: Date.now(),
      testProcessPid: process.pid,
      launcherAncestors: [],
      launcherCmdline: "",
    };
  }
  const ppid = Number(target.ParentProcessId);
  const ancestors: number[] = [];
  let current = ppid;
  for (let i = 0; i < 32 && current > 0; i += 1) {
    ancestors.push(current);
    const row = byPid.get(current);
    if (row === undefined || Number(row.ParentProcessId) === current) break;
    current = Number(row.ParentProcessId);
  }
  return {
    source: "windows-cim",
    targetPid: pid,
    ppid,
    alive: true,
    sampledAtMs: Date.now(),
    testProcessPid: process.pid,
    launcherAncestors: ancestors,
    launcherCmdline: byPid.get(ppid)?.CommandLine ?? "",
  };
}

interface Observations {
  arm: Arm;
  startedAt: string;
  runtimeMs: number;
  checkedInLaunchJsonSha256: string;
  derivedOverrides: string[];
  launchInvoked: boolean;
  panelStatusAfterLaunch: string;
  panelDetailAfterLaunch: string;
  launchRecordPresent: boolean;
  record: any | null;
  targetAliveAtFailure: boolean | null;
  /**
   * Did an OS process-table sample taken WHILE the launch was still in progress
   * find the target alive?
   *
   * The independent half of the distinction between "the program exited before
   * its agent connected" and "the program is running and its agent never
   * connected". Both are product-reported states; this is the kernel's opinion,
   * sampled by the gate rather than read out of the product's own record, and
   * it is what stops those two arms from being told apart only by the string
   * the product printed (Verification-Harness-Traps.md §20).
   */
  targetAliveWhileWaiting: boolean | null;
  targetAliveSamples: number;
  sessionDirPresent: boolean;
  sessionPatchesRequested: number | null;
  editStatuses: string[];
  provenanceVerdict: string;
  provenanceOutput: string;
  flameVerdict: string;
  flameOutput: string;
  ppidSample: any | null;
}

test.describe("H6 — CodeTracer launches the flame under HCR", () => {
  test.setTimeout(1_200_000);
  test.use({
    launchMode: "edit",
    editFolderPath: SCRATCH_WORKSPACE,
    editWorkingDirectory: SCRATCH_WORKSPACE,
  });

  test(`arm ${ARM}: the product starts the session and the program it patches`, async ({
    ctPage,
  }) => {
    // NOT `test.skip`. A prerequisite that is missing is a failure here.
    expect(
      unavailable,
      `H6 prerequisites are not present: ${unavailable ?? ""}`,
    ).toBeNull();
    const paths = flame as FlamePaths;
    const started = Date.now();

    const obs: Observations = {
      arm: ARM,
      startedAt: new Date().toISOString(),
      runtimeMs: 0,
      checkedInLaunchJsonSha256: derived!.sha256OfCheckedIn,
      derivedOverrides: derived!.overridden,
      launchInvoked: false,
      panelStatusAfterLaunch: "",
      panelDetailAfterLaunch: "",
      launchRecordPresent: false,
      record: null,
      targetAliveAtFailure: null,
      targetAliveWhileWaiting: null,
      targetAliveSamples: 0,
      sessionDirPresent: false,
      sessionPatchesRequested: null,
      editStatuses: [],
      provenanceVerdict: "not-run",
      provenanceOutput: "",
      flameVerdict: "not-run",
      flameOutput: "",
      ppidSample: null,
    };
    const writeObservations = () => {
      obs.runtimeMs = Date.now() - started;
      fs.writeFileSync(OBSERVATIONS, JSON.stringify(obs, null, 2));
    };

    // Nothing may survive from a previous arm: a stale `hcr-launch.json` read
    // as this run's would be the whole gate passing on last week's evidence.
    fs.rmSync(SESSION_DIR, { recursive: true, force: true });
    fs.rmSync(TICKS, { force: true });
    fs.rmSync(PPID_SAMPLE, { force: true });
    fs.mkdirSync(path.dirname(TICKS), { recursive: true });

    let harnessCoordinator: ChildProcess | null = null;
    let harnessTarget: ChildProcess | null = null;
    let harnessTargetDone: Promise<number | null> | null = null;
    let controlDone: Promise<{ code: number | null; stdout: string }> | null =
      null;

    // --- the CONTROL run, where a flame verdict is going to be asked for ----
    // The same scene, the same engine, the same environment, no agent. It is
    // the trajectory the patched run must reproduce before the first edit and
    // the denominator of every plateau ratio afterwards.
    const cfg = derived!.raw.configurations[0];
    if (ARM_EDITS_THREE) {
      fs.rmSync(CONTROL_TICKS, { force: true });
      controlDone = runProgram(
        paths.engine,
        cfg.args as string[],
        {
          ...(cfg.env as Record<string, string>),
          CT_H2_TICKFILE: CONTROL_TICKS,
        },
        paths.flameRepo,
        null,
        600_000,
      );
    }

    // --- the arm that BYPASSES the feature ----------------------------------
    if (ARM === "harness-launches") {
      // H5's arrangement, reproduced exactly for this platform. Everything
      // downstream works; the gate must still refuse it on provenance alone.
      fs.mkdirSync(SESSION_DIR, { recursive: true });
      const driverLog = fs.openSync(
        path.join(WORK, "harness-coordinator.log"),
        "w",
      );
      let spawned: ReturnType<typeof spawnProgram>;
      if (IS_WINDOWS) {
        spawned = spawnProgram(
          paths.engine,
          cfg.args as string[],
          {
            ...(cfg.env as Record<string, string>),
            REPRO_HCR_AGENT_DLL: cfg.hcr.agentDll,
          },
          paths.flameRepo,
          path.join(WORK, "harness-target.log"),
        );
        expect(spawned.child.pid ?? 0).toBeGreaterThan(0);
        harnessCoordinator = spawn(
          SESSION_DRIVER,
          [
            "--pid",
            String(spawned.child.pid),
            "--target-image",
            cfg.hcr.targetImage,
            "--target-pdb",
            cfg.hcr.targetPdb,
            "--target-symbol",
            cfg.hcr.targetSymbol,
            "--first-instruction-length",
            String(cfg.hcr.firstInstructionLength),
            "--session",
            "--session-dir",
            SESSION_DIR,
            "--session-idle-timeout-ms",
            "600000",
          ],
          { stdio: ["ignore", driverLog, driverLog] },
        );
      } else {
        fs.rmSync(HARNESS_SOCKET, { force: true });
        harnessCoordinator = spawn(
          SESSION_DRIVER,
          [
            "--socket",
            HARNESS_SOCKET,
            "--target-symbol",
            cfg.hcr.targetSymbol,
            "--session",
            "--session-dir",
            SESSION_DIR,
            "--session-idle-timeout-ms",
            "600000",
          ],
          { stdio: ["ignore", driverLog, driverLog] },
        );
        await waitForFile(
          HARNESS_SOCKET,
          60_000,
          "the harness coordinator's socket",
        );
        spawned = spawnProgram(
          paths.engine,
          cfg.args as string[],
          {
            ...(cfg.env as Record<string, string>),
            REPRO_HCR_AGENT_SOCKET: HARNESS_SOCKET,
          },
          paths.flameRepo,
          path.join(WORK, "harness-target.log"),
        );
      }
      harnessTarget = spawned.child;
      harnessTargetDone = spawned.done;
      await waitForFile(
        path.join(SESSION_DIR, "ready"),
        120_000,
        "the harness-opened session becoming ready",
      );
      // This process-table sample is about the process the HARNESS started,
      // which is the honest subject: the question the gate asks is "whose child
      // is the thing that got patched".
      const pid = harnessTarget.pid ?? 0;
      obs.ppidSample = processWitness(pid);
      fs.writeFileSync(PPID_SAMPLE, JSON.stringify(obs.ppidSample, null, 2));
    }

    // --- the panel, and (for every arm but one) the product's launch --------
    const panel = ctPage.locator(".hcr-live-edit-panel");
    const status = ctPage.locator("[data-hcr-live-edit-status]");
    const detail = ctPage.locator("[data-hcr-live-edit-detail]");

    if (ARM === "harness-launches") {
      // Open the panel WITHOUT launching — this arm's point is that the product
      // did not do the launching.
      await runPaletteCommand(ctPage, "Live Edit", PANEL_COMMAND_LABEL);
      await expect(panel).toBeVisible({ timeout: 30_000 });
      await expect(status).toHaveText("waiting", { timeout: 20_000 });
    } else {
      await runPaletteCommand(ctPage, "Launch Under", LAUNCH_COMMAND_LABEL);
      obs.launchInvoked = true;
      // Sample the OS process table CONCURRENTLY with the launch, not afterwards.
      // The product
      // kills a target whose agent never dialled — correctly, since it is a
      // process nobody can edit and nobody asked to keep — so by the time the
      // panel shows the refusal the subject is gone, and a sample taken then
      // measures the cleanup rather than the state being reported. That is
      // trap 21's shape (a transient asserted after a long await), reached from
      // the launcher's side.
      let sampling = true;
      const sampler = (async () => {
        const recordFile = path.join(SESSION_DIR, "hcr-launch.json");
        while (sampling) {
          try {
            if (fs.existsSync(recordFile)) {
              const pid = Number(
                JSON.parse(fs.readFileSync(recordFile, "utf8")).targetPid ?? 0,
              );
              if (pid > 0) {
                if (procAlive(pid)) {
                  obs.targetAliveSamples += 1;
                  obs.targetAliveWhileWaiting = true;
                } else if (obs.targetAliveWhileWaiting === null) {
                  obs.targetAliveWhileWaiting = false;
                }
              }
            }
          } catch {
            /* the record is rewritten at every phase; a torn read is not news */
          }
          await new Promise((resolve) => setTimeout(resolve, 100));
        }
      })();
      await expect(panel).toBeVisible({ timeout: 30_000 });
      // The panel must leave `launching` within a BOUNDED time, whatever
      // happens: this is the assertion that a failed launch is not an
      // indefinite spinner. Every terminal state is a named one.
      await expect
        .poll(async () => (await status.textContent()) ?? "", {
          timeout: 180_000,
          message: "the launch never reached a terminal state — it spun",
        })
        .not.toBe("launching");
      obs.panelStatusAfterLaunch = ((await status.textContent()) ?? "").trim();
      obs.panelDetailAfterLaunch = ((await detail.textContent()) ?? "").trim();
      sampling = false;
      await sampler;
    }

    // --- what the product wrote about its own launch ------------------------
    const recordPath = path.join(SESSION_DIR, "hcr-launch.json");
    obs.sessionDirPresent = fs.existsSync(SESSION_DIR);
    if (fs.existsSync(recordPath)) {
      obs.launchRecordPresent = true;
      obs.record = JSON.parse(fs.readFileSync(recordPath, "utf8"));
    }

    if (ARM !== "harness-launches" && obs.record !== null) {
      const targetPid = Number(obs.record.targetPid ?? 0);
      obs.targetAliveAtFailure = targetPid > 0 ? procAlive(targetPid) : false;
    }

    // --- the green arm: sample process ancestry while the target is ALIVE ----
    if (ARM === "green") {
      expect(
        obs.panelStatusAfterLaunch,
        `the launch did not reach a ready session; the panel said ` +
          `"${obs.panelStatusAfterLaunch}" — ${obs.panelDetailAfterLaunch}`,
      ).toBe("session-ready");
      expect(obs.record, "the product wrote no launch record").not.toBeNull();
      const targetPid = Number(obs.record.targetPid ?? 0);
      expect(
        targetPid,
        "the launch record names no target pid",
      ).toBeGreaterThan(0);
      obs.ppidSample = processWitness(targetPid);
      fs.writeFileSync(PPID_SAMPLE, JSON.stringify(obs.ppidSample, null, 2));
    }

    // --- the edits ----------------------------------------------------------
    const appliedAt: number[] = [];
    const submittedAt: number[] = [];
    const input = panel.locator("[data-hcr-live-edit-input]");
    if (ARM_EDITS_THREE) {
      for (let i = 0; i < ARMS_TABLE.length; i += 1) {
        const arm = ARMS_TABLE[i];
        const due =
          i === 0 ? FIRST_EDIT_AT : appliedAt[i - 1] + SETTLE + PLATEAU;
        await waitForFrame(TICKS, due, 600_000);
        // Read BEFORE the keypress: the patch cannot have landed earlier than
        // this, so it is the conservative identity boundary (trap 23).
        submittedAt.push(currentFrame(TICKS));
        await input.fill(arm.edit);
        await input.press("Enter");
        await expect(status).toHaveText("applied", { timeout: 300_000 });
        appliedAt.push(currentFrame(TICKS));
        obs.editStatuses.push("applied");
      }
    } else {
      // One edit, into a product with no session. It must be REFUSED by name —
      // a panel that quietly accepted an edit with nothing to publish into
      // would be the silent no-op this whole beat exists to rule out.
      await input.fill(ARMS_TABLE[0].edit);
      await input.press("Enter");
      await expect
        .poll(async () => (await status.textContent()) ?? "", {
          timeout: 120_000,
        })
        .not.toBe("applying…");
      obs.editStatuses.push(((await status.textContent()) ?? "").trim());
    }

    // --- let the target finish, and collect the session's own summary -------
    if (ARM === "green") {
      // The product tears the session down when its target exits. Waiting for
      // `session.json` is waiting for the coordinator to have been told `stop`
      // BY THE PRODUCT and to have written its summary — i.e. for the teardown
      // this milestone is also about.
      await waitForFile(
        path.join(SESSION_DIR, "session.json"),
        900_000,
        "the coordinator's session summary, written after the product tore the session down",
      );
      await expect
        .poll(async () => (await status.textContent()) ?? "", {
          timeout: 120_000,
        })
        .toBe("session-closed");
      obs.record = JSON.parse(fs.readFileSync(recordPath, "utf8"));
    } else if (ARM === "harness-launches") {
      fs.writeFileSync(path.join(SESSION_DIR, "stop"), "");
      if (harnessTargetDone !== null) await harnessTargetDone;
      await waitForFile(
        path.join(SESSION_DIR, "session.json"),
        120_000,
        "the harness session's summary",
      );
    }

    const sessionPath = path.join(SESSION_DIR, "session.json");
    if (fs.existsSync(sessionPath)) {
      const session = JSON.parse(fs.readFileSync(sessionPath, "utf8"));
      obs.sessionPatchesRequested = Number(session.patchesRequested ?? 0);
    }

    // --- the two verdicts ---------------------------------------------------
    if (ARM_EDITS_THREE) {
      const provenance = spawnSync(
        PYTHON,
        [
          path.join(
            paths.flameRepo,
            "scripts",
            "verify_hcr6_launch_provenance.py",
          ),
          "--record",
          recordPath,
          "--ppid-sample",
          PPID_SAMPLE,
          "--session",
          sessionPath,
          "--expect-patches",
          String(ARMS_TABLE.length),
          "--expect-launcher-cmdline",
          CODETRACER_REPO,
          "--json-out",
          path.join(WORK, "provenance-verdict.json"),
        ],
        { encoding: "utf8" },
      );
      obs.provenanceOutput = `${provenance.stdout ?? ""}\n${provenance.stderr ?? ""}`;
      obs.provenanceVerdict =
        provenance.status === 0
          ? "pass"
          : provenance.status === 1
            ? "fail"
            : "unusable";

      const armsJson = path.join(WORK, "arms.json");
      const armArgs: string[] = [];
      ARMS_TABLE.forEach((arm, i) => {
        armArgs.push(
          "--arm",
          `${i + 1}|${arm.edit}|${arm.predicted}|${arm.band}|${appliedAt[i]}|${path.join(
            SESSION_DIR,
            `cmd-${i + 1}.json`,
          )}|${submittedAt[i]}|${submittedAt[i]}`,
        );
      });
      const written = spawnSync(
        PYTHON,
        [
          path.join(paths.flameRepo, "scripts", "hcr5_arms_json.py"),
          "--out",
          armsJson,
          ...armArgs,
        ],
        { encoding: "utf8" },
      );
      expect(written.status, `${written.stdout}${written.stderr}`).toBe(0);
      const control = await controlDone!;
      expect(control.code, "the control flame did not finish").toBe(0);
      const flameVerdict = spawnSync(
        PYTHON,
        [
          path.join(
            paths.flameRepo,
            "scripts",
            "verify_hcr5_live_edit_loop.py",
          ),
          "--control",
          CONTROL_TICKS,
          "--patched",
          TICKS,
          "--arms",
          armsJson,
          "--session",
          sessionPath,
          "--frames",
          String(FRAMES),
          "--settle",
          String(SETTLE),
          "--json-out",
          path.join(WORK, "flame-verdict.json"),
        ],
        { encoding: "utf8" },
      );
      obs.flameOutput = `${flameVerdict.stdout ?? ""}\n${flameVerdict.stderr ?? ""}`;
      obs.flameVerdict = flameVerdict.status === 0 ? "pass" : "fail";
    }

    writeObservations();

    // --- cleanup ------------------------------------------------------------
    if (harnessCoordinator !== null && harnessCoordinator.exitCode === null) {
      harnessCoordinator.kill("SIGTERM");
    }
    if (harnessTarget !== null && harnessTarget.exitCode === null) {
      harnessTarget.kill("SIGKILL");
    }
    if (obs.record !== null && ARM !== "green") {
      const pid = Number(obs.record.targetPid ?? 0);
      if (pid > 0 && procAlive(pid)) process.kill(pid, "SIGKILL");
    }

    // --- the arm's own claim ------------------------------------------------
    //
    // Asserted here so a run that produced the wrong kind of failure fails the
    // test, rather than being left for the matrix script to notice. The matrix
    // script then grades the SET: each arm must also fail every other arm's
    // expectation, which a single run cannot show.
    switch (ARM) {
      case "green":
        expect(obs.provenanceVerdict, obs.provenanceOutput).toBe("pass");
        expect(obs.flameVerdict, obs.flameOutput).toBe("pass");
        expect(obs.flameOutput).toContain("are identical in both runs");
        expect(obs.sessionPatchesRequested).toBe(ARMS_TABLE.length);
        break;
      case "harness-launches":
        // Everything downstream WORKS — that is the arm. Only provenance refuses.
        expect(obs.editStatuses).toEqual(["applied", "applied", "applied"]);
        expect(obs.sessionPatchesRequested).toBe(ARMS_TABLE.length);
        expect(obs.flameVerdict, obs.flameOutput).toBe("pass");
        expect(obs.launchRecordPresent).toBe(false);
        expect(obs.provenanceVerdict, obs.provenanceOutput).toBe("fail");
        expect(obs.provenanceOutput).toContain("no launch record");
        break;
      case "no-hcr-block":
        expect(obs.panelStatusAfterLaunch).toBe("hcr-no-launch-configuration");
        expect(obs.panelDetailAfterLaunch).toContain("launch.json");
        expect(obs.launchRecordPresent).toBe(false);
        break;
      case "coordinator-not-a-coordinator":
        expect(obs.panelStatusAfterLaunch).toBe("hcr-coordinator-failed");
        expect(obs.launchRecordPresent).toBe(true);
        // Linux can refuse before spending the target's one dial-out. Windows
        // must create the target first because the coordinator needs its PID;
        // the product then tears that now-unusable target down.
        if (IS_WINDOWS) {
          expect(Number(obs.record.targetPid ?? 0)).toBeGreaterThan(0);
        } else {
          expect(Number(obs.record.targetPid ?? -1)).toBe(0);
        }
        expect(Number(obs.record.coordinatorPid ?? 0)).toBeGreaterThan(0);
        break;
      case "target-exits-immediately":
        expect(obs.panelStatusAfterLaunch).toBe("hcr-target-exited-early");
        expect(obs.launchRecordPresent).toBe(true);
        expect(Number(obs.record.targetPid ?? 0)).toBeGreaterThan(0);
        expect(obs.record.targetExited).toBe(true);
        // The STUB'S OWN exit code, which names the object this arm touched
        // rather than the class of thing that happened.
        expect(Number(obs.record.targetExitCode ?? -1)).toBe(7);
        if (IS_WINDOWS) {
          expect(Number(obs.record.targetStartedAtMs ?? 0)).toBeLessThanOrEqual(
            Number(obs.record.coordinatorStartedAtMs ?? 0),
          );
        } else {
          expect(
            Number(obs.record.coordinatorListeningAtMs ?? 0),
          ).toBeLessThanOrEqual(Number(obs.record.targetStartedAtMs ?? 0));
        }
        break;
      case "agent-never-dials":
        expect(obs.panelStatusAfterLaunch).toBe("hcr-agent-never-dialled");
        expect(obs.launchRecordPresent).toBe(true);
        expect(Number(obs.record.targetPid ?? 0)).toBeGreaterThan(0);
        expect(obs.record.targetExited).toBe(false);
        // And the kernel agreed, while the product was still waiting.
        expect(obs.targetAliveWhileWaiting).toBe(true);
        break;
    }
    writeObservations();
  });
});

/** Open the command palette, type `query`, and click the entry labelled `label`. */
async function runPaletteCommand(
  page: any,
  query: string,
  label: string,
): Promise<void> {
  await page.keyboard.press("Control+KeyP");
  const box = page.locator("#command-query-text");
  await expect(box).toBeVisible({ timeout: 30_000 });
  await box.fill(`:${query}`);
  const hit = page
    .locator(".command-results .command-result.command-command")
    .filter({ hasText: label })
    .first();
  await expect(hit, `the command palette has no entry "${label}"`).toBeVisible({
    timeout: 30_000,
  });
  await hit.click();
}

function spawnProgram(
  program: string,
  args: string[],
  env: Record<string, string>,
  cwd: string,
  logFile: string,
): { child: ChildProcess; done: Promise<number | null> } {
  const childEnv: NodeJS.ProcessEnv = { ...process.env, ...env };
  delete childEnv.CT_H2_CAPTURE;
  if (childEnv.REPRO_HCR_AGENT_DLL !== undefined)
    delete childEnv.REPRO_HCR_AGENT_SOCKET;
  if (childEnv.REPRO_HCR_AGENT_SOCKET !== undefined)
    delete childEnv.REPRO_HCR_AGENT_DLL;
  // STDOUT GOES TO A FILE, and that is not about keeping evidence. A child
  // spawned with a PIPE nobody reads stops when the pipe's 64 KB buffer fills:
  // the probe prints one ~70-byte line per frame, so this flame froze at frame
  // 1131 of 2400 — measured on the first run of this arm, and indistinguishable
  // from a hang in the thing under test. The product's own launcher redirects
  // to files for the same reason.
  const fd = fs.openSync(logFile, "w");
  const child = spawn(program, args, {
    env: childEnv,
    cwd,
    stdio: ["ignore", fd, fd],
  });
  const done = new Promise<number | null>((resolve) => {
    child.on("close", (code) => {
      fs.closeSync(fd);
      resolve(code);
    });
    child.on("error", () => {
      fs.closeSync(fd);
      resolve(-1);
    });
  });
  return { child, done };
}

function runProgram(
  program: string,
  args: string[],
  env: Record<string, string>,
  cwd: string,
  agentSocket: string | null,
  timeoutMs: number,
): Promise<{ code: number | null; stdout: string }> {
  const childEnv: NodeJS.ProcessEnv = { ...process.env, ...env };
  delete childEnv.CT_H2_CAPTURE;
  if (agentSocket === null) {
    // The control run must have NO agent. Inheriting one would make the control
    // the same run as the patched one and the identity comparison vacuous.
    delete childEnv.REPRO_HCR_AGENT_SOCKET;
    delete childEnv.REPRO_HCR_AGENT_DLL;
  } else {
    childEnv.REPRO_HCR_AGENT_SOCKET = agentSocket;
    delete childEnv.REPRO_HCR_AGENT_DLL;
  }
  return new Promise((resolve, reject) => {
    const child = spawn(program, args, { env: childEnv, cwd });
    let stdout = "";
    const timer = setTimeout(() => {
      child.kill("SIGKILL");
      reject(new Error(`${program} did not finish within ${timeoutMs} ms`));
    }, timeoutMs);
    child.stdout.on("data", (chunk) => (stdout += chunk.toString()));
    child.on("error", (err) => {
      clearTimeout(timer);
      reject(err);
    });
    child.on("close", (code) => {
      clearTimeout(timer);
      resolve({ code, stdout });
    });
  });
}
