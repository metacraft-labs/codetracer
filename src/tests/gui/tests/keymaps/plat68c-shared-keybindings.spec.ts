/**
 * plat68c-shared-keybindings.spec.ts — the desktop's half of "one
 * configuration, three front-ends" (Base-Keymaps-And-Layer-Stack.md §3.5).
 *
 * `ci/test/plat68-one-keymap-three-front-ends.sh` writes ONE
 * `keybindings.json`, runs the terminal's and GPUI's halves over it
 * (`ci/test/plat68_one_keymap_probe.nim`), then this spec over the SAME file
 * (`PLAT68_SHARED_KEYBINDINGS`, handed to the app as
 * `CODETRACER_KEYBINDINGS`), and compares the three answers. The file
 * carries a PANE-SCOPED row — Step Over on `Ctrl+Alt+J` only while a list
 * pane has the focus (`when: listFocus`) — and removes the base's `F10` →
 * Step Over.
 *
 * On the `calc` recording from its start, through real KeyboardEvents: the
 * execution line; `Ctrl+Alt+J` with the caret in the editor — out of the
 * row's scope, so the debugger stays; `Alt+C` to the call trace, then
 * `F10` — removed, so the debugger stays; `Ctrl+Alt+J` — one step. The answer is
 * appended to `PLAT68_SHARED_RESULTS` as one JSON line. Run alone (no shared
 * file named), it writes the same rows to a file of its own and asserts the
 * same behaviour.
 *
 * No mocks: the real app, the real `ct`, a real engine, a real file.
 */

import * as fs from "fs";
import * as os from "os";
import * as path from "path";

import { expect } from "@playwright/test";
import { test } from "../../lib/fixtures";

const repoRoot = path.resolve(__dirname, "..", "..", "..", "..", "..");
const prefix = process.env.PLAT68_DESKTOP_PREFIX ?? "";

const SharedRows = `// one keymap for every front-end
[
  { "key": "ctrl+alt+j", "command": "debugger.step-over", "when": "listFocus" },
  { "key": "f10", "command": "-debugger.step-over" },
]
`;

const shared = process.env.PLAT68_SHARED_KEYBINDINGS ?? (() => {
  const d = fs.mkdtempSync(path.join(os.tmpdir(), "plat68c-shared-"));
  fs.writeFileSync(path.join(d, "keybindings.json"), SharedRows);
  return path.join(d, "keybindings.json");
})();
const results = process.env.PLAT68_SHARED_RESULTS ??
  path.join(path.dirname(shared), "results.jsonl");
// The app reads the file this names (`viewmodel/host/keybindings_location`);
// the Electron child inherits this process's environment.
process.env.CODETRACER_KEYBINDINGS = shared;

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

async function line(page: any): Promise<number> {
  return page.evaluate(() =>
    Number((globalThis as any).data?.services?.debugger?.location?.line ?? -1));
}

async function settled(page: any): Promise<number> {
  // The line once it has not moved for three seconds (a step's answer can
  // take seconds on a loaded host).
  let last = await line(page);
  let stable = 0;
  for (let i = 0; i < 90; i++) {
    await page.waitForTimeout(1_000);
    const now = await line(page);
    if (now === last && now > 0) {
      if (++stable >= 3) return now;
    } else {
      stable = 0;
    }
    last = now;
  }
  return last;
}

async function keyTrace(page: any): Promise<string[]> {
  return page.evaluate(() => ((globalThis as any).__ctKeyTrace ?? []).slice());
}

test.setTimeout(300_000);

test.describe("one keybindings.json: the desktop's answer", () => {
  test.use({
    sourcePath: recording("calc"),
    launchMode: "trace-folder",
    codetracerPrefixOverride: prefix,
  });

  test("Ctrl+Alt+J steps only in a list pane; the removed F10 steps nothing", async ({ ctPage }) => {
    await ctPage.waitForSelector(".calltrace-view .call-text", { timeout: 120_000 });
    // The file arrives from the main process after start-up.
    await ctPage.waitForTimeout(2_500);
    const start = await settled(ctPage);
    await ctPage.evaluate(() => { (globalThis as any).__ctKeyTrace = []; });
    // The caret in the editor (a press on its first line): out of scope.
    await ctPage.locator(".monaco-editor .view-line").first().click({ position: { x: 4, y: 4 } });
    await ctPage.keyboard.press("Control+Alt+KeyJ");
    const afterOutside = await settled(ctPage);
    // `Alt+C` (CUA's `layout.focus-pane(call-trace)`) focuses that pane. (A
    // press on its tab activates the tab but leaves the DOM focus where it
    // was.)
    await ctPage.keyboard.press("Alt+KeyC");
    await ctPage.waitForFunction(() => {
      const a = document.activeElement as HTMLElement | null;
      return !!a && !!a.closest("[data-scope-kind='pane'][data-scope-id='calltrace']");
    }, undefined, { timeout: 20_000 });
    await ctPage.keyboard.press("F10");
    const afterRemoved = await settled(ctPage);
    await ctPage.keyboard.press("Control+Alt+KeyJ");
    const afterRebound = await settled(ctPage);
    const trace = await keyTrace(ctPage);
    const answer = { frontEnd: "desktop", start, afterOutside, afterRemoved, afterRebound };
    fs.appendFileSync(results, JSON.stringify(answer) + "\n");
    console.log("answer", JSON.stringify(answer), "trace", JSON.stringify(trace));
    // The router ran the user's row once — in the call trace — and nothing
    // for the out-of-scope chord or the removed F10.
    expect(trace).toEqual(["layout.focus-pane(call-trace)", "debugger.step-over"]);
    expect(start).toBeGreaterThan(0);
    expect(afterOutside).toBe(start);
    expect(afterRemoved).toBe(start);
    expect(afterRebound).not.toBe(start);
  });
});
