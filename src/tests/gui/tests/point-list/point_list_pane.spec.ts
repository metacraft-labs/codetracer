/**
 * point_list_pane.spec.ts — PLAT-40. The desktop's Breakpoints & Tracepoints
 * pane, opened the way a user opens it, fed by the engine's verdict.
 *
 * Until 2026-09-23 this pane could not exist on the desktop: its
 * `makeComponent` arm was commented out (constructing it raised) and its menu
 * entry was commented out (so nothing reached the raise). It now draws the
 * ViewModel session's `PointListVM` — `store.pointList.rows`, the rows the
 * native front-ends read — and a breakpoint reaches those rows through ONE
 * decoder on every runtime: `ReplayDataStore.applyVerifiedBreakpoints`, fed
 * here by the debugger service's `setBreakpoints` ANSWER, so a row is the line
 * the engine bound.
 *
 * What is asserted, through the product's own routes (a real gutter click,
 * the real View menu, the pane's own DOM):
 *
 *   1. a breakpoint set BEFORE the pane opens is a row once it opens;
 *   2. a breakpoint set AFTER the pane is open appears in it — the pane's
 *      rows are a `for` in an isonim `ui:` block, which runs ONCE; before the
 *      mount was put under an effect the second row never appeared;
 *   3. toggling the first breakpoint off removes exactly its row — the
 *      negative half, which a pane that only ever appends would fail.
 *
 * No mocks: the Electron app, a real recording, a real replay engine.
 */
import * as fs from "node:fs";
import * as path from "node:path";

import { test, expect, readyOnEntryTest as readyOnEntry } from "../../lib/fixtures";

const repoRoot = path.resolve(__dirname, "../../../../..");

/**
 * The `noir_space_ship` recording the product's own `ct record` made for the
 * terminal lanes (`test-logs/tui-fixtures/`), opened as a trace FOLDER — the
 * PLAT-35 capture's arrangement. Recording it afresh here would tie this test
 * to the Noir toolchain's trace-format version, which is not what it is about.
 * FAILS, rather than skipping, when the recording is absent.
 */
function noirRecording(): string {
  const cache = path.join(repoRoot, "test-logs", "tui-fixtures");
  const hits = fs.existsSync(cache)
    ? fs.readdirSync(cache).filter((e) => e.startsWith("noir_space_ship-")).sort()
    : [];
  if (hits.length === 0) {
    throw new Error(
      "PLAT-40: the 'noir_space_ship' recording is not in test-logs/tui-fixtures/; " +
        "run 'just test-tui' once to record it.",
    );
  }
  return path.join(cache, hits[hits.length - 1]);
}

test.use({ sourcePath: noirRecording(), launchMode: "trace-folder" });
test.setTimeout(300_000);

/** Two lines that ran in `noir_space_ship`'s `calculate_damage`. */
const FIRST = 26;
const SECOND = 34;

async function toggleBreakpoint(page: any, line: number): Promise<void> {
  const coords = await page.evaluate((lineNumber: number) => {
    const gutter = document.querySelector(
      `.monaco-editor .margin-view-overlays .gutter[data-line='${lineNumber}']`,
    );
    if (!gutter) return null;
    const r = gutter.getBoundingClientRect();
    if (r.height === 0) return null;
    return { x: r.left + r.width / 2, y: r.top + r.height / 2 };
  }, line);
  if (!coords) {
    throw new Error(`gutter row for line ${line} is not laid out`);
  }
  await page.mouse.click(coords.x, coords.y);
}

async function openPointList(page: any): Promise<void> {
  // The in-app menu, as a user reaches it: the menu root, then View, then
  // the entry. `.menu-element-*` is the menu's own class for an element.
  if (!(await page.locator("#menu-main").isVisible())) {
    await page.locator("#menu-root").click();
  }
  await page.locator(".menu-folder-view").hover();
  await page.locator(".menu-element-breakpoints-tracepoints").click();
}

async function paneRows(page: any): Promise<string[]> {
  return page.$$eval(
    ".point-list-component .point-list-row",
    (rows: Element[]) =>
      rows.map(
        (r) =>
          `${r.querySelector(".point-list-kind")?.textContent ?? ""}@` +
          `${r.querySelector(".point-list-location")?.textContent ?? ""}`,
      ),
  );
}

const lineOf = (row: string): number => {
  const m = /:(\d+)$/.exec(row);
  return m ? Number(m[1]) : -1;
};

test("a breakpoint is a row of the Point List, as the engine verified it", async ({
  ctPage,
}) => {
  await readyOnEntry(ctPage);
  await ctPage.waitForSelector(".view-line", { timeout: 90_000 });

  // 1. Set BEFORE the pane exists.
  await toggleBreakpoint(ctPage, FIRST);
  await openPointList(ctPage);
  await expect(ctPage.locator(".point-list-component")).toBeVisible({
    timeout: 60_000,
  });
  await expect
    .poll(async () => (await paneRows(ctPage)).map(lineOf), { timeout: 60_000 })
    .toEqual([FIRST]);
  const first = await paneRows(ctPage);
  expect(first[0].startsWith("breakpoint@"), `row: ${first[0]}`).toBe(true);

  // 2. Set AFTER the pane is open: it must update.
  await toggleBreakpoint(ctPage, SECOND);
  await expect
    .poll(async () => (await paneRows(ctPage)).map(lineOf).sort((a, b) => a - b), {
      timeout: 60_000,
    })
    .toEqual([FIRST, SECOND]);

  // 3. Toggle the first OFF: exactly its row goes.
  await toggleBreakpoint(ctPage, FIRST);
  await expect
    .poll(async () => (await paneRows(ctPage)).map(lineOf), { timeout: 60_000 })
    .toEqual([SECOND]);
});
