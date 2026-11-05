/**
 * run-build-lone-file.spec.ts — the BUILD panel's "Run build" writes the
 * modified editors before the build runs, and what Build and Run do for a
 * lone file and for a session with no project folder.
 *
 * Spec: codetracer-pm `spec/Planned-Features/Edit-Mode-Toolbar.md` EMT-D30
 * (the 2026-10-29 amendment: Run build saves first), EMT-D17, EMT-D34 (a
 * lone file, and a session with no project folder); `Build-Output-Pane.md`
 * §3.13 (Run builds the shown build's command again), §5.2.
 *
 * The real Electron front-end:
 *
 *   * RUN BUILD SAVES FIRST. `ct edit <folder>/note.c` over a folder whose
 *     `.codetracer/build.yaml` task copies `note.c` to `build-saw.txt` (so the
 *     build itself records the bytes it read). An edit typed into the editor
 *     and NOT saved; the BUILD panel's Run build: the build's own copy holds
 *     the edit — it was written before the build ran. Once with nothing
 *     shown (the default task), once more with that build shown (its command
 *     again).
 *   * A LONE FILE. `ct edit <folder>/lone.c` over a folder that is no
 *     project: the file on screen, the toolbar's Build and Run hidden (no
 *     project recognised, nothing declared — EMT-D13), Run build and the
 *     palette's Project: Run each SAY why nothing runs; a task the folder
 *     then declares is what Run build builds.
 *   * NO PROJECT FOLDER. Welcome screen → New File: Run build, `:build` and
 *     `:build <command>` say there is no project folder and start nothing;
 *     Run build asks for no save first (the untitled buffer's Save dialog in
 *     front of a build that cannot run was #837's complaint).
 *
 * No mocks. The one stand-in is an OBSERVER on the renderer's IPC sender
 * (`data.ipc.send`, wrapped to note each channel and then send it unchanged —
 * the pattern `welcome-screen/edit_mode.spec.ts` uses to answer a dialog): it
 * is how the New File case sees that no save and no build were asked of the
 * main process. It replaces nothing; every message still goes through. The
 * project, the editor, the main process's runner and the build are real.
 */
import { test, expect } from "../../lib/fixtures";
import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";
import {
  DOCKED_BOTTOM_CONTENT_SELECTOR,
  openBottomPanel,
  waitForDefaultBottomTabs,
} from "../../page-objects/auto-hide-strip";

// The words the shared model says (`viewmodels/build_tasks.nim`,
// `viewmodels/edit_mode_toolbar.nim`, `viewmodels/desktop_test_host.nim`).
const NO_PROJECT_FOLDER_BUILD =
  "No project folder is open. There is nothing to build: open the project's folder to build it.";
const NO_BUILD_TASKS = "No build tasks: add .codetracer/build.yaml to the project";
const NOT_A_PROJECT = "CodeTracer does not recognise this folder as a project";
const NO_PROGRAM_PROJECT = "No project folder is open, so there is no program to run.";

/** The notifications the status bar shows now (`#active-notifications`). */
async function notifications(ctPage: any): Promise<string[]> {
  return await ctPage
    .locator("#active-notifications .status-notification .notification-message")
    .allInnerTexts();
}

async function expectNotification(ctPage: any, text: string) {
  await expect
    .poll(async () => (await notifications(ctPage)).join("\n"), { timeout: 30_000 })
    .toContain(text);
}

async function dismissOverlay(ctPage: any) {
  for (let i = 0; i < 5 && (await ctPage.locator("#auto-hide-overlay.visible").count()) > 0; i++) {
    await ctPage.keyboard.press("Escape");
    await ctPage.mouse.move(5, 5);
    await ctPage.waitForTimeout(500);
  }
}

// The BUILD panel where the user sees it: docked open below the editor. (An
// undocked auto-hide pane is parked in an off-screen host, so `:visible`
// alone does not mean on screen.)
const SHOWN_BUILD = `${DOCKED_BOTTOM_CONTENT_SELECTOR} .build-panel`;

/** The BUILD panel on screen, docked open from its footer tab if it is not. */
async function ensureBuildShown(ctPage: any) {
  await dismissOverlay(ctPage);
  if ((await ctPage.locator(`${SHOWN_BUILD}:visible`).count()) > 0) return;
  await openBottomPanel(ctPage, "BUILD");
  await expect(ctPage.locator(SHOWN_BUILD).first()).toBeVisible({ timeout: 30_000 });
}

/** The BUILD panel's Run build, pressed. */
async function pressRunBuild(ctPage: any) {
  await ensureBuildShown(ctPage);
  const run = ctPage.locator(`${SHOWN_BUILD} .build-run-btn`).first();
  await expect(run).toBeVisible({ timeout: 15_000 });
  await run.click();
}

/** A palette line, typed and run (`:build`, `:Project: Run`, …). */
async function paletteLine(ctPage: any, line: string) {
  await ctPage.locator(".lm_goldenlayout").click({ position: { x: 5, y: 5 } }).catch(() => {});
  await ctPage.keyboard.press("Control+KeyP");
  const box = ctPage.locator("#command-query-text");
  await expect(box).toBeVisible({ timeout: 30_000 });
  await box.fill(line);
  await ctPage.waitForTimeout(300);
  await box.press("Enter");
}

/** A line typed at the top of the editor on screen, not saved. */
async function typeAtTop(ctPage: any, text: string) {
  const firstLine = ctPage.locator(".monaco-editor .view-line").first();
  await expect(firstLine).toBeVisible({ timeout: 60_000 });
  await firstLine.click();
  await ctPage.keyboard.press("Control+Home");
  await ctPage.keyboard.type(text);
}

// ---------------------------------------------------------------------------
// Run build saves first.
// ---------------------------------------------------------------------------

const saveProject = fs.mkdtempSync(path.join(os.tmpdir(), "ct-run-build-saves-"));
const noteFile = path.join(saveProject, "note.c");
const sawFile = path.join(saveProject, "build-saw.txt");
fs.writeFileSync(noteFile, "int on_disk = 1;\n");
fs.mkdirSync(path.join(saveProject, ".codetracer"), { recursive: true });
fs.writeFileSync(
  path.join(saveProject, ".codetracer", "build.yaml"),
  ["tasks:", "  copy:", '    command: "cp note.c build-saw.txt"', "    default: true", ""].join("\n"),
);

test.describe("the BUILD panel's Run build writes the modified editors first", () => {
  test.use({ launchMode: "edit", editFolderPath: noteFile });
  test.setTimeout(300_000);

  test("an unsaved edit is on disk before the build reads it", async ({ ctPage }) => {
    await expect(ctPage.locator(".lm_goldenlayout")).toBeVisible({ timeout: 60_000 });
    await waitForDefaultBottomTabs(ctPage);
    await expect(ctPage.locator(".lm_tab", { hasText: "note.c" }).first()).toBeVisible({
      timeout: 60_000,
    });

    // NOTHING SHOWN YET: Run build runs the default task.
    await typeAtTop(ctPage, "// first unsaved edit\n");
    expect(fs.readFileSync(noteFile, "utf8")).not.toContain("first unsaved edit");
    await pressRunBuild(ctPage);
    await expect
      .poll(() => (fs.existsSync(sawFile) ? fs.readFileSync(sawFile, "utf8") : ""), {
        timeout: 120_000,
      })
      .toContain("int on_disk = 1;");
    // The build's own copy: what the build read had the edit in it.
    expect(fs.readFileSync(sawFile, "utf8")).toContain("// first unsaved edit");
    expect(fs.readFileSync(noteFile, "utf8")).toContain("// first unsaved edit");
    await expect(ctPage.locator("#status .build-status-text")).toHaveText(/^Build succeeded/, {
      timeout: 60_000,
    });

    // THAT BUILD SHOWN: Run build runs its command again — and saves first.
    fs.rmSync(sawFile);
    await typeAtTop(ctPage, "// second unsaved edit\n");
    expect(fs.readFileSync(noteFile, "utf8")).not.toContain("second unsaved edit");
    await pressRunBuild(ctPage);
    await expect
      .poll(() => (fs.existsSync(sawFile) ? fs.readFileSync(sawFile, "utf8") : ""), {
        timeout: 120_000,
      })
      .toContain("int on_disk = 1;");
    expect(fs.readFileSync(sawFile, "utf8")).toContain("// second unsaved edit");
  });
});

// ---------------------------------------------------------------------------
// A lone file: its folder is the project, and the folder decides.
// ---------------------------------------------------------------------------

const loneFolder = fs.mkdtempSync(path.join(os.tmpdir(), "ct-lone-file-"));
const loneFile = path.join(loneFolder, "lone.c");
fs.writeFileSync(loneFile, "int lone_marker = 1;\n");

test.describe("ct edit <file> over a folder that is no project", () => {
  test.use({ launchMode: "edit", editFolderPath: loneFile });
  test.setTimeout(300_000);

  test("the file is shown; Build and Run say what the folder lacks; its task builds", async ({ ctPage }) => {
    await expect(ctPage.locator(".lm_goldenlayout")).toBeVisible({ timeout: 60_000 });
    await waitForDefaultBottomTabs(ctPage);
    await expect(ctPage.locator(".lm_tab", { hasText: "lone.c" }).first()).toBeVisible({
      timeout: 60_000,
    });
    await expect(ctPage.locator(".monaco-editor .view-line").filter({ hasText: "lone_marker" }).first())
      .toBeVisible({ timeout: 60_000 });
    // EMT-D13: nothing recognised, nothing declared — no Build or Run button.
    await expect(ctPage.locator("#build-image:visible")).toHaveCount(0);
    await expect(ctPage.locator("#run-image:visible")).toHaveCount(0);

    // Run build: the folder has no task, and the user is told so.
    await pressRunBuild(ctPage);
    await expectNotification(ctPage, NO_BUILD_TASKS);
    // The palette's Project: Run: the folder is not a project.
    await paletteLine(ctPage, ":Project: Run");
    await expectNotification(ctPage, NOT_A_PROJECT);

    // The folder declares a task: Run build builds it, in the folder.
    fs.mkdirSync(path.join(loneFolder, ".codetracer"), { recursive: true });
    fs.writeFileSync(
      path.join(loneFolder, ".codetracer", "build.yaml"),
      ["tasks:", "  check:", '    command: "grep -c lone_marker lone.c"', ""].join("\n"),
    );
    await pressRunBuild(ctPage);
    await expect(ctPage.locator("#status .build-status-text")).toHaveText(/^Build succeeded/, {
      timeout: 120_000,
    });
  });
});

// ---------------------------------------------------------------------------
// No project folder: Welcome screen → New File.
// ---------------------------------------------------------------------------

test.describe("a session with no project folder (New File)", () => {
  test.use({ launchMode: "welcome" });
  test.setTimeout(300_000);

  test("Run build, :build and :build <command> start nothing and say why", async ({ ctPage }) => {
    const newFile = ctPage.locator(".start-option.new-file");
    await expect(newFile).toBeVisible({ timeout: 30_000 });
    await newFile.click();
    await expect(ctPage.locator(".welcome-screen")).toBeHidden({ timeout: 15_000 });
    await expect(ctPage.locator(".lm_goldenlayout")).toBeVisible({ timeout: 60_000 });
    await waitForDefaultBottomTabs(ctPage);

    // The observer: every channel the renderer sends from here on, noted
    // and then sent unchanged.
    await ctPage.evaluate(() => {
      const d = (window as any).data;
      const w = window as any;
      w.__sentChannels = [];
      const originalSend = d.ipc.send.bind(d.ipc);
      d.ipc.send = (channel: string, payload?: unknown) => {
        w.__sentChannels.push(String(channel));
        return originalSend(channel, payload);
      };
    });
    const sent = async (): Promise<string[]> =>
      await ctPage.evaluate(() => (window as any).__sentChannels.slice());

    // The untitled buffer has an unsaved change.
    await typeAtTop(ctPage, "int scratch = 1;\n");

    await pressRunBuild(ctPage);
    await expectNotification(ctPage, NO_PROJECT_FOLDER_BUILD);
    await paletteLine(ctPage, ":build");
    await paletteLine(ctPage, ":build echo from-the-launch-directory");
    await expect
      .poll(async () => (await notifications(ctPage)).filter((t) => t.includes(NO_PROJECT_FOLDER_BUILD)).length, {
        timeout: 30_000,
      })
      .toBeGreaterThanOrEqual(1);
    await paletteLine(ctPage, ":Project: Run");
    await expectNotification(ctPage, NO_PROGRAM_PROJECT);
    await ctPage.waitForTimeout(1_000);

    const channels = await sent();
    test.info().attach("channels sent", { body: channels.join("\n") });
    // No build was asked of the main process, and nothing was saved first.
    expect(channels.filter((c) => c === "CODETRACER::build-start")).toEqual([]);
    expect(channels.filter((c) => c === "CODETRACER::save-untitled" || c === "CODETRACER::save-file"))
      .toEqual([]);
    const status = (await ctPage.locator("#status .build-status-text").allInnerTexts()).join(" ");
    expect(status).not.toMatch(/Build (succeeded|failed|cancelled)|Building/);
  });
});
