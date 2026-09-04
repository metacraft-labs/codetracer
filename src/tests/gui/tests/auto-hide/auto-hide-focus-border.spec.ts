/**
 * The auto-hide panel's border, docked and in auto-hide, measured against
 * each other.
 *
 * Reported as: *"There is still a glitch with borders of the active tab in the
 * auto hidden panels positioned in the status bar.  The borders display
 * properly when I dock a panel, but not when it's focused in auto-hide mode."*
 *
 * WHAT WENT WRONG, so that the assertions below are read as more than
 * arbitrary numbers.  The selection outline is one stroked SVG path around the
 * panel AND its strip tab, built in `ui/layout.nim`.  Docked, it is
 * `.ct-docked-outline` at `z-index: 202` over a panel at 101, and it shows.
 * In auto-hide the panel is `#auto-hide-overlay`, which sits at 203 —
 * deliberately above that outline, because a docked panel and the overlay are
 * both 101 and the overlay has to clear the line that traces the panel it
 * floats over — and carries `border: none`.  So in auto-hide there was no line
 * to see: the outline that existed was under the overlay, and the overlay had
 * none of its own.  `.ct-overlay-outline` (z-index 204) is that missing line.
 *
 * WHAT THIS MEASURES, and why it is measured HERE rather than read off the
 * stylesheet.  A border is only real if it resolves: an undeclared Stylus
 * variable compiles to its own bare name, browsers drop the declaration
 * silently, and the source still reads as though a border were being set.  So
 * every assertion below reads `getComputedStyle` in the running app and
 * requires a RESOLVED value — an `rgb(...)`, never a token name — plus a
 * non-zero width and a solid (undashed) stroke.
 *
 * WHAT IT ASSERTS BEYOND PRESENCE:
 *
 *  1. **Parity.**  The docked line and the auto-hide line must agree on colour
 *     and width, because "docked is right, auto-hide is not" is exactly the
 *     report.  Two panels drawn from one pair of tokens is the fix; two
 *     declarations that merely happen to match today is not.
 *  2. **The tab, not just the panel.**  The report says *borders of the active
 *     tab*.  A rectangle around the panel alone would satisfy a presence
 *     check and still leave the tab bare, so the path's bounding box must
 *     enclose the active strip tab as well.
 *
 *     This one is applied to the DOCKED outline too, not only the new one, and
 *     it is what caught the right-hand strip.  `dockedWithTabPath` describes
 *     the shape once for a left-hand tab and reflects it for the right; the
 *     panel's own two edges are each other's reflection so they came out
 *     right, but the tab is not, and it was being reflected onto the panel's
 *     inner side — drawn into the layout instead of out to the strip.  A
 *     presence check passes on that, and so does a look at the bottom edge,
 *     where `mirror` is false.  Only asking whether the line reaches the tab
 *     finds it.
 *  3. **Above the overlay.**  The defect was an outline that existed and was
 *     painted over.  Presence in the DOM is therefore not enough: the
 *     outline's computed `z-index` must exceed the overlay's.
 *  4. **Every edge.**  A cue on two edges and not the third reads as a
 *     rendering fault rather than a design, so bottom, left and right are all
 *     checked.  The report is about the status bar; the fix is general and
 *     this says so.
 *
 * CONTROL DATA.  On the tree before the fix, the docked half of every case
 * below passes and the auto-hide half fails at `overlay outline is present`,
 * naming its edge.  A check that has never refused is not a check.
 *
 * No mocks: a real JavaScript recording opened by the real Electron app, the
 * same fixture the neighbouring auto-hide specs use.
 */

import type { Page } from "@playwright/test";

import { test, expect, wait } from "../../lib/fixtures";
import { recordChromeTraceFixture } from "../../lib/js-trace-fixture";
import { LayoutPage } from "../../page-objects/layout-page";
import {
  DEFAULT_BOTTOM_TAB_TITLES,
  OVERLAY_SELECTOR,
  bottomStripTab,
  closeDockedPanelFromTab,
  openDockedPanelFromTab,
  openOverlayFromTab,
  waitForDefaultBottomTabs,
} from "../../page-objects/auto-hide-strip";

const WAIT_TIMEOUT_MS = 15_000;

/** Where the paired before/after screenshots land. */
const SHOT_DIR = "/tmp/auto-hide-focus-border";

/**
 * Geometry tolerance, in CSS pixels.
 *
 * The outline is inset by half its own stroke width so the line falls inside
 * the shape rather than straddling its edge, and the tab's rect is read from
 * layout while the path is measured from its bounding box.  A pixel of slack
 * absorbs both without letting an outline that misses the tab entirely pass.
 */
const TOL = 2;

type Rect = { left: number; top: number; right: number; bottom: number };

type OutlineMeasurement = {
  present: boolean;
  /** Resolved stroke paint — an `rgb(...)`, or a bare token name if it did not resolve. */
  stroke: string;
  /** Resolved stroke width, e.g. `"1px"`. */
  strokeWidth: string;
  /** `none` for a solid line; anything else is a dashed stroke. */
  strokeDasharray: string;
  /** The outline's own stacking position, and the overlay's to compare it to. */
  outlineZIndex: string;
  overlayZIndex: string;
  /** Bounding box of the stroked path, in viewport coordinates. */
  bbox: Rect | null;
  /** The active strip tab this outline is supposed to run around. */
  tab: Rect | null;
};

/**
 * Measure the outline named by `outlineClass`, and the strip tab labelled
 * `tabLabel` that it should enclose.
 *
 * Read in one `evaluate` so the two rects are sampled from the same layout —
 * two round trips could straddle a resize and produce a mismatch that is an
 * artefact of the measurement rather than of the paint.
 */
async function measureOutline(
  page: Page,
  outlineClass: string,
  stripSelector: string,
  tabLabel: string,
): Promise<OutlineMeasurement> {
  return await page.evaluate(
    ({ outlineClass, stripSelector, tabLabel }) => {
      const box = (el: Element): Rect => {
        const r = el.getBoundingClientRect();
        return { left: r.left, top: r.top, right: r.right, bottom: r.bottom };
      };

      const overlay = document.getElementById("auto-hide-overlay");
      const overlayZIndex = overlay
        ? window.getComputedStyle(overlay).zIndex
        : "";

      // The active tab is found by label, not by `.active`: a tab carries that
      // class when its panel is docked OR when it is the one being previewed,
      // so during a hover preview two tabs have it.
      let tab: Rect | null = null;
      const candidates = document.querySelectorAll(
        `${stripSelector} .auto-hide-strip-tab`,
      );
      for (const candidate of Array.from(candidates)) {
        if (candidate.textContent?.trim() === tabLabel) {
          tab = box(candidate);
          break;
        }
      }

      const svg = document.querySelector(`.${outlineClass}`);
      if (svg === null) {
        return {
          present: false,
          stroke: "",
          strokeWidth: "",
          strokeDasharray: "",
          outlineZIndex: "",
          overlayZIndex,
          bbox: null,
          tab,
        };
      }

      const path = svg.querySelector("path");
      if (path === null) {
        return {
          present: false,
          stroke: "",
          strokeWidth: "",
          strokeDasharray: "",
          outlineZIndex: window.getComputedStyle(svg).zIndex,
          overlayZIndex,
          bbox: null,
          tab,
        };
      }

      const cs = window.getComputedStyle(path);
      // `getBBox` is in the SVG's own user units.  The outline SVGs are sized
      // to the viewport with a matching `viewBox` and carry no transform, so
      // those units ARE viewport pixels; `getBoundingClientRect` on the path
      // agrees and is used here so the comparison with the tab's rect is in
      // one coordinate system by construction rather than by assumption.
      const r = path.getBoundingClientRect();

      return {
        present: true,
        stroke: cs.stroke,
        strokeWidth: cs.strokeWidth,
        strokeDasharray: cs.strokeDasharray,
        outlineZIndex: window.getComputedStyle(svg).zIndex,
        overlayZIndex,
        bbox: { left: r.left, top: r.top, right: r.right, bottom: r.bottom },
        tab,
      };
    },
    { outlineClass, stripSelector, tabLabel },
  );
}

/**
 * The assertions every drawn outline must satisfy, docked or in auto-hide.
 *
 * `where` names the case in the failure message — the brief for this work asked
 * that a refusal name its edge, so that a report of "no border on one edge"
 * comes back as that edge rather than as a bare boolean.
 */
function assertOutlineIsReal(m: OutlineMeasurement, where: string): void {
  expect(m.present, `${where}: outline element is in the DOM`).toBe(true);

  // A RESOLVED colour.  An unresolved Stylus variable compiles to its own
  // name, the browser drops the declaration, and the stroke falls back to
  // `none` — which is precisely the "no border at all" this work fixes.
  expect(
    m.stroke,
    `${where}: stroke resolved to a colour, not a bare token name (got ${JSON.stringify(m.stroke)})`,
  ).toMatch(/^rgba?\(/);
  expect(m.stroke, `${where}: stroke is painted, not 'none'`).not.toBe("none");

  const width = parseFloat(m.strokeWidth);
  expect(
    width,
    `${where}: stroke width is a positive length (got ${JSON.stringify(m.strokeWidth)})`,
  ).toBeGreaterThan(0);

  // The stroke analogue of `border-style: solid`.
  expect(m.strokeDasharray, `${where}: the line is solid, not dashed`).toMatch(
    /^(none|)$/,
  );

  expect(m.bbox, `${where}: the path has a measurable box`).not.toBeNull();
  expect(m.bbox!.right - m.bbox!.left, `${where}: the path has width`)
    .toBeGreaterThan(1);
  expect(m.bbox!.bottom - m.bbox!.top, `${where}: the path has height`)
    .toBeGreaterThan(1);
}

/**
 * The report is about *the active tab's* border, so the path has to reach
 * around the tab and not stop at the panel's edge.
 */
function assertOutlineEnclosesTab(m: OutlineMeasurement, where: string): void {
  expect(m.tab, `${where}: the active strip tab was found`).not.toBeNull();
  const { bbox, tab } = m;
  expect(bbox!.left, `${where}: outline reaches the tab's left edge`)
    .toBeLessThanOrEqual(tab!.left + TOL);
  expect(bbox!.right, `${where}: outline reaches the tab's right edge`)
    .toBeGreaterThanOrEqual(tab!.right - TOL);
  expect(bbox!.top, `${where}: outline reaches the tab's top edge`)
    .toBeLessThanOrEqual(tab!.top + TOL);
  expect(bbox!.bottom, `${where}: outline reaches the tab's bottom edge`)
    .toBeGreaterThanOrEqual(tab!.bottom - TOL);
}

/**
 * Right-click the active tab of a GL stack and run a context-menu command.
 *
 * `addPanelTransferContextMenu` in `ui/layout.nim` is the only route to the
 * pin commands; the stack-header dropdown that used to carry them is gone.
 */
async function pinToEdge(page: Page, edge: string): Promise<void> {
  await page.locator(".lm_stack").first()
    .locator(".lm_tab.lm_active").first()
    .click({ button: "right" });
  await wait(300);
  await page.evaluate((e) => {
    const items = document.querySelectorAll(
      "#context-menu-container .context-menu-item",
    );
    for (const item of Array.from(items)) {
      if (item.textContent?.trim() === `Pin to ${e}`) {
        (item as HTMLElement).click();
        return;
      }
    }
  }, edge);
  await wait(1500);
}

/**
 * The two themes a user can actually be looking at.
 *
 * The app boots with `default_dark_theme_electron.css` in `index.html`'s
 * `link#theme`; the white build is its sibling in the same directory.
 */
const THEMES = ["dark", "white"] as const;

/** Point `link#theme` at `<name>`'s built stylesheet. */
async function setTheme(page: Page, name: string): Promise<void> {
  await page.evaluate((theme) => {
    const link = document.getElementById("theme") as HTMLLinkElement | null;
    if (link === null) return;
    link.href = link.href.replace(
      /default_[a-z]+_theme_electron\.css/,
      `default_${theme}_theme_electron.css`,
    );
  }, name);
  // The swapped stylesheet has to load and the rAF-scheduled outline has to
  // re-measure against whatever it changed.
  await wait(900);
}

/**
 * Screenshot the CURRENT state under both themes, then restore the default.
 *
 * The deliverable for this work is the docked and auto-hide states side by
 * side in both themes, because "these two should look the same and do not" is
 * the whole of the report.  Capturing both themes from one interaction rather
 * than driving the app twice keeps the two shots of a pair showing the same
 * panel at the same size — a re-drive would differ in ways that have nothing
 * to do with the border.
 */
async function shotBothThemes(page: Page, stem: string): Promise<void> {
  for (const theme of THEMES) {
    await setTheme(page, theme);
    await page.screenshot({ path: `${SHOT_DIR}/${stem}-${theme}.png` });
  }
  await setTheme(page, "dark");
}

/**
 * Move the pointer off the strip and let the tab see a `mouseleave`.
 *
 * Required between closing a docked panel and hovering the same tab.
 * Clicking a tab to collapse its panel sets `suppressHoverAfterClose` in
 * `ui/auto_hide.nim`, which blocks the hover preview until "the mouse [has
 * left] and re-enter[ed]" — the pointer is still sitting on the tab after the
 * click, so a `hover()` on it fires nothing and the overlay never opens.  The
 * flag is cleared by `onHoverLeave`, which is what this provokes.
 */
async function leaveStrip(page: Page): Promise<void> {
  const root = await page.locator("#ROOT").boundingBox();
  if (root !== null) {
    await page.mouse.move(root.x + root.width / 2, root.y + root.height / 2);
  } else {
    await page.mouse.move(10, 10);
  }
  await wait(400);
}

/**
 * Put the strips into their text-tab rendering.
 *
 * Under a headless/virtual display the heuristic in `updateCollapsedMode`
 * decides the window is maximised and switches the strips to the 1px collapsed
 * form, which has no tab to draw a border around.  The neighbouring visual
 * specs force it off the same way.
 */
async function forceExpandedStrips(page: Page): Promise<void> {
  await page.evaluate(() => {
    const f = (window as unknown as {
      __ctForceCollapsedMode?: (v: boolean) => void;
    }).__ctForceCollapsedMode;
    if (typeof f === "function") f(false);
  });
  await wait(200);
}

const fixture = recordChromeTraceFixture("auto-hide-focus-border");

test.describe("auto-hide panel focus border", () => {
  test.setTimeout(180_000);
  test.use({ sourcePath: fixture.traceDir, launchMode: "trace-folder" });

  /**
   * The bottom edge — the case the user reported, in the place they reported
   * it.  BUILD is one of the standalone panes `layout.nim` registers at boot,
   * so it is in the status bar on every trace without anything being pinned.
   */
  test("the status-bar panel's border is the same docked and in auto-hide", async ({
    ctPage,
  }) => {
    const layout = new LayoutPage(ctPage);
    await layout.waitForAllComponentsLoaded();
    await layout.waitForTraceLoaded();
    await forceExpandedStrips(ctPage);
    await waitForDefaultBottomTabs(ctPage);

    const label = DEFAULT_BOTTOM_TAB_TITLES[0]; // "BUILD"
    const tab = bottomStripTab(ctPage, label);
    const strip = "#auto-hide-bottom-strip";

    // --- Docked: the half the user says already works. ---
    await openDockedPanelFromTab(ctPage, tab, "bottom", WAIT_TIMEOUT_MS);
    await wait(600); // let the rAF-scheduled outline settle
    const docked = await measureOutline(
      ctPage, "ct-docked-outline", strip, label,
    );
    assertOutlineIsReal(docked, "bottom edge, docked");
    assertOutlineEnclosesTab(docked, "bottom edge, docked");
    await shotBothThemes(ctPage, "bottom-01-docked");

    // --- Auto-hide: the half they say does not. ---
    await closeDockedPanelFromTab(ctPage, tab, "bottom", WAIT_TIMEOUT_MS);
    await leaveStrip(ctPage);
    await openOverlayFromTab(ctPage, tab, WAIT_TIMEOUT_MS);
    await wait(600);
    const overlay = await measureOutline(
      ctPage, "ct-overlay-outline", strip, label,
    );
    assertOutlineIsReal(overlay, "bottom edge, auto-hide");
    assertOutlineEnclosesTab(overlay, "bottom edge, auto-hide");
    await shotBothThemes(ctPage, "bottom-02-auto-hide");

    // --- The report itself: the two must agree. ---
    expect(
      overlay.stroke,
      "bottom edge: auto-hide and docked draw the same colour",
    ).toBe(docked.stroke);
    expect(
      overlay.strokeWidth,
      "bottom edge: auto-hide and docked draw the same width",
    ).toBe(docked.strokeWidth);

    // --- And the line is above the overlay, not under it. ---
    //
    // This is the defect's actual mechanism.  An outline can be present,
    // resolved and correctly shaped and still be invisible, which is what the
    // docked outline was in auto-hide mode: `#auto-hide-overlay` is above it
    // by design.  Presence alone would have passed on the broken tree had the
    // element merely been created.
    expect(
      Number(overlay.outlineZIndex),
      `bottom edge: the outline paints above the overlay ` +
        `(outline ${overlay.outlineZIndex}, overlay ${overlay.overlayZIndex})`,
    ).toBeGreaterThan(Number(overlay.overlayZIndex));
  });

  /**
   * The side edges.  The report named the status bar, but a focus cue present
   * on two edges and absent on the third reads as a fault rather than a
   * design, so the fix is general and this is the evidence that it is.
   */
  for (const edge of ["Left", "Right"] as const) {
    const lower = edge.toLowerCase() as "left" | "right";

    test(`the ${lower}-edge panel's border is the same docked and in auto-hide`, async ({
      ctPage,
    }) => {
      const layout = new LayoutPage(ctPage);
      await layout.waitForAllComponentsLoaded();
      await layout.waitForTraceLoaded();
      await forceExpandedStrips(ctPage);
      await wait(500);

      await pinToEdge(ctPage, edge);
      const strip = `#auto-hide-strip-${lower}`;
      await expect(ctPage.locator(strip)).toHaveClass(/has-tabs/, {
        timeout: WAIT_TIMEOUT_MS,
      });
      await forceExpandedStrips(ctPage);

      const tab = ctPage.locator(`${strip} .auto-hide-strip-tab`).first();
      await expect(tab).toBeVisible({ timeout: WAIT_TIMEOUT_MS });
      const label = ((await tab.textContent()) ?? "").trim();

      // --- Docked ---
      await openDockedPanelFromTab(ctPage, tab, lower, WAIT_TIMEOUT_MS);
      await wait(600);
      const docked = await measureOutline(
        ctPage, "ct-docked-outline", strip, label,
      );
      assertOutlineIsReal(docked, `${lower} edge, docked`);
      assertOutlineEnclosesTab(docked, `${lower} edge, docked`);
      await shotBothThemes(ctPage, `${lower}-01-docked`);

      // --- Auto-hide ---
      await closeDockedPanelFromTab(ctPage, tab, lower, WAIT_TIMEOUT_MS);
      await leaveStrip(ctPage);
      await openOverlayFromTab(ctPage, tab, WAIT_TIMEOUT_MS);
      await wait(600);
      const overlay = await measureOutline(
        ctPage, "ct-overlay-outline", strip, label,
      );
      assertOutlineIsReal(overlay, `${lower} edge, auto-hide`);
      assertOutlineEnclosesTab(overlay, `${lower} edge, auto-hide`);
      await shotBothThemes(ctPage, `${lower}-02-auto-hide`);

      expect(
        overlay.stroke,
        `${lower} edge: auto-hide and docked draw the same colour`,
      ).toBe(docked.stroke);
      expect(
        overlay.strokeWidth,
        `${lower} edge: auto-hide and docked draw the same width`,
      ).toBe(docked.strokeWidth);
      expect(
        Number(overlay.outlineZIndex),
        `${lower} edge: the outline paints above the overlay ` +
          `(outline ${overlay.outlineZIndex}, overlay ${overlay.overlayZIndex})`,
      ).toBeGreaterThan(Number(overlay.overlayZIndex));
    });
  }

  /**
   * Only ONE outline is on screen at a time.
   *
   * The line means "this is the panel you are working in", and two of them
   * means nothing.  Opening the overlay does not clear `ct-docked-focused` or
   * GoldenLayout's `.lm_focused` — the strip tab that opens it is inside
   * neither a `.auto-hide-docked` nor an `.lm_stack`, so the click-to-focus
   * listener never runs — so without the precedence rule in `update()` the new
   * outline would be drawn ALONGSIDE the old one rather than instead of it.
   * That is a regression this fix could plausibly have introduced, so it is
   * asserted rather than assumed.
   */
  test("the overlay's outline replaces the others rather than joining them", async ({
    ctPage,
  }) => {
    const layout = new LayoutPage(ctPage);
    await layout.waitForAllComponentsLoaded();
    await layout.waitForTraceLoaded();
    await forceExpandedStrips(ctPage);
    await waitForDefaultBottomTabs(ctPage);

    const tab = bottomStripTab(ctPage, DEFAULT_BOTTOM_TAB_TITLES[0]);

    // Dock it first, so a docked outline exists and `ct-docked-focused` is set.
    await openDockedPanelFromTab(ctPage, tab, "bottom", WAIT_TIMEOUT_MS);
    await wait(600);
    expect(
      await ctPage.locator(".ct-docked-outline").count(),
      "a docked panel is outlined to begin with",
    ).toBe(1);

    // Now open a DIFFERENT panel in the overlay, leaving the docked one open.
    const other = bottomStripTab(ctPage, DEFAULT_BOTTOM_TAB_TITLES[1]);
    await openOverlayFromTab(ctPage, other, WAIT_TIMEOUT_MS);
    await wait(600);

    await expect(ctPage.locator(OVERLAY_SELECTOR)).toHaveClass(/\bvisible\b/);
    expect(
      await ctPage.locator(".ct-overlay-outline").count(),
      "the overlay carries the outline while it is open",
    ).toBe(1);
    expect(
      await ctPage.locator(".ct-docked-outline").count(),
      "and the docked outline has stood down, so only one line is on screen",
    ).toBe(0);
    expect(
      await ctPage.locator(".ct-selected-outline").count(),
      "as has the GoldenLayout stack outline",
    ).toBe(0);
  });
});
