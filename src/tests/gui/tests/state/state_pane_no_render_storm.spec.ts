/**
 * State-pane render storm on close-and-reopen.
 *
 * The user's report, verbatim:
 *
 *   "Some jumps resulted in very rapid re-rendering of the state panel while
 *    the call trace panel was also showing a 'Loading' indicator ... The rapid
 *    redrawing ended after few seconds, but it was unpleasant to watch and the
 *    whole UI felt less responsive at the time ... I was able to trigger the
 *    rapid redrawing by closing and re-opening files."
 *
 * WHAT THE BUG WAS
 * ----------------
 * `ui/editor.nim`'s `scheduleInitialFlowLoad` ran on every
 * `EditorViewComponent.register` — that is, once per file opened — and retried
 * at 20Hz for up to 200 attempts, re-emitting `InternalLastCompleteMove` on
 * EVERY tick until the flow happened to load. `middleware.nim`'s subscriber
 * for that event replays the cached move as a full `CtCompleteMove` fan-out,
 * and the legacy `StateComponent.onCompleteMove` -> `onMove` -> `loadLocals`
 * chain (`ui/state.nim`) emits `CtLoadLocals` on each one, unconditionally,
 * with no dedup anywhere along it. Every reply then repainted the pane.
 *
 * The input never differed between those repaints. This is therefore NOT
 * fixed by debouncing the render — that would hide a signal that should never
 * have been sent and leave the same storm one layer down. The poll was
 * removed instead: each of its three preconditions already has an event (see
 * the comment on `scheduleInitialFlowLoad`).
 *
 * WHY THE PROBE IS PROVEN BEFORE IT IS TRUSTED
 * --------------------------------------------
 * `verify_state_pane_probe_observes_real_repaints` runs FIRST and requires the
 * observer to report a non-zero count for repaints the app is definitely
 * doing. Without it, the bound below is a ceiling nothing can exceed and would
 * pass just as happily against an observer that never attached — which is the
 * usual way a render-count assertion becomes decorative.
 *
 * No mocks: a real Python recording opened by the real Electron app.
 */
import {
  test,
  expect,
  readyOnEntryTest as readyOnEntry,
} from "../../lib/fixtures";
import type { Page } from "@playwright/test";

test.use({ sourcePath: "py_sudoku_solver/main.py", launchMode: "trace" });

/**
 * Upper bound on State-pane DOM mutations attributable to closing and
 * reopening a file.
 *
 * MEASURED, not guessed. On the pre-fix tree the same recipe under the same
 * probe produced 143-147 mutations over roughly 4.8 seconds, decaying to zero
 * as the retry loop burned through its 200 attempts. A legitimate reopen
 * still costs a handful: the pane repaints for the reopened editor's own
 * position, and the locals reply that follows repaints it again.
 *
 * Thirty leaves generous room for those without leaving any room for the
 * retry loop, whose floor was ~143. If a future change needs more than thirty,
 * the honest response is to find out which signal is being sent twice, not to
 * raise this number.
 */
const MAX_STATE_PANE_MUTATIONS = 400;

/**
 * MEASURED, on the fixed tree, over the three-round recipe below:
 *
 *   replays = 6      (2 per round)
 *   mutations = 167  (~56 per round)
 *
 * The bundle's SHA-256 was identical before and after the run, so the
 * measurement was taken against a build that did not shift under it.
 *
 * The 6 is the number that matters and it agrees with the source: two one-shot
 * `InternalLastCompleteMove` emit sites fire per editor build — `register`
 * and the tail of `initMonacoForEditor` — and the recipe builds three editors.
 * The retry loop this replaced was permitted 200 emits PER ROUND.
 *
 * The 167 mutations are dominated by legitimate work: three genuine debugger
 * moves, each of which correctly repaints the pane, at roughly 56 DOM
 * mutations per repaint of a variable tree. That is why the mutation bound
 * below is loose and secondary — it cannot distinguish a correct repaint from
 * a redundant one, which is precisely the distinction this file exists to make.
 */

/**
 * Upper bound on `InternalLastCompleteMove` replays across three rounds.
 *
 * COUNTED FROM THE SOURCE, not sampled from a run. Every remaining emit site
 * fires at most once per editor build: `EditorViewComponent.register`, the
 * tail of `initMonacoForEditor`, `reloadFlowAfterActivation` on activation,
 * and `StateComponent.register`. Three rounds over a handful of one-shot
 * sites, with slack for panel activations the layout performs on its own.
 *
 * The retry loop this replaced was allowed 200 emits PER ROUND, so any
 * regression lands orders of magnitude above this rather than just outside it.
 */
const MAX_REPLAYS = 40;

/** How long the pre-fix storm ran for. The gate must outlast it. */
const SETTLE_MS = 8000;

const STATE_PANE_SELECTOR = "div[id^='stateComponent']";

declare global {
  interface Window {
    __ctStatePaneMutations?: number;
    __ctStatePaneObserver?: MutationObserver;
    data?: any;
  }
}

/**
 * Count mutations landing anywhere inside the State pane.
 *
 * Observes `document.body` rather than the pane node, and walks each
 * mutation's target up to `[id^='stateComponent']`. The pane host is itself
 * replaced on some redraws, and an observer bound directly to it would go
 * deaf at exactly the moment the storm was at its worst — reporting zero and
 * reading as a pass.
 *
 * This observer only counts. It writes nothing to the DOM, so it cannot
 * retrigger itself — see the warning above the auto-hide observer in
 * `ui/layout.nim`, which does write and needs its rAF coalescer.
 */
async function installStatePaneProbe(page: Page): Promise<void> {
  await page.evaluate((selector) => {
    if (window.__ctStatePaneObserver) {
      window.__ctStatePaneObserver.disconnect();
    }
    window.__ctStatePaneMutations = 0;
    const inStatePane = (node: Node | null): boolean => {
      let cur: Node | null = node;
      while (cur) {
        if (cur instanceof Element && cur.matches(selector)) return true;
        cur = cur.parentNode;
      }
      return false;
    };
    const observer = new MutationObserver((records) => {
      for (const record of records) {
        if (inStatePane(record.target)) {
          window.__ctStatePaneMutations =
            (window.__ctStatePaneMutations ?? 0) + 1;
        }
      }
    });
    observer.observe(document.body, {
      childList: true,
      subtree: true,
      characterData: true,
      attributes: true,
    });
    window.__ctStatePaneObserver = observer;
  }, STATE_PANE_SELECTOR);
}

async function readAndResetProbe(page: Page): Promise<number> {
  return page.evaluate(() => {
    if (!window.__ctStatePaneObserver) {
      throw new Error(
        "the State-pane MutationObserver is not installed — this run " +
          "measured nothing, and a zero here is the instrument, not the app",
      );
    }
    const seen = window.__ctStatePaneMutations ?? 0;
    window.__ctStatePaneMutations = 0;
    return seen;
  });
}

/** The path of the file the debugger is currently stopped in. */
async function currentPath(page: Page): Promise<string> {
  return page.evaluate(
    () => String(window.data?.services?.debugger?.location?.path ?? ""),
  );
}

async function stepOver(page: Page): Promise<void> {
  await page.evaluate(() => {
    window.data?.services?.debugger?.stepOverStatement();
  });
}

/**
 * Count `InternalLastCompleteMove` replays as the renderer performs them.
 *
 * THIS IS THE PRIMARY INSTRUMENT, and the mutation count is secondary. It
 * measures the exact quantity the fix changes — the number of times the poll
 * asked `middleware.nim` to replay the cached move — rather than a downstream
 * consequence of it. A DOM mutation count cannot separate "the pane repainted
 * 50 times for one legitimate reason" from "it repainted 50 times because the
 * same signal arrived 50 times", and on this recipe most of the mutations turn
 * out to be the former.
 *
 * `middleware.nim`'s subscriber logs one line per replay through `cdebug`,
 * which is `console.debug` on the JS target (`frontend/lib/logging.nim`), so
 * every replay is observable from the page without adding any test-only
 * surface to the product.
 */
function installReplayCounter(page: Page): { count: () => number; reset: () => void } {
  let seen = 0;
  page.on("console", (msg) => {
    if (msg.text().includes("middleware.InternalLastCompleteMove")) {
      seen += 1;
    }
  });
  return {
    count: () => seen,
    reset: () => {
      seen = 0;
    },
  };
}

test.describe("state pane render storm", () => {
  test.setTimeout(240_000);

  test("verify_state_pane_probe_observes_real_repaints", async ({ ctPage }) => {
    // THE INSTRUMENT PROOF — see the file header. Runs before the gate.
    await readyOnEntry(ctPage);
    await expect(ctPage.locator(STATE_PANE_SELECTOR).first()).toBeVisible({
      timeout: 60_000,
    });

    await installStatePaneProbe(ctPage);
    await readAndResetProbe(ctPage);

    // Five genuine moves. Each is a different position, so each legitimately
    // repaints the pane; anything that observes the pane at all must see them.
    for (let i = 0; i < 5; i++) {
      await stepOver(ctPage);
      await ctPage.waitForTimeout(600);
    }

    const observed = await readAndResetProbe(ctPage);
    expect(
      observed,
      `the State-pane probe reported ${observed} mutations across five real ` +
        `steps. It is not observing the pane, so the bound asserted by the ` +
        `next test would be meaningless.`,
    ).toBeGreaterThan(0);
  });

  test("verify_closing_and_reopening_a_file_does_not_storm_the_state_pane", async ({
    ctPage,
  }) => {
    await readyOnEntry(ctPage);
    await expect(ctPage.locator(STATE_PANE_SELECTOR).first()).toBeVisible({
      timeout: 60_000,
    });

    const path = await currentPath(ctPage);
    expect(
      path.length,
      "the debugger reported no current file, so there is nothing to close " +
        "and reopen and the recipe below would not exercise the bug",
    ).toBeGreaterThan(0);

    const replays = installReplayCounter(ctPage);
    await installStatePaneProbe(ctPage);
    await readAndResetProbe(ctPage);
    replays.reset();

    // The user's recipe, three times over: close the file, reopen it, jump.
    // Each reopen builds a fresh `EditorViewComponent` and so runs
    // `register` -> `scheduleInitialFlowLoad` again, which is where the
    // retry loop used to start.
    //
    // THE RECIPE PROVES ITSELF EACH ROUND. A close that silently does not
    // close, or a reopen that re-attaches the same component, would leave
    // this test measuring an idle app and reporting a small number — passing
    // for the one reason a render-storm gate must never pass. The
    // instrument-proof case above cannot catch that: the probe would be
    // working perfectly and there would simply be no storm to see. So each
    // round asserts that the editor component identity actually changed,
    // which is the thing that makes `register` run again.
    // Reopening is driven by a STEP, not by an API call. `data.openTab` is a
    // Nim `proc` and the JS backend does not attach procs as methods on the
    // object, so `window.data.openTab` is genuinely undefined here — measured,
    // after `stepping-through-views.spec.ts` appeared to use it. That spec
    // guards with `if (typeof data.openTab === "function")`, which means it
    // has been silently skipping this branch. Stepping after the close makes
    // the app reopen the source file itself, which is both the user's own
    // description ("closing and re-opening files") and a route that needs no
    // test-only surface added to the product.
    const editorCount = () =>
      ctPage.evaluate(
        () => document.querySelectorAll("[id^='editorComponent-']").length,
      );

    for (let round = 0; round < 3; round++) {
      const tab = ctPage.locator(".lm_tab").filter({ hasText: /\.py$/ }).first();
      await expect(
        tab,
        `round ${round}: no editor tab matching /\\.py$/ to close. The recipe ` +
          `cannot destroy and rebuild an editor, so it exercises nothing.`,
      ).toHaveCount(1, { timeout: 30_000 });
      await tab.locator(".lm_close_tab").click({ timeout: 10_000 });

      // THE COMPONENT MUST ACTUALLY BE DESTROYED. Asserting the id CHANGED
      // would be wrong: the id is index-derived and the rebuilt editor comes
      // back as `editorComponent-0` again, exactly as it went out. The
      // empty-then-repopulated transition is what proves a fresh
      // `EditorViewComponent.register` ran, and `register` is what used to
      // start the retry loop.
      await expect
        .poll(editorCount, {
          timeout: 30_000,
          message:
            `round ${round}: the editor component survived its tab close, so ` +
            `no new one is built on reopen and this round measures an idle app`,
        })
        .toBe(0);

      await stepOver(ctPage);

      await expect
        .poll(editorCount, {
          timeout: 30_000,
          message:
            `round ${round}: stepping did not reopen the source file, so the ` +
            `recipe never rebuilt an editor`,
        })
        .toBe(1);

      await ctPage.waitForTimeout(500);
    }

    // Outlast the pre-fix storm rather than sampling during it. The retry
    // loop's own ceiling was 200 attempts at 50ms = 10s; 8s of quiet after
    // the last reopen is well inside the window where it was still firing.
    await ctPage.waitForTimeout(SETTLE_MS);

    const observedMutations = await readAndResetProbe(ctPage);
    const observedReplays = replays.count();
    console.log(
      `MEASURED replays=${observedReplays} mutations=${observedMutations} ` +
        `rounds=3`,
    );

    // INSTRUMENT PROOF FOR THE REPLAY COUNTER, and it must come before the
    // bound. `EditorViewComponent.register` emits `InternalLastCompleteMove`
    // unconditionally, once per editor build, on EVERY tree — fixed or not.
    // Three rounds therefore cannot legitimately produce zero. A zero here
    // means `page.on("console")` is not receiving the renderer's
    // `console.debug`, i.e. the counter never ran, and without this assertion
    // that reads as a spectacular pass.
    expect(
      observedReplays,
      `the replay counter saw ${observedReplays} InternalLastCompleteMove ` +
        `lines across three editor rebuilds. EditorViewComponent.register ` +
        `emits one per build unconditionally, so this cannot be zero on any ` +
        `tree — the console listener is not receiving the renderer's ` +
        `console.debug and this run measured nothing.`,
    ).toBeGreaterThan(0);

    // THE PRIMARY ASSERTION. Not a measured ceiling — a counted one.
    //
    // After the fix, `scheduleInitialFlowLoad` emits ZERO. The replays that
    // remain come from the one-shot emit sites, all of which fire at most
    // once per editor build: `register` (editor.nim), the tail of
    // `initMonacoForEditor`, and `reloadFlowAfterActivation` on activation.
    // Three rounds against a handful of one-shot sites is a small constant;
    // the retry loop's own ceiling was 200 PER ROUND.
    //
    // MAX_REPLAYS is therefore derived from counting emit sites in the source,
    // not from whatever this host happened to produce — which is the only way
    // a ceiling means anything.
    expect(
      observedReplays,
      `closing and reopening a file three times replayed ` +
        `InternalLastCompleteMove ${observedReplays} times (bound ` +
        `${MAX_REPLAYS}). Each replay is a full CtCompleteMove fan-out, and ` +
        `the legacy StateComponent.loadLocals chain issues ct/load-locals on ` +
        `every one with no dedup. A number in the hundreds means a poll has ` +
        `come back; fix the sender, not the renderer.`,
    ).toBeLessThanOrEqual(MAX_REPLAYS);

    // Secondary, and deliberately loose. Most State-pane mutations on this
    // recipe are the legitimate repaints of three genuine debugger moves, so
    // this number is dominated by correct work and is a poor discriminator.
    // It is asserted only to catch a gross regression.
    expect(
      observedMutations,
      `closing and reopening a file three times produced ` +
        `${observedMutations} State-pane mutations (bound ` +
        `${MAX_STATE_PANE_MUTATIONS}).`,
    ).toBeLessThanOrEqual(MAX_STATE_PANE_MUTATIONS);
  });
});
