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

/**
 * THE HOST NOW CARRIES ONE OF TWO PANELS.
 *
 * `#isonim-debug-controls` holds the debugger's stepping controls in a replay
 * session and the EDIT-MODE toolbar while the user is editing — never both,
 * because it is one element. Which one is a function of `data.ui.mode`, and
 * the swap happens through `ui/debug.nim`'s `refreshTopbarSurface`.
 *
 * Both panel roots declare which surface they are, so a selector can be
 * specific instead of hoping. Prefer `topbarSurfaceSelector` over a bare
 * `#run-tests-image`: that id is emitted by BOTH panels and means different
 * things in each — "record and replay tests" in the debugger,
 * `ToolbarButton.id` for Run Tests in the edit toolbar. It is deliberately not
 * renamed, because it is the spec's id and no page object here targets it.
 */
export const TOPBAR_SURFACES = {
  debuggerControls: "debugger-controls",
  editCommands: "edit-commands",
} as const;

export type TopbarSurface = keyof typeof TOPBAR_SURFACES;

/** Selector for the topbar panel root of a given surface. */
export function topbarSurfaceSelector(surface: TopbarSurface): string {
  return `[data-topbar-surface="${TOPBAR_SURFACES[surface]}"]`;
}

/**
 * The edit-mode toolbar's button ids, which are `ToolbarButton.id` from
 * `viewmodel/viewmodels/edit_mode_toolbar.nim` — the spec's names, not the
 * harness's. Scope them with `topbarSurfaceSelector("editCommands")` when the
 * id is one the debugger also emits.
 */
export const EDIT_TOOLBAR_IDS = {
  build: "build-image",
  run: "run-image",
  /** Also emitted by the debugger panel, where it means Record Tests. */
  runTests: "run-tests-image",
  recordTests: "record-tests-image",
  overflow: "action-overflow-image",
} as const;

export type EditToolbarButton = keyof typeof EDIT_TOOLBAR_IDS;

/** `#`-prefixed selector scoped to the edit-mode surface. */
export function editToolbarSelector(button: EditToolbarButton): string {
  return `${topbarSurfaceSelector("editCommands")} #${EDIT_TOOLBAR_IDS[button]}`;
}
