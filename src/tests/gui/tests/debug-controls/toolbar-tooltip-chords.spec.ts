/**
 * RUN IT with
 *   just test-gui tests/debug-controls/toolbar-tooltip-chords.spec.ts
 * from a checkout that sits beside its sibling repos: `just test-gui`
 * resolves them against the checkout's parent directory.
 *
 * ---------------------------------------------------------------------------
 *
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
 * router drives all 13 controls and that rebinding changes the answer;
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
 *
 * The synthetic readings in the oracle controls deliberately corrupt text to
 * calibrate the SAME validators used on the DOM below. They test the instrument;
 * the toolbar tests use the real app and its live router, without mocks.
 */

import { test, expect } from "../../lib/fixtures";
import type { Page } from "@playwright/test";
import * as fs from "node:fs";
import * as path from "node:path";
import { ctUserConfigDir } from "../../lib/ct-home";

/**
 * The toolbar's controls, by the ids the view emits (`page-objects/
 * debug-toolbar-ids.ts` is the map; the ids are `{action}-image`, renamed at
 * some point from `{action}-debug`).  Kept in the order the toolbar paints
 * them so "crossing" below is a real traversal of the strip.
 *
 * The ClientAction identifies what each control does, independently of its
 * tooltip. No chord is stored here: every expected chord comes from the live
 * router for THAT action, so another control's valid chord cannot pass.
 */
const TOOLBAR_CONTROLS = [
  { id: "history-back-image", action: "aHistoryBack" },
  { id: "history-forward-image", action: "aHistoryForward" },
  { id: "reverse-next-image", action: "reverseNext" },
  { id: "next-image", action: "forwardNext" },
  { id: "reverse-step-in-image", action: "reverseStep" },
  { id: "step-in-image", action: "forwardStep" },
  { id: "reverse-step-out-image", action: "reverseStepOut" },
  { id: "step-out-image", action: "forwardStepOut" },
  { id: "reverse-continue-image", action: "reverseContinue" },
  { id: "continue-image", action: "forwardContinue" },
  { id: "run-to-entry-image", action: "aRunToEntry" },
  { id: "reset-operation-image", action: "aResetOperation" },
  { id: "run-tests-image", action: "aRunTests" },
] as const;
const TOOLBAR_BUTTON_IDS = TOOLBAR_CONTROLS.map(({ id }) => id);

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


/**
 * Rest on a control and report whether its tooltip is already shown, read at
 * an instant the page itself confirms is still inside the tooltip's delay.
 *
 * "Absent before the delay" is a claim about a moment, and the moment is
 * measured in the page, not in the test process. A read that sleeps
 * `CROSSING_MS` and then asks can still land after the delay has run out: any
 * main-thread task longer than the delay that falls between the hover and the
 * read (a synchronous git refresh, for instance) defers the read and not the
 * CSS transition, so the read then sees a correctly delayed tooltip and the
 * check fails for a reason that has nothing to do with the delay. Such a read
 * says nothing about the claim, so it is discarded and the rest is taken again.
 *
 * The page stamps the `mouseover` the rest produces and the read reports how
 * long after it it ran, together with the delay the control's own computed
 * style declares — read off the page, so this file still does not turn the
 * number into a requirement. A tooltip with no delay at all declares 0, so no
 * read can qualify and the helper throws rather than passing.
 */
async function tooltipShownBeforeItsDelay(page: Page, id: string): Promise<boolean> {
  const attempts = 5;
  const late: string[] = [];
  for (let attempt = 0; attempt < attempts; attempt++) {
    await restOffToolbar(page);
    await sleep(400);
    await page.evaluate((elementId: string) => {
      const w = window as unknown as { __tooltipHoverAt?: number };
      w.__tooltipHoverAt = undefined;
      document.getElementById(elementId)?.addEventListener(
        "mouseover",
        () => {
          w.__tooltipHoverAt = performance.now();
        },
        { once: true },
      );
    }, id);
    await restOn(page, id);
    await sleep(CROSSING_MS);
    const read = await page.evaluate((elementId: string) => {
      const now = performance.now();
      const hoverAt = (window as unknown as { __tooltipHoverAt?: number }).__tooltipHoverAt;
      const tip = document.querySelector(`#${elementId} .custom-tooltip`);
      if (!tip) return { shown: false, elapsedMs: -1, delayMs: -1 };
      const style = window.getComputedStyle(tip);
      const delayMs = Math.max(
        ...style.transitionDelay.split(",").map((d) => {
          const t = d.trim();
          return t.endsWith("ms") ? parseFloat(t) : parseFloat(t) * 1000;
        }),
      );
      return {
        shown: style.visibility === "visible" && Number(style.opacity) > 0.5,
        elapsedMs: hoverAt === undefined ? -1 : now - hoverAt,
        delayMs,
      };
    }, id);
    if (read.elapsedMs >= 0 && read.elapsedMs < read.delayMs) return read.shown;
    late.push(`read ${read.elapsedMs.toFixed(0)} ms after the hover, delay ${read.delayMs} ms`);
  }
  throw new Error(
    `#${id}: no read landed inside the tooltip's delay in ${attempts} rests (${late.join("; ")})`,
  );
}

/**
 * The router's canonical syntax (`common/key_names.nim`): modifiers, then a
 * printable character or named key. Case does not decide whether this is a
 * chord: `Ctrl+Alt+-` is one, and uppercase prose is not. Spaces separate
 * successive strokes of ONE binding, not alternative bindings.
 */
function chordStrokes(chord: string): string[] {
  const strokePattern = /^(?:(?:Ctrl|Shift|Alt|Meta)\+)*(?:[!-~]|F(?:[1-9]|1[0-2])|Esc|Enter|Tab|Backspace|Delete|Insert|Space|Home|End|PageUp|PageDown|Up|Down|Left|Right|Alt)$/i;
  const strokes = chord.trim().split(/\s+/);
  if (!strokes.every((stroke) => strokePattern.test(stroke))) {
    throw new Error(`not a chord: "${chord}"`);
  }
  return strokes;
}

/** Transliterate every stroke the tooltip claims, without a binding table. */
function chordToPlaywrightKeys(chord: string): string[] {
  return chordStrokes(chord).map((stroke) => {
    // Keep a literal '+' key intact (Ctrl++), instead of splitting it into
    // an empty key and an unrecognised modifier.
    const [, prefix, key] = /^((?:(?:Ctrl|Shift|Alt|Meta)\+)*)(.+)$/i.exec(stroke)!;
    const modifiers = prefix.split("+").filter(Boolean).map((m) => {
      switch (m.toUpperCase()) {
        case "CTRL":
          return "Control";
        case "SHIFT":
          return "Shift";
        case "ALT":
          return "Alt";
        case "META":
          return "Meta";
        default:
          throw new Error(`unrecognised modifier in chord "${chord}": ${m}`);
      }
    });
    const mainKey = key.length === 1 && prefix.length > 0 ? key.toLowerCase() : key;
    return [...modifiers, mainKey].join("+");
  });
}

/** Read and validate the actual text, shared by DOM assertions and controls. */
function tooltipChord(text: string, id: string): string {
  const match = /^(.+?) \((.+)\)$/.exec(text);
  if (!match) throw new Error(`#${id} tooltip names no chord: "${text}"`);
  const chord = match[2];
  chordStrokes(chord);
  return chord;
}

function assertRouterChord(text: string, id: string, routerChord: string): void {
  const chord = tooltipChord(text, id);
  expect(routerChord, `#${id}: the router has no chord for this control's action`).not.toBe("");
  // This is the canonical string the router returns, including sequence order
  // and letter case: bare `g` and `G` really are different keys.
  expect(chord, `#${id} claims "${chord}", but its action's router chord is "${routerChord}"`)
    .toBe(routerChord);
}

async function toolbarBindings(page: Page) {
  return page.evaluate((controls) => {
    const probe = (window as unknown as {
      __CODETRACER_TEST__?: { chordForAction?: (action: string) => string };
    }).__CODETRACER_TEST__;
    if (typeof probe?.chordForAction !== "function") {
      throw new Error("the live key router's chordForAction test seam is missing");
    }
    return controls.map(({ id, action }) => ({
      id,
      action,
      text: (document.querySelector(`#${id} .custom-tooltip`)?.textContent ?? "").trim(),
      routerChord: probe.chordForAction!(action),
    }));
  }, TOOLBAR_CONTROLS);
}

/** Read the chord a control's own tooltip claims, without hovering. */
async function chordFromTooltip(page: Page, id: string): Promise<string> {
  const text = await page.evaluate((elementId: string) => {
    const tip = document.querySelector(`#${elementId} .custom-tooltip`);
    return (tip?.textContent ?? "").trim();
  }, id);
  return tooltipChord(text, id);
}

async function resetStepLog(page: Page): Promise<void> {
  await page.evaluate(() => {
    const w = window as unknown as { __CODETRACER_TEST__?: { vmBackendRequests?: unknown[] } };
    w.__CODETRACER_TEST__ = w.__CODETRACER_TEST__ ?? {};
    w.__CODETRACER_TEST__.vmBackendRequests = [];
  });
}

/**
 * The toolbar action id of the first step the page recorded, or "".
 *
 * `ui/debug.nim`'s `recordDapStep` logs the action id the toolbar dispatched
 * ("next", "reverse-step-in", ...), and BOTH a click and a chord reach it
 * through the same `invokeToolbarStep` bridge (`ui/debug.nim:83-93`). That
 * shared path is what makes the comparison below meaningful rather than a
 * coincidence of two similar code paths.
 */
async function firstRecordedStep(page: Page): Promise<string> {
  return page.evaluate(() => {
    type R = { command?: string; source?: string };
    const log =
      ((window as unknown as { __CODETRACER_TEST__?: { vmBackendRequests?: R[] } })
        .__CODETRACER_TEST__?.vmBackendRequests ?? []) as R[];
    const step = log.find((r) => r.source === "dapStep");
    return step?.command ?? "";
  });
}

async function waitStableBusyFalse(page: Page): Promise<void> {
  await expect
    .poll(
      () =>
        page.evaluate(
          () =>
            (window as unknown as { data?: { status?: { stableBusy?: boolean } } })
              .data?.status?.stableBusy === false,
        ),
      { timeout: 60_000 },
    )
    .toBe(true);
}

test("CHORD ORACLE accepts router spelling and rejects malformed, stale and wrong-action readings", () => {
  for (const chord of ["Ctrl+Alt+-", "Shift+F10", "ctrl+alt+-", "Ctrl+K Ctrl+C", "Ctrl++", "g", "G"]) {
    expect(() => assertRouterChord(`Control (${chord})`, "control", chord)).not.toThrow();
  }
  for (const text of ["Control", "Control ()", "Control (PRESS THE KEY)", "Control (press the key)",
                      "Control (Ctrl+Alt+)", "Control (Moon+F10)", "Control (F10) trailing"]) {
    expect(() => tooltipChord(text, "control"), text).toThrow();
  }
  // A valid chord is insufficient: it must be this action's current chord.
  // These deliberately corrupt readings calibrate the same assertion as the DOM.
  for (const [claimed, bound] of [["Ctrl+Alt+B", "Ctrl+Alt+-"], ["F10", "Ctrl+Alt+-"],
                                 ["Ctrl+K", "Ctrl+K Ctrl+C"], ["g", "G"]]) {
    expect(() => assertRouterChord(`Control (${claimed})`, "control", bound)).toThrow(/router chord/);
  }
  expect(() => assertRouterChord("Control (F10)", "control", "")).toThrow(/router has no chord/);
  expect(chordToPlaywrightKeys("Ctrl+K Ctrl+Shift+C")).toEqual(["Control+k", "Control+Shift+c"]);
  expect(chordToPlaywrightKeys("g G")).toEqual(["g", "G"]);
});

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

      // BEFORE the delay — this is an assertion, not a warm-up.
      expect(await tooltipShownBeforeItsDelay(page, id)).toBe(false);

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

  test("a DISABLED control still raises its tooltip on a rest, and stays inert", async ({ ctPage }) => {
    const page = ctPage as unknown as Page;
    // `Debugger-Controls.md` requires a tooltip on EVERY debug-control button:
    // a control that cannot act yet still says what it does and which chord
    // it is bound to. The two history controls are the ones a fresh trace
    // shows disabled (no history yet), and they were the two whose tooltip
    // never appeared: the shared `button:disabled` rule took them out of
    // hit-testing with `pointer-events: none`, so they never matched `:hover`.
    //
    // NON-VACUITY: the subject is a control the page itself reports disabled.
    // If a fresh trace ever starts with history, this test is no longer about
    // a disabled control and says so here rather than passing on an enabled one.
    const subjects = await page.evaluate((ids: string[]) => {
      return ids.filter((id) => document.getElementById(id)?.hasAttribute("disabled"));
    }, ["history-back-image", "history-forward-image"]);
    expect(subjects).toEqual(["history-back-image", "history-forward-image"]);

    for (const id of subjects) {
      await restOffToolbar(page);
      await sleep(400);
      await restOn(page, id);
      await sleep(REST_MS);
      expect(await isTooltipShown(page, id), `#${id} is disabled and raised no tooltip`).toBe(true);
      expect(await visibleTooltipCount(page)).toBe(1);

      // The tooltip must not have cost the control its inertness: a click on
      // the disabled button reaches no handler on it (the browser dispatches
      // no `click` to a disabled form control) and leaves it disabled.
      await page.evaluate((elementId: string) => {
        const w = window as unknown as { __disabledClicks?: number };
        w.__disabledClicks = 0;
        const el = document.getElementById(elementId);
        document.addEventListener(
          "click",
          (event) => {
            if (el && event.composedPath().includes(el)) w.__disabledClicks! += 1;
          },
          { capture: true },
        );
      }, id);
      const box = await page.locator(`#${id}`).boundingBox();
      if (!box) throw new Error(`#${id} has no box — it is not laid out`);
      await page.mouse.click(box.x + box.width / 2, box.y + box.height / 2);
      await sleep(CROSSING_MS);
      const after = await page.evaluate((elementId: string) => ({
        clicks: (window as unknown as { __disabledClicks?: number }).__disabledClicks,
        disabled: document.getElementById(elementId)?.hasAttribute("disabled"),
      }), id);
      expect(after.clicks, `#${id}: a click reached the disabled control`).toBe(0);
      expect(after.disabled).toBe(true);
    }
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

    let controlsWithChord = 0;
    const chords = new Set<string>();

    for (const reading of readings) {
      // A control whose tooltip is a bare label is exactly the state this work
      // removed: five of the thirteen had no binding at all and so could only
      // ever have shown a label.
      const chord = tooltipChord(reading.text, reading.id);
      chords.add(chord);
      controlsWithChord += 1;
    }

    expect(controlsWithChord).toBe(13);
    // Distinct chords: a lookup that ignored its argument and returned one
    // constant would give all 13 controls the same chord and pass every
    // assertion above.
    expect(chords.size).toBe(13);
  });

  test("EVERY control's tooltip names a chord the page actually has bound", async ({ ctPage }) => {
    const page = ctPage as unknown as Page;
    // §10.5, counted over every control on screen (rule 3): "one control with a
    // stale tooltip is the defect". This is the half of the strongest reading
    // that can be taken for ALL THIRTEEN without pressing anything — a chord
    // the router does not return for this action is a stale or wrong-action claim.
    //
    // It relates two things the page reports — the chord the tooltip claims and
    // the chord the live router runs for its action — and names neither.
    const results = await toolbarBindings(page);

    // Size both populations and require a binding for EVERY selected action.
    expect(results.length).toBe(13);
    expect(new Set(results.map(({ action }) => action)).size).toBe(13);

    let controlsBound = 0;
    for (const r of results) {
      assertRouterChord(r.text, r.id, r.routerChord);
      controlsBound += 1;
    }
    expect(controlsBound).toBe(13);
  });

  test("the tooltip oracle follows a user's live keybindings.json rebind", async ({ ctPage }) => {
    const page = ctPage as unknown as Page;
    const file = path.join(ctUserConfigDir(), "keybindings.json");
    const previous = fs.existsSync(file) ? fs.readFileSync(file) : null;
    const original = await toolbarBindings(page);
    const back = original.find(({ id }) => id === "history-back-image")!;
    const next = original.find(({ id }) => id === "next-image")!;
    assertRouterChord(back.text, back.id, back.routerChord);
    expect(back.routerChord).not.toBe("Ctrl+Alt+9");

    try {
      fs.mkdirSync(path.dirname(file), { recursive: true });
      fs.writeFileSync(file, JSON.stringify([
        { key: "ctrl+alt+9", command: "navigation.back" },
      ]));
      // The real main-process file watcher reloads the router; no binding is
      // injected into the renderer by this test. Wait for the painted claim too.
      await expect.poll(async () => (await toolbarBindings(page))
        .find(({ id }) => id === back.id)?.routerChord, { timeout: 30_000 }).toBe("Ctrl+Alt+9");
      await expect.poll(() => chordFromTooltip(page, back.id), { timeout: 30_000 }).toBe("Ctrl+Alt+9");
      const rebound = await toolbarBindings(page);
      expect(rebound.length).toBe(13);
      for (const reading of rebound) assertRouterChord(reading.text, reading.id, reading.routerChord);
      expect(rebound.find(({ id }) => id === next.id)?.routerChord).toBe(next.routerChord);
      // A stale pre-rebind claim is rejected by the very same live oracle.
      expect(() => assertRouterChord(back.text, back.id, "Ctrl+Alt+9")).toThrow(/router chord/);
    } finally {
      if (previous === null) fs.unlinkSync(file);
      else fs.writeFileSync(file, previous);
      await expect.poll(async () => (await toolbarBindings(page))
        .find(({ id }) => id === back.id)?.routerChord, { timeout: 30_000 }).toBe(back.routerChord);
      await expect.poll(() => chordFromTooltip(page, back.id), { timeout: 30_000 }).toBe(back.routerChord);
    }
  });

  test("PRESSING the key a tooltip names does what that control does", async ({ ctPage }) => {
    const page = ctPage as unknown as Page;
    // §10.5's strongest reading: "read the key its own tooltip names, press
    // that key, and assert the session moves the way that control moves it."
    // This is the only assertion in the whole change that closes the loop —
    // everything else proves the tooltip is DERIVED from a binding; this proves
    // the binding it names is TRUE.
    //
    // The comparison is against CLICKING THE SAME CONTROL rather than against a
    // named expectation, so the check names no key and no action. Both gestures
    // reach `DebugControlsVM.invokeToolbarStep` (`ui/debug.nim:83-93`), and
    // `recordDapStep` logs the toolbar action id each one dispatched — so
    // "moves the way that control moves it" is readable as an equality between
    // two things the page reported about itself.
    //
    // SCOPED TO THE STEPPING CONTROLS, and the exclusions are asserted rather
    // than left implicit. The other five are not merely inconvenient: pressing
    // `run-tests` opens a second window and starts a recording, `run-to-entry`
    // and `reset-operation` restart the session out from under the loop, and
    // the two history controls do not dispatch a DAP step at all — they send
    // `ct/history-jump`, which `recordDapStep` does not log, so the equality
    // this loop asserts has nothing to compare on either side.
    //
    // THAT WAS NOT ALWAYS THE REASON, and the old one is worth keeping in
    // view: this comment used to read "the subject of a separate, tracked
    // defect (`ui/debug.nim:417-421` maps `history-back` to
    // `isForward = true`)". It did, and it was correct anyway, because the
    // `isForward` parameter named the opposite of what it did — two
    // inversions that cancelled. Both are gone: the direction is now a
    // `HistoryDirection` enum in `frontend/ui/history_cursor.nim`, named for
    // the sequence rather than the gesture, and the landing of each gesture
    // is asserted by value in
    // `frontend/viewmodel/tests/unit/test_history_cursor.nim`.
    const STEPPING_CONTROLS = [
      "next-image",
      "step-in-image",
      "reverse-next-image",
      "reverse-step-in-image",
    ] as const;
    expect(STEPPING_CONTROLS.length).toBe(4);
    expect(TOOLBAR_BUTTON_IDS.length - STEPPING_CONTROLS.length).toBe(9);

    // Step forward a few times first so the REVERSE controls are enabled — at
    // the start of a recording there is nothing behind the position, and a
    // disabled control records nothing, which would pass a "commands match"
    // assertion with two empty strings. The emptiness check below is what
    // actually catches that, but arriving somewhere steppable makes the test
    // about tooltips rather than about being at tick zero.
    await waitStableBusyFalse(page);
    for (let i = 0; i < 3; i += 1) {
      await page.locator("#next-image").click();
      await waitStableBusyFalse(page);
    }

    let comparedControls = 0;

    for (const id of STEPPING_CONTROLS) {
      const chord = await chordFromTooltip(page, id);

      // 1. Press the key the tooltip claims.
      await resetStepLog(page);
      for (const key of chordToPlaywrightKeys(chord)) await page.keyboard.press(key);
      await expect
        .poll(() => firstRecordedStep(page), { timeout: 30_000 })
        .not.toBe("");
      const fromKey = await firstRecordedStep(page);
      await waitStableBusyFalse(page);

      // 2. Click the control itself.
      await resetStepLog(page);
      await page.locator(`#${id}`).click();
      await expect
        .poll(() => firstRecordedStep(page), { timeout: 30_000 })
        .not.toBe("");
      const fromClick = await firstRecordedStep(page);
      await waitStableBusyFalse(page);

      // Neither gesture may have been a no-op: two empty strings are equal.
      expect(fromKey, `#${id}: chord "${chord}" dispatched nothing`).not.toBe("");
      expect(fromClick, `#${id}: clicking dispatched nothing`).not.toBe("");
      // THE ASSERTION. The key the tooltip names moves the session the way the
      // control it sits on moves it.
      expect(
        fromKey,
        `#${id}: tooltip says "${chord}", but that key dispatched "${fromKey}" ` +
          `while clicking the control dispatched "${fromClick}"`,
      ).toBe(fromClick);

      comparedControls += 1;
    }

    // Counted, so a loop that ranged over nothing cannot pass.
    expect(comparedControls).toBe(STEPPING_CONTROLS.length);
    expect(comparedControls).toBeGreaterThan(0);
  });
});
