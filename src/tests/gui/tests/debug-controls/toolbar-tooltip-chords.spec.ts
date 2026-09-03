/**
 * !!! UNEXECUTED AS WRITTEN — THIS FILE HAS NEVER BEEN RUN. !!!
 *
 * Every other assertion in this change was executed and has recorded mutation
 * arms (see `src/frontend/tests/debug_toolbar_tooltips_test.nim` and the
 * "tooltips read the binding" suite in `isonim_views_test.nim`). THIS ONE HAS
 * NOT. An unexecuted spec is not evidence — it is the same category as a
 * mutation arm that never mutated, and the presence of a plausible-looking
 * file is exactly the kind of thing that reads as coverage when it is not.
 * Treat every claim below as UNVERIFIED until someone runs it and deletes this
 * banner.
 *
 * WHY IT COULD NOT BE RUN, precisely, so the next reader does not repeat the
 * attempt blind. `just test-gui` requires `build-once`, which failed in this
 * workspace for three reasons, none of them related to this change and all of
 * them reproduced deterministically on a second run:
 *
 *   1. `db-replay-server-cargo` dies with
 *      `dyld: Symbol not found: _SSL_set_quic_tls_cbs`, referenced from
 *      `ngtcp2-1.17.0` and expected in `openssl-3.4.3` — an ABI mismatch
 *      inside the dev shell. Upstream of it, `nix` refused the flake with a
 *      `narHash` mismatch on the `ethereum.nix` input, so direnv fell back to
 *      a CACHED shell; the stale closure is the likely cause of the mismatch.
 *   2. `docs-book` / `docs-book-assets` fail with
 *      `cannot open file: docs_scaffold` (the `isonim-docs` nimble dependency
 *      is not installed, though the sibling repo is present).
 *   3. `codetracer-visual-replay/ct_gfx_player` is not built.
 *
 * No `src/build-debug` output is produced, so there is no app to drive.
 *
 * ALSO NOTE, for anyone running this from an agent worktree: `just test-gui`
 * resolves sibling repos against the worktree's PARENT directory. A worktree
 * under `.agent-wt/` fails the `runquota` check outright, and `runquota` has
 * an empty override column in `scripts/require-siblings.sh` by design, so no
 * environment variable papers over it. Run from a checkout that sits beside
 * the sibling repos.
 *
 * TO RUN IT:
 *   just storybook-build   # only needed for the sibling storybook spec
 *   just test-gui tests/debug-controls/toolbar-tooltip-chords.spec.ts
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


/**
 * Turn a chord as the TOOLTIP SPELLS IT into the key string Playwright presses.
 *
 * Deliberately a dumb transliteration with no table of known chords in it: the
 * whole point of §10.5's strongest reading is that the test does not know what
 * any control is bound to, it reads the claim off the page and tries it. A
 * lookup table here would re-introduce exactly the second source of truth this
 * work removed.
 *
 * `forwardContinue` is bound to two chords ("F8 F2") and the tooltip shows
 * both; pressing the first is enough to test the claim.
 */
function chordToPlaywrightKey(chord: string): string {
  const first = chord.trim().split(/\s+/)[0];
  const parts = first.split("+");
  const key = parts[parts.length - 1];
  const modifiers = parts.slice(0, -1).map((m) => {
    switch (m.toUpperCase()) {
      case "CTRL":
        return "Control";
      case "SHIFT":
        return "Shift";
      case "ALT":
        return "Alt";
      case "COMMAND":
      case "META":
        return "Meta";
      default:
        throw new Error(`unrecognised modifier in chord "${chord}": ${m}`);
    }
  });
  // A single character is a letter key and Playwright wants it lower case;
  // anything longer is a named key (F10, PageUp, Home) and is passed through.
  const mainKey = key.length === 1 ? key.toLowerCase() : key;
  return [...modifiers, mainKey].join("+");
}

/** Read the chord a control's own tooltip claims, without hovering. */
async function chordFromTooltip(page: Page, id: string): Promise<string> {
  const text = await page.evaluate((elementId: string) => {
    const tip = document.querySelector(`#${elementId} .custom-tooltip`);
    return (tip?.textContent ?? "").trim();
  }, id);
  const match = /^(.+?) \(([^()]+)\)$/.exec(text);
  if (!match) throw new Error(`#${id} tooltip names no chord: "${text}"`);
  return match[2];
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

  test("EVERY control's tooltip names a chord the page actually has bound", async ({ ctPage }) => {
    const page = ctPage as unknown as Page;
    // §10.5, counted over every control on screen (rule 3): "one control with a
    // stale tooltip is the defect". This is the half of the strongest reading
    // that can be taken for ALL THIRTEEN without pressing anything — a chord
    // the shortcut map does not contain is one that cannot possibly work, and
    // that is decidable from the page alone.
    //
    // It relates two things the page reports — the chord the tooltip claims and
    // the chords the running config has bound — and names neither.
    const results = await page.evaluate((ids: string[]) => {
      const shortcutActions =
        (window as unknown as {
          data?: { config?: { shortcutMap?: { shortcutActions?: Record<string, unknown> } } };
        }).data?.config?.shortcutMap?.shortcutActions ?? {};
      const bound = new Set(Object.keys(shortcutActions).map((k) => k.toUpperCase()));
      return ids.map((id) => {
        const tip = document.querySelector(`#${id} .custom-tooltip`);
        const text = (tip?.textContent ?? "").trim();
        const match = /^(.+?) \(([^()]+)\)$/.exec(text);
        const chord = match ? match[2] : "";
        // "F8 F2" is two chords; every one of them must be bound.
        const chords = chord ? chord.split(/\s+/) : [];
        return {
          id,
          chord,
          chordCount: chords.length,
          allBound: chords.length > 0 && chords.every((c) => bound.has(c.toUpperCase())),
          boundTableSize: bound.size,
        };
      });
    }, TOOLBAR_BUTTON_IDS as unknown as string[]);

    // NON-VACUITY: an empty shortcut table would make `allBound` false for
    // everything, but an assertion shaped as "no unbound chords found" would
    // pass over an empty LIST of controls. Both populations are sized.
    expect(results.length).toBe(13);
    expect(results[0].boundTableSize).toBeGreaterThan(40);

    let controlsBound = 0;
    for (const r of results) {
      expect(r.chordCount).toBeGreaterThan(0);
      expect(r.allBound, `#${r.id} claims "${r.chord}", which nothing has bound`).toBe(true);
      controlsBound += 1;
    }
    expect(controlsBound).toBe(13);
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
      const key = chordToPlaywrightKey(chord);

      // 1. Press the key the tooltip claims.
      await resetStepLog(page);
      await page.keyboard.press(key);
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
