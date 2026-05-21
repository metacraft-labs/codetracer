/**
 * Observability M29 acceptance: local materialized manifest hostability.
 *
 * Exercises the user-facing `ct host --manifest=<manifest.json>` path with
 * real hostable materialized trace folders (`trace.bin`/`trace.json` plus
 * metadata).
 * The test intentionally launches `ct host` directly because the acceptance
 * target is manifest routing, import, and browser replay from that manifest.
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

const pythonFlowTraceFixture = path.join(
  codetracerInstallDir,
  "examples",
  "recordings",
  "python",
  "flow_test",
);
const pythonFlowSourceFixture = path.join(
  codetracerInstallDir,
  "examples",
  "recordings",
  "programs",
  "python_flow_test.py",
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
const javascriptFlowSourceFixture = path.join(
  javascriptFlowTraceFixture,
  "files",
  "tmp",
  "ct-example-recordings-build",
  "javascript_flow_test.js",
);
const rubyFlowSourcePayload = path.join(
  rubyFlowTraceFixture,
  "files",
  "tmp",
  "ct-example-recordings-build",
  "ruby_flow_test.rb",
);

type MaterializedFlowFixture = {
  label: string;
  objectName: string;
  traceDir: string;
  traceFileName: "trace.bin" | "trace.json";
  sourcePath: string;
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

const pythonFlowFixture: MaterializedFlowFixture = {
  label: "Python",
  objectName: "python-flow",
  traceDir: pythonFlowTraceFixture,
  traceFileName: "trace.bin",
  sourcePath: pythonFlowSourceFixture,
  sourceFileName: "python_flow_test.py",
  requiredSourceSnippets: ["calculate_sum", "sum_with_while"],
  calltraceFunction: "calculate_sum",
  eventText: "Result: 94",
  terminalText: "Result: 94",
  programFragment: "python_flow_test.py",
  traceId: "m29-python-materialized-flow",
  spanId: "30000000000029aa",
  momentId: "m29-python-flow-calculate-sum",
};

const rubyFlowFixture: MaterializedFlowFixture = {
  label: "Ruby",
  objectName: "ruby-flow",
  traceDir: rubyFlowTraceFixture,
  traceFileName: "trace.json",
  sourcePath: rubyFlowSourcePayload,
  sourceFileName: "ruby_flow_test.rb",
  requiredSourceSnippets: ["def calculate_sum", "def sum_with_while"],
  calltraceFunction: "calculate_sum",
  expectedCallArgs: {
    a: "10",
    b: "32",
  },
  eventText: "sum with while 45",
  terminalText: "Result: 94",
  programFragment: "ruby_flow_test.rb",
  traceId: "m29-ruby-materialized-flow",
  spanId: "30000000000029bb",
  momentId: "m29-ruby-flow-calculate-sum",
};

const javascriptFlowFixture: MaterializedFlowFixture = {
  label: "JavaScript",
  objectName: "javascript-flow",
  traceDir: javascriptFlowTraceFixture,
  traceFileName: "trace.json",
  sourcePath: javascriptFlowSourceFixture,
  sourceFileName: "javascript_flow_test.js",
  requiredSourceSnippets: ["function calculate_sum", "var sum_val"],
  calltraceFunction: "calculate_sum",
  expectedCallArgs: {
    a: "10",
    b: "32",
  },
  eventText: "Result: 94",
  terminalText: "Result: 94",
  programFragment: "javascript_flow_test.js",
  traceId: "m29-javascript-materialized-flow",
  spanId: "30000000000029cc",
  momentId: "m29-javascript-flow-calculate-sum",
};

const maxConnectAttempts = 25;
const retryDelayMs = 1_500;
const gotoTimeoutMs = 5_000;
const portReleaseDelayMs = 500;
const browserDetailTimeoutMs = 60_000;

type FilesystemSourceState = {
  matchedPath: string;
  filesystemPaths: string[];
  anchorLabels: string[];
  renderedSourceLabel: string;
  traceProgram: string;
  traceOutputFolder: string;
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

function copyDirectory(srcDir: string, destDir: string): void {
  fs.mkdirSync(destDir, { recursive: true });
  for (const entry of fs.readdirSync(srcDir, { withFileTypes: true })) {
    const src = path.join(srcDir, entry.name);
    const dest = path.join(destDir, entry.name);
    if (entry.isDirectory()) {
      copyDirectory(src, dest);
    } else if (entry.isFile()) {
      fs.copyFileSync(src, dest);
    }
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
    `${label} is required for M29 materialized manifest acceptance: ${filePath}`,
  ).toBe(true);
}

function escapeRegExp(value: string): string {
  return value.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
}

function prepareLocalMaterializedManifest(fixture: MaterializedFlowFixture): {
  rootDir: string;
  manifestPath: string;
} {
  const rootDir = fs.mkdtempSync(
    path.join(os.tmpdir(), "ct-m29-materialized-manifest-"),
  );
  const objectDir = path.join(rootDir, "objects", fixture.objectName);
  copyDirectory(fixture.traceDir, objectDir);

  const manifestPath = path.join(rootDir, "manifest.json");
  const manifest = {
    schema: "codetracer.trace-storage.v1",
    source: {
      kind: "materialized_artifact",
      artifact: {
        uri: `objects/${fixture.objectName}`,
        uploadCompletionState: "complete",
        retentionStatus: "available",
        sizeBytes: fs.statSync(path.join(objectDir, fixture.traceFileName)).size,
      },
      replay_start: {
        trace_id: fixture.traceId,
        span_id: fixture.spanId,
        moment_id: fixture.momentId,
      },
    },
  };
  fs.writeFileSync(manifestPath, JSON.stringify(manifest, null, 2));

  return { rootDir, manifestPath };
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

async function readFilesystemSourceState(
  page: Page,
  sourceFileName: string,
): Promise<FilesystemSourceState> {
  return await page.evaluate((expectedFileName) => {
    const data = (window as any).data;
    const filesystem = data?.services?.editor?.filesystem;
    const paths: string[] = [];

    const visit = (node: any): void => {
      if (!node) return;
      const path = String(node?.original?.path ?? node?.path ?? "");
      if (path.length > 0) paths.push(path);
      for (const child of node?.children ?? []) visit(child);
    };
    visit(filesystem);

    const suffix = `/${expectedFileName}`;
    const matchedPath =
      paths.find((path) => path === expectedFileName || path.endsWith(suffix)) ??
      "";

    const anchorLabels = Array.from(document.querySelectorAll(".jstree-anchor"))
      .map((anchor) => String(anchor.textContent ?? "").trim())
      .filter((label) => label.length > 0)
      .slice(0, 80);
    const renderedSourceLabel =
      anchorLabels.find((label) => label === expectedFileName) ?? "";

    const trace = data?.sessions?.[data?.activeSessionIndex ?? 0]?.trace;
    return {
      matchedPath,
      filesystemPaths: paths.slice(0, 80),
      anchorLabels,
      renderedSourceLabel,
      traceProgram: String(trace?.program ?? ""),
      traceOutputFolder: String(trace?.outputFolder ?? ""),
    };
  }, sourceFileName);
}

async function waitForFilesystemSourcePath(
  page: Page,
  fixture: MaterializedFlowFixture,
  timeoutMs = browserDetailTimeoutMs,
): Promise<string> {
  const layout = new LayoutPage(page);
  await layout.waitForFilesystemLoaded();

  try {
    await retry(
      async () => {
        const state = await readFilesystemSourceState(page, fixture.sourceFileName);
        return (
          state.matchedPath.length > 0 ||
          state.renderedSourceLabel === fixture.sourceFileName
        );
      },
      {
        maxAttempts: Math.ceil(timeoutMs / 1_000),
        delayMs: 1_000,
      },
    );
    const state = await readFilesystemSourceState(page, fixture.sourceFileName);
    return state.matchedPath || state.renderedSourceLabel;
  } catch (error) {
    const state = await readFilesystemSourceState(page, fixture.sourceFileName);
    throw new Error(
      `Timed out waiting for ${fixture.label} source ${fixture.sourceFileName} in the filesystem UI.\n` +
        `Trace program: ${state.traceProgram}\n` +
        `Trace output folder: ${state.traceOutputFolder}\n` +
        `Filesystem paths:\n${state.filesystemPaths.join("\n")}\n` +
        `Rendered filesystem labels:\n${state.anchorLabels.join("\n")}`,
      { cause: error },
    );
  }
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

base.describe("Observability M29 local materialized manifest browser acceptance", () => {
  base.describe.configure({ mode: "serial", timeout: 180_000 });

  for (const fixture of [
    pythonFlowFixture,
    rubyFlowFixture,
    javascriptFlowFixture,
  ]) {
    base(`ct host --manifest loads a local ${fixture.label} materialized trace folder`, async ({}) => {
      expectRequiredPath("CodeTracer test binary", codetracerPath);
      expectRequiredPath(
        `${fixture.label} materialized trace fixture`,
        fixture.traceDir,
      );
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
      expectRequiredPath(`${fixture.label} flow source fixture`, fixture.sourcePath);

      const { rootDir, manifestPath } = prepareLocalMaterializedManifest(fixture);
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

        await connectToHost(page, httpPort, hostOutput);
        const sourceText = await verifyMaterializedTraceDetails(page, fixture);

        const traceMetadata = await page.evaluate(() => {
          const d = (window as any).data;
          const trace = d?.sessions?.[d?.activeSessionIndex ?? 0]?.trace;
          return {
            recordingId: String(trace?.recordingId ?? ""),
            program: String(trace?.program ?? ""),
            outputFolder: String(trace?.outputFolder ?? ""),
          };
        });
        console.log(
          `# active trace metadata: ${JSON.stringify(traceMetadata, null, 2)}`,
        );
        console.log(`# source model sample:\n${sourceText.slice(0, 2000)}`);

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
        // M-REC-7: the recording identity is a canonical UUIDv7
        // (`recording_id`) and the on-disk folder is the bare UUID — the
        // pre-1.0 numeric `id` and `trace-<n>` folder prefix were retired.
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
        await sleep(portReleaseDelayMs);
        if (browser) {
          await browser.close().catch(() => undefined);
        }
        fs.rmSync(rootDir, { recursive: true, force: true });
        // M-REC-6: env var renamed; delete legacy and new names.
        delete process.env.CODETRACER_TRACE_ID;
        delete process.env.CODETRACER_RECORDING_ID;
        delete process.env.CODETRACER_CALLER_PID;
        delete process.env.CODETRACER_IN_UI_TEST;
        delete process.env.CODETRACER_TEST;
      }
    });
  }
});
