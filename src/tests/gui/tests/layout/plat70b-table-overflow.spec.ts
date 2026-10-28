/**
 * plat70b-table-overflow.spec.ts — PLAT-70 Part B (Horizontal-Overflow.md
 * §5), the desktop's column: the TABLE panes truncate, resize and reveal, in
 * the real Electron app on a real recording of `test-programs/wide_lines`
 * (an output line, a call argument and a variable far wider than any pane):
 *
 *   * HO-8 — in the Variables and Event Log panes, the cells the shared
 *     model marks cut (`data-ct-cut`, `views/table_overflow_dom`) are
 *     EXACTLY the cells the browser draws cut (its `text-overflow: ellipsis`
 *     shows when the text is wider than the cell), both directions, and a
 *     cut is present in each pane;
 *   * the desktop's Call Trace fits or scrolls (PLAT-70 Part I, §5.5.5 —
 *     OQ-H5, proposed, awaiting the user's confirmation): here every row's
 *     indent and callee name fit, so its rows are table cells cut at the
 *     pane — the long argument list is cut, not scrolled to
 *     (`plat70i-fit-or-scroll.spec.ts` covers the scroll);
 *   * §5.3 hover — the pointer resting on a cut cell shows its whole text in
 *     a tooltip after 500 ms (not before), wrapped at min(80 columns, the
 *     window); on a cell that fits, none;
 *   * §5.3 detail — a press on a cut cell's `…` opens its row's whole text
 *     under the row, at most `DetailMaxLines` lines, and does not move the
 *     debugger; again closes it; `Ctrl+K Ctrl+I` (`list.show-detail`) opens
 *     the focused row's;
 *   * `list.copy` (`Ctrl+C`) copies the focused row's WHOLE text;
 *   * §5.2 / HO-9 — the Event Log's widths are the ONE remembered document
 *     the terminal and GPUI read and write (`table-columns` in the native
 *     state root): a width written there in the terminal's own form is the
 *     width the desktop opens with, and a drag on a header separator writes
 *     it back (the 3-cell minimum holding);
 *   * Variable-State-Pane Decision 3 — the state pane does not scroll
 *     sideways;
 *   * a pane that is not rendered (`display: none`, as a hidden session
 *     tab's panes are) is not fitted: the Event Log's `#` cells — a
 *     middle-cut number column (PLAT-71) — keep their indices while it is
 *     hidden and after it is shown again. A fit at the hidden pane's zero
 *     width once cut every index to "" for good (issue #835's spec,
 *     `welcome-screen/new_file_with_open_replay.spec.ts`, shows it through
 *     the session tabs).
 *
 * No mocks: a real `.ct` recording, the real `ct`, a real `replay-server`,
 * the real Electron app, real pointer and key events.
 */

import * as fs from "fs";
import * as path from "path";

import { expect } from "@playwright/test";
import { test } from "../../lib/fixtures";

const repoRoot = path.resolve(__dirname, "..", "..", "..", "..", "..");

function recording(prefix: string): string {
  const cache = path.join(repoRoot, "test-logs", "tui-fixtures");
  const hits = fs.existsSync(cache)
    ? fs.readdirSync(cache).filter((e) => e.startsWith(prefix + "-")).sort()
    : [];
  if (hits.length === 0) {
    throw new Error(
      `PLAT-70: the '${prefix}' recording is not in test-logs/tui-fixtures/; ` +
        "the tui-real-terminal lane's test_plat70b_tables_pty.nim records it.",
    );
  }
  return path.join(cache, hits[hits.length - 1]);
}

const DETAIL_CAP = 10;
const prefix = process.env.PLAT70_DESKTOP_PREFIX ?? "";

test.setTimeout(500_000);

/** The state directory the main process reads `table-columns` from. It is
 * given to the app only while this file's tests run (`beforeAll` /
 * `afterAll`): set at module load and never restored, it stayed in the
 * worker's environment, so a later spec in the same worker launched with
 * this file's remembered widths — the Event Log's `#` column at the 3-cell
 * minimum its last step drags it to. */
const stateDir = fs.mkdtempSync(path.join(require("os").tmpdir(), "plat70b-state-"));
const columnsFile = path.join(stateDir, "table-columns");
const layoutDirBefore = process.env.CODETRACER_TUI_LAYOUT_DIR;

function where(page: any) {
  return page.evaluate(() => {
    const loc = (globalThis as any).data?.services?.debugger?.location;
    return { line: loc?.line ?? -1, ticks: Number(loc?.rrTicks ?? -1) };
  });
}

/** Every marked cell: its key, whether the model cut it, whether the browser
 * draws it cut, its box. */
function cells(page: any) {
  return page.evaluate(() =>
    (Array.from(document.querySelectorAll("[data-ct-cell]")) as HTMLElement[])
      .filter((c) => c.offsetParent !== null && c.clientWidth > 0)
      .map((c) => {
        const r = c.getBoundingClientRect();
        return {
          cell: c.getAttribute("data-ct-cell") ?? "",
          cut: c.hasAttribute("data-ct-cut"),
          drawnCut: c.scrollWidth > c.clientWidth,
          full: c.getAttribute("data-ct-full") ?? "",
          drawn: c.getAttribute("data-ct-text") ?? c.textContent ?? "",
          x: r.left, y: r.top, w: r.width, h: r.height,
        };
      }),
  );
}

async function stepTo(page: any, ticksAtLeast: number) {
  for (let i = 0; i < 12; i++) {
    const at = await where(page);
    if (at.ticks >= ticksAtLeast) return;
    await page.keyboard.press("F10");
    await page.waitForTimeout(1500);
  }
}

test.describe("PLAT-70 Part B: the desktop's table panes truncate, resize and reveal", () => {
  test.use({
    sourcePath: recording("wide_lines"),
    launchMode: "trace-folder",
    ...(prefix ? { codetracerPrefixOverride: prefix } : {}),
  });

  test.beforeAll(() => {
    process.env.CODETRACER_TUI_LAYOUT_DIR = stateDir;
    // THE TERMINAL'S OWN FORM of a remembered width (`encodeColumnWidths`):
    // the index column 6 cells, as `:column-width # 6` writes it there.
    fs.writeFileSync(columnsFile, "event-log.#=6\n");
  });

  test.afterAll(() => {
    if (layoutDirBefore === undefined) delete process.env.CODETRACER_TUI_LAYOUT_DIR;
    else process.env.CODETRACER_TUI_LAYOUT_DIR = layoutDirBefore;
  });

  test("HO-8, hover, detail, copy and the remembered widths", async ({ ctPage }) => {
    const page = ctPage;
    await page.waitForSelector(".calltrace-view .call-text", { timeout: 180_000 });
    await page.waitForSelector("[data-ct-cell^='event-log|']", { timeout: 120_000 });
    // Into `main`, past `WIDE_SOURCE`'s assignment: its value is a cell.
    await stepTo(page, 4);
    await page.waitForSelector("[data-ct-cell^='variables|']", { timeout: 120_000 });
    await page.waitForTimeout(1500);

    // ---- HO-8: the model's cut set is the browser's, both directions -------
    const all = await cells(page);
    const panes = ["variables|", "event-log|"];
    for (const p of panes) {
      const mine = all.filter((c: any) => c.cell.startsWith(p));
      expect(mine.length, `cells in ${p}`).toBeGreaterThan(0);
      for (const c of mine) {
        expect(c.cut, `${c.cell}: cut iff drawn cut`).toBe(c.drawnCut);
      }
      expect(mine.some((c: any) => c.cut), `a cut cell in ${p}`).toBe(true);
    }

    // ---- A hidden pane is not fitted: its number cells survive -------------
    // The Event Log host is hidden the way a background session tab hides
    // its panes (an ancestor `display: none`), which fires the pane's
    // ResizeObserver and so runs a fit pass at zero width; then shown again.
    const indexCells = () =>
      page.evaluate(() =>
        (Array.from(document.querySelectorAll("td.eventLog-index[data-ct-cell]")) as HTMLElement[])
          .map((c) => `${c.getAttribute("data-ct-cell")}=${(c.textContent ?? "").trim()}`));
    const setEventLogDisplay = (display: string) =>
      page.evaluate(async (d: string) => {
        (document.querySelector('[id^="eventLogComponent"]') as HTMLElement).style.display = d;
        // Two frames: the resize is observed, then the pass it schedules
        // (`requestAnimationFrame`) has run.
        for (let i = 0; i < 2; i++) await new Promise((r) => requestAnimationFrame(() => r(null)));
      }, display);
    const indicesShown = await indexCells();
    expect(indicesShown.length, "Event Log # cells").toBeGreaterThan(0);
    expect(indicesShown.every((c) => !c.endsWith("=")), "every # cell holds an index").toBe(true);
    await setEventLogDisplay("none");
    expect(await indexCells(), "a hidden pane's # cells are left as they are").toEqual(indicesShown);
    await setEventLogDisplay("");
    expect(await indexCells(), "the # cells keep their indices once shown again").toEqual(indicesShown);

    // ---- PLAT-70 Part I: the desktop's Call Trace fits — its rows cut ------
    const callCells = all.filter((c: any) => c.cell.startsWith("call-trace|"));
    expect(callCells.length).toBeGreaterThan(0);
    expect(callCells.some((c: any) => c.cut), "the wide call is cut").toBe(true);
    const callScroll = await page.evaluate(() => {
      const box = document.querySelector(".local-calltrace-view") as HTMLElement;
      return box ? { sw: box.scrollWidth, cw: box.clientWidth, ox: getComputedStyle(box).overflowX } : null;
    });
    expect(callScroll).not.toBeNull();
    expect(callScroll!.ox, "no sideways scroll while the floors fit").toBe("hidden");

    // ---- Decision 3: the state pane does not scroll sideways ---------------
    const stateScroll = await page.evaluate(() => {
      const box = document.querySelector(".isonim-state .value-components-container") as HTMLElement;
      return box ? { sw: box.scrollWidth, cw: box.clientWidth, ox: getComputedStyle(box).overflowX } : null;
    });
    expect(stateScroll).not.toBeNull();
    expect(stateScroll!.ox).not.toBe("auto");
    expect(stateScroll!.ox).not.toBe("scroll");

    // ---- Hover: 500 ms on a cut cell, nothing on one that fits -------------
    const cut = all.find((c: any) => c.cell.startsWith("event-log|") && c.cut)!;
    const fits = all.find((c: any) => c.cell.startsWith("event-log|") && !c.cut)!;
    await page.mouse.move(cut.x + 10, cut.y + cut.h / 2);
    await page.waitForTimeout(250);
    expect(await page.locator(".ct-table-tooltip").count()).toBe(0);
    await page.waitForTimeout(500);
    const tip = page.locator(".ct-table-tooltip");
    await expect(tip).toHaveCount(1);
    const tipLines = await tip.locator(".ct-table-tooltip-line").allTextContents();
    expect(tipLines.join(" ").replace(/\s+/g, " ")).toContain(
      cut.full.trim().slice(0, 40).replace(/\s+/g, " "));
    for (const l of tipLines) expect(l.length).toBeLessThanOrEqual(80);
    await page.mouse.move(fits.x + 2, fits.y + fits.h / 2);
    await page.waitForTimeout(700);
    expect(await page.locator(".ct-table-tooltip").count()).toBe(0);

    // ---- The `…` press opens the detail under the row; the debugger stays --
    const before = await where(page);
    await page.mouse.click(cut.x + cut.w - 3, cut.y + cut.h / 2);
    const detail = page.locator(".ct-table-detail");
    await expect(detail).toHaveCount(1);
    const lines = await detail.locator(".ct-table-detail-line").allTextContents();
    expect(lines.length).toBeGreaterThan(0);
    expect(lines.length).toBeLessThanOrEqual(DETAIL_CAP);
    expect(lines.join("").replace(/\s+/g, "")).toContain(
      cut.full.replace(/\s+/g, "").slice(0, 60));
    expect(await where(page)).toEqual(before);
    // Again closes it.
    await page.mouse.click(cut.x + cut.w - 3, cut.y + cut.h / 2);
    await expect(detail).toHaveCount(0);

    // ---- Ctrl+K Ctrl+I and Ctrl+C on the focused (pressed) variable --------
    const varCut = (await cells(page)).find((c: any) => c.cell.startsWith("variables|") && c.cut)!;
    // The cut value's WHOLE value (asked of the pane once the cell is cut,
    // `views/state_view.fullValueOf`) is more than the text the row draws.
    expect(varCut.full.length).toBeGreaterThan(varCut.drawn.length);
    await page.mouse.click(varCut.x + 4, varCut.y + varCut.h / 2);
    await page.keyboard.press("Control+K");
    await page.keyboard.press("Control+I");
    await expect(page.locator(".ct-table-detail")).toHaveCount(1);
    const detailText = (await page.locator(".ct-table-detail .ct-table-detail-line").allTextContents()).join("");
    expect(detailText.replace(/\s+/g, "")).toContain(varCut.full.replace(/\s+/g, "").slice(0, 40));
    await page.keyboard.press("Control+C");
    const copied = await page.evaluate(() => (window as any).__ctCopied ?? []);
    expect(copied[copied.length - 1]).toBe(varCut.full);
    await page.keyboard.press("Control+K");
    await page.keyboard.press("Control+I");
    await expect(page.locator(".ct-table-detail")).toHaveCount(0);

    // ---- HO-9: the remembered width is the one drawn ------------------------
    const indexHeader = page.locator(".eventLog-column-header .eventLog-index").first();
    const w0 = (await indexHeader.boundingBox())!.width;
    expect(Math.round(w0)).toBe(6 * 8);
    // A drag on its separator: wider, written back in the shared form.
    const grip = indexHeader.locator(".eventLog-column-grip");
    const g = (await grip.boundingBox())!;
    await page.mouse.move(g.x + g.width / 2, g.y + g.height / 2);
    await page.mouse.down();
    await page.mouse.move(g.x + 80, g.y + g.height / 2, { steps: 6 });
    await page.mouse.up();
    await page.waitForTimeout(800);
    const w1 = (await indexHeader.boundingBox())!.width;
    expect(w1).toBeGreaterThan(w0 + 40);
    const doc = fs.readFileSync(columnsFile, "utf8");
    const m = /event-log\.#=(\d+)/.exec(doc);
    expect(m).not.toBeNull();
    expect(Number(m![1]) * 8).toBe(Math.round(w1));
    // And the minimum: dragged far left, 3 cells.
    const g2 = (await grip.boundingBox())!;
    await page.mouse.move(g2.x + g2.width / 2, g2.y + g2.height / 2);
    await page.mouse.down();
    await page.mouse.move(g2.x - 400, g2.y + g2.height / 2, { steps: 6 });
    await page.mouse.up();
    await page.waitForTimeout(800);
    expect(Math.round((await indexHeader.boundingBox())!.width)).toBe(3 * 8);
    expect(fs.readFileSync(columnsFile, "utf8")).toContain("event-log.#=3");
  });
});
