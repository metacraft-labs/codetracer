/**
 * plat53-test-results-capture.spec.ts — PLAT-53, the desktop's column: the
 * REFERENCE the terminal's and the GPUI window's Test Results panes are
 * measured against.
 *
 * Spec: codetracer-pm `spec/GUI/Core-Panes/Test-Results-Pane.md` §8.
 *
 * The real Electron front-end in edit mode over the PLAT-53 crate (the same
 * bytes the native suites write: `src/frontend/tui/tests/fixtures/
 * plat53_noir_project.nim` — one test that passes, one that fails), its Test
 * Results pane read from the DOM:
 *
 *   * BEFORE A RUN — the headline, the ▶'s title and whether it is disabled,
 *     and per row: the test id, state class, mark, name, location, duration,
 *     the `⟳` / `⏵` titles, glyphs, `data-ct-open-mode` and whether each is
 *     disabled;
 *   * what a right-click on a row opens (the desktop has no menu there —
 *     measured, so the native panes are measured against it);
 *   * AFTER THE ▶ — the real `ct test run` — the same, plus each row's
 *     message, the failure block's lines, and the computed colours of the
 *     passed and failed marks and of the message (the design tokens the
 *     native panes draw them in).
 *
 * Written to `src/tests/visual/answers/plat53-test-results.electron.json`,
 * which `src/frontend/tui/tests/real_terminal/test_plat53_test_results_pty.nim`
 * and `src/frontend/gpui/tests/test_plat53_gpui_plan.nim` assert the native
 * panes against (`just plat53-capture-electron`).
 *
 * No mocks: a real crate, the real `ct` in edit mode, the real `ct test run`
 * (handed to the real `ct-test` and `nargo`), the real Electron app.
 * Isolation: the fixtures give the app a scratch `CODETRACER_HOME`; the test
 * certificate stores are scratch directories.
 */
import { test, expect } from "../../lib/fixtures";
import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";

const repoRoot = path.resolve(__dirname, "..", "..", "..", "..", "..");
const answersDir = path.join(repoRoot, "src", "tests", "visual", "answers");
const answersFile = path.join(answersDir, "plat53-test-results.electron.json");

// THE CRATE, byte for byte `plat53_noir_project.nim`'s.
const project = fs.mkdtempSync(path.join(os.tmpdir(), "ct-plat53-capture-"));
fs.mkdirSync(path.join(project, "src"), { recursive: true });
fs.writeFileSync(
  path.join(project, "Nargo.toml"),
  '[package]\nname = "plat53_suite"\ntype = "bin"\nauthors = [""]\n\n[dependencies]\n',
);
fs.writeFileSync(
  path.join(project, "src", "main.nr"),
  [
    "fn main(x: Field, y: pub Field) {",
    "    assert(x != y);",
    "}",
    "",
    "#[test]",
    "fn test_passes() {",
    "    main(1, 2);",
    "}",
    "",
    "#[test]",
    "fn test_fails() {",
    "    main(1, 1);",
    "}",
    "",
  ].join("\n"),
);
const certificates = fs.mkdtempSync(path.join(os.tmpdir(), "ct-plat53-certs-"));

async function showTestsPane(ctPage: any) {
  await expect(ctPage.locator(".lm_goldenlayout")).toBeVisible({ timeout: 60_000 });
  const tab = ctPage.locator(".lm_tab", { hasText: "TESTS" }).first();
  if (await tab.count()) {
    await tab.click();
  }
  await expect(ctPage.locator(".test-results-headline").first()).toBeVisible({
    timeout: 30_000,
  });
}

/** The pane as a reader of the DOM sees it. */
async function readPane(ctPage: any) {
  return await ctPage.evaluate(() => {
    const pane = document.querySelector(".test-results") as HTMLElement;
    const text = (n: Element | null) => (n ? (n.textContent || "").trim() : "");
    const run = pane.querySelector(".test-results-run-btn") as HTMLElement;
    const rows = Array.from(pane.querySelectorAll(".test-results-row")).map((row) => {
      const refresh = row.querySelector(".test-results-refresh-btn") as HTMLElement;
      const open = row.querySelector(".test-results-open-btn") as HTMLElement;
      const mark = row.querySelector(".test-results-mark") as HTMLElement;
      const message = row.querySelector(".test-results-message") as HTMLElement | null;
      return {
        testId: row.getAttribute("data-ct-test-id") || "",
        state: (row.getAttribute("class") || "").replace("test-results-row", "").trim(),
        mark: text(mark),
        markColor: getComputedStyle(mark).color,
        name: text(row.querySelector(".test-results-name")),
        where: text(row.querySelector(".test-results-where")),
        duration: text(row.querySelector(".test-results-duration")),
        refresh: {
          label: text(refresh),
          title: refresh.getAttribute("title") || "",
          disabled: refresh.classList.contains("disabled"),
        },
        open: {
          label: text(open),
          title: open.getAttribute("title") || "",
          mode: open.getAttribute("data-ct-open-mode") || "",
          disabled: open.classList.contains("disabled"),
        },
        message: message ? message.innerText : "",
        messageColor: message ? getComputedStyle(message).color : "",
      };
    });
    const failure = pane.querySelector(".test-results-failure") as HTMLElement;
    const absence = pane.querySelector(".test-results-absence") as HTMLElement;
    const empty = pane.querySelector(".test-results-empty") as HTMLElement;
    return {
      headline: text(pane.querySelector(".test-results-headline")),
      run: {
        label: text(run),
        title: run.getAttribute("title") || "",
        disabled: run.classList.contains("disabled"),
      },
      rows,
      failure: failure.classList.contains("hidden")
        ? []
        : Array.from(failure.querySelectorAll(".test-results-failure-line")).map(text),
      absence: absence.classList.contains("hidden") ? "" : text(absence),
      empty: empty.classList.contains("hidden") ? "" : text(empty),
    };
  });
}

/**
 * The entries of the context menu a right-click opened, or [] when none
 * opened (`#context-menu-container`, the desktop's one menu host — the probe
 * PLAT-52's capture uses).
 */
async function contextMenuEntries(ctPage: any): Promise<string[]> {
  try {
    await ctPage.locator("#context-menu-container").waitFor({ state: "visible", timeout: 3_000 });
    const entries = await ctPage
      .locator("#context-menu-container .context-menu-item")
      .allInnerTexts();
    await ctPage.keyboard.press("Escape");
    return entries;
  } catch {
    return [];
  }
}

test.describe("PLAT-53: the desktop's Test Results pane, captured", () => {
  test.use({
    launchMode: "edit",
    editFolderPath: project,
    launchEnv: {
      TEST_CERTIFICATES_DIR: path.join(certificates, "user-root"),
      TEST_CERTIFICATES_SYSTEM_DIR: path.join(certificates, "system"),
    },
  });
  test.setTimeout(600_000);

  test("the pane before and after a real run, and a row's right-click", async ({ ctPage }) => {
    await showTestsPane(ctPage);
    await expect(ctPage.locator(".test-results-row")).toHaveCount(2, { timeout: 60_000 });
    const run = ctPage.locator(".test-results-run-btn").first();
    await expect(run).not.toHaveClass(/disabled/, { timeout: 30_000 });
    const before = await readPane(ctPage);

    // A RIGHT-CLICK ON A ROW: what opens (measured, not assumed).
    await ctPage.locator(".test-results-row .test-results-name").first().click({
      button: "right",
    });
    const rowContextMenu = await contextMenuEntries(ctPage);

    await run.click();
    await expect(
      ctPage.locator('.test-results-row[data-ct-test-id$="::test_fails"]').first(),
    ).toHaveClass(/\bfailed\b/, { timeout: 300_000 });
    await expect(ctPage.locator(".test-results-headline").first()).not.toHaveText(/running/);
    const after = await readPane(ctPage);

    const out = {
      _comment: [
        "PLAT-53 — the desktop's Test Results pane, read from the real Electron app.",
        "Produced by src/tests/gui/tests/test-results-pane/plat53-test-results-capture.spec.ts",
        "(`just plat53-capture-electron`). Durations vary per run; the suites compare their presence.",
      ],
      project: "plat53_suite",
      before,
      rowContextMenu,
      after,
    };
    fs.mkdirSync(answersDir, { recursive: true });
    fs.writeFileSync(answersFile, JSON.stringify(out, null, 1) + "\n");

    // The capture is only a reference if it is the run it says it is.
    expect(before.headline).toBe("2 tests, not run yet");
    expect(after.headline).toMatch(/^1 passed, 1 failed/);
    expect(after.rows.map((r: any) => r.state)).toEqual(["passed", "failed"]);
  });
});
