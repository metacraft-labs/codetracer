/**
 * plat62-constraints-capture.spec.ts — PLAT-62, the desktop's column: the
 * REFERENCE the terminal's and the GPUI window's Constraints panes are
 * measured against.
 *
 * Spec: codetracer-pm `spec/Planned-Features/Noir-Studio.md` § "The
 * Constraints pane on the terminal and the GPUI window (PLAT-62)".
 *
 * The real Electron front-end over the PLAT-62 crate, in edit mode and then in
 * its Debug mode: the crate's test recorded and opened in a new tab, the pane
 * opened with View › Constraints and measured there (the same
 * bytes the native suites write: `src/frontend/tui/tests/fixtures/
 * plat62_noir_circuit.nim`), its CONSTRAINTS pane read from the DOM after the
 * main process measured the crate with the real
 * `nargo info --json --print-acir`:
 *
 *   * the headline, the notice, the provenance and the absence;
 *   * per row, in order: its index (`data-ct-row`), name, kind, count, where
 *     the function is declared, its title, and whether a press leads anywhere
 *     (`linked`);
 *   * what a right-click on a placed row and on a row placed nowhere opens —
 *     the entries, and which are disabled with what reason;
 *   * what a press on a placed row does: the editor's active file and caret
 *     line, for a function and for an opcode; and that a press on a row placed
 *     nowhere opens nothing;
 *   * in the recording's tab, the same pane again (`debug`), and where a press
 *     on `main` goes there.
 *
 * Written to `src/tests/visual/answers/plat62-constraints.electron.json`,
 * which `src/frontend/tui/tests/test_plat62_constraints.nim`,
 * `src/frontend/tui/tests/real_terminal/test_plat62_constraints_pty.nim` and
 * `src/frontend/gpui/tests/test_plat62_gpui_constraints.nim` assert the
 * native panes against (`just plat62-capture-electron`).
 *
 * No mocks: a real crate, the real `nargo`, the real `ct` in edit mode, the
 * real Electron app. Isolation: the fixtures give the app a scratch
 * `CODETRACER_HOME`; the test certificate stores are scratch directories.
 */
import { test, expect } from "../../lib/fixtures";
import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";

const repoRoot = path.resolve(__dirname, "..", "..", "..", "..", "..");
const answersDir = path.join(repoRoot, "src", "tests", "visual", "answers");
const answersFile = path.join(answersDir, "plat62-constraints.electron.json");

// THE CRATE, byte for byte `plat62_noir_circuit.nim`'s.
const project = fs.mkdtempSync(path.join(os.tmpdir(), "ct-plat62-capture-"));
fs.mkdirSync(path.join(project, "src"), { recursive: true });
fs.writeFileSync(
  path.join(project, "Nargo.toml"),
  '[package]\nname = "plat62_circuit"\ntype = "bin"\nauthors = [""]\n\n[dependencies]\n',
);
fs.writeFileSync(
  path.join(project, "src", "main.nr"),
  [
    "mod checks;",
    "",
    "fn main(x: Field, y: pub Field) {",
    "    assert(x != y);",
    "    // Safety: the hint is checked right below.",
    "    let half = unsafe { halve(y) };",
    "    assert(half * 2 == y);",
    "    checks::in_range(x);",
    "}",
    "",
    "unconstrained fn halve(v: Field) -> Field {",
    "    v / 2",
    "}",
    "",
    "#[test]",
    "fn test_main() {",
    "    main(1, 4);",
    "}",
    "",
  ].join("\n"),
);
fs.writeFileSync(
  path.join(project, "src", "checks.nr"),
  ["pub fn in_range(v: Field) {", "    assert(v as u8 < 200);", "}", ""].join("\n"),
);
const certificates = fs.mkdtempSync(path.join(os.tmpdir(), "ct-plat62-certs-"));

/** The pane as a reader of the DOM sees it. */
async function readPane(ctPage: any) {
  return await ctPage.evaluate(() => {
    // Each tab keeps its own pane: the one on screen.
    const pane = Array.from(document.querySelectorAll(".constraints")).find(
      (n) => (n as HTMLElement).offsetParent !== null,
    ) as HTMLElement;
    const text = (n: Element | null) => (n ? (n.textContent || "").trim() : "");
    const shown = (sel: string) => {
      const n = pane.querySelector(sel) as HTMLElement | null;
      return n && !n.classList.contains("hidden") ? text(n) : "";
    };
    const rows = Array.from(pane.querySelectorAll("[data-ct-row]")).map((row) => {
      const cls = row.getAttribute("class") || "";
      return {
        index: Number(row.getAttribute("data-ct-row")),
        opcode: /\bconstraints-opcode\b/.test(cls),
        name: text(
          row.querySelector(".constraints-name") ??
            row.querySelector(".low-level-code-instruction-name"),
        ),
        kind: text(row.querySelector(".constraints-kind")),
        count: text(
          row.querySelector(".constraints-count") ??
            row.querySelector(".low-level-code-instruction-offset"),
        ),
        where: text(row.querySelector(".constraints-where")),
        title: row.getAttribute("title") || "",
        linked: /\blinked\b/.test(cls),
        selected: /\bselected\b/.test(cls),
      };
    });
    return {
      headline: text(pane.querySelector(".constraints-headline")),
      stale: pane.classList.contains("stale"),
      notice: shown(".constraints-listing-notice"),
      provenance: shown(".constraints-provenance"),
      absence: shown(".constraints-absence"),
      rows,
    };
  });
}

/** The entries of the context menu a right-click opened, with their state. */
async function contextMenu(ctPage: any) {
  try {
    await ctPage.locator("#context-menu-container").waitFor({ state: "visible", timeout: 3_000 });
    const entries = await ctPage.evaluate(() =>
      Array.from(document.querySelectorAll("#context-menu-container .context-menu-item")).map(
        (n) => ({
          label: ((n.querySelector(".ct-menu-item-label") || n).textContent || "").trim(),
          disabled: n.getAttribute("aria-disabled") === "true",
          reason: ((n.querySelector(".ct-menu-item-sublabel") || { textContent: "" }).textContent || "").trim(),
        }),
      ),
    );
    await ctPage.keyboard.press("Escape");
    return entries;
  } catch {
    return [];
  }
}

/** The active editor's path (relative to the crate) and its caret line. */
async function activeEditor(ctPage: any) {
  const at = await ctPage.evaluate(() => {
    const d = (globalThis as any).data;
    const active = d?.services?.editor?.active;
    const tab = active ? d.ui.editors[active] : null;
    const pos = tab?.monacoEditor?.getPosition?.();
    return { path: active ? String(active) : null, line: pos ? pos.lineNumber : null };
  });
  const p = at.path;
  return {
    path: p && p.startsWith(project + path.sep) ? p.slice(project.length + 1) : p,
    line: at.line,
  };
}

// Where each kind of row is, by `plat62_noir_circuit.nim`'s count: `main`'s 18
// opcodes, then `halve`'s 16, then the directives'.
const HalveRow = 19;
const InvertRow = 36;
const QuotientRow = 46;
const RangeOpcodeRow = 5;
const RowTotal = 55;

test.describe("PLAT-62: the desktop's Constraints pane, captured", () => {
  test.use({
    launchMode: "edit",
    editFolderPath: project,
    launchEnv: {
      TEST_CERTIFICATES_DIR: path.join(certificates, "user-root"),
      TEST_CERTIFICATES_SYSTEM_DIR: path.join(certificates, "system"),
    },
  });
  test.setTimeout(600_000);

  test("the measured rows, their menus and a press", async ({ ctPage }) => {
    await expect(ctPage.locator(".lm_goldenlayout")).toBeVisible({ timeout: 60_000 });
    const tab = ctPage.locator(".lm_tab", { hasText: /CONSTRAINTS/i }).first();
    if (await tab.count()) {
      await tab.click();
    }
    await expect(ctPage.locator(".constraints [data-ct-row]").first()).toBeVisible({
      timeout: 120_000,
    });
    // The sources arrive with the report; wait until a row is placed.
    await expect(ctPage.locator(".constraints [data-ct-row].linked").first()).toBeVisible({
      timeout: 30_000,
    });
    const before = await readPane(ctPage);

    // A RIGHT-CLICK on a placed row (`main`) and on one placed nowhere.
    const rows = ctPage.locator(".constraints [data-ct-row]");
    await rows.nth(0).click({ button: "right" });
    const placedMenu = await contextMenu(ctPage);
    await rows.nth(InvertRow).click({ button: "right" });
    const nowhereMenu = await contextMenu(ctPage);

    // A PRESS on `halve`: its declaring line in the editor.
    await rows.nth(HalveRow).click();
    await expect
      .poll(async () => (await activeEditor(ctPage)).line, { timeout: 30_000 })
      .toBe(11);
    const pressedPlaced = await activeEditor(ctPage);
    const afterPress = await readPane(ctPage);

    // A PRESS ON AN OPCODE: the line its debug symbols name, in the file
    // `checks::in_range` was inlined from.
    await rows.nth(RangeOpcodeRow).click();
    await expect
      .poll(async () => (await activeEditor(ctPage)).path, { timeout: 30_000 })
      .toBe("src/checks.nr");
    const pressedOpcode = await activeEditor(ctPage);

    // A PRESS on a directive: nothing opens.
    await rows.nth(0).click();
    await expect
      .poll(async () => (await activeEditor(ctPage)).line, { timeout: 30_000 })
      .toBe(3);
    await rows.nth(QuotientRow).click();
    await ctPage.waitForTimeout(800);
    const pressedNowhere = await activeEditor(ctPage);

    // ITS RECORDING, IN DEBUG MODE: the crate's test recorded and opened in a new
    // tab from Test Results, where the Debug default places no Constraints pane.
    await ctPage.locator(".lm_tab", { hasText: "TESTS" }).first().click();
    const testRow = ctPage
      .locator('.test-results-row[data-ct-test-id$="::test_main"]')
      .first();
    await expect(testRow).toBeVisible({ timeout: 60_000 });
    const open = testRow.locator(".test-results-open-btn");
    await expect(open).not.toHaveClass(/disabled/, { timeout: 30_000 });
    await open.click();
    await expect
      .poll(
        async () =>
          await ctPage.evaluate(() => {
            const d = (window as any).__CODETRACER_DATA__;
            return d && d.trace && d.trace.recordingId ? String(d.trace.recordingId) : "";
          }),
        { timeout: 300_000 },
      )
      .not.toBe("");
    await expect(ctPage.locator(".lm_goldenlayout:visible")).toBeVisible({ timeout: 120_000 });
    await expect(ctPage.locator(".constraints:visible")).toHaveCount(0);

    // View › Constraints, as a user opens it.
    await ctPage.locator("#menu-root").click();
    await ctPage.locator("#menu-elements").waitFor({ timeout: 30_000 });
    await ctPage
      .locator("#menu-elements > .menu-node-container", { hasText: "View" })
      .first()
      .hover();
    await ctPage
      .locator(".menu-nested-elements .ct-menu-item-label", { hasText: /^Constraints$/ })
      .first()
      .click();
    const debugRows = ctPage.locator(".constraints:visible [data-ct-row]");
    await expect(debugRows.first()).toBeVisible({ timeout: 120_000 });
    await expect(ctPage.locator(".constraints:visible [data-ct-row].linked").first()).toBeVisible({
      timeout: 30_000,
    });
    const debug = await readPane(ctPage);
    await debugRows.nth(0).click();
    await expect
      .poll(async () => (await activeEditor(ctPage)).line, { timeout: 60_000 })
      .toBe(3);
    const debugPressed = await activeEditor(ctPage);

    const out = {
      _comment: [
        "PLAT-62 — the desktop's Constraints pane, read from the real Electron app.",
        "Produced by src/tests/gui/tests/constraints-pane/plat62-constraints-capture.spec.ts",
        "(`just plat62-capture-electron`).",
      ],
      project: "plat62_circuit",
      before,
      placedMenu,
      nowhereMenu,
      pressedPlaced,
      pressedOpcode,
      selectedAfterPress: afterPress.rows.filter((r: any) => r.selected).map((r: any) => r.index),
      pressedNowhere,
      debug,
      debugPressed,
    };
    fs.mkdirSync(answersDir, { recursive: true });
    fs.writeFileSync(answersFile, JSON.stringify(out, null, 1) + "\n");

    // The capture is only a reference if it is the run it says it is.
    expect(before.headline).toBe("18 ACIR opcodes, 33 unconstrained");
    expect(before.rows.length).toBe(RowTotal);
    expect(before.notice).toBe("");
    expect(
      before.rows.filter((r: any) => !r.opcode).map((r: any) => r.name),
    ).toEqual(["main", "halve", "directive_invert", "directive_integer_quotient"]);
    expect(before.rows[RangeOpcodeRow].where).toBe("src/checks.nr:2");
    expect(pressedPlaced.path).toBe("src/main.nr");
    expect(pressedOpcode.line).toBe(2);
    expect(pressedNowhere.path).toBe("src/main.nr");
    expect(pressedNowhere.line).toBe(3);
    // The two modes' rows are one answer: Debug mode measured the same project.
    expect(debug.headline).toBe(before.headline);
    expect(debug.rows.map((r: any) => ({ ...r, selected: false }))).toEqual(
      before.rows.map((r: any) => ({ ...r, selected: false })),
    );
    expect(debugPressed.path).toBe("src/main.nr");
  });
});
