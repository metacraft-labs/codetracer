/**
 * plat70i-fit-or-scroll.spec.ts — PLAT-70 Part I (Horizontal-Overflow.md
 * §5.5), the desktop's column: the TABLE panes fit or scroll, from their
 * columns' minimum widths, in the real Electron app on real recordings:
 *
 *   * the Event Log of `test-programs/wide_lines` — its columns fit the
 *     pane: the table is not in SCROLL (`data-ct-fit`) and its body does not
 *     scroll sideways; with the remembered width of its output column wider
 *     than the pane (the terminal's own form of the `table-columns`
 *     document, HO-14) the columns SCROLL: the body's sideways scroll exists,
 *     the header and the rows are as wide as the laid-out table, and the
 *     header follows the body's sideways scroll;
 *   * the Call Trace of `wide_lines` — every row's indent and callee name fit
 *     the pane, so it does not scroll sideways (OQ-H5, proposed, awaiting the
 *     user): its rows are table cells, the wide call is cut, and its cut is
 *     the browser's (HO-8: marked iff its box overflows);
 *   * the Call Trace of `test-programs/deep_calls` — a call nested 40 deep:
 *     once the deep calls are on screen the list SCROLLS sideways (HO-15);
 *   * the palette's **View: Scroll Right** / **View: Scroll Left** move the
 *     Event Log's body while its columns scroll — the table pane last pressed,
 *     since the palette holds the keyboard while its entry runs;
 *   * PLAT-71 (Terminal-Adaptation §9.2): the location column, shown and
 *     narrower than its text, loses its MIDDLE — the line number stays — as
 *     the shared presenter cuts it on every front-end, while `text-overflow`
 *     could only cut the end.
 *
 * No mocks: real `.ct` recordings, the real `ct`, a real `replay-server`, the
 * real Electron app, real wheel events.
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
      `PLAT-70 Part I: the '${prefix}' recording is not in ` +
        "test-logs/tui-fixtures/; the tui-real-terminal lane's " +
        "test_plat70i_fit_pty.nim records it.",
    );
  }
  return path.join(cache, hits[hits.length - 1]);
}

const prefix = process.env.PLAT70_DESKTOP_PREFIX ?? "";

test.setTimeout(500_000);

/** The state directory the main process reads `table-columns` from. */
const stateDir = fs.mkdtempSync(path.join(require("os").tmpdir(), "plat70i-state-"));
process.env.CODETRACER_TUI_LAYOUT_DIR = stateDir;
const columnsFile = path.join(stateDir, "table-columns");

function eventLogFit(page: any) {
  return page.evaluate(() => {
    const table = document.querySelector(".eventLog-dense-table") as HTMLElement | null;
    const body = document.querySelector(".eventLog-scroll-body") as HTMLElement | null;
    const head = document.querySelector(".eventLog-column-header") as HTMLElement | null;
    if (!table || !body || !head) return null;
    return {
      mode: table.getAttribute("data-ct-fit") ?? "",
      ox: getComputedStyle(body).overflowX,
      bodySW: body.scrollWidth,
      bodyCW: body.clientWidth,
      headMin: parseFloat(getComputedStyle(head).minWidth || "0") || 0,
    };
  });
}

function callTraceFit(page: any) {
  return page.evaluate(() => {
    const box = document.querySelector(".local-calltrace-view") as HTMLElement | null;
    if (!box) return null;
    const cells = (Array.from(document.querySelectorAll(
      ".isonim-calltrace [data-ct-cell]")) as HTMLElement[])
      .filter((c) => c.offsetParent !== null && c.clientWidth > 0)
      .map((c) => ({
        cell: c.getAttribute("data-ct-cell") ?? "",
        cut: c.hasAttribute("data-ct-cut"),
        drawnCut: c.scrollWidth > c.clientWidth + 1,
        full: c.getAttribute("data-ct-full") ?? "",
      }));
    return {
      mode: box.getAttribute("data-ct-fit") ?? "",
      ox: getComputedStyle(box).overflowX,
      sw: box.scrollWidth,
      cw: box.clientWidth,
      cells,
    };
  });
}

test.describe("PLAT-70 Part I: wide_lines — the columns fit", () => {
  test.use({
    sourcePath: recording("wide_lines"),
    launchMode: "trace-folder",
    ...(prefix ? { codetracerPrefixOverride: prefix } : {}),
  });

  test.beforeAll(() => {
    if (fs.existsSync(columnsFile)) fs.unlinkSync(columnsFile);
  });

  test("the Event Log and the Call Trace fit", async ({ ctPage }) => {
    const page = ctPage;
    await page.waitForSelector(".calltrace-view .call-text", { timeout: 180_000 });
    await page.waitForSelector("[data-ct-cell^='event-log|']", { timeout: 120_000 });
    await page.waitForTimeout(1500);

    // ---- The Event Log fits: no sideways scroll -----------------------------
    const fits = await eventLogFit(page);
    expect(fits).not.toBeNull();
    expect(fits!.mode).not.toBe("scroll");
    expect(fits!.ox).not.toBe("auto");

    // ---- The Call Trace fits: its rows are cut cells, not scrolled ----------
    await expect.poll(async () => (await callTraceFit(page))?.cells.length ?? 0,
                      { timeout: 30_000 }).toBeGreaterThan(0);
    const calls = await callTraceFit(page);
    expect(calls!.mode).not.toBe("scroll");
    expect(calls!.ox).not.toBe("auto");
    expect(calls!.sw, "the list is not wider than the pane").toBeLessThanOrEqual(calls!.cw + 1);
    const wide = calls!.cells.find((c: any) => c.full.includes("<<LEFT-EDGE>>"));
    expect(wide, "the wide call is a table cell").toBeTruthy();
    expect(wide!.cut, "the wide call is cut").toBe(true);
    for (const c of calls!.cells) {
      expect(c.cut, `${c.cell}: cut iff drawn cut`).toBe(c.drawnCut);
    }

  });
});

test.describe("PLAT-70 Part I: wide_lines — a remembered wide column scrolls", () => {
  test.use({
    sourcePath: recording("wide_lines"),
    launchMode: "trace-folder",
    ...(prefix ? { codetracerPrefixOverride: prefix } : {}),
  });

  test.beforeAll(() => {
    // THE TERMINAL'S OWN FORM of a remembered width (`encodeColumnWidths`):
    // the output column 400 cells, as `:column-width output 400` writes it.
    fs.writeFileSync(columnsFile, "event-log.output=400\n");
  });

  test.afterAll(() => {
    if (fs.existsSync(columnsFile)) fs.unlinkSync(columnsFile);
  });

  test("HO-14: the columns scroll, the header follows the body", async ({ ctPage }) => {
    const page = ctPage;
    await page.waitForSelector("[data-ct-cell^='event-log|']", { timeout: 180_000 });
    await expect.poll(async () => (await eventLogFit(page))?.mode ?? "",
                      { timeout: 60_000 }).toBe("scroll");
    const scrolls = await eventLogFit(page);
    expect(scrolls!.ox).toBe("auto");
    expect(scrolls!.bodySW).toBeGreaterThan(scrolls!.bodyCW);
    expect(scrolls!.headMin).toBeGreaterThan(scrolls!.bodyCW);
    // The header follows the body's sideways scroll: the output column's
    // title stays over its cells.
    const followed = await page.evaluate(async () => {
      const body = document.querySelector(".eventLog-scroll-body") as HTMLElement;
      const left = () => {
        const h = document.querySelector(".eventLog-column-header .eventLog-text") as HTMLElement;
        const c = document.querySelector(".eventLog-rows td.eventLog-text") as HTMLElement;
        return { head: h.getBoundingClientRect().left, cell: c.getBoundingClientRect().left };
      };
      const before = left();
      body.scrollLeft = 60;
      body.dispatchEvent(new Event("scroll"));
      await new Promise((r) => setTimeout(r, 150));
      return { scrolled: body.scrollLeft, before, after: left() };
    });
    expect(followed.scrolled).toBeGreaterThan(0);
    expect(followed.after.cell).toBeLessThan(followed.before.cell);
    expect(Math.abs(followed.after.head - followed.after.cell)).toBeLessThanOrEqual(
      Math.abs(followed.before.head - followed.before.cell) + 1);

    // ---- The palette's View: Scroll Right / Left -----------------------------
    await page.evaluate(() => {
      const body = document.querySelector(".eventLog-scroll-body") as HTMLElement;
      body.scrollLeft = 0;
      body.dispatchEvent(new Event("scroll"));
      // A press in the pane: the table pane the palette's entry acts on.
      document.querySelector(".eventLog-column-header")!.dispatchEvent(
        new MouseEvent("mousedown", { bubbles: true }));
    });
    const scrollLeft = () => page.evaluate(() =>
      (document.querySelector(".eventLog-scroll-body") as HTMLElement).scrollLeft);
    expect(await scrollLeft()).toBe(0);
    const run = async (label: string) => {
      await page.keyboard.press("Control+KeyP");
      const input = page.locator("#command-query-text");
      // The palette's command search is one word (a space starts arguments).
      await input.fill(":" + label.replace("View: ", "").replace(/ /g, ""));
      await expect(page.locator(".command-results .command-result.command-command")
        .filter({ hasText: label }).first()).toBeVisible({ timeout: 10_000 });
      await input.press("Enter");
    };
    await run("View: Scroll Right");
    await expect.poll(scrollLeft, { timeout: 10_000 }).toBeGreaterThan(0);
    const right = await scrollLeft();
    await run("View: Scroll Left");
    await expect.poll(scrollLeft, { timeout: 10_000 }).toBeLessThan(right);
  });
});

test.describe("PLAT-71: a cut location loses its middle (§9.2)", () => {
  test.use({
    sourcePath: recording("wide_lines"),
    launchMode: "trace-folder",
    ...(prefix ? { codetracerPrefixOverride: prefix } : {}),
  });

  test.beforeAll(() => {
    // The location column 6 cells wide: narrower than `main.py:<line>`.
    fs.writeFileSync(columnsFile, "event-log.location=6\n");
  });

  test.afterAll(() => {
    if (fs.existsSync(columnsFile)) fs.unlinkSync(columnsFile);
  });

  test("the location column, shown narrow, keeps its line number", async ({ ctPage }) => {
    const page = ctPage;
    await page.waitForSelector("[data-ct-cell^='event-log|']", { timeout: 180_000 });
    await page.click(".eventLog-columns-button");
    await page.click(".eventLog-column-option[data-column='location'] span:first-child");
    const cells = () => page.evaluate(() =>
      (Array.from(document.querySelectorAll("[data-ct-cell$='|location']")) as HTMLElement[])
        .filter((c) => c.offsetParent !== null)
        .map((c) => ({ text: c.textContent ?? "", cut: c.hasAttribute("data-ct-cut"),
                       full: c.getAttribute("data-ct-full") ?? "" })));
    await expect.poll(async () => (await cells()).filter((c) => c.cut).length,
                      { timeout: 30_000 }).toBeGreaterThan(0);
    for (const c of (await cells()).filter((c) => c.cut)) {
      // The middle went: the `…` is inside, the line number is the end.
      // The middle went: the `…` is inside, between the text's start and
      // its end — the line number's digits are kept.
      expect(c.full).toMatch(/^main\.py:\d+$/);
      const [head, tail] = c.text.split("…");
      expect(head.length).toBeGreaterThan(0);
      expect(tail.length).toBeGreaterThan(0);
      expect(c.full.startsWith(head)).toBe(true);
      expect(c.full.endsWith(tail)).toBe(true);
      expect(tail).toMatch(/\d$/);
    }
  });
});

test.describe("PLAT-70 Part I: deep_calls — a deep call scrolls the Call Trace", () => {
  test.use({
    sourcePath: recording("deep_calls"),
    launchMode: "trace-folder",
    ...(prefix ? { codetracerPrefixOverride: prefix } : {}),
  });

  test("HO-15: the deep calls on screen, the list scrolls sideways", async ({ ctPage }) => {
    const page = ctPage;
    await page.waitForSelector(".calltrace-view .call-text", { timeout: 180_000 });
    // The deep calls on screen: the wheel over the list.
    const box = await page.locator(".local-calltrace-view").boundingBox();
    expect(box).not.toBeNull();
    for (let i = 0; i < 12; i++) {
      await page.mouse.move(box!.x + box!.width / 2, box!.y + box!.height / 2);
      await page.mouse.wheel(0, 400);
      await page.waitForTimeout(300);
      const now = await callTraceFit(page);
      if (now?.mode === "scroll") break;
    }
    await expect.poll(async () => (await callTraceFit(page))?.mode ?? "",
                      { timeout: 30_000 }).toBe("scroll");
    const deep = await callTraceFit(page);
    expect(deep!.ox).toBe("auto");
    expect(deep!.sw).toBeGreaterThan(deep!.cw);
  });
});
