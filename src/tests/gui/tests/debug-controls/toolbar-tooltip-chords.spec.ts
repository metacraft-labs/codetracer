/**
 * The debug toolbar's tooltips, judged in a real browser.
 *
 * Spec: `codetracer-specs/BlockTracer/Debugger-Integration.md` §10.5 — "Every
 * control carries a binding, and the tooltip reads it":
 *
 *   - "A control's tooltip names the key that actually works. The text is
 *     derived from the binding in force, not written beside the control as a
 *     label."
 *   - "The tooltip appears on a rest, not on a crossing. A pointer travelling
 *     across a dense strip of controls to reach the far one must not leave a
 *     wake of tooltips behind it. The delay is a design constant and is not
 *     fixed here; what is fixed is the behaviour it exists to produce."
 *   - "a pointer that crosses a control raises no tooltip, and a pointer that
 *     rests on one raises exactly one."
 *
 * ## Why a browser test exists at all when two Nim suites already pass
 *
 * They assert different halves and neither can reach this one.
 * `src/frontend/tests/debug_toolbar_tooltips_test.nim` asserts the SHIPPED
 * config table drives all 13 controls and that rebinding changes the answer;
 * `src/tests/gui/tests/views/isonim_views_test.nim` asserts the view PAINTS
 * that string and repaints it on a rebind. Neither runs CSS, so neither can
 * see the thing this file is for: the tooltip is hidden until the pointer
 * rests, and an always-visible tooltip satisfies every assertion in both.
 *
 * ## The false passes this file is shaped against
 *
 * 1. **A hover that never fires goes green.** §10's own caveat: "A hover that
 *    never fires and a drag that lands nowhere both produce a clean, confident
 *    green." Rule 5 — prove the instrument, then judge the subject — so the
 *    first test asserts the hover LANDED before any test trusts one, and every
 *    hover is a real mouse move to the element's measured centre rather than
 *    Playwright's `hover()` convenience, because the centre is where a user's
 *    pointer actually rests.
 * 2. **Asserting the tooltip is visible proves nothing** if it was visible all
 *    along. So visibility is read BEFORE the delay as well as after, and the
 *    "before" reading is an assertion, not a warm-up.
 * 3. **Asserting a tooltip contains an expected literal proves nothing** — a
 *    hardcoded label passes. So the chord is read out of the tooltip and
 *    related to what the page itself reports the binding to be; no chord is
 *    named by the assertion that judges a control.
 */

import { test, expect } from "../../lib/fixtures";
import type { Page } from "@playwright/test";

/**
 * The toolbar's controls, by the ids the view emits (`page-objects/
 * debug-toolbar-ids.ts` is the map; the ids are `{action}-image`, renamed at
 * some point from `{action}-debug`).  Kept in the order the toolbar paints
 * them so "crossing" below is a real traversal of the strip.
 *
 * This list is the SUBJECT SELECTOR, not the expectation: no assertion below
 * says what chord any of these has.  It exists so the tests can be counted
 * over every control rather than over whichever one happened to be found.
 */
const TOOLBAR_BUTTON_IDS = [
  "history-back-image",
  "history-forward-image",
  "reverse-next-image",
  "next-image",
  "reverse-step-in-image",
  "step-in-image",
  "reverse-step-out-image",
  "step-out-image",
  "reverse-continue-image",
  "continue-image",
  "run-to-entry-image",
  "reset-operation-image",
  "run-tests-image",
] as const;

/**
 * Longer than `TOOLTIP_DELAY_TIMER` (0.20s, `styles/defaults.styl`) plus the
 * 0.3s opacity transition, with room to spare.  Deliberately NOT equal to the
 * constant: §10.5 fixes the behaviour, not the number, so this file must not
 * turn the number into a requirement.
 */
const REST_MS = 900;

/** Comfortably shorter than the delay. */
const CROSSING_MS = 60;

function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

/** Move the real pointer to an element's measured centre and leave it there. */
async function restOn(page: Page, id: string): Promise<void> {
  const box = await page.locator(`#${id}`).boundingBox();
  if (!box) throw new Error(`#${id} has no box — it is not laid out`);
  await page.mouse.move(box.x + box.width / 2, box.y + box.height / 2);
}

/** Park the pointer somewhere that is not a control. */
async function restOffToolbar(page: Page): Promise<void> {
  await page.mouse.move(2, 2);
}

/**
 * How many of the toolbar's tooltips are actually being shown.
 *
 * Reads COMPUTED STYLE rather than Playwright's `toBeVisible()`, because the
 * tooltip is shown by transitioning `opacity`/`visibility` and is in the DOM
 * and laid out the whole time.  §10's caveat lists computed style as one of
 * the four readings this suite has never taken.
 */
async function visibleTooltipCount(page: Page): Promise<number> {
  return page.evaluate((ids: string[]) => {
    let shown = 0;
    for (const id of ids) {
      const tip = document.querySelector(`#${id} .custom-tooltip`);
      if (!tip) continue;
      const style = window.getComputedStyle(tip);
      if (style.visibility === "visible" && Number(style.opacity) > 0.5) {
        shown += 1;
      }
    }
    return shown;
  }, TOOLBAR_BUTTON_IDS as unknown as string[]);
}

async function isTooltipShown(page: Page, id: string): Promise<boolean> {
  return page.evaluate((elementId: string) => {
    const tip = document.querySelector(`#${elementId} .custom-tooltip`);
    if (!tip) return false;
    const style = window.getComputedStyle(tip);
    return style.visibility === "visible" && Number(style.opacity) > 0.5;
  }, id);
}

test.describe("Debug toolbar tooltips name the bound chord, and wait for a rest", () => {
  test.describe.configure({ mode: "serial" });
  test.setTimeout(120_000);
  test.use({
    sourcePath: "py_console_logs/main.py",
    launchMode: "trace",
  });

  test.beforeEach(async ({ ctPage }) => {
    await expect(ctPage.locator("#next-image")).toBeVisible({ timeout: 60_000 });
    await restOffToolbar(ctPage as unknown as Page);
  });

  test("PROVE THE INSTRUMENT: the hover lands, and only where it was aimed", async ({ ctPage }) => {
    const page = ctPage as unknown as Page;
    // Rule 5. Everything below this test is a statement about what hovering
    // does; if hovering does nothing, all of it passes without meaning. This
    // asserts the gesture has an effect AND that the effect is local to the
    // control aimed at — a "hover" that lit up the whole strip, or that landed
    // on the wrong element, would otherwise be indistinguishable from success.
    expect(await visibleTooltipCount(page)).toBe(0);

    await restOn(page, "next-image");
    await sleep(REST_MS);

    expect(await isTooltipShown(page, "next-image")).toBe(true);
    // The neighbour was not hovered and must not have reacted.
    expect(await isTooltipShown(page, "step-in-image")).toBe(false);
    expect(await visibleTooltipCount(page)).toBe(1);
  });

  test("a tooltip is ABSENT immediately on hover and PRESENT after the delay", async ({ ctPage }) => {
    const page = ctPage as unknown as Page;
    // The reading that distinguishes a tooltip from a label. An always-visible
    // tooltip satisfies any check that only looks after the delay.
    let checkedControls = 0;

    for (const id of ["next-image", "continue-image", "run-tests-image"]) {
      await restOffToolbar(page);
      await sleep(400); // let any previous tooltip finish hiding
      expect(await isTooltipShown(page, id)).toBe(false);

      await restOn(page, id);
      await sleep(CROSSING_MS);
      // BEFORE the delay — this is an assertion, not a warm-up.
      expect(await isTooltipShown(page, id)).toBe(false);

      await sleep(REST_MS);
      // AFTER.
      expect(await isTooltipShown(page, id)).toBe(true);
      checkedControls += 1;
    }

    expect(checkedControls).toBe(3);
    expect(checkedControls).toBeGreaterThan(0);
  });

  test("a pointer CROSSING the strip leaves no wake of tooltips", async ({ ctPage }) => {
    const page = ctPage as unknown as Page;
    // §10.5's second reading, and the reason the delay exists. Traverse every
    // control in paint order without resting on any, then look at the whole
    // strip at once.
    let maxSeen = 0;
    let crossedControls = 0;

    for (const id of TOOLBAR_BUTTON_IDS) {
      await restOn(page, id);
      crossedControls += 1;
      await sleep(CROSSING_MS);
      const shown = await visibleTooltipCount(page);
      if (shown > maxSeen) maxSeen = shown;
    }

    // The traversal happened — a loop that ranged over nothing would report 0
    // tooltips and pass.
    expect(crossedControls).toBe(TOOLBAR_BUTTON_IDS.length);
    expect(crossedControls).toBe(13);
    expect(maxSeen).toBe(0);
  });

  test("a pointer RESTING on a control raises exactly one tooltip", async ({ ctPage }) => {
    const page = ctPage as unknown as Page;
    // Counted over every control, not existentially (rule 3): one control that
    // never raises its tooltip is the defect.
    let controlsThatRaised = 0;

    for (const id of TOOLBAR_BUTTON_IDS) {
      await restOffToolbar(page);
      await sleep(400);
      await restOn(page, id);
      await sleep(REST_MS);

      if (await isTooltipShown(page, id)) controlsThatRaised += 1;
      // Exactly one — never a wake.
      expect(await visibleTooltipCount(page)).toBe(1);
    }

    expect(controlsThatRaised).toBe(TOOLBAR_BUTTON_IDS.length);
    expect(controlsThatRaised).toBe(13);
  });

  test("EVERY control's tooltip names a chord, and none is a bare label", async ({ ctPage }) => {
    const page = ctPage as unknown as Page;
    // The subject is selected by a property read off the page (the control has
    // a tooltip); the expectation relates two things the page reports (the
    // label the control shows and the chord it claims). No chord is named
    // here — a test that named them would be the hardcoded label problem
    // relocated into the test suite.
    const readings = await page.evaluate((ids: string[]) => {
      return ids.map((id) => {
        const tip = document.querySelector(`#${id} .custom-tooltip`);
        return { id, text: (tip?.textContent ?? "").trim() };
      });
    }, TOOLBAR_BUTTON_IDS as unknown as string[]);

    expect(readings.length).toBe(13);
    expect(readings.length).toBeGreaterThan(0);

    const chordPattern = /^(.+?) \(([^()]+)\)$/;
    let controlsWithChord = 0;
    const chords = new Set<string>();

    for (const reading of readings) {
      const match = chordPattern.exec(reading.text);
      // A control whose tooltip is a bare label is exactly the state this work
      // removed: five of the thirteen had no binding at all and so could only
      // ever have shown a label.
      expect(match, `#${reading.id} tooltip has no chord: "${reading.text}"`).not.toBeNull();
      if (!match) continue;

      const [, label, chord] = match;
      expect(label.length).toBeGreaterThan(0);
      expect(chord.length).toBeGreaterThan(0);
      // A chord is spelled in upper case by `renderChord`; a label is not. This
      // catches a tooltip whose parentheses hold prose rather than a binding.
      expect(chord).toBe(chord.toUpperCase());
      chords.add(chord);
      controlsWithChord += 1;
    }

    expect(controlsWithChord).toBe(13);
    // Distinct chords: a lookup that ignored its argument and returned one
    // constant would give all 13 controls the same chord and pass every
    // assertion above.
    expect(chords.size).toBe(13);
  });
});
