/**
 * plat52-terminal-capture.spec.ts — PLAT-52, the desktop's column: the
 * REFERENCE the terminal's and the GPUI window's Terminal Output panes are
 * measured against.
 *
 * The real Electron front-end on the two recordings the terminal lanes record
 * (`test-programs/terminal_colours`, `test-programs/terminal_screen`):
 *
 *   * the LINE view — every line's text and, per fragment, the write it came
 *     from, its tense class (past / active / future) and the computed style
 *     the desktop draws it in (colour, ground, weight, slant, decoration, the
 *     opacity the `.future` class gives it) — at the program's entry and
 *     after a click on a fragment, which must move the debugger to its write
 *     (K32); and what a right-click on a line opens (the desktop has no menu
 *     there — measured, so the native panes are measured against it);
 *   * the SCREEN view — offered and shown for the full-screen program, its
 *     rows at the writes the scrubber is dragged across, the debugger's tick
 *     at each step of the drag (the scrubber is REAL-TIME, the user's
 *     2026-10-06 decision), the marks under the slider, ArrowRight's step,
 *     and the toggle back to the lines.
 *
 * Written to `src/tests/visual/answers/plat52-terminal.electron.json`, which
 * `src/frontend/tui/tests/test_plat52_desktop_reference.nim` and
 * `src/frontend/gpui/tests/test_plat52_gpui_plan.nim` assert the native
 * panes against.
 *
 * No mocks: real `.ct` recordings, the real `ct`, a real `replay-server`, the
 * real Electron app. The prefix (this checkout's desktop JavaScript) comes
 * from `scripts/plat45-desktop-prefix.sh` via `PLAT52_DESKTOP_PREFIX`.
 */

import * as fs from "fs";
import * as path from "path";

import { expect } from "@playwright/test";
import { test } from "../../lib/fixtures";

const repoRoot = path.resolve(__dirname, "..", "..", "..", "..", "..");
const answersDir = path.join(repoRoot, "src", "tests", "visual", "answers");
const answersFile = path.join(answersDir, "plat52-terminal.electron.json");

function recording(prefix: string): string {
  const cache = path.join(repoRoot, "test-logs", "tui-fixtures");
  const hits = fs.existsSync(cache)
    ? fs.readdirSync(cache).filter((e) => e.startsWith(prefix + "-")).sort()
    : [];
  if (hits.length === 0) {
    throw new Error(
      `PLAT-52: the '${prefix}' recording is not in test-logs/tui-fixtures/; ` +
        "run scripts/plat52-capture-electron.sh (it records it).",
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
    "PLAT-52 — the desktop's Terminal Output pane, read from the real Electron app.",
    "Produced by src/tests/gui/tests/visual/plat52-terminal-capture.spec.ts",
    "(`bash scripts/plat52-capture-electron.sh`).",
  ];
  out[part] = value;
  fs.mkdirSync(answersDir, { recursive: true });
  fs.writeFileSync(answersFile, JSON.stringify(out, null, 1) + "\n");
}

type Fragment = {
  text: string;
  tense: string;
  write: number;
  color: string;
  background: string;
  weight: string;
  fontStyle: string;
  decoration: string;
  opacity: string;
};

test.setTimeout(400_000);

const prefix = process.env.PLAT52_DESKTOP_PREFIX ?? "";

async function showTerminal(page: any) {
  // GoldenLayout activates a tab on a press on its title (the page object's
  // `TerminalOutputPane.tabButton`); pressed again until the pane shows.
  const title = page.locator(".lm_tab[title='TERMINAL OUTPUT'] .lm_title").first();
  await title.waitFor({ state: "visible", timeout: 120_000 });
  const content = page.locator(
    ".isonim-terminal-output[data-terminal-view='lines'] pre .terminal-line, " +
      ".isonim-terminal-output[data-terminal-view='screen'] .terminal-screen-row").first();
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
  await page.waitForTimeout(1_000);
}

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

async function readLines(page: any): Promise<{ text: string; fragments: Fragment[] }[]> {
  return page.evaluate(() => {
    const hex = (css: string): string => {
      const m = css.match(/rgba?\(\s*(\d+)[ ,]+(\d+)[ ,]+(\d+)(?:[ ,/]+([\d.]+))?/);
      if (!m) return "";
      if (m[4] !== undefined && Number(m[4]) === 0) return "transparent";
      return "#" + [m[1], m[2], m[3]].map((v) => Number(v).toString(16).padStart(2, "0")).join("");
    };
    const lines = Array.from(document.querySelectorAll(".isonim-terminal-output pre .terminal-line"));
    return lines.map((line) => {
      const fragments = Array.from(line.children).map((frag) => {
        const span = frag.querySelector("span") as HTMLElement | null;
        const s = getComputedStyle(span ?? (frag as HTMLElement));
        return {
          text: (frag.textContent ?? ""),
          tense: frag.className,
          write: Number((frag as HTMLElement).dataset.eventIndex ?? -1),
          color: hex(s.color),
          background: hex(s.backgroundColor),
          weight: s.fontWeight,
          fontStyle: s.fontStyle,
          decoration: s.textDecorationLine,
          opacity: getComputedStyle(frag as HTMLElement).opacity,
        };
      });
      return { text: line.textContent ?? "", fragments };
    });
  });
}

test.describe("PLAT-52: the desktop's line view", () => {
  test.use({
    sourcePath: recording("terminal_colours"),
    launchMode: "trace-folder",
    noUserLayout: true,
    codetracerPrefixOverride: prefix,
  });

  test("PLAT-52: lines, their styles, a click on a fragment, no menu", async ({ ctPage }) => {
    const pageErrors: string[] = [];
    ctPage.on("pageerror", (e) => pageErrors.push(String(e?.stack ?? e)));
    await ctPage.waitForSelector(".calltrace-view .call-text", { timeout: 120_000 });
    await showTerminal(ctPage);
    const out: Record<string, unknown> = {};
    out.start = await where(ctPage);
    out.view = await ctPage.locator(".isonim-terminal-output").getAttribute("data-terminal-view");
    out.toggleShown = await ctPage.locator(".isonim-terminal-output .terminal-view-toggle").isVisible();
    out.linesAtStart = await readLines(ctPage);

    // A right-click on a line: whatever the desktop opens there.
    await ctPage.locator(".isonim-terminal-output .terminal-line").nth(2).click({ button: "right" });
    let menu: string[] = [];
    try {
      await ctPage.locator("#context-menu-container").waitFor({ state: "visible", timeout: 3_000 });
      menu = await ctPage.locator("#context-menu-container .context-menu-item").allInnerTexts();
      await ctPage.keyboard.press("Escape");
    } catch {
      menu = [];
    }
    out.lineContextMenu = menu;

    // Let anything the right-click set off settle before the click is timed.
    await ctPage.waitForTimeout(2_000);
    out.afterRightClick = await where(ctPage);
    // K32: a click on the fragment of line 10 ("row   2 ###") goes to its write.
    const before = await where(ctPage);
    const fragment = ctPage.locator(".isonim-terminal-output #terminal-line-10 > div").first();
    const write = Number(await fragment.getAttribute("data-event-index"));
    await fragment.click();
    const after = await waitMoved(ctPage, before);
    // Every position the debugger passes through in the next few seconds:
    // the click's move must be the last word.
    const seen: number[] = [after.ticks];
    for (let i = 0; i < 15; i++) {
      await ctPage.waitForTimeout(200);
      const t = (await where(ctPage)).ticks;
      if (t !== seen[seen.length - 1]) seen.push(t);
    }
    out.ticksSeenAfterClick = seen;
    // What the click sent (the renderer's test-mode request recorder).
    out.jumpRequests = await ctPage.evaluate(() =>
      ((globalThis as any).__CODETRACER_TEST__?.vmBackendRequests ?? [])
        .filter((r: any) => String(r.command) === "ct/event-jump")
        .map((r: any) => r.args));
    out.click = { line: 10, write, before, after, moved: after.ticks !== before.ticks };
    out.linesAfterClick = await readLines(ctPage);
    out.pageErrors = pageErrors;

    expect(out.view).toBe("lines");
    expect((out.click as { moved: boolean }).moved).toBe(true);
    expect((out.linesAtStart as unknown[]).length).toBe(129);
    expect(pageErrors).toEqual([]);
    writeAnswers("lines", out);
  });
});

test.describe("PLAT-52: the desktop's screen view", () => {
  test.use({
    sourcePath: recording("terminal_screen"),
    launchMode: "trace-folder",
    noUserLayout: true,
    codetracerPrefixOverride: prefix,
  });

  test("PLAT-52: the screen, its real-time scrubber, its marks, the toggle", async ({ ctPage }) => {
    const pageErrors: string[] = [];
    ctPage.on("pageerror", (e) => pageErrors.push(String(e?.stack ?? e)));
    await ctPage.waitForSelector(".calltrace-view .call-text", { timeout: 120_000 });
    await showTerminal(ctPage);
    const out: Record<string, unknown> = {};
    const root = ctPage.locator(".isonim-terminal-output");
    out.view = await root.getAttribute("data-terminal-view");
    out.toggleShown = await root.locator(".terminal-view-toggle").isVisible();
    const range = root.locator(".terminal-scrubber-range");
    out.rangeMax = Number(await range.getAttribute("max"));
    out.marks = await root.locator(".terminal-scrubber-mark").evaluateAll((els) =>
      els.map((el) => ({
        kind: (el as HTMLElement).dataset.kind,
        write: Number((el as HTMLElement).dataset.write),
      })),
    );
    const rows = () =>
      root.locator(".terminal-screen-row").evaluateAll((els) => els.map((el) => el.textContent ?? ""));
    const gridWrite = async () => Number(await root.locator(".terminal-screen-grid").getAttribute("data-write"));

    // A DRAG of the scrubber: `input` events, as the range control fires
    // them while its thumb is held. The scrubber is real-time — the debugger
    // moves at each step, before the release (`change`).
    // At each target: the move made WHILE HELD (before any release), then the
    // release, and the screen as of the tick it left the debugger at.
    const steps: unknown[] = [];
    for (const target of [3, 12, 24]) {
      const before = await where(ctPage);
      await range.evaluate((el, v) => {
        (el as HTMLInputElement).value = String(v);
        el.dispatchEvent(new Event("input", { bubbles: true }));
      }, target);
      const held = await waitMoved(ctPage, before);
      await ctPage.waitForTimeout(500);
      const heldWrite = await gridWrite();
      await range.evaluate((el) => el.dispatchEvent(new Event("change", { bubbles: true })));
      await ctPage.waitForTimeout(800);
      const now = await where(ctPage);
      steps.push({ target, heldTicks: held.ticks, heldWrite, ticks: now.ticks,
                   write: await gridWrite(), rows: await rows() });
    }
    out.drag = steps;

    // ArrowRight on the screen: the next write.
    const beforeKey = await where(ctPage);
    await root.locator(".terminal-screen").focus();
    await ctPage.keyboard.press("ArrowRight");
    const afterKey = await waitMoved(ctPage, beforeKey);
    await ctPage.waitForTimeout(800);
    out.stepRight = { before: beforeKey, after: afterKey, write: await gridWrite() };

    // The toggle: the lines.
    await root.locator(".terminal-view-button[data-view='lines']").click();
    await ctPage.waitForTimeout(500);
    out.afterToggle = await root.getAttribute("data-terminal-view");
    out.pageErrors = pageErrors;

    expect(out.view).toBe("screen");
    expect(out.toggleShown).toBe(true);
    for (const s of steps as { heldTicks: number; ticks: number }[]) {
      expect(s.heldTicks).toBeGreaterThan(0);
      expect(s.ticks).toBe(s.heldTicks);
    }
    expect(out.afterToggle).toBe("lines");
    expect(pageErrors).toEqual([]);
    writeAnswers("screen", out);
  });
});
