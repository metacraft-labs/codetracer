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
import {
  DEBUG_TOOLBAR_IDS,
  EDIT_TOOLBAR_IDS,
  editToolbarSelector,
  topbarSurfaceSelector,
} from "../../page-objects/debug-toolbar-ids";

function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

const testFolder = testProgramsPath;
const gitEditFixture = fs.mkdtempSync(path.join(os.tmpdir(), "codetracer-edit-mode-"));
fs.mkdirSync(path.join(gitEditFixture, "src"), { recursive: true });
fs.writeFileSync(path.join(gitEditFixture, "README.md"), "# Edit mode fixture\n");
fs.writeFileSync(path.join(gitEditFixture, "src", "main.nim"), "proc main() =\n  echo \"edit mode\"\n");
// `src/db` sits at depth 2, which is exactly the depth at which the
// index process stops recursing for a plain folder open
// (`editFilesystemDepthLimit(selfContained = false) == 2`).  It is
// therefore delivered as a single "Loading..." stub child, and only a
// successful `CODETRACER::load-path-content` round-trip can replace it.
// Without a folder at this depth the tree never exercises the lazy
// fill at all — which is why #574 survived the earlier edit-mode specs.
fs.mkdirSync(path.join(gitEditFixture, "src", "db"), { recursive: true });
fs.writeFileSync(
  path.join(gitEditFixture, "src", "db", "store.nim"),
  "proc store() =\n  echo \"lazy child\"\n",
);
childProcess.execFileSync("git", ["init"], { cwd: gitEditFixture, stdio: "ignore" });
childProcess.execFileSync("git", ["add", "."], { cwd: gitEditFixture, stdio: "ignore" });
childProcess.execFileSync(
  "git",
  // commit.gpgsign=false: a runner configured to sign, with no secret key
  // present, would abort this fixture commit. Edit mode is not about signing.
  [
    "-c",
    "user.name=CodeTracer Tests",
    "-c",
    "user.email=tests@codetracer.dev",
    "-c",
    "commit.gpgsign=false",
    "commit",
    "-m",
    "initial",
  ],
  { cwd: gitEditFixture, stdio: "ignore" },
);

// A folder `projectKinds` recognises as exactly ONE project kind: `Nargo.toml`
// at the root is Noir, whose Build (`nargo compile`) and Run proposals are both
// canonical. An unrecognised folder hides the command group (§8's recognition
// split), so without a marker the edit bar would carry no buttons and "Build
// and Run are refused with a reason" could not be asserted at all.
const noirEditFixture = fs.mkdtempSync(path.join(os.tmpdir(), "codetracer-edit-toolbar-"));
fs.mkdirSync(path.join(noirEditFixture, "src"), { recursive: true });
fs.writeFileSync(
  path.join(noirEditFixture, "Nargo.toml"),
  '[package]\nname = "edit_toolbar"\ntype = "bin"\nauthors = [""]\n\n[dependencies]\n',
);
fs.writeFileSync(
  path.join(noirEditFixture, "src", "main.nr"),
  "fn main(x: Field) {\n    assert(x != 0);\n}\n",
);

/** `LayoutMode` ordinals, as `data.ui.mode` carries them. */
const DEBUG_MODE = 0;
const EDIT_MODE = 1;

async function layoutMode(ctPage: any): Promise<number> {
  return await ctPage.evaluate(() => Number((window as any).data?.ui?.mode));
}

async function activeSessionIndex(ctPage: any): Promise<number> {
  return await ctPage.evaluate(() => Number((window as any).data?.activeSessionIndex));
}

/**
 * Flip the session's mode with the product's own chord (`Ctrl+F5`,
 * `session.toggle-product-mode`) and wait until `data.ui.mode` says it
 * happened, so a toolbar assertion that follows cannot run against the mode
 * the session is leaving.
 */
async function toggleProductMode(ctPage: any, expected: number) {
  await ctPage.keyboard.press("Control+F5");
  await expect.poll(async () => layoutMode(ctPage), {
    timeout: 30_000,
    message: `Ctrl+F5 did not switch data.ui.mode to ${expected}`,
  }).toBe(expected);
}

/**
 * The topbar in EDIT mode (#812): the edit-commands surface, and NOT ONE of
 * the debugger's stepping controls. `Edit-Mode-Toolbar.md` §7.3 / EMT-A1:
 * `tbaDebuggerControls` is absent in `EditMode`.
 *
 * With `withCommands`, also the two command buttons, each DISABLED and saying
 * why: the desktop has no route that builds or runs from the toolbar yet, and
 * §8 / EMT-D14 forbid an enabled button that does nothing as much as a
 * disabled one with no reason.
 */
async function expectEditModeTopbar(ctPage: any, withCommands: boolean) {
  await expect(
    ctPage.locator(`#isonim-debug-controls ${topbarSurfaceSelector("editCommands")}`),
    "Edit mode's topbar is not the edit-commands surface",
  ).toHaveCount(1, { timeout: 30_000 });
  await expect(ctPage.locator(topbarSurfaceSelector("debuggerControls"))).toHaveCount(0);
  for (const [name, id] of Object.entries(DEBUG_TOOLBAR_IDS)) {
    await expect(
      ctPage.locator(`#${id}`),
      `the debugger's '${name}' control (#${id}) is on screen in Edit mode`,
    ).toHaveCount(0);
  }
  if (!withCommands) return;
  for (const button of ["build", "run"] as const) {
    const locator = ctPage.locator(editToolbarSelector(button));
    await expect(locator, `#${EDIT_TOOLBAR_IDS[button]} is missing`).toBeVisible();
    await expect(locator, `#${EDIT_TOOLBAR_IDS[button]} is enabled`).toBeDisabled();
    const reason = ((await locator.getAttribute("title")) ?? "").trim();
    expect(
      reason.length,
      `#${EDIT_TOOLBAR_IDS[button]} is disabled with no reason (EMT-A28)`,
    ).toBeGreaterThan(0);
  }
}

/** The topbar in DEBUG mode: the stepping controls, and no command buttons. */
async function expectDebugModeTopbar(ctPage: any) {
  await expect(
    ctPage.locator(`#isonim-debug-controls ${topbarSurfaceSelector("debuggerControls")}`),
    "Debug mode's topbar is not the debugger-controls surface",
  ).toHaveCount(1, { timeout: 30_000 });
  await expect(ctPage.locator(`#${DEBUG_TOOLBAR_IDS.next}`)).toHaveCount(1);
  await expect(ctPage.locator(topbarSurfaceSelector("editCommands"))).toHaveCount(0);
  await expect(ctPage.locator(`#${EDIT_TOOLBAR_IDS.build}`)).toHaveCount(0);
  await expect(ctPage.locator(`#${EDIT_TOOLBAR_IDS.run}`)).toHaveCount(0);
}

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

    // #812: and the TOPBAR says so. `test-programs/` is not one project, so
    // the command group may be hidden here; the stepping controls must be
    // gone regardless.
    expect(await layoutMode(ctPage)).toBe(EDIT_MODE);
    await expectEditModeTopbar(ctPage, false);
  });

});

test.describe("Edit Mode toolbar on the desktop (#812)", () => {
  test.use({ launchMode: "edit", editFolderPath: noirEditFixture, deploymentMode: "electron" });

  test("edit mode shows the edit toolbar with Build and Run refused, and no stepping controls", async ({
    ctPage,
  }) => {
    await ctPage.waitForSelector(".lm_goldenlayout", { timeout: 60_000 });
    expect(await layoutMode(ctPage)).toBe(EDIT_MODE);
    await expectEditModeTopbar(ctPage, true);
  });

  test("the topbar follows an Edit -> Debug -> Edit round trip", async ({ ctPage }) => {
    await ctPage.waitForSelector(".lm_goldenlayout", { timeout: 60_000 });
    expect(await layoutMode(ctPage)).toBe(EDIT_MODE);
    await expectEditModeTopbar(ctPage, true);

    await toggleProductMode(ctPage, DEBUG_MODE);
    await expectDebugModeTopbar(ctPage);

    // The SECOND entry is the one `Mode-Transitions.md` §3 warns nobody
    // exercises: the bar must be re-derived for it, not left from the first.
    await toggleProductMode(ctPage, EDIT_MODE);
    await expectEditModeTopbar(ctPage, true);

    await toggleProductMode(ctPage, DEBUG_MODE);
    await expectDebugModeTopbar(ctPage);
    await toggleProductMode(ctPage, EDIT_MODE);
    await expectEditModeTopbar(ctPage, true);
  });
});

test.describe("Edit Mode toolbar from a replay session (#812)", () => {
  test.use({ launchMode: "trace", sourcePath: "py_console_logs/main.py", deploymentMode: "electron" });

  test("a trace session's Debug -> Edit -> Debug -> Edit round trip shows the right bar each time", async ({
    ctPage,
  }) => {
    test.setTimeout(240_000);
    // A replay session starts in Debug mode; the toolbar is what is under
    // test, so readiness is the session's mode, not any one pane.
    await expect.poll(async () => layoutMode(ctPage), { timeout: 120_000 }).toBe(DEBUG_MODE);
    await expectDebugModeTopbar(ctPage);

    // A recording's source folder need not be a recognised project, so only
    // the surface and the absence of the stepping controls are asserted here.
    await toggleProductMode(ctPage, EDIT_MODE);
    await expectEditModeTopbar(ctPage, false);

    await toggleProductMode(ctPage, DEBUG_MODE);
    await expectDebugModeTopbar(ctPage);

    await toggleProductMode(ctPage, EDIT_MODE);
    await expectEditModeTopbar(ctPage, false);
  });
});

test.describe("Edit Mode toolbar across session tabs (#812)", () => {
  test.use({ launchMode: "trace", sourcePath: "py_console_logs/main.py", deploymentMode: "electron" });

  test("switching between a replay tab and an edit tab shows each tab's own bar", async ({ ctPage }) => {
    test.setTimeout(240_000);
    // Tab 0 is a replay session, in Debug mode.
    await expect.poll(async () => layoutMode(ctPage), { timeout: 120_000 }).toBe(DEBUG_MODE);
    await expectDebugModeTopbar(ctPage);

    // Tab 1 is an edit session over the Noir fixture, opened from the new
    // tab's welcome screen. The folder dialog is answered by sending the
    // message the dialog's handler sends, as the new-tab handoff test does.
    await ctPage.locator(".session-tab-add").click();
    await expect(ctPage.locator(".welcome-screen")).toBeVisible({ timeout: 10_000 });
    await ctPage.evaluate((folderPath: string) => {
      const d = (window as any).data;
      const originalSend = d.ipc.send.bind(d.ipc);
      d.ipc.send = (channel: string, payload?: unknown) => {
        if (channel === "CODETRACER::open-folder-dialog") {
          originalSend("CODETRACER::init-edit-mode", { folder: folderPath });
          return;
        }
        originalSend(channel, payload);
      };
    }, noirEditFixture);
    await ctPage.locator(".start-option.open-folder").click();
    await expect(ctPage.locator(".welcome-screen")).toBeHidden({ timeout: 45_000 });
    await expect.poll(async () => activeSessionIndex(ctPage), { timeout: 30_000 }).toBe(1);
    await expect.poll(async () => layoutMode(ctPage), { timeout: 30_000 }).toBe(EDIT_MODE);
    await expectEditModeTopbar(ctPage, true);

    // Back to the replay tab: its session is in Debug mode, so the bar must
    // be the stepping controls again, not the edit tab's bar left behind.
    await ctPage.locator(".session-tab").nth(0).click();
    await expect.poll(async () => activeSessionIndex(ctPage), { timeout: 30_000 }).toBe(0);
    expect(await layoutMode(ctPage)).toBe(DEBUG_MODE);
    await expectDebugModeTopbar(ctPage);

    // And to the edit tab once more: the edit bar, composed for that tab.
    await ctPage.locator(".session-tab").nth(1).click();
    await expect.poll(async () => activeSessionIndex(ctPage), { timeout: 30_000 }).toBe(1);
    expect(await layoutMode(ctPage)).toBe(EDIT_MODE);
    await expectEditModeTopbar(ctPage, true);
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

test.describe("Welcome Open Folder through main-process dialog handler", () => {
  test.use({
    launchMode: "welcome",
    testOpenFolderDialogPath: gitEditFixture,
  });

  test("open-folder-dialog initializes edit mode with populated workspace panels", async ({ ctPage }) => {
    await ctPage.waitForSelector(".welcome-screen", { timeout: 15000 });

    await ctPage.locator(".start-option.open-folder").click();

    await assertWorkspacePanelsPopulated(ctPage, /src|README|main\.nim/i);
    await expect(ctPage.locator(".welcome-screen")).toBeHidden({ timeout: 10_000 });
  });

  // Regression cover for #574 — "the file tree stays on Loading... after
  // Open Folder".
  //
  // A plain folder open loads the tree only two levels deep; anything
  // deeper arrives as a `Loading...` stub that is filled in on demand by
  // `CODETRACER::load-path-content`.  The main-process handler for that
  // message used to build its payload root from `data.trace.outputFolder`
  // unconditionally — and in folder mode there IS no trace, so the
  // handler threw before it could answer.  Nothing retries, so the stub
  // was permanent.
  //
  // The assertions are therefore: the stub is REPLACED (not merely
  // present), the real child appears, and the main process logged no
  // null dereference / unhandled rejection while doing it.
  test("expanding a depth-limited folder replaces the Loading stub with real children", async ({
    ctPage,
    electronApp,
  }) => {
    // Capture main-process stderr ourselves.  The launcher already
    // attaches its own diagnostic listener; Node streams fan out to every
    // listener, so a second one is additive and does not steal data.
    const mainProcessOutput: string[] = [];
    const mainProcess = electronApp?.process();
    for (const stream of [mainProcess?.stderr, mainProcess?.stdout]) {
      stream?.on("data", (chunk: Buffer) => {
        for (const line of chunk.toString().split("\n")) {
          if (line.trim().length > 0) mainProcessOutput.push(line);
        }
      });
    }

    await ctPage.waitForSelector(".welcome-screen", { timeout: 15000 });
    await ctPage.locator(".start-option.open-folder").click();
    await assertWorkspacePanelsPopulated(ctPage, /src|README|main\.nim/i);

    const label = (name: string) =>
      ctPage.locator(".filesystem-entry-label").filter({
        hasText: new RegExp(`^${name.replace(/\./g, "\\.")}$`),
      });

    // `src` is inside the depth limit, so its children are already there.
    await expect(label("db").first()).toBeVisible({ timeout: 30_000 });

    // `src/db` is at the depth limit: expanding it is what asks the main
    // process for its children.
    await label("db").first().click();

    // The lazily loaded child must actually appear …
    await expect(label("store.nim").first()).toBeVisible({ timeout: 30_000 });
    // … and no stub may be left anywhere in the tree.
    await expect(
      ctPage.locator(".filesystem-entry-label").filter({ hasText: /^Loading\.\.\.$/ }),
    ).toHaveCount(0, { timeout: 30_000 });

    const mainProcessFailures = mainProcessOutput.filter(
      (line) =>
        line.includes("Cannot read properties of null") ||
        line.includes("Cannot read properties of undefined") ||
        line.includes("UnhandledPromiseRejection") ||
        line.includes("unhandledRejection"),
    );
    expect(
      mainProcessFailures,
      "the load-path-content handler must not dereference a nil trace in " +
        "folder mode — see #574; the rejected promise meant the renderer " +
        "never received CODETRACER::update-path-content and the folder " +
        "stayed on 'Loading...' forever",
    ).toEqual([]);
  });
});

test.describe("Welcome new-tab Open Folder through main-process dialog handler", () => {
  test.use({
    launchMode: "welcome",
    testOpenFolderDialogPath: codetracerInstallDir,
  });

  test("new-tab open-folder-dialog populates the CodeTracer repository", async ({ ctPage }) => {
    await ctPage.waitForSelector(".welcome-screen", { timeout: 15000 });
    await ctPage.locator(".session-tab-add").click();
    await expect(ctPage.locator(".welcome-screen")).toBeVisible({ timeout: 10_000 });

    await ctPage.locator(".start-option.open-folder").click();

    await assertWorkspacePanelsPopulated(ctPage, /src|README|Justfile|flake\.nix/i);
    await expect(ctPage.locator(".welcome-screen")).toBeHidden({ timeout: 10_000 });
    await expect(ctPage.locator(".session-tab.active .session-tab-label")).toHaveText("codetracer", {
      timeout: 10_000,
    });
    await expect.poll(async () => {
      return await ctPage.evaluate(() => {
        const d = (window as any).data;
        const activeSession = d.sessions?.[d.activeSessionIndex];
        return {
          activeSessionIndex: d.activeSessionIndex,
          folder: String(activeSession?.startOptions?.folder ?? ""),
          mode: Number(d.ui?.mode),
          fileCount: Array.isArray(d.services?.debugger?.paths)
            ? d.services.debugger.paths.length
            : -1,
        };
      });
    }, { timeout: 10_000 }).toMatchObject({
      activeSessionIndex: 1,
      folder: codetracerInstallDir,
    });
  });
});

test.describe("Welcome Open Folder via second process", () => {
  test.use({ launchMode: "welcome", newTracePolicy: "tab" });

  test("running ct edit dot delegates into the existing welcome window", async ({ ctPage }) => {
    await ctPage.waitForSelector(".welcome-screen", { timeout: 15000 });

    const env = { ...process.env };
    // M-REC-6: legacy CODETRACER_TRACE_ID is retired in favour of
    // CODETRACER_RECORDING_ID; delete both so neither leaks in.
    delete env.CODETRACER_TRACE_ID;
    delete env.CODETRACER_RECORDING_ID;
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
