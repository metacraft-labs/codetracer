/**
 * plat55-problems-capture.spec.ts — PLAT-55, the desktop's column: the
 * REFERENCE the terminal's and the GPUI window's Problems panes are measured
 * against.
 *
 * Spec: codetracer-pm `spec/Planned-Features/Build-Output-Pane.md` §3.3 (the
 * Problems panel), §3.4 (the matchers); `Edit-Mode-Toolbar.md` §11 (EMT-D20,
 * D21, D22).
 *
 * The real Electron front-end in edit mode over the PLAT-55 crate (the same
 * bytes the native suites write: `src/frontend/tui/tests/fixtures/
 * plat55_noir_build.nim` — two files, one warning and two errors), its
 * Problems panel read from the DOM after a real `nargo compile`:
 *
 *   * THE ROWS — per row its severity class, icon and the icon's computed
 *     colour, path, location and message, in order; the header's counts and
 *     its buttons (label, active);
 *   * THE FIRST ERROR HIGHLIGHTED after the failed build (EMT-D21) — which
 *     row is `problems-row-selected`;
 *   * THE ERRORS FILTER and GROUP BY FILE — the rows and file headers each
 *     shows;
 *   * what a right-click on a row opens (measured, not assumed);
 *   * what a press on a row OPENS — the active editor's path and its caret
 *     line before and after the press (K35): the compiler's relative path
 *     resolved against the folder Edit mode opened (EMT-A36; until PLAT-56
 *     it opened nothing — codetracer-pm issue
 *     `2026-10-26-desktop-problems-row-ignores-relative-paths`).
 *
 * Written to `src/tests/visual/answers/plat55-problems.electron.json`, which
 * `src/frontend/tui/tests/test_plat55_problems.nim`,
 * `src/frontend/tui/tests/real_terminal/test_plat55_problems_pty.nim` and
 * `src/frontend/gpui/tests/test_plat55_gpui_plan.nim` assert the native panes
 * against (`just plat55-capture-electron`).
 *
 * THE ONE STAND-IN, AND WHY IT IS NOT A MOCK. The desktop's Electron main
 * process has no build runner: nothing in it sends `CODETRACER::build-*`
 * (a working-tree build exists on the web arm, through the wasm worker, and on
 * the native front-ends, through `tui/host/build_runner`). So the build is the
 * REAL `nargo compile`, run here on the crate, and its stdout / stderr lines
 * and exit code are sent through the main process's own
 * `CODETRACER::build-command` / `build-stdout` / `build-stderr` / `build-code`
 * messages — exactly as `tests/build/build-output.spec.ts` and
 * `tests/layout/plat70a-output-hscroll.spec.ts` do. Everything after that
 * (`onBuildStderr` → `appendBuild` → the shared `build_diagnostics` rule → the
 * `ErrorsVM` → the IsoNim view) is the product's own, unchanged.
 *
 * No mocks otherwise: a real crate, the real `nargo`, the real `ct` in edit
 * mode, the real Electron app.
 */
import { test, expect } from "../../lib/fixtures";
import { spawnSync } from "node:child_process";
import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";
import { openBottomPanel, waitForDefaultBottomTabs } from "../../page-objects/auto-hide-strip";
import { ProblemsPane } from "../../page-objects/panes/build/problems-pane";

const repoRoot = path.resolve(__dirname, "..", "..", "..", "..", "..");
const answersDir = path.join(repoRoot, "src", "tests", "visual", "answers");
const answersFile = path.join(answersDir, "plat55-problems.electron.json");

// THE CRATE, byte for byte `plat55_noir_build.nim`'s.
const project = fs.mkdtempSync(path.join(os.tmpdir(), "ct-plat55-capture-"));
fs.mkdirSync(path.join(project, "src"), { recursive: true });
fs.writeFileSync(
  path.join(project, "Nargo.toml"),
  '[package]\nname = "plat55_build"\ntype = "bin"\nauthors = [""]\n\n[dependencies]\n',
);
fs.writeFileSync(
  path.join(project, "src", "main.nr"),
  [
    "mod util;",
    "",
    "fn main(x: Field, y: pub Field) {",
    "    let a: Field = 42;",
    "    let b: bool = a;",
    "    assert(b);",
    "    assert(util::double(y) != x);",
    "}",
    "",
  ].join("\n"),
);
fs.writeFileSync(
  path.join(project, "src", "util.nr"),
  [
    "pub fn double(v: Field) -> Field {",
    "    let unused = 1;",
    "    let flag: bool = v;",
    "    assert(flag);",
    "    v * 2",
    "}",
    "",
  ].join("\n"),
);

/** The real build, run on the crate: its lines per stream and its code. */
function realBuild() {
  const nargo = process.env.NARGO || "nargo";
  const r = spawnSync(nargo, ["compile"], { cwd: project, encoding: "utf8" });
  if (r.error) throw new Error(`could not run ${nargo}: ${r.error.message}`);
  const lines = (s: string) => s.split("\n").filter((l, i, a) => i < a.length - 1 || l.length > 0);
  return { stdout: lines(r.stdout), stderr: lines(r.stderr), code: r.status ?? -1 };
}

/** The panel as a reader of the DOM sees it. */
async function readPanel(ctPage: any) {
  return await ctPage.evaluate(() => {
    const panel = document.querySelector(".problems-panel") as HTMLElement;
    const text = (n: Element | null) => (n ? (n.textContent || "").trim() : "");
    const rows = Array.from(panel.querySelectorAll(".problems-row")).map((row) => {
      const icon = row.querySelector(".problems-icon") as HTMLElement;
      const cls = row.getAttribute("class") || "";
      const severity = (cls.match(/problems-severity-(\w+)/) || ["", ""])[1];
      return {
        severity,
        selected: /\bproblems-row-selected\b/.test(cls),
        icon: text(icon),
        iconColor: getComputedStyle(icon).color,
        path: text(row.querySelector(".problems-path")),
        location: text(row.querySelector(".problems-location")),
        message: text(row.querySelector(".problems-message")),
      };
    });
    const buttons = Array.from(panel.querySelectorAll(".problems-filter-btn")).map((b) => ({
      label: text(b),
      active: b.classList.contains("active"),
    }));
    return {
      counts: Array.from(panel.querySelectorAll(".problems-count-badge")).map(text),
      status: text(panel.querySelector(".problems-status")),
      buttons,
      rows,
      fileHeaders: Array.from(panel.querySelectorAll(".problems-file-header")).map(text),
      empty: text(panel.querySelector(".problems-empty")),
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

/** `p` relative to the crate (the capture's temporary directory varies). */
function inProject(p: string | null): string | null {
  return p && p.startsWith(project + path.sep) ? p.slice(project.length + 1) : p;
}

test.describe("PLAT-55: the desktop's Problems panel, captured", () => {
  test.use({ launchMode: "edit", editFolderPath: project });
  test.setTimeout(300_000);

  test("the rows of a real failing build, the filters, a right-click and a press", async ({
    ctPage,
    electronApp,
  }) => {
    const build = realBuild();
    expect(build.code).not.toBe(0);

    // Edit mode has no State pane, so the layout itself is the readiness
    // signal (as in the PLAT-53 capture).
    await expect(ctPage.locator(".lm_goldenlayout")).toBeVisible({ timeout: 60_000 });
    await waitForDefaultBottomTabs(ctPage);
    await openBottomPanel(ctPage, "PROBLEMS");
    const pane = new ProblemsPane(ctPage);
    await expect(pane.root.first()).toBeVisible({ timeout: 60_000 });

    await electronApp!.evaluate(({ BrowserWindow }, b) => {
      const w = BrowserWindow.getAllWindows()[0];
      w.webContents.send("CODETRACER::build-command", { command: "nargo compile" });
      for (const data of b.stdout) w.webContents.send("CODETRACER::build-stdout", { data });
      for (const data of b.stderr) w.webContents.send("CODETRACER::build-stderr", { data });
      w.webContents.send("CODETRACER::build-code", { code: b.code });
    }, build);
    await expect(pane.rows()).toHaveCount(3, { timeout: 60_000 });

    // The failed build shows the BUILD panel in the bottom overlay (the
    // desktop's `onBuildCode`), over the docked PROBLEMS; dismiss it.
    for (let i = 0; i < 5 && (await ctPage.locator("#auto-hide-overlay.visible").count()) > 0; i++) {
      await ctPage.keyboard.press("Escape");
      await ctPage.mouse.move(5, 5);
      await ctPage.waitForTimeout(500);
    }
    await expect(ctPage.locator("#auto-hide-overlay.visible")).toHaveCount(0, { timeout: 30_000 });
    const after = await readPanel(ctPage);

    // THE ERRORS FILTER, then back.
    await pane.filterButton("Errors").click();
    await expect(pane.rows()).toHaveCount(2);
    const errorsOnly = await readPanel(ctPage);
    await pane.filterButton("All").click();
    await expect(pane.rows()).toHaveCount(3);

    // GROUP BY FILE, then back.
    await pane.groupByFileButton().click();
    await expect(pane.fileGroupHeaders()).toHaveCount(2);
    const grouped = await readPanel(ctPage);
    await pane.groupByFileButton().click();
    await expect(pane.fileGroupHeaders()).toHaveCount(0);

    // A RIGHT-CLICK ON A ROW: what opens (measured, not assumed).
    await pane.rows().nth(1).locator(".problems-message").click({ button: "right" });
    const rowContextMenu = await contextMenuEntries(ctPage);

    // A PRESS ON THE SECOND ROW (src/util.nr:3:22): what it opens, measured.
    // The compiler's relative path is resolved against the folder Edit mode
    // opened (`errors.desktopResolvedPath`, PLAT-56).
    const before = await activeEditor(ctPage);
    await pane.rows().nth(1).click();
    await ctPage.waitForTimeout(3_000);
    const opened = await activeEditor(ctPage);
    const afterPress = await readPanel(ctPage);

    const out = {
      _comment: [
        "PLAT-55 — the desktop's Problems panel, read from the real Electron app after a real `nargo compile`.",
        "Produced by src/tests/gui/tests/problems-pane/plat55-problems-capture.spec.ts",
        "(`just plat55-capture-electron`).",
      ],
      project: "plat55_build",
      build: { command: "nargo compile", code: build.code, stdout: build.stdout, stderr: build.stderr },
      after,
      errorsOnly,
      grouped,
      rowContextMenu,
      press: {
        row: 1,
        before: { path: inProject(before.path), line: before.line },
        opened: { path: inProject(opened.path), line: opened.line },
        after: afterPress,
      },
    };
    // The capture is only a reference (checked BEFORE it is written, so a
    // broken desktop never overwrites it) if it is the build it says it is.
    expect(after.rows.map((r: any) => `${r.severity} ${r.path}:${r.location}`)).toEqual([
      "warning src/util.nr:2:9",
      "error src/util.nr:3:22",
      "error src/main.nr:5:19",
    ]);
    // EMT-D21: the failed build highlights its first error (PLAT-56 fixed
    // the desktop's highlight, which went to the shown tab's slot —
    // `2026-10-26-desktop-failed-build-highlights-no-problems-row`).
    expect(after.rows.map((r: any) => r.selected)).toEqual([false, true, false]);
    // K35 / EMT-A36: the press opened the row's file at its line.
    expect(inProject(opened.path)).toBe("src/util.nr");
    expect(opened.line).toBe(3);
    fs.mkdirSync(answersDir, { recursive: true });
    fs.writeFileSync(answersFile, JSON.stringify(out, null, 1) + "\n");
  });
});
