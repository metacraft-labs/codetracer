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
