/**
 * plat64-monaco-unbound-chords.spec.ts — Input-Routing-And-Keymaps.md §11a: in
 * the desktop's editor only a chord a keymap binds acts. Monaco ships its own
 * keybinding service, and some of its Linux shortcuts are in no keymap: the
 * CUA base follows VS Code's map, which gives F7 / Shift+F7 to the diff
 * editor, so in a code editor Monaco's word-highlight navigation (the next /
 * previous occurrence of the word under the caret) is bound by nothing. The
 * desktop's key listener stops a shortcut the router resolves to nothing
 * before Monaco's own listener sees it (`key_router.monacoWouldAnswer`).
 *
 * On the `calc` recording, with the caret in the read-only editor, for each of
 * Monaco's stock shortcuts below that the live router binds to NOTHING (asked
 * of a copy of it, `window.__ctKeymapProbe`, with the CUA base and no user
 * rows): the CONTROL first — Monaco's own command (`editor.trigger`) changes
 * the editor's selections, so the shortcut would have done something — then
 * the real key press, after which the selections are what they were and the
 * router ran nothing. At least one candidate must be exercised.
 *
 * No mocks: the real app, a real recording, real KeyboardEvents.
 */

import * as fs from "fs";
import * as path from "path";

import { expect } from "@playwright/test";
import { test } from "../../lib/fixtures";

const repoRoot = path.resolve(__dirname, "..", "..", "..", "..", "..");
const prefix = process.env.PLAT68_DESKTOP_PREFIX ?? "";

function recording(prefixName: string): string {
  const cache = process.env.PLAT68_FIXTURES_DIR ??
    path.join(repoRoot, "test-logs", "tui-fixtures");
  const hits = fs.existsSync(cache)
    ? fs.readdirSync(cache).filter((e) => e.startsWith(prefixName + "-")).sort()
    : [];
  if (hits.length === 0) {
    throw new Error(`the '${prefixName}' recording is not in ${cache}`);
  }
  return path.join(cache, hits[hits.length - 1]);
}

// Monaco's stock shortcuts on Linux that the CUA base does not bind, each
// with the command it runs and the KeyboardEvent the router's probe names it
// from. (Its column-selection chords would not do: Monaco declares them with
// `linux: { primary: 0 }`, unbound on Linux.) The test asks the probe again,
// so a base that later binds one only skips it.
const Candidates = [
  { press: "F7", command: "editor.action.wordHighlight.next",
    init: { key: "F7", code: "F7" } },
  { press: "Shift+F7", command: "editor.action.wordHighlight.prev",
    init: { key: "F7", code: "F7", shiftKey: true } },
];

async function caretOnRepeatedWord(page: any) {
  // Word-highlight navigation moves between the occurrences of the word
  // under the caret, so the caret goes on the first occurrence of a word the
  // file holds more than once; Monaco highlights them after a short delay.
  const placed = await page.evaluate(() => {
    const m = (globalThis as any).monaco;
    const ed = m.editor.getEditors().find((e: any) => e.hasTextFocus());
    if (!ed) return false;
    const model = ed.getModel();
    const counts = new Map<string, number>();
    for (const w of model.getValue().match(/[A-Za-z_][A-Za-z0-9_]{2,}/g) ?? []) {
      counts.set(w, (counts.get(w) ?? 0) + 1);
    }
    for (let n = 1; n <= model.getLineCount(); n++) {
      const text = model.getLineContent(n);
      const re = /[A-Za-z_][A-Za-z0-9_]{2,}/g;
      let hit;
      while ((hit = re.exec(text)) !== null) {
        if ((counts.get(hit[0]) ?? 0) >= 2) {
          ed.setPosition({ lineNumber: n, column: hit.index + 2 });
          ed.revealLine(n);
          return true;
        }
      }
    }
    return false;
  });
  expect(placed, "a word the file holds twice").toBe(true);
  await page.waitForTimeout(1_000);
}

async function caretInEditor(page: any) {
  // A REAL click, because what these tests exercise is real input — but on a
  // point the editor actually shows.  A `.view-line` is as wide as the
  // file's longest line (6575 px for `calc/main.py` in a 455 px editor), so
  // its centre, where `locator.click()` aims by default, lies far outside the
  // editor's visible content box; Playwright then reported whatever covered
  // that point (the State pane's watch field, its Globals tab, the gutter)
  // as intercepting the click, and every test died here.  The point used is
  // just inside the left edge of a line's intersection with its editor's
  // `.monaco-scrollable-element` (the content area, right of the gutter),
  // vertically centred, given relative to the line as `click` takes it.
  //
  // Waits for such a line rather than taking the first `.view-line` as it
  // is: right after launch the editor may not have laid out yet, and Monaco
  // keeps line nodes in DOM order, not screen order.
  const target = await page.waitForFunction(() => {
    const lines = Array.from(
      document.querySelectorAll(".monaco-editor .view-lines > .view-line"),
    ) as HTMLElement[];
    for (let index = 0; index < lines.length; index++) {
      const lineBox = lines[index].getBoundingClientRect();
      const content = lines[index].closest(".monaco-editor")
        ?.querySelector(".monaco-scrollable-element")
        ?.getBoundingClientRect();
      if (!content) continue;
      const left = Math.max(lineBox.left, content.left);
      const right = Math.min(lineBox.right, content.right);
      const top = Math.max(lineBox.top, content.top);
      const bottom = Math.min(lineBox.bottom, content.bottom);
      // Whole line height inside the content box, and room to click.
      if (right - left < 2 || bottom - top < lineBox.height - 0.5) continue;
      return {
        index,
        x: left + Math.min(8, (right - left) / 2) - lineBox.left,
        y: (top + bottom) / 2 - lineBox.top,
      };
    }
    return null;
  }, undefined, { timeout: 120_000 });
  const { index, x, y } = await target.jsonValue();
  await page
    .locator(".monaco-editor .view-lines > .view-line")
    .nth(index)
    .click({ position: { x, y } });
  await page.waitForFunction(() => {
    const a = document.activeElement as HTMLElement | null;
    return !!a && !!a.closest("[data-scope-kind='editor']");
  }, undefined, { timeout: 20_000 });
}

async function selections(page: any): Promise<string> {
  return page.evaluate(() => {
    const m = (globalThis as any).monaco;
    const ed = m.editor.getEditors().find((e: any) => e.hasTextFocus());
    return ed ? JSON.stringify(ed.getSelections()) : "no focused editor";
  });
}

async function setSelections(page: any, json: string) {
  await page.evaluate((s: string) => {
    const m = (globalThis as any).monaco;
    const ed = m.editor.getEditors().find((e: any) => e.hasTextFocus());
    ed.setSelections(JSON.parse(s));
  }, json);
}

async function trigger(page: any, command: string) {
  await page.evaluate((c: string) => {
    const m = (globalThis as any).monaco;
    const ed = m.editor.getEditors().find((e: any) => e.hasTextFocus());
    ed.trigger("keyboard", c, null);
  }, command);
}

test.setTimeout(300_000);

test.describe("a shortcut no keymap binds is not Monaco's either", () => {
  test.use({
    sourcePath: recording("calc"),
    launchMode: "trace-folder",
    codetracerPrefixOverride: prefix,
  });

  test("Monaco's stock shortcuts do nothing the router did not run", async ({ ctPage }) => {
    await ctPage.waitForSelector(".calltrace-view .call-text", { timeout: 120_000 });
    await caretInEditor(ctPage);
    await caretOnRepeatedWord(ctPage);
    const probe = await ctPage.evaluate((req: string) =>
      (globalThis as any).__ctKeymapProbe(req),
      JSON.stringify({ base: "cua", keybindings: "[]",
                       events: Candidates.map((c) => c.init) }));
    const answers: string[] = JSON.parse(probe).answers;
    let exercised = 0;
    for (let i = 0; i < Candidates.length; i++) {
      const c = Candidates[i];
      if (!/->\s*(nothing|none|unbound)/i.test(answers[i])) continue;
      const before = await selections(ctPage);
      // CONTROL: Monaco's own command changes the selections from here.
      await trigger(ctPage, c.command);
      const byCommand = await selections(ctPage);
      await setSelections(ctPage, before);
      if (byCommand === before) continue;
      await ctPage.evaluate(() => { (globalThis as any).__ctKeyTrace = []; });
      await ctPage.keyboard.press(c.press);
      await ctPage.waitForTimeout(500);
      expect(await selections(ctPage), `${c.press} (${answers[i]})`).toBe(before);
      expect(await ctPage.evaluate(() =>
        ((globalThis as any).__ctKeyTrace ?? []).length)).toBe(0);
      exercised++;
    }
    expect(exercised, `probe answered: ${answers.join("; ")}`).toBeGreaterThan(0);
  });
});
