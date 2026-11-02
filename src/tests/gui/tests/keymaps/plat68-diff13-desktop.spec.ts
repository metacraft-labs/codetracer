/**
 * plat68-diff13-desktop.spec.ts — PLAT-68 DIFF-13 (Base-Keymaps KL-6), the
 * desktop's column: the REAL Electron front-end, on the `calc` recording
 * with a real engine, is held to the same answers as the terminal and GPUI.
 *
 * `diff13/answers-<base>.json` are the population `src/frontend/tui/tests/
 * test_plat68_diff13.nim` derives from the four bases' tables (and asserts is
 * current): per situation and base, with and without the population's
 * `keybindings.json`, every key's `KeyboardEvent` fields on a US layout and
 * the shared router's resolution for the declared scope path under the
 * desktop's delivery. Both halves of the gate are asserted here:
 *
 *   * the SCOPE PATH the desktop's own producer reads off the DOM focus chain
 *     (`ui/key_router.desktopScopePath`) equals the situation's declared one;
 *   * every key, built as a real `KeyboardEvent` and named by the listener's
 *     own decoder (`canonicalKeyOfEvent` → `key_event_names`), resolves as
 *     declared, through a COPY of the live router (`window.__ctKeymapProbe`,
 *     the desktop's counterpart of GPUI's `--window-ops=probe:`), with this
 *     renderer's own facts (`desktopFacts`).
 *
 * THE DRIVER, not the product: the event fields (a keyboard's part), and how
 * each situation is reached — a real click in the editor, `Ctrl+P` and
 * `Ctrl+E` as real key presses, and a list pane focused by `focus()` on its
 * scope element (a click on one of its rows would also run the row).
 * No mocks: the real app, the real `ct`, a real engine.
 */

import * as fs from "fs";
import * as path from "path";

import { expect } from "@playwright/test";
import { test } from "../../lib/fixtures";

const repoRoot = path.resolve(__dirname, "..", "..", "..", "..", "..");
const prefix = process.env.PLAT68_DESKTOP_PREFIX ?? "";
// One file per base (`diff13/answers-<base>.json`); the situations and the
// population's `keybindings.json` are the same in all four.
const answerFiles = ["cua", "emacs", "vim", "kakoune"].map((b) => JSON.parse(
  fs.readFileSync(path.join(__dirname, "diff13", `answers-${b}.json`), "utf8")));
const answers = {
  keybindings: answerFiles[0].keybindings,
  situations: answerFiles[0].situations,
  probes: answerFiles.flatMap((f: any) =>
    f.probes.map((p: any) => ({ ...p, base: f.base }))),
};

function recording(prefixName: string): string {
  const cache = process.env.PLAT68_FIXTURES_DIR ??
    path.join(repoRoot, "test-logs", "tui-fixtures");
  const hits = fs.existsSync(cache)
    ? fs.readdirSync(cache).filter((e) => e.startsWith(prefixName + "-")).sort()
    : [];
  if (hits.length === 0) {
    throw new Error(
      `DIFF-13: the '${prefixName}' recording is not in test-logs/tui-fixtures/; ` +
        "run the tui lane once (its fixture provider records it).",
    );
  }
  return path.join(cache, hits[hits.length - 1]);
}

function normalised(p: string): string {
  return p.split(" / ").map((e) =>
    e.startsWith("editor:editor:") ? "editor:editor:<source>" : e).join(" / ");
}

async function caretInEditor(page: any) {
  // A real click inside a line's visible content (see
  // plat68b-desktop-keys.spec.ts for why the centre of a `.view-line` is not).
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
  await page.locator(".monaco-editor .view-lines > .view-line").nth(index)
    .click({ position: { x, y } });
  await page.waitForFunction(() => {
    const a = document.activeElement as HTMLElement | null;
    return !!a && !!a.closest("[data-scope-kind='editor']");
  }, undefined, { timeout: 20_000 });
}

async function focusPane(page: any, kind: string) {
  await page.evaluate((k: string) => {
    const el = document.querySelector(
      `[data-scope-kind='pane'][data-scope-id='${k}']`) as HTMLElement | null;
    if (!el) throw new Error(`no pane '${k}' in the layout`);
    el.focus();
  }, kind);
}

async function reach(page: any, recipe: string) {
  await page.keyboard.press("Escape");
  switch (recipe) {
    case "editor":
      await caretInEditor(page);
      break;
    case "calltrace":
    case "state":
    case "eventLog":
      await focusPane(page, recipe);
      break;
    case "palette":
      await caretInEditor(page);
      await page.keyboard.press("Control+Shift+KeyP");   // CUA: palette.open-commands
      await page.waitForFunction(
        () => !!(globalThis as any).data?.ui?.commandPalette?.active,
        undefined, { timeout: 20_000 });
      break;
    case "writable":
      await caretInEditor(page);
      await page.keyboard.press("Control+KeyE");
      await page.waitForFunction(
        () => (globalThis as any).data?.ui?.readOnly === false,
        undefined, { timeout: 20_000 });
      break;
    default:
      throw new Error(`no recipe '${recipe}'`);
  }
}

async function leave(page: any, recipe: string) {
  if (recipe === "palette") await page.keyboard.press("Escape");
  if (recipe === "writable") {
    await caretInEditor(page);
    await page.keyboard.press("Control+KeyE");
  }
}

test.setTimeout(900_000);

test.describe("PLAT-68 DIFF-13: the desktop answers every key as the rule does", () => {
  test.use({
    sourcePath: recording("calc"),
    launchMode: "trace-folder",
    codetracerPrefixOverride: prefix,
  });

  test("every situation's path and every key's resolution", async ({ ctPage }) => {
    await ctPage.waitForSelector(".calltrace-view .call-text", { timeout: 120_000 });
    const failures: string[] = [];
    let compared = 0;
    let wrong = 0;
    const tally = new Map<string, number>();
    for (let si = 0; si < answers.situations.length; si++) {
      const s = answers.situations[si];
      await reach(ctPage, s.desktop);
      const groups = new Map<string, any[]>();
      for (const p of answers.probes) {
        if (p.situation !== si) continue;
        const k = `${p.base}|${p.user}`;
        if (!groups.has(k)) groups.set(k, []);
        groups.get(k)!.push(p);
      }
      for (const [k, probes] of groups) {
        const [base, user] = k.split("|");
        const reply = JSON.parse(await ctPage.evaluate(
          (req: string) => (globalThis as any).__ctKeymapProbe(req),
          JSON.stringify({
            base,
            keybindings: user === "true" ? answers.keybindings : "",
            events: probes.map((p: any) => ({
              key: p.key, code: p.code, ctrlKey: p.ctrlKey,
              shiftKey: p.shiftKey, altKey: p.altKey, metaKey: p.metaKey,
            })),
          })));
        if (normalised(reply.path) !== s.path) {
          failures.push(`${s.name} (${k}): desktop path ${reply.path}; declared ${s.path}`);
        }
        probes.forEach((p: any, i: number) => {
          compared++;
          const want = `${p.chord} -> ${p.expected}`;
          if (reply.answers[i] !== want) {
            wrong++;
            const t = `${s.name} (${k})`;
            tally.set(t, (tally.get(t) ?? 0) + 1);
            if (wrong <= 40) {
              failures.push(`${s.name} (${k}): ${reply.answers[i]}; the rule: ${want}`);
            }
          }
        });
      }
      await leave(ctPage, s.desktop);
    }
    console.log(`DIFF-13 desktop: ${compared} keys compared, ${wrong} differ`);
    for (const [t, n] of tally) console.log(`  ${n} differ in ${t}`);
    expect(compared).toBe(answers.probes.length);
    expect(failures).toEqual([]);
    expect(wrong).toBe(0);
  });
});
