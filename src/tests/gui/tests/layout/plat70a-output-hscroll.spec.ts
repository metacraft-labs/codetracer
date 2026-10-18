/**
 * plat70a-output-hscroll.spec.ts — PLAT-70 Part A (Horizontal-Overflow.md
 * §4), the desktop's column: the OUTPUT panes' overflow-only horizontal bar,
 * the shared scrubber model on the column axis (`views/list_scrubber_dom
 * .attachHorizontalScrubber`), in the real Electron app on a real recording
 * of `test-programs/wide_lines` (a line far wider than any pane):
 *
 *   * the Terminal Output's LINE view: the bar exists (the line is wider than
 *     the pane), its thumb is `viewport / content` of the track (20 px at
 *     least), the browser's real horizontal wheel and Shift + wheel scroll it,
 *     a press on the track centres the column under it, a held thumb follows
 *     the pointer, the corner where it meets the vertical scrubber belongs to
 *     neither, CUA's `ArrowRight` / `ArrowLeft` move the view by six columns
 *     (`view.scroll-right` / `-left`, through the key router) — and none of it
 *     moves the debugger (HO-4);
 *   * Build Output: its lines are no longer wrapped, and a line wider than the
 *     pane gets the same bar;
 *   * the editor is untouched: it keeps Monaco's own bar (OQ-H2).
 *
 * THE ONE STAND-IN, AND WHY IT IS NOT A MOCK: Build Output's line reaches
 * the renderer as the main process's `CODETRACER::build-command` /
 * `build-stdout` / `build-code` messages, sent from the real Electron main
 * process by this spec — a Python recording has no build to run, and the
 * renderer path those messages take (`onBuildStdout` → the BuildVM → the
 * IsoNim view) is the product's own, unchanged.
 *
 * No mocks otherwise: a real `.ct` recording, the real `ct`, a real
 * `replay-server`, the real Electron app, real wheel and pointer events.
 */

import * as fs from "fs";
import * as path from "path";

import { expect } from "@playwright/test";
import { test } from "../../lib/fixtures";
import { openBottomPanel, waitForDefaultBottomTabs } from "../../page-objects/auto-hide-strip";

const repoRoot = path.resolve(__dirname, "..", "..", "..", "..", "..");

function recording(prefix: string): string {
  const cache = path.join(repoRoot, "test-logs", "tui-fixtures");
  const hits = fs.existsSync(cache)
    ? fs.readdirSync(cache).filter((e) => e.startsWith(prefix + "-")).sort()
    : [];
  if (hits.length === 0) {
    throw new Error(
      `PLAT-70: the '${prefix}' recording is not in test-logs/tui-fixtures/; ` +
        "the tui-real-terminal lane's test_plat70a_hscroll_pty.nim records it.",
    );
  }
  return path.join(cache, hits[hits.length - 1]);
}

const OUTPUT_LINE =
  "<<LEFT-EDGE>> the quick brown fox jumps over the lazy dog, 0123456789 " +
  "the quick brown fox jumps over the lazy dog, 0123456789 the quick brown " +
  "fox jumps over the lazy dog, 0123456789 the quick brown fox jumps over " +
  "the lazy dog, 0123456789 <<RIGHT-EDGE>>";

const prefix = process.env.PLAT70_DESKTOP_PREFIX ?? "";

test.setTimeout(400_000);

function where(page: any) {
  return page.evaluate(() => {
    const loc = (globalThis as any).data?.services?.debugger?.location;
    return { line: loc?.line ?? -1, ticks: Number(loc?.rrTicks ?? -1) };
  });
}

async function showTerminal(page: any) {
  const title = page.locator(".lm_tab[title='TERMINAL OUTPUT'] .lm_title").first();
  await title.waitFor({ state: "visible", timeout: 120_000 });
  const content = page.locator(".isonim-terminal-output pre .terminal-line").first();
  for (let attempt = 0; attempt < 5; attempt++) {
    await title.click();
    try {
      await content.waitFor({ state: "visible", timeout: 10_000 });
      break;
    } catch {
      // pressed again
    }
  }
  await content.waitFor({ state: "visible", timeout: 60_000 });
  await page.waitForTimeout(800);
}

/** The model's track click, restated from the specification (§4.2, HO-3). */
function clickedLeft(content: number, view: number, fraction: number): number {
  if (content <= view) return 0;
  const col = Math.round(fraction * (content - 1));
  return Math.max(0, Math.min(content - view, col - Math.floor(view / 2)));
}

function trackFraction(pos: number, units: number): number {
  return units <= 1 ? 0 : Math.max(0, Math.min(1, pos / (units - 1)));
}

async function barState(page: any, sel: string) {
  return page.evaluate((selector: string) => {
    const track = document.querySelector(selector) as HTMLElement | null;
    if (!track || track.style.display === "none") return null;
    const thumb = track.querySelector(".ct-hscrubber-thumb") as HTMLElement;
    const r = track.getBoundingClientRect();
    return {
      content: Number(track.getAttribute("data-ct-hscrub-content")),
      viewport: Number(track.getAttribute("data-ct-hscrub-viewport")),
      left: Number(track.getAttribute("data-ct-hscrub-left")),
      thumbPx: Number(thumb.getAttribute("data-ct-thumb-px")),
      thumbLeft: Number(thumb.getAttribute("data-ct-thumb-left")),
      x: r.left, y: r.top, w: r.width, h: r.height,
    };
  }, sel);
}

function scrollLeftOf(page: any, sel: string): Promise<number> {
  return page.evaluate((s: string) => {
    const el = document.querySelector(s) as HTMLElement | null;
    return el ? el.scrollLeft : -1;
  }, sel);
}

test.describe("PLAT-70 Part A: the desktop's output panes scroll sideways", () => {
  test.use({
    sourcePath: recording("wide_lines"),
    launchMode: "trace-folder",
    noUserLayout: true,
    ...(prefix ? { codetracerPrefixOverride: prefix } : {}),
  });

  test("Terminal Output: the bar, the wheels, the track, the thumb, the keys", async ({ ctPage }) => {
    const page = ctPage;
    await page.waitForSelector(".calltrace-view .call-text", { timeout: 120_000 });
    await showTerminal(page);
    const pre = ".isonim-terminal-output > pre";
    const barSel = "[data-ct-hscrubber='terminalOutput']";
    const start = await where(page);

    // THE LINE IS THE PROGRAM'S, AND IT IS WIDER THAN THE PANE: the bar.
    const first = await page.locator(".isonim-terminal-output pre .terminal-line").first().textContent();
    expect((first ?? "").trim()).toBe(OUTPUT_LINE);
    await expect(page.locator(barSel)).toBeVisible();
    const rest = await barState(page, barSel);
    expect(rest).not.toBeNull();
    expect(rest!.content).toBeGreaterThan(rest!.viewport);
    expect(rest!.left).toBe(0);
    expect(rest!.thumbPx).toBe(
      Math.min(Math.round(rest!.w), Math.max(20, Math.round((rest!.w * rest!.viewport) / rest!.content))));

    // THE CORNER (HO-7): the vertical scrubber stops above the bar, and the
    // bar stops left of the vertical track.
    const corner = await page.evaluate(() => {
      const v = document.querySelector("[data-ct-list-scrubber='terminalOutput']")!.getBoundingClientRect();
      const h = document.querySelector("[data-ct-hscrubber='terminalOutput']")!.getBoundingClientRect();
      return { vBottom: v.bottom, vLeft: v.left, hTop: h.top, hRight: h.right };
    });
    expect(corner.vBottom).toBeLessThanOrEqual(corner.hTop + 0.5);
    expect(corner.hRight).toBeLessThanOrEqual(corner.vLeft + 0.5);

    // THE BROWSER'S HORIZONTAL WHEEL, then Shift + the vertical wheel.
    const box = await page.locator(pre).boundingBox();
    await page.mouse.move(box!.x + 40, box!.y + 10);
    await page.mouse.wheel(120, 0);
    await expect.poll(() => scrollLeftOf(page, pre)).toBeGreaterThan(0);
    await page.mouse.wheel(-400, 0);
    await expect.poll(() => scrollLeftOf(page, pre)).toBe(0);
    await page.keyboard.down("Shift");
    await page.mouse.wheel(0, 120);
    await page.keyboard.up("Shift");
    await expect.poll(() => scrollLeftOf(page, pre)).toBeGreaterThan(0);
    // The bar follows the view.
    await expect.poll(async () => (await barState(page, barSel))!.left).toBeGreaterThan(0);
    await page.mouse.wheel(-400, 0);
    await expect.poll(() => scrollLeftOf(page, pre)).toBe(0);

    // A PRESS ON THE TRACK centres the column under it (the scrubber rule,
    // not the platform's page step).
    const b = (await barState(page, barSel))!;
    const at = Math.floor(b.w * 0.8);
    await page.mouse.click(b.x + at, b.y + b.h / 2);
    const want = clickedLeft(b.content, b.viewport, trackFraction(at, Math.round(b.w)));
    await expect.poll(() => scrollLeftOf(page, pre)).toBeGreaterThan(0);
    expect(Math.abs((await scrollLeftOf(page, pre)) - want)).toBeLessThanOrEqual(1);

    // A HELD THUMB follows the pointer back to the start.
    const held = (await barState(page, barSel))!;
    await page.mouse.move(held.x + held.thumbLeft + held.thumbPx / 2, held.y + held.h / 2);
    await page.mouse.down();
    await page.mouse.move(held.x + 2, held.y + held.h / 2, { steps: 8 });
    await page.mouse.up();
    await expect.poll(() => scrollLeftOf(page, pre)).toBeLessThan(want);

    // THE VIEW KEYS (CUA `Right` / `Left`), in the focused line view.
    await page.evaluate((s: string) => {
      (document.querySelector(s) as HTMLElement).scrollLeft = 0;
      const pane = document.querySelector("[data-scope-kind='pane'][data-scope-id='terminalOutput']") as HTMLElement;
      pane.focus();
    }, pre);
    await page.keyboard.press("ArrowRight");
    await expect.poll(() => scrollLeftOf(page, pre)).toBeGreaterThan(0);
    const one = await scrollLeftOf(page, pre);
    await page.keyboard.press("ArrowRight");
    await expect.poll(() => scrollLeftOf(page, pre)).toBeGreaterThan(one);
    await page.keyboard.press("ArrowLeft");
    await expect.poll(() => scrollLeftOf(page, pre)).toBe(one);
    const trace = await page.evaluate(() => (window as any).__ctKeyTrace ?? []);
    expect(trace).toContain("view.scroll-right");
    expect(trace).toContain("view.scroll-left");

    // NONE OF IT MOVED THE DEBUGGER (HO-4).
    expect((await where(page)).ticks).toBe(start.ticks);

    // THE EDITOR KEEPS MONACO'S OWN BAR (OQ-H2): no shared bar inside it.
    expect(await page.locator(".monaco-editor .ct-hscrubber").count()).toBe(0);
  });

  test("Build Output: unwrapped lines, and the bar on a wide one", async ({ ctPage, electronApp }) => {
    const page = ctPage;
    await page.waitForSelector(".calltrace-view .call-text", { timeout: 120_000 });
    const wide = "<<BUILD-LEFT>>" + "0123456789".repeat(24) + "<<BUILD-RIGHT>>";
    // The BUILD panel docked open from the bottom strip, then the main
    // process's build messages (see the header: the one stand-in).
    await waitForDefaultBottomTabs(page);
    await openBottomPanel(page, "BUILD");
    await electronApp!.evaluate(({ BrowserWindow }, line) => {
      const w = BrowserWindow.getAllWindows()[0];
      w.webContents.send("CODETRACER::build-command", { command: "printf wide" });
      w.webContents.send("CODETRACER::build-stdout", { data: line });
      w.webContents.send("CODETRACER::build-code", { code: 0 });
    }, wide);
    const output = ".build-output-container";
    const lineSel = `${output} .build-stdout`;
    await expect(page.locator(lineSel).first()).toBeVisible({ timeout: 30_000 });
    // ONE ROW: the line is not wrapped (Build Output is a text pane).
    const row = await page.locator(lineSel).first().boundingBox();
    expect(row!.height).toBeLessThanOrEqual(30);
    const barSel = "[data-ct-hscrubber='buildOutput']";
    await expect(page.locator(barSel)).toBeVisible();
    const bar = (await barState(page, barSel))!;
    expect(bar.content).toBeGreaterThan(bar.viewport);
    // Shift + wheel over it scrolls it sideways; the track's end shows the
    // line's end.
    const box = await page.locator(output).boundingBox();
    await page.mouse.move(box!.x + 40, box!.y + 10);
    await page.keyboard.down("Shift");
    await page.mouse.wheel(0, 120);
    await page.keyboard.up("Shift");
    await expect.poll(() => scrollLeftOf(page, output)).toBeGreaterThan(0);
    await page.mouse.click(bar.x + bar.w - 1, bar.y + bar.h / 2);
    await expect
      .poll(async () => {
        const s = (await barState(page, barSel))!;
        return s.left + s.viewport;
      })
      .toBeGreaterThanOrEqual(bar.content - 1);
  });
});
