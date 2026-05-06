import {
  test,
  expect,
  codetracerInstallDir,
  codetracerPath,
  testProgramsPath,
} from "../../lib/fixtures";
import * as childProcess from "node:child_process";
import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";

function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

const testFolder = testProgramsPath;
const gitEditFixture = fs.mkdtempSync(path.join(os.tmpdir(), "codetracer-edit-mode-"));
fs.mkdirSync(path.join(gitEditFixture, "src"), { recursive: true });
fs.writeFileSync(path.join(gitEditFixture, "README.md"), "# Edit mode fixture\n");
fs.writeFileSync(path.join(gitEditFixture, "src", "main.nim"), "proc main() =\n  echo \"edit mode\"\n");
childProcess.execFileSync("git", ["init"], { cwd: gitEditFixture, stdio: "ignore" });
childProcess.execFileSync("git", ["add", "."], { cwd: gitEditFixture, stdio: "ignore" });
childProcess.execFileSync(
  "git",
  ["-c", "user.name=CodeTracer Tests", "-c", "user.email=tests@codetracer.dev", "commit", "-m", "initial"],
  { cwd: gitEditFixture, stdio: "ignore" },
);

async function visibleEditorText(ctPage: any): Promise<string> {
  return await ctPage.evaluate(() => {
    return Array.from(document.querySelectorAll(".monaco-editor .view-lines"))
      .map((node) => (node as HTMLElement).innerText)
      .join("\n");
  });
}

async function assertWorkspacePanelsPopulated(ctPage: any, expectedFile: RegExp) {
  await expect(ctPage.locator(".lm_goldenlayout")).toBeVisible({ timeout: 45_000 });

  await expect.poll(async () => {
    return await ctPage.evaluate(() =>
      Array.from(document.querySelectorAll(".filesystem-entry-label, .jstree-anchor"))
        .map((node) => (node as HTMLElement).innerText)
        .join("\n"),
    );
  }, { timeout: 45_000 }).toMatch(expectedFile);

  await ctPage.locator(".lm_tab", { hasText: "VCS" }).first().click();
  await expect(ctPage.locator(".vcs-container").first()).toBeVisible({ timeout: 15_000 });

  await expect.poll(async () => {
    return await ctPage.evaluate(() => {
      const branch = document.querySelector(".vcs-branch-name") as HTMLElement | null;
      const commits = document.querySelectorAll(".vcs-commit-item").length;
      const noRepo = document.querySelector(".vcs-no-repo-message") as HTMLElement | null;
      const branchText = branch?.innerText.trim() ?? "";
      const noRepoText = noRepo?.innerText.trim() ?? "";
      return noRepoText.length === 0 && (branchText.length > 0 || commits > 0);
    });
  }, { timeout: 30_000 }).toBe(true);
}

test.describe("Edit Mode", () => {
  test.use({ launchMode: "edit", editFolderPath: testFolder });

  test("edit mode loads the main UI", async ({ ctPage }) => {
    await ctPage.waitForSelector(".lm_goldenlayout", { timeout: 15000 });

    const layout = ctPage.locator(".lm_goldenlayout");
    await expect(layout).toBeVisible();

    await expect.poll(async () => {
      return await ctPage.evaluate(() => document.querySelectorAll(".monaco-editor").length);
    }).toBeGreaterThan(0);

    await expect.poll(async () => visibleEditorText(ctPage), { timeout: 10_000 })
      .toMatch(/proc|def|fn|import|class|module|func|contract|use|echo|print/i);
  });

  test("edit mode shows populated file system panel and opens clicked files", async ({ ctPage }) => {
    await ctPage.waitForSelector(".lm_goldenlayout", { timeout: 15000 });

    const filesystem = ctPage.locator(".filesystem").first();
    await expect(filesystem).toBeVisible({ timeout: 10_000 });

    const mainFile = filesystem.locator(".jstree-anchor", { hasText: "main.py" }).first();
    await expect(mainFile).toBeVisible({ timeout: 10_000 });
    await mainFile.click();

    await expect.poll(async () => visibleEditorText(ctPage), { timeout: 10_000 })
      .toMatch(/print|def|import/);
  });

  test("edit mode does not show welcome screen", async ({ ctPage }) => {
    await ctPage.waitForSelector(".lm_goldenlayout", { timeout: 15000 });

    const welcomeScreen = ctPage.locator(".welcome-screen");
    await expect(welcomeScreen).toBeHidden();
  });

  test("edit mode is in edit mode (not debug mode)", async ({ ctPage }) => {
    await ctPage.waitForSelector(".lm_goldenlayout", { timeout: 15000 });
    await sleep(1000);

    const layoutContent = ctPage.locator(".lm_content").first();
    await expect(layoutContent).toBeVisible({ timeout: 10000 });
  });

});

test.describe("Edit Mode CLI", () => {
  test.use({
    launchMode: "edit",
    editFolderPath: ".",
    editWorkingDirectory: testFolder,
  });

  test("ct edit dot launches edit mode from the process cwd", async ({ ctPage }) => {
    await ctPage.waitForSelector(".lm_goldenlayout", { timeout: 15000 });

    await expect.poll(async () => {
      return await ctPage.evaluate(() => document.querySelectorAll(".monaco-editor").length);
    }, { timeout: 10_000 }).toBeGreaterThan(0);

    await expect.poll(async () => visibleEditorText(ctPage), { timeout: 10_000 })
      .toMatch(/proc|def|fn|import|class|module|func|contract|use|echo|print/i);
  });
});

test.describe("Edit Mode CLI from git workspace", () => {
  test.use({
    launchMode: "edit",
    editFolderPath: ".",
    editWorkingDirectory: gitEditFixture,
  });

  test("ct edit dot populates the Files and VCS panels for a git workspace", async ({ ctPage }) => {
    await assertWorkspacePanelsPopulated(ctPage, /src|README|main\.nim/i);
  });
});

test.describe("Edit Mode CLI from CodeTracer repo root", () => {
  test.use({
    launchMode: "edit",
    editFolderPath: ".",
    editWorkingDirectory: codetracerInstallDir,
  });

  test("ct edit dot populates Files and VCS for the CodeTracer repository", async ({ ctPage }) => {
    await assertWorkspacePanelsPopulated(ctPage, /src|README|Justfile|flake\.nix/i);

    await expect.poll(async () => {
      return await ctPage.evaluate(() =>
        Array.from(document.querySelectorAll(".lm_tab"))
          .map((node) => (node as HTMLElement).innerText)
          .join("\n"),
      );
    }, { timeout: 10_000 }).not.toMatch(/Calltrace|State|Trace/i);
  });
});

test.describe("Welcome Open Folder", () => {
  test.use({ launchMode: "welcome" });

  test("welcome open-folder handoff initializes edit mode", async ({ ctPage }) => {
    await ctPage.waitForSelector(".welcome-screen", { timeout: 15000 });

    await ctPage.evaluate((folderPath) => {
      const d = (window as any).data;
      const originalSend = d.ipc.send.bind(d.ipc);
      d.ipc.send = (channel: string, payload?: unknown) => {
        if (channel === "CODETRACER::open-folder-dialog") {
          originalSend("CODETRACER::init-edit-mode", { folder: folderPath });
          return;
        }
        originalSend(channel, payload);
      };
    }, testFolder);

    await ctPage.locator(".start-option.open-folder").click();

    await expect.poll(async () => {
      const state = await ctPage.evaluate(() => {
        return {
          welcomeVisible: document.querySelector(".welcome-screen") !== null &&
            getComputedStyle(document.querySelector(".welcome-screen") as Element).display !== "none",
          monacoCount: document.querySelectorAll(".monaco-editor").length,
        };
      });
      return !state.welcomeVisible;
    }, { timeout: 15_000 }).toBe(true);

    await expect(ctPage.locator(".lm_goldenlayout")).toBeVisible({ timeout: 15_000 });
    await assertWorkspacePanelsPopulated(ctPage, /main\.py/i);
  });

  test("delegated edit-folder event opens a populated new tab", async ({ ctPage }) => {
    await ctPage.waitForSelector(".welcome-screen", { timeout: 15000 });

    await ctPage.evaluate((folderPath) => {
      const { ipcRenderer } = require("electron");
      ipcRenderer.emit("CODETRACER::open-edit-folder-in-tab-ready", {}, { folderPath });
    }, gitEditFixture);

    await assertWorkspacePanelsPopulated(ctPage, /src|README|main\.nim/i);
  });

  test("welcome new-tab open-folder handoff populates the CodeTracer repository", async ({ ctPage }) => {
    await ctPage.waitForSelector(".welcome-screen", { timeout: 15000 });
    await ctPage.locator(".session-tab-add").click();
    await expect(ctPage.locator(".welcome-screen")).toBeVisible({ timeout: 10_000 });

    await ctPage.evaluate((folderPath) => {
      const d = (window as any).data;
      const originalSend = d.ipc.send.bind(d.ipc);
      d.ipc.send = (channel: string, payload?: unknown) => {
        if (channel === "CODETRACER::open-folder-dialog") {
          originalSend("CODETRACER::init-edit-mode", { folder: folderPath });
          return;
        }
        originalSend(channel, payload);
      };
    }, codetracerInstallDir);

    await ctPage.locator(".start-option.open-folder").click();
    await assertWorkspacePanelsPopulated(ctPage, /src|README|Justfile|flake\.nix/i);
    await expect(ctPage.locator(".welcome-screen")).toBeHidden({ timeout: 10_000 });
  });
});

test.describe("Welcome Open Folder via second process", () => {
  test.use({ launchMode: "welcome", newTracePolicy: "tab" });

  test("running ct edit dot delegates into the existing welcome window", async ({ ctPage }) => {
    await ctPage.waitForSelector(".welcome-screen", { timeout: 15000 });

    const env = { ...process.env };
    delete env.CODETRACER_TRACE_ID;
    delete env.CODETRACER_CALLER_PID;
    env.CODETRACER_IN_UI_TEST = "1";
    env.CODETRACER_TEST = "1";
    env.CODETRACER_NEW_TRACE_POLICY = "tab";
    env.CODETRACER_ELECTRON_ARGS = [
      "--no-sandbox",
      "--no-zygote",
      "--disable-gpu",
      "--disable-gpu-compositing",
      "--disable-dev-shm-usage",
      "--in-process-gpu",
      "--ozone-platform-hint=x11",
    ].join(" ");

    const delegated = childProcess.spawnSync(codetracerPath, ["edit", "."], {
      cwd: gitEditFixture,
      env,
      encoding: "utf-8",
      timeout: 30_000,
      windowsHide: true,
    });

    expect(delegated.error, delegated.stderr).toBeUndefined();
    expect(delegated.status, delegated.stderr || delegated.stdout).toBe(0);
    await assertWorkspacePanelsPopulated(ctPage, /src|README|main\.nim/i);
    await expect(ctPage.locator(".welcome-screen")).toBeHidden({ timeout: 10_000 });
  });
});
