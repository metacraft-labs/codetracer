/**
 * THE PANE TAB STRIP CONTAINS TABS, EVENLY SPACED, AND LOSES NONE OF THEM.
 *
 * Four separate reports against noirstudio.dev, all of them the tab bar:
 *
 *   1. "When there is a single tab in a pane, it still displays a bit of a
 *      rounder border/margin on the rightmost side of the tab bar ... now just
 *      creates an awkward empty space at the end of the tab bar."
 *   2. "I'm not sure why the VCS panel is now not drawn in the tab bar next to
 *      the FILES panel. It seems to show up when I unpin the FILES panel."
 *   3. "After I open several files in the main editor area, the margin between
 *      the first and the second tab is inconsistent (larger) than the margins
 *      that separate the other tabs."
 *   4. "When I drop a panel over an existing tab bar, it doesn't show up."
 *
 * The reporter guessed "an upstream update that removed the 3 dots button in
 * each pane broke the rendering of the tab bars". That was right, and it is
 * two mechanisms rather than one — both of them width that is still being
 * reserved for a control that no longer exists. See the commentary on the
 * `stackCreated` handler in `frontend/ui/layout.nim` for the full account.
 *
 * WHY THESE ASSERTIONS ARE GEOMETRIC AND RELATIVE.
 *
 * Every one of these defects is invisible to a markup assertion. The exiled
 * VCS tab was PRESENT in the DOM the whole time — correct class, correct
 * title, correct id — inside a `display: none` list at a 0x0 box. A
 * `toBeAttached()` or an element count passes on the broken build. So:
 *
 *   * tabs are asserted to have a NON-ZERO box, not merely to exist;
 *   * spacing is asserted as a RELATION (every inter-tab gap equal), never
 *     against a hardcoded pixel value, so that changing `LAYOUT_TAB_GAP` in
 *     `golden_layout.styl` stays a legal edit and does not fail this file;
 *   * geometry is read only after two animation frames, because a premature
 *     read returns the previous layout's numbers and then fails quietly in
 *     whichever direction the stale value happened to point.
 *
 * Control data — these assertions run against the shipped build `1a427e3e`
 * (measured through the live bundle at 1600x1000) and fail as:
 *
 *     x stack 0: 1 non-tab element(s) inside .lm_tabs
 *     x stack 0: trailing slack after last tab = 4px
 *     x stack 0: tab "VCS" exiled to display:none list at zero width
 *     x stack 1: inter-tab gaps unequal: [8,4] (min 4, max 8)
 *     x stack 1: 1 non-tab element(s) inside .lm_tabs
 *     x stack 2: 1 non-tab element(s) inside .lm_tabs
 *     x stack 2: trailing slack after last tab = 4px
 *     x stack 3: 1 non-tab element(s) inside .lm_tabs
 *     x stack 3: trailing slack after last tab = 4px
 *
 * `[8,4]` is report 3 in numbers: one 8px gap where the orphaned container
 * sat, 4px everywhere else.
 */

import * as fs from "node:fs";
import * as path from "node:path";

import { test, expect, codetracerInstallDir } from "../../lib/fixtures";

const testFolder = path.join(codetracerInstallDir, "test-programs");

/** Tolerance for a sub-pixel difference between two flex-distributed edges. */
const EPSILON_PX = 0.5;

type StackGeometry = {
  index: number;
  /** Class names of children of `.lm_tabs` that are not tabs. */
  strays: string[];
  /** Titles + widths of the tabs actually in the strip. */
  tabs: { title: string; width: number; x: number; right: number }[];
  /** Gap between each consecutive pair of tabs. */
  gaps: number[];
  /** Distance from the last tab's right edge to the strip's right edge. */
  trailingSlack: number;
  /** Tabs GoldenLayout moved into the hidden overflow list. */
  exiled: { title: string; width: number }[];
};

/**
 * Read the geometry of every GoldenLayout stack header, after layout settles.
 */
async function readStacks(page: any): Promise<StackGeometry[]> {
  // Two frames: the first lets a pending style/layout invalidation flush, the
  // second guarantees we are reading a laid-out box and not a scheduled one.
  await page.evaluate(
    () =>
      new Promise<void>((resolve) =>
        requestAnimationFrame(() => requestAnimationFrame(() => resolve())),
      ),
  );

  return page.evaluate(() => {
    const round = (n: number) => Math.round(n * 100) / 100;
    const titleOf = (el: Element) =>
      (el.querySelector(".lm_title")?.textContent ?? "").trim();

    return [...document.querySelectorAll(".lm_stack")]
      .map((stack, index) => {
        const header = stack.querySelector(":scope > .lm_header");
        if (!header) return null;
        const strip = header.querySelector(".lm_tabs");
        const overflow = header.querySelector(".lm_tabdropdown_list");
        if (!strip) return null;

        const children = [...strip.children];
        const strays = children
          .filter((c) => !c.classList.contains("lm_tab"))
          .map((c) => c.className);

        const tabs = children
          .filter((c) => c.classList.contains("lm_tab"))
          .map((c) => {
            const b = c.getBoundingClientRect();
            return {
              title: titleOf(c),
              width: round(b.width),
              x: round(b.x),
              right: round(b.right),
            };
          });

        const gaps: number[] = [];
        for (let i = 0; i < tabs.length - 1; i++) {
          gaps.push(round(tabs[i + 1].x - tabs[i].right));
        }

        const stripBox = strip.getBoundingClientRect();
        const trailingSlack = tabs.length
          ? round(stripBox.right - tabs[tabs.length - 1].right)
          : 0;

        const exiled = [...(overflow?.children ?? [])].map((c) => ({
          title: titleOf(c),
          width: round(c.getBoundingClientRect().width),
        }));

        return { index, strays, tabs, gaps, trailingSlack, exiled };
      })
      .filter(Boolean);
  });
}

/**
 * The four invariants, asserted against every stack on screen.
 */
function assertStripIsWellFormed(stacks: StackGeometry[], context: string) {
  expect(stacks.length, `${context}: no GoldenLayout stacks on screen`).
    toBeGreaterThan(0);

  for (const s of stacks) {
    // (1) The strip holds tabs and nothing else. An extra flex child is
    // charged a `gap` even at zero width, which is reports 1 and 3.
    expect(
      s.strays,
      `${context}: stack ${s.index} has non-tab children inside .lm_tabs`,
    ).toEqual([]);

    // (2) Nothing was moved into the hidden overflow list. That list is
    // `display: none` and the button that opens it is removed, so a tab in
    // it is unreachable, not merely hidden — reports 2 and 4.
    expect(
      s.exiled,
      `${context}: stack ${s.index} has tabs exiled to .lm_tabdropdown_list`,
    ).toEqual([]);

    // (3) Every tab on screen occupies a real box. An element that exists at
    // zero size is exactly the failure a presence check cannot see.
    for (const t of s.tabs) {
      expect(
        t.width,
        `${context}: stack ${s.index} tab "${t.title}" has a zero-width box`,
      ).toBeGreaterThan(0);
    }

    // (4) Spacing is uniform, and the last tab ends flush with the strip.
    // Asserted as a relation so that changing LAYOUT_TAB_GAP stays legal.
    if (s.gaps.length > 1) {
      const min = Math.min(...s.gaps);
      const max = Math.max(...s.gaps);
      expect(
        max - min,
        `${context}: stack ${s.index} inter-tab gaps are not equal: ` +
          `${JSON.stringify(s.gaps)}`,
      ).toBeLessThanOrEqual(EPSILON_PX);
    }

    expect(
      s.trailingSlack,
      `${context}: stack ${s.index} leaves empty space after the last tab`,
    ).toBeLessThanOrEqual(EPSILON_PX);
  }
}

test.describe("Pane tab strip geometry", () => {
  test.setTimeout(180_000);
  test.use({
    launchMode: "edit",
    editFolderPath: testFolder,
    deploymentMode: "web",
  });

  // Several widths: the exile is a width comparison, so a single viewport
  // could pass by luck. The narrow end is where `availableWidth` bites.
  const WIDTHS = [1600, 1280, 1024];

  for (const width of WIDTHS) {
    test(`strip is well-formed at ${width}px`, async ({ ctPage }) => {
      await ctPage.setViewportSize({ width, height: 900 });
      await ctPage.waitForSelector(".lm_goldenlayout", { timeout: 60_000 });
      await ctPage.waitForSelector(".lm_tab", { timeout: 60_000 });

      const stacks = await readStacks(ctPage);
      assertStripIsWellFormed(stacks, `${width}px`);
    });
  }

  test("FILES and VCS share one strip, both with a real box", async ({
    ctPage,
  }) => {
    // `config/default_layout.json` puts Filesystem and VCS in a single stack.
    // On the shipped build VCS was in the DOM the whole time, at 0x0, inside
    // the hidden overflow list — so this asserts the box, not the element.
    await ctPage.waitForSelector(".lm_goldenlayout", { timeout: 60_000 });
    await ctPage.waitForSelector(".lm_tab", { timeout: 60_000 });

    const stacks = await readStacks(ctPage);
    const titles = stacks.flatMap((s) => s.tabs.map((t) => t.title));

    expect(
      titles,
      `VCS is not in any tab strip; strips hold ${JSON.stringify(titles)}`,
    ).toContain("VCS");

    const vcs = stacks
      .flatMap((s) => s.tabs)
      .find((t) => t.title === "VCS");
    expect(vcs!.width, "VCS tab has a zero-width box").toBeGreaterThan(0);

    // And it is a sibling of FILES rather than a stack of its own.
    const shared = stacks.find((s) =>
      s.tabs.some((t) => t.title === "VCS"),
    );
    expect(
      shared!.tabs.map((t) => t.title),
      "VCS is not in the same strip as FILES",
    ).toContain("FILES");
  });

  test("gaps stay uniform once several editor tabs are open", async ({
    ctPage,
  }) => {
    // Report 3 needs more than two tabs before the uneven gap is visible:
    // the orphaned container ended up between the first and the second.
    await ctPage.waitForSelector(".lm_goldenlayout", { timeout: 60_000 });
    await ctPage.waitForSelector(".jstree-anchor", { timeout: 60_000 });

    const files = ctPage.locator(".jstree-anchor");
    const count = await files.count();
    let opened = 0;
    for (let i = 0; i < count && opened < 3; i++) {
      const name = (await files.nth(i).textContent())?.trim() ?? "";
      if (!/\.\w+$/.test(name)) continue; // folders have no extension
      await files.nth(i).dblclick();
      await ctPage.waitForTimeout(1200);
      opened++;
    }

    expect(opened, "could not open any file from the tree").toBeGreaterThan(0);

    const stacks = await readStacks(ctPage);
    assertStripIsWellFormed(stacks, "after opening editor tabs");

    const widest = stacks.reduce((a, b) =>
      a.tabs.length >= b.tabs.length ? a : b,
    );
    expect(
      widest.tabs.length,
      "expected a stack with more than one editor tab",
    ).toBeGreaterThan(1);
  });
});

/**
 * THE SELECTED PANEL'S OUTLINE DOES NOT LEAVE THE PANEL.
 *
 * A fifth report on the same strip: *"when the last tab in a pane is
 * selected, there is a bit of discontinuity in the border on the right, just
 * below the point where the right border of the tabbar label for the tab
 * begins."*
 *
 * WHY THIS IS NOT DRIVEN THROUGH THE APP LIKE THE TESTS ABOVE.
 * The outline is one stroked SVG path whose `d` is computed from measured
 * geometry by `buildPath`, inside the `{.emit.}` block of
 * `setupSelectedPanelOutline` in `frontend/ui/layout.nim`. The defect is
 * entirely in that arithmetic, and the arithmetic is a pure function of eight
 * rectangles' worth of numbers — so it can be asserted exactly, at every tab
 * position, instead of at whatever three positions a launched app happens to
 * produce. The function is READ OUT OF THE NIM SOURCE rather than
 * transcribed, for the reason the edit-toolbar spec gives about class names: a
 * test carrying its own copy of the code under test cannot see the code change
 * underneath it.
 *
 * WHAT THE DEFECT WAS, IN NUMBERS.
 * On a 400px-wide stack whose last tab is active, the shipped builder emitted
 *
 *     … L 399.5 14.5  A 6 6 0 0 0 405.5 20.5  L 399.5 20.5  A 0 0 0 0 1 …
 *
 * against a panel whose right edge is at 399.5: down the tab's right edge, out
 * SIX PIXELS past the panel, and straight back — a spur beginning just under
 * the tab's top-right corner, which is where the report puts it. The
 * stylesheet had already handled the case twice (`golden_layout.styl` hides
 * the last active tab's `::after` connector and squares the panel's top-right
 * radius, both on `:last-child`); only the path builder had never been told,
 * which is why it also emitted that degenerate zero-radius arc.
 */

const LAYOUT_NIM = path.resolve(
  __dirname,
  "../../../../frontend/ui/layout.nim",
);

type BuildPath = (...args: unknown[]) => string;

/**
 * `buildPath`, lifted out of the `{.emit.}` block it lives in.
 *
 * Sliced between its own `function` keyword and the next one so the extraction
 * fails loudly if the proc is restructured, rather than silently compiling
 * some other function and asserting about it.
 */
function buildPathFromSource(): BuildPath {
  const src = fs.readFileSync(LAYOUT_NIM, "utf8");
  const from = src.indexOf("function buildPath(");
  const to = src.indexOf("function radiusOf(", from);
  if (from < 0 || to < 0) {
    throw new Error(
      `Could not lift buildPath out of ${LAYOUT_NIM}; the emit block has been ` +
        `restructured and this spec must be updated with it.`,
    );
  }
  // eslint-disable-next-line no-new-func
  return new Function(`${src.slice(from, to)}\nreturn buildPath;`)() as BuildPath;
}

/** A 400x300 stack: a 20px tab strip over a panel. */
const STACK = { w: 400, h: 300, panelTop: 20, panelBottom: 300, inset: 0.5 };

/** `.lm_tab`'s 0.36em and the connector's 0.375em, at the 16px root. */
const TAB_RADIUS = 5.76;
const CONNECTOR_RADIUS = 6;

/**
 * Run the builder for a tab spanning [x0, x1].
 *
 * `panelTR` follows the stylesheet: the `:last-child` rule squares the panel's
 * top-right corner, so passing the rounded value for a last tab would be
 * testing a cascade the product does not apply.
 */
function outlineFor(
  buildPath: BuildPath,
  x0: number,
  x1: number,
  isFirst: boolean,
  isLast: boolean,
): string {
  return buildPath(
    STACK.w, STACK.h, x0, x1, 0, STACK.panelTop, STACK.panelBottom,
    TAB_RADIUS, TAB_RADIUS,
    isFirst ? 0 : TAB_RADIUS, // panel top-left, squared for a first tab
    isLast ? 0 : TAB_RADIUS, // panel top-right, squared for a last tab
    TAB_RADIUS, TAB_RADIUS,
    CONNECTOR_RADIUS, STACK.inset, isFirst, isLast,
  );
}

/** Every x the path visits — the endpoint of each M, L and A. */
function xsOf(d: string): number[] {
  const tok = d.trim().split(/\s+/);
  const xs: number[] = [];
  for (let i = 0; i < tok.length; ) {
    if (tok[i] === "M" || tok[i] === "L") { xs.push(Number(tok[i + 1])); i += 3; }
    else if (tok[i] === "A") { xs.push(Number(tok[i + 6])); i += 8; }
    else i += 1;
  }
  return xs;
}

/** Concave connector arcs — sweep flag 0 is what makes a curve a connector. */
function connectorCount(d: string): number {
  return (d.match(/A [\d.]+ [\d.]+ 0 0 0 /g) ?? []).length;
}

test.describe("Selected panel outline", () => {
  test("a last tab's outline stays inside the panel's right edge", () => {
    const buildPath = buildPathFromSource();
    const right = STACK.w - STACK.inset;

    // Every last-tab width, not one: the spur is a fixed 6px overshoot, so a
    // single sample could be dismissed as that tab's arithmetic.
    for (const x0 of [80, 150, 220, 300, 360]) {
      const d = outlineFor(buildPath, x0, STACK.w, false, true);
      const max = Math.max(...xsOf(d));
      expect(
        Number((max - right).toFixed(3)),
        `last tab starting at ${x0}px: the outline reaches x=${max}, ` +
          `${(max - right).toFixed(2)}px past the panel's right edge at ` +
          `${right}. That overshoot is the reported seam — the path leaves ` +
          `the panel and doubles straight back.\n  d = ${d}`,
      ).toBeLessThanOrEqual(0);

      // And it is a seam, not merely an overshoot: prove the path never turns
      // back on itself along the right-hand run.
      expect(
        d,
        `last tab starting at ${x0}px: a zero-radius arc means the builder ` +
          `still drew the corner the stylesheet squared away`,
      ).not.toContain("A 0 0 ");
    }
  });

  test("only the connectors that have room are drawn", () => {
    const buildPath = buildPathFromSource();

    // A middle tab has panel on both sides and keeps both curves. This is the
    // regression guard on the fix: suppressing the right connector for every
    // tab would pass the test above and flatten the product's identity.
    expect(
      connectorCount(outlineFor(buildPath, 150, 260, false, false)),
      "a tab with panel on both sides must keep both concave connectors",
    ).toBe(2);

    // A first tab has nothing to its left; a last tab nothing to its right.
    expect(
      connectorCount(outlineFor(buildPath, 0, 110, true, false)),
      "a first tab keeps its right connector and loses its left",
    ).toBe(1);
    expect(
      connectorCount(outlineFor(buildPath, 300, 400, false, true)),
      "a last tab keeps its left connector and loses its right",
    ).toBe(1);

    // A lone tab spans the whole strip and has room for neither.
    expect(
      connectorCount(outlineFor(buildPath, 0, 400, true, true)),
      "a lone tab is flush on both sides and has room for no connector",
    ).toBe(0);
  });

  test("verify the outline check can fail", () => {
    // The builder as it shipped: no `tabIsLast`, no clamp. Reproduced here
    // rather than described, so the assertion above is watched failing against
    // the geometry the report was made about. If this ever stops overshooting,
    // the check above has stopped measuring the thing it names.
    const shipped = (x1: number, panelTR: number) => {
      const l = STACK.inset;
      const r = STACK.w - STACK.inset;
      const pt = STACK.panelTop + STACK.inset;
      const x1i = x1 - STACK.inset;
      void l;
      return [
        "L", x1i, pt - CONNECTOR_RADIUS,
        "A", CONNECTOR_RADIUS, CONNECTOR_RADIUS, 0, 0, 0, x1i + CONNECTOR_RADIUS, pt,
        "L", r - panelTR, pt,
      ].join(" ");
    };

    const d = shipped(STACK.w, 0);
    const right = STACK.w - STACK.inset;
    const max = Math.max(...xsOf(`M 0 0 ${d}`));

    expect(max, "the shipped builder must overshoot, or this arm proves nothing")
      .toBeGreaterThan(right);
    expect(Number((max - right).toFixed(3))).toBe(CONNECTOR_RADIUS);
  });
});
