/**
 * Observability M34 acceptance: storage-server backed materialized manifest hostability.
 *
 * Starts the codetracer-ci ASP.NET local-storage API harness, uploads real
 * Python, Ruby, and JavaScript materialized trace folders through authenticated
 * storage endpoints, then launches `ct host --manifest` using only storage
 * references for the trace payload and companion files.
 */

import * as childProcess from "node:child_process";
import * as fs from "node:fs";
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
const codetracerCiDir = path.join(workspaceRoot, "codetracer-ci");
const storageHarnessProject = path.join(
  codetracerCiDir,
  "tests",
  "CrossRepo.ObservabilityDebugSessionHarness",
  "CrossRepo.ObservabilityDebugSessionHarness.csproj",
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

type MaterializedFlowFixture = {
  label: string;
  language: string;
  traceDir: string;
  traceFileName: "trace.bin" | "trace.json";
  sourceFileName: string;
  requiredSourceSnippets: string[];
  calltraceFunction: string;
  expectedCallArgs?: Record<string, string>;
  eventText: string;
  terminalText: string;
  programFragment: string;
  traceId: string;
  spanId: string;
  momentId: string;
};

const materializedFixtures: MaterializedFlowFixture[] = [
  {
    label: "Python",
    language: "python",
    traceDir: pythonFlowTraceFixture,
    traceFileName: "trace.bin",
    sourceFileName: "python_flow_test.py",
    requiredSourceSnippets: ["calculate_sum", "sum_with_while"],
    calltraceFunction: "calculate_sum",
    eventText: "Result: 94",
    terminalText: "Result: 94",
    programFragment: "python_flow_test.py",
    traceId: "m34-python-materialized-flow",
    spanId: "30000000000034aa",
    momentId: "m34-python-flow-calculate-sum",
  },
  {
    label: "Ruby",
    language: "ruby",
    traceDir: rubyFlowTraceFixture,
    traceFileName: "trace.json",
    sourceFileName: "ruby_flow_test.rb",
    requiredSourceSnippets: ["def calculate_sum", "def sum_with_while"],
    calltraceFunction: "calculate_sum",
    expectedCallArgs: { a: "10", b: "32" },
    eventText: "sum with while 45",
    terminalText: "Result: 94",
    programFragment: "ruby_flow_test.rb",
    traceId: "m34-ruby-materialized-flow",
    spanId: "30000000000034bb",
    momentId: "m34-ruby-flow-calculate-sum",
  },
  {
    label: "JavaScript",
    language: "javascript",
    traceDir: javascriptFlowTraceFixture,
    traceFileName: "trace.json",
    sourceFileName: "javascript_flow_test.js",
    requiredSourceSnippets: ["function calculate_sum", "var sum_val"],
    calltraceFunction: "calculate_sum",
    expectedCallArgs: { a: "10", b: "32" },
    eventText: "Result: 94",
    terminalText: "Result: 94",
    programFragment: "javascript_flow_test.js",
    traceId: "m34-javascript-materialized-flow",
    spanId: "30000000000034cc",
    momentId: "m34-javascript-flow-calculate-sum",
  },
];

const maxConnectAttempts = 25;
const retryDelayMs = 1_500;
const gotoTimeoutMs = 5_000;
const browserDetailTimeoutMs = 60_000;

type StorageHarnessReady = {
  baseUrl: string;
  tenantId: string;
  replayToken: string;
  serverIds: string[];
  manifests: { language: string; manifestPath: string }[];
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
  // M-REC-6: CODETRACER_TRACE_ID → CODETRACER_RECORDING_ID; delete both.
  delete env.CODETRACER_TRACE_ID;
  delete env.CODETRACER_RECORDING_ID;
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
  return { ...env, ...extra };
}

function resolveChromiumPath(): string | undefined {
  const explicit = process.env.PLAYWRIGHT_CHROMIUM_EXECUTABLE_PATH;
  if (explicit && fs.existsSync(explicit)) {
    return explicit;
  }

  // Candidate browser caches: the explicit env var, then Playwright's
  // default install location.  Returning `undefined` when none yield a
  // chromium lets `chromium.launch()` fall back to its bundled browser
  // rather than throwing — the GUI test still runs on machines that did
  // not set $PLAYWRIGHT_BROWSERS_PATH.
  const candidateDirs: string[] = [];
  if (process.env.PLAYWRIGHT_BROWSERS_PATH) {
    candidateDirs.push(process.env.PLAYWRIGHT_BROWSERS_PATH);
  }
  const homeDir = os.homedir();
  if (homeDir) {
    candidateDirs.push(
      process.platform === "win32"
        ? path.join(homeDir, "AppData", "Local", "ms-playwright")
        : path.join(homeDir, ".cache", "ms-playwright"),
    );
  }

  for (const browsersDir of candidateDirs) {
    if (!fs.existsSync(browsersDir)) {
      continue;
    }
    const chromiumDir = fs
      .readdirSync(browsersDir)
      .filter((dir) => dir.startsWith("chromium-") && !dir.includes("headless"))
      .sort()
      .pop();
    if (!chromiumDir) {
      continue;
    }
    const chromiumBase = path.join(browsersDir, chromiumDir);
    if (process.platform === "win32") {
      const chromeSubdir = fs
        .readdirSync(chromiumBase)
        .find((dir) => dir.startsWith("chrome-win"));
      if (chromeSubdir) {
        const exe = path.join(chromiumBase, chromeSubdir, "chrome.exe");
        if (fs.existsSync(exe)) {
          return exe;
        }
      }
    } else {
      const chromeSubdir = fs
        .readdirSync(chromiumBase)
        .find((dir) => dir.startsWith("chrome-linux"));
      if (chromeSubdir) {
        const exe = path.join(chromiumBase, chromeSubdir, "chrome");
        if (fs.existsSync(exe)) {
          return exe;
        }
      }
    }
  }
  return undefined;
}

function expectRequiredPath(label: string, filePath: string): void {
  expect(
    fs.existsSync(filePath),
    `${label} is required for M34 materialized storage acceptance: ${filePath}`,
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

function prepareStorageHarnessInput(): { rootDir: string; inputPath: string } {
  const rootDir = fs.mkdtempSync(
    path.join(os.tmpdir(), "ct-m34-storage-materialized-manifest-"),
  );
  const inputPath = path.join(rootDir, "storage-harness-input.json");
  fs.writeFileSync(
    inputPath,
    JSON.stringify(
      {
        artifacts: materializedFixtures.map((fixture) => ({
          language: fixture.language,
          traceId: fixture.traceId,
          spanId: fixture.spanId,
          momentId: fixture.momentId,
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
      "storage-server-materialized-manifest",
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

async function waitForFilesystemSourcePath(
  page: Page,
  fixture: MaterializedFlowFixture,
): Promise<string> {
  const layout = new LayoutPage(page);
  await layout.waitForFilesystemLoaded();

  await retry(
    async () => {
      const labels = await page
        .locator(".jstree-anchor")
        .evaluateAll((anchors) =>
          anchors.map((anchor) => String(anchor.textContent ?? "").trim()),
        );
      return labels.includes(fixture.sourceFileName);
    },
    {
      maxAttempts: Math.ceil(browserDetailTimeoutMs / 1_000),
      delayMs: 1_000,
    },
  );
  return fixture.sourceFileName;
}

async function verifyMaterializedTraceDetails(
  page: Page,
  fixture: MaterializedFlowFixture,
): Promise<string> {
  await expect(page.locator(".lm_content").first()).toBeVisible({
    timeout: 30_000,
  });

  const sourcePath = await waitForFilesystemSourcePath(page, fixture);
  const sourceNode = page
    .locator(".jstree-anchor")
    .filter({ hasText: new RegExp(`^${escapeRegExp(fixture.sourceFileName)}$`) })
    .first();
  await expect(
    sourceNode,
    `${fixture.label} source node should be rendered for imported path ${sourcePath}`,
  ).toBeVisible({ timeout: 30_000 });
  await sourceNode.click();

  const sourceText = await waitForEditorModelText(
    page,
    fixture.requiredSourceSnippets[0],
  );
  for (const snippet of fixture.requiredSourceSnippets.slice(1)) {
    await waitForEditorModelText(page, snippet);
  }

  const layout = new LayoutPage(page);
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

  return sourceText;
}

async function runHostForFixture(
  fixture: MaterializedFlowFixture,
  ready: StorageHarnessReady,
): Promise<void> {
  const manifestEntry = ready.manifests.find(
    (entry) => entry.language === fixture.language,
  );
  expect(manifestEntry, `${fixture.label} storage manifest entry`).toBeTruthy();
  const manifestPath = manifestEntry!.manifestPath;
  const storageManifest = JSON.parse(fs.readFileSync(manifestPath, "utf-8"));
  expect(storageManifest.source.kind).toBe("materialized_artifact");
  expect(storageManifest.source.artifact.objectKey).toContain(
    `/${fixture.traceFileName}`,
  );
  expect(storageManifest.source.supportFiles.length).toBeGreaterThanOrEqual(3);

  const httpPort = await getFreeTcpPort();
  const backendPort = await getFreeTcpPort();
  const hostOutput: string[] = [];
  let ctProcess: childProcess.ChildProcess | null = null;
  let browser: Awaited<ReturnType<typeof chromium.launch>> | null = null;

  try {
    ctProcess = childProcess.spawn(
      codetracerPath,
      [
        "host",
        `--manifest=${manifestPath}`,
        `--storage-base-url=${ready.baseUrl}`,
        `--storage-tenant-id=${ready.tenantId}`,
        `--storage-token=${ready.replayToken}`,
        "--storage-protocol=local-storage",
        `--port=${httpPort}`,
        `--backend-socket-port=${backendPort}`,
        `--frontend-socket=${backendPort}`,
      ],
      {
        cwd: codetracerInstallDir,
        env: makeCleanEnv({
          XDG_CONFIG_HOME: path.join(
            os.tmpdir(),
            `ct-m34-materialized-xdg-${fixture.language}-${Date.now()}`,
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
    expect(importOutput).toContain("fetching materialized artifact from storage:");
    expect(importOutput).toContain("fetching storage support file trace_metadata.json from storage:");
    expect(importOutput).toContain("fetching storage support file trace_paths.json from storage:");
    expect(importOutput).toContain(`fetching storage support file files/`);
    expect(importOutput).toContain(ready.baseUrl);
    expect(importOutput).toContain(`/servers/${ready.serverIds[0]}/objects/`);

    await connectToHost(page, httpPort, hostOutput);
    const sourceText = await verifyMaterializedTraceDetails(page, fixture);
    // M-REC-3/M-REC-7: the renderer Trace object's identity field is
    // ``recordingId`` — a canonical UUIDv7 string.  The pre-M-REC-2
    // numeric ``id`` field was retired, and the on-disk output folder
    // is the bare UUID (no ``trace-<n>`` prefix any more).  See
    // ``codetracer-specs/Refactoring-Plans/Recording-Identifier-Migration.md``.
    const traceMetadata = await page.evaluate(() => {
      const d = (window as any).data;
      const trace = d?.sessions?.[d?.activeSessionIndex ?? 0]?.trace;
      return {
        recordingId: String(trace?.recordingId ?? ""),
        program: String(trace?.program ?? ""),
        outputFolder: String(trace?.outputFolder ?? ""),
      };
    });

    const importedTracePaths = JSON.parse(
      fs.readFileSync(
        path.join(traceMetadata.outputFolder, "trace_paths.json"),
        "utf-8",
      ),
    ) as string[];
    const importedSourcePath = importedTracePaths.find((tracePath) =>
      tracePath.endsWith(fixture.sourceFileName),
    );
    expect(importedSourcePath, `${fixture.label} imported source path`).toBeTruthy();
    expect(
      path.isAbsolute(importedSourcePath ?? ""),
      `${fixture.label} imported source path should be self-contained`,
    ).toBe(false);
    expect(
      fs.existsSync(
        path.join(traceMetadata.outputFolder, "files", importedSourcePath ?? ""),
      ),
      `${fixture.label} imported source payload should exist`,
    ).toBe(true);

    for (const snippet of fixture.requiredSourceSnippets) {
      expect(sourceText).toContain(snippet);
    }
    expect(
      /^[0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/.test(
        traceMetadata.recordingId,
      ),
      `${fixture.label} trace recording id should be a canonical UUIDv7`,
    ).toBe(true);
    expect(traceMetadata.program).toContain(fixture.programFragment);
    expect(
      fs.existsSync(traceMetadata.outputFolder),
      `${fixture.label} trace output folder should exist on disk`,
    ).toBe(true);
    expect(path.basename(traceMetadata.outputFolder)).toBe(traceMetadata.recordingId);
  } finally {
    if (ctProcess?.pid) {
      killProcessTree(ctProcess.pid);
    }
    if (browser) {
      await browser.close().catch(() => undefined);
    }
    await sleep(500);
  }
}

base.describe("Observability M34 storage-server materialized manifest browser acceptance", () => {
  base.describe.configure({ mode: "serial", timeout: 600_000 });

  base("ct host --manifest loads Python, Ruby, and JavaScript materialized traces from codetracer-ci local-storage endpoints", async ({}) => {
    expectRequiredPath("CodeTracer test binary", codetracerPath);
    expectRequiredPath("codetracer-ci storage harness project", storageHarnessProject);
    for (const fixture of materializedFixtures) {
      expectRequiredPath(`${fixture.label} materialized trace fixture`, fixture.traceDir);
      expectRequiredPath(
        `${fixture.label} materialized ${fixture.traceFileName}`,
        path.join(fixture.traceDir, fixture.traceFileName),
      );
      expectRequiredPath(
        `${fixture.label} materialized trace metadata`,
        path.join(fixture.traceDir, "trace_metadata.json"),
      );
      expectRequiredPath(
        `${fixture.label} materialized trace paths`,
        path.join(fixture.traceDir, "trace_paths.json"),
      );
    }

    const prepared = prepareStorageHarnessInput();
    let storageHarness: Awaited<ReturnType<typeof startStorageHarness>> | null = null;

    try {
      storageHarness = await startStorageHarness(prepared.inputPath);
      expect(storageHarness.ready.serverIds.length).toBe(1);
      expect(storageHarness.ready.manifests.map((entry) => entry.language).sort())
        .toEqual(materializedFixtures.map((fixture) => fixture.language).sort());

      fs.rmSync(prepared.rootDir, { recursive: true, force: true });

      for (const fixture of materializedFixtures) {
        await runHostForFixture(fixture, storageHarness.ready);
      }
    } finally {
      if (storageHarness?.process.pid) {
        killProcessTree(storageHarness.process.pid);
      }
      fs.rmSync(prepared.rootDir, { recursive: true, force: true });
      await sleep(500);
    }
  });
});
