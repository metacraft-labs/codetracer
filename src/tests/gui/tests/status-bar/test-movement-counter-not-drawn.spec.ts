/**
 * The test-only move counter is in the DOM but is not drawn.
 *
 * Every Electron launch of the fixture runs with `CODETRACER_TEST=1`, so the
 * renderer runs with `data.startOptions.inTest` set. Under that flag the
 * status bar emits `span.test-movement`, the number of completed moves
 * (`ui/status.nim` sets `showTestMovement` from `inTest`,
 * `viewmodel/views/isonim_status_view.nim` renders it before
 * `.status-right`). A production renderer never emits it. While the fixture
 * let it be drawn, every Electron frame the parity lanes captured as the
 * reference for the native (GPUI) front-end carried a number in front of
 * "No certificates" (`4`, `14`, `20`). The native front-end has no such
 * element, so the comparison reported a difference the harness had made.
 * The PLAT-49 footer census recorded the counter as a status-bar part too.
 *
 * This spec asserts the fixture's contract (`showTestMovementCounter`,
 * `lib/fixtures.ts`):
 *
 *   * POSITIVE CONTROL. The counter is in the DOM, and its text is a number
 *     that moves when the debugger moves. That shows the launch really ran
 *     under `inTest`, so the absence asserted next is not an absence of
 *     the harness condition.
 *   * THE FRAME MATCHES PRODUCTION. The counter has no box, and the census
 *     of `#status-base`'s visible children (the walk the PLAT-49 capture
 *     uses for `statusParts`) has no `test-movement` entry.
 *   * THE OPT-OUT WORKS. With `showTestMovementCounter: true` the counter is
 *     drawn, which shows the hiding comes from the option and not from
 *     something else.
 *
 * No mocks: the spec drives the real Electron app against a trace that the
 * fixture records from a real program.
 */
import type { Page } from "@playwright/test";

import { test, expect } from "../../lib/fixtures";
import { LayoutPage } from "../../page-objects/layout-page";

const SOURCE = "py_console_logs/main.py";

/** The counter's text and box, read in one synchronous pass. */
async function readCounter(page: Page) {
  return page.evaluate(() => {
    const el = document.querySelector("#status-base .test-movement") as HTMLElement | null;
    if (!el) return null;
    const r = el.getBoundingClientRect();
    return {
      text: (el.textContent ?? "").trim(),
      width: r.width,
      height: r.height,
      display: getComputedStyle(el).display,
    };
  });
}

/**
 * The status bar's visible parts, left to right: each child of
 * `#status-base` (and its children, one level down) that has a box. This is
 * the walk `tests/visual/plat49-panes-capture.spec.ts` records as
 * `statusParts`, so what it sees is what that reference answer records.
 */
async function statusParts(page: Page): Promise<string[]> {
  return page.evaluate(() => {
    const base = document.getElementById("status-base");
    if (!base) return [];
    const parts: string[] = [];
    const walk = (e: Element, depth: number) => {
      for (const c of Array.from(e.children)) {
        const r = (c as HTMLElement).getBoundingClientRect();
        if (r.width > 0 && r.height > 0) parts.push((c as HTMLElement).className);
        if (depth < 1) walk(c, depth + 1);
      }
    };
    walk(base, 0);
    return parts;
  });
}

/** Launch, wait for the session, step once, and wait for the counter to move. */
async function stepAndReadCounter(page: Page) {
  const layout = new LayoutPage(page);
  await layout.waitForBaseComponentsLoaded();
  await layout.waitForStateLoaded();

  // POSITIVE CONTROL, part 1: `inTest` is on, so the counter is emitted.
  await expect
    .poll(async () => (await readCounter(page))?.text ?? null, {
      message: "span.test-movement is not in #status-base, so this launch did not run under inTest",
      timeout: 60_000,
    })
    .toMatch(/^\d+$/);
  const before = Number((await readCounter(page))!.text);

  await layout.clickNextButton();

  // POSITIVE CONTROL, part 2: the counter is live, and it counts the move.
  await expect
    .poll(async () => Number((await readCounter(page))?.text ?? NaN), {
      message: "the completed-move counter did not advance after a step",
      timeout: 60_000,
    })
    .toBeGreaterThan(before);
  return readCounter(page);
}

test.describe("test-only move counter, default launch", () => {
  test.use({ sourcePath: SOURCE, launchMode: "trace" });

  test("is emitted under inTest but has no box, so the frame matches production", async ({
    ctPage,
  }) => {
    test.setTimeout(240_000);
    const counter = await stepAndReadCounter(ctPage);

    expect(
      { width: counter!.width, height: counter!.height, display: counter!.display },
      "the test-only move counter is drawn in the status bar. A production " +
        "renderer does not emit it, so every reference frame and footer " +
        "census taken from this launch differs from what a user sees",
    ).toEqual({ width: 0, height: 0, display: "none" });

    const parts = await statusParts(ctPage);
    // The census must have read a real bar, or its absence check is vacuous.
    expect(parts, "the status-bar census found no visible parts").toContain("status-right");
    expect(parts.filter((cls) => cls.split(/\s+/).includes("test-movement"))).toEqual([]);
  });
});

test.describe("test-only move counter, opted back in", () => {
  test.use({ sourcePath: SOURCE, launchMode: "trace", showTestMovementCounter: true });

  test("is drawn when a spec asks for it", async ({ ctPage }) => {
    test.setTimeout(240_000);
    const counter = await stepAndReadCounter(ctPage);
    expect(counter!.display).not.toBe("none");
    expect(counter!.width).toBeGreaterThan(0);
    expect(counter!.height).toBeGreaterThan(0);
    expect(await statusParts(ctPage)).toContain("test-movement");
  });
});
