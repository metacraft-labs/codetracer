import { expect, test } from "../../lib/fixtures";
import type { Page } from "@playwright/test";
import * as childProcess from "node:child_process";
import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";

import {
  AgentWorkspacePage,
  CaptionBarProgressPage,
} from "./page-objects/agentic-page";
import { DeepReviewPage } from "../deepreview/page-objects/deepreview-page";
import { AgenticWorktreeArtifacts } from "./agentic-worktree-artifacts";

type AgenticWorktreeSnapshot = {
  startedFromCodeTracer: boolean;
  productLauncher: "CodeTracerAgenticSessionLauncher";
  productLauncherCommand: string;
  backend: "harbor";
  workingCopyMode: "git_worktree";
  tabCaption: string;
  lifecycle: string;
  workspaceMode: "user" | "agent";
  activity: string[];
  userWorkspacePath: string;
  agentWorkspacePath: string;
  changedFiles: Array<{
    path: string;
    status: string;
    additions: number;
    deletions: number;
  }>;
  activeEditorPath: string;
  activeEditorContent: string;
  taskId: string;
  sessionId: string;
  agentHarborBaseUrl: string;
  scenarioEvidenceCommandConfigured?: boolean;
  scenarioEvidenceCommandObserved?: boolean;
  scenarioEvidenceCommandSource?: "agent-harbor-history";
  scenarioEvidenceCommands?: string[];
  deepReview: {
    active: boolean;
    traceContextLabels: string[];
    viewMode: "unified" | "fullFiles";
    fullFilesAvailable: boolean;
    modifiedFiles: string[];
  };
  cancellation?: {
    requested: boolean;
    recovered: boolean;
    message: string;
    cancelledTaskId: string;
    recoveredTaskId: string;
    cancelledLifecycle: string;
    cancelledWorkspaceMode: "user" | "agent";
    cancelledSnapshot: AgenticWorktreeSnapshot;
  };
};

type AgenticWorktreeLaunchInput = {
  userWorkspacePath: string;
  prompt: string;
  artifactDir: string;
  bridgeExecutable: string;
  repoRoot: string;
  agentHarborBaseUrl: string;
  agentHarborApiKey?: string;
  acpBinary?: string;
  acpArgs?: string[];
};

type AgenticWorktreeLaunchRequest = Omit<
  AgenticWorktreeLaunchInput,
  "bridgeExecutable" | "repoRoot"
>;

declare global {
  interface Window {
    __CODETRACER_TEST__?: {
      agenticWorktree?: AgenticWorktreeBridge;
    };
  }
}

type AgenticWorktreeBridge = {
  productLauncher?: string;
  startWorktreeAgentSession(
    input: AgenticWorktreeLaunchRequest,
  ): Promise<AgenticWorktreeSnapshot>;
  openAgentTab(): Promise<AgenticWorktreeSnapshot>;
  switchToUserWorkspace(): Promise<AgenticWorktreeSnapshot>;
  waitForEvidenceDeepReview(): Promise<AgenticWorktreeSnapshot>;
  cancelAndRecover(
    input: AgenticWorktreeLaunchRequest,
  ): Promise<AgenticWorktreeSnapshot>;
};

const changedFile = "src/feature.nim";
const changedContent = "proc featureValue*(): int =\n  42\n";
const repoRoot = path.resolve(process.cwd(), "..", "..", "..");
const helperSource = path.join(
  repoRoot,
  "src",
  "tests",
  "gui",
  "tests",
  "agentic-coding",
  "agentic_worktree_m7_bridge.nim",
);
const agentHarborBaseUrl = process.env.AGENT_HARBOR_M7_BASE_URL ?? "";
const agentHarborApiKey = process.env.AGENT_HARBOR_M7_API_KEY;
const agentHarborScenario = process.env.AGENT_HARBOR_M7_SCENARIO;
const mockAgentBinary = process.env.AGENT_HARBOR_M7_MOCK_AGENT_BINARY;

function requireAgentHarborBaseUrl(): string {
  if (!agentHarborBaseUrl) {
    throw new Error(
      "AGENT_HARBOR_M7_BASE_URL must point at a real Agent Harbor REST " +
        "server prepared with the CodeTracer worktree scenario. M7 must not " +
        "fall back to fake Harbor transports or fixture-only IPC.",
    );
  }
  return agentHarborBaseUrl;
}

function run(command: string, args: string[], cwd: string): string {
  const result = childProcess.spawnSync(command, args, {
    cwd,
    encoding: "utf-8",
    stdio: "pipe",
    timeout: 30_000,
  });
  if (result.status !== 0) {
    throw new Error(
      `${command} ${args.join(" ")} failed in ${cwd}\nstdout:\n${result.stdout}\nstderr:\n${result.stderr}`,
    );
  }
  return result.stdout;
}

function compileBridge(artifactDir: string): string {
  const output = path.join(artifactDir, "agentic_worktree_m7_bridge");
  const result = childProcess.spawnSync(
    "nim",
    [
      "c",
      "--hints:off",
      "--warnings:off",
      `--path:${path.join(repoRoot, "src", "frontend", "viewmodel")}`,
      `-o:${output}`,
      helperSource,
    ],
    {
      cwd: repoRoot,
      encoding: "utf-8",
      stdio: "pipe",
      timeout: 120_000,
    },
  );
  if (result.status !== 0) {
    throw new Error(
      `failed to compile ${helperSource}\nstdout:\n${result.stdout}\nstderr:\n${result.stderr}`,
    );
  }
  return output;
}

function createGitWorkspace(): string {
  const root = fs.mkdtempSync(
    path.join(os.tmpdir(), "ct-agentic-worktree-gui-"),
  );
  fs.mkdirSync(path.join(root, "src"), { recursive: true });
  fs.writeFileSync(
    path.join(root, "src", "feature.nim"),
    "proc featureValue*(): int =\n  1\n",
    "utf-8",
  );
  fs.writeFileSync(
    path.join(root, "feature_test.nim"),
    "import src/feature\n\ndoAssert featureValue() == 1\n",
    "utf-8",
  );
  run("git", ["init", "."], root);
  run("git", ["config", "user.email", "codetracer-gui@example.invalid"], root);
  run("git", ["config", "user.name", "CodeTracer GUI E2E"], root);
  run("git", ["add", "."], root);
  run("git", ["commit", "-m", "Initial fixture"], root);
  return root;
}

async function requireFrontendBridge(page: Page): Promise<void> {
  await page.waitForFunction(
    () => Boolean(window.__CODETRACER_TEST__?.agenticWorktree),
    undefined,
    { timeout: 60_000 },
  );
  await page.evaluate(() => {
    const bridge = window.__CODETRACER_TEST__?.agenticWorktree;
    if (!bridge) {
      throw new Error(
        "M7 product bridge is unavailable. The GUI must expose " +
          "window.__CODETRACER_TEST__.agenticWorktree from CodeTracer frontend " +
          "code and render state through product panels.",
      );
    }
  });
}

async function agenticBridge(
  page: Page,
  bridgeExecutable: string,
): Promise<AgenticWorktreeBridge> {
  await requireFrontendBridge(page);
  let lastInput: AgenticWorktreeLaunchInput | undefined;
  const drive = async (
    method: keyof AgenticWorktreeBridge,
    input?: AgenticWorktreeLaunchInput,
  ): Promise<AgenticWorktreeSnapshot> => {
    const payload = input ?? lastInput;
    if (!payload) {
      throw new Error(
        `M7 product bridge method ${method} was called before session start`,
      );
    }
    return page.evaluate(
      ({ methodName, payload }) => {
        const bridge = window.__CODETRACER_TEST__?.agenticWorktree;
        if (!bridge) {
          throw new Error("M7 product bridge disappeared");
        }
        const fn = bridge[methodName];
        if (typeof fn !== "function") {
          throw new Error(`M7 product bridge method ${methodName} is missing`);
        }
        const describeFailure = (error: unknown): string => {
          if (error instanceof Error) {
            return `${error.name}: ${error.message}\n${error.stack ?? ""}`;
          }
          if (error && typeof error === "object") {
            const parts: string[] = [];
            for (const key of Object.getOwnPropertyNames(error)) {
              try {
                parts.push(`${key}=${JSON.stringify((error as Record<string, unknown>)[key])}`);
              } catch {
                parts.push(`${key}=${String((error as Record<string, unknown>)[key])}`);
              }
            }
            const prototype = Object.getPrototypeOf(error);
            if (prototype) {
              parts.push(`prototype=${prototype.constructor?.name ?? "Object"}`);
              for (const key of Object.getOwnPropertyNames(prototype)) {
                if (key === "constructor") {
                  continue;
                }
                try {
                  parts.push(
                    `prototype.${key}=${JSON.stringify(
                      (error as Record<string, unknown>)[key],
                    )}`,
                  );
                } catch {
                  parts.push(
                    `prototype.${key}=${String(
                      (error as Record<string, unknown>)[key],
                    )}`,
                  );
                }
              }
            }
            return parts.length > 0 ? parts.join("; ") : String(error);
          }
          try {
            return JSON.stringify(error);
          } catch {
            return String(error);
          }
        };
        return (async () => {
          try {
            return await (
              fn as (value: unknown) => Promise<AgenticWorktreeSnapshot>
            )(payload);
          } catch (error) {
            throw new Error(
              `M7 product bridge method ${methodName} failed: ` +
                describeFailure(error),
            );
          }
        })();
      },
      { methodName: method, payload },
    );
  };
  return {
    startWorktreeAgentSession: (input) => {
      lastInput = {
        ...input,
        bridgeExecutable,
        repoRoot,
        agentHarborBaseUrl: requireAgentHarborBaseUrl(),
        agentHarborApiKey,
        acpBinary: mockAgentBinary,
        acpArgs: agentHarborScenario ? ["--scenario", agentHarborScenario] : undefined,
      };
      return drive("startWorktreeAgentSession", lastInput);
    },
    openAgentTab: () => drive("openAgentTab", lastInput),
    switchToUserWorkspace: () => drive("switchToUserWorkspace", lastInput),
    waitForEvidenceDeepReview: () =>
      drive("waitForEvidenceDeepReview", lastInput),
    cancelAndRecover: (input) => {
      lastInput = {
        ...input,
        bridgeExecutable,
        repoRoot,
        agentHarborBaseUrl: requireAgentHarborBaseUrl(),
        agentHarborApiKey,
        acpBinary: mockAgentBinary,
        acpArgs: agentHarborScenario ? ["--scenario", agentHarborScenario] : undefined,
      };
      return drive("cancelAndRecover", lastInput);
    },
  };
}

function assertWorktreeStart(snapshot: AgenticWorktreeSnapshot): void {
  expect(snapshot.startedFromCodeTracer).toBe(true);
  expect(snapshot.productLauncher).toBe("CodeTracerAgenticSessionLauncher");
  expect(snapshot.productLauncherCommand).toContain("codetracer.agent.");
  expect(snapshot.backend).toBe("harbor");
  expect(snapshot.workingCopyMode).toBe("git_worktree");
  expect(snapshot.tabCaption).toContain("Agent");
  expect(snapshot.tabCaption).toMatch(/\d+\/\d+/);
  expect(snapshot.lifecycle).toMatch(/running|completed/i);
  expect(snapshot.activity.join("\n")).toContain("ct agent evidence");
}

function assertAgentWorkspace(snapshot: AgenticWorktreeSnapshot): void {
  expect(snapshot.workspaceMode).toBe("agent");
  expect(snapshot.agentWorkspacePath).toBeTruthy();
  expect(snapshot.agentWorkspacePath).not.toBe(snapshot.userWorkspacePath);
  expect(snapshot.changedFiles.map((file) => file.path)).toContain(changedFile);
  const feature = snapshot.changedFiles.find(
    (file) => file.path === changedFile,
  );
  expect(feature?.status).toMatch(/M|modified/);
  expect(feature?.additions).toBeGreaterThanOrEqual(1);
  expect(snapshot.changedFiles.map((file) => file.path)).toContain(
    snapshot.activeEditorPath,
  );
  expect(snapshot.activeEditorContent).toContain("42");
}

function assertSameAgentSession(
  first: AgenticWorktreeSnapshot,
  later: AgenticWorktreeSnapshot,
): void {
  expect(later.taskId).toBe(first.taskId);
  expect(later.sessionId).toBe(first.sessionId);
  if (first.agentWorkspacePath && later.agentWorkspacePath) {
    expect(later.agentWorkspacePath).toBe(first.agentWorkspacePath);
  }
  expect(later.agentHarborBaseUrl).toBe(first.agentHarborBaseUrl);
}

function assertDeepReview(snapshot: AgenticWorktreeSnapshot): void {
  expect(snapshot.deepReview.active).toBe(true);
  expect(snapshot.scenarioEvidenceCommandConfigured).toBe(true);
  expect(snapshot.scenarioEvidenceCommandObserved).toBe(true);
  expect(snapshot.scenarioEvidenceCommandSource).toBe("agent-harbor-history");
  expect((snapshot.scenarioEvidenceCommands ?? []).join("\n")).toContain(
    "ct agent evidence",
  );
  expect(snapshot.deepReview.modifiedFiles).toContain(changedFile);
  expect(snapshot.deepReview.traceContextLabels.length).toBeGreaterThanOrEqual(
    1,
  );
  expect(snapshot.deepReview.viewMode).toBe("unified");
  expect(snapshot.deepReview.fullFilesAvailable).toBe(true);
}

async function waitForAgentWorkspace(
  bridge: AgenticWorktreeBridge,
): Promise<AgenticWorktreeSnapshot> {
  let snapshot = await bridge.openAgentTab();
  for (let attempt = 0; attempt < 40; attempt += 1) {
    const changedPaths = snapshot.changedFiles.map((file) => file.path);
    if (
      snapshot.workspaceMode === "agent" &&
      snapshot.agentWorkspacePath &&
      snapshot.agentWorkspacePath !== snapshot.userWorkspacePath &&
      changedPaths.includes(changedFile) &&
      snapshot.activeEditorContent.includes("42")
    ) {
      return snapshot;
    }
    await new Promise((resolve) => setTimeout(resolve, 250));
    snapshot = await bridge.openAgentTab();
  }
  return snapshot;
}

test.describe("Agentic worktree GUI E2E", () => {
  const editLaunchWorkspace = createGitWorkspace();

  test.use({
    launchMode: "edit",
    editFolderPath: ".",
    editWorkingDirectory: editLaunchWorkspace,
  });

  test("e2e_agentic_worktree_session_progress_workspace_and_deepreview", async ({
    ctPage,
  }, testInfo) => {
    const artifacts = new AgenticWorktreeArtifacts(testInfo);
    artifacts.collectConsole(ctPage);
    const workspace = createGitWorkspace();
    const bridgeExecutable = compileBridge(artifacts.dir);
    const bridge = await agenticBridge(ctPage, bridgeExecutable);
    const caption = new CaptionBarProgressPage(ctPage);
    const workspacePage = new AgentWorkspacePage(ctPage);
    const deepReview = new DeepReviewPage(ctPage);

    const startSnapshot = await bridge.startWorktreeAgentSession({
      userWorkspacePath: workspace,
      artifactDir: artifacts.dir,
      agentHarborBaseUrl: requireAgentHarborBaseUrl(),
      agentHarborApiKey,
      prompt:
        "Change src/feature.nim so featureValue returns 42, update the test, " +
        "run the test, then run the session ct agent evidence command.",
    });
    artifacts.writeJson("start-snapshot", startSnapshot);
    assertWorktreeStart(startSnapshot);
    await expect(caption.container()).toBeVisible();
    await expect(caption.milestoneCount()).toContainText(/\d+\/\d+/);
    await artifacts.screenshot(ctPage, "01-progress", testInfo);

    const agentSnapshot = await waitForAgentWorkspace(bridge);
    artifacts.writeJson("agent-workspace-snapshot", agentSnapshot);
    assertSameAgentSession(startSnapshot, agentSnapshot);
    assertAgentWorkspace(agentSnapshot);
    await workspacePage.waitForReady();
    await expect(workspacePage.headerLabel()).toContainText("Agent Workspace");
    await expect(
      ctPage.locator(".agent-workspace-file-item", { hasText: "feature.nim" }),
    ).toBeVisible();
    await artifacts.screenshot(ctPage, "02-agent-workspace", testInfo);

    const userSnapshot = await bridge.switchToUserWorkspace();
    artifacts.writeJson("user-workspace-snapshot", userSnapshot);
    assertSameAgentSession(startSnapshot, userSnapshot);
    expect(userSnapshot.workspaceMode).toBe("user");
    expect(userSnapshot.activeEditorContent).not.toBe(changedContent);

    const deepReviewSnapshot = await bridge.waitForEvidenceDeepReview();
    artifacts.writeJson("deepreview-snapshot", deepReviewSnapshot);
    assertSameAgentSession(startSnapshot, deepReviewSnapshot);
    assertDeepReview(deepReviewSnapshot);
    await expect(deepReview.traceContextSelector()).toBeVisible();
    await expect(ctPage.locator(".deepreview-unified-diff")).toBeVisible();
    await expect(
      ctPage.locator(".agent-workspace-file-item", { hasText: "feature.nim" }),
    ).toBeVisible();
    await artifacts.screenshot(ctPage, "03-deepreview", testInfo);
    await artifacts.flush(testInfo);
  });

  test("e2e_agentic_worktree_session_cancel_and_recover", async ({
    ctPage,
  }, testInfo) => {
    const artifacts = new AgenticWorktreeArtifacts(testInfo);
    artifacts.collectConsole(ctPage);
    const workspace = createGitWorkspace();
    const bridgeExecutable = compileBridge(artifacts.dir);
    const bridge = await agenticBridge(ctPage, bridgeExecutable);

    const snapshot = await bridge.cancelAndRecover({
      userWorkspacePath: workspace,
      artifactDir: artifacts.dir,
      agentHarborBaseUrl: requireAgentHarborBaseUrl(),
      agentHarborApiKey,
      prompt:
        "Start changing src/feature.nim, wait for cancellation, then prove " +
        "CodeTracer can start a fresh worktree-isolated agent session.",
    });
    artifacts.writeJson("cancel-recover-snapshot", snapshot);

    expect(snapshot.cancellation?.requested).toBe(true);
    expect(snapshot.cancellation?.message).toMatch(/cancel/i);
    expect(snapshot.cancellation?.cancelledLifecycle).toBe("cancelled");
    expect(snapshot.cancellation?.cancelledWorkspaceMode).toBe("agent");
    expect(snapshot.cancellation?.cancelledSnapshot.lifecycle).toBe(
      "cancelled",
    );
    expect(snapshot.cancellation?.cancelledSnapshot.workspaceMode).toBe(
      "agent",
    );
    expect(snapshot.lifecycle).toMatch(/running|completed/i);
    expect(snapshot.cancellation?.recovered).toBe(true);
    expect(snapshot.cancellation?.recoveredTaskId).toBe(snapshot.taskId);
    expect(snapshot.cancellation?.cancelledTaskId).not.toBe(snapshot.taskId);
    assertWorktreeStart(snapshot);
    await expect(ctPage.locator(".agent-com")).toContainText(
      /cancel|recovered/i,
    );
    await artifacts.screenshot(ctPage, "cancel-recover", testInfo);
    await artifacts.flush(testInfo);
  });
});
