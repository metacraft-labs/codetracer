/**
 * plat49-panes-capture.spec.ts — PLAT-49 part B, the desktop's column: the
 * REFERENCE the terminal and GPUI front-ends are measured against for the
 * user's 2026-10-01 findings about the desktop's panes and chrome.
 *
 * The real Electron front-end on the terminal lanes' own `calc` recording:
 *
 *   * finding 7, the SESSION TABS — the `+` control's name; after it opens a
 *     second session, each tab as a separate item (its box, its ground, the
 *     gap to the next, the close control) and which one is active;
 *   * finding 8, the CALL TRACE — each row's parts as the desktop draws them:
 *     the toggle's state, `.call-text` (`name #index`), `.call-args`
 *     (`(name=value, …)`) and `.return-text`;
 *   * finding 9, the FOOTER AUTO-HIDE panels — their labels INSIDE the status
 *     bar; a hover shows the pane as an overlay only after a moment, and
 *     leaving closes it a moment later; a click docks it inline (no overlay,
 *     the layout shrinks), a second click collapses it;
 *   * finding 11, GOLDENLAYOUT'S DROP ZONES — where `.lm_dropTargetIndicator`
 *     lands for a tab dragged over a stack's body at sampled points, and over
 *     a header;
 *   * finding 14, the EVENT LOG'S COLUMNS — every dense-table column's title
 *     and whether it is visible.
 *
 * Written to `src/tests/visual/answers/plat49-panes.electron.json`, which
 * `src/frontend/tui/tests/test_plat49_desktop_reference.nim` asserts beside
 * the shared ViewModels the terminal and GPUI render from.
 *
 * No mocks: a real `.ct` recording, the real `ct`, a real `replay-server`,
 * the real Electron app. The prefix (this checkout's desktop JavaScript)
 * comes from `scripts/plat45-desktop-prefix.sh` via `PLAT49_DESKTOP_PREFIX`.
 */

import * as fs from "fs";
import * as path from "path";

import { expect } from "@playwright/test";
import type { Page } from "@playwright/test";
import { test } from "../../lib/fixtures";

const repoRoot = path.resolve(__dirname, "..", "..", "..", "..", "..");
const answersDir = path.join(repoRoot, "src", "tests", "visual", "answers");
const answersFile = path.join(answersDir, "plat49-panes.electron.json");

function recording(): string {
  const cache = path.join(repoRoot, "test-logs", "tui-fixtures");
  const hits = fs.existsSync(cache)
    ? fs.readdirSync(cache).filter((e) => e.startsWith("calc-")).sort()
    : [];
  if (hits.length === 0) {
    throw new Error(
      "PLAT-49: the 'calc' recording is not in test-logs/tui-fixtures/; run 'just test-tui' once to record it.",
    );
  }
  return path.join(cache, hits[hits.length - 1]);
}

test.use({
  sourcePath: recording(),
  launchMode: "trace-folder",
  codetracerPrefixOverride: process.env.PLAT49_DESKTOP_PREFIX ?? "",
});
test.setTimeout(420_000);

type Box = { x: number; y: number; w: number; h: number };
type GroundSide = "right" | "left" | "top" | "bottom";
/** Where a ground-band probe sampled, and the run along the band it chose from. */
interface BandProbe { x: number; y: number; along: [number, number] }

/**
 * A point inside GoldenLayout's 50 px ground band on `side` at which the drop
 * target IS that band — computed from the live DOM by GoldenLayout 2.6.0's own
 * rules, so the probe follows whatever layout the app opened on.
 *
 * `LayoutManager.calculateItemAreas` lists the ground's four side areas
 * (`GroundItem.createSideAreas`, in the order top, left, bottom, right), then
 * for each visible stack its whole element and its header;
 * `LayoutManager.getArea` picks, of the areas holding the point, the one with
 * the SMALLEST surface (a tie keeps the earlier one) — codetracer-pm
 * `spec/Architecture/Layout-ViewModel.md` §4.2.2. A stack's header (stack
 * width × ~24 px) or a small stack is smaller than a 50 px × full-height band,
 * so a fixed point (the layout's mid-height) can land on a header instead —
 * the first-run layout's split right column puts one exactly there. (A
 * stack's 25 % body segments are not in that list: they only pick the segment
 * once the stack has won.)
 *
 * The probe keeps its distance from the edge (`inset`) and walks ALONG the
 * band one pixel at a time, simulating `getArea` at each point; it returns the
 * middle of the longest run where the band wins, or null when there is none
 * (the root is a stack, so there are no side areas, or every point is taken).
 * Call it during a drag: GoldenLayout computes its areas once the dragged tab
 * has left its stack.
 */
async function groundBandProbe(page: Page, side: GroundSide,
                               inset: number): Promise<BandProbe | null> {
  return await page.evaluate(({ side, inset }) => {
    const gl = document.querySelector<HTMLElement>(".lm_goldenlayout");
    const rootItem = gl?.querySelector(":scope > .lm_item");
    if (gl === null || rootItem == null || rootItem.classList.contains("lm_stack")) return null;
    interface Area { x1: number; y1: number; x2: number; y2: number; surface: number }
    const areaOf = (r: DOMRect): Area =>
      ({ x1: r.left, y1: r.top, x2: r.right, y2: r.bottom, surface: r.width * r.height });
    const g = areaOf(gl.getBoundingClientRect());
    const size = 50; // `createSideAreas`' areaSize
    const withSurface = (a: Omit<Area, "surface">): Area =>
      ({ ...a, surface: (a.x2 - a.x1) * (a.y2 - a.y1) });
    const sides: Record<GroundSide, Area> = {
      top: withSurface({ ...g, y2: g.y1 + size }),
      left: withSurface({ ...g, x2: g.x1 + size }),
      bottom: withSurface({ ...g, y1: g.y2 - size }),
      right: withSurface({ ...g, x1: g.x2 - size }),
    };
    const areas: Area[] = [sides.top, sides.left, sides.bottom, sides.right];
    for (const s of Array.from(gl.querySelectorAll<HTMLElement>(".lm_stack"))) {
      if (s.style.display === "none") continue; // `Stack.getArea` skips it
      areas.push(areaOf(s.getBoundingClientRect()));
      const header = s.querySelector(":scope > .lm_header");
      if (header !== null) areas.push(areaOf(header.getBoundingClientRect()));
    }
    const { [side]: band } = sides;
    const winner = (x: number, y: number): Area | null => {
      let best: Area | null = null;
      for (const a of areas) {
        if (x >= a.x1 && x < a.x2 && y >= a.y1 && y < a.y2 && (best === null || best.surface > a.surface)) best = a;
      }
      return best;
    };
    const vertical = side === "left" || side === "right";
    const across = Math.round(side === "right" ? g.x2 - inset : side === "left" ? g.x1 + inset
      : side === "bottom" ? g.y2 - inset : g.y1 + inset);
    const from = Math.ceil(vertical ? g.y1 : g.x1);
    const to = Math.floor(vertical ? g.y2 : g.x2) - 1;
    let best: [number, number] | null = null;
    let runStart = -1;
    for (let t = from; t <= to + 1; t += 1) {
      const wins = t <= to && winner(vertical ? across : t, vertical ? t : across) === band;
      if (wins && runStart < 0) runStart = t;
      if (!wins && runStart >= 0) {
        if (best === null || t - 1 - runStart > best[1] - best[0]) best = [runStart, t - 1];
        runStart = -1;
      }
    }
    if (best === null) return null;
    const mid = Math.round((best[0] + best[1]) / 2);
    return { x: vertical ? across : mid, y: vertical ? mid : across, along: best };
  }, { side, inset });
}
// How far in from the edge each band is probed: 45 px is inside the 50 px
// band and clear of the desktop's own 40 px drag-to-pin band
// (`layout.setupDragToPinListeners`, left, right and bottom), where a release
// would also auto-hide the pane; the top has no pin band.
const groundBandInset: Record<GroundSide, number> = { right: 45, left: 45, top: 40, bottom: 45 };

test("PLAT-49 part B: the desktop's panes and session tabs", async ({ ctPage }) => {
  const out: Record<string, unknown> = {
    _comment: [
      "PLAT-49 part B — the desktop's panes and session tabs, read from the real Electron app on calc.",
      "Produced by src/tests/gui/tests/visual/plat49-panes-capture.spec.ts",
      "(`bash scripts/plat49-capture-electron.sh`).",
    ],
  };
  const page = ctPage;
  await page.waitForFunction(() => typeof (globalThis as any).__ctMenuVM !== "undefined", undefined, {
    timeout: 120_000,
  });
  // The element's box from the DOM at once: the status bar re-renders while
  // the session settles, and Playwright's `boundingBox` waits for a stable
  // element (it timed out under load).
  const box = async (selector: string): Promise<Box | null> => page.evaluate((sel) => {
    const e = document.querySelector(sel);
    if (!e) return null;
    const r = e.getBoundingClientRect();
    return { x: Math.round(r.x), y: Math.round(r.y), w: Math.round(r.width), h: Math.round(r.height) };
  }, selector);

  // ---- 8. THE CALL TRACE ---------------------------------------------------
  await page.locator(".calltrace-call-line").first().waitFor({ timeout: 120_000 });
  // Step a little so calls with arguments and returns are in the section.
  for (let i = 0; i < 40; i++) {
    await page.keyboard.press("F11");
  }
  await page.waitForTimeout(3000);
  out.calltrace = await page.evaluate(() => {
    const rows = Array.from(document.querySelectorAll(".calltrace-call-line")).slice(0, 12);
    return rows.map((r) => {
      const toggle = r.querySelector(".toggle-call > div");
      const cls = toggle ? toggle.className : "";
      return {
        toggle: cls.includes("collapse-call-img") ? "expanded"
          : cls.includes("expand-call-img") ? "collapsed"
          : cls.includes("dot-call-img") ? "leaf" : "?",
        text: (r.querySelector(".call-text")?.textContent ?? "").trim(),
        args: (r.querySelector(".call-args")?.textContent ?? "").trim(),
        returnText: (r.querySelector(".return-text")?.textContent ?? "").trim(),
        selected: r.classList.contains("event-selected"),
        argColour: getComputedStyle(r.querySelector(".call-args") ?? r).color,
        returnColour: getComputedStyle(r.querySelector(".return-text") ?? r).color,
      };
    });
  });

  // ---- 14. THE EVENT LOG'S COLUMNS -----------------------------------------
  out.eventLog = await page.evaluate(() => {
    const $ = (globalThis as any).jQuery;
    const tables = Array.from(document.querySelectorAll("table.dataTable"))
      .filter((t) => (t as HTMLElement).id.length > 0 && !(t as HTMLElement).id.includes("detailed"));
    for (const t of tables) {
      if (!$ || !$.fn || !$.fn.dataTable || !$.fn.dataTable.isDataTable(t)) continue;
      const dt = $(t).DataTable();
      const cols: { title: string; visible: boolean }[] = [];
      dt.columns().every(function (this: any) {
        cols.push({ title: (this.header()?.textContent ?? "").trim(), visible: this.visible() });
      });
      const header = Array.from(document.querySelectorAll(".eventLog-column-header > *"))
        .map((e) => ({ title: (e.textContent ?? "").trim(), cls: (e as HTMLElement).className,
                       shown: (e as HTMLElement).offsetParent !== null && (e as HTMLElement).offsetWidth > 0 }));
      return { id: (t as HTMLElement).id, columns: cols, header };
    }
    return { id: "", columns: [], header: [] };
  });

  // ---- 14 (review). THE COLUMN MENU -----------------------------------------
  // Event-Log-Pane.md's "[+ Columns]", over the Event Log ViewModel's columns:
  // open it, show the location column, move the output column left, read
  // the header after each, then put both back.
  const headerTitles = async () => page.evaluate(() =>
    Array.from(document.querySelectorAll(".eventLog-column-header > *"))
      .map((e) => (e.textContent ?? "").trim()));
  const menu: Record<string, unknown> = {};
  const columnsButton = page.locator(".eventLog-columns-button").first();
  menu.button = (await columnsButton.count()) > 0;
  if (menu.button) {
    menu.buttonText = ((await columnsButton.textContent()) ?? "").trim();
    menu.headerBefore = await headerTitles();
    await columnsButton.click();
    await page.waitForTimeout(400);
    const options = async () => page.evaluate(() =>
      Array.from(document.querySelectorAll(".eventLog-columns-menu .eventLog-column-option"))
        .map((o) => ({ column: (o as HTMLElement).dataset.column ?? "",
                       checked: o.querySelector(".eventLog-column-check")?.classList.contains("checked") ?? false,
                       shown: (o as HTMLElement).offsetParent !== null })));
    menu.options = await options();
    await page.locator('.eventLog-column-option[data-column="location"] .eventLog-column-check').first().click();
    await page.waitForTimeout(2500);
    menu.headerAfterShowLocation = await headerTitles();
    menu.optionsAfterShowLocation = await options();
    await page.locator('.eventLog-column-option[data-column="output"] .eventLog-column-left').first().click();
    await page.waitForTimeout(2500);
    menu.headerAfterMoveOutputLeft = await headerTitles();
    // Put both back.
    await page.locator('.eventLog-column-option[data-column="output"] .eventLog-column-right').first().click();
    await page.waitForTimeout(1500);
    await page.locator('.eventLog-column-option[data-column="location"] .eventLog-column-check').first().click();
    await page.waitForTimeout(2500);
    menu.headerRestored = await headerTitles();
    await columnsButton.click();
    await page.waitForTimeout(300);
    menu.openAfterSecondClick = await page.evaluate(() => {
      const m = document.querySelector(".eventLog-columns-menu") as HTMLElement | null;
      return !!m && getComputedStyle(m).display !== "none";
    });
  }
  out.eventLogMenu = menu;

  // ---- The desktop's cell, for carrying its pixel measures into a terminal's
  // cells: one character of the editor's monospace, and its line height.
  out.cellPx = await page.evaluate(() => {
    const line = document.querySelector(".monaco-editor .view-line") as HTMLElement | null;
    const lines = document.querySelector(".monaco-editor .view-lines") as HTMLElement | null;
    if (!line || !lines) return null;
    const probe = document.createElement("span");
    probe.textContent = "MMMMMMMMMMMMMMMMMMMM";
    probe.style.position = "absolute";
    probe.style.visibility = "hidden";
    probe.style.whiteSpace = "pre";
    lines.appendChild(probe);
    const w = probe.getBoundingClientRect().width / 20;
    probe.remove();
    return { width: Math.round(w * 100) / 100, height: Math.round(line.getBoundingClientRect().height * 100) / 100 };
  });

  // ---- 9. THE FOOTER AUTO-HIDE PANELS --------------------------------------
  const statusBox = await box("#status-base");
  const stripBox = await box("#auto-hide-bottom-strip");
  const labels = await page.locator("#auto-hide-bottom-strip .auto-hide-strip-tab-label").allInnerTexts();
  const tabRect = await box("#auto-hide-bottom-strip .auto-hide-strip-tab");
  const tabBox = tabRect === null ? null
    : { x: tabRect.x, y: tabRect.y, width: tabRect.w, height: tabRect.h };
  const overlayVisible = async () => page.evaluate(() => {
    const o = document.getElementById("auto-hide-overlay");
    if (!o) return false;
    const r = o.getBoundingClientRect();
    const cs = getComputedStyle(o);
    return r.width > 0 && r.height > 0 && cs.visibility !== "hidden" && cs.display !== "none" &&
      parseFloat(cs.opacity || "1") > 0.01 && !o.classList.contains("hidden");
  });
  const dockedOpen = async () => page.evaluate(() =>
    document.getElementById("auto-hide-docked-bottom")?.classList.contains("docked-open") ?? false);
  const glHeight = async () => page.evaluate(() => {
    const gl = document.querySelector(".lm_goldenlayout") as HTMLElement | null;
    return gl ? Math.round(gl.getBoundingClientRect().height) : -1;
  });
  // What the status bar holds, left to right: each direct child's box and
  // text — where the labels sit among the bar's own parts.
  const statusParts = await page.evaluate(() => {
    const base = document.getElementById("status-base");
    if (!base) return [];
    const parts: { id: string; cls: string; x: number; w: number; text: string }[] = [];
    const walk = (e: Element, depth: number) => {
      for (const c of Array.from(e.children)) {
        const r = (c as HTMLElement).getBoundingClientRect();
        if (r.width > 0 && r.height > 0) {
          parts.push({ id: (c as HTMLElement).id, cls: (c as HTMLElement).className,
                       x: Math.round(r.x), w: Math.round(r.width),
                       text: ((c as HTMLElement).innerText ?? "").trim().slice(0, 60) });
        }
        if (depth < 1) walk(c, depth + 1);
      }
    };
    walk(base, 0);
    return parts;
  });
  const footer: Record<string, unknown> = { statusBox, stripBox, labels, statusParts };
  // Hover: nothing at once; the overlay after the preview delay.
  await page.mouse.move(900, 400);
  await page.waitForTimeout(800);
  if (tabBox) {
    const glBefore = await glHeight();
    await page.mouse.move(tabBox.x + tabBox.width / 2, tabBox.y + tabBox.height / 2);
    await page.waitForTimeout(120);
    footer.overlayAfter120ms = await overlayVisible();
    await page.waitForTimeout(600);
    footer.overlayAfterHover = await overlayVisible();
    footer.dockedAfterHover = await dockedOpen();
    // Leave: still shown a moment later, gone after the grace period.
    await page.mouse.move(900, 200);
    await page.waitForTimeout(100);
    footer.overlayAfterLeave100ms = await overlayVisible();
    await page.waitForTimeout(800);
    footer.overlayAfterLeave = await overlayVisible();
    // Click: docked inline, no overlay, the layout gave up the space.
    await page.mouse.click(tabBox.x + tabBox.width / 2, tabBox.y + tabBox.height / 2);
    await page.waitForTimeout(800);
    footer.dockedAfterClick = await dockedOpen();
    footer.overlayAfterClick = await overlayVisible();
    footer.layoutHeightBefore = glBefore;
    footer.layoutHeightDocked = await glHeight();
    footer.dockedBox = await box("#auto-hide-docked-bottom");
    // A second click collapses it.
    await page.mouse.click(tabBox.x + tabBox.width / 2, tabBox.y + tabBox.height / 2);
    await page.waitForTimeout(800);
    footer.dockedAfterSecondClick = await dockedOpen();
    footer.layoutHeightAfter = await glHeight();
    await page.mouse.move(900, 200);
    await page.waitForTimeout(800);
  }
  footer.labelsInsideStatusBar = !!(statusBox && stripBox &&
    stripBox.y >= statusBox.y - 1 && stripBox.y + stripBox.h <= statusBox.y + statusBox.h + 1);
  out.footer = footer;

  // ---- 11. GOLDENLAYOUT'S DROP ZONES ---------------------------------------
  // Drag the EVENT LOG's tab over the CALL TRACE stack's body and read where
  // the drop indicator lands, as fractions of the stack's content box.
  const zones: Record<string, unknown> = {};
  const src = page.locator(".lm_tab", { hasText: /event log/i }).first();
  const targetContent = await page.evaluate(() => {
    const tabs = Array.from(document.querySelectorAll(".lm_tab"));
    const t = tabs.find((e) => /call ?trace/i.test(e.textContent ?? ""));
    const stack = t?.closest(".lm_stack");
    const content = stack?.querySelector(".lm_items") as HTMLElement | null;
    const header = stack?.querySelector(".lm_header") as HTMLElement | null;
    if (!content || !header) return null;
    const c = content.getBoundingClientRect();
    const h = header.getBoundingClientRect();
    return { c: { x: c.x, y: c.y, w: c.width, h: c.height }, h: { x: h.x, y: h.y, w: h.width, h: h.height } };
  });
  const srcBox = await src.boundingBox();
  if (srcBox && targetContent) {
    const c = targetContent.c;
    await page.mouse.move(srcBox.x + srcBox.width / 2, srcBox.y + srcBox.height / 2);
    await page.mouse.down();
    await page.mouse.move(srcBox.x + srcBox.width / 2 + 30, srcBox.y + srcBox.height / 2 + 30, { steps: 5 });
    const samples: [string, number, number][] = [
      ["left", 0.1, 0.5], ["left-top", 0.2, 0.1], ["right", 0.9, 0.5], ["right-bottom", 0.8, 0.9],
      ["top", 0.5, 0.1], ["top-mid", 0.5, 0.4], ["bottom", 0.5, 0.9], ["bottom-mid", 0.5, 0.6],
      ["centre-left", 0.3, 0.45], ["centre-right", 0.7, 0.55],
    ];
    for (const [name, fx, fy] of samples) {
      await page.mouse.move(c.x + c.w * fx, c.y + c.h * fy, { steps: 3 });
      await page.waitForTimeout(150);
      zones[name] = await page.evaluate((cb) => {
        // The indicator's TARGET box — `highlightArea` writes it into the
        // element's style; its rendered box slides there over 200 ms
        // (`.lm_dropTargetIndicator { transition: all 200ms }`).
        const ind = document.querySelector(".lm_dropTargetIndicator") as HTMLElement | null;
        if (!ind || getComputedStyle(ind).display === "none") return null;
        const px = (v: string) => parseFloat(v || "0");
        const r = { x: px(ind.style.left), y: px(ind.style.top), width: px(ind.style.width), height: px(ind.style.height) };
        if (r.width <= 0 || r.height <= 0) return null;
        const f = (v: number) => Math.round(v * 100) / 100;
        return { x: f((r.x - cb.x) / cb.w), y: f((r.y - cb.y) / cb.h), w: f(r.width / cb.w), h: f(r.height / cb.h) };
      }, c);
    }
    // GOLDENLAYOUT'S GROUND BANDS (`GroundItem.createSideAreas`): near the
    // layout's own outer edges, inside it, the indicator is a band of the
    // WHOLE layout — measured in pixels against the layout's box.
    const root = await page.evaluate(() => {
      const gl = document.querySelector(".lm_goldenlayout") as HTMLElement | null;
      if (!gl) return null;
      const r = gl.getBoundingClientRect();
      return { x: r.x, y: r.y, w: r.width, h: r.height };
    });
    const band: Record<string, unknown> = {};
    if (root) {
      band.layout = { x: Math.round(root.x), y: Math.round(root.y), w: Math.round(root.w), h: Math.round(root.h) };
      // Each band at a point where GoldenLayout picks the band, not a header
      // or a stack that lies across it (`groundBandProbe`); the point is
      // recorded beside the reading.
      const probes: Record<string, BandProbe | null> = {};
      for (const name of ["right", "left", "top", "bottom"] as GroundSide[]) {
        const probe = await groundBandProbe(page, name, groundBandInset[name]);
        probes[name] = probe;
        if (!probe) {
          band[name] = null;
          continue;
        }
        await page.mouse.move(probe.x, probe.y, { steps: 3 });
        await page.waitForTimeout(300);
        band[name] = await page.evaluate(() => {
          const ind = document.querySelector(".lm_dropTargetIndicator") as HTMLElement | null;
          if (!ind || getComputedStyle(ind).display === "none") return null;
          const px = (v: string) => Math.round(parseFloat(v || "0"));
          return { x: px(ind.style.left), y: px(ind.style.top), w: px(ind.style.width), h: px(ind.style.height) };
        });
      }
      band.probe = probes;
    }
    zones.rootBand = band;
    // Over the header: the placeholder's index among the tabs.
    const h = targetContent.h;
    await page.mouse.move(h.x + 4, h.y + h.h / 2, { steps: 3 });
    await page.waitForTimeout(150);
    zones.headerPlaceholderIndex = await page.evaluate(() => {
      const ph = document.querySelector(".lm_drop_tab_placeholder");
      if (!ph || !ph.parentElement) return -1;
      return Array.from(ph.parentElement.children).filter((e) =>
        e.classList.contains("lm_tab") || e === ph).indexOf(ph);
    });
    // Put it back where it was: release over its own header.
    await page.mouse.move(srcBox.x + srcBox.width / 2, srcBox.y + srcBox.height / 2, { steps: 5 });
    await page.mouse.up();
  }
  // A DROP ON THE RIGHT GROUND BAND (`GroundItem.onDrop`): the event log
  // becomes the whole layout's right side. Read what the root became.
  const src2 = await page.locator(".lm_tab", { hasText: /event log/i }).first().boundingBox();
  const rootBox = (zones.rootBand as any)?.layout;
  if (src2 && rootBox) {
    await page.mouse.move(src2.x + src2.width / 2, src2.y + src2.height / 2);
    await page.mouse.down();
    await page.mouse.move(src2.x + src2.width / 2 + 30, src2.y + src2.height / 2 + 30, { steps: 5 });
    await page.waitForTimeout(150);
    // The same rule as the probe above, over the layout as it stands with
    // the tab lifted out.
    const dropProbe = await groundBandProbe(page, "right", groundBandInset.right);
    // No point where the band wins: put the tab back and record no drop.
    const dropAt = dropProbe ?? { x: src2.x + src2.width / 2, y: src2.y + src2.height / 2 };
    await page.mouse.move(dropAt.x, dropAt.y, { steps: 8 });
    await page.waitForTimeout(300);
    await page.mouse.up();
    await page.waitForTimeout(1500);
    zones.rootDrop = dropProbe === null ? null : await page.evaluate(() => {
      const gl = document.querySelector(".lm_goldenlayout") as HTMLElement | null;
      const top = gl?.querySelector(":scope > .lm_item") as HTMLElement | null;
      if (!top) return null;
      const kids = Array.from(top.children).filter((c) => c.classList.contains("lm_item"));
      const last = kids[kids.length - 1] as HTMLElement | undefined;
      const r = last?.getBoundingClientRect();
      const g = gl!.getBoundingClientRect();
      return {
        rootIsRow: top.classList.contains("lm_row"),
        children: kids.length,
        lastTabs: last ? Array.from(last.querySelectorAll(".lm_tab")).map((t) => (t.textContent ?? "").trim()) : [],
        lastFullHeight: !!r && Math.abs(r.height - g.height) <= 2,
        lastShare: r ? Math.round((r.width / g.width) * 100) / 100 : 0,
      };
    });
    if (zones.rootDrop) (zones.rootDrop as Record<string, unknown>).probe = dropProbe;
  }
  out.dropZones = zones;

  // ---- 7. THE SESSION TABS -------------------------------------------------
  const sessions: Record<string, unknown> = {};
  sessions.barClassSingle = await page.evaluate(() => document.getElementById("session-tab-bar")?.className ?? "");
  sessions.addTitle = await page.evaluate(() =>
    (document.querySelector(".session-tab-add") as HTMLElement | null)?.title ?? "");
  sessions.addBox = await box(".session-tab-add");
  sessions.addVisibleWithOneSession = await page.evaluate(() => {
    const a = document.querySelector(".session-tab-add") as HTMLElement | null;
    return !!a && a.offsetParent !== null && a.getBoundingClientRect().width > 0;
  });
  await page.locator(".session-tab-add").first().click();
  await page.waitForTimeout(3000);
  sessions.tabs = await page.evaluate(() => Array.from(document.querySelectorAll("#session-tab-bar > .session-tab")).map((t) => {
    const r = t.getBoundingClientRect();
    const cs = getComputedStyle(t);
    return {
      label: (t.querySelector(".session-tab-label")?.textContent ?? "").trim(),
      active: t.classList.contains("active"),
      close: t.querySelector(".session-tab-close") !== null,
      x: Math.round(r.x), w: Math.round(r.width),
      background: cs.backgroundColor, colour: cs.color, radius: cs.borderTopLeftRadius,
      marginRight: cs.marginRight,
    };
  }));
  sessions.barClassMulti = await page.evaluate(() => document.getElementById("session-tab-bar")?.className ?? "");
  out.sessionTabs = sessions;

  // The answers first, so a red gate leaves what it saw for the reader.
  fs.mkdirSync(answersDir, { recursive: true });
  fs.writeFileSync(answersFile, JSON.stringify(out, null, 1) + "\n");

  // ---- THE GATES -------------------------------------------------------------
  // Finding 8: the call trace's rows carry arguments and return values.
  expect((out.calltrace as any[]).some((r) => r.args.length > 2)).toBe(true);
  // The first `evaluate`, found by what it is (its name and its argument),
  // not by its number: the number depends on the frames the recorder wraps the
  // program in (the Python recorder's `<toplevel>` root above `<__main__>`).
  const firstEvaluate = (out.calltrace as any[]).find((r) =>
    /^evaluate #\d+$/.test(r.text) && r.args.includes('"2 + 3"'));
  expect(firstEvaluate?.returnText).toBe("5");
  // Finding 9: the labels are in the status bar, and a click docks.
  expect(footer.labelsInsideStatusBar).toBe(true);
  // The review's gates: the column menu changes the header as the ViewModel
  // says; the ground band is GoldenLayout's 50 px of the whole layout.
  const em = out.eventLogMenu as any;
  expect(em.button).toBe(true);
  expect(em.headerAfterShowLocation).toContain("location");
  expect(em.headerAfterMoveOutputLeft.indexOf("output"))
    .toBeLessThan(em.headerAfterMoveOutputLeft.indexOf(""));
  expect(em.headerRestored).toEqual(em.headerBefore);
  // Every ground band is read (a missing reading fails, it does not skip),
  // and each is GoldenLayout's 50 px band along its whole edge.
  const must = <T>(v: T | null | undefined, what: string): T => {
    expect(v, what).toBeTruthy();
    return v as T;
  };
  const { rootBand: rb, rootDrop: rd } = out.dropZones as {
    rootBand?: Partial<Record<GroundSide | "layout", Box | null>> & { probe?: Record<string, BandProbe | null> };
    rootDrop?: { rootIsRow: boolean; lastTabs: string[]; lastFullHeight: boolean } | null;
  };
  const lay = must(rb?.layout, "the layout's box was read");
  for (const side of ["right", "left", "top", "bottom"] as GroundSide[]) {
    const b = must(rb?.[side], `the ${side} ground band was read (probe ${JSON.stringify(rb?.probe?.[side])})`);
    const vertical = side === "left" || side === "right";
    expect(Math.abs((vertical ? b.w : b.h) - 50), `the ${side} band's thickness`).toBeLessThanOrEqual(2);
    expect(Math.abs((vertical ? b.h : b.w) - (vertical ? lay.h : lay.w)), `the ${side} band's length`)
      .toBeLessThanOrEqual(2);
    const edgeGap = side === "right" ? b.x + b.w - (lay.x + lay.w) : side === "left" ? b.x - lay.x
      : side === "bottom" ? b.y + b.h - (lay.y + lay.h) : b.y - lay.y;
    expect(Math.abs(edgeGap), `the ${side} band lies on the layout's ${side} edge`).toBeLessThanOrEqual(2);
  }
  // A drop there splits the whole layout: the event log alone, full height,
  // as the root row's last child.
  const drop = must(rd, "the drop on the right ground band was made and read");
  expect(drop.rootIsRow).toBe(true);
  expect(drop.lastTabs).toEqual(["EVENT LOG"]);
  expect(drop.lastFullHeight).toBe(true);
  // Finding 14: the location column, when the table has one, is hidden.
  const loc = ((out.eventLog as any).columns as any[]).find((c) => c.title === "location");
  if (loc) expect(loc.visible).toBe(false);
});
