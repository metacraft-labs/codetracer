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
import * as os from "node:os";
import * as path from "node:path";
import * as process from "node:process";

import { test as base, expect, chromium, type Page } from "@playwright/test";

import {
  codetracerInstallDir,
  codetracerPath,
} from "../lib/fixtures";
import { getFreeTcpPort } from "../lib/port-allocator";
import { retry } from "../lib/retry-helpers";

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

type StorageHarnessReady = {
  baseUrl: string;
  tenantId: string;
  replayToken: string;
  manifestPath: string;
  serverIds: string[];
  selectedSegmentIndex: number;
};

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
  const inputPath = path.join(rootDir, "storage-harness-input.json");
  fs.writeFileSync(
    inputPath,
    JSON.stringify(
      {
        traceId: "m25-real-mcr-request-001",
        spanId: "30000000000025cc",
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

base.describe("Observability M34 storage-server MCR manifest browser acceptance", () => {
  base.describe.configure({ mode: "serial", timeout: 300_000 });

  base("ct host --manifest loads sharded split MCR bytes from codetracer-ci local-storage endpoints", async ({}) => {
    expectRequiredFile("CodeTracer test binary", codetracerPath);
    expectRequiredFile("codetracer-ci storage harness project", storageHarnessProject);
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
      expect(importOutput).toContain(storageHarness.ready.baseUrl);
      expect(importOutput).toContain(
        `/servers/${storageHarness.ready.serverIds[0]}/objects/`,
      );
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
});
