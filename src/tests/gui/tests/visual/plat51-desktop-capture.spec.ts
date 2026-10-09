/**
 * plat51-desktop-capture.spec.ts — PLAT-51, the desktop's column: the
 * REFERENCE the terminal and the GPUI window are measured against, and the
 * desktop's own share of the milestone.
 *
 * The real Electron front-end:
 *
 *   * NO TIMELINE — no tab, nothing in the View menu, nothing in the
 *     omnibox's commands; and a SAVED layout that held a Timeline tab (the
 *     bundled default before its removal) opens without it and without an
 *     empty tab (`index/config.dropRetiredPanels`);
 *   * the LIST SCRUBBERS — the Event Log (`noir_space_ship`, 70 events), the
 *     Call Trace (`call_pages`, 600+ calls) and the Terminal Output's line
 *     view (`terminal_colours`, 129 lines): the track's population is the
 *     whole one; a press at the track's END shows the LAST row of it; a drag
 *     from top to bottom moves the view without moving the debugger, with a
 *     bounded number of view moves; the current-position mark is on the
 *     debugger's row;
 *   * the CHANGED-VALUE STYLE — the State pane's value a step changed carries
 *     `.value-changed` in the accent the terminal and GPUI paint (the desktop
 *     had none before: the user's 2026-10-05 decision gave it one).
 *
 * Written to `src/tests/visual/answers/plat51-desktop.electron.json`, which
 * `src/frontend/tui/tests/test_plat51_desktop_reference.nim` asserts the
 * native front-ends against.
 *
 * No mocks: real `.ct` recordings, the real `ct`, a real `replay-server`, the
 * real Electron app. The prefix (this checkout's desktop JavaScript) comes
 * from `scripts/plat45-desktop-prefix.sh` via `PLAT51_DESKTOP_PREFIX`.
 */

import * as fs from "fs";
import * as path from "path";

import { expect } from "@playwright/test";
import { test } from "../../lib/fixtures";

const repoRoot = path.resolve(__dirname, "..", "..", "..", "..", "..");
const answersDir = path.join(repoRoot, "src", "tests", "visual", "answers");
const answersFile = path.join(answersDir, "plat51-desktop.electron.json");

function recording(prefix: string): string {
  const cache = path.join(repoRoot, "test-logs", "tui-fixtures");
  const hits = fs.existsSync(cache)
    ? fs.readdirSync(cache).filter((e) => e.startsWith(prefix + "-")).sort()
    : [];
  if (hits.length === 0) {
    throw new Error(
      `PLAT-51: the '${prefix}' recording is not in test-logs/tui-fixtures/; ` +
        "run the tui lane once (its fixture provider records it).",
    );
  }
  return path.join(cache, hits[hits.length - 1]);
}

function readAnswers(): Record<string, unknown> {
  try {
    return JSON.parse(fs.readFileSync(answersFile, "utf8"));
  } catch {
    return {};
  }
}

function writeAnswers(part: string, value: unknown) {
  const out = readAnswers();
  out._comment = [
    "PLAT-51 — the desktop, read from the real Electron app.",
    "Produced by src/tests/gui/tests/visual/plat51-desktop-capture.spec.ts",
    "(`bash scripts/plat51-capture-electron.sh`).",
  ];
  out[part] = value;
  fs.mkdirSync(answersDir, { recursive: true });
  fs.writeFileSync(answersFile, JSON.stringify(out, null, 1) + "\n");
}

test.setTimeout(400_000);

const prefix = process.env.PLAT51_DESKTOP_PREFIX ?? "";

function where(page: any) {
  return page.evaluate(() => {
    const loc = (globalThis as any).data?.services?.debugger?.location;
    return { line: loc?.line ?? -1, ticks: Number(loc?.rrTicks ?? -1), path: String(loc?.path ?? "") };
  });
}

async function waitMoved(page: any, from: { ticks: number }) {
  const deadline = Date.now() + 60_000;
  let now = await where(page);
  while (Date.now() < deadline && now.ticks === from.ticks) {
    await page.waitForTimeout(200);
    now = await where(page);
  }
  return now;
}

async function showTab(page: any, title: string, content: string) {
  const tab = page.locator(`.lm_tab[title='${title}'] .lm_title`).first();
  await tab.waitFor({ state: "visible", timeout: 120_000 });
  for (let attempt = 0; attempt < 5; attempt++) {
    await tab.click();
    try {
      await page.locator(content).first().waitFor({ state: "visible", timeout: 10_000 });
      break;
    } catch {
      // pressed again
    }
  }
  await page.locator(content).first().waitFor({ state: "visible", timeout: 60_000 });
  await page.waitForTimeout(1_000);
}

type Track = {
  total: number; first: number; visible: number; current: number;
  thumbTop: number; thumbPx: number; height: number; top: number; x: number;
};

function readTrack(page: any, pane: string): Promise<Track | null> {
  return page.evaluate((p: string) => {
    const t = document.querySelector(`.ct-list-scrubber[data-ct-list-scrubber='${p}']`) as HTMLElement | null;
    if (!t || getComputedStyle(t).display === "none") return null;
    const thumb = t.querySelector(".ct-list-scrubber-thumb") as HTMLElement | null;
    const r = t.getBoundingClientRect();
    return {
      total: Number(t.dataset.ctScrubTotal), first: Number(t.dataset.ctScrubFirst),
      visible: Number(t.dataset.ctScrubVisible), current: Number(t.dataset.ctScrubCurrent),
      thumbTop: Number(thumb?.dataset.ctThumbTop ?? -1), thumbPx: Number(thumb?.dataset.ctThumbPx ?? -1),
      height: r.height, top: r.top, x: r.left + r.width / 2,
    };
  }, pane);
}

async function settledTrack(page: any, pane: string): Promise<Track> {
  let t: Track | null = null;
  for (let i = 0; i < 40; i++) {
    t = await readTrack(page, pane);
    if (t && t.total > 0) break;
    await page.waitForTimeout(500);
  }
  if (!t) throw new Error(`PLAT-51: no ${pane} scrubber drawn`);
  return t;
}

/** Press the track at `fraction` of its height (0 = top, 1 = bottom). */
async function pressTrack(page: any, pane: string, fraction: number) {
  const t = await settledTrack(page, pane);
  // Two pixels inside the track's ends: its first and last pixel rows touch
  // the neighbouring chrome (the table's footer), which takes the press.
  const y = t.top + Math.min(t.height - 3, Math.max(2, fraction * (t.height - 1)));
  const hit = await page.evaluate(([x, yy]: number[]) => {
    const e = document.elementFromPoint(x, yy) as HTMLElement | null;
    return e ? (e.className || e.tagName) : "";
  }, [t.x, y]);
  if (!String(hit).includes("ct-list-scrubber")) {
    console.log(`PLAT51: the press at ${y} lands on '${hit}', not the track`);
  }
  await page.mouse.click(t.x, y);
  await page.waitForTimeout(1_500);
}

/** Hold the thumb, move to the bottom of the track in steps, release. */
async function dragThumb(page: any, pane: string, steps: number) {
  const t = await settledTrack(page, pane);
  await page.mouse.move(t.x, t.top + t.thumbTop + t.thumbPx / 2);
  await page.mouse.down();
  for (let k = 1; k <= steps; k++) {
    await page.mouse.move(t.x, t.top + (t.height - 1) * (k / steps));
    await page.waitForTimeout(60);
  }
  await page.mouse.up();
  await page.waitForTimeout(2_000);
}

test.describe("PLAT-51: the desktop's Event Log scrubber, no Timeline", () => {
  test.use({
    sourcePath: recording("noir_space_ship"),
    launchMode: "trace-folder",
    noUserLayout: true,
    codetracerPrefixOverride: prefix,
  });

  test("PLAT-51: no Timeline anywhere; the Event Log's scrubber spans the whole log", async ({ ctPage }) => {
    const pageErrors: string[] = [];
    ctPage.on("pageerror", (e) => pageErrors.push(String(e?.stack ?? e)));
    await ctPage.waitForSelector(".calltrace-view .call-text", { timeout: 120_000 });
    const out: Record<string, unknown> = {};

    // ---- the Timeline is gone ----------------------------------------------
    out.tabs = await ctPage.locator(".lm_tab .lm_title").allInnerTexts();
    // ANY tab whose label names a timeline — `TIMELINE`, or the retired
    // content's own name (`RETIRED TIMELINE PANEL`) a config that kept the
    // component would show.
    out.timelineTabs = (out.tabs as string[]).filter((t) => /timeline/i.test(t)).length;
    out.timelineContainers = await ctPage.locator("#timelineComponent-0").count();
    // The View folder, opened through the shared Menu ViewModel as PLAT-48's
    // capture does (the root's child 3: index 0 is the macOS application
    // folder, hidden off macOS; then File, Edit, View), and its items read
    // back off the DOM the desktop drew for it.
    await ctPage.waitForFunction(() => typeof (globalThis as any).__ctMenuVM !== "undefined", undefined, {
      timeout: 120_000,
    });
    await ctPage.locator("#menu-root").click();
    await ctPage.locator("#menu-main").waitFor({ timeout: 30_000 });
    await ctPage.evaluate(() => (globalThis as any).__ctMenuVM.setHighlight([3], 0));
    await ctPage.waitForFunction(
      () => Array.from(document.querySelectorAll(".menu-active-node .ct-menu-item-label"))
        .some((e) => (e.textContent ?? "").trim() === "View"),
      undefined, { timeout: 30_000 });
    const viewItems: string[] = (await ctPage.locator(".menu-nested-elements").first()
      .locator(".ct-menu-item .ct-menu-item-label").allInnerTexts()).map((s) => s.trim());
    out.viewMenuItems = viewItems;
    out.menuHasTimeline = viewItems.some((s) => /^Timeline\b/.test(s));
    await ctPage.evaluate(() => (globalThis as any).__ctMenuVM.close());

    // ---- the Event Log's scrubber --------------------------------------------
    await showTab(ctPage, "EVENT LOG", ".dt-scroll-body tbody tr");
    const start = await where(ctPage);
    const t0 = await settledTrack(ctPage, "eventLog");
    out.trackAtStart = t0;
    await pressTrack(ctPage, "eventLog", 1.0);
    const atEnd = await settledTrack(ctPage, "eventLog");
    out.trackAtEnd = atEnd;
    // The rows IN VIEW (inside the scroll body's box), as the table drew
    // them — the last one must be the log's last event.
    out.rowsAtEnd = await ctPage.evaluate(() => {
      const body = document.querySelector(".dt-scroll-body") as HTMLElement | null;
      if (!body) return [];
      const box = body.getBoundingClientRect();
      return Array.from(body.querySelectorAll("tbody tr"))
        .filter((r) => {
          const b = r.getBoundingClientRect();
          return b.bottom > box.top + 1 && b.top < box.bottom - 1;
        })
        .map((r) => (r.textContent ?? "").replace(/\s+/g, " ").trim()).slice(-3);
    });
    out.afterEndPress = await where(ctPage);
    await pressTrack(ctPage, "eventLog", 0.0);
    out.trackAtTop = await settledTrack(ctPage, "eventLog");

    // A drag from the thumb to the bottom: the view moves, the debugger does
    // not; the view moves the scrubber made (and so the Scroller's fetches)
    // are bounded by the drag's steps.
    await ctPage.evaluate(() => { (globalThis as any).__ctScrubberJumps = 0; });
    await dragThumb(ctPage, "eventLog", 20);
    out.dragJumps = await ctPage.evaluate(() => (globalThis as any).__ctScrubberJumps ?? 0);
    out.trackAfterDrag = await settledTrack(ctPage, "eventLog");
    out.afterDrag = await where(ctPage);
    out.start = start;

    // A ROW click still moves the debugger; the mark follows it.
    await pressTrack(ctPage, "eventLog", 0.0);
    const before = await where(ctPage);
    await ctPage.locator(".dt-scroll-body tbody tr").nth(5).click();
    out.afterRowClick = await waitMoved(ctPage, before);
    await ctPage.waitForTimeout(2_000);
    out.trackAfterRowClick = await settledTrack(ctPage, "eventLog");
    out.pageErrors = pageErrors;
    out.scrollBody = await ctPage.evaluate(() => {
      const b = document.querySelector(".dt-scroll-body") as HTMLElement | null;
      const r = document.querySelector(".dt-scroll-body tbody tr") as HTMLElement | null;
      return b ? { scrollTop: b.scrollTop, scrollHeight: b.scrollHeight, clientHeight: b.clientHeight,
                   rowHeight: r ? r.getBoundingClientRect().height : -1 } : null;
    });
    console.log("PLAT51-EVENTLOG " + JSON.stringify(out));
    writeAnswers("eventLog", out);

    expect(out.timelineTabs).toBe(0);
    expect(out.menuHasTimeline).toBe(false);
    // …and the View menu WAS read (its panes are listed), so the line above
    // is not vacuous.
    expect(out.viewMenuItems as string[]).toContain("Event Log");
    expect(t0.total).toBe(70);
    expect(atEnd.first + atEnd.visible).toBeGreaterThanOrEqual(70);
    expect((out.afterEndPress as { ticks: number }).ticks).toBe(start.ticks);
    expect((out.afterDrag as { ticks: number }).ticks).toBe(start.ticks);
    writeAnswers("eventLog", out);
  });
});

test.describe("PLAT-51: a saved desktop layout that held the Timeline", () => {
  // The user's remembered layout is the BUNDLED DEFAULT AS IT WAS before the
  // Timeline's removal (git history): a Timeline tab between Event Log and
  // Terminal Output. It must open without it, and without an empty tab.
  const saved = path.join(repoRoot, "src", "tests", "visual", "plat51-layout-with-timeline.json");
  const dir = path.join(process.env.XDG_CONFIG_HOME ?? "", "codetracer");
  if (process.env.XDG_CONFIG_HOME && fs.existsSync(saved)) {
    fs.mkdirSync(dir, { recursive: true });
    fs.copyFileSync(saved, path.join(dir, "default_layout.json"));
  }
  test.use({
    sourcePath: recording("calc"),
    launchMode: "trace-folder",
    preserveUserLayout: true,
    codetracerPrefixOverride: prefix,
  });

  test("PLAT-51: the Timeline tab is dropped on load, its stack keeps the rest", async ({ ctPage }) => {
    const pageErrors: string[] = [];
    ctPage.on("pageerror", (e) => pageErrors.push(String(e?.stack ?? e)));
    await ctPage.waitForSelector(".calltrace-view .call-text", { timeout: 120_000 });
    await ctPage.waitForTimeout(2_000);
    const out: Record<string, unknown> = {};
    out.tabs = await ctPage.locator(".lm_tab .lm_title").allInnerTexts();
    // ANY tab whose label names a timeline — `TIMELINE`, or the retired
    // content's own name (`RETIRED TIMELINE PANEL`) a config that kept the
    // component would show.
    out.timelineTabs = (out.tabs as string[]).filter((t) => /timeline/i.test(t)).length;
    out.emptyTabs = await ctPage.evaluate(() =>
      Array.from(document.querySelectorAll(".lm_tab .lm_title"))
        .filter((e) => (e.textContent ?? "").trim().length === 0).length);
    out.pageErrors = pageErrors;
    expect(out.timelineTabs).toBe(0);
    expect((out.tabs as string[])).toContain("EVENT LOG");
    expect((out.tabs as string[])).toContain("TERMINAL OUTPUT");
    writeAnswers("savedLayout", out);
  });
});

test.describe("PLAT-51: the desktop's Call Trace scrubber", () => {
  test.use({
    sourcePath: recording("call_pages"),
    launchMode: "trace-folder",
    noUserLayout: true,
    codetracerPrefixOverride: prefix,
  });

  test("PLAT-51: the Call Trace's scrubber spans the whole trace", async ({ ctPage }) => {
    const pageErrors: string[] = [];
    ctPage.on("pageerror", (e) => pageErrors.push(String(e?.stack ?? e)));
    await ctPage.waitForSelector(".calltrace-view .call-text", { timeout: 120_000 });
    await ctPage.waitForTimeout(2_000);
    const out: Record<string, unknown> = {};
    const start = await where(ctPage);
    out.start = start;
    out.trackAtStart = await settledTrack(ctPage, "calltrace");
    await pressTrack(ctPage, "calltrace", 1.0);
    await ctPage.waitForTimeout(2_000);
    out.trackAtEnd = await settledTrack(ctPage, "calltrace");
    out.scrollAtEnd = await ctPage.evaluate(() =>
      Array.from(document.querySelectorAll(".ct-scrubbed")).map((e) => {
        const el = e as HTMLElement;
        const row = el.querySelector(".calltrace-call-line") as HTMLElement | null;
        return { cls: el.className, scrollTop: el.scrollTop, scrollHeight: el.scrollHeight,
                 clientHeight: el.clientHeight, row: row ? row.getBoundingClientRect().height : -1 };
      }));
    console.log("PLAT51-CALLTRACE " + JSON.stringify(out));
    out.lastRows = await ctPage.evaluate(() =>
      Array.from(document.querySelectorAll(".calltrace-view .calltrace-call-line .call-text"))
        .map((e) => (e.textContent ?? "").trim()).slice(-3));
    out.afterEndPress = await where(ctPage);
    await ctPage.evaluate(() => { (globalThis as any).__ctScrubberJumps = 0; });
    await pressTrack(ctPage, "calltrace", 0.0);
    await dragThumb(ctPage, "calltrace", 20);
    out.dragJumps = await ctPage.evaluate(() => (globalThis as any).__ctScrubberJumps ?? 0);
    out.trackAfterDrag = await settledTrack(ctPage, "calltrace");
    out.afterDrag = await where(ctPage);
    out.pageErrors = pageErrors;
    const t = out.trackAtStart as Track;
    expect(t.total).toBeGreaterThan(600);
    // The end of the track shows the trace's LAST call.
    const e = out.trackAtEnd as Track;
    expect(e.first + e.visible).toBeGreaterThanOrEqual(e.total);
    expect((out.lastRows as string[]).join("|")).toContain("#" + String(e.total));
    expect((out.afterEndPress as { ticks: number }).ticks).toBe(start.ticks);
    expect((out.afterDrag as { ticks: number }).ticks).toBe(start.ticks);
    writeAnswers("calltrace", out);
  });
});

test.describe("PLAT-51: the desktop's Terminal Output line scrubber", () => {
  test.use({
    sourcePath: recording("terminal_colours"),
    launchMode: "trace-folder",
    noUserLayout: true,
    codetracerPrefixOverride: prefix,
  });

  test("PLAT-51: the line view's scrubber spans every line", async ({ ctPage }) => {
    const pageErrors: string[] = [];
    ctPage.on("pageerror", (e) => pageErrors.push(String(e?.stack ?? e)));
    await ctPage.waitForSelector(".calltrace-view .call-text", { timeout: 120_000 });
    await showTab(ctPage, "TERMINAL OUTPUT", ".isonim-terminal-output pre .terminal-line");
    const out: Record<string, unknown> = {};
    const start = await where(ctPage);
    out.trackAtStart = await settledTrack(ctPage, "terminalOutput");
    await pressTrack(ctPage, "terminalOutput", 1.0);
    out.trackAtEnd = await settledTrack(ctPage, "terminalOutput");
    out.lastLineVisible = await ctPage.evaluate(() => {
      const pre = document.querySelector(".isonim-terminal-output pre") as HTMLElement | null;
      const lines = Array.from(document.querySelectorAll(".isonim-terminal-output pre .terminal-line"));
      const last = lines[lines.length - 1] as HTMLElement | undefined;
      if (!pre || !last) return false;
      const a = pre.getBoundingClientRect(), b = last.getBoundingClientRect();
      return b.bottom <= a.bottom + 1 && b.top >= a.top - 1;
    });
    out.afterEndPress = await where(ctPage);
    out.pageErrors = pageErrors;
    expect((out.trackAtStart as Track).total).toBe(129);
    expect(out.lastLineVisible).toBe(true);
    expect((out.afterEndPress as { ticks: number }).ticks).toBe(start.ticks);
    writeAnswers("terminalOutput", out);
  });
});

test.describe("PLAT-51: the desktop's changed-value style", () => {
  test.use({
    sourcePath: recording("calc"),
    launchMode: "trace-folder",
    noUserLayout: true,
    codetracerPrefixOverride: prefix,
  });

  test("PLAT-51: a value the step changed carries .value-changed in the accent", async ({ ctPage }) => {
    const pageErrors: string[] = [];
    ctPage.on("pageerror", (e) => pageErrors.push(String(e?.stack ?? e)));
    await ctPage.waitForSelector(".calltrace-view .call-text", { timeout: 120_000 });
    const out: Record<string, unknown> = {};
    // Into `main` (its call-trace row), then step over its lines until a
    // value changes.
    const before = await where(ctPage);
    await ctPage.locator(".calltrace-view .call-text", { hasText: "evaluate" }).first().click();
    await waitMoved(ctPage, before);
    await ctPage.waitForTimeout(1_500);
    const samples: unknown[] = [];
    for (let i = 0; i < 6; i++) {
      const at = await where(ctPage);
      await ctPage.keyboard.press("F10");
      await waitMoved(ctPage, at);
      await ctPage.waitForTimeout(1_500);
      const changed = await ctPage.evaluate(() => {
        const hex = (css: string): string => {
          const m = css.match(/rgba?\(\s*(\d+)[ ,]+(\d+)[ ,]+(\d+)/);
          return m ? "#" + [m[1], m[2], m[3]].map((v) => Number(v).toString(16).padStart(2, "0")).join("") : "";
        };
        return Array.from(document.querySelectorAll(".state-component .value-expanded-text.value-changed"))
          .map((e) => {
            const row = e.closest("[data-variable-name]") as HTMLElement | null;
            const s = getComputedStyle(e as HTMLElement);
            return { name: row?.dataset.variableName ?? "", text: e.textContent ?? "",
                     color: hex(s.color), weight: s.fontWeight };
          });
      });
      const plain = await ctPage.evaluate(() => {
        const e = document.querySelector(".state-component .value-expanded-text:not(.value-changed)") as HTMLElement | null;
        if (!e) return null;
        const m = getComputedStyle(e).color.match(/rgba?\(\s*(\d+)[ ,]+(\d+)[ ,]+(\d+)/);
        return m ? "#" + [m[1], m[2], m[3]].map((v) => Number(v).toString(16).padStart(2, "0")).join("") : "";
      });
      samples.push({ at: await where(ctPage), changed, plain });
    }
    out.samples = samples;
    out.pageErrors = pageErrors;
    const anyChanged = (samples as { changed: unknown[] }[]).some((s) => s.changed.length > 0);
    expect(anyChanged).toBe(true);
    writeAnswers("changedValues", out);
  });
});

// ---------------------------------------------------------------------------
// PLAT-51 part B, deliverable 10: GOLDENLAYOUT'S OWN DROP DECISIONS, for the
// pointer-trace differential (Layout-ViewModel §4.2.2). A tab is picked up
// with the real mouse (GoldenLayout's own DragProxy lifts it out and measures
// the layout), then:
//   * the GEOMETRY GoldenLayout measured is read back — the ground, every
//     stack in `getAllContentItems` order (element, header, content, tabs
//     with the placeholder taken out), and the placeholder's own push;
//   * a DENSE GRID over the layout is put through GoldenLayout's own
//     `getArea` and the chosen item's `highlightDropZone` — the two calls
//     `DragProxy.setDropPosition` makes — and each sample's decision is read
//     back: the area's index in `_itemAreas`, the stack's `_dropSegment` and
//     `_dropIndex`, and where the placeholder now is;
//   * RECORDED DRAG PATHS (tab -> edge, tab -> header slot, tab -> another
//     stack's middle, tab -> outer band) are walked with the REAL mouse, and
//     each step's decision read the same way (the clamped point
//     `setDropPosition` used is recorded by a wrapper on `getArea`).
// At three window sizes. Written one file per size,
// `plat51-dropzones-<width>x<height>.electron.json` (one file would exceed the
// repository's 500 KB limit on added files);
// `viewmodel/tests/unit/test_golden_layout_hit.nim` replays every sample
// through the shared port and requires the SAME decision at each.
// ---------------------------------------------------------------------------

const dropAnswersFile = (size: { width: number; height: number }) =>
  path.join(answersDir, `plat51-dropzones-${size.width}x${size.height}.electron.json`);

test.describe("PLAT-51: GoldenLayout's drop decisions, for the pointer-trace differential", () => {
  test.use({
    sourcePath: recording("calc"),
    launchMode: "trace-folder",
    noUserLayout: true,
    codetracerPrefixOverride: prefix,
  });

  test("PLAT-51: GoldenLayout's area, segment and header index at every sample", async ({ ctPage }) => {
    const page = ctPage;
    await page.waitForSelector(".calltrace-view .call-text", { timeout: 120_000 });
    await page.waitForTimeout(2_000);
    const sizes = [
      { width: 1400, height: 900 },
      { width: 1100, height: 760 },
      { width: 1720, height: 1020 },
    ];
    const runs: unknown[] = [];
    for (const size of sizes) {
      await page.setViewportSize(size);
      await page.waitForTimeout(1_500);
      // The source: the event log's tab, picked up with the real mouse past
      // GoldenLayout's drag threshold.
      const src = await page.locator(".lm_tab", { hasText: /event log/i }).first().boundingBox();
      if (!src) throw new Error("PLAT-51: no Event Log tab");
      const sx = src.x + src.width / 2;
      const sy = src.y + src.height / 2;
      await page.mouse.move(sx, sy);
      await page.mouse.down();
      await page.mouse.move(sx + 15, sy + 15, { steps: 4 });
      await page.mouse.move(sx + 40, sy + 60, { steps: 4 });
      await page.waitForTimeout(400);
      // Record every `getArea` call (the point `setDropPosition` used,
      // clamped) — how a real move's decision is found again.
      const geometry = await page.evaluate(() => {
        const lm = (globalThis as any).data?.ui?.layout;
        if (!lm) return null;
        const w = globalThis as any;
        if (!w.__glWrapped) {
          const orig = lm.getArea.bind(lm);
          lm.getArea = (x: number, y: number) => {
            const a = orig(x, y);
            w.__glLast = { x, y, area: a };
            return a;
          };
          w.__glWrapped = true;
        }
        const rect = (e: Element) => {
          const r = e.getBoundingClientRect();
          return { x1: r.left, y1: r.top, x2: r.left + r.width, y2: r.top + r.height };
        };
        const ph = lm.tabDropPlaceholder as HTMLElement;
        const phParent = ph.parentElement;
        const phNext = ph.nextSibling;
        // GoldenLayout's STATE before the first grid sample: where the
        // placeholder is, and each stack's segment and index — what the
        // replay starts from.
        let phStack0 = -1;
        let phIndex0 = -1;
        const allStacks = lm.getAllContentItems().filter((i: any) => i.isStack);
        if (phParent) {
          allStacks.forEach((s: any, i: number) => {
            if (s._header.tabsContainerElement === phParent) {
              phStack0 = i;
              phIndex0 = Array.from(phParent.children)
                .filter((c) => c.classList.contains("lm_tab") || c === ph).indexOf(ph);
            }
          });
        }
        if (phParent) ph.remove();
        const stacks = lm.getAllContentItems().filter((i: any) => i.isStack).map((s: any) => {
          const header = s._header;
          const visible = header.lastVisibleTabIndex + 1;
          const tabEls = header.tabs.slice(0, visible).map((t: any) => t.element as HTMLElement);
          // THE STRIP WITH THE PLACEHOLDER IN EACH SLOT: GoldenLayout reads
          // the tabs where the browser lays them out, and a flex strip
          // SHRINKS them to make room (it does not just push them right) —
          // so the port is handed the strip as drawn for every slot.
          const tabsAt: unknown[] = [];
          for (let p = 0; p <= tabEls.length; p++) {
            if (tabEls.length === 0) break;
            if (p < tabEls.length) tabEls[p].insertAdjacentElement("beforebegin", ph);
            else tabEls[tabEls.length - 1].insertAdjacentElement("afterend", ph);
            tabsAt.push(tabEls.map((e: HTMLElement) => rect(e)));
            ph.remove();
          }
          return {
            element: rect(s.element),
            header: rect(header.element),
            content: rect(s._childElementContainer),
            tabs: header.tabs.slice(0, visible).map((t: any) => rect(t.element)),
            tabsAt,
            titles: s.contentItems.map((c: any) => String(c.title ?? "")),
            empty: s.contentItems.length === 0,
            segment0: String(s._dropSegment ?? ""),
            dropIndex0: Number(s._dropIndex ?? -1),
          };
        });
        // The placeholder's push: before the first tab of a stack with a tab.
        let placeholderPx = 100;
        const first = lm.getAllContentItems().find((i: any) => i.isStack && i._header.tabs.length > 0);
        if (first) {
          const tabEl = first._header.tabs[0].element as HTMLElement;
          const before = tabEl.getBoundingClientRect().left;
          tabEl.insertAdjacentElement("beforebegin", ph);
          placeholderPx = tabEl.getBoundingClientRect().left - before;
          ph.remove();
        }
        if (phParent) phParent.insertBefore(ph, phNext);
        const ground = rect(lm._groundItem.element);
        const rootIsStack = !!lm._groundItem.contentItems[0]?.isStack;
        return {
          ground, rootIsStack, placeholderPx, stacks, phStack0, phIndex0,
          areas: lm._itemAreas.map((a: any) => ({
            x1: a.x1, y1: a.y1, x2: a.x2, y2: a.y2, surface: a.surface,
            side: a.side ?? "", stack: a.contentItem?.isStack ? true : false,
          })),
        };
      });
      if (!geometry) throw new Error("PLAT-51: no GoldenLayout at window.data.ui.layout");
      // What GoldenLayout decided for the sample just taken.
      const readDecision = () => page.evaluate(() => {
        const lm = (globalThis as any).data.ui.layout;
        const last = (globalThis as any).__glLast;
        const ph = lm.tabDropPlaceholder as HTMLElement;
        const stacks = lm.getAllContentItems().filter((i: any) => i.isStack);
        let phStack = -1;
        let phIndex = -1;
        if (ph.parentElement) {
          stacks.forEach((s: any, i: number) => {
            if (s._header.tabsContainerElement === ph.parentElement) {
              phStack = i;
              phIndex = Array.from(ph.parentElement!.children)
                .filter((c) => c.classList.contains("lm_tab") || c === ph).indexOf(ph);
            }
          });
        }
        const a = last?.area ?? null;
        const idx = a ? lm._itemAreas.indexOf(a) : -1;
        const stack = a && a.contentItem?.isStack ? stacks.indexOf(a.contentItem) : -1;
        return {
          x: last?.x ?? -1, y: last?.y ?? -1, area: idx, stack,
          segment: stack >= 0 ? String(a.contentItem._dropSegment ?? "") : "",
          dropIndex: stack >= 0 ? Number(a.contentItem._dropIndex ?? -1) : -1,
          phStack, phIndex,
        };
      });
      // The DENSE GRID, through GoldenLayout's own two calls.
      const grid = await page.evaluate((g: any) => {
        const lm = (globalThis as any).data.ui.layout;
        const out: unknown[] = [];
        const stepX = Math.max(7, (g.ground.x2 - g.ground.x1) / 61);
        const stepY = Math.max(7, (g.ground.y2 - g.ground.y1) / 41);
        const stacks = lm.getAllContentItems().filter((i: any) => i.isStack);
        const ph = lm.tabDropPlaceholder as HTMLElement;
        for (let y = g.ground.y1 + 0.37; y < g.ground.y2; y += stepY) {
          for (let x = g.ground.x1 + 0.53; x < g.ground.x2; x += stepX) {
            const a = lm.getArea(x, y);
            if (a) a.contentItem.highlightDropZone(x, y, a);
            let phStack = -1;
            let phIndex = -1;
            if (ph.parentElement) {
              stacks.forEach((s: any, i: number) => {
                if (s._header.tabsContainerElement === ph.parentElement) {
                  phStack = i;
                  phIndex = Array.from(ph.parentElement!.children)
                    .filter((c) => c.classList.contains("lm_tab") || c === ph).indexOf(ph);
                }
              });
            }
            const stack = a && a.contentItem?.isStack ? stacks.indexOf(a.contentItem) : -1;
            out.push({
              x, y, area: a ? lm._itemAreas.indexOf(a) : -1, stack,
              segment: stack >= 0 ? String(a.contentItem._dropSegment ?? "") : "",
              dropIndex: stack >= 0 ? Number(a.contentItem._dropIndex ?? -1) : -1,
              phStack, phIndex,
            });
          }
        }
        return out;
      }, geometry);
      // RECORDED PATHS with the real mouse. The targets from the geometry:
      // the first stack's header (a slot), another stack's middle, its left
      // edge, and the ground's right band.
      const paths: Record<string, unknown[]> = {};
      const st = (geometry as any).stacks as any[];
      const g = (geometry as any).ground;
      const mid = (r: any) => ({ x: (r.x1 + r.x2) / 2, y: (r.y1 + r.y2) / 2 });
      const targets: Record<string, { x: number; y: number }> = {};
      const withTabs = st.find((s) => s.tabs.length > 1) ?? st[0];
      targets.headerSlot = { x: withTabs.tabs[withTabs.tabs.length - 1].x1 + 3, y: mid(withTabs.header).y };
      const big = [...st].sort((a, b) => (b.content.x2 - b.content.x1) * (b.content.y2 - b.content.y1) -
        (a.content.x2 - a.content.x1) * (a.content.y2 - a.content.y1))[0];
      targets.middle = mid(big.content);
      targets.leftEdge = { x: big.content.x1 + (big.content.x2 - big.content.x1) * 0.12, y: mid(big.content).y };
      targets.outerBand = { x: g.x2 - 20, y: (g.y1 + g.y2) / 2 };
      targets.outside = { x: g.x2 + 60, y: g.y2 + 40 };
      for (const [name, t] of Object.entries(targets)) {
        const samples: unknown[] = [];
        const from = await page.evaluate(() => (globalThis as any).__glLast) ?? { x: sx + 40, y: sy + 60 };
        const n = 14;
        for (let k = 1; k <= n; k++) {
          const px = from.x + (t.x - from.x) * k / n;
          const py = from.y + (t.y - from.y) * k / n;
          await page.mouse.move(px, py);
          await page.waitForTimeout(30);
          samples.push(await readDecision());
        }
        paths[name] = samples;
      }
      // Put the tab back: released over its own stack's header.
      await page.mouse.move(sx, sy, { steps: 6 });
      await page.waitForTimeout(200);
      await page.mouse.up();
      await page.waitForTimeout(1_500);
      runs.push({ size, geometry, grid, paths });
    }
    fs.mkdirSync(answersDir, { recursive: true });
    for (const run of runs as any[]) {
      fs.writeFileSync(dropAnswersFile(run.size), JSON.stringify({
        _comment: [
          "PLAT-51 part B — GoldenLayout 2.6.0's own drop decisions in the real Electron app.",
          "Produced by src/tests/gui/tests/visual/plat51-desktop-capture.spec.ts",
          "(`bash scripts/plat51-capture-electron.sh`); replayed through the shared port by",
          "src/frontend/tui/tests/test_plat51_dropzones_reference.nim.",
        ],
        runs: [run],
      }) + "\n");
    }
    // Every run measured something and decided somewhere.
    for (const run of runs as any[]) {
      expect(run.geometry.stacks.length).toBeGreaterThan(2);
      expect(run.grid.length).toBeGreaterThan(1000);
      expect(run.grid.some((s: any) => s.segment === "header")).toBe(true);
      expect(run.grid.some((s: any) => s.area >= 0 && s.stack < 0)).toBe(true);
    }
  });
});

// ---------------------------------------------------------------------------
// PLAT-51 part B, deliverable 8: the desktop's NEW TAB — its Welcome Screen's
// start options, in order, with which are live — the reference the native
// front-ends' new tab is asserted against.
// ---------------------------------------------------------------------------

test.describe("PLAT-51: the desktop's new tab opens the Welcome Screen", () => {
  test.use({
    sourcePath: recording("calc"),
    launchMode: "trace-folder",
    noUserLayout: true,
    codetracerPrefixOverride: prefix,
  });

  test("PLAT-51: the + opens a tab showing the Welcome Screen's start options", async ({ ctPage }) => {
    const page = ctPage;
    await page.waitForSelector(".calltrace-view .call-text", { timeout: 120_000 });
    // The pointer away first: a value tooltip over the bar takes the press.
    await page.mouse.move(5, 300);
    await page.waitForTimeout(500);
    await page.locator(".session-tab-add").first().click({ force: true });
    await page.waitForTimeout(3_000);
    const out = await page.evaluate(() => {
      const buttons = Array.from(document.querySelectorAll(".start-options > *"))
        .filter((e) => (e as HTMLElement).offsetParent !== null);
      return {
        heading: (document.querySelector(".welcome-title, .welcome-screen h1, .welcome-text")?.textContent ?? "").trim(),
        options: buttons.map((b) => ({
          label: (b.textContent ?? "").trim(),
          inactive: b.classList.contains("inactive") || (b as HTMLButtonElement).disabled === true ||
            b.getAttribute("aria-disabled") === "true",
          title: (b as HTMLElement).title ?? "",
        })),
        panels: Array.from(document.querySelectorAll(".recent-traces-title, .recent-folders-title, .welcome-panel-title"))
          .map((e) => (e.textContent ?? "").trim()),
        tabs: Array.from(document.querySelectorAll("#session-tab-bar > .session-tab .session-tab-label"))
          .map((e) => (e.textContent ?? "").trim()),
      };
    });
    writeAnswers("newTab", out);
    expect((out.options as any[]).length).toBe(6);
  });
});
