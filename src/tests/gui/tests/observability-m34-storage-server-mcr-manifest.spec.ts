/**
 * Observability M34 acceptance: storage-server backed MCR manifest hostability.
 *
 * This test starts the codetracer-ci ASP.NET local-storage API harness, uploads
 * real split MCR segment bytes through that API, and launches `ct host
 * --manifest` with storage endpoint credentials. The browser checks exercise
 * the same real replay UI assertions as M29 without reading segment bytes from
 * the local filesystem.
 */

import * as childProcess from "node:child_process";
import * as crypto from "node:crypto";
import * as fs from "node:fs";
import * as http from "node:http";
import * as os from "node:os";
import * as path from "node:path";
import * as process from "node:process";

import { test as base, expect, chromium, type Page } from "@playwright/test";

import {
  codetracerInstallDir,
  codetracerPath,
} from "../lib/fixtures";
import * as helpers from "../lib/language-smoke-test-helpers";
import { getFreeTcpPort } from "../lib/port-allocator";
import { retry } from "../lib/retry-helpers";
import { LayoutPage } from "../page-objects/layout-page";

const workspaceRoot = path.dirname(codetracerInstallDir);
const observabilityE2eDir = path.join(
  workspaceRoot,
  "codetracer-observability-e2e",
);
const codetracerCiDir = path.join(workspaceRoot, "codetracer-ci");
const storageHarnessProject = path.join(
  codetracerCiDir,
  "tests",
  "CrossRepo.ObservabilityDebugSessionHarness",
  "CrossRepo.ObservabilityDebugSessionHarness.csproj",
);
const replayAgentProject = path.join(
  codetracerCiDir,
  "apps",
  "ReplayAgent",
  "ReplayAgent.csproj",
);
const m25RealMcrArtifactDir = path.join(
  observabilityE2eDir,
  "artifacts",
  "m25-real-mcr",
);
const portableTracePath = path.join(
  m25RealMcrArtifactDir,
  "mcr",
  "inventory.ct",
);
const fixtureSourcePath = path.join(
  observabilityE2eDir,
  "services",
  "native_inventory_smoke",
  "inventory_smoke.c",
);
const fixtureBinaryPath = path.join(
  m25RealMcrArtifactDir,
  "bin",
  "inventory_smoke",
);
const fixtureRequestDetailsPath = path.join(
  m25RealMcrArtifactDir,
  "requests",
  "inventory-response.json",
);
const pythonFlowTraceFixture = path.join(
  codetracerInstallDir,
  "examples",
  "recordings",
  "python",
  "flow_test",
);
const rubyFlowTraceFixture = path.join(
  codetracerInstallDir,
  "examples",
  "recordings",
  "ruby",
  "flow_test",
);
const javascriptFlowTraceFixture = path.join(
  codetracerInstallDir,
  "examples",
  "recordings",
  "javascript",
  "flow_test",
);
const codetracerPrefix = path.join(codetracerInstallDir, "src", "build-debug");
const ctMcrCandidates = [
  path.join(codetracerPrefix, "bin", "ct-mcr"),
  path.join(
    workspaceRoot,
    "codetracer-native-recorder",
    "ct_cli",
    "ct_cli",
  ),
  path.join(
    workspaceRoot,
    "codetracer-native-recorder",
    "target",
    "debug",
    "ct-mcr",
  ),
];
const ctMcrPath = ctMcrCandidates.find((candidate) =>
  fs.existsSync(candidate),
) ?? "";

const maxConnectAttempts = 25;
const retryDelayMs = 1_500;
const gotoTimeoutMs = 5_000;
const browserDetailTimeoutMs = 60_000;

type SliceManifestEntry = {
  intervalId: number;
  slicePath: string;
  geidStart: bigint;
  geidEnd: bigint;
};

type PreparedSplitMcr = {
  rootDir: string;
  inputPath: string;
  selectedSegmentIndex: number;
};

type McrMarkerCoordinates = {
  traceId: string;
  spanId: string;
};

type StorageHarnessReady = {
  baseUrl: string;
  tenantId: string;
  replayToken: string;
  manifestPath: string;
  serverIds: string[];
  selectedSegmentIndex: number;
};

type DebugSessionReplayReady = {
  baseUrl: string;
  tenantId: string;
  callerToken: string;
  replayToken: string;
  authProbes: {
    replayTokenSelectedObjectStatus: number;
    replayTokenCrossTraceStatus: number;
    replayTokenGeneralApiStatus: number;
    userTokenStorageReadStatus: number;
  };
  manifestKey: string;
  selectedSegmentIndex: number;
  debugSession: {
    status: string;
    resolvedCoordinate: {
      geid?: number;
      sliceKey?: string;
    };
  };
  replayPayload: any;
};

type PlatformLinkReady = {
  baseUrl: string;
  tenantId: string;
  callerToken: string;
  traceId: string;
  spanId: string;
  serviceName: string;
  wallTimeUnixNs: string;
  monotonicTimeNs: string;
  timeWindowNs: string;
  selectedSegmentIndex: number;
};

type MaterializedFlowFixture = {
  label: string;
  language: string;
  serviceName: string;
  operationName: string;
  traceDir: string;
  traceFileName: "trace.bin" | "trace.json";
  sourceFileName: string;
  requiredSourceSnippets: string[];
  calltraceFunction: string;
  expectedCallArgs?: Record<string, string>;
  eventText: string;
  terminalText: string;
  traceId: string;
  spanId: string;
  momentId: string;
  requestKey: string;
};

type MaterializedPlatformLinkReady = {
  baseUrl: string;
  tenantId: string;
  callerToken: string;
  replayToken: string;
  serverIds: string[];
  links: MaterializedPlatformLink[];
};

type MaterializedPlatformLink = {
  language: string;
  label: string;
  serviceName: string;
  operationName: string;
  traceId: string;
  spanId: string;
  momentId: string;
  requestKey: string;
  wallTimeUnixNs: string;
  monotonicTimeNs: string;
  timeWindowNs: string;
  manifestPath: string;
  materializedArtifactKey: string;
};

type CorruptedPrimaryReplicas = {
  primaryServerId: string;
  secondaryServerId: string;
  missingObjectKeys: string[];
  secondaryObjectKeys: string[];
};

const materializedFixtures: MaterializedFlowFixture[] = [
  {
    label: "Python",
    language: "python",
    serviceName: "python-flow-materialized",
    operationName: "POST /python/flow",
    traceDir: pythonFlowTraceFixture,
    traceFileName: "trace.bin",
    sourceFileName: "python_flow_test.py",
    requiredSourceSnippets: ["calculate_sum", "sum_with_while"],
    calltraceFunction: "calculate_sum",
    eventText: "Result: 94",
    terminalText: "Result: 94",
    traceId: "4bf92f3577b34da6a3ce929d0e0e3601",
    spanId: "36000000000000aa",
    momentId: "m36-python-flow-calculate-sum",
    requestKey: "m36-python-materialized-request-001",
  },
  {
    label: "Ruby",
    language: "ruby",
    serviceName: "ruby-flow-materialized",
    operationName: "POST /ruby/flow",
    traceDir: rubyFlowTraceFixture,
    traceFileName: "trace.json",
    sourceFileName: "ruby_flow_test.rb",
    requiredSourceSnippets: ["def calculate_sum", "def sum_with_while"],
    calltraceFunction: "calculate_sum",
    expectedCallArgs: { a: "10", b: "32" },
    eventText: "sum with while 45",
    terminalText: "Result: 94",
    traceId: "4bf92f3577b34da6a3ce929d0e0e3602",
    spanId: "36000000000000bb",
    momentId: "m36-ruby-flow-calculate-sum",
    requestKey: "m36-ruby-materialized-request-001",
  },
  {
    label: "JavaScript",
    language: "javascript",
    serviceName: "javascript-flow-materialized",
    operationName: "POST /javascript/flow",
    traceDir: javascriptFlowTraceFixture,
    traceFileName: "trace.json",
    sourceFileName: "javascript_flow_test.js",
    requiredSourceSnippets: ["function calculate_sum", "var sum_val"],
    calltraceFunction: "calculate_sum",
    expectedCallArgs: { a: "10", b: "32" },
    eventText: "Result: 94",
    terminalText: "Result: 94",
    traceId: "4bf92f3577b34da6a3ce929d0e0e3603",
    spanId: "36000000000000cc",
    momentId: "m36-javascript-flow-calculate-sum",
    requestKey: "m36-javascript-materialized-request-001",
  },
];

function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

function killProcessTree(pid: number): void {
  if (process.platform === "win32") {
    try {
      childProcess.execSync(`taskkill /PID ${pid} /T /F`, {
        encoding: "utf-8",
        stdio: "pipe",
        windowsHide: true,
      });
    } catch {
      // Process may already be gone.
    }
    return;
  }

  let childPids: number[] = [];
  try {
    const output = childProcess
      .execSync(`pgrep -P ${pid} 2>/dev/null`, { encoding: "utf-8" })
      .trim();
    if (output) {
      childPids = output.split("\n").map(Number).filter(Boolean);
    }
  } catch {
    // No children found.
  }

  for (const child of childPids) {
    killProcessTree(child);
  }

  try {
    process.kill(pid, "SIGKILL");
  } catch {
    // Already dead.
  }
}

function makeCleanEnv(extra?: Record<string, string>): Record<string, string> {
  const env: Record<string, string> = {};
  for (const [key, value] of Object.entries(process.env)) {
    if (value !== undefined) env[key] = value;
  }
  delete env.CODETRACER_TRACE_ID;
  delete env.CODETRACER_CALLER_PID;
  delete env.CODETRACER_PREFIX;
  delete env.WAYLAND_DISPLAY;
  delete env.XDG_SESSION_TYPE;
  env.CODETRACER_IN_UI_TEST = "1";
  env.CODETRACER_TEST = "1";
  env.CODETRACER_ELECTRON_ARGS = [
    "--no-sandbox",
    "--no-zygote",
    "--disable-gpu",
    "--disable-gpu-compositing",
    "--disable-dev-shm-usage",
    "--in-process-gpu",
    "--ozone-platform-hint=x11",
  ].join(" ");
  if (ctMcrPath) {
    env.CODETRACER_CT_MCR_CMD = ctMcrPath;
  }
  return { ...env, ...extra };
}

function resolveChromiumPath(): string {
  if (process.env.PLAYWRIGHT_CHROMIUM_EXECUTABLE_PATH) {
    return process.env.PLAYWRIGHT_CHROMIUM_EXECUTABLE_PATH;
  }

  const browsersDir = process.env.PLAYWRIGHT_BROWSERS_PATH;
  if (!browsersDir) {
    throw new Error("PLAYWRIGHT_BROWSERS_PATH is required for this GUI test");
  }

  const chromiumDir = fs
    .readdirSync(browsersDir)
    .filter((dir) => dir.startsWith("chromium-") && !dir.includes("headless"))
    .sort()
    .pop();
  if (!chromiumDir) {
    throw new Error(`no chromium-* directory found in ${browsersDir}`);
  }

  const chromiumBase = path.join(browsersDir, chromiumDir);
  if (process.platform === "win32") {
    const chromeSubdir = fs
      .readdirSync(chromiumBase)
      .find((dir) => dir.startsWith("chrome-win"));
    if (!chromeSubdir) {
      throw new Error(`no chrome-win* directory found in ${chromiumBase}`);
    }
    return path.join(chromiumBase, chromeSubdir, "chrome.exe");
  }

  const chromeSubdir = fs
    .readdirSync(chromiumBase)
    .find((dir) => dir.startsWith("chrome-linux"));
  if (!chromeSubdir) {
    throw new Error(`no chrome-linux* directory found in ${chromiumBase}`);
  }
  return path.join(chromiumBase, chromeSubdir, "chrome");
}

function expectRequiredFile(label: string, filePath: string): void {
  expect(
    fs.existsSync(filePath),
    `${label} is required for M34 storage manifest acceptance: ${filePath}`,
  ).toBe(true);
}

function escapeRegExp(value: string): string {
  return value.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
}

function walkFiles(rootDir: string): string[] {
  const result: string[] = [];
  for (const entry of fs.readdirSync(rootDir, { withFileTypes: true })) {
    const fullPath = path.join(rootDir, entry.name);
    if (entry.isDirectory()) {
      result.push(...walkFiles(fullPath));
    } else if (entry.isFile()) {
      result.push(fullPath);
    }
  }
  return result;
}

function toStorageRelativePath(rootDir: string, filePath: string): string {
  return path.relative(rootDir, filePath).split(path.sep).join("/");
}

function readVarString(
  buffer: Buffer,
  offset: number,
): { value: string; nextOffset: number } {
  if (offset + 4 > buffer.length) {
    throw new Error("truncated SMNF string length");
  }
  const length = buffer.readUInt32LE(offset);
  const valueStart = offset + 4;
  const valueEnd = valueStart + length;
  if (valueEnd > buffer.length) {
    throw new Error("truncated SMNF string payload");
  }
  return {
    value: buffer.subarray(valueStart, valueEnd).toString("utf-8"),
    nextOffset: valueEnd,
  };
}

function parseSliceManifest(manifestPath: string): SliceManifestEntry[] {
  const buffer = fs.readFileSync(manifestPath);
  if (buffer.length < 14 || buffer.subarray(0, 4).toString("ascii") !== "SMNF") {
    throw new Error(`invalid split slice manifest: ${manifestPath}`);
  }

  let offset = 4;
  const version = buffer.readUInt16LE(offset);
  offset += 2;
  if (version !== 1) {
    throw new Error(`unsupported split slice manifest version ${version}`);
  }

  offset += 4;
  offset = readVarString(buffer, offset).nextOffset;
  const entryCount = buffer.readUInt32LE(offset);
  offset += 4;

  const entries: SliceManifestEntry[] = [];
  for (let i = 0; i < entryCount; i++) {
    const intervalId = buffer.readUInt32LE(offset);
    offset += 4;
    const slicePath = readVarString(buffer, offset);
    offset = slicePath.nextOffset;
    const geidStart = buffer.readBigUInt64LE(offset);
    offset += 8;
    const geidEnd = buffer.readBigUInt64LE(offset);
    offset += 8;
    offset += 8; // tickStart
    offset += 8; // tickEnd
    offset += 4; // eventCount
    entries.push({
      intervalId,
      slicePath: slicePath.value,
      geidStart,
      geidEnd,
    });
  }

  return entries;
}

function segmentInteriorGeid(entry: SliceManifestEntry): bigint {
  if (entry.geidEnd > entry.geidStart) return entry.geidStart + 1n;
  if (entry.geidStart > 0n) return entry.geidStart;
  return entry.geidEnd;
}

function sha256File(filePath: string): string {
  return crypto
    .createHash("sha256")
    .update(fs.readFileSync(filePath))
    .digest("hex");
}

function parseMcrMarkerCoordinates(filePath: string): McrMarkerCoordinates {
  const text = fs.readFileSync(filePath).toString("utf-8");
  const markerLine = text
    .split(/[\0\r\n]+/)
    .find((line) =>
      line.includes("CT_TRACE_MARKER") &&
      /trace_id=/i.test(line) &&
      /span_id=/i.test(line),
    );
  if (!markerLine) {
    throw new Error(`MCR marker with trace_id/span_id not found in ${filePath}`);
  }

  const values = new Map<string, string>();
  for (const part of markerLine.split(/\s+/)) {
    const equals = part.indexOf("=");
    if (equals <= 0 || equals === part.length - 1) continue;
    values.set(
      part.slice(0, equals).toLowerCase(),
      part.slice(equals + 1).replace(/[",]+$/g, ""),
    );
  }

  const traceId = values.get("trace_id");
  const spanId = values.get("span_id");
  if (!traceId || !spanId) {
    throw new Error(`MCR marker coordinates are incomplete in ${filePath}`);
  }
  return { traceId, spanId };
}

function prepareStorageHarnessInput(): PreparedSplitMcr {
  expectRequiredFile("ct-mcr slicer", ctMcrPath);

  const rootDir = fs.mkdtempSync(
    path.join(os.tmpdir(), "ct-m34-storage-mcr-manifest-"),
  );
  const segmentsDir = path.join(rootDir, "segments");
  fs.mkdirSync(segmentsDir, { recursive: true });

  const localTracePath = path.join(rootDir, "inventory.ct");
  fs.copyFileSync(portableTracePath, localTracePath);
  const sliceOutput = childProcess.execFileSync(
    ctMcrPath,
    ["slice", "--by-checkpoints", "-o", segmentsDir, localTracePath],
    {
      encoding: "utf-8",
      stdio: "pipe",
    },
  );
  console.log(`# ct-mcr slice output:\n${sliceOutput}`);

  const sliceEntries = parseSliceManifest(path.join(segmentsDir, "manifest.smnf"));
  expect(
    sliceEntries.length,
    "M34 storage acceptance requires the four retained split segments claimed by M29/M34",
  ).toBe(4);

  const segmentPaths = sliceEntries.map((entry) =>
    path.join(segmentsDir, entry.slicePath),
  );
  expect(new Set(segmentPaths.map(sha256File)).size).toBe(segmentPaths.length);

  const selectedEntry = sliceEntries[sliceEntries.length - 1];
  const selectedGeid = segmentInteriorGeid(selectedEntry);
  const marker = parseMcrMarkerCoordinates(localTracePath);
  const inputPath = path.join(rootDir, "storage-harness-input.json");
  fs.writeFileSync(
    inputPath,
    JSON.stringify(
      {
        traceId: marker.traceId,
        spanId: marker.spanId,
        selectedGeid: selectedGeid.toString(),
        selectedSegmentIndex: selectedEntry.intervalId,
        segments: sliceEntries.map((entry) => ({
          index: entry.intervalId,
          filePath: path.join(segmentsDir, entry.slicePath),
          geidStart: entry.geidStart.toString(),
          geidEnd: entry.geidEnd.toString(),
        })),
        supportFiles: [
          {
            relativePath: "inventory_smoke.c",
            filePath: fixtureSourcePath,
            includeInTracePaths: true,
          },
          {
            relativePath: "inventory-response.json",
            filePath: fixtureRequestDetailsPath,
            includeInTracePaths: true,
          },
          {
            relativePath: "binaries/inventory_smoke",
            filePath: fixtureBinaryPath,
          },
          {
            relativePath: "expired-support-should-not-load.txt",
            filePath: fixtureRequestDetailsPath,
            retentionStatus: "expired",
          },
          {
            relativePath: "incomplete-support-should-not-load.txt",
            filePath: fixtureRequestDetailsPath,
            uploadCompletionState: "uploading",
          },
        ],
      },
      null,
      2,
    ),
  );

  return {
    rootDir,
    inputPath,
    selectedSegmentIndex: selectedEntry.intervalId,
  };
}

function prepareMaterializedPlatformHarnessInput(): { rootDir: string; inputPath: string } {
  const rootDir = fs.mkdtempSync(
    path.join(os.tmpdir(), "ct-m36-storage-materialized-platform-link-"),
  );
  const inputPath = path.join(rootDir, "storage-materialized-platform-input.json");
  fs.writeFileSync(
    inputPath,
    JSON.stringify(
      {
        artifacts: materializedFixtures.map((fixture) => ({
          label: fixture.label,
          language: fixture.language,
          serviceName: fixture.serviceName,
          operationName: fixture.operationName,
          traceId: fixture.traceId,
          spanId: fixture.spanId,
          momentId: fixture.momentId,
          requestKey: fixture.requestKey,
          files: walkFiles(fixture.traceDir).map((filePath) => {
            const relativePath = toStorageRelativePath(fixture.traceDir, filePath);
            return {
              relativePath,
              filePath,
              isTracePayload: relativePath === fixture.traceFileName,
            };
          }),
        })),
      },
      null,
      2,
    ),
  );
  return { rootDir, inputPath };
}

function forceSelectedSegmentPrimaryReplicaMiss(
  manifestPath: string,
  selectedSegmentIndex: number,
): CorruptedPrimaryReplicas {
  const manifest = JSON.parse(fs.readFileSync(manifestPath, "utf-8"));
  const selectedSegment = manifest.source.segments.find(
    (segment: any) => segment.index === selectedSegmentIndex,
  );
  if (!selectedSegment) {
    throw new Error(`selected segment ${selectedSegmentIndex} missing from ${manifestPath}`);
  }

  const missingObjectKeys: string[] = [];
  const secondaryObjectKeys: string[] = [];
  let primaryServerId = "";
  let secondaryServerId = "";

  for (const shard of selectedSegment.shards) {
    const primary = shard.replicas?.[0];
    const secondary = shard.replicas?.[1];
    if (!primary?.objectKey || !secondary?.objectKey) {
      throw new Error("replica fallback acceptance requires two object-key replicas per selected shard");
    }

    if (!primaryServerId) primaryServerId = primary.storageServerId;
    if (!secondaryServerId) secondaryServerId = secondary.storageServerId;
    primary.objectKey = `${primary.objectKey}.missing-primary-replica`;
    missingObjectKeys.push(primary.objectKey);
    secondaryObjectKeys.push(secondary.objectKey);
  }

  fs.writeFileSync(manifestPath, JSON.stringify(manifest, null, 2));
  return {
    primaryServerId,
    secondaryServerId,
    missingObjectKeys,
    secondaryObjectKeys,
  };
}

async function waitForOutput(
  output: string[],
  pattern: RegExp,
  timeoutMs = 60_000,
): Promise<string> {
  try {
    await retry(
      async () => pattern.test(output.join("")),
      {
        maxAttempts: Math.ceil(timeoutMs / 1_000),
        delayMs: 1_000,
      },
    );
    return output.join("");
  } catch (error) {
    throw new Error(
      `Timed out waiting for output ${pattern}.\nCaptured output:\n${output.join("")}`,
      { cause: error },
    );
  }
}

async function waitFor(
  label: string,
  action: () => Promise<unknown>,
  timeoutMs: number,
): Promise<void> {
  try {
    await retry(
      async () => {
        try {
          await action();
          return true;
        } catch {
          return false;
        }
      },
      {
        maxAttempts: Math.ceil(timeoutMs / 1_000),
        delayMs: 1_000,
      },
    );
  } catch (error) {
    throw new Error(`Timed out waiting for ${label}`, { cause: error });
  }
}

async function startStorageHarness(
  inputPath: string,
): Promise<{ process: childProcess.ChildProcess; ready: StorageHarnessReady; output: string[] }> {
  const output: string[] = [];
  const harnessProcess = childProcess.spawn(
    "direnv",
    [
      "exec",
      codetracerCiDir,
      "dotnet",
      "run",
      "--project",
      storageHarnessProject,
      "--",
      "storage-server-manifest",
      inputPath,
    ],
    {
      cwd: codetracerCiDir,
      env: makeCleanEnv(),
      stdio: ["ignore", "pipe", "pipe"],
      windowsHide: true,
    },
  );
  harnessProcess.stdout?.on("data", (chunk: Buffer) => {
    output.push(chunk.toString());
  });
  harnessProcess.stderr?.on("data", (chunk: Buffer) => {
    output.push(chunk.toString());
  });

  const readyOutput = await waitForOutput(
    output,
    /CODETRACER_CI_STORAGE_HARNESS_READY\s+({.+})/,
    120_000,
  );
  const match = readyOutput.match(/CODETRACER_CI_STORAGE_HARNESS_READY\s+({.+})/);
  if (!match) {
    throw new Error(`storage harness ready payload missing:\n${readyOutput}`);
  }

  return {
    process: harnessProcess,
    ready: JSON.parse(match[1]) as StorageHarnessReady,
    output,
  };
}

async function startDebugSessionHarness(
  inputPath: string,
): Promise<{ process: childProcess.ChildProcess; ready: DebugSessionReplayReady; output: string[] }> {
  const output: string[] = [];
  const harnessProcess = childProcess.spawn(
    "direnv",
    [
      "exec",
      codetracerCiDir,
      "dotnet",
      "run",
      "--project",
      storageHarnessProject,
      "--",
      "storage-server-debug-session",
      inputPath,
    ],
    {
      cwd: codetracerCiDir,
      env: makeCleanEnv(),
      stdio: ["ignore", "pipe", "pipe"],
      windowsHide: true,
    },
  );
  harnessProcess.stdout?.on("data", (chunk: Buffer) => {
    output.push(chunk.toString());
  });
  harnessProcess.stderr?.on("data", (chunk: Buffer) => {
    output.push(chunk.toString());
  });

  const readyOutput = await waitForOutput(
    output,
    /CODETRACER_CI_DEBUG_SESSION_REPLAY_READY\s+({.+})/,
    120_000,
  );
  const match = readyOutput.match(
    /CODETRACER_CI_DEBUG_SESSION_REPLAY_READY\s+({.+})/,
  );
  if (!match) {
    throw new Error(`debug-session replay ready payload missing:\n${readyOutput}`);
  }

  return {
    process: harnessProcess,
    ready: JSON.parse(match[1]) as DebugSessionReplayReady,
    output,
  };
}

async function startPlatformLinkHarness(
  inputPath: string,
): Promise<{ process: childProcess.ChildProcess; ready: PlatformLinkReady; output: string[] }> {
  const output: string[] = [];
  const harnessProcess = childProcess.spawn(
    "direnv",
    [
      "exec",
      codetracerCiDir,
      "dotnet",
      "run",
      "--project",
      storageHarnessProject,
      "--",
      "storage-server-platform-link",
      inputPath,
    ],
    {
      cwd: codetracerCiDir,
      env: makeCleanEnv(),
      stdio: ["ignore", "pipe", "pipe"],
      windowsHide: true,
    },
  );
  harnessProcess.stdout?.on("data", (chunk: Buffer) => {
    output.push(chunk.toString());
  });
  harnessProcess.stderr?.on("data", (chunk: Buffer) => {
    output.push(chunk.toString());
  });

  const readyOutput = await waitForOutput(
    output,
    /CODETRACER_CI_PLATFORM_LINK_READY\s+({.+})/,
    120_000,
  );
  const match = readyOutput.match(/CODETRACER_CI_PLATFORM_LINK_READY\s+({.+})/);
  if (!match) {
    throw new Error(`platform-link ready payload missing:\n${readyOutput}`);
  }

  return {
    process: harnessProcess,
    ready: JSON.parse(match[1]) as PlatformLinkReady,
    output,
  };
}

async function startMaterializedPlatformLinkHarness(
  inputPath: string,
): Promise<{ process: childProcess.ChildProcess; ready: MaterializedPlatformLinkReady; output: string[] }> {
  const output: string[] = [];
  const harnessProcess = childProcess.spawn(
    "direnv",
    [
      "exec",
      codetracerCiDir,
      "dotnet",
      "run",
      "--project",
      storageHarnessProject,
      "--",
      "storage-server-materialized-platform-link",
      inputPath,
    ],
    {
      cwd: codetracerCiDir,
      env: makeCleanEnv(),
      stdio: ["ignore", "pipe", "pipe"],
      windowsHide: true,
    },
  );
  harnessProcess.stdout?.on("data", (chunk: Buffer) => {
    output.push(chunk.toString());
  });
  harnessProcess.stderr?.on("data", (chunk: Buffer) => {
    output.push(chunk.toString());
  });

  const readyOutput = await waitForOutput(
    output,
    /CODETRACER_CI_MATERIALIZED_PLATFORM_LINK_READY\s+({.+})/,
    120_000,
  );
  const match = readyOutput.match(
    /CODETRACER_CI_MATERIALIZED_PLATFORM_LINK_READY\s+({.+})/,
  );
  if (!match) {
    throw new Error(`materialized platform-link ready payload missing:\n${readyOutput}`);
  }

  return {
    process: harnessProcess,
    ready: JSON.parse(match[1]) as MaterializedPlatformLinkReady,
    output,
  };
}

function parseReplayAgentEnv(commandLine: string): Record<string, string> {
  const env: Record<string, string> = {};
  const pattern = /-e '([^=']+)=([^']*)'/g;
  for (const match of commandLine.matchAll(pattern)) {
    env[match[1]] = match[2];
  }
  return env;
}

function generateReplayAgentCommand(payload: any, rootDir: string): string {
  const payloadPath = path.join(rootDir, "replay-provisioning-requested.json");
  fs.writeFileSync(payloadPath, JSON.stringify(payload, null, 2));
  return childProcess.execFileSync(
    "direnv",
    [
      "exec",
      codetracerCiDir,
      "dotnet",
      "run",
      "--project",
      replayAgentProject,
      "--",
      "print-runner-command",
      payloadPath,
    ],
    {
      cwd: codetracerCiDir,
      env: makeCleanEnv(),
      encoding: "utf-8",
      stdio: ["ignore", "pipe", "pipe"],
      windowsHide: true,
    },
  ).trim();
}

function shellQuote(value: string): string {
  return `'${value.replace(/'/g, `'\"'\"'`)}'`;
}

function createCtPathShim(rootDir: string): string {
  const shimDir = path.join(rootDir, "bin");
  fs.mkdirSync(shimDir, { recursive: true });
  const shimPath = path.join(shimDir, "ct");
  fs.writeFileSync(
    shimPath,
    [
      "#!/usr/bin/env bash",
      "set -euo pipefail",
      `exec ${shellQuote(codetracerPath)} "$@"`,
      "",
    ].join("\n"),
  );
  fs.chmodSync(shimPath, 0o755);
  return shimDir;
}

async function connectToHost(
  page: Page,
  httpPort: number,
  hostOutput: string[],
): Promise<void> {
  let connected = false;
  for (let attempt = 1; attempt <= maxConnectAttempts && !connected; attempt++) {
    try {
      await page.goto(`http://localhost:${httpPort}`, {
        timeout: gotoTimeoutMs,
      });
      connected = true;
    } catch {
      if (attempt < maxConnectAttempts) {
        console.log(
          `  ct host connect attempt ${attempt}/${maxConnectAttempts} failed, retrying...`,
        );
        await sleep(retryDelayMs);
      }
    }
  }
  if (!connected) {
    throw new Error(
      `Timed out connecting to ct host on http://localhost:${httpPort}.\n` +
        `Captured host output:\n${hostOutput.join("")}`,
    );
  }
}

async function waitForEditorModelText(
  page: Page,
  expectedText: string,
  timeoutMs = browserDetailTimeoutMs,
): Promise<string> {
  const readEditorText = async (): Promise<string> =>
    await page.evaluate(() => {
      const data = (window as any).data;
      const editorModels = Object.values(data?.ui?.editors ?? {})
        .map((editor: any) => editor?.monacoEditor?.getModel?.())
        .filter((model: any) => model?.getValue)
        .map((model: any) => String(model.getValue() ?? ""));
      if (editorModels.length > 0) return editorModels.join("\n");

      const monaco = (window as any).monaco;
      if (!monaco?.editor?.getModels) return "";
      return monaco.editor
        .getModels()
        .map((model: any) => String(model.getValue?.() ?? ""))
        .join("\n");
    });

  try {
    await retry(
      async () => (await readEditorText()).includes(expectedText),
      {
        maxAttempts: Math.ceil(timeoutMs / 1_000),
        delayMs: 1_000,
      },
    );
    return await readEditorText();
  } catch (error) {
    const modelText = await readEditorText();
    throw new Error(
      `Timed out waiting for editor model text ${JSON.stringify(expectedText)}.\n` +
        `Editor model sample:\n${modelText.slice(0, 4000)}`,
      { cause: error },
    );
  }
}

async function waitForVisibleEditorText(
  page: Page,
  expectedText: string,
  timeoutMs = browserDetailTimeoutMs,
): Promise<string> {
  const readVisibleText = async (): Promise<string> =>
    await page.evaluate(() =>
      Array.from(document.querySelectorAll(".monaco-editor .view-lines"))
        .map((node) => (node as HTMLElement).innerText)
        .join("\n")
        .replace(/\u00a0/g, " "),
    );

  try {
    await retry(
      async () => (await readVisibleText()).includes(expectedText),
      {
        maxAttempts: Math.ceil(timeoutMs / 1_000),
        delayMs: 1_000,
      },
    );
    return await readVisibleText();
  } catch (error) {
    const visibleText = await readVisibleText();
    throw new Error(
      `Timed out waiting for visible editor text ${JSON.stringify(expectedText)}.\n` +
        `Visible editor sample:\n${visibleText.slice(0, 4000)}`,
      { cause: error },
    );
  }
}

function dockerBin(): string {
  return process.env.CODETRACER_M36_DOCKER_BIN || "docker";
}

function ctObserveBin(): string {
  return process.env.CODETRACER_M36_CT_OBSERVE_BIN ||
    path.join(workspaceRoot, "codetracer-observability-cli", "ct-observe");
}

function jaegerUiConfigPath(): string {
  return process.env.CODETRACER_M36_JAEGER_UI_CONFIG ||
    path.join(
      workspaceRoot,
      "codetracer-observability-jaeger",
      "examples",
      "jaeger-v1.76",
      "ui-config.json",
    );
}

function jaegerUiConfigRendererPath(): string {
  return process.env.CODETRACER_M36_JAEGER_CONFIG_RENDERER ||
    path.join(
      workspaceRoot,
      "codetracer-observability-jaeger",
      "scripts",
      "render-jaeger-config.sh",
    );
}

function dockerImage(): string {
  return process.env.CODETRACER_M36_JAEGER_IMAGE ||
    "jaegertracing/all-in-one:1.76.0";
}

function m36ArtifactDir(): string | null {
  return process.env.CODETRACER_M36_ARTIFACT_DIR || null;
}

async function fetchJsonFromUrl(url: string, init?: any): Promise<any> {
  const response = await fetch(url, init);
  if (!response.ok) {
    throw new Error(`${url} returned HTTP ${response.status}: ${await response.text()}`);
  }
  return await response.json();
}

function startJaegerAllInOne(
  rootDir: string,
  uiConfigPath: string,
  uiPort: number,
  otlpPort: number,
): childProcess.ChildProcess {
  const name = `ct-m36-jaeger-${process.pid}-${Date.now()}`;
  fs.writeFileSync(path.join(rootDir, "jaeger-container-name.txt"), name);
  childProcess.spawnSync(dockerBin(), ["rm", "-f", name], {
    encoding: "utf-8",
    stdio: "ignore",
    windowsHide: true,
  });
  const container = childProcess.spawn(
    dockerBin(),
    [
      "run",
      "--rm",
      "--name",
      name,
      "-p",
      `127.0.0.1:${uiPort}:16686`,
      "-p",
      `127.0.0.1:${otlpPort}:4318`,
      "-v",
      `${uiConfigPath}:/etc/jaeger/ui-config.json:ro`,
      "-e",
      "COLLECTOR_OTLP_ENABLED=true",
      dockerImage(),
      "--query.ui-config=/etc/jaeger/ui-config.json",
    ],
    {
      cwd: rootDir,
      env: makeCleanEnv(),
      stdio: ["ignore", "pipe", "pipe"],
      windowsHide: true,
    },
  );
  container.stdout?.on("data", (chunk: Buffer) =>
    fs.appendFileSync(path.join(rootDir, "jaeger-docker.log"), chunk),
  );
  container.stderr?.on("data", (chunk: Buffer) =>
    fs.appendFileSync(path.join(rootDir, "jaeger-docker.log"), chunk),
  );
  return container;
}

async function stopJaegerAllInOne(rootDir: string, processHandle: childProcess.ChildProcess | null): Promise<void> {
  const namePath = path.join(rootDir, "jaeger-container-name.txt");
  if (fs.existsSync(namePath)) {
    childProcess.spawnSync(dockerBin(), ["rm", "-f", fs.readFileSync(namePath, "utf-8").trim()], {
      encoding: "utf-8",
      stdio: "ignore",
      windowsHide: true,
    });
  }
  if (processHandle?.pid) {
    killProcessTree(processHandle.pid);
  }
}

async function ingestJaegerSpan(
  otlpPort: number,
  ready: PlatformLinkReady,
  debugUrl: string,
): Promise<void> {
  const start = BigInt(ready.wallTimeUnixNs);
  const end = start + 500_000_000n;
  const payload = {
    resourceSpans: [
      {
        resource: {
          attributes: [
            { key: "service.name", value: { stringValue: ready.serviceName } },
          ],
        },
        scopeSpans: [
          {
            scope: { name: "codetracer-observability-m36" },
            spans: [
              {
                traceId: ready.traceId,
                spanId: ready.spanId,
                name: "GET /reserve",
                kind: 2,
                startTimeUnixNano: ready.wallTimeUnixNs,
                endTimeUnixNano: end.toString(),
                attributes: [
                  { key: "ct.recording_available", value: { boolValue: true } },
                  { key: "ct.dive_in_url", value: { stringValue: debugUrl } },
                  { key: "service.name", value: { stringValue: ready.serviceName } },
                  { key: "tenant_id", value: { stringValue: ready.tenantId } },
                  { key: "span_id", value: { stringValue: ready.spanId } },
                  { key: "ct.mcr.wall_time_unix_ns", value: { intValue: ready.wallTimeUnixNs } },
                  { key: "ct.mcr.monotonic_time_ns", value: { intValue: ready.monotonicTimeNs } },
                  { key: "time_window_ns", value: { intValue: ready.timeWindowNs } },
                  { key: "request.id", value: { stringValue: "m25-real-mcr-request-001" } },
                ],
              },
            ],
          },
        ],
      },
    ],
  };
  const response = await fetch(`http://127.0.0.1:${otlpPort}/v1/traces`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify(payload),
  });
  if (!response.ok) {
    throw new Error(`Jaeger OTLP ingest failed: HTTP ${response.status} ${await response.text()}`);
  }
}

async function ingestMaterializedJaegerSpan(
  otlpPort: number,
  ready: MaterializedPlatformLinkReady,
  linkReady: MaterializedPlatformLink,
  debugUrl: string,
): Promise<void> {
  const start = BigInt(linkReady.wallTimeUnixNs);
  const end = start + 500_000_000n;
  const payload = {
    resourceSpans: [
      {
        resource: {
          attributes: [
            { key: "service.name", value: { stringValue: linkReady.serviceName } },
          ],
        },
        scopeSpans: [
          {
            scope: { name: "codetracer-observability-m36-materialized" },
            spans: [
              {
                traceId: linkReady.traceId,
                spanId: linkReady.spanId,
                name: linkReady.operationName,
                kind: 2,
                startTimeUnixNano: linkReady.wallTimeUnixNs,
                endTimeUnixNano: end.toString(),
                attributes: [
                  { key: "ct.recording_available", value: { boolValue: true } },
                  { key: "ct.dive_in_url", value: { stringValue: debugUrl } },
                  { key: "service.name", value: { stringValue: linkReady.serviceName } },
                  { key: "tenant_id", value: { stringValue: ready.tenantId } },
                  { key: "span_id", value: { stringValue: linkReady.spanId } },
                  { key: "ct.mcr.wall_time_unix_ns", value: { intValue: linkReady.wallTimeUnixNs } },
                  { key: "ct.mcr.monotonic_time_ns", value: { intValue: linkReady.monotonicTimeNs } },
                  { key: "time_window_ns", value: { intValue: linkReady.timeWindowNs } },
                  { key: "request.id", value: { stringValue: linkReady.requestKey } },
                  { key: "code.namespace", value: { stringValue: linkReady.language } },
                  { key: "code.function", value: { stringValue: linkReady.momentId } },
                ],
              },
            ],
          },
        ],
      },
    ],
  };
  const response = await fetch(`http://127.0.0.1:${otlpPort}/v1/traces`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify(payload),
  });
  if (!response.ok) {
    throw new Error(`Jaeger materialized OTLP ingest failed: HTTP ${response.status} ${await response.text()}`);
  }
}

function renderJaegerUiConfigForDebugBase(rootDir: string, debugSessionBaseUrl: string): string {
  expectRequiredFile("Jaeger plugin UI config renderer", jaegerUiConfigRendererPath());
  const outputPath = path.join(rootDir, "jaeger-ui-config.json");
  childProcess.execFileSync(jaegerUiConfigRendererPath(), [outputPath], {
    encoding: "utf-8",
    env: {
      ...makeCleanEnv(),
      CODETRACER_JAEGER_DEBUG_SESSION_BASE_URL: debugSessionBaseUrl,
      CODETRACER_JAEGER_MENU_URL: debugSessionBaseUrl,
    },
    stdio: ["ignore", "pipe", "pipe"],
    windowsHide: true,
  });
  expectRequiredFile("rendered Jaeger plugin UI config", outputPath);
  return outputPath;
}

async function runCtObserveAgainstJaeger(
  jaegerBaseUrl: string,
  ready: PlatformLinkReady,
): Promise<any> {
  expectRequiredFile("ct-observe binary", ctObserveBin());
  const cliTime = (unixNs: bigint): string =>
    new Date(Number(unixNs / 1_000_000n))
      .toISOString()
      .replace(/\.\d{3}Z$/, "Z");
  const fromIso = cliTime(BigInt(ready.wallTimeUnixNs) - 60_000_000_000n);
  const toIso = cliTime(BigInt(ready.wallTimeUnixNs) + 60_000_000_000n);
  const output = childProcess.execFileSync(
    ctObserveBin(),
    [
      "extract",
      "--backend=jaeger",
      `--url=${jaegerBaseUrl}`,
      `--from=${fromIso}`,
      `--to=${toIso}`,
      `--service=${ready.serviceName}`,
      "--format=jsonl",
    ],
    {
      encoding: "utf-8",
      stdio: ["ignore", "pipe", "pipe"],
      windowsHide: true,
    },
  );
  const rows = output
    .split(/\n/)
    .filter((line) => line.trim().length > 0)
    .map((line) => JSON.parse(line));
  const row = rows.find(
    (candidate) =>
      candidate.trace_id === ready.traceId && candidate.span_id === ready.spanId,
  );
  if (!row) {
    throw new Error(`ct-observe did not return M36 Jaeger row:\n${output}`);
  }
  return row;
}

async function runMaterializedCtObserveAgainstJaeger(
  jaegerBaseUrl: string,
  linkReady: MaterializedPlatformLink,
): Promise<any> {
  expectRequiredFile("ct-observe binary", ctObserveBin());
  const cliTime = (unixNs: bigint): string =>
    new Date(Number(unixNs / 1_000_000n))
      .toISOString()
      .replace(/\.\d{3}Z$/, "Z");
  const fromIso = cliTime(BigInt(linkReady.wallTimeUnixNs) - 60_000_000_000n);
  const toIso = cliTime(BigInt(linkReady.wallTimeUnixNs) + 60_000_000_000n);
  const output = childProcess.execFileSync(
    ctObserveBin(),
    [
      "extract",
      "--backend=jaeger",
      `--url=${jaegerBaseUrl}`,
      `--from=${fromIso}`,
      `--to=${toIso}`,
      `--service=${linkReady.serviceName}`,
      "--format=jsonl",
    ],
    {
      encoding: "utf-8",
      stdio: ["ignore", "pipe", "pipe"],
      windowsHide: true,
    },
  );
  const rows = output
    .split(/\n/)
    .filter((line) => line.trim().length > 0)
    .map((line) => JSON.parse(line));
  const row = rows.find(
    (candidate) =>
      candidate.trace_id === linkReady.traceId && candidate.span_id === linkReady.spanId,
  );
  if (!row) {
    throw new Error(`ct-observe did not return M36 materialized Jaeger row:\n${output}`);
  }
  return row;
}

async function waitForRealReplayDetails(page: Page, hostOutput: string[]): Promise<void> {
  await expect(page.locator(".lm_content").first()).toBeVisible({
    timeout: 30_000,
  });

  const sourceNode = page
    .locator(".jstree-anchor")
    .filter({ hasText: /^inventory_smoke\.c$/ })
    .first();
  await expect(sourceNode).toBeVisible({ timeout: 30_000 });
  await sourceNode.click();
  const sourceText = await waitForEditorModelText(page, "handle_client");
  await waitForEditorModelText(page, "reserve_from_primary_bin");

  const requestDetailsNode = page
    .locator(".jstree-anchor")
    .filter({ hasText: /^inventory-response\.json$/ })
    .first();
  await expect(requestDetailsNode).toBeVisible({ timeout: 30_000 });
  await requestDetailsNode.click();
  const requestDetailsText = await waitForVisibleEditorText(
    page,
    `"requestId": "m25-real-mcr-request-001"`,
  );
  await waitForVisibleEditorText(page, `"branch": "reserve_from_primary_bin"`);

  const bodyText = await page.evaluate(() => document.body.innerText);
  expect(bodyText).toContain("inventory_smoke.c");
  expect(bodyText).toContain("inventory-response.json");
  expect(sourceText).toContain("handle_client");
  expect(sourceText).toContain("reserve_from_primary_bin");
  expect(requestDetailsText).toContain(`"requestId": "m25-real-mcr-request-001"`);
  expect(requestDetailsText).toContain(`"branch": "reserve_from_primary_bin"`);
  expect(hostOutput.join("")).toContain("fetching CTFS shard replica from storage:");
}

async function waitForMaterializedReplayDetails(
  page: Page,
  fixture: MaterializedFlowFixture,
  hostOutput: string[],
): Promise<void> {
  await expect(page.locator(".lm_content").first()).toBeVisible({
    timeout: 30_000,
  });

  const layout = new LayoutPage(page);
  await layout.waitForFilesystemLoaded();
  const sourceNode = page
    .locator(".jstree-anchor")
    .filter({ hasText: new RegExp(`^${escapeRegExp(fixture.sourceFileName)}$`) })
    .first();
  await expect(sourceNode).toBeVisible({ timeout: 30_000 });
  await sourceNode.click();

  const sourceText = await waitForEditorModelText(
    page,
    fixture.requiredSourceSnippets[0],
  );
  for (const snippet of fixture.requiredSourceSnippets.slice(1)) {
    await waitForEditorModelText(page, snippet);
  }

  await layout.waitForCallTraceReady();
  const callTrace = (await layout.callTraceTabs())[0];
  await callTrace.clickTab();
  const callEntry = await callTrace.navigateToEntry(fixture.calltraceFunction);
  expect((await callEntry.functionName()).toLowerCase()).toBe(
    fixture.calltraceFunction.toLowerCase(),
  );
  if (fixture.expectedCallArgs) {
    const args = await callEntry.arguments();
    const observedArgs = new Map<string, string>();
    for (const arg of args) {
      observedArgs.set((await arg.name()).toLowerCase(), await arg.value());
    }
    for (const [name, value] of Object.entries(fixture.expectedCallArgs)) {
      expect(
        observedArgs.get(name.toLowerCase()),
        `${fixture.label} calltrace argument ${name}`,
      ).toBe(value);
    }
  }

  await helpers.assertEventLogContainsText(page, fixture.eventText);
  await helpers.assertTerminalOutputContains(page, fixture.terminalText);
  expect(sourceText).toContain(fixture.requiredSourceSnippets[0]);
  expect(hostOutput.join("")).toContain("fetching materialized artifact from storage:");
  expect(hostOutput.join("")).toContain("fetching storage support file trace_metadata.json from storage:");
  expect(hostOutput.join("")).toContain("fetching storage support file trace_paths.json from storage:");
}

function startPlatformLaunchBridge(options: {
  rootDir: string;
  ready: PlatformLinkReady;
  runnerRoot: string;
  port: number;
  launches: Array<{ ctProcess: childProcess.ChildProcess; hostOutput: string[]; hostUrl: string }>;
}): http.Server {
  const server = http.createServer(async (request, response) => {
    try {
      const requestUrl = new URL(request.url ?? "/", `http://${request.headers.host}`);
      if (requestUrl.pathname !== "/observability/v0/debug-session") {
        response.writeHead(404);
        response.end("not found");
        return;
      }

      const upstreamUrl = `${options.ready.baseUrl}${requestUrl.pathname}${requestUrl.search}`;
      const upstreamResponse = await fetch(upstreamUrl, {
        headers: { authorization: `Bearer ${options.ready.callerToken}` },
        redirect: "manual",
      });
      if (upstreamResponse.status !== 302) {
        throw new Error(
          `codetracer-ci browser debug-session returned HTTP ${upstreamResponse.status}: ${await upstreamResponse.text()}`,
        );
      }

      const replayPayload = await fetchJsonFromUrl(
        `${options.ready.baseUrl}/__tests/replay-provisioning/latest`,
      );
      const replayAgentCommandLine = generateReplayAgentCommand(
        replayPayload,
        options.runnerRoot,
      );
      const replayEnv = parseReplayAgentEnv(replayAgentCommandLine);
      const httpPort = await getFreeTcpPort();
      const backendPort = await getFreeTcpPort();
      const hostOutput: string[] = [];
      const shimDir = createCtPathShim(options.runnerRoot);
      const entrypointPath = path.join(
        codetracerCiDir,
        "resources",
        "docker",
        "codetracer-runner",
        "replay-entrypoint.sh",
      );
      const ctProcess = childProcess.spawn(
        "bash",
        [
          entrypointPath,
          `--port=${httpPort}`,
          `--backend-socket-port=${backendPort}`,
          `--frontend-socket=${backendPort}`,
        ],
        {
          cwd: codetracerInstallDir,
          env: {
            ...makeCleanEnv({
              XDG_CONFIG_HOME: path.join(options.runnerRoot, "xdg-config"),
            }),
            ...replayEnv,
            CODETRACER_WORK_DIR: path.join(options.runnerRoot, "work"),
            PATH: `${shimDir}${path.delimiter}${process.env.PATH ?? ""}`,
          },
          stdio: ["ignore", "pipe", "pipe"],
          windowsHide: true,
        },
      );
      ctProcess.stdout?.on("data", (chunk: Buffer) => {
        hostOutput.push(chunk.toString());
      });
      ctProcess.stderr?.on("data", (chunk: Buffer) => {
        hostOutput.push(chunk.toString());
      });
      await waitForOutput(hostOutput, /imported manifest trace as trace id\s+\d+/);
      const hostUrl = `http://127.0.0.1:${httpPort}`;
      options.launches.push({ ctProcess, hostOutput, hostUrl });
      response.writeHead(302, { location: hostUrl });
      response.end();
    } catch (error) {
      response.writeHead(500, { "content-type": "text/plain; charset=utf-8" });
      response.end(error instanceof Error ? error.stack : String(error));
    }
  });
  server.listen(options.port, "127.0.0.1");
  return server;
}

function startMaterializedPlatformLaunchBridge(options: {
  ready: MaterializedPlatformLinkReady;
  runnerRoot: string;
  port: number;
  launches: Array<{
    ctProcess: childProcess.ChildProcess;
    hostOutput: string[];
    hostUrl: string;
    linkReady: MaterializedPlatformLink;
    replayPayload: any;
  }>;
}): http.Server {
  const server = http.createServer(async (request, response) => {
    try {
      const requestUrl = new URL(request.url ?? "/", `http://${request.headers.host}`);
      if (requestUrl.pathname !== "/observability/v0/debug-session") {
        response.writeHead(404);
        response.end("not found");
        return;
      }

      const traceId = requestUrl.searchParams.get("trace_id") ?? "";
      const spanId = requestUrl.searchParams.get("span_id") ?? "";
      const linkReady = options.ready.links.find(
        (candidate) => candidate.traceId === traceId && candidate.spanId === spanId,
      );
      if (!linkReady) {
        throw new Error(`unexpected materialized debug-session link ${requestUrl.toString()}`);
      }

      const upstreamUrl = `${options.ready.baseUrl}${requestUrl.pathname}${requestUrl.search}`;
      const upstreamResponse = await fetch(upstreamUrl, {
        headers: { authorization: `Bearer ${options.ready.callerToken}` },
        redirect: "manual",
      });
      if (upstreamResponse.status !== 302) {
        throw new Error(
          `codetracer-ci materialized debug-session returned HTTP ${upstreamResponse.status}: ${await upstreamResponse.text()}`,
        );
      }

      const replayPayload = await fetchJsonFromUrl(
        `${options.ready.baseUrl}/__tests/replay-provisioning/latest`,
      );
      expect(replayPayload.traceSource.kind).toBe("materialized_trace");
      expect(replayPayload.traceSource.artifacts[0].artifactKey).toBe(
        linkReady.materializedArtifactKey,
      );
      expect(replayPayload.initialPosition.materializedMomentId).toBe(
        linkReady.momentId,
      );
      expect(replayPayload.initialPosition.materializedArtifactKey).toBe(
        linkReady.materializedArtifactKey,
      );

      const httpPort = await getFreeTcpPort();
      const backendPort = await getFreeTcpPort();
      const hostOutput: string[] = [];
      const ctProcess = childProcess.spawn(
        codetracerPath,
        [
          "host",
          `--manifest=${linkReady.manifestPath}`,
          `--storage-base-url=${options.ready.baseUrl}`,
          `--storage-tenant-id=${options.ready.tenantId}`,
          `--storage-token=${options.ready.replayToken}`,
          "--storage-protocol=local-storage",
          `--port=${httpPort}`,
          `--backend-socket-port=${backendPort}`,
          `--frontend-socket=${backendPort}`,
        ],
        {
          cwd: codetracerInstallDir,
          env: makeCleanEnv({
            XDG_CONFIG_HOME: path.join(
              options.runnerRoot,
              `xdg-config-${linkReady.language}`,
            ),
          }),
          stdio: ["ignore", "pipe", "pipe"],
          windowsHide: true,
        },
      );
      ctProcess.stdout?.on("data", (chunk: Buffer) => {
        hostOutput.push(chunk.toString());
      });
      ctProcess.stderr?.on("data", (chunk: Buffer) => {
        hostOutput.push(chunk.toString());
      });
      await waitForOutput(hostOutput, /imported manifest trace as trace id\s+\d+/);
      const hostUrl = `http://127.0.0.1:${httpPort}`;
      options.launches.push({ ctProcess, hostOutput, hostUrl, linkReady, replayPayload });
      response.writeHead(302, { location: hostUrl });
      response.end();
    } catch (error) {
      response.writeHead(500, { "content-type": "text/plain; charset=utf-8" });
      response.end(error instanceof Error ? error.stack : String(error));
    }
  });
  server.listen(options.port, "127.0.0.1");
  return server;
}

base.describe("Observability M34 storage-server MCR manifest browser acceptance", () => {
  base.describe.configure({ mode: "serial", timeout: 300_000 });

  base("ct host --manifest falls back from missing primary shard replicas to secondary storage replicas", async ({}) => {
    expectRequiredFile("CodeTracer test binary", codetracerPath);
    expectRequiredFile("codetracer-ci storage harness project", storageHarnessProject);
    expectRequiredFile("ReplayAgent project", replayAgentProject);
    expectRequiredFile("real MCR request trace fixture", portableTracePath);
    expectRequiredFile("MCR request source file", fixtureSourcePath);
    expectRequiredFile("MCR request binary fixture", fixtureBinaryPath);
    expectRequiredFile("MCR request details fixture", fixtureRequestDetailsPath);

    const prepared = prepareStorageHarnessInput();
    let storageHarness: Awaited<ReturnType<typeof startStorageHarness>> | null = null;
    let ctProcess: childProcess.ChildProcess | null = null;
    let browser: Awaited<ReturnType<typeof chromium.launch>> | null = null;

    try {
      storageHarness = await startStorageHarness(prepared.inputPath);
      expect(storageHarness.ready.selectedSegmentIndex).toBe(
        prepared.selectedSegmentIndex,
      );
      expect(storageHarness.ready.serverIds.length).toBe(2);
      const storageManifest = JSON.parse(
        fs.readFileSync(storageHarness.ready.manifestPath, "utf-8"),
      );
      expect(storageManifest.source.kind).toBe("sharded_split_ctfs");
      const selectedSegment = storageManifest.source.segments.find(
        (segment: any) => segment.index === prepared.selectedSegmentIndex,
      );
      expect(selectedSegment).toBeTruthy();
      expect(selectedSegment.shards.length).toBeGreaterThanOrEqual(2);
      for (const shard of selectedSegment.shards) {
        expect(shard.replicas.length).toBe(2);
        expect(shard.replicas.map((replica: any) => replica.storageServerId))
          .toEqual(storageHarness.ready.serverIds);
      }
      const fallbackSetup = forceSelectedSegmentPrimaryReplicaMiss(
        storageHarness.ready.manifestPath,
        prepared.selectedSegmentIndex,
      );
      expect(fallbackSetup.primaryServerId).toBe(storageHarness.ready.serverIds[0]);
      expect(fallbackSetup.secondaryServerId).toBe(storageHarness.ready.serverIds[1]);
      expect(fallbackSetup.missingObjectKeys.length).toBe(selectedSegment.shards.length);
      expect(fallbackSetup.secondaryObjectKeys.length).toBe(selectedSegment.shards.length);

      fs.rmSync(prepared.rootDir, { recursive: true, force: true });

      const httpPort = await getFreeTcpPort();
      const backendPort = await getFreeTcpPort();
      const hostOutput: string[] = [];
      ctProcess = childProcess.spawn(
        codetracerPath,
        [
          "host",
          `--manifest=${storageHarness.ready.manifestPath}`,
          `--storage-base-url=${storageHarness.ready.baseUrl}`,
          `--storage-tenant-id=${storageHarness.ready.tenantId}`,
          `--storage-token=${storageHarness.ready.replayToken}`,
          "--storage-protocol=local-storage",
          `--port=${httpPort}`,
          `--backend-socket-port=${backendPort}`,
          `--frontend-socket=${backendPort}`,
        ],
        {
          cwd: codetracerInstallDir,
          env: makeCleanEnv({
            XDG_CONFIG_HOME: path.join(os.tmpdir(), `ct-m34-xdg-${Date.now()}`),
          }),
          stdio: ["ignore", "pipe", "pipe"],
          windowsHide: true,
        },
      );
      ctProcess.stdout?.on("data", (chunk: Buffer) => {
        hostOutput.push(chunk.toString());
      });
      ctProcess.stderr?.on("data", (chunk: Buffer) => {
        hostOutput.push(chunk.toString());
      });

      browser = await chromium.launch({
        executablePath: resolveChromiumPath(),
        args: (process.env.CODETRACER_ELECTRON_ARGS ?? "")
          .split(/\s+/)
          .filter(Boolean),
      });
      const page = await browser.newPage();

      const importOutput = await waitForOutput(
        hostOutput,
        /imported manifest trace as trace id\s+\d+/,
      );
      expect(importOutput).toContain("loaded local manifest:");
      expect(importOutput).toContain("fetching CTFS shard replica from storage:");
      expect(importOutput).toContain("CTFS shard replica read failed; trying next replica:");
      expect(importOutput).toContain("HTTP 404");
      expect(importOutput).toContain(storageHarness.ready.baseUrl);
      expect(importOutput).toContain(
        `/servers/${storageHarness.ready.serverIds[0]}/objects/`,
      );
      expect(importOutput).toContain(
        `/servers/${storageHarness.ready.serverIds[1]}/objects/`,
      );
      for (const missingObjectKey of fallbackSetup.missingObjectKeys) {
        expect(importOutput).toContain(encodeURIComponent(missingObjectKey));
      }
      for (const secondaryObjectKey of fallbackSetup.secondaryObjectKeys) {
        expect(importOutput).toContain(encodeURIComponent(secondaryObjectKey));
      }
      expect(importOutput).toContain("fetching storage support file inventory_smoke.c from storage:");
      expect(importOutput).toContain("fetching storage support file inventory-response.json from storage:");

      await connectToHost(page, httpPort, hostOutput);
      await expect(page.locator(".lm_content").first()).toBeVisible({
        timeout: 30_000,
      });

      const sourceNode = page
        .locator(".jstree-anchor")
        .filter({ hasText: /^inventory_smoke\.c$/ })
        .first();
      await expect(sourceNode).toBeVisible({ timeout: 30_000 });
      await sourceNode.click();

      const sourceText = await waitForEditorModelText(page, "handle_client");
      await waitForEditorModelText(page, "reserve_from_primary_bin");

      const requestDetailsNode = page
        .locator(".jstree-anchor")
        .filter({ hasText: /^inventory-response\.json$/ })
        .first();
      await expect(requestDetailsNode).toBeVisible({ timeout: 30_000 });
      await requestDetailsNode.click();
      const requestDetailsText = await waitForVisibleEditorText(
        page,
        `"requestId": "m25-real-mcr-request-001"`,
      );
      await waitForVisibleEditorText(page, `"branch": "reserve_from_primary_bin"`);
      const bodyText = await page.evaluate(() => document.body.innerText);
      const traceMetadata = await page.evaluate(() => {
        const d = (window as any).data;
        const trace = d?.sessions?.[d?.activeSessionIndex ?? 0]?.trace;
        return {
          id: Number(trace?.id ?? -1),
          outputFolder: String(trace?.outputFolder ?? ""),
        };
      });

      expect(bodyText).toContain("inventory_smoke.c");
      expect(bodyText).toContain("inventory-response.json");
      expect(sourceText).toContain("handle_client");
      expect(sourceText).toContain("reserve_from_primary_bin");
      expect(requestDetailsText).toContain(
        `"requestId": "m25-real-mcr-request-001"`,
      );
      expect(requestDetailsText).toContain(
        `"branch": "reserve_from_primary_bin"`,
      );
      expect(traceMetadata.id).toBeGreaterThan(0);
      expect(traceMetadata.outputFolder).toContain("trace-");
    } finally {
      if (ctProcess?.pid) {
        killProcessTree(ctProcess.pid);
      }
      if (storageHarness?.process.pid) {
        killProcessTree(storageHarness.process.pid);
      }
      if (browser) {
        await browser.close().catch(() => undefined);
      }
      fs.rmSync(prepared.rootDir, { recursive: true, force: true });
      await sleep(500);
    }
  });

  base("debug-session provisioning reaches storage-server ct host through ReplayAgent entrypoint", async ({}) => {
    expectRequiredFile("CodeTracer test binary", codetracerPath);
    expectRequiredFile("codetracer-ci storage harness project", storageHarnessProject);
    expectRequiredFile(
      "ReplayAgent runner entrypoint",
      path.join(codetracerCiDir, "resources", "docker", "codetracer-runner", "replay-entrypoint.sh"),
    );
    expectRequiredFile("real MCR request trace fixture", portableTracePath);
    expectRequiredFile("MCR request source file", fixtureSourcePath);
    expectRequiredFile("MCR request binary fixture", fixtureBinaryPath);
    expectRequiredFile("MCR request details fixture", fixtureRequestDetailsPath);

    const prepared = prepareStorageHarnessInput();
    let debugHarness: Awaited<ReturnType<typeof startDebugSessionHarness>> | null = null;
    let ctProcess: childProcess.ChildProcess | null = null;
    let browser: Awaited<ReturnType<typeof chromium.launch>> | null = null;
    const runnerRoot = fs.mkdtempSync(
      path.join(os.tmpdir(), "ct-m34-replay-agent-entrypoint-"),
    );

    try {
      debugHarness = await startDebugSessionHarness(prepared.inputPath);
      fs.rmSync(prepared.rootDir, { recursive: true, force: true });

      expect(debugHarness.ready.debugSession.status).toBe("Provisioning");
      expect(debugHarness.ready.selectedSegmentIndex).toBe(
        prepared.selectedSegmentIndex,
      );
      expect(debugHarness.ready.replayPayload.traceSource.storageBaseUrl).toBe(
        debugHarness.ready.baseUrl,
      );
      expect(debugHarness.ready.replayPayload.traceSource.storageReplayToken).toBe(
        debugHarness.ready.replayToken,
      );
      expect(debugHarness.ready.replayPayload.traceSource.storageReplayToken).not.toBe(
        debugHarness.ready.callerToken,
      );
      expect(debugHarness.ready.callerToken).not.toContain(":");
      expect(debugHarness.ready.replayToken).toMatch(/^ct_replay_storage_/);
      expect(debugHarness.ready.authProbes.replayTokenSelectedObjectStatus).toBe(200);
      expect(debugHarness.ready.authProbes.replayTokenCrossTraceStatus).toBe(403);
      expect(debugHarness.ready.authProbes.replayTokenGeneralApiStatus).toBe(401);
      expect(debugHarness.ready.authProbes.userTokenStorageReadStatus).toBe(403);
      expect(debugHarness.ready.replayPayload.traceSource.storageProtocol).toBe(
        "local-storage",
      );
      const selectedReplaySegment =
        debugHarness.ready.replayPayload.traceSource.shardedMcrSegments.find(
          (segment: any) => segment.segmentIndex === prepared.selectedSegmentIndex,
        );
      expect(selectedReplaySegment).toBeTruthy();
      const supportFileNames = (selectedReplaySegment.supportFiles ?? []).map(
        (file: any) => file.relativePath,
      );
      expect(supportFileNames).toContain("inventory-response.json");
      expect(supportFileNames).not.toContain("expired-support-should-not-load.txt");
      expect(supportFileNames).not.toContain("incomplete-support-should-not-load.txt");
      const responseSupportFile = selectedReplaySegment.supportFiles.find(
        (file: any) => file.relativePath === "inventory-response.json",
      );
      expect(responseSupportFile.uploadCompletionState).toBe("complete");
      expect(responseSupportFile.retentionStatus).toBe("available");
      expect(
        debugHarness.ready.replayPayload.traceSource.shardedMcrSegments.some(
          (segment: any) =>
            segment.segmentIndex === prepared.selectedSegmentIndex &&
            segment.supportFiles?.some(
              (file: any) => file.relativePath === "inventory-response.json",
            ),
        ),
      ).toBe(true);
      const replayAgentCommandLine = generateReplayAgentCommand(
        debugHarness.ready.replayPayload,
        runnerRoot,
      );
      expect(replayAgentCommandLine).toContain("docker run ");
      expect(replayAgentCommandLine).toContain(
        "CODETRACER_TRACE_SHARDED_MCR_SEGMENTS=",
      );
      expect(replayAgentCommandLine).toContain(
        "CODETRACER_STORAGE_REPLAY_TOKEN=",
      );

      const replayEnv = parseReplayAgentEnv(replayAgentCommandLine);
      expect(replayEnv.CODETRACER_TRACE_MANIFEST_KEY).toBe(
        debugHarness.ready.manifestKey,
      );
      expect(replayEnv.CODETRACER_STORAGE_BASE_URL).toBe(
        debugHarness.ready.baseUrl,
      );
      expect(replayEnv.CODETRACER_STORAGE_REPLAY_TOKEN).toBe(
        debugHarness.ready.replayToken,
      );
      expect(replayEnv.CODETRACER_TRACE_SHARDED_MCR_SEGMENTS).toContain(
        "inventory-response.json",
      );
      expect(replayEnv.CODETRACER_TRACE_SHARDED_MCR_SEGMENTS).toContain(
        "\"uploadCompletionState\":\"complete\"",
      );
      expect(replayEnv.CODETRACER_TRACE_SHARDED_MCR_SEGMENTS).toContain(
        "\"retentionStatus\":\"available\"",
      );
      expect(replayEnv.CODETRACER_TRACE_SHARDED_MCR_SEGMENTS).not.toContain(
        "expired-support-should-not-load.txt",
      );
      expect(replayEnv.CODETRACER_TRACE_SHARDED_MCR_SEGMENTS).not.toContain(
        "incomplete-support-should-not-load.txt",
      );

      const httpPort = await getFreeTcpPort();
      const backendPort = await getFreeTcpPort();
      const hostOutput: string[] = [];
      const shimDir = createCtPathShim(runnerRoot);
      const entrypointPath = path.join(
        codetracerCiDir,
        "resources",
        "docker",
        "codetracer-runner",
        "replay-entrypoint.sh",
      );
      ctProcess = childProcess.spawn(
        "bash",
        [
          entrypointPath,
          `--port=${httpPort}`,
          `--backend-socket-port=${backendPort}`,
          `--frontend-socket=${backendPort}`,
        ],
        {
          cwd: codetracerInstallDir,
          env: {
            ...makeCleanEnv({
              XDG_CONFIG_HOME: path.join(runnerRoot, "xdg-config"),
            }),
            ...replayEnv,
            CODETRACER_WORK_DIR: path.join(runnerRoot, "work"),
            PATH: `${shimDir}${path.delimiter}${process.env.PATH ?? ""}`,
          },
          stdio: ["ignore", "pipe", "pipe"],
          windowsHide: true,
        },
      );
      ctProcess.stdout?.on("data", (chunk: Buffer) => {
        hostOutput.push(chunk.toString());
      });
      ctProcess.stderr?.on("data", (chunk: Buffer) => {
        hostOutput.push(chunk.toString());
      });

      browser = await chromium.launch({
        executablePath: resolveChromiumPath(),
        args: (process.env.CODETRACER_ELECTRON_ARGS ?? "")
          .split(/\s+/)
          .filter(Boolean),
      });
      const page = await browser.newPage();

      const importOutput = await waitForOutput(
        hostOutput,
        /imported manifest trace as trace id\s+\d+/,
      );
      expect(importOutput).toContain("Starting host from generated replay manifest");
      expect(importOutput).toContain("loaded local manifest:");
      expect(importOutput).toContain("fetching CTFS shard replica from storage:");
      expect(importOutput).toContain(debugHarness.ready.baseUrl);
      expect(importOutput).toContain("fetching storage support file inventory_smoke.c from storage:");
      expect(importOutput).toContain("fetching storage support file inventory-response.json from storage:");
      expect(importOutput).not.toContain("expired-support-should-not-load.txt");
      expect(importOutput).not.toContain("incomplete-support-should-not-load.txt");

      await connectToHost(page, httpPort, hostOutput);
      await expect(page.locator(".lm_content").first()).toBeVisible({
        timeout: 30_000,
      });

      const sourceNode = page
        .locator(".jstree-anchor")
        .filter({ hasText: /^inventory_smoke\.c$/ })
        .first();
      await expect(sourceNode).toBeVisible({ timeout: 30_000 });
      await sourceNode.click();

      const sourceText = await waitForEditorModelText(page, "handle_client");
      await waitForEditorModelText(page, "reserve_from_primary_bin");

      const requestDetailsNode = page
        .locator(".jstree-anchor")
        .filter({ hasText: /^inventory-response\.json$/ })
        .first();
      await expect(requestDetailsNode).toBeVisible({ timeout: 30_000 });
      await requestDetailsNode.click();
      const requestDetailsText = await waitForVisibleEditorText(
        page,
        `"requestId": "m25-real-mcr-request-001"`,
      );
      await waitForVisibleEditorText(page, `"branch": "reserve_from_primary_bin"`);

      const bodyText = await page.evaluate(() => document.body.innerText);
      const traceMetadata = await page.evaluate(() => {
        const d = (window as any).data;
        const trace = d?.sessions?.[d?.activeSessionIndex ?? 0]?.trace;
        return {
          id: Number(trace?.id ?? -1),
          outputFolder: String(trace?.outputFolder ?? ""),
        };
      });

      expect(bodyText).toContain("inventory_smoke.c");
      expect(bodyText).toContain("inventory-response.json");
      expect(sourceText).toContain("handle_client");
      expect(sourceText).toContain("reserve_from_primary_bin");
      expect(requestDetailsText).toContain(
        `"requestId": "m25-real-mcr-request-001"`,
      );
      expect(requestDetailsText).toContain(
        `"branch": "reserve_from_primary_bin"`,
      );
      expect(traceMetadata.id).toBeGreaterThan(0);
      expect(traceMetadata.outputFolder).toContain("trace-");
    } finally {
      if (ctProcess?.pid) {
        killProcessTree(ctProcess.pid);
      }
      if (debugHarness?.process.pid) {
        killProcessTree(debugHarness.process.pid);
      }
      if (browser) {
        await browser.close().catch(() => undefined);
      }
      fs.rmSync(prepared.rootDir, { recursive: true, force: true });
      fs.rmSync(runnerRoot, { recursive: true, force: true });
      await sleep(500);
    }
  });

  base("M36 real Jaeger UI link launches routed-storage CodeTracer replay", async ({ page }) => {
    expectRequiredFile("CodeTracer test binary", codetracerPath);
    expectRequiredFile("codetracer-ci storage harness project", storageHarnessProject);
    expectRequiredFile(
      "ReplayAgent runner entrypoint",
      path.join(codetracerCiDir, "resources", "docker", "codetracer-runner", "replay-entrypoint.sh"),
    );
    expectRequiredFile("Jaeger plugin UI config", jaegerUiConfigPath());
    expectRequiredFile("Jaeger plugin UI config renderer", jaegerUiConfigRendererPath());
    expectRequiredFile("real MCR request trace fixture", portableTracePath);
    expectRequiredFile("MCR request source file", fixtureSourcePath);
    expectRequiredFile("MCR request binary fixture", fixtureBinaryPath);
    expectRequiredFile("MCR request details fixture", fixtureRequestDetailsPath);
    childProcess.execFileSync(dockerBin(), ["version", "--format", "{{.Server.Version}}"], {
      encoding: "utf-8",
      stdio: ["ignore", "pipe", "pipe"],
      windowsHide: true,
    });

    const prepared = prepareStorageHarnessInput();
    const runnerRoot = fs.mkdtempSync(
      path.join(os.tmpdir(), "ct-m36-jaeger-platform-link-"),
    );
    let platformHarness: Awaited<ReturnType<typeof startPlatformLinkHarness>> | null = null;
    let jaegerProcess: childProcess.ChildProcess | null = null;
    let bridge: http.Server | null = null;
    const launches: Array<{ ctProcess: childProcess.ChildProcess; hostOutput: string[]; hostUrl: string }> = [];

    try {
      platformHarness = await startPlatformLinkHarness(prepared.inputPath);
      expect(platformHarness.ready.selectedSegmentIndex).toBe(
        prepared.selectedSegmentIndex,
      );
      fs.rmSync(prepared.rootDir, { recursive: true, force: true });

      const jaegerUiPort = await getFreeTcpPort();
      const jaegerOtlpPort = await getFreeTcpPort();
      const bridgePort = await getFreeTcpPort();
      const bridgeBaseUrl = `http://127.0.0.1:${bridgePort}`;
      const jaegerBaseUrl = `http://127.0.0.1:${jaegerUiPort}`;
      const debugParams = new URLSearchParams({
        tenant_id: platformHarness.ready.tenantId,
        "service.name": platformHarness.ready.serviceName,
        trace_id: platformHarness.ready.traceId,
        span_id: platformHarness.ready.spanId,
        "ct.mcr.wall_time_unix_ns": platformHarness.ready.wallTimeUnixNs,
        "ct.mcr.monotonic_time_ns": platformHarness.ready.monotonicTimeNs,
        time_window_ns: platformHarness.ready.timeWindowNs,
      });
      const debugUrl = `${bridgeBaseUrl}/observability/v0/debug-session?${debugParams.toString()}`;
      const renderedJaegerUiConfigPath = renderJaegerUiConfigForDebugBase(
        runnerRoot,
        bridgeBaseUrl,
      );

      bridge = startPlatformLaunchBridge({
        rootDir: runnerRoot,
        ready: platformHarness.ready,
        runnerRoot,
        port: bridgePort,
        launches,
      });
      jaegerProcess = startJaegerAllInOne(
        runnerRoot,
        renderedJaegerUiConfigPath,
        jaegerUiPort,
        jaegerOtlpPort,
      );
      await waitFor(
        "Jaeger UI readiness",
        async () => fetchJsonFromUrl(`${jaegerBaseUrl}/api/services`),
        120_000,
      );
      await ingestJaegerSpan(jaegerOtlpPort, platformHarness.ready, debugUrl);
      await waitFor(
        "Jaeger trace ingestion",
        async () => fetchJsonFromUrl(`${jaegerBaseUrl}/api/traces/${platformHarness.ready.traceId}`),
        60_000,
      );

      const cliRow = await runCtObserveAgainstJaeger(
        jaegerBaseUrl,
        platformHarness.ready,
      );
      expect(cliRow.codetracer_debug_session_url).toBe(debugUrl);
      expect(cliRow.recording_available).toBe(true);
      expect(cliRow.request_key).toBe("m25-real-mcr-request-001");

      await page.goto(`${jaegerBaseUrl}/trace/${platformHarness.ready.traceId}`, {
        waitUntil: "domcontentloaded",
        timeout: 60_000,
      });
      await page.getByText("GET /reserve").first().waitFor({ timeout: 60_000 });
      const spanRow = page.getByRole("switch", {
        name: /inventory GET \/reserve/,
      });
      await spanRow.click();

      await page.getByRole("switch", { name: /Tags/ }).click();
      const link = page.locator('a[title="Debug in CodeTracer"]').first();
      await expect(link).toBeVisible({ timeout: 60_000 });
      expect(await link.getAttribute("href")).toBe(debugUrl);

      const popupPromise = page.context().waitForEvent("page", { timeout: 5_000 }).catch(() => null);
      await link.click();
      const popup = await popupPromise;
      const replayPage = popup ?? page;
      await replayPage.waitForURL(/http:\/\/127\.0\.0\.1:\d+\//, {
        timeout: 120_000,
      });

      await waitFor(
        "platform launch bridge started CodeTracer",
        async () => {
          if (launches.length !== 1) {
            throw new Error(`expected one CodeTracer launch, got ${launches.length}`);
          }
        },
        120_000,
      );
      const launch = launches[0];
      await replayPage.waitForURL(`${launch.hostUrl}/`, { timeout: 120_000 });
      await waitForRealReplayDetails(replayPage, launch.hostOutput);
      const artifactDir = m36ArtifactDir();
      if (artifactDir) {
        fs.mkdirSync(artifactDir, { recursive: true });
        fs.writeFileSync(path.join(artifactDir, "jaeger-debug-url.txt"), debugUrl);
        fs.writeFileSync(
          path.join(artifactDir, "ct-observe-jaeger-row.json"),
          JSON.stringify(cliRow, null, 2),
        );
        fs.writeFileSync(
          path.join(artifactDir, "ct-host-output.log"),
          launch.hostOutput.join(""),
        );
        const jaegerLog = path.join(runnerRoot, "jaeger-docker.log");
        if (fs.existsSync(jaegerLog)) {
          fs.copyFileSync(jaegerLog, path.join(artifactDir, "jaeger-docker.log"));
        }
      }
      await replayPage.screenshot({
        path: path.join(
          m36ArtifactDir() ?? runnerRoot,
          "m36-jaeger-real-codetracer-replay.png",
        ),
        fullPage: true,
      });
    } finally {
      for (const launch of launches) {
        if (launch.ctProcess.pid) {
          killProcessTree(launch.ctProcess.pid);
        }
      }
      if (bridge) {
        await new Promise<void>((resolve) => bridge?.close(() => resolve()));
      }
      await stopJaegerAllInOne(runnerRoot, jaegerProcess);
      if (platformHarness?.process.pid) {
        killProcessTree(platformHarness.process.pid);
      }
      fs.rmSync(prepared.rootDir, { recursive: true, force: true });
      fs.rmSync(runnerRoot, { recursive: true, force: true });
      await sleep(500);
    }
  });

  base("M36 real Jaeger UI links launch materialized Python Ruby and JavaScript CodeTracer replays", async ({ page }) => {
    expectRequiredFile("CodeTracer test binary", codetracerPath);
    expectRequiredFile("codetracer-ci storage harness project", storageHarnessProject);
    expectRequiredFile("Jaeger plugin UI config renderer", jaegerUiConfigRendererPath());
    for (const fixture of materializedFixtures) {
      expectRequiredFile(`${fixture.label} materialized trace fixture`, fixture.traceDir);
      expectRequiredFile(
        `${fixture.label} materialized ${fixture.traceFileName}`,
        path.join(fixture.traceDir, fixture.traceFileName),
      );
      expectRequiredFile(
        `${fixture.label} materialized trace metadata`,
        path.join(fixture.traceDir, "trace_metadata.json"),
      );
      expectRequiredFile(
        `${fixture.label} materialized trace paths`,
        path.join(fixture.traceDir, "trace_paths.json"),
      );
    }
    childProcess.execFileSync(dockerBin(), ["version", "--format", "{{.Server.Version}}"], {
      encoding: "utf-8",
      stdio: ["ignore", "pipe", "pipe"],
      windowsHide: true,
    });

    const prepared = prepareMaterializedPlatformHarnessInput();
    const runnerRoot = fs.mkdtempSync(
      path.join(os.tmpdir(), "ct-m36-jaeger-materialized-platform-link-"),
    );
    let platformHarness: Awaited<ReturnType<typeof startMaterializedPlatformLinkHarness>> | null = null;
    let jaegerProcess: childProcess.ChildProcess | null = null;
    let bridge: http.Server | null = null;
    const launches: Array<{
      ctProcess: childProcess.ChildProcess;
      hostOutput: string[];
      hostUrl: string;
      linkReady: MaterializedPlatformLink;
      replayPayload: any;
    }> = [];
    const cliRows: Record<string, any> = {};

    try {
      platformHarness = await startMaterializedPlatformLinkHarness(prepared.inputPath);
      expect(platformHarness.ready.links.map((link) => link.language).sort())
        .toEqual(materializedFixtures.map((fixture) => fixture.language).sort());
      fs.rmSync(prepared.rootDir, { recursive: true, force: true });

      const jaegerUiPort = await getFreeTcpPort();
      const jaegerOtlpPort = await getFreeTcpPort();
      const bridgePort = await getFreeTcpPort();
      const bridgeBaseUrl = `http://127.0.0.1:${bridgePort}`;
      const jaegerBaseUrl = `http://127.0.0.1:${jaegerUiPort}`;
      const renderedJaegerUiConfigPath = renderJaegerUiConfigForDebugBase(
        runnerRoot,
        bridgeBaseUrl,
      );

      bridge = startMaterializedPlatformLaunchBridge({
        ready: platformHarness.ready,
        runnerRoot,
        port: bridgePort,
        launches,
      });
      jaegerProcess = startJaegerAllInOne(
        runnerRoot,
        renderedJaegerUiConfigPath,
        jaegerUiPort,
        jaegerOtlpPort,
      );
      await waitFor(
        "Jaeger UI readiness",
        async () => fetchJsonFromUrl(`${jaegerBaseUrl}/api/services`),
        120_000,
      );

      for (const linkReady of platformHarness.ready.links) {
        const debugParams = new URLSearchParams({
          tenant_id: platformHarness.ready.tenantId,
          "service.name": linkReady.serviceName,
          trace_id: linkReady.traceId,
          span_id: linkReady.spanId,
          "ct.mcr.wall_time_unix_ns": linkReady.wallTimeUnixNs,
          "ct.mcr.monotonic_time_ns": linkReady.monotonicTimeNs,
          time_window_ns: linkReady.timeWindowNs,
        });
        const debugUrl = `${bridgeBaseUrl}/observability/v0/debug-session?${debugParams.toString()}`;
        await ingestMaterializedJaegerSpan(
          jaegerOtlpPort,
          platformHarness.ready,
          linkReady,
          debugUrl,
        );
        await waitFor(
          `${linkReady.label} Jaeger trace ingestion`,
          async () => fetchJsonFromUrl(`${jaegerBaseUrl}/api/traces/${linkReady.traceId}`),
          60_000,
        );

        const cliRow = await runMaterializedCtObserveAgainstJaeger(
          jaegerBaseUrl,
          linkReady,
        );
        expect(cliRow.codetracer_debug_session_url).toBe(debugUrl);
        expect(cliRow.recording_available).toBe(true);
        expect(cliRow.request_key).toBe(linkReady.requestKey);
        cliRows[linkReady.language] = cliRow;
      }

      for (const fixture of materializedFixtures) {
        const linkReady = platformHarness.ready.links.find(
          (candidate) => candidate.language === fixture.language,
        );
        expect(linkReady, `${fixture.label} platform link ready`).toBeTruthy();
        await page.goto(`${jaegerBaseUrl}/trace/${linkReady!.traceId}`, {
          waitUntil: "domcontentloaded",
          timeout: 60_000,
        });
        await page.getByText(linkReady!.operationName).first().waitFor({
          timeout: 60_000,
        });
        await page
          .getByRole("switch", {
            name: new RegExp(`${escapeRegExp(linkReady!.serviceName)}.*${escapeRegExp(linkReady!.operationName)}`),
          })
          .click();

        await page.getByRole("switch", { name: /Tags/ }).click();
        const link = page.locator('a[title="Debug in CodeTracer"]').first();
        await expect(link).toBeVisible({ timeout: 60_000 });
        expect(await link.getAttribute("href")).toBe(
          cliRows[fixture.language].codetracer_debug_session_url,
        );

        const previousLaunches = launches.length;
        const popupPromise = page.context().waitForEvent("page", { timeout: 5_000 }).catch(() => null);
        await link.click();
        const popup = await popupPromise;
        const replayPage = popup ?? page;
        await replayPage.waitForURL(/http:\/\/127\.0\.0\.1:\d+\//, {
          timeout: 120_000,
        });
        await waitFor(
          `${fixture.label} platform launch bridge started CodeTracer`,
          async () => {
            if (launches.length !== previousLaunches + 1) {
              throw new Error(`expected ${previousLaunches + 1} CodeTracer launches, got ${launches.length}`);
            }
          },
          120_000,
        );
        const launch = launches[launches.length - 1];
        await replayPage.waitForURL(`${launch.hostUrl}/`, { timeout: 120_000 });
        await waitForMaterializedReplayDetails(
          replayPage,
          fixture,
          launch.hostOutput,
        );
        await replayPage.screenshot({
          path: path.join(
            m36ArtifactDir() ?? runnerRoot,
            `m36-jaeger-${fixture.language}-materialized-replay.png`,
          ),
          fullPage: true,
        });
      }

      const artifactDir = m36ArtifactDir();
      if (artifactDir) {
        fs.mkdirSync(artifactDir, { recursive: true });
        fs.writeFileSync(
          path.join(artifactDir, "ct-observe-jaeger-materialized-rows.json"),
          JSON.stringify(cliRows, null, 2),
        );
        fs.writeFileSync(
          path.join(artifactDir, "materialized-replay-payloads.json"),
          JSON.stringify(
            launches.map((launch) => ({
              language: launch.linkReady.language,
              replayPayload: launch.replayPayload,
            })),
            null,
            2,
          ),
        );
      }
    } finally {
      for (const launch of launches) {
        if (launch.ctProcess.pid) {
          killProcessTree(launch.ctProcess.pid);
        }
      }
      if (bridge) {
        await new Promise<void>((resolve) => bridge?.close(() => resolve()));
      }
      await stopJaegerAllInOne(runnerRoot, jaegerProcess);
      if (platformHarness?.process.pid) {
        killProcessTree(platformHarness.process.pid);
      }
      fs.rmSync(prepared.rootDir, { recursive: true, force: true });
      fs.rmSync(runnerRoot, { recursive: true, force: true });
      await sleep(500);
    }
  });
});
