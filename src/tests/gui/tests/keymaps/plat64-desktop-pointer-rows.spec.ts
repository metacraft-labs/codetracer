/**
 * plat64-desktop-pointer-rows.spec.ts — on the desktop a press on a pane's
 * element is the pointer keymap's row (Input-Routing-And-Keymaps.md §5.1),
 * performed by the desktop's procedure on the element pressed
 * (`viewmodel/input/dom_pointer`, `dom_pane_presses`), as on the terminal and
 * in the GPUI window. The panes' views hold no click handler of their own.
 *
 * On the `calc` recording, through real mouse events into the Electron window:
 *
 *   * a press on a call's text runs `calltrace.go-to-call` (the debugger goes
 *     to that call), on its toggle `calltrace.toggle-call` (its children show),
 *     on an Event Log column's header `event-log.sort`, on an event's row
 *     `event-log.jump` — each read off
 *     `window.__ctKeyTrace`, every operation the router ran, beside the
 *     product's own state;
 *   * with a user's `keybindings.json` that REMOVES the base's row for a press
 *     on a call (`-calltrace.go-to-call`), the same press runs nothing and the
 *     debugger stays: the row is what performs it, not the view.
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

function keybindingsFile(rows: string): string {
  const d = fs.mkdtempSync(path.join(os.tmpdir(), "plat64-pointer-rows-"));
  const f = path.join(d, "keybindings.json");
  fs.writeFileSync(f, rows);
  return f;
}

/** Points `CODETRACER_KEYBINDINGS` at `file` for one describe's tests. */
function useKeybindings(file: string) {
  let before: string | undefined;
  test.beforeAll(() => {
    before = process.env.CODETRACER_KEYBINDINGS;
    process.env.CODETRACER_KEYBINDINGS = file;
  });
  test.afterAll(() => {
    if (before === undefined) delete process.env.CODETRACER_KEYBINDINGS;
    else process.env.CODETRACER_KEYBINDINGS = before;
  });
}

async function line(page: any): Promise<number> {
  return page.evaluate(() =>
    Number((globalThis as any).data?.services?.debugger?.location?.line ?? -1));
}

async function settled(page: any): Promise<number> {
  // The line once it has not moved for three seconds (a move's answer can
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

async function clearTrace(page: any) {
  await page.evaluate(() => { (globalThis as any).__ctKeyTrace = []; });
}

/** A call's text whose call is not where the debugger is: the last one shown. */
async function otherCall(page: any) {
  const calls = page.locator(".calltrace-view .call-text");
  await expect(calls.first()).toBeVisible({ timeout: 120_000 });
  return calls.last();
}

test.setTimeout(300_000);

test.describe("the desktop's presses are the pointer keymap's rows", () => {
  useKeybindings(keybindingsFile("[]\n"));
  test.use({
    sourcePath: recording("calc"),
    launchMode: "trace-folder",
    codetracerPrefixOverride: prefix,
  });

  test("a press on a call, its toggle and a column header runs each element's row", async ({ ctPage }) => {
    await ctPage.waitForSelector(".calltrace-view .call-text", { timeout: 120_000 });
    await ctPage.waitForTimeout(2_500);
    const start = await settled(ctPage);

    await clearTrace(ctPage);
    await (await otherCall(ctPage)).click();
    const afterCall = await settled(ctPage);
    expect(await keyTrace(ctPage)).toEqual(["calltrace.go-to-call"]);
    expect(afterCall).not.toBe(start);

    const toggle = ctPage.locator(".calltrace-view .toggle-call[role=\"button\"]").first();
    await expect(toggle).toBeVisible({ timeout: 30_000 });
    const before = await toggle.getAttribute("aria-expanded");
    await clearTrace(ctPage);
    await toggle.click();
    await expect.poll(() => toggle.getAttribute("aria-expanded"), { timeout: 30_000 })
      .not.toBe(before);
    expect(await keyTrace(ctPage)).toEqual(["calltrace.toggle-call"]);

    const header = ctPage.locator(".eventLog-column-header [data-column]").first();
    await expect(header).toBeVisible({ timeout: 30_000 });
    await clearTrace(ctPage);
    await header.click();
    await expect.poll(() => keyTrace(ctPage), { timeout: 30_000 })
      .toEqual(["event-log.sort"]);

    // An event's row: the Event Log's row runs `event-log.jump`.
    const event = ctPage.locator(".eventLog-row[data-position]").last();
    await expect(event).toBeVisible({ timeout: 30_000 });
    await clearTrace(ctPage);
    await event.click();
    await expect.poll(() => keyTrace(ctPage), { timeout: 30_000 })
      .toEqual(["event-log.jump"]);
  });
});

test.describe("a user's row that removes the base's leaves the press with nothing to run", () => {
  useKeybindings(keybindingsFile(`[
  { "key": "click", "command": "-calltrace.go-to-call",
    "when": "paneKind == calltrace && elementKind == row" }
]
`));
  test.use({
    sourcePath: recording("calc"),
    launchMode: "trace-folder",
    codetracerPrefixOverride: prefix,
  });

  test("a press on a call does not go to it", async ({ ctPage }) => {
    await ctPage.waitForSelector(".calltrace-view .call-text", { timeout: 120_000 });
    await ctPage.waitForTimeout(2_500);
    const start = await settled(ctPage);
    await clearTrace(ctPage);
    await (await otherCall(ctPage)).click();
    const after = await settled(ctPage);
    expect(await keyTrace(ctPage)).toEqual([]);
    expect(after).toBe(start);
  });
});
