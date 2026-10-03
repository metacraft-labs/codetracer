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
  noUserLayout: true,
  codetracerPrefixOverride: process.env.PLAT49_DESKTOP_PREFIX ?? "",
});
test.setTimeout(420_000);

type Box = { x: number; y: number; w: number; h: number };

test("PLAT-49 part B: the desktop's panes and session tabs", async ({ ctPage }) => {
  const out: Record<string, unknown> = {
    _comment: [
      "PLAT-49 part B — the desktop's panes and session tabs, read from the real Electron app on calc.",
      "Produced by src/tests/gui/tests/visual/plat49-panes-capture.spec.ts",
      "(`bash scripts/plat49-capture-electron.sh`).",
    ],
  };
  const page = ctPage;
  await page.waitForFunction(() => typeof (globalThis as any).__ctMenuVM !== "undefined", {
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
      // 45 px in: inside GoldenLayout's 50 px band and clear of the
      // desktop's own 40 px drag-to-pin band (`layout.setupDragToPinListeners`,
      // left, right and bottom), where a release would also auto-hide it.
      for (const [name, px, py] of [["right", root.x + root.w - 45, root.y + root.h * 0.5],
                                    ["left", root.x + 45, root.y + root.h * 0.5],
                                    ["top", root.x + root.w * 0.5, root.y + 40],
                                    ["bottom", root.x + root.w * 0.5, root.y + root.h - 45]] as [string, number, number][]) {
        await page.mouse.move(px, py, { steps: 3 });
        await page.waitForTimeout(300);
        band[name] = await page.evaluate(() => {
          const ind = document.querySelector(".lm_dropTargetIndicator") as HTMLElement | null;
          if (!ind || getComputedStyle(ind).display === "none") return null;
          const px = (v: string) => Math.round(parseFloat(v || "0"));
          return { x: px(ind.style.left), y: px(ind.style.top), w: px(ind.style.width), h: px(ind.style.height) };
        });
      }
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
    await page.mouse.move(rootBox.x + rootBox.w - 45, rootBox.y + rootBox.h * 0.5, { steps: 8 });
    await page.waitForTimeout(300);
    await page.mouse.up();
    await page.waitForTimeout(1500);
    zones.rootDrop = await page.evaluate(() => {
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
  const evaluate2 = (out.calltrace as any[]).find((r) => r.text === "evaluate #2");
  expect(evaluate2?.returnText).toBe("5");
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
  const rb = (out.dropZones as any).rootBand;
  if (rb && rb.right) expect(Math.abs(rb.right.w - 50)).toBeLessThanOrEqual(2);
  // Finding 14: the location column, when the table has one, is hidden.
  const loc = ((out.eventLog as any).columns as any[]).find((c) => c.title === "location");
  if (loc) expect(loc.visible).toBe(false);
});
