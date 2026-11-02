/**
 * plat56-build-output-capture.spec.ts — PLAT-56, the desktop's column: the
 * REFERENCE the terminal's and the GPUI window's Build Output panes are
 * measured against.
 *
 * Spec: codetracer-pm `spec/Planned-Features/Build-Output-Pane.md` §3.13 (the
 * pane on every front-end), §3.5 (ANSI colour), §3.7 (build history), §3.10
 * (the status bar).
 *
 * The real Electron front-end in edit mode over the PLAT-56 project (the same
 * bytes the native suites write: `src/frontend/viewmodel/tests/unit/
 * build_fixtures/plat56_c_build.nim` — `src/main.c`, which fails with two
 * errors, a warning and a note, and `src/ok.c`, which passes with a warning),
 * built by the real `gcc` with its diagnostics in colour. Its BUILD panel and
 * status bar read from the DOM:
 *
 *   * THE LINES of the failing build and of the passing one — per line its
 *     class (`build-stderr`, `build-line-error`, …), its text and its runs
 *     (each span's text and its `style`, the colours the compiler wrote);
 *   * THE VERDICT — the header's words and class — and THE STATUS BAR'S
 *     BUILD INDICATOR (its words, its state class);
 *   * what a press on a located line OPENS (the active editor's path and
 *     caret line), and what a right-click on a line opens (measured);
 *   * THE HISTORY PICKER after the second build: its entries, and the first
 *     build shown again from it;
 *   * the status bar's indicator pressed: whether the BUILD panel is shown.
 *
 * Written to `src/tests/visual/answers/plat56-build-output.electron.json`,
 * which `src/frontend/tui/tests/test_plat56_build_output.nim`,
 * `src/frontend/tui/tests/real_terminal/test_plat56_build_output_pty.nim` and
 * `src/frontend/gpui/tests/test_plat56_gpui_plan.nim` assert the native panes
 * against (`just plat56-capture-electron`).
 *
 * THE ONE STAND-IN, AND WHY IT IS NOT A MOCK. The desktop's Electron main
 * process has no build runner: nothing in it sends `CODETRACER::build-*`. So
 * the build is the REAL `gcc`, run here on the project, and its stderr lines
 * and exit code are sent through the main process's own
 * `CODETRACER::build-command` / `build-stderr` / `build-code` messages —
 * exactly as `tests/problems-pane/plat55-problems-capture.spec.ts` does.
 * Everything after that (`onBuildStderr` → `appendBuild` → the `BuildVM`'s
 * reader → the IsoNim view and the status bar) is the product's own.
 *
 * No mocks otherwise: a real project, the real `gcc`, the real `ct` in edit
 * mode, the real Electron app.
 */
import { test, expect } from "../../lib/fixtures";
import { spawnSync } from "node:child_process";
import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";
import { bottomStripTab, closeDockedPanelFromTab, openBottomPanel, waitForDefaultBottomTabs } from "../../page-objects/auto-hide-strip";

const repoRoot = path.resolve(__dirname, "..", "..", "..", "..", "..");
const answersDir = path.join(repoRoot, "src", "tests", "visual", "answers");
const answersFile = path.join(answersDir, "plat56-build-output.electron.json");
const fixtureFile = path.join(
  repoRoot, "src", "frontend", "viewmodel", "tests", "unit", "build_fixtures", "plat56_c_build.nim");

/** A `const` string of the Nim fixture, between its `"""` quotes. */
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

// THE PROJECT, byte for byte the fixture's.
const project = fs.mkdtempSync(path.join(os.tmpdir(), "ct-plat56-capture-"));
fs.mkdirSync(path.join(project, "src"), { recursive: true });
fs.writeFileSync(path.join(project, "src", "main.c"), fixtureText("Plat56MainC"));
fs.writeFileSync(path.join(project, "src", "ok.c"), fixtureText("Plat56OkC"));
const failCommand = fixtureCommand("Plat56FailCommand");
const passCommand = fixtureCommand("Plat56PassCommand");

/** The real build, run on the project: its stderr lines and its code. */
function realBuild(command: string) {
  const r = spawnSync("/bin/sh", ["-c", command], { cwd: project, encoding: "utf8" });
  if (r.error) throw new Error(`could not run ${command}: ${r.error.message}`);
  const lines = (s: string) => s.split("\n").filter((l, i, a) => i < a.length - 1 || l.length > 0);
  return { stdout: lines(r.stdout), stderr: lines(r.stderr), code: r.status ?? -1 };
}

/** The BUILD panel and the status bar's indicator, as a reader sees them. */
async function readPanel(ctPage: any) {
  return await ctPage.evaluate(() => {
    const panel = document.querySelector(".build-panel") as HTMLElement;
    const text = (n: Element | null) => (n ? (n.textContent || "").trim() : "");
    const lines = Array.from(panel.querySelectorAll("#build > div")).map((line) => ({
      class: (line.getAttribute("class") || "")
        .split(" ")
        .filter((c) => c !== "build-output-line" && c !== "build-clickable")
        .join(" ") || "build-output-line",
      text: line.textContent || "",
      runs: Array.from(line.querySelectorAll("span")).map((s) => ({
        text: s.textContent || "",
        style: s.getAttribute("style") || "",
        color: getComputedStyle(s).color,
      })),
    }));
    const header = panel.querySelector(".build-header") as HTMLElement;
    const status = document.querySelector("#status .build-status");
    return {
      header: text(panel.querySelector(".build-command-label")),
      headerClass: header ? header.getAttribute("class") : "",
      duration: text(panel.querySelector(".build-duration")),
      empty: (panel.querySelector(".build-empty") as HTMLElement | null)?.style.display === "block",
      historyShown: (panel.querySelector(".build-history-btn") as HTMLElement | null)?.style.display !== "none",
      lines,
      status: text(document.querySelector("#status .build-status-text")),
      statusIcon: text(document.querySelector("#status .build-status-icon")),
      statusClass: status ? status.getAttribute("class") : "",
    };
  });
}

async function contextMenuEntries(ctPage: any): Promise<string[]> {
  try {
    await ctPage.locator("#context-menu-container").waitFor({ state: "visible", timeout: 3_000 });
    const entries = await ctPage.locator("#context-menu-container .context-menu-item").allInnerTexts();
    await ctPage.keyboard.press("Escape");
    return entries;
  } catch {
    return [];
  }
}

/** The active editor's path and its caret line, or nulls. */
async function activeEditor(ctPage: any) {
  return await ctPage.evaluate(() => {
    const d = (globalThis as any).data;
    const active = d?.services?.editor?.active;
    const tab = active ? d.ui.editors[active] : null;
    const pos = tab?.monacoEditor?.getPosition?.();
    return { path: active ? String(active) : null, line: pos ? pos.lineNumber : null };
  });
}

function inProject(p: string | null): string | null {
  return p && p.startsWith(project + path.sep) ? p.slice(project.length + 1) : p;
}

async function sendBuild(electronApp: any, command: string, b: { stdout: string[]; stderr: string[]; code: number }) {
  await electronApp!.evaluate(
    ({ BrowserWindow }: any, args: any) => {
      const w = BrowserWindow.getAllWindows()[0];
      w.webContents.send("CODETRACER::build-command", { command: args.command });
      for (const data of args.b.stdout) w.webContents.send("CODETRACER::build-stdout", { data });
      for (const data of args.b.stderr) w.webContents.send("CODETRACER::build-stderr", { data });
      w.webContents.send("CODETRACER::build-code", { code: args.b.code });
    },
    { command, b },
  );
}

/** The BUILD panel on screen, docked open from its footer tab if it is not. */
async function ensureBuildShown(ctPage: any) {
  // A failed build reveals PROBLEMS (and BUILD) in the bottom overlay (the
  // desktop's `onBuildCode`); dismissed first, so a press lands on the dock.
  await dismissOverlay(ctPage);
  if ((await ctPage.locator(".build-panel:visible").count()) > 0) return;
  await openBottomPanel(ctPage, "BUILD");
  await expect(ctPage.locator(".build-panel:visible").first()).toBeVisible({ timeout: 30_000 });
}

async function dismissOverlay(ctPage: any) {
  for (let i = 0; i < 5 && (await ctPage.locator("#auto-hide-overlay.visible").count()) > 0; i++) {
    await ctPage.keyboard.press("Escape");
    await ctPage.mouse.move(5, 5);
    await ctPage.waitForTimeout(500);
  }
}

test.describe("PLAT-56: the desktop's Build Output, captured", () => {
  test.use({ launchMode: "edit", editFolderPath: project });
  test.setTimeout(300_000);

  test("a real failing build, a passing one, the history and the status bar", async ({ ctPage, electronApp }) => {
    const failing = realBuild(failCommand);
    const passing = realBuild(passCommand);
    expect(failing.code).toBe(1);
    expect(passing.code).toBe(0);

    await expect(ctPage.locator(".lm_goldenlayout")).toBeVisible({ timeout: 60_000 });
    await waitForDefaultBottomTabs(ctPage);
    await openBottomPanel(ctPage, "BUILD");
    await expect(ctPage.locator(".build-panel").first()).toBeVisible({ timeout: 60_000 });
    const idle = await readPanel(ctPage);

    // THE FAILING BUILD.
    await sendBuild(electronApp, failCommand, failing);
    await expect(ctPage.locator("#build > div")).toHaveCount(failing.stderr.length, { timeout: 60_000 });
    await expect(ctPage.locator(".build-command-label")).toHaveText(/build failed/, { timeout: 30_000 });
    await ensureBuildShown(ctPage);
    const failed = await readPanel(ctPage);

    // A RIGHT-CLICK ON A LINE: what opens (measured, not assumed).
    await ctPage.locator("#build > div").nth(1).click({ button: "right" });
    const lineContextMenu = await contextMenuEntries(ctPage);

    // A PRESS ON THE FIRST ERROR'S LINE (src/main.c:5:17): what it opens.
    const before = await activeEditor(ctPage);
    await ctPage.locator("#build > div").nth(1).click();
    await expect
      .poll(async () => inProject((await activeEditor(ctPage)).path), { timeout: 15_000 })
      .toBe("src/main.c");
    await ctPage.waitForTimeout(1_000);
    const opened = await activeEditor(ctPage);

    // THE PASSING BUILD.
    await sendBuild(electronApp, passCommand, passing);
    await expect(ctPage.locator(".build-command-label").first()).toHaveText("build succeeded", { timeout: 60_000 });
    await ensureBuildShown(ctPage);
    const passed = await readPanel(ctPage);

    // THE HISTORY PICKER: its entries, and the failing build shown again.
    await ensureBuildShown(ctPage);
    await ctPage.locator(".build-history-btn:visible").click();
    const labels = await ctPage.locator(".build-history-item").allInnerTexts();
    await ctPage.locator(".build-history-item").nth(1).click();
    await expect(ctPage.locator(".build-command-label")).toHaveText(/build failed/, { timeout: 15_000 });
    const historyShown = await readPanel(ctPage);

    // THE STATUS BAR'S INDICATOR, pressed with the BUILD panel hidden (its
    // footer tab pressed again closes it).
    await closeDockedPanelFromTab(ctPage, bottomStripTab(ctPage, "BUILD")).catch(() => {});
    await dismissOverlay(ctPage);
    const statusBefore = await ctPage.locator(".build-panel:visible").count();
    await ctPage.locator("#status .build-status").click();
    await ctPage.waitForTimeout(1_000);
    const statusAfter = await ctPage.locator(".build-panel:visible").count();

    const out = {
      _comment: [
        "PLAT-56 — the desktop's BUILD panel and status bar, read from the real Electron app after real `gcc` builds.",
        "Produced by src/tests/gui/tests/build/plat56-build-output-capture.spec.ts",
        "(`just plat56-capture-electron`).",
      ],
      idle,
      failing: {
        command: failCommand,
        build: failing,
        ...failed,
        lineContextMenu,
        press: {
          line: 1,
          before: { path: inProject(before.path), line: before.line },
          opened: { path: inProject(opened.path), line: opened.line },
        },
      },
      passing: { command: passCommand, build: passing, ...passed },
      history: { labels, shown: historyShown },
      statusPress: { panelsBefore: statusBefore, panelsAfter: statusAfter },
    };
    // The capture is only a reference (checked BEFORE it is written, so a
    // broken desktop never overwrites it) if it is the builds it says it is.
    expect(failed.lines.length).toBe(15);
    expect(failed.lines[1].text).toBe("src/main.c:5:17: error: expected ‘;’ before ‘}’ token");
    expect(failed.lines[1].class).toBe("build-line-error");
    expect(failed.lines[2].class).toBe("build-stderr");
    // THE COMPILER'S COLOURS, as data drawn into spans (§3.5).
    expect(failed.lines[1].runs[2].style).toBe("color:rgb(187,0,0);font-weight:bold");
    expect(failed.header).toBe("build failed (exit code 1)");
    expect(failed.status).toBe("Build failed: 2 errors, 1 warning");
    // K35 / EMT-A36: the press opened the line's file at its line.
    expect(inProject(opened.path)).toBe("src/main.c");
    expect(opened.line).toBe(5);
    expect(passed.lines.length).toBe(4);
    expect(passed.header).toBe("build succeeded");
    expect(labels.length).toBe(2);
    expect(historyShown.header).toBe("build failed (exit code 1)");
    fs.mkdirSync(answersDir, { recursive: true });
    fs.writeFileSync(answersFile, JSON.stringify(out, null, 1) + "\n");
  });
});
