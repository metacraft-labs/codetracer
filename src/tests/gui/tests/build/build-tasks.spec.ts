/**
 * build-tasks.spec.ts — the desktop's build tasks, its task picker, its Stop,
 * the BUILD panel's reveal and a build's diagnostics in the editor.
 *
 * Spec: codetracer-pm `spec/Planned-Features/Build-Output-Pane.md` §3.6
 * (build tasks), §3.2 (Stop), §3.8 (auto-reveal, auto-dismiss), §3.9 (editor
 * integration), §3.11 (`Ctrl+Shift+B`), §3.12 (the omnibox commands), §4.2
 * (the planned flow: the main process runs the build), §5.2 (the project's
 * task file).
 *
 * The real Electron front-end in edit mode over the PLAT-56 project (the
 * bytes of `src/frontend/viewmodel/tests/unit/build_fixtures/
 * plat56_c_build.nim`) with a `.codetracer/build.yaml`:
 *
 *   * `Ctrl+Shift+B` opens the command palette on `:build: `, the project's
 *     tasks listed with the default first; `Enter` runs it — the REAL `gcc`,
 *     run by the desktop's main process (`index/build_runner`), its output
 *     in the BUILD panel with the shared verdict and status bar words;
 *   * `:build: <task>` typed into the palette runs that task;
 *   * ■ Stop stops a running task (`sleep 30`): the verdict "build
 *     cancelled", in seconds;
 *   * `src/main.c` opened after the failing build: Monaco carries the
 *     build's four markers (squiggles of the severity, the message on
 *     hover), and the gutter's pointer lane its icons; the pointer resting
 *     on `undefined_name` shows the compiler's message; a passing build
 *     clears the marks;
 *   * with the BUILD panel on its auto-hide strip: a build reveals it, a
 *     clean success puts it away two seconds later, a success with a warning
 *     leaves it.
 *
 * No mocks and no stand-in: a real project, the real `gcc`, the real `ct`
 * in edit mode, the real Electron app — its main process runs the builds.
 */
import { test, expect } from "../../lib/fixtures";
import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";
import { openBottomPanel, waitForDefaultBottomTabs } from "../../page-objects/auto-hide-strip";

const repoRoot = path.resolve(__dirname, "..", "..", "..", "..", "..");
const fixtureFile = path.join(
  repoRoot, "src", "frontend", "viewmodel", "tests", "unit", "build_fixtures", "plat56_c_build.nim");

function fixtureText(name: string): string {
  const text = fs.readFileSync(fixtureFile, "utf8");
  const m = text.match(new RegExp(`${name}\\* = """([\\s\\S]*?)"""`));
  if (!m) throw new Error(`${name} not in ${fixtureFile}`);
  return m[1];
}

function fixtureCommand(name: string): string {
  const text = fs.readFileSync(fixtureFile, "utf8");
  const m = text.match(new RegExp(`${name}\\* = "([^"]*)"`));
  if (!m) throw new Error(`${name} not in ${fixtureFile}`);
  return m[1];
}

const failCommand = fixtureCommand("Plat56FailCommand");
const passCommand = fixtureCommand("Plat56PassCommand");
const cleanCommand = "gcc -fdiagnostics-color=always -c src/ok.c -o /dev/null";

const project = fs.mkdtempSync(path.join(os.tmpdir(), "ct-build-tasks-"));
fs.mkdirSync(path.join(project, "src"), { recursive: true });
fs.mkdirSync(path.join(project, ".codetracer"), { recursive: true });
fs.writeFileSync(path.join(project, "src", "main.c"), fixtureText("Plat56MainC"));
fs.writeFileSync(path.join(project, "src", "ok.c"), fixtureText("Plat56OkC"));
fs.writeFileSync(
  path.join(project, ".codetracer", "build.yaml"),
  [
    "tasks:",
    "  fail:",
    `    command: "${failCommand}"`,
    "    default: true",
    "  pass:",
    `    command: "${passCommand}"`,
    "  slow:",
    '    command: "sleep 30"',
    "  clean:",
    `    command: "${cleanCommand}"`,
    "",
  ].join("\n"),
);

async function openPicker(ctPage: any) {
  await ctPage.locator(".lm_goldenlayout").click({ position: { x: 5, y: 5 } }).catch(() => {});
  await ctPage.keyboard.press("Control+Shift+B");
  await expect(ctPage.locator("#command-query-text")).toHaveValue(":build: ", { timeout: 15_000 });
}

async function runTask(ctPage: any, name: string) {
  await openPicker(ctPage);
  if (name.length > 0) await ctPage.keyboard.type(name);
  await ctPage.waitForTimeout(300);
  await ctPage.keyboard.press("Enter");
}

/** The BUILD panel's verdict, as any of the window's panels draws it. */
async function expectVerdict(ctPage: any, text: string, timeout = 120_000) {
  await expect
    .poll(async () => await ctPage.locator(".build-command-label").allInnerTexts(),
          { timeout })
    .toContain(text);
}

async function dismissOverlay(ctPage: any) {
  for (let i = 0; i < 5 && (await ctPage.locator("#auto-hide-overlay.visible").count()) > 0; i++) {
    await ctPage.keyboard.press("Escape");
    await ctPage.mouse.move(5, 5);
    await ctPage.waitForTimeout(500);
  }
}

/** The BUILD panel on screen, docked open from its footer tab if it is not. */
async function ensureBuildShown(ctPage: any) {
  await dismissOverlay(ctPage);
  if ((await ctPage.locator(".build-panel:visible").count()) > 0) return;
  await openBottomPanel(ctPage, "BUILD");
  await expect(ctPage.locator(".build-panel:visible").first()).toBeVisible({ timeout: 30_000 });
}

async function markers(ctPage: any) {
  return await ctPage.evaluate(() =>
    (globalThis as any).monaco.editor
      .getModelMarkers({ owner: "codetracer-build" })
      .map((m: any) => `${m.severity} ${m.startLineNumber}:${m.startColumn}-${m.endColumn}`)
      .sort());
}

test.describe("Build tasks on the desktop", () => {
  test.use({ launchMode: "edit", editFolderPath: project });
  test.setTimeout(300_000);

  test("Ctrl+Shift+B, the default task, the editor's marks, Stop", async ({ ctPage }) => {
    await expect(ctPage.locator(".lm_goldenlayout")).toBeVisible({ timeout: 60_000 });
    await waitForDefaultBottomTabs(ctPage);

    // THE PICKER: the default task first, then the others, then the pane's
    // commands.
    await openPicker(ctPage);
    const rows = ctPage.locator(".ct-menu-item-label");
    await expect(rows.first()).toContainText("fail", { timeout: 15_000 });
    const labels = (await rows.allInnerTexts()).map((t: string) => t.split(/\s+/)[0]);
    expect(labels).toEqual(["fail", "pass", "slow", "clean", "stop", "clear", "history"]);
    await expect(rows.first()).toContainText(failCommand);

    // ENTER: the main process runs the real failing build.
    await ctPage.keyboard.press("Enter");
    await expect(ctPage.locator("#status .build-status-text")).toHaveText(
      "Build failed: 2 errors, 1 warning", { timeout: 120_000 });
    // §3.8: the failure revealed the panels from their strip (Problems last).
    await expect(ctPage.locator("#auto-hide-overlay.visible")).toHaveCount(1, { timeout: 15_000 });
    await ensureBuildShown(ctPage);
    await expectVerdict(ctPage, "build failed (exit code 1)", 15_000);
    await expect(ctPage.locator("#build > div")).toHaveCount(15, { timeout: 15_000 });

    // THE EDITOR'S MARKS in src/main.c, opened from the first error's line.
    await ctPage.locator("#build > div").nth(1).click();
    await expect
      .poll(async () => (await markers(ctPage)).length, { timeout: 30_000 })
      .toBe(4);
    expect(await markers(ctPage)).toEqual(
      ["2 10:12-26", "4 4:9-15", "8 10:12-26", "8 5:16-17"]);
    await expect(ctPage.locator(".squiggly-error").first()).toBeAttached({ timeout: 15_000 });
    await expect(ctPage.locator(".squiggly-warning").first()).toBeAttached();
    await expect(ctPage.locator(".build-diagnostic-margin-error").first()).toBeAttached();
    await expect(ctPage.locator(".build-diagnostic-margin-warning").first()).toBeAttached();

    // THE HOVER: the pointer resting on `undefined_name` (line 10, column 14).
    const at = await ctPage.evaluate(() => {
      const d = (globalThis as any).data;
      const tab = d.ui.editors[d.services.editor.active];
      const e = tab.monacoEditor;
      e.revealLineInCenter(10);
      const p = e.getScrolledVisiblePosition({ lineNumber: 10, column: 14 });
      const r = e.getDomNode().getBoundingClientRect();
      return { x: r.left + p.left + 2, y: r.top + p.top + p.height / 2 };
    });
    await ctPage.mouse.move(at.x, at.y);
    await ctPage.mouse.move(at.x + 1, at.y);
    await expect(ctPage.locator(".monaco-hover").filter({ hasText: "undeclared" }).first())
      .toBeVisible({ timeout: 15_000 });

    // `:build: pass` — a task by name; the marks are the passing build's
    // (none in src/main.c).
    await runTask(ctPage, "pass");
    await expectVerdict(ctPage, "build succeeded", 120_000);
    await expect.poll(async () => (await markers(ctPage)).length, { timeout: 15_000 }).toBe(0);

    // STOP: a running task, cancelled.
    await runTask(ctPage, "slow");
    await ensureBuildShown(ctPage);
    await expectVerdict(ctPage, "running sleep 30", 30_000);
    const started = Date.now();
    await ctPage.locator(".build-stop-btn:visible").first().click();
    await expectVerdict(ctPage, "build cancelled", 15_000);
    expect(Date.now() - started).toBeLessThan(15_000);
    await expect(ctPage.locator("#status .build-status-text")).toHaveText("Build cancelled");
  });

  test("the BUILD panel revealed by a build, put away after a clean success", async ({ ctPage }) => {
    await expect(ctPage.locator(".lm_goldenlayout")).toBeVisible({ timeout: 60_000 });
    await waitForDefaultBottomTabs(ctPage);
    const revealed = ctPage.locator("#auto-hide-overlay.visible .build-panel");
    await expect(revealed).toHaveCount(0);

    // A CLEAN SUCCESS: revealed, then put away two seconds on.
    await runTask(ctPage, "clean");
    await expect(revealed).toHaveCount(1, { timeout: 60_000 });
    await expectVerdict(ctPage, "build succeeded", 120_000);
    await expect(revealed).toHaveCount(0, { timeout: 10_000 });

    // A SUCCESS WITH A WARNING stays.
    await runTask(ctPage, "pass");
    await expect(revealed).toHaveCount(1, { timeout: 60_000 });
    await expectVerdict(ctPage, "build succeeded", 120_000);
    await ctPage.waitForTimeout(3_500);
    await expect(revealed).toHaveCount(1);
  });
});

// THE EDIT-MODE TOOLBAR'S BUILD (Edit-Mode-Toolbar.md EMT-D17, EMT-D30): the
// project's own command — a Noir crate's `nargo compile`, which the toolbar
// derives from `Nargo.toml` — run by the same main-process runner, its
// output in the BUILD panel. The crate is the PLAT-55 one
// (`src/frontend/tui/tests/fixtures/plat55_noir_build.nim`), which fails.
// `nargo` is found where `$NARGO` says (the pinned build), as the PLAT-55
// capture finds it.
const noirFixture = path.join(repoRoot, "src", "frontend", "tui", "tests", "fixtures",
                              "plat55_noir_build.nim");
function noirText(name: string): string {
  const text = fs.readFileSync(noirFixture, "utf8");
  const m = text.match(new RegExp(`${name}\\* = """([\\s\\S]*?)"""`));
  if (!m) throw new Error(`${name} not in ${noirFixture}`);
  return m[1];
}
if (process.env.NARGO) {
  process.env.PATH = `${path.dirname(process.env.NARGO)}${path.delimiter}${process.env.PATH}`;
}
const noirProject = fs.mkdtempSync(path.join(os.tmpdir(), "ct-build-toolbar-"));
fs.mkdirSync(path.join(noirProject, "src"), { recursive: true });
fs.writeFileSync(path.join(noirProject, "Nargo.toml"),
  '[package]\nname = "plat55_build"\ntype = "bin"\nauthors = [""]\n\n[dependencies]\n');
fs.writeFileSync(path.join(noirProject, "src", "main.nr"), noirText("Plat55MainNr"));
fs.writeFileSync(path.join(noirProject, "src", "util.nr"), noirText("Plat55UtilNr"));

test.describe("The desktop toolbar's Build", () => {
  test.use({ launchMode: "edit", editFolderPath: noirProject });
  test.setTimeout(300_000);

  test("runs the project's build command through the main process", async ({ ctPage }) => {
    await expect(ctPage.locator(".lm_goldenlayout")).toBeVisible({ timeout: 60_000 });
    const button = ctPage.locator("#build-image");
    await expect(button).toBeVisible({ timeout: 60_000 });
    await expect(button).toBeEnabled({ timeout: 30_000 });
    // Run stays refused, and says why (EMT-D30).
    await expect(ctPage.locator("#run-image")).toBeDisabled();
    await expect(ctPage.locator("#run-image")).toHaveAttribute("title", /record, then debug/);
    await button.click();
    // The status bar first: it is always on screen, while the failure moves the
    // strip's overlay from the BUILD panel to Problems (§3.8).
    await expect(ctPage.locator("#status .build-status-text")).toHaveText(
      /^Build failed: 2 errors?, 1 warning/, { timeout: 120_000 });
    await ensureBuildShown(ctPage);
    await expectVerdict(ctPage, "build failed (exit code 1)", 15_000);
  });
});
