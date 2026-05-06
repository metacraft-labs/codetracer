/**
 * Observability M29 acceptance: local materialized manifest hostability.
 *
 * Exercises the user-facing `ct host --manifest=<manifest.json>` path with a
 * real hostable Python materialized trace folder (`trace.bin` plus metadata).
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

const maxConnectAttempts = 25;
const retryDelayMs = 1_500;
const gotoTimeoutMs = 5_000;
const portReleaseDelayMs = 500;
const browserDetailTimeoutMs = 60_000;

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

function expectRequiredPath(label: string, filePath: string): void {
  expect(
    fs.existsSync(filePath),
    `${label} is required for M29 materialized manifest acceptance: ${filePath}`,
  ).toBe(true);
}

function prepareLocalMaterializedManifest(): {
  rootDir: string;
  manifestPath: string;
} {
  const rootDir = fs.mkdtempSync(
    path.join(os.tmpdir(), "ct-m29-materialized-manifest-"),
  );
  const objectDir = path.join(rootDir, "objects", "python-flow");
  copyDirectory(pythonFlowTraceFixture, objectDir);

  const manifestPath = path.join(rootDir, "manifest.json");
  const manifest = {
    schema: "codetracer.trace-storage.v1",
    source: {
      kind: "materialized_artifact",
      artifact: {
        uri: "objects/python-flow",
        uploadCompletionState: "complete",
        retentionStatus: "available",
        sizeBytes: fs.statSync(path.join(objectDir, "trace.bin")).size,
      },
      replay_start: {
        trace_id: "m29-python-materialized-flow",
        span_id: "30000000000029aa",
        moment_id: "m29-python-flow-calculate-sum",
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

base.describe("Observability M29 local materialized manifest browser acceptance", () => {
  base.describe.configure({ mode: "serial", timeout: 180_000 });

  base("ct host --manifest loads a local Python materialized trace folder", async ({}) => {
    expectRequiredPath("CodeTracer test binary", codetracerPath);
    expectRequiredPath("Python materialized trace fixture", pythonFlowTraceFixture);
    expectRequiredPath(
      "Python materialized trace.bin",
      path.join(pythonFlowTraceFixture, "trace.bin"),
    );
    expectRequiredPath(
      "Python materialized trace metadata",
      path.join(pythonFlowTraceFixture, "trace_metadata.json"),
    );
    expectRequiredPath("Python flow source fixture", pythonFlowSourceFixture);

    const { rootDir, manifestPath } = prepareLocalMaterializedManifest();
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
      await expect(page.locator(".lm_content").first()).toBeVisible({
        timeout: 30_000,
      });

      const sourceNode = page
        .locator(".jstree-anchor")
        .filter({ hasText: /^python_flow_test\.py$/ })
        .first();
      await expect(sourceNode).toBeVisible({ timeout: 30_000 });
      await sourceNode.click();
      const sourceText = await waitForEditorModelText(page, "calculate_sum");
      await waitForEditorModelText(page, "sum_with_while");
      const layout = new LayoutPage(page);
      await layout.waitForCallTraceReady();
      const callTrace = (await layout.callTraceTabs())[0];
      await callTrace.clickTab();
      const calculateSumEntry = await callTrace.navigateToEntry("calculate_sum");
      expect((await calculateSumEntry.functionName()).toLowerCase()).toBe(
        "calculate_sum",
      );
      await helpers.assertEventLogPopulated(page);
      await helpers.assertTerminalOutputContains(page, "Result: 94");

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
      console.log(`# source model sample:\n${sourceText.slice(0, 2000)}`);

      expect(sourceText).toContain("calculate_sum");
      expect(sourceText).toContain("sum_with_while");
      expect(traceMetadata.id).toBeGreaterThan(0);
      expect(traceMetadata.program).toContain("python_flow_test.py");
      expect(traceMetadata.outputFolder).toContain("trace-");
    } finally {
      if (ctProcess?.pid) {
        killProcessTree(ctProcess.pid);
      }
      await sleep(portReleaseDelayMs);
      if (browser) {
        await browser.close().catch(() => undefined);
      }
      fs.rmSync(rootDir, { recursive: true, force: true });
      delete process.env.CODETRACER_TRACE_ID;
      delete process.env.CODETRACER_CALLER_PID;
      delete process.env.CODETRACER_IN_UI_TEST;
      delete process.env.CODETRACER_TEST;
    }
  });
});
