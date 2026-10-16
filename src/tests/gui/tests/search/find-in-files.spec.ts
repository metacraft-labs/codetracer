/**
 * PLAT-57: Find in Files on the desktop — the panel over THE shared runner
 * (`viewmodel/host/find_in_files`, which the Electron main process now runs
 * in place of its shell-string `rg` call) and the shared `SearchResultsVM`.
 *
 * Verifies, on the real app and a real recording:
 *   - `:grep <text>` typed into the omnibox closes it and shows the FIND IN
 *     FILES panel, grouped by file, with every matching line of the
 *     recording's sources — compared with an oracle this spec computes by
 *     reading the program's sources itself (the recording's files are those
 *     sources), so the panel is graded against something other than the
 *     runner;
 *   - the runner's match is the highlighted text (never a second search of
 *     the line by the view);
 *   - a click on a row opens its file at its line; `F4` / `Shift+F4` walk
 *     the results;
 *   - the Match Case toggle runs the search again case-sensitively;
 *   - in the panel's field `Alt+C` flips Match Case back and `Alt+R` turns
 *     on Use Regular Expression (the keymap's `search.toggle-*`, read where
 *     the field has the focus), and a regular expression lists exactly the
 *     lines the oracle's own reading of it finds.
 *
 * No mocks: a `multi_root` recording made by the real Python recorder through
 * `ct record`, opened by the real Electron app.
 */

import * as fs from "node:fs";
import * as path from "node:path";

import { test, expect, codetracerInstallDir } from "../../lib/fixtures";
import { LayoutPage } from "../../page-objects/layout-page";
import { CommandPalette } from "../../page-objects/command-palette/command-palette";

const PROGRAM = "multi_root/app/main.py";
const PATTERN = "scale";

/** Every line of every source of `multi_root` containing `pattern`, any case,
 *  in the order the runner lists them (files by path, then line). */
function oracle(pattern: string): { file: string; line: number }[] {
  const root = path.join(codetracerInstallDir, "test-programs", "multi_root");
  const files: string[] = [];
  const walk = (dir: string) => {
    for (const name of fs.readdirSync(dir).sort()) {
      if (name.startsWith(".")) continue;
      const p = path.join(dir, name);
      const st = fs.lstatSync(p);
      if (st.isDirectory()) walk(p);
      else if (st.isFile() && name.endsWith(".py")) files.push(p);
    }
  };
  walk(root);
  const rows: { file: string; line: number }[] = [];
  for (const f of files) {
    const lines = fs.readFileSync(f, "utf8").split("\n");
    lines.forEach((text, i) => {
      if (text.toLowerCase().includes(pattern.toLowerCase())) {
        rows.push({ file: f, line: i + 1 });
      }
    });
  }
  return rows;
}

/** The oracle's reading of the regular expression `sc[a]le\b`: the lines
 *  holding `name`, any case, with no word character after it. */
function wordEndOracle(name: string): { file: string; line: number }[] {
  return oracle(name).filter(({ file, line }) => {
    const text = fs.readFileSync(file, "utf8").split("\n")[line - 1].toLowerCase();
    for (let at = text.indexOf(name); at >= 0; at = text.indexOf(name, at + 1)) {
      const after = text[at + name.length];
      if (after === undefined || !/[A-Za-z0-9_]/.test(after)) return true;
    }
    return false;
  });
}

function shortPath(p: string): string {
  const parts = p.split("/");
  return `${parts[parts.length - 2]}/${parts[parts.length - 1]}`;
}

test.describe("Find in Files", () => {
  test.setTimeout(240_000);
  test.use({ sourcePath: PROGRAM, launchMode: "trace" });

  test(":grep shows the panel with the sources' rows; a row opens; Aa runs it again", async ({ ctPage }) => {
    const layout = new LayoutPage(ctPage);
    await layout.waitForBaseComponentsLoaded();
    await layout.waitForTraceLoaded();

    const expected = oracle(PATTERN);
    expect(expected.length).toBeGreaterThanOrEqual(4);

    // `:grep scale` in the omnibox: it closes, the panel shows the rows.
    const palette = new CommandPalette(ctPage);
    await palette.open();
    const input = ctPage.locator("#command-query-text");
    await input.fill(`:grep ${PATTERN}`);
    await input.press("Enter");
    // The omnibox closes: its results go, its field empties (the header's
    // omnibox itself stays on screen, as it always does).
    await expect(ctPage.locator(".command-container")).toHaveClass(/hidden/,
      { timeout: 10_000 });
    await expect(input).toHaveValue("");

    const panel = ctPage.locator(".search-results:visible").first();
    await expect(panel).toBeVisible({ timeout: 20_000 });
    const rows = panel.locator(".search-results-match-row");
    await expect(rows).toHaveCount(expected.length, { timeout: 30_000 });

    // Grouped by file, in the oracle's order, with its counts.
    const groups = panel.locator(".fif-file-group");
    const files = [...new Set(expected.map((r) => r.file))];
    await expect(groups).toHaveCount(files.length);
    for (let g = 0; g < files.length; g++) {
      const n = expected.filter((r) => r.file === files[g]).length;
      await expect(groups.nth(g).locator(".fif-file-path")).toHaveText(shortPath(files[g]));
      await expect(groups.nth(g).locator(".fif-file-count")).toHaveText(
        `${n} ${n === 1 ? "match" : "matches"}`);
    }
    // Every row's line, in order; the runner's match highlighted.
    for (let i = 0; i < expected.length; i++) {
      await expect(rows.nth(i).locator(".fif-line-number")).toHaveText(`${expected[i].line}`);
      await expect(rows.nth(i).locator(".fif-highlight")).toHaveText(/^scale$/i);
    }
    // The panel's field shows the query the omnibox searched for.
    await expect(panel.locator("#fif-input")).toHaveValue(PATTERN);

    // A click on the last row (another file) opens it at its line.
    const last = expected[expected.length - 1];
    await rows.nth(expected.length - 1).click();
    await expect(ctPage.locator(".lm_tab.lm_active .lm_title").filter({
      hasText: path.basename(last.file) }).first()).toBeVisible({ timeout: 20_000 });
    await expect(ctPage.locator(".view-lines").filter({
      hasText: "def scale(value, factor):" }).first()).toBeVisible({ timeout: 20_000 });

    // `F4` (CUA, §5.3): the next result — wrapping past the last to the
    // first — selected and opened; `Shift+F4` back to the last.
    await ctPage.keyboard.press("F4");
    await expect(rows.nth(0)).toHaveClass(/fif-match-row-selected/, { timeout: 10_000 });
    await expect(ctPage.locator(".lm_tab.lm_active .lm_title").filter({
      hasText: path.basename(expected[0].file) }).first()).toBeVisible({ timeout: 20_000 });
    await ctPage.keyboard.press("Shift+F4");
    await expect(rows.nth(expected.length - 1)).toHaveClass(/fif-match-row-selected/,
      { timeout: 10_000 });

    // Match Case: `Scale` is nowhere, case-sensitively.
    await palette.open();
    await input.fill(":grep Scale");
    await input.press("Enter");
    const again = ctPage.locator(".search-results:visible").first();
    await expect(again.locator(".search-results-match-row")).toHaveCount(expected.length,
      { timeout: 30_000 });
    await again.locator(".fif-option-case").click();
    await expect(again.locator(".fif-option-case")).toHaveClass(/fif-option-on/);
    await expect(again.locator(".search-results-match-row")).toHaveCount(0, { timeout: 30_000 });
    await expect(again.locator(".fif-empty-prompt")).toHaveText('No results for "Scale"');

    // The field's keys (`searchInputFocus`): `Alt+C` flips Match Case back
    // off — the rows return — and `Alt+R` turns on Use Regular Expression.
    const field = again.locator("#fif-input");
    await field.focus();
    await ctPage.keyboard.press("Alt+C");
    await expect(again.locator(".fif-option-case")).not.toHaveClass(/fif-option-on/);
    await expect(again.locator(".search-results-match-row")).toHaveCount(expected.length,
      { timeout: 30_000 });
    await ctPage.keyboard.press("Alt+R");
    await expect(again.locator(".fif-option-regex")).toHaveClass(/fif-option-on/);
    // A regular expression, run from the field: the oracle's reading of it.
    const words = wordEndOracle(PATTERN);
    expect(words.length).toBeGreaterThanOrEqual(2);
    expect(words.length).toBeLessThan(expected.length);
    await field.fill("sc[a]le\\b");
    await field.press("Enter");
    const wordRows = again.locator(".search-results-match-row");
    await expect(wordRows).toHaveCount(words.length, { timeout: 30_000 });
    for (let i = 0; i < words.length; i++) {
      await expect(wordRows.nth(i).locator(".fif-line-number")).toHaveText(`${words[i].line}`);
      await expect(wordRows.nth(i).locator(".fif-highlight")).toHaveText(/^scale$/i);
    }
  });
});
