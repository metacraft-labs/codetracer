/**
 * Observability M29 acceptance: local MCR manifest hostability.
 *
 * This test exercises the user-facing `ct host --manifest=<manifest.json>`
 * path with a real portable MCR `.ct` artifact. It intentionally does not use
 * the generic `deploymentMode: "web"` fixture, because the acceptance target
 * is the local manifest loader itself, not only web-mode replay by trace ID.
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
const portReleaseDelayMs = 500;
const browserDetailTimeoutMs = 60_000;

type SliceManifestEntry = {
  intervalId: number;
  slicePath: string;
  geidStart: bigint;
  geidEnd: bigint;
  tickStart: bigint;
  tickEnd: bigint;
  eventCount: number;
};

type SplitMcrManifest = {
  rootDir: string;
  manifestPath: string;
  selectedSegmentPath: string;
  otherSegmentPaths: string[];
};

type ExpectedImportedCtfsSegment = {
  selectedSegmentPath: string;
  otherSegmentPaths: string[];
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

function prepareLocalMcrManifest(): { rootDir: string; manifestPath: string } {
  const rootDir = fs.mkdtempSync(path.join(os.tmpdir(), "ct-m29-mcr-manifest-"));
  const objectDir = path.join(rootDir, "objects", "m25-inventory");
  fs.mkdirSync(objectDir, { recursive: true });

  const localTracePath = path.join(objectDir, "inventory.ct");
  const localSourcePath = path.join(objectDir, "inventory_smoke.c");
  const localRequestDetailsPath = path.join(objectDir, "inventory-response.json");
  fs.copyFileSync(portableTracePath, localTracePath);
  fs.copyFileSync(fixtureSourcePath, localSourcePath);
  fs.copyFileSync(fixtureRequestDetailsPath, localRequestDetailsPath);
  fs.writeFileSync(
    path.join(objectDir, "trace_paths.json"),
    JSON.stringify([localSourcePath, localRequestDetailsPath], null, 2),
  );

  if (fs.existsSync(fixtureBinaryPath)) {
    const binariesDir = path.join(objectDir, "binaries");
    fs.mkdirSync(binariesDir, { recursive: true });
    fs.copyFileSync(fixtureBinaryPath, path.join(binariesDir, "inventory_smoke"));
  }

  const manifestPath = path.join(rootDir, "manifest.json");
  const manifest = {
    schema: "codetracer.trace-storage.v1",
    source: {
      kind: "single_ctfs",
      file: {
        uri: "objects/m25-inventory/inventory.ct",
        uploadCompletionState: "complete",
        retentionStatus: "available",
        sizeBytes: fs.statSync(portableTracePath).size,
      },
      replay_start: {
        trace_id: "m25-real-mcr-request-001",
        span_id: "30000000000025cc",
        geid: "1",
      },
    },
  };
  fs.writeFileSync(manifestPath, JSON.stringify(manifest, null, 2));

  return { rootDir, manifestPath };
}

function sha256File(filePath: string): string {
  return crypto
    .createHash("sha256")
    .update(fs.readFileSync(filePath))
    .digest("hex");
}

function segmentInteriorGeid(entry: SliceManifestEntry): bigint {
  if (entry.geidEnd > entry.geidStart) return entry.geidStart + 1n;
  if (entry.geidStart > 0n) return entry.geidStart;
  return entry.geidEnd;
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

  offset += 4; // totalIntervals
  offset = readVarString(buffer, offset).nextOffset; // original trace path
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
    const tickStart = buffer.readBigUInt64LE(offset);
    offset += 8;
    const tickEnd = buffer.readBigUInt64LE(offset);
    offset += 8;
    const eventCount = buffer.readUInt32LE(offset);
    offset += 4;
    entries.push({
      intervalId,
      slicePath: slicePath.value,
      geidStart,
      geidEnd,
      tickStart,
      tickEnd,
      eventCount,
    });
  }

  return entries;
}

function prepareLocalSplitMcrManifest(): SplitMcrManifest {
  expectRequiredFile("ct-mcr slicer", ctMcrPath);

  const rootDir = fs.mkdtempSync(
    path.join(os.tmpdir(), "ct-m29-split-mcr-manifest-"),
  );
  const objectDir = path.join(rootDir, "objects", "m25-inventory-split");
  const segmentsDir = path.join(objectDir, "segments");
  fs.mkdirSync(segmentsDir, { recursive: true });

  const localTracePath = path.join(objectDir, "inventory.ct");
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
    "M29 split manifest acceptance requires the four retained split segments claimed by the milestone",
  ).toBe(4);

  const segmentPaths = sliceEntries.map((entry) =>
    path.join(segmentsDir, entry.slicePath),
  );
  const segmentHashes = segmentPaths.map(sha256File);
  expect(
    new Set(segmentHashes).size,
    "M29 split manifest segment identity check requires byte-distinct segment files",
  ).toBe(segmentPaths.length);

  const localSourcePath = path.join(segmentsDir, "inventory_smoke.c");
  const localRequestDetailsPath = path.join(segmentsDir, "inventory-response.json");
  fs.copyFileSync(fixtureSourcePath, localSourcePath);
  fs.copyFileSync(fixtureRequestDetailsPath, localRequestDetailsPath);
  fs.writeFileSync(
    path.join(segmentsDir, "trace_paths.json"),
    JSON.stringify([localSourcePath, localRequestDetailsPath], null, 2),
  );

  if (fs.existsSync(fixtureBinaryPath)) {
    const binariesDir = path.join(segmentsDir, "binaries");
    fs.mkdirSync(binariesDir, { recursive: true });
    fs.copyFileSync(fixtureBinaryPath, path.join(binariesDir, "inventory_smoke"));
  }

  const selectedEntry = sliceEntries[sliceEntries.length - 1];
  const selectedGeid = segmentInteriorGeid(selectedEntry);
  const selectedSegmentPath = path.join(segmentsDir, selectedEntry.slicePath);

  const manifestPath = path.join(rootDir, "manifest.json");
  const manifest = {
    schema: "codetracer.trace-storage.v1",
    source: {
      kind: "split_ctfs",
      segments: sliceEntries.map((entry) => {
        const segmentPath = path.join(segmentsDir, entry.slicePath);
        return {
          index: entry.intervalId,
          geid_start: entry.geidStart.toString(),
          geid_end: entry.geidEnd.toString(),
          file: {
            uri: `objects/m25-inventory-split/segments/${entry.slicePath}`,
            uploadCompletionState: "complete",
            retentionStatus: "available",
            sizeBytes: fs.statSync(segmentPath).size,
          },
        };
      }),
      replay_start: {
        trace_id: "m25-real-mcr-request-001",
        span_id: "30000000000025cc",
        geid: selectedGeid.toString(),
      },
    },
  };
  fs.writeFileSync(manifestPath, JSON.stringify(manifest, null, 2));

  return {
    rootDir,
    manifestPath,
    selectedSegmentPath,
    otherSegmentPaths: segmentPaths.filter(
      (segmentPath) => segmentPath !== selectedSegmentPath,
    ),
  };
}

function expectRequiredFile(label: string, filePath: string): void {
  expect(
    fs.existsSync(filePath),
    `${label} is required for M29 manifest acceptance: ${filePath}`,
  ).toBe(true);
}

async function waitForHostOutput(
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
      `Timed out waiting for host output ${pattern}.\n` +
        `Captured host output:\n${output.join("")}`,
      { cause: error },
    );
  }
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

async function waitForBrowserText(
  page: Page,
  expectedText: string,
  timeoutMs = browserDetailTimeoutMs,
): Promise<string> {
  try {
    await retry(
      async () => {
        const bodyText = await page.evaluate(() => document.body.innerText);
        return bodyText.includes(expectedText);
      },
      {
        maxAttempts: Math.ceil(timeoutMs / 1_000),
        delayMs: 1_000,
      },
    );
    return await page.evaluate(() => document.body.innerText);
  } catch (error) {
    const bodyText = await page.evaluate(() => document.body.innerText);
    throw new Error(
      `Timed out waiting for browser text ${JSON.stringify(expectedText)}.\n` +
        `Browser body sample:\n${bodyText.slice(0, 4000)}`,
      { cause: error },
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
      async () => {
        const modelText = await readEditorText();
        return modelText.includes(expectedText);
      },
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

async function exerciseLocalMcrManifestBrowserAcceptance(
  manifestPath: string,
  rootDir: string,
  expectedImportedSegment?: ExpectedImportedCtfsSegment,
): Promise<void> {
  const httpPort = await getFreeTcpPort();
  const backendPort = await getFreeTcpPort();
  let ctProcess: childProcess.ChildProcess | null = null;
  let browser: Awaited<ReturnType<typeof chromium.launch>> | null = null;

  try {
    console.log(
      `# launching ct host --manifest=${manifestPath} on port ${httpPort}`,
    );
    ctProcess = childProcess.spawn(
      codetracerPath,
      [
        "host",
        `--manifest=${manifestPath}`,
        `--port=${httpPort}`,
        `--backend-socket-port=${backendPort}`,
        `--frontend-socket=${backendPort}`,
      ],
      {
        cwd: codetracerInstallDir,
        env: makeCleanEnv({
          XDG_CONFIG_HOME: path.join(rootDir, "xdg-config"),
        }),
        stdio: ["ignore", "pipe", "pipe"],
        windowsHide: true,
      },
    );

    const hostOutput: string[] = [];
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

    await waitForHostOutput(hostOutput, /loaded local manifest:/);
    const importOutput = await waitForHostOutput(
      hostOutput,
      /imported manifest trace as trace id\s+\d+/,
    );
    expect(importOutput).toContain(manifestPath);
    if (expectedImportedSegment) {
      expect(importOutput).toContain(
        `ct host: selected split_ctfs segment: ${expectedImportedSegment.selectedSegmentPath}`,
      );
      for (const otherSegmentPath of expectedImportedSegment.otherSegmentPaths) {
        expect(importOutput).not.toContain(
          `ct host: selected split_ctfs segment: ${otherSegmentPath}`,
        );
      }
    }

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
    console.log(`# browser body sample:\n${bodyText.slice(0, 2000)}`);
    console.log(`# source model sample:\n${sourceText.slice(0, 2000)}`);
    console.log(
      `# request details model sample:\n${requestDetailsText.slice(0, 2000)}`,
    );
    const traceMetadata = await page.evaluate(() => {
      const d = (window as any).data;
      const trace = d?.sessions?.[d?.activeSessionIndex ?? 0]?.trace;
      return {
        id: Number(trace?.id ?? -1),
        program: String(trace?.program ?? ""),
        outputFolder: String(trace?.outputFolder ?? ""),
      };
    });
    console.log(
      `# active trace metadata: ${JSON.stringify(traceMetadata, null, 2)}`,
    );
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
    await sleep(portReleaseDelayMs);
    if (browser) {
      await browser.close().catch(() => undefined);
    }
    delete process.env.CODETRACER_TRACE_ID;
    delete process.env.CODETRACER_CALLER_PID;
    delete process.env.CODETRACER_IN_UI_TEST;
    delete process.env.CODETRACER_TEST;
  }
}

base.describe("Observability M29 local MCR manifest browser acceptance", () => {
  base.describe.configure({ mode: "serial", timeout: 180_000 });

  base("ct host --manifest loads a local MCR .ct and opens replay details", async ({}) => {
    expectRequiredFile("CodeTracer test binary", codetracerPath);
    expectRequiredFile("real MCR request trace fixture", portableTracePath);
    expectRequiredFile("MCR request source file", fixtureSourcePath);
    expectRequiredFile("MCR request binary fixture", fixtureBinaryPath);
    expectRequiredFile("MCR request details fixture", fixtureRequestDetailsPath);

    const { rootDir, manifestPath } = prepareLocalMcrManifest();

    try {
      await exerciseLocalMcrManifestBrowserAcceptance(manifestPath, rootDir);
    } finally {
      fs.rmSync(rootDir, { recursive: true, force: true });
    }
  });

  base("ct host --manifest loads a local split_ctfs MCR segment and opens replay details", async ({}) => {
    expectRequiredFile("CodeTracer test binary", codetracerPath);
    expectRequiredFile("real MCR request trace fixture", portableTracePath);
    expectRequiredFile("MCR request source file", fixtureSourcePath);
    expectRequiredFile("MCR request binary fixture", fixtureBinaryPath);
    expectRequiredFile("MCR request details fixture", fixtureRequestDetailsPath);

    const {
      rootDir,
      manifestPath,
      selectedSegmentPath,
      otherSegmentPaths,
    } = prepareLocalSplitMcrManifest();
    const manifest = JSON.parse(fs.readFileSync(manifestPath, "utf-8"));
    expect(manifest.source.kind).toBe("split_ctfs");
    expect(manifest.source.segments.length).toBe(4);

    try {
      await exerciseLocalMcrManifestBrowserAcceptance(manifestPath, rootDir, {
        selectedSegmentPath,
        otherSegmentPaths,
      });
    } finally {
      fs.rmSync(rootDir, { recursive: true, force: true });
    }
  });
});
