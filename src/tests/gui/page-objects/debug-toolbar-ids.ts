/**
 * Single source of truth for the debug-toolbar button element ids.
 *
 * The toolbar markup is emitted by
 * `src/frontend/viewmodel/views/isonim_debug_controls_view.nim`.  The button
 * ids there all end in `-image` (`run-to-entry-image`, `next-image`, ...);
 * `jump-to-live-debug` is the one control that kept a `-debug` suffix.
 *
 * Why this file exists: the repo has two page objects that both locate these
 * buttons — `layout-page.ts` (the rich one nearly every spec imports) and
 * `layout_page.ts` (a smaller one used by a handful of specs).  Each carried
 * its own hard-coded copy of the id list, and they drifted: `layout-page.ts`
 * still used the pre-rename `*-debug` ids, so `LayoutPage.runToEntryButton()`
 * and friends resolved to nothing and every spec that clicked a debug-toolbar
 * button died on a 30 s locator timeout.  Keeping the ids here means a future
 * rename in the Nim view has exactly one place to land on the harness side.
 */

export const DEBUG_TOOLBAR_IDS = {
  runToEntry: "run-to-entry-image",
  continue: "continue-image",
  reverseContinue: "reverse-continue-image",
  stepOut: "step-out-image",
  reverseStepOut: "reverse-step-out-image",
  stepIn: "step-in-image",
  reverseStepIn: "reverse-step-in-image",
  next: "next-image",
  reverseNext: "reverse-next-image",
  /** The one control the rename left alone. */
  jumpToLive: "jump-to-live-debug",
} as const;

export type DebugToolbarButton = keyof typeof DEBUG_TOOLBAR_IDS;

/** `#`-prefixed CSS selector for a debug-toolbar button. */
export function debugToolbarSelector(button: DebugToolbarButton): string {
  return `#${DEBUG_TOOLBAR_IDS[button]}`;
}
