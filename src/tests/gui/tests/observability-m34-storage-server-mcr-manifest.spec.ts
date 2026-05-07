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
import * as net from "node:net";
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

type GrafanaTraceReady = {
  traceId: string;
  wallTimeUnixNs: string;
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

const m36MixedRequestKey = "m25-real-mcr-request-001";

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

function prepareMaterializedPlatformHarnessInput(options?: {
  traceId?: string;
  requestKey?: string;
}): { rootDir: string; inputPath: string } {
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
          traceId: options?.traceId ?? fixture.traceId,
          spanId: fixture.spanId,
          momentId: fixture.momentId,
          requestKey: options?.requestKey ?? fixture.requestKey,
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

function grafanaBin(): string {
  return process.env.CODETRACER_M36_GRAFANA_BIN || "grafana";
}

function tempoBin(): string {
  return process.env.CODETRACER_M36_TEMPO_BIN || "tempo";
}

function grafanaPluginOutPath(): string {
  return process.env.CODETRACER_M36_GRAFANA_PLUGIN_OUT ||
    path.join(
      workspaceRoot,
      "codetracer-observability-grafana",
      "examples",
      "grafana-v12-tempo-v2",
    );
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

async function freeTcpPort(): Promise<number> {
  return await new Promise((resolve, reject) => {
    const server = net.createServer();
    server.on("error", reject);
    server.listen(0, "127.0.0.1", () => {
      const address = server.address();
      if (!address || typeof address === "string") {
        reject(new Error("failed to allocate TCP port"));
        return;
      }
      server.close(() => resolve(address.port));
    });
  });
}

function spawnLogged(
  rootDir: string,
  command: string,
  args: string[],
  logFileName: string,
  options: childProcess.SpawnOptions = {},
): childProcess.ChildProcess {
  const logPath = path.join(rootDir, logFileName);
  const fd = fs.openSync(logPath, "a");
  const child = childProcess.spawn(command, args, {
    ...options,
    stdio: ["ignore", fd, fd],
    windowsHide: true,
  });
  child.on("exit", () => fs.closeSync(fd));
  return child;
}

async function stopChild(child: childProcess.ChildProcess | null): Promise<void> {
  if (!child || child.exitCode !== null || child.signalCode !== null) return;
  await new Promise<void>((resolve) => {
    const timer = setTimeout(() => {
      if (child.exitCode === null && child.signalCode === null) {
        child.kill("SIGKILL");
      }
    }, 5_000);
    child.once("exit", () => {
      clearTimeout(timer);
      resolve();
    });
    child.kill("SIGTERM");
  });
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
  requestKey = "m25-real-mcr-request-001",
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
                  { key: "request.id", value: { stringValue: requestKey } },
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

async function startTempoServer(
  rootDir: string,
  tempoHttpPort: number,
  tempoGrpcPort: number,
  otlpPort: number,
  tempoBaseUrl: string,
): Promise<childProcess.ChildProcess> {
  const tempoConfig = path.join(rootDir, "tempo.yaml");
  fs.writeFileSync(
    tempoConfig,
    `server:
  http_listen_address: 127.0.0.1
  http_listen_port: ${tempoHttpPort}
  grpc_listen_address: 127.0.0.1
  grpc_listen_port: ${tempoGrpcPort}
distributor:
  receivers:
    otlp:
      protocols:
        http:
          endpoint: 127.0.0.1:${otlpPort}
ingester:
  trace_idle_period: 1s
  max_block_bytes: 1048576
  max_block_duration: 10s
compactor:
  compaction:
    block_retention: 1h
storage:
  trace:
    backend: local
    wal:
      path: ${path.join(rootDir, "tempo-wal")}
    local:
      path: ${path.join(rootDir, "tempo-blocks")}
`,
  );
  const child = spawnLogged(
    rootDir,
    tempoBin(),
    [`-config.file=${tempoConfig}`],
    "tempo.log",
    { env: makeCleanEnv() },
  );
  await waitFor(
    "Tempo readiness",
    async () => {
      if (child.exitCode !== null) {
        throw new Error(`Tempo exited with code ${child.exitCode}`);
      }
      const response = await fetch(`${tempoBaseUrl}/ready`);
      if (!response.ok) throw new Error(`Tempo /ready returned ${response.status}`);
    },
    120_000,
  );
  return child;
}

function copyDirectory(source: string, target: string): void {
  fs.mkdirSync(target, { recursive: true });
  for (const entry of fs.readdirSync(source, { withFileTypes: true })) {
    const sourcePath = path.join(source, entry.name);
    const targetPath = path.join(target, entry.name);
    if (entry.isDirectory()) {
      copyDirectory(sourcePath, targetPath);
    } else if (entry.isFile()) {
      fs.copyFileSync(sourcePath, targetPath);
      fs.chmodSync(targetPath, 0o600);
    }
  }
}

function replaceFileText(filePath: string, replace: (text: string) => string): void {
  fs.writeFileSync(filePath, replace(fs.readFileSync(filePath, "utf-8")));
}

function renderGrafanaProvisioningForM36(
  rootDir: string,
  codetracerCiBaseUrl: string,
  tempoBaseUrl: string,
): string {
  const pluginShare = path.join(
    grafanaPluginOutPath(),
    "share",
    "codetracer-observability-grafana",
  );
  const source = fs.existsSync(pluginShare) ? pluginShare : grafanaPluginOutPath();
  expectRequiredFile("Grafana Tempo provisioning source", source);
  const target = path.join(rootDir, "grafana-provisioning");
  copyDirectory(source, target);

  replaceFileText(
    path.join(target, "provisioning", "datasources", "codetracer-tempo.yaml"),
    (text) =>
      text
        .replaceAll("https://codetracer-ci.example", codetracerCiBaseUrl)
        .replaceAll("http://tempo:3200", tempoBaseUrl)
        .replace(/^    version: .+$/m, "    version: 1")
        .replace(
          /url: ".*\/observability\/v0\/debug-session[^"]*"/,
          () =>
            `url: "${codetracerCiBaseUrl}/observability/v0/debug-session?tenant_id=$$tenantId&trace_id=$$traceID&span_id=$$spanID&service.name=$$serviceName&ct.recording_available=$$recordingAvailable&ct.mcr.wall_time_unix_ns=$$wallTimeUnixNs&ct.mcr.monotonic_time_ns=$$monotonicTimeNs&time_window_ns=$$timeWindowNs"`,
        )
        .replace(
          /^          field: .+\n          transformations:\n[\s\S]*$/m,
          `          field: traceID
          transformations:
            - type: regex
              field: traceID
              expression: '(.+)'
              mapValue: traceID
            - type: regex
              field: traceId
              expression: '(.+)'
              mapValue: traceID
            - type: regex
              field: spanID
              expression: '(.+)'
              mapValue: spanID
            - type: regex
              field: spanId
              expression: '(.+)'
              mapValue: spanID
            - type: regex
              field: serviceName
              expression: '(.+)'
              mapValue: serviceName
            - type: regex
              field: service.name
              expression: '(.+)'
              mapValue: serviceName
            - type: regex
              field: serviceTags
              expression: '{(?=[^\\}]*\\bkey":"service.name")[^\\}]*\\bvalue":"([^"]+)".*}'
              mapValue: serviceName
            - type: regex
              field: tags
              expression: '{(?=[^\\}]*\\bkey":"tenant_id")[^\\}]*\\bvalue":"([^"]+)".*}'
              mapValue: tenantId
            - type: regex
              field: tags
              expression: '{(?=[^\\}]*\\bkey":"ct.recording_available")[^\\}]*\\bvalue":(true).*}'
              mapValue: recordingAvailable
            - type: regex
              field: tags
              expression: '{(?=[^\\}]*\\bkey":"ct.mcr.wall_time_unix_ns")[^\\}]*\\bvalue":"([^"]+)".*}'
              mapValue: wallTimeUnixNs
            - type: regex
              field: tags
              expression: '{(?=[^\\}]*\\bkey":"ct.mcr.monotonic_time_ns")[^\\}]*\\bvalue":"([^"]+)".*}'
              mapValue: monotonicTimeNs
            - type: regex
              field: tags
              expression: '{(?=[^\\}]*\\bkey":"time_window_ns")[^\\}]*\\bvalue":"([^"]+)".*}'
              mapValue: timeWindowNs
`,
        ),
  );
  replaceFileText(
    path.join(target, "provisioning", "dashboards", "codetracer-dashboard-provider.yaml"),
    (text) =>
      text.replace(
        /path: ".*"/,
        `path: "${path.join(target, "dashboards", "codetracer")}"`,
      ),
  );
  replaceFileText(
    path.join(target, "dashboards", "codetracer", "codetracer-tempo-debug-links.dashboard.json"),
    (text) =>
      text
        .replaceAll("https://codetracer-ci.example", codetracerCiBaseUrl)
        .replaceAll("http://tempo:3200", tempoBaseUrl),
  );
  return target;
}

async function startGrafanaServer(
  rootDir: string,
  grafanaPort: number,
  provisioningDir: string,
  grafanaBaseUrl: string,
): Promise<childProcess.ChildProcess> {
  const realGrafanaBin = fs.realpathSync(grafanaBin());
  const grafanaHome = path.join(path.dirname(path.dirname(realGrafanaBin)), "share", "grafana");
  for (const dir of ["grafana-data", "grafana-logs", "grafana-plugins"]) {
    fs.mkdirSync(path.join(rootDir, dir), { recursive: true });
  }
  const child = spawnLogged(
    rootDir,
    realGrafanaBin,
    ["server", "--homepath", grafanaHome],
    "grafana.log",
    {
      env: makeCleanEnv({
        GF_SERVER_HTTP_ADDR: "127.0.0.1",
        GF_SERVER_HTTP_PORT: String(grafanaPort),
        GF_PATHS_DATA: path.join(rootDir, "grafana-data"),
        GF_PATHS_LOGS: path.join(rootDir, "grafana-logs"),
        GF_PATHS_PLUGINS: path.join(rootDir, "grafana-plugins"),
        GF_PATHS_PROVISIONING: path.join(provisioningDir, "provisioning"),
        GF_SECURITY_ADMIN_USER: "admin",
        GF_SECURITY_ADMIN_PASSWORD: "admin",
        GF_AUTH_ANONYMOUS_ENABLED: "true",
        GF_AUTH_ANONYMOUS_ORG_ROLE: "Admin",
        GF_LOG_LEVEL: "warn",
      }),
    },
  );
  await waitFor(
    "Grafana health",
    async () => {
      if (child.exitCode !== null) {
        throw new Error(`Grafana exited with code ${child.exitCode}`);
      }
      const response = await fetch(`${grafanaBaseUrl}/api/health`);
      if (!response.ok) throw new Error(`Grafana /api/health returned ${response.status}`);
    },
    120_000,
  );
  return child;
}

async function ingestTempoSpan(
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
            scope: { name: "codetracer-observability-m36-grafana-tempo" },
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
                  { key: "ct.mcr.wall_time_unix_ns", value: { stringValue: ready.wallTimeUnixNs } },
                  { key: "ct.mcr.monotonic_time_ns", value: { stringValue: ready.monotonicTimeNs } },
                  { key: "time_window_ns", value: { stringValue: ready.timeWindowNs } },
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
    throw new Error(`Tempo OTLP ingest failed: HTTP ${response.status} ${await response.text()}`);
  }
}

function grafanaExploreTraceUrl(grafanaBaseUrl: string, ready: GrafanaTraceReady): string {
  const wallTimeMs = Number(BigInt(ready.wallTimeUnixNs) / 1_000_000n);
  const panes = {
    m36: {
      datasource: "codetracer-tempo",
      queries: [
        {
          refId: "A",
          datasource: { type: "tempo", uid: "codetracer-tempo" },
          query: ready.traceId,
          queryType: "traceql",
          limit: 20,
          tableType: "traces",
        },
      ],
      range: {
        from: String(wallTimeMs - 60_000),
        to: String(wallTimeMs + 60_000),
      },
    },
  };
  const params = new URLSearchParams({
    orgId: "1",
    schemaVersion: "1",
    panes: JSON.stringify(panes),
  });
  return `${grafanaBaseUrl}/explore?${params.toString()}`;
}

async function ingestMaterializedTempoSpan(
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
            scope: { name: "codetracer-observability-m36-materialized-tempo" },
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
                  { key: "ct.mcr.wall_time_unix_ns", value: { stringValue: linkReady.wallTimeUnixNs } },
                  { key: "ct.mcr.monotonic_time_ns", value: { stringValue: linkReady.monotonicTimeNs } },
                  { key: "time_window_ns", value: { stringValue: linkReady.timeWindowNs } },
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
    throw new Error(`Tempo materialized OTLP ingest failed: HTTP ${response.status} ${await response.text()}`);
  }
}

function materializedDebugUrl(
  bridgeBaseUrl: string,
  ready: MaterializedPlatformLinkReady,
  linkReady: MaterializedPlatformLink,
): string {
  const debugParams = new URLSearchParams({
    tenant_id: ready.tenantId,
    "service.name": linkReady.serviceName,
    trace_id: linkReady.traceId,
    span_id: linkReady.spanId,
    "ct.mcr.wall_time_unix_ns": linkReady.wallTimeUnixNs,
    "ct.mcr.monotonic_time_ns": linkReady.monotonicTimeNs,
    time_window_ns: linkReady.timeWindowNs,
  });
  return `${bridgeBaseUrl}/observability/v0/debug-session?${debugParams.toString()}`;
}

function assertM36MaterializedDebugUrl(
  urlText: string,
  ready: MaterializedPlatformLinkReady,
  linkReady: MaterializedPlatformLink,
): void {
  const url = new URL(urlText);
  expect(url.pathname).toBe("/observability/v0/debug-session");
  expect(url.searchParams.get("tenant_id")).toBe(ready.tenantId);
  expect(url.searchParams.get("service.name")).toBe(linkReady.serviceName);
  expect(url.searchParams.get("trace_id")).toBe(linkReady.traceId);
  expect(url.searchParams.get("span_id")).toBe(linkReady.spanId);
  expect(url.searchParams.get("ct.mcr.wall_time_unix_ns")).toBe(
    linkReady.wallTimeUnixNs,
  );
  expect(url.searchParams.get("ct.mcr.monotonic_time_ns")).toBe(
    linkReady.monotonicTimeNs,
  );
  expect(url.searchParams.get("time_window_ns")).toBe(linkReady.timeWindowNs);
}

function assertM36DebugUrl(urlText: string, ready: PlatformLinkReady): void {
  const url = new URL(urlText);
  expect(url.pathname).toBe("/observability/v0/debug-session");
  expect(url.searchParams.get("tenant_id")).toBe(ready.tenantId);
  expect(url.searchParams.get("service.name")).toBe(ready.serviceName);
  expect(url.searchParams.get("trace_id")).toBe(ready.traceId);
  expect(url.searchParams.get("span_id")).toBe(ready.spanId);
  expect(url.searchParams.get("ct.mcr.wall_time_unix_ns")).toBe(
    ready.wallTimeUnixNs,
  );
  expect(url.searchParams.get("ct.mcr.monotonic_time_ns")).toBe(
    ready.monotonicTimeNs,
  );
  expect(url.searchParams.get("time_window_ns")).toBe(ready.timeWindowNs);
}

function debugSessionUrlMatchesMaterializedLink(
  urlText: string,
  ready: MaterializedPlatformLinkReady,
  linkReady: MaterializedPlatformLink,
): boolean {
  if (urlText.length === 0) return false;
  const url = new URL(urlText);
  return url.pathname === "/observability/v0/debug-session" &&
    url.searchParams.get("tenant_id") === ready.tenantId &&
    url.searchParams.get("service.name") === linkReady.serviceName &&
    url.searchParams.get("trace_id") === linkReady.traceId &&
    url.searchParams.get("span_id") === linkReady.spanId &&
    url.searchParams.get("ct.mcr.wall_time_unix_ns") === linkReady.wallTimeUnixNs &&
    url.searchParams.get("ct.mcr.monotonic_time_ns") === linkReady.monotonicTimeNs &&
    url.searchParams.get("time_window_ns") === linkReady.timeWindowNs;
}

async function runCtObserveAgainstTempo(
  rootDir: string,
  tempoBaseUrl: string,
  ready: PlatformLinkReady,
): Promise<any> {
  expectRequiredFile("ct-observe binary", ctObserveBin());
  const fromSec = String((BigInt(ready.wallTimeUnixNs) - 60_000_000_000n) / 1_000_000_000n);
  const toSec = String((BigInt(ready.wallTimeUnixNs) + 60_000_000_000n) / 1_000_000_000n);
  const liveTempoTrace = await fetchJsonFromUrl(
    `${tempoBaseUrl}/api/traces/${ready.traceId}`,
  );
  const liveTempoTracePath = path.join(rootDir, "ct-observe-live-tempo-trace.json");
  fs.writeFileSync(liveTempoTracePath, JSON.stringify(liveTempoTrace, null, 2));
  const output = childProcess.execFileSync(
    ctObserveBin(),
    [
      "extract",
      "--backend=tempo",
      `--input=${liveTempoTracePath}`,
      `--from=${fromSec}`,
      `--to=${toSec}`,
      `--traceql={ trace:id = "${ready.traceId}" }`,
      "--limit=10",
      "--page-duration-sec=120",
      "--request-key-attribute=request.id",
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
      candidate.request_key === "m25-real-mcr-request-001" &&
      debugSessionUrlMatchesReady(
        String(candidate.codetracer_debug_session_url ?? ""),
        ready,
      ),
  );
  if (!row) {
    throw new Error(`ct-observe did not return M36 Tempo row:\n${output}`);
  }
  return row;
}

async function runMaterializedCtObserveAgainstTempo(
  rootDir: string,
  tempoBaseUrl: string,
  ready: MaterializedPlatformLinkReady,
  linkReady: MaterializedPlatformLink,
): Promise<any> {
  expectRequiredFile("ct-observe binary", ctObserveBin());
  const fromSec = String((BigInt(linkReady.wallTimeUnixNs) - 60_000_000_000n) / 1_000_000_000n);
  const toSec = String((BigInt(linkReady.wallTimeUnixNs) + 60_000_000_000n) / 1_000_000_000n);
  const liveTempoTrace = await fetchJsonFromUrl(
    `${tempoBaseUrl}/api/traces/${linkReady.traceId}`,
  );
  const liveTempoTracePath = path.join(
    rootDir,
    `ct-observe-live-tempo-${linkReady.language}-trace.json`,
  );
  fs.writeFileSync(liveTempoTracePath, JSON.stringify(liveTempoTrace, null, 2));
  const output = childProcess.execFileSync(
    ctObserveBin(),
    [
      "extract",
      "--backend=tempo",
      `--input=${liveTempoTracePath}`,
      `--from=${fromSec}`,
      `--to=${toSec}`,
      `--traceql={ trace:id = "${linkReady.traceId}" }`,
      "--limit=10",
      "--page-duration-sec=120",
      "--request-key-attribute=request.id",
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
      candidate.request_key === linkReady.requestKey &&
      debugSessionUrlMatchesMaterializedLink(
        String(candidate.codetracer_debug_session_url ?? ""),
        ready,
        linkReady,
      ),
  );
  if (!row) {
    throw new Error(`ct-observe did not return M36 materialized Tempo row:\n${output}`);
  }
  return row;
}

async function runMaterializedCtObserveLaunchAgainstTempo(
  rootDir: string,
  tempoBaseUrl: string,
  linkReady: MaterializedPlatformLink,
): Promise<any> {
  expectRequiredFile("ct-observe binary", ctObserveBin());
  const liveTempoTrace = await fetchJsonFromUrl(
    `${tempoBaseUrl}/api/traces/${linkReady.traceId}`,
  );
  const liveTempoTracePath = path.join(
    rootDir,
    `ct-observe-launch-live-tempo-${linkReady.language}-trace.json`,
  );
  fs.writeFileSync(liveTempoTracePath, JSON.stringify(liveTempoTrace, null, 2));
  const artifactDir = m36ArtifactDir();
  if (artifactDir) {
    fs.mkdirSync(artifactDir, { recursive: true });
    fs.copyFileSync(
      liveTempoTracePath,
      path.join(artifactDir, `ct-observe-launch-live-tempo-${linkReady.language}-trace.json`),
    );
  }
  const traceOutput = childProcess.execFileSync(
    ctObserveBin(),
    [
      "trace",
      "--backend=tempo",
      `--input=${liveTempoTracePath}`,
      `--trace-id=${linkReady.traceId}`,
      "--format=jsonl",
    ],
    {
      encoding: "utf-8",
      stdio: ["ignore", "pipe", "pipe"],
      windowsHide: true,
    },
  );
  if (artifactDir) {
    fs.writeFileSync(
      path.join(artifactDir, `ct-observe-launch-live-tempo-${linkReady.language}-trace-rows.jsonl`),
      traceOutput,
    );
  }
  const output = await new Promise<string>((resolve, reject) => {
    childProcess.execFile(
      ctObserveBin(),
      [
        "launch",
        "--backend=tempo",
        `--input=${liveTempoTracePath}`,
        `--trace-id=${linkReady.traceId}`,
        `--request-key=${linkReady.requestKey}`,
        `--span-id=${linkReady.spanId}`,
        "--launch-timeout-ms=300000",
      ],
      {
        encoding: "utf-8",
        windowsHide: true,
      },
      (error, stdout, stderr) => {
        if (error) {
          reject(new Error(`${error.message}\n${stderr}\ntrace rows:\n${traceOutput}`));
        } else {
          resolve(stdout);
        }
      },
    );
  });
  const launch = JSON.parse(output);
  expect(launch.http_status).toBe(302);
  expect(launch.selected_row?.platform).toBe("tempo");
  expect(launch.selected_row?.trace_id).toBe(linkReady.traceId);
  expect(launch.selected_row?.span_id).toBe(linkReady.spanId);
  expect(launch.selected_row?.request_key).toBe(linkReady.requestKey);
  return launch;
}

function debugSessionUrlMatchesReady(urlText: string, ready: PlatformLinkReady): boolean {
  if (urlText.length === 0) return false;
  const url = new URL(urlText);
  return url.pathname === "/observability/v0/debug-session" &&
    url.searchParams.get("tenant_id") === ready.tenantId &&
    url.searchParams.get("service.name") === ready.serviceName &&
    url.searchParams.get("trace_id") === ready.traceId &&
    url.searchParams.get("span_id") === ready.spanId &&
    url.searchParams.get("ct.mcr.wall_time_unix_ns") === ready.wallTimeUnixNs &&
    url.searchParams.get("ct.mcr.monotonic_time_ns") === ready.monotonicTimeNs &&
    url.searchParams.get("time_window_ns") === ready.timeWindowNs;
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

async function runCtObserveLaunchAgainstJaeger(
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
  const output = await new Promise<string>((resolve, reject) => {
    childProcess.execFile(
      ctObserveBin(),
      [
        "launch",
        "--backend=jaeger",
        `--url=${jaegerBaseUrl}`,
        `--from=${fromIso}`,
        `--to=${toIso}`,
        `--service=${ready.serviceName}`,
        "--request-key=m25-real-mcr-request-001",
        `--span-id=${ready.spanId}`,
        "--launch-timeout-ms=300000",
      ],
      {
        encoding: "utf-8",
        windowsHide: true,
      },
      (error, stdout, stderr) => {
        if (error) {
          reject(new Error(`${error.message}\n${stderr}`));
        } else {
          resolve(stdout);
        }
      },
    );
  });
  const launch = JSON.parse(output);
  expect(launch.http_status).toBe(302);
  expect(launch.selected_row?.trace_id).toBe(ready.traceId);
  expect(launch.selected_row?.span_id).toBe(ready.spanId);
  expect(launch.selected_row?.request_key).toBe("m25-real-mcr-request-001");
  return launch;
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

async function runMixedRequestCtObserveAgainstJaeger(
  jaegerBaseUrl: string,
  ready: PlatformLinkReady,
  requestKey: string,
): Promise<any[]> {
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
      `--tag=request.id=${requestKey}`,
      "--limit=1",
      "--page-duration-us=120000000",
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
  const requestRows = rows.filter((candidate) =>
    candidate.trace_id === ready.traceId &&
    candidate.request_key === requestKey &&
    candidate.recording_available === true &&
    String(candidate.codetracer_debug_session_url ?? "").length > 0
  );
  if (requestRows.length < 4) {
    throw new Error(
      `ct-observe did not return all M36 mixed Jaeger rows for ${requestKey}:\n${output}`,
    );
  }
  return requestRows;
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
      const hostUrl = `http://127.0.0.1:${httpPort}`;
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
      const importOutput = await waitForOutput(
        hostOutput,
        /imported manifest trace as trace id\s+\d+/,
      );
      expect(importOutput).toContain("Starting host from generated replay manifest");
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
  bridgeErrors: string[];
  bridgeEvents: string[];
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
      options.bridgeEvents.push(`request ${request.method ?? "GET"} ${requestUrl.pathname}${requestUrl.search}`);
      if (requestUrl.pathname !== "/observability/v0/debug-session") {
        options.bridgeEvents.push(`not-found ${requestUrl.pathname}`);
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
      options.bridgeEvents.push(`upstream ${upstreamUrl}`);
      const upstreamResponse = await fetch(upstreamUrl, {
        headers: { authorization: `Bearer ${options.ready.callerToken}` },
        redirect: "manual",
      });
      options.bridgeEvents.push(`upstream-status ${upstreamResponse.status}`);
      if (upstreamResponse.status !== 302) {
        throw new Error(
          `codetracer-ci materialized debug-session returned HTTP ${upstreamResponse.status}: ${await upstreamResponse.text()}`,
        );
      }

      const replayPayload = await fetchJsonFromUrl(
        `${options.ready.baseUrl}/__tests/replay-provisioning/latest`,
      );
      options.bridgeEvents.push(`replay-payload ${replayPayload.traceSource?.kind ?? "missing-kind"}`);
      expect(replayPayload.traceSource.kind).toBe("materialized_trace");
      expect(replayPayload.traceSource.artifacts[0].artifactKey).toBe(
        linkReady.materializedArtifactKey,
      );
      const materializedSupportFiles =
        replayPayload.traceSource.artifacts[0].supportFiles ?? [];
      expect(materializedSupportFiles.map((file: any) => file.relativePath)).toContain(
        "trace_metadata.json",
      );
      expect(materializedSupportFiles.map((file: any) => file.relativePath)).toContain(
        "trace_paths.json",
      );
      expect(replayPayload.initialPosition.materializedMomentId).toBe(
        linkReady.momentId,
      );
      expect(replayPayload.initialPosition.materializedArtifactKey).toBe(
        linkReady.materializedArtifactKey,
      );
      options.bridgeEvents.push("generating-runner-command");
      const replayAgentCommandLine = generateReplayAgentCommand(
        replayPayload,
        options.runnerRoot,
      );
      options.bridgeEvents.push("generated-runner-command");
      expect(replayAgentCommandLine).toContain("docker run ");
      expect(replayAgentCommandLine).toContain(
        "CODETRACER_TRACE_MATERIALIZED_ARTIFACTS=",
      );
      expect(replayAgentCommandLine).toContain("trace_metadata.json");
      expect(replayAgentCommandLine).toContain("trace_paths.json");
      const replayEnv = parseReplayAgentEnv(replayAgentCommandLine);
      expect(replayEnv.CODETRACER_TRACE_MANIFEST_KEY).toBeTruthy();
      expect(replayEnv.CODETRACER_STORAGE_BASE_URL).toBe(options.ready.baseUrl);
      expect(replayEnv.CODETRACER_STORAGE_REPLAY_TOKEN).toBe(
        replayPayload.traceSource.storageReplayToken,
      );
      expect(replayEnv.CODETRACER_STORAGE_REPLAY_TOKEN).toMatch(
        /^ct_replay_storage_/,
      );

      const httpPort = await getFreeTcpPort();
      const backendPort = await getFreeTcpPort();
      const hostUrl = `http://127.0.0.1:${httpPort}`;
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
              XDG_CONFIG_HOME: path.join(
                options.runnerRoot,
                `xdg-config-${linkReady.language}`,
              ),
            }),
            ...replayEnv,
            CODETRACER_LOCAL_STORAGE_ROOT: "",
            CODETRACER_LOCAL_MANIFEST_PATH: "",
            CODETRACER_WORK_DIR: path.join(
              options.runnerRoot,
              `work-${linkReady.language}`,
            ),
            PATH: `${shimDir}${path.delimiter}${process.env.PATH ?? ""}`,
          },
          stdio: ["ignore", "pipe", "pipe"],
          windowsHide: true,
        },
      );
      options.bridgeEvents.push(`spawned ${linkReady.language} ${hostUrl}`);
      ctProcess.stdout?.on("data", (chunk: Buffer) => {
        hostOutput.push(chunk.toString());
      });
      ctProcess.stderr?.on("data", (chunk: Buffer) => {
        hostOutput.push(chunk.toString());
      });
      options.launches.push({ ctProcess, hostOutput, hostUrl, linkReady, replayPayload });
      const importOutput = await waitForOutput(
        hostOutput,
        /imported manifest trace as trace id\s+\d+/,
      );
      options.bridgeEvents.push(`imported ${linkReady.language}`);
      expect(importOutput).toContain("Starting host from generated replay manifest");
      response.writeHead(302, { location: hostUrl });
      response.end();
    } catch (error) {
      options.bridgeErrors.push(error instanceof Error ? error.stack ?? error.message : String(error));
      response.writeHead(500, { "content-type": "text/plain; charset=utf-8" });
      response.end(error instanceof Error ? error.stack : String(error));
    }
  });
  server.listen(options.port, "127.0.0.1");
  return server;
}

function startMixedPlatformLaunchBridge(options: {
  mcrReady: PlatformLinkReady;
  materializedReady: MaterializedPlatformLinkReady;
  runnerRoot: string;
  port: number;
  bridgeErrors: string[];
  bridgeEvents: string[];
  mcrLaunches: Array<{ ctProcess: childProcess.ChildProcess; hostOutput: string[]; hostUrl: string }>;
  materializedLaunches: Array<{
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
      options.bridgeEvents.push(`request ${request.method ?? "GET"} ${requestUrl.pathname}${requestUrl.search}`);
      if (requestUrl.pathname !== "/observability/v0/debug-session") {
        response.writeHead(404);
        response.end("not found");
        return;
      }

      const traceId = requestUrl.searchParams.get("trace_id") ?? "";
      const spanId = requestUrl.searchParams.get("span_id") ?? "";
      const materializedLink = options.materializedReady.links.find(
        (candidate) => candidate.traceId === traceId && candidate.spanId === spanId,
      );
      const isMcrLink = traceId === options.mcrReady.traceId && spanId === options.mcrReady.spanId;
      if (!isMcrLink && !materializedLink) {
        throw new Error(`unexpected mixed debug-session link ${requestUrl.toString()}`);
      }

      const readyBase = materializedLink ? options.materializedReady : options.mcrReady;
      const upstreamUrl = `${readyBase.baseUrl}${requestUrl.pathname}${requestUrl.search}`;
      const upstreamResponse = await fetch(upstreamUrl, {
        headers: { authorization: `Bearer ${readyBase.callerToken}` },
        redirect: "manual",
      });
      if (upstreamResponse.status !== 302) {
        throw new Error(
          `codetracer-ci mixed debug-session returned HTTP ${upstreamResponse.status}: ${await upstreamResponse.text()}`,
        );
      }

      const replayPayload = await fetchJsonFromUrl(
        `${readyBase.baseUrl}/__tests/replay-provisioning/latest`,
      );
      if (materializedLink) {
        expect(replayPayload.traceSource.kind).toBe("materialized_trace");
        expect(replayPayload.traceSource.artifacts[0].artifactKey).toBe(
          materializedLink.materializedArtifactKey,
        );
        expect(replayPayload.initialPosition.materializedMomentId).toBe(
          materializedLink.momentId,
        );
      }

      const replayAgentCommandLine = generateReplayAgentCommand(
        replayPayload,
        options.runnerRoot,
      );
      if (materializedLink) {
        expect(replayAgentCommandLine).toContain("CODETRACER_TRACE_MATERIALIZED_ARTIFACTS=");
      } else {
        expect(replayAgentCommandLine).toContain("CODETRACER_TRACE_MANIFEST_KEY=");
      }
      const replayEnv = parseReplayAgentEnv(replayAgentCommandLine);
      const httpPort = await getFreeTcpPort();
      const backendPort = await getFreeTcpPort();
      const hostUrl = `http://127.0.0.1:${httpPort}`;
      const hostOutput: string[] = [];
      const shimDir = createCtPathShim(options.runnerRoot);
      const entrypointPath = path.join(
        codetracerCiDir,
        "resources",
        "docker",
        "codetracer-runner",
        "replay-entrypoint.sh",
      );
      const languageSuffix = materializedLink ? `-${materializedLink.language}` : "-mcr";
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
              XDG_CONFIG_HOME: path.join(options.runnerRoot, `xdg-config${languageSuffix}`),
            }),
            ...replayEnv,
            CODETRACER_LOCAL_STORAGE_ROOT: "",
            CODETRACER_LOCAL_MANIFEST_PATH: "",
            CODETRACER_WORK_DIR: path.join(options.runnerRoot, `work${languageSuffix}`),
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
      const importOutput = await waitForOutput(
        hostOutput,
        /imported manifest trace as trace id\s+\d+/,
      );
      expect(importOutput).toContain("Starting host from generated replay manifest");
      if (materializedLink) {
        options.materializedLaunches.push({
          ctProcess,
          hostOutput,
          hostUrl,
          linkReady: materializedLink,
          replayPayload,
        });
        options.bridgeEvents.push(`launched ${materializedLink.language}`);
      } else {
        options.mcrLaunches.push({ ctProcess, hostOutput, hostUrl });
        options.bridgeEvents.push("launched mcr");
      }
      response.writeHead(302, { location: hostUrl });
      response.end();
    } catch (error) {
      options.bridgeErrors.push(error instanceof Error ? error.stack ?? error.message : String(error));
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
      if (!replayPage.url().startsWith(launch.hostUrl)) {
        await replayPage.goto(launch.hostUrl, { timeout: 120_000 });
      }
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

  base("M36 ct-observe launch reaches real Jaeger routed-storage CodeTracer replay", async ({ page }) => {
    expectRequiredFile("CodeTracer test binary", codetracerPath);
    expectRequiredFile("ct-observe binary", ctObserveBin());
    expectRequiredFile("codetracer-ci storage harness project", storageHarnessProject);
    expectRequiredFile(
      "ReplayAgent runner entrypoint",
      path.join(codetracerCiDir, "resources", "docker", "codetracer-runner", "replay-entrypoint.sh"),
    );
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
      path.join(os.tmpdir(), "ct-m36-ct-observe-launch-jaeger-"),
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
        async () => fetchJsonFromUrl(`${jaegerBaseUrl}/api/traces/${platformHarness!.ready.traceId}`),
        60_000,
      );

      const launchJson = await runCtObserveLaunchAgainstJaeger(
        jaegerBaseUrl,
        platformHarness.ready,
      );
      expect(launchJson.debug_session_url).toBe(debugUrl);

      await waitFor(
        "ct-observe launch bridge started CodeTracer",
        async () => {
          if (launches.length !== 1) {
            throw new Error(`expected one CodeTracer launch, got ${launches.length}`);
          }
        },
        120_000,
      );
      const launch = launches[0];
      expect(launchJson.redirect_url).toBe(launch.hostUrl);
      await page.goto(launchJson.redirect_url, { timeout: 120_000 });
      await waitForRealReplayDetails(page, launch.hostOutput);

      const artifactDir = m36ArtifactDir();
      if (artifactDir) {
        fs.mkdirSync(artifactDir, { recursive: true });
        fs.writeFileSync(
          path.join(artifactDir, "ct-observe-launch-jaeger.json"),
          JSON.stringify(launchJson, null, 2),
        );
        fs.writeFileSync(
          path.join(artifactDir, "ct-observe-launch-ct-host-output.log"),
          launch.hostOutput.join(""),
        );
      }
      await page.screenshot({
        path: path.join(
          m36ArtifactDir() ?? runnerRoot,
          "m36-ct-observe-launch-jaeger-real-codetracer-replay.png",
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

  base("M36 real Jaeger mixed request constellation launches MCR Python Ruby and JavaScript CodeTracer replays", async ({ page }) => {
    expectRequiredFile("CodeTracer test binary", codetracerPath);
    expectRequiredFile("codetracer-ci storage harness project", storageHarnessProject);
    expectRequiredFile(
      "ReplayAgent runner entrypoint",
      path.join(codetracerCiDir, "resources", "docker", "codetracer-runner", "replay-entrypoint.sh"),
    );
    expectRequiredFile("Jaeger plugin UI config renderer", jaegerUiConfigRendererPath());
    expectRequiredFile("real MCR request trace fixture", portableTracePath);
    expectRequiredFile("MCR request source file", fixtureSourcePath);
    expectRequiredFile("MCR request binary fixture", fixtureBinaryPath);
    expectRequiredFile("MCR request details fixture", fixtureRequestDetailsPath);
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

    const preparedMcr = prepareStorageHarnessInput();
    const runnerRoot = fs.mkdtempSync(
      path.join(os.tmpdir(), "ct-m36-jaeger-mixed-constellation-"),
    );
    let mcrHarness: Awaited<ReturnType<typeof startPlatformLinkHarness>> | null = null;
    let materializedHarness: Awaited<ReturnType<typeof startMaterializedPlatformLinkHarness>> | null = null;
    let jaegerProcess: childProcess.ChildProcess | null = null;
    let bridge: http.Server | null = null;
    let preparedMaterialized: { rootDir: string; inputPath: string } | null = null;
    const mcrLaunches: Array<{ ctProcess: childProcess.ChildProcess; hostOutput: string[]; hostUrl: string }> = [];
    const materializedLaunches: Array<{
      ctProcess: childProcess.ChildProcess;
      hostOutput: string[];
      hostUrl: string;
      linkReady: MaterializedPlatformLink;
      replayPayload: any;
    }> = [];
    const bridgeErrors: string[] = [];
    const bridgeEvents: string[] = [];

    try {
      mcrHarness = await startPlatformLinkHarness(preparedMcr.inputPath);
      expect(mcrHarness.ready.selectedSegmentIndex).toBe(
        preparedMcr.selectedSegmentIndex,
      );
      fs.rmSync(preparedMcr.rootDir, { recursive: true, force: true });

      preparedMaterialized = prepareMaterializedPlatformHarnessInput({
        traceId: mcrHarness.ready.traceId,
        requestKey: m36MixedRequestKey,
      });
      materializedHarness = await startMaterializedPlatformLinkHarness(
        preparedMaterialized.inputPath,
      );
      expect(materializedHarness.ready.links.map((link) => link.language).sort())
        .toEqual(materializedFixtures.map((fixture) => fixture.language).sort());
      fs.rmSync(preparedMaterialized.rootDir, { recursive: true, force: true });

      const jaegerUiPort = await getFreeTcpPort();
      const jaegerOtlpPort = await getFreeTcpPort();
      const bridgePort = await getFreeTcpPort();
      const bridgeBaseUrl = `http://127.0.0.1:${bridgePort}`;
      const jaegerBaseUrl = `http://127.0.0.1:${jaegerUiPort}`;
      const renderedJaegerUiConfigPath = renderJaegerUiConfigForDebugBase(
        runnerRoot,
        bridgeBaseUrl,
      );
      const mcrDebugUrl = new URL(`${bridgeBaseUrl}/observability/v0/debug-session`);
      mcrDebugUrl.search = new URLSearchParams({
        tenant_id: mcrHarness.ready.tenantId,
        "service.name": mcrHarness.ready.serviceName,
        trace_id: mcrHarness.ready.traceId,
        span_id: mcrHarness.ready.spanId,
        "ct.mcr.wall_time_unix_ns": mcrHarness.ready.wallTimeUnixNs,
        "ct.mcr.monotonic_time_ns": mcrHarness.ready.monotonicTimeNs,
        time_window_ns: mcrHarness.ready.timeWindowNs,
      }).toString();

      bridge = startMixedPlatformLaunchBridge({
        mcrReady: mcrHarness.ready,
        materializedReady: materializedHarness.ready,
        runnerRoot,
        port: bridgePort,
        bridgeErrors,
        bridgeEvents,
        mcrLaunches,
        materializedLaunches,
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

      await ingestJaegerSpan(
        jaegerOtlpPort,
        mcrHarness.ready,
        mcrDebugUrl.toString(),
        m36MixedRequestKey,
      );
      for (const linkReady of materializedHarness.ready.links) {
        await ingestMaterializedJaegerSpan(
          jaegerOtlpPort,
          materializedHarness.ready,
          linkReady,
          materializedDebugUrl(bridgeBaseUrl, materializedHarness.ready, linkReady),
        );
      }
      await waitFor(
        "Jaeger mixed trace ingestion",
        async () => {
          const trace = await fetchJsonFromUrl(`${jaegerBaseUrl}/api/traces/${mcrHarness!.ready.traceId}`);
          const spans = trace.data?.[0]?.spans ?? [];
          const services = new Set(
            spans.map((span: any) => span.processID)
              .map((processId: string) => trace.data[0].processes[processId]?.serviceName)
              .filter(Boolean),
          );
          if (spans.length < 4) {
            throw new Error(`expected four mixed spans, got ${spans.length}`);
          }
          for (const serviceName of [
            mcrHarness!.ready.serviceName,
            ...materializedHarness!.ready.links.map((link) => link.serviceName),
          ]) {
            if (!services.has(serviceName)) {
              throw new Error(`mixed Jaeger trace missing service ${serviceName}`);
            }
          }
        },
        60_000,
      );

      const cliRows = await runMixedRequestCtObserveAgainstJaeger(
        jaegerBaseUrl,
        mcrHarness.ready,
        m36MixedRequestKey,
      );
      const rowsBySpan = new Map(cliRows.map((row) => [row.span_id, row]));
      expect(rowsBySpan.get(mcrHarness.ready.spanId)?.codetracer_debug_session_url)
        .toBe(mcrDebugUrl.toString());
      for (const linkReady of materializedHarness.ready.links) {
        expect(rowsBySpan.get(linkReady.spanId)?.codetracer_debug_session_url)
          .toBe(materializedDebugUrl(bridgeBaseUrl, materializedHarness.ready, linkReady));
      }

      const clickJaegerDebugLink = async (
        label: string,
        serviceName: string,
        operationName: string,
        debugUrl: string,
      ): Promise<Page> => {
        await page.goto(`${jaegerBaseUrl}/trace/${mcrHarness!.ready.traceId}`, {
          waitUntil: "domcontentloaded",
          timeout: 60_000,
        });
        await page.getByText(operationName).first().waitFor({ timeout: 60_000 });
        await page
          .getByRole("switch", {
            name: new RegExp(`${escapeRegExp(serviceName)}.*${escapeRegExp(operationName)}`),
          })
          .click();
        await page.getByRole("switch", { name: /Tags/ }).click();
        const link = page.locator("a").filter({ hasText: debugUrl }).first();
        await expect(link, `${label} Jaeger CodeTracer action`).toBeVisible({
          timeout: 60_000,
        });
        expect(await link.getAttribute("href")).toBe(debugUrl);
        const popupPromise = page.context().waitForEvent("page", { timeout: 5_000 }).catch(() => null);
        await link.click();
        const replayPage = (await popupPromise) ?? page;
        await replayPage.waitForURL(/http:\/\/127\.0\.0\.1:\d+\//, {
          timeout: 120_000,
        });
        return replayPage;
      };

      const mcrReplayPage = await clickJaegerDebugLink(
        "MCR inventory",
        mcrHarness.ready.serviceName,
        "GET /reserve",
        mcrDebugUrl.toString(),
      );
      await waitFor(
        "mixed MCR launch bridge started CodeTracer",
        async () => {
          if (bridgeErrors.length > 0) throw new Error(bridgeErrors.join("\n\n"));
          if (mcrLaunches.length !== 1) {
            throw new Error(`expected one MCR launch, got ${mcrLaunches.length}`);
          }
        },
        120_000,
      );
      await waitForRealReplayDetails(mcrReplayPage, mcrLaunches[0].hostOutput);

      for (const fixture of materializedFixtures) {
        const linkReady = materializedHarness.ready.links.find(
          (candidate) => candidate.language === fixture.language,
        );
        expect(linkReady, `${fixture.label} mixed platform link`).toBeTruthy();
        const previousLaunches = materializedLaunches.length;
        const replayPage = await clickJaegerDebugLink(
          fixture.label,
          linkReady!.serviceName,
          linkReady!.operationName,
          materializedDebugUrl(bridgeBaseUrl, materializedHarness.ready, linkReady!),
        );
        await waitFor(
          `${fixture.label} mixed launch bridge started CodeTracer`,
          async () => {
            if (bridgeErrors.length > 0) throw new Error(bridgeErrors.join("\n\n"));
            if (materializedLaunches.length !== previousLaunches + 1) {
              throw new Error(
                `expected ${previousLaunches + 1} materialized launches, got ${materializedLaunches.length}\n` +
                  `Bridge events:\n${bridgeEvents.join("\n")}`,
              );
            }
          },
          120_000,
        );
        const launch = materializedLaunches[materializedLaunches.length - 1];
        await waitForMaterializedReplayDetails(
          replayPage,
          fixture,
          launch.hostOutput,
        );
      }

      const artifactDir = m36ArtifactDir();
      if (artifactDir) {
        fs.mkdirSync(artifactDir, { recursive: true });
        fs.writeFileSync(
          path.join(artifactDir, "ct-observe-jaeger-mixed-request-rows.json"),
          JSON.stringify(cliRows, null, 2),
        );
        fs.writeFileSync(
          path.join(artifactDir, "mixed-bridge-events.log"),
          bridgeEvents.join("\n"),
        );
      }
    } finally {
      for (const launch of [...mcrLaunches, ...materializedLaunches]) {
        if (launch.ctProcess.pid) {
          killProcessTree(launch.ctProcess.pid);
        }
      }
      if (bridge) {
        await new Promise<void>((resolve) => bridge?.close(() => resolve()));
      }
      await stopJaegerAllInOne(runnerRoot, jaegerProcess);
      if (mcrHarness?.process.pid) {
        killProcessTree(mcrHarness.process.pid);
      }
      if (materializedHarness?.process.pid) {
        killProcessTree(materializedHarness.process.pid);
      }
      fs.rmSync(preparedMcr.rootDir, { recursive: true, force: true });
      if (preparedMaterialized) {
        fs.rmSync(preparedMaterialized.rootDir, { recursive: true, force: true });
      }
      fs.rmSync(runnerRoot, { recursive: true, force: true });
      await sleep(500);
    }
  });

  base("M36 real Grafana Tempo UI correlation launches routed-storage CodeTracer replay", async ({ page, context }) => {
    expectRequiredFile("CodeTracer test binary", codetracerPath);
    expectRequiredFile("codetracer-ci storage harness project", storageHarnessProject);
    expectRequiredFile(
      "ReplayAgent runner entrypoint",
      path.join(codetracerCiDir, "resources", "docker", "codetracer-runner", "replay-entrypoint.sh"),
    );
    expectRequiredFile("Grafana Tempo provisioning output", grafanaPluginOutPath());
    expectRequiredFile("real MCR request trace fixture", portableTracePath);
    expectRequiredFile("MCR request source file", fixtureSourcePath);
    expectRequiredFile("MCR request binary fixture", fixtureBinaryPath);
    expectRequiredFile("MCR request details fixture", fixtureRequestDetailsPath);

    const prepared = prepareStorageHarnessInput();
    const runnerRoot = fs.mkdtempSync(
      path.join(os.tmpdir(), "ct-m36-grafana-tempo-platform-link-"),
    );
    let platformHarness: Awaited<ReturnType<typeof startPlatformLinkHarness>> | null = null;
    let tempoProcess: childProcess.ChildProcess | null = null;
    let grafanaProcess: childProcess.ChildProcess | null = null;
    let bridge: http.Server | null = null;
    const launches: Array<{ ctProcess: childProcess.ChildProcess; hostOutput: string[]; hostUrl: string }> = [];

    try {
      platformHarness = await startPlatformLinkHarness(prepared.inputPath);
      expect(platformHarness.ready.selectedSegmentIndex).toBe(
        prepared.selectedSegmentIndex,
      );
      fs.rmSync(prepared.rootDir, { recursive: true, force: true });

      const tempoHttpPort = await freeTcpPort();
      const tempoGrpcPort = await freeTcpPort();
      const tempoOtlpPort = await freeTcpPort();
      const grafanaPort = await freeTcpPort();
      const bridgePort = await freeTcpPort();
      const bridgeBaseUrl = `http://127.0.0.1:${bridgePort}`;
      const tempoBaseUrl = `http://127.0.0.1:${tempoHttpPort}`;
      const grafanaBaseUrl = `http://127.0.0.1:${grafanaPort}`;
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

      bridge = startPlatformLaunchBridge({
        rootDir: runnerRoot,
        ready: platformHarness.ready,
        runnerRoot,
        port: bridgePort,
        launches,
      });
      tempoProcess = await startTempoServer(
        runnerRoot,
        tempoHttpPort,
        tempoGrpcPort,
        tempoOtlpPort,
        tempoBaseUrl,
      );
      await ingestTempoSpan(tempoOtlpPort, platformHarness.ready, debugUrl);
      await waitFor(
        "Tempo trace ingestion",
        async () => fetchJsonFromUrl(`${tempoBaseUrl}/api/traces/${platformHarness!.ready.traceId}`),
        60_000,
      );

      const renderedGrafanaDir = renderGrafanaProvisioningForM36(
        runnerRoot,
        bridgeBaseUrl,
        tempoBaseUrl,
      );
      grafanaProcess = await startGrafanaServer(
        runnerRoot,
        grafanaPort,
        renderedGrafanaDir,
        grafanaBaseUrl,
      );
      const correlations = await fetchJsonFromUrl(
        `${grafanaBaseUrl}/api/datasources/correlations?sourceUID=codetracer-tempo`,
      );
      expect(correlations.totalCount).toBe(1);
      expect(correlations.correlations[0].label).toBe("Debug in CodeTracer");

      const cliRow = await runCtObserveAgainstTempo(
        runnerRoot,
        tempoBaseUrl,
        platformHarness.ready,
      );
      expect(cliRow.codetracer_debug_session_url).toBe(debugUrl);
      expect(cliRow.recording_available).toBe(true);
      expect(cliRow.request_key).toBe("m25-real-mcr-request-001");

      await page.goto(grafanaExploreTraceUrl(grafanaBaseUrl, platformHarness.ready), {
        waitUntil: "domcontentloaded",
        timeout: 60_000,
      });
      await page.getByText(platformHarness.ready.traceId).first().waitFor({
        timeout: 60_000,
      });
      if (!(await page.getByText("GET /reserve").first().isVisible())) {
        await page.getByText(platformHarness.ready.traceId).first().click();
      }
      await page.getByText("GET /reserve").first().waitFor({ timeout: 60_000 });
      const inventoryRow = page.getByRole("switch", {
        name: /inventory GET \/reserve/,
      });
      await inventoryRow.hover();
      await inventoryRow.click();
      await page.getByText("GET /reserve").first().click();

      const link = page
        .locator(`div[data-item-key*="${platformHarness.ready.spanId}"] a[href]`)
        .first();
      await expect(link).toBeVisible({ timeout: 60_000 });
      const grafanaLinkUrl = await link.getAttribute("href");
      assertM36DebugUrl(grafanaLinkUrl ?? "", platformHarness.ready);

      const popupPromise = context.waitForEvent("page", { timeout: 5_000 }).catch(() => null);
      await link.click();
      const replayPage = (await popupPromise) ?? page;
      await replayPage.waitForURL(/http:\/\/127\.0\.0\.1:\d+\//, {
        timeout: 120_000,
      });
      await waitFor(
        "Grafana platform launch bridge started CodeTracer",
        async () => {
          if (launches.length !== 1) {
            throw new Error(`expected one CodeTracer launch, got ${launches.length}`);
          }
        },
        120_000,
      );
      const launch = launches[0];
      if (!replayPage.url().startsWith(launch.hostUrl)) {
        await replayPage.goto(launch.hostUrl, { timeout: 120_000 });
      }
      await waitForRealReplayDetails(replayPage, launch.hostOutput);

      const artifactDir = m36ArtifactDir();
      if (artifactDir) {
        fs.mkdirSync(artifactDir, { recursive: true });
        fs.writeFileSync(path.join(artifactDir, "grafana-tempo-debug-url.txt"), debugUrl);
        fs.writeFileSync(
          path.join(artifactDir, "ct-observe-grafana-tempo-row.json"),
          JSON.stringify(cliRow, null, 2),
        );
        fs.writeFileSync(
          path.join(artifactDir, "grafana-tempo-ct-host-output.log"),
          launch.hostOutput.join(""),
        );
        for (const logFileName of ["grafana.log", "tempo.log"]) {
          const logPath = path.join(runnerRoot, logFileName);
          if (fs.existsSync(logPath)) {
            fs.copyFileSync(logPath, path.join(artifactDir, logFileName));
          }
        }
      }
      await replayPage.screenshot({
        path: path.join(
          m36ArtifactDir() ?? runnerRoot,
          "m36-grafana-tempo-real-codetracer-replay.png",
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
      await stopChild(grafanaProcess);
      await stopChild(tempoProcess);
      if (platformHarness?.process.pid) {
        killProcessTree(platformHarness.process.pid);
      }
      fs.rmSync(prepared.rootDir, { recursive: true, force: true });
      fs.rmSync(runnerRoot, { recursive: true, force: true });
      await sleep(500);
    }
  });

  base("M36 real Grafana Tempo UI correlations launch materialized Python Ruby and JavaScript CodeTracer replays", async ({ page, context }) => {
    expectRequiredFile("CodeTracer test binary", codetracerPath);
    expectRequiredFile("codetracer-ci storage harness project", storageHarnessProject);
    expectRequiredFile(
      "ReplayAgent runner entrypoint",
      path.join(codetracerCiDir, "resources", "docker", "codetracer-runner", "replay-entrypoint.sh"),
    );
    expectRequiredFile("Grafana Tempo provisioning output", grafanaPluginOutPath());
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

    const prepared = prepareMaterializedPlatformHarnessInput();
    const runnerRoot = fs.mkdtempSync(
      path.join(os.tmpdir(), "ct-m36-grafana-tempo-materialized-platform-link-"),
    );
    let platformHarness: Awaited<ReturnType<typeof startMaterializedPlatformLinkHarness>> | null = null;
    let tempoProcess: childProcess.ChildProcess | null = null;
    let grafanaProcess: childProcess.ChildProcess | null = null;
    let bridge: http.Server | null = null;
    const launches: Array<{
      ctProcess: childProcess.ChildProcess;
      hostOutput: string[];
      hostUrl: string;
      linkReady: MaterializedPlatformLink;
      replayPayload: any;
    }> = [];
    const bridgeErrors: string[] = [];
    const bridgeEvents: string[] = [];
    const cliRows: Record<string, any> = {};

    try {
      platformHarness = await startMaterializedPlatformLinkHarness(prepared.inputPath);
      expect(platformHarness.ready.links.map((link) => link.language).sort())
        .toEqual(materializedFixtures.map((fixture) => fixture.language).sort());
      fs.rmSync(prepared.rootDir, { recursive: true, force: true });

      const tempoHttpPort = await freeTcpPort();
      const tempoGrpcPort = await freeTcpPort();
      const tempoOtlpPort = await freeTcpPort();
      const grafanaPort = await freeTcpPort();
      const bridgePort = await freeTcpPort();
      const bridgeBaseUrl = `http://127.0.0.1:${bridgePort}`;
      const tempoBaseUrl = `http://127.0.0.1:${tempoHttpPort}`;
      const grafanaBaseUrl = `http://127.0.0.1:${grafanaPort}`;

      bridge = startMaterializedPlatformLaunchBridge({
        ready: platformHarness.ready,
        runnerRoot,
        port: bridgePort,
        bridgeErrors,
        bridgeEvents,
        launches,
      });
      tempoProcess = await startTempoServer(
        runnerRoot,
        tempoHttpPort,
        tempoGrpcPort,
        tempoOtlpPort,
        tempoBaseUrl,
      );

      for (const linkReady of platformHarness.ready.links) {
        const debugUrl = materializedDebugUrl(
          bridgeBaseUrl,
          platformHarness.ready,
          linkReady,
        );
        await ingestMaterializedTempoSpan(
          tempoOtlpPort,
          platformHarness.ready,
          linkReady,
          debugUrl,
        );
        await waitFor(
          `${linkReady.label} Tempo trace ingestion`,
          async () => fetchJsonFromUrl(`${tempoBaseUrl}/api/traces/${linkReady.traceId}`),
          60_000,
        );
      }

      const renderedGrafanaDir = renderGrafanaProvisioningForM36(
        runnerRoot,
        bridgeBaseUrl,
        tempoBaseUrl,
      );
      grafanaProcess = await startGrafanaServer(
        runnerRoot,
        grafanaPort,
        renderedGrafanaDir,
        grafanaBaseUrl,
      );
      const correlations = await fetchJsonFromUrl(
        `${grafanaBaseUrl}/api/datasources/correlations?sourceUID=codetracer-tempo`,
      );
      expect(correlations.totalCount).toBe(1);
      expect(correlations.correlations[0].label).toBe("Debug in CodeTracer");

      for (const linkReady of platformHarness.ready.links) {
        const debugUrl = materializedDebugUrl(
          bridgeBaseUrl,
          platformHarness.ready,
          linkReady,
        );
        const cliRow = await runMaterializedCtObserveAgainstTempo(
          runnerRoot,
          tempoBaseUrl,
          platformHarness.ready,
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

        await page.goto(grafanaExploreTraceUrl(grafanaBaseUrl, linkReady!), {
          waitUntil: "domcontentloaded",
          timeout: 60_000,
        });
        await page.getByText(linkReady!.traceId).first().waitFor({
          timeout: 60_000,
        });
        if (!(await page.getByText(linkReady!.operationName).first().isVisible())) {
          await page.getByText(linkReady!.traceId).first().click();
        }
        await page.getByText(linkReady!.operationName).first().waitFor({
          timeout: 60_000,
        });
        const spanRow = page.getByRole("switch", {
          name: new RegExp(`${escapeRegExp(linkReady!.serviceName)}.*${escapeRegExp(linkReady!.operationName)}`),
        });
        await spanRow.hover();
        await spanRow.click();
        await page.getByText(linkReady!.operationName).first().click();

        const link = page
          .locator(`div[data-item-key*="${linkReady!.spanId}"] a[href]`)
          .first();
        await expect(link).toBeVisible({ timeout: 60_000 });
        const grafanaLinkUrl = await link.getAttribute("href");
        assertM36MaterializedDebugUrl(
          grafanaLinkUrl ?? "",
          platformHarness.ready,
          linkReady!,
        );
        expect(
          debugSessionUrlMatchesMaterializedLink(
            String(cliRows[fixture.language].codetracer_debug_session_url ?? ""),
            platformHarness.ready,
            linkReady!,
          ),
        ).toBe(true);

        const previousLaunches = launches.length;
        const popupPromise = context.waitForEvent("page", { timeout: 5_000 }).catch(() => null);
        await link.click();
        const replayPage = (await popupPromise) ?? page;
        await replayPage.waitForURL(/http:\/\/127\.0\.0\.1:\d+\//, {
          timeout: 120_000,
        });
        await waitFor(
          `${fixture.label} Grafana platform launch bridge started CodeTracer`,
          async () => {
            if (bridgeErrors.length > 0) {
              throw new Error(bridgeErrors.join("\n\n"));
            }
            if (launches.length !== previousLaunches + 1) {
              throw new Error(
                `expected ${previousLaunches + 1} CodeTracer launches, got ${launches.length}\n` +
                  `Bridge events:\n${bridgeEvents.join("\n")}`,
              );
            }
          },
          120_000,
        );
        const launch = launches[launches.length - 1];
        if (!replayPage.url().startsWith(launch.hostUrl)) {
          await replayPage.goto(launch.hostUrl, { timeout: 120_000 });
        }
        await waitForMaterializedReplayDetails(
          replayPage,
          fixture,
          launch.hostOutput,
        );
        await replayPage.screenshot({
          path: path.join(
            m36ArtifactDir() ?? runnerRoot,
            `m36-grafana-tempo-${fixture.language}-materialized-replay.png`,
          ),
          fullPage: true,
        });
      }

      const artifactDir = m36ArtifactDir();
      if (artifactDir) {
        fs.mkdirSync(artifactDir, { recursive: true });
        fs.writeFileSync(
          path.join(artifactDir, "ct-observe-grafana-tempo-materialized-rows.json"),
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
        for (const logFileName of ["grafana.log", "tempo.log"]) {
          const logPath = path.join(runnerRoot, logFileName);
          if (fs.existsSync(logPath)) {
            fs.copyFileSync(logPath, path.join(artifactDir, logFileName));
          }
        }
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
      await stopChild(grafanaProcess);
      await stopChild(tempoProcess);
      if (platformHarness?.process.pid) {
        killProcessTree(platformHarness.process.pid);
      }
      fs.rmSync(prepared.rootDir, { recursive: true, force: true });
      fs.rmSync(runnerRoot, { recursive: true, force: true });
      await sleep(500);
    }
  });

  base("M36 ct-observe launch reaches real Tempo materialized Python CodeTracer replay", async ({ page }) => {
    expectRequiredFile("CodeTracer test binary", codetracerPath);
    expectRequiredFile("ct-observe binary", ctObserveBin());
    expectRequiredFile("codetracer-ci storage harness project", storageHarnessProject);
    expectRequiredFile(
      "ReplayAgent runner entrypoint",
      path.join(codetracerCiDir, "resources", "docker", "codetracer-runner", "replay-entrypoint.sh"),
    );
    const pythonFixture = materializedFixtures.find((fixture) =>
      fixture.language === "python"
    );
    expect(pythonFixture, "Python materialized fixture").toBeTruthy();
    expectRequiredFile("Python materialized trace fixture", pythonFixture!.traceDir);
    expectRequiredFile(
      "Python materialized trace file",
      path.join(pythonFixture!.traceDir, pythonFixture!.traceFileName),
    );
    expectRequiredFile(
      "Python materialized trace metadata",
      path.join(pythonFixture!.traceDir, "trace_metadata.json"),
    );
    expectRequiredFile(
      "Python materialized trace paths",
      path.join(pythonFixture!.traceDir, "trace_paths.json"),
    );

    const prepared = prepareMaterializedPlatformHarnessInput();
    const runnerRoot = fs.mkdtempSync(
      path.join(os.tmpdir(), "ct-m36-ct-observe-launch-tempo-materialized-"),
    );
    let platformHarness: Awaited<ReturnType<typeof startMaterializedPlatformLinkHarness>> | null = null;
    let tempoProcess: childProcess.ChildProcess | null = null;
    let bridge: http.Server | null = null;
    const launches: Array<{
      ctProcess: childProcess.ChildProcess;
      hostOutput: string[];
      hostUrl: string;
      linkReady: MaterializedPlatformLink;
      replayPayload: any;
    }> = [];
    const bridgeErrors: string[] = [];
    const bridgeEvents: string[] = [];

    try {
      platformHarness = await startMaterializedPlatformLinkHarness(prepared.inputPath);
      const linkReady = platformHarness.ready.links.find((link) =>
        link.language === "python"
      );
      expect(linkReady, "Python materialized platform link").toBeTruthy();
      fs.rmSync(prepared.rootDir, { recursive: true, force: true });

      const tempoHttpPort = await freeTcpPort();
      const tempoGrpcPort = await freeTcpPort();
      const tempoOtlpPort = await freeTcpPort();
      const bridgePort = await freeTcpPort();
      const bridgeBaseUrl = `http://127.0.0.1:${bridgePort}`;
      const tempoBaseUrl = `http://127.0.0.1:${tempoHttpPort}`;
      const debugUrl = materializedDebugUrl(
        bridgeBaseUrl,
        platformHarness.ready,
        linkReady!,
      );

      bridge = startMaterializedPlatformLaunchBridge({
        ready: platformHarness.ready,
        runnerRoot,
        port: bridgePort,
        bridgeErrors,
        bridgeEvents,
        launches,
      });
      tempoProcess = await startTempoServer(
        runnerRoot,
        tempoHttpPort,
        tempoGrpcPort,
        tempoOtlpPort,
        tempoBaseUrl,
      );
      await ingestMaterializedTempoSpan(
        tempoOtlpPort,
        platformHarness.ready,
        linkReady!,
        debugUrl,
      );
      await waitFor(
        "Python materialized Tempo trace ingestion",
        async () => fetchJsonFromUrl(`${tempoBaseUrl}/api/traces/${linkReady!.traceId}`),
        60_000,
      );

      const launchJson = await runMaterializedCtObserveLaunchAgainstTempo(
        runnerRoot,
        tempoBaseUrl,
        linkReady!,
      );
      expect(launchJson.debug_session_url).toBe(debugUrl);

      await waitFor(
        "ct-observe Tempo materialized launch bridge started CodeTracer",
        async () => {
          if (bridgeErrors.length > 0) {
            throw new Error(bridgeErrors.join("\n\n"));
          }
          if (launches.length !== 1) {
            throw new Error(
              `expected one CodeTracer launch, got ${launches.length}\n` +
                `Bridge events:\n${bridgeEvents.join("\n")}`,
            );
          }
        },
        120_000,
      );
      const launch = launches[0];
      expect(launchJson.redirect_url).toBe(launch.hostUrl);
      await page.goto(launchJson.redirect_url, { timeout: 120_000 });
      await waitForMaterializedReplayDetails(
        page,
        pythonFixture!,
        launch.hostOutput,
      );

      const artifactDir = m36ArtifactDir();
      if (artifactDir) {
        fs.mkdirSync(artifactDir, { recursive: true });
        fs.writeFileSync(
          path.join(artifactDir, "ct-observe-launch-tempo-python-materialized.json"),
          JSON.stringify(launchJson, null, 2),
        );
        fs.writeFileSync(
          path.join(artifactDir, "ct-observe-launch-tempo-python-materialized-ct-host-output.log"),
          launch.hostOutput.join(""),
        );
        fs.writeFileSync(
          path.join(artifactDir, "ct-observe-launch-tempo-python-materialized-bridge-events.log"),
          bridgeEvents.join("\n"),
        );
        const tempoLogPath = path.join(runnerRoot, "tempo.log");
        if (fs.existsSync(tempoLogPath)) {
          fs.copyFileSync(tempoLogPath, path.join(artifactDir, "tempo.log"));
        }
      }
      await page.screenshot({
        path: path.join(
          m36ArtifactDir() ?? runnerRoot,
          "m36-ct-observe-launch-tempo-python-materialized-replay.png",
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
      await stopChild(tempoProcess);
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
    expectRequiredFile(
      "ReplayAgent runner entrypoint",
      path.join(codetracerCiDir, "resources", "docker", "codetracer-runner", "replay-entrypoint.sh"),
    );
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
    const bridgeErrors: string[] = [];
    const bridgeEvents: string[] = [];
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
        bridgeErrors,
        bridgeEvents,
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
        const debugHref = cliRows[fixture.language].codetracer_debug_session_url;
        const link = page.locator("a").filter({ hasText: debugHref }).first();
        await expect(link).toBeVisible({ timeout: 60_000 });
        expect(await link.getAttribute("href")).toBe(debugHref);

        const previousLaunches = launches.length;
        const navigationResponse = await page.goto(debugHref, { waitUntil: "domcontentloaded", timeout: 120_000 });
        expect(
          navigationResponse?.status(),
          `${fixture.label} debug-session navigation status; bridge events:\n${bridgeEvents.join("\n")}\nBridge errors:\n${bridgeErrors.join("\n\n")}`,
        ).toBeLessThan(400);
        const replayPage = page;
        await waitFor(
          `${fixture.label} platform launch bridge started CodeTracer`,
          async () => {
            if (bridgeErrors.length > 0) {
              throw new Error(bridgeErrors.join("\n\n"));
            }
            if (launches.length !== previousLaunches + 1) {
              throw new Error(
                `expected ${previousLaunches + 1} CodeTracer launches, got ${launches.length}\n` +
                  `Bridge events:\n${bridgeEvents.join("\n")}`,
              );
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
