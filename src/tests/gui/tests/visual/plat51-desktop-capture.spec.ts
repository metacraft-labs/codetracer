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
