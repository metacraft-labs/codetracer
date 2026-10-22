/**
 * plat50-desktop-capture.spec.ts — PLAT-50, the desktop's column: the
 * REFERENCE the terminal and GPUI front-ends are measured against for the
 * user's 2026-10-02 requests.
 *
 * The real Electron front-end on the terminal lanes' own `calc` recording:
 *
 *   * the CAPTION BAR's geometry — the root menu button, the transport
 *     toolbar, the omnibox (`.command-input-row`) and the session strip —
 *     and its colours: the bar's ground, a transport button's ground, the
 *     omnibox's ground and border, the menu button's border;
 *   * the GOLDENLAYOUT strip: the ground behind the tabs (`.lm_header`'s
 *     effective background), a tab's ground, the inactive and active title
 *     colours, a splitter's colour;
 *   * the open MENU's surface (`#menu-main`) and border, and the pane
 *     ground under it;
 *   * the CLICK BEHAVIOURS the native suites mirror: a call-trace row click
 *     and an event-log row click move the debugger (the tick changes); a
 *     gutter click puts a breakpoint on the line and a right-click on its
 *     marker disables it; and the RIGHT-CLICK MENUS' labels — a pane tab, a
 *     call-trace row (a call with children and a leaf), a Files node, the
 *     editor's text.
 *
 * Written to `src/tests/visual/answers/plat50-desktop.electron.json`, which
 * `src/frontend/tui/tests/test_plat50_desktop_reference.nim` asserts beside
 * the shared models (`headless_app/pane_clicks`) the terminal and GPUI read.
 *
 * No mocks: a real `.ct` recording, the real `ct`, a real `replay-server`,
 * the real Electron app. The prefix (this checkout's desktop JavaScript)
 * comes from `scripts/plat45-desktop-prefix.sh` via `PLAT50_DESKTOP_PREFIX`.
 */

import * as fs from "fs";
import * as path from "path";

import { expect } from "@playwright/test";
import { test } from "../../lib/fixtures";

const repoRoot = path.resolve(__dirname, "..", "..", "..", "..", "..");
const answersDir = path.join(repoRoot, "src", "tests", "visual", "answers");
const answersFile = path.join(answersDir, "plat50-desktop.electron.json");

function recording(): string {
  const cache = path.join(repoRoot, "test-logs", "tui-fixtures");
  const hits = fs.existsSync(cache)
    ? fs.readdirSync(cache).filter((e) => e.startsWith("calc-")).sort()
    : [];
  if (hits.length === 0) {
    throw new Error(
      "PLAT-50: the 'calc' recording is not in test-logs/tui-fixtures/; run 'just test-tui' once to record it.",
    );
  }
  return path.join(cache, hits[hits.length - 1]);
}

test.use({
  sourcePath: recording(),
  launchMode: "trace-folder",
  codetracerPrefixOverride: process.env.PLAT50_DESKTOP_PREFIX ?? "",
});
test.setTimeout(300_000);

type Box = { x: number; y: number; w: number; h: number };

test("PLAT-50: the desktop's caption bar, strips, menu surface and click behaviours", async ({ ctPage }) => {
  const out: Record<string, unknown> = {
    _comment: [
      "PLAT-50 — the desktop's chrome and click behaviours, read from the real Electron app on calc.",
      "Produced by src/tests/gui/tests/visual/plat50-desktop-capture.spec.ts",
      "(`bash scripts/plat50-capture-electron.sh`).",
    ],
  };
  // Uncaught exceptions in the renderer: a click handler that throws (the
  // editor's `onMouseDown` on a target without a position did) is a defect
  // the measurements below would not otherwise show.
  const pageErrors: string[] = [];
  ctPage.on("pageerror", (e) => pageErrors.push(String(e?.stack ?? e)));
  await ctPage.waitForSelector(".calltrace-view .call-text", { timeout: 120_000 });
  await ctPage.waitForTimeout(2_000);

  // ---- colours and geometry ---------------------------------------------------
  const chrome = await ctPage.evaluate(() => {
    const hex = (css: string): string => {
      const m = css.match(/rgba?\(\s*(\d+)[ ,]+(\d+)[ ,]+(\d+)(?:[ ,/]+([\d.]+))?/);
      if (!m) return "";
      if (m[4] !== undefined && Number(m[4]) === 0) return "transparent";
      return "#" + [m[1], m[2], m[3]].map((v) => Number(v).toString(16).padStart(2, "0")).join("");
    };
    const effectiveBg = (el: Element | null): string => {
      let e: Element | null = el;
      while (e) {
        const c = hex(getComputedStyle(e).backgroundColor);
        if (c !== "" && c !== "transparent") return c;
        e = e.parentElement;
      }
      return "";
    };
    const box = (el: Element | null) => {
      if (!el) return null;
      const r = el.getBoundingClientRect();
      return { x: Math.round(r.x), y: Math.round(r.y), w: Math.round(r.width), h: Math.round(r.height) };
    };
    const q = (s: string) => document.querySelector(s);
    const field = q(".command-input-row");
    const menuRoot = q("#menu-root");
    const next = q("#next-image");
    const toolbar = q("#isonim-debug-controls");
    const tabs = q("#session-tab-bar");
    const header = q(".lm_header");
    const inactive = q(".lm_tab:not(.lm_active)");
    const active = q(".lm_tab.lm_active");
    return {
      viewportWidth: window.innerWidth,
      bar: { ground: effectiveBg(q("#menu")), box: box(q("#menu")) },
      menuButton: {
        box: box(menuRoot),
        ground: effectiveBg(menuRoot),
        border: menuRoot ? hex(getComputedStyle(menuRoot).borderTopColor) : "",
      },
      toolbar: { box: box(toolbar) },
      transportButton: { ground: effectiveBg(next), box: box(next) },
      omnibox: {
        box: box(field),
        ground: effectiveBg(field),
        border: field ? hex(getComputedStyle(field).borderTopColor) : "",
      },
      sessionStrip: { box: box(tabs) },
      strip: {
        groundBehindTabs: effectiveBg(header),
        inactiveTab: effectiveBg(inactive),
        activeTab: effectiveBg(active),
        inactiveTitle: inactive ? hex(getComputedStyle(inactive.querySelector(".lm_title") ?? inactive).color) : "",
        activeTitle: active ? hex(getComputedStyle(active.querySelector(".lm_title") ?? active).color) : "",
        splitter: effectiveBg(q(".lm_splitter")),
        paneGround: effectiveBg(q(".lm_content")),
      },
    };
  });
  out.chrome = chrome;
  // The omnibox is centred between its two equal-share neighbours.
  const field = chrome.omnibox.box as Box;
  out.omniboxCentre = field.x + field.w / 2;
  out.omniboxShare = field.w / chrome.viewportWidth;

  // ---- the menu's surface -------------------------------------------------------
  await ctPage.locator("#menu-root").click();
  await ctPage.locator("#menu-main").waitFor({ timeout: 30_000 });
  out.menu = await ctPage.evaluate(() => {
    const hex = (css: string): string => {
      const m = css.match(/rgba?\(\s*(\d+)[ ,]+(\d+)[ ,]+(\d+)/);
      return m ? "#" + [m[1], m[2], m[3]].map((v) => Number(v).toString(16).padStart(2, "0")).join("") : "";
    };
    const main = document.querySelector("#menu-main");
    return {
      ground: main ? hex(getComputedStyle(main).backgroundColor) : "",
      border: main ? hex(getComputedStyle(main).borderTopColor) : "",
    };
  });
  await ctPage.evaluate(() => (globalThis as any).__ctMenuVM.close());

  // ---- the right-click menus ----------------------------------------------------
  const menuLabels = async (): Promise<string[]> => {
    await ctPage.locator("#context-menu-container").waitFor({ state: "visible", timeout: 15_000 });
    const items = ctPage.locator("#context-menu-container .context-menu-item");
    const labels: string[] = [];
    for (const item of await items.all()) {
      const label = item.locator(".ct-menu-item-label");
      const text = (await label.count()) > 0 ? await label.first().innerText() : await item.innerText();
      if (text.trim().length > 0) labels.push(text.trim().split("\n")[0]);
    }
    await ctPage.keyboard.press("Escape");
    await ctPage.mouse.click(5, 300);
    await ctPage.waitForTimeout(300);
    return labels;
  };
  // A right-click whose menu is not up within a few seconds is pressed
  // again: the renderer can still be settling a previous press (a pane that
  // just took focus), and a lost press is not what is being measured.
  const rightClickMenu = async (
    target: ReturnType<typeof ctPage.locator>,
    position?: { x: number; y: number },
  ): Promise<string[]> => {
    for (let attempt = 0; attempt < 3; attempt++) {
      await target.click({ button: "right", ...(position ? { position } : {}) });
      try {
        await ctPage.locator("#context-menu-container").waitFor({ state: "visible", timeout: 5_000 });
        break;
      } catch {
        // pressed again below
      }
    }
    return menuLabels();
  };
  const menus: Record<string, string[]> = {};
  menus.tab = await rightClickMenu(ctPage.locator(".lm_tab", { hasText: "VCS" }).first());
  menus.callTraceWithChildren = await rightClickMenu(ctPage.locator(".calltrace-view .call-text", { hasText: "apply_op" }).first());
  menus.callTraceLeaf = await rightClickMenu(ctPage.locator(".calltrace-view .call-text", { hasText: "add" }).first());
  // A Files node: NO menu (its four entries did nothing and were removed).
  await ctPage.locator(".jstree-anchor", { hasText: "main.py" }).first().click({ button: "right" });
  await ctPage.waitForTimeout(800);
  menus.filesNode = (await ctPage.locator("#context-menu-container").isVisible())
    ? await menuLabels() : [];
  // The editor's text, on a line with no breakpoint, in Debug.
  const line31 = ctPage.locator(".monaco-editor .view-line", { hasText: "return left + right" }).first();
  // ON THE LINE'S TEXT, near its start — not at the centre of the
  // `.view-line`, which is as wide as the editor's WIDEST line. Since the
  // recording opens in the module's frame, the flow annotates the module's
  // own lines with their values, some of them long; the centre of a line
  // then lies far right of the visible text, the press scrolls the editor
  // sideways, and lands on nothing.
  menus.editorText = await rightClickMenu(line31, { x: 60, y: 8 });
  // AND A PRESS THAT LANDS ON NO TEXT POSITION, kept on purpose: the
  // editor's own vertical scrollbar, which Monaco's mouse target resolves to
  // no position. The editor's mouse handler once read `lineNumber` off that
  // null position and threw (`ui/editor.nim`, "A press Monaco resolves to no
  // text position"); `pageErrors` below is what notices it. No menu is
  // expected there, so none is waited for. This press used to happen by
  // accident — the right-click on the line's text above landed at the centre
  // of a `.view-line` as wide as the widest line — and the line's own press
  // now lands on its text, so the null-position press is made explicitly.
  // The scrollbar track is drawn only while hovered, so the press is made at
  // its place — the editor's right edge — rather than on its element.
  const editorBox = await line31.locator("xpath=ancestor::div[contains(@class,'monaco-editor')][1]").boundingBox();
  expect(editorBox).not.toBeNull();
  await ctPage.mouse.click(editorBox!.x + editorBox!.width - 4, editorBox!.y + editorBox!.height / 2,
    { button: "right" });
  await ctPage.keyboard.press("Escape");
  // A call's ARGUMENT, and a docked pane's label in the footer.
  menus.callArgument = await rightClickMenu(ctPage.locator(".calltrace-view .call-arg", { hasText: "left" }).first());
  menus.dockLabelBottom = await rightClickMenu(ctPage.locator(".auto-hide-strip-tab", { hasText: /^BUILD$/i }).first());
  out.menus = menus;

  // ---- the click behaviours -----------------------------------------------------
  const where = async () =>
    ctPage.evaluate(() => {
      const loc = (globalThis as any).data?.services?.debugger?.location;
      return { line: loc?.line ?? -1, ticks: Number(loc?.rrTicks ?? -1) };
    });
  const waitMoved = async (from: { ticks: number }) => {
    const deadline = Date.now() + 30_000;
    let now = await where();
    while (Date.now() < deadline && now.ticks === from.ticks) {
      await ctPage.waitForTimeout(200);
      now = await where();
    }
    return now;
  };
  const clicks: Record<string, unknown> = {};
  // The gutter first, while line 31 is on screen: a click on its line
  // number puts a breakpoint there; a right-click disables it.
  const gutter = ctPage.locator(".monaco-editor .margin-view-overlays .gutter[data-line='31']").first();
  if ((await gutter.count()) > 0) {
    await gutter.locator(".gutter-line").first().click();
    await ctPage.waitForTimeout(800);
    clicks.gutterBreakpoint = await ctPage.locator(
      ".monaco-editor .margin-view-overlays .gutter[data-line='31'] .gutter-breakpoint-enabled").count() > 0;
    // The right-click lands on the breakpoint's own marker — the element the
    // desktop's `lineActionContextMenu` is written for.
    await ctPage.locator(".monaco-editor .margin-view-overlays .gutter[data-line='31'] .gutter-breakpoint-enabled")
      .first().click({ button: "right" });
    await ctPage.waitForTimeout(800);
    // AND NO MENU: the marker's right-click is the enable / disable toggle and
    // nothing else (`Editor-Pane.md`, the gutter's gesture 8). Monaco's own
    // `onContextMenu` used to answer the same press with the editor's menu,
    // built BEFORE the toggle ran, so it offered "Disable breakpoint" for the
    // breakpoint the press had just disabled — and that stale menu was still
    // open when the next right-click read it (codetracer-pm issue
    // 2026-10-04-desktop-editor-menu-offers-disable-for-a-just-disabled-
    // breakpoint).
    clicks.gutterRightClickMenu = await ctPage.locator("#context-menu-container").isVisible();
    clicks.gutterDisabled = await ctPage.locator(
      ".monaco-editor .margin-view-overlays .gutter[data-line='31'] .gutter-breakpoint-disabled").count() > 0;
    // The editor's menu on a line WITH a breakpoint — the one just disabled,
    // so its entry reads "Enable breakpoint", on the FIRST press as on the
    // second. Both are recorded and both are asserted below.
    //
    // Each press is made on line 31 brought to the editor's CENTRE first. By
    // now the debugger has moved and the editor has scrolled line 31 under
    // Monaco's sticky-scroll header (`.overlayWidgets`), which then takes the
    // press: Playwright reports it intercepting pointer events and the press
    // never reaches the line. The press is made near the line's start, as the
    // breakpoint-free `editorText` press above is, and for its reason.
    const centreLine31 = async () => {
      await ctPage.evaluate(() => {
        const editors = (globalThis as any).data?.ui?.editors ?? {};
        for (const key of Object.keys(editors)) {
          editors[key]?.monacoEditor?.revealLineInCenter?.(31);
        }
      });
      await ctPage.waitForTimeout(300);
    };
    const line31OnBreakpoint = () =>
      ctPage.locator(".monaco-editor .view-line", { hasText: "return left + right" }).first();
    await centreLine31();
    menus.editorTextOnBreakpointFirst = await rightClickMenu(line31OnBreakpoint(), { x: 60, y: 8 });
    await centreLine31();
    menus.editorTextOnBreakpoint = await rightClickMenu(line31OnBreakpoint(), { x: 60, y: 8 });
  }
  // A disabled breakpoint does not stop the jumps below.
  const start = await where();
  await ctPage.locator(".calltrace-view .call-text", { hasText: "add" }).first().click();
  const afterCall = await waitMoved(start);
  clicks.callTraceRow = { from: start, to: afterCall, moved: afterCall.ticks !== start.ticks };
  const eventRow = ctPage.locator("tr", { hasText: "10 - 4 + 1 = 7" }).first();
  await eventRow.click();
  const afterEvent = await waitMoved(afterCall);
  clicks.eventLogRow = { from: afterCall, to: afterEvent, moved: afterEvent.ticks !== afterCall.ticks };

  // THE REST OF THE SWEEP, measured here so the native suites' claims about
  // the desktop are readings rather than recollections.
  //
  // A Variables row's menu, at the event's stop (`value`, `expression` …).
  const varRow = ctPage.locator("[data-variable-name]").first();
  if ((await varRow.count()) > 0) {
    menus.variablesRow = await rightClickMenu(varRow);
  }
  // An inline (flow) value's menu, where the editor draws one.
  const flowSelector =
    ".flow-parallel-value-box, .flow-inline-value-box, .flow-multiline-value-box";
  const onScreen = await ctPage.evaluate((sel) => {
    const els = Array.from(document.querySelectorAll(sel)) as HTMLElement[];
    return els.findIndex((el) => {
      const r = el.getBoundingClientRect();
      return r.width > 0 && r.top >= 0 && r.left >= 0 &&
        r.bottom <= window.innerHeight && r.right <= window.innerWidth;
    });
  }, flowSelector);
  if (onScreen >= 0) {
    await ctPage.locator(flowSelector).nth(onScreen).click({ button: "right", timeout: 10_000 });
    menus.flowValue = await menuLabels();
  }
  // The event log's header: the first row's output before and after a
  // click on the `output` column (and after a second click).
  const firstOutput = async () =>
    ctPage.evaluate(() => {
      const cell = document.querySelector("table[id*=\"-dense-table-\"] tbody tr .eventLog-text") as HTMLElement | null;
      return cell ? cell.innerText.trim() : "";
    });
  // The header the desktop shows is its own strip (`ui/event_log.
  // renderColumnHeader`; DataTables' header row is hidden).
  const header = ctPage.locator(".eventLog-column-header .eventLog-cell", { hasText: /^output( [▲▼])?$/ }).first();
  if ((await header.count()) > 0) {
    const before = await firstOutput();
    await header.click();
    await ctPage.waitForTimeout(1500);
    const ascending = await firstOutput();
    await header.click();
    await ctPage.waitForTimeout(1500);
    const descending = await firstOutput();
    const arrow = async () => (await header.innerText()).trim();
    clicks.eventLogSort = { before, ascending, descending, header: await arrow() };
  }
  // A call argument's LEFT click: does a value tooltip open, is the row
  // selected, does the debugger move?
  const argument = ctPage.locator(".calltrace-view .call-arg", { hasText: "left" }).first();
  const argFrom = await where();
  await argument.click();
  await ctPage.waitForTimeout(1500);
  const argTo = await where();
  clicks.callArgumentClick = {
    tooltip: (await ctPage.locator(".calltrace-view .value-tooltip, .call-tooltip, .ct-tooltip:visible").count()) > 0,
    rowClass: await argument.evaluate((el) => el.closest(".calltrace-call-line")?.className ?? ""),
    moved: argTo.ticks !== argFrom.ticks,
  };
  // The status bar's copy control: the location on the clipboard.
  //
  // THE CONTROL IS HIDDEN BY DESIGN, AND THE ACTION IS WHAT IS MEASURED.
  // `status_bar.styl`'s "HIDDEN FOR NOW" rule (2026-10-15) sets the location
  // path and `#copy-path-image` to `display: none`, so a pointer click waits
  // for a box that never appears and the capture died here, before writing
  // any answers. Whether the readout comes back is an open design decision
  // (codetracer-pm issue 2026-10-20-ready-on-entry-waits-for-a-location-path-
  // the-status-bar-now-hides-by-design.md), not this capture's to make. What
  // the native front-ends are compared against is the copy ACTION the control
  // is wired to (`isonim_status_view`'s `onclick`, `invokeCopyLocation`), so
  // a hidden control gets the same `click` event dispatched straight to it.
  // `statusCopyControlVisible` records which of the two happened, so the
  // answers file says whether a user could have made this press at all.
  //
  // Not a way around a failure: the clipboard is emptied first and read
  // after, and a gate below requires the location on it, so a copy action
  // that did not run fails this capture rather than writing answers. The
  // emptying matters when the capture runs on a real desktop's DISPLAY,
  // whose clipboard can still hold the path an earlier run copied.
  const copy = ctPage.locator("#copy-path-image").first();
  if ((await copy.count()) > 0) {
    await ctPage.evaluate(() => {
      (globalThis as any).require?.("electron")?.clipboard?.writeText?.("");
    });
    clicks.statusCopyControlVisible = await copy.isVisible();
    if (clicks.statusCopyControlVisible) {
      await copy.click();
    } else {
      await copy.dispatchEvent("click");
    }
    await ctPage.waitForTimeout(500);
    clicks.statusLocationCopied = await ctPage.evaluate(async () => {
      try {
        // Electron's renderer reads the system clipboard it just wrote.
        const electron = (globalThis as any).require?.("electron");
        if (electron?.clipboard) return electron.clipboard.readText();
        return await navigator.clipboard.readText();
      } catch (e) { return "error: " + String(e); }
    });
  }
  out.clicks = clicks;

  // THE GATES: what the native front-ends are measured against must have
  // happened here.
  expect(clicks.callTraceRow).toMatchObject({ moved: true });
  expect(clicks.gutterBreakpoint).toBe(true);
  expect(clicks.gutterDisabled).toBe(true);
  expect(clicks.eventLogRow).toMatchObject({ moved: true });
  expect(menus.tab.slice(0, 4)).toEqual(["Pin to Left", "Pin to Bottom", "Pin to Right", "Close"]);
  expect(menus.filesNode).toEqual([]);
  const sort = clicks.eventLogSort as { ascending: unknown; descending: unknown };
  expect(sort.ascending).not.toEqual(sort.descending);
  expect(menus.callTraceWithChildren).toEqual(["Collapse Call Children"]);
  expect(clicks.gutterRightClickMenu).toBe(false);
  expect(menus.editorTextOnBreakpointFirst).toContain("Enable breakpoint");
  expect(menus.editorTextOnBreakpoint).toContain("Enable breakpoint");
  // The status bar's copy action put the location on the clipboard (pressed
  // or, while the control is hidden, dispatched to it; see above).
  expect(String(clicks.statusLocationCopied ?? "")).toContain("main.py");
  // An argument takes no left press of its own on the desktop: no tooltip,
  // and the debugger stays (only the call's name is the row's target).
  expect(clicks.callArgumentClick).toMatchObject({ tooltip: false, moved: false });
  out.pageErrors = pageErrors;
  expect(pageErrors).toEqual([]);

  fs.mkdirSync(answersDir, { recursive: true });
  fs.writeFileSync(answersFile, JSON.stringify(out, null, 1) + "\n");
});
