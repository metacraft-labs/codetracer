/**
 * Opening CodeTracer's alternative editor views (generated C, assembly) from a
 * Playwright test.
 *
 * ---------------------------------------------------------------------------
 * WHY THIS MODULE EXISTS: the old approach could never work
 * ---------------------------------------------------------------------------
 *
 * Both Nim view-switching specs used to reach for `window.data.openTab`:
 *
 *     if (typeof data.openTab === "function") {
 *       data.openTab(cPath, 1);
 *       ...
 *     }
 *     return false;      // <- the only branch that ever ran
 *
 * `openTab` is a *free* Nim proc — `proc openTab*(data: Data, ...)` at
 * `src/frontend/utils.nim:1848`. Nim's JS backend emits procs as free
 * functions taking `self` as the first parameter; they are never attached to
 * the generated JS object. The codebase states this about itself at
 * `src/frontend/ui_js.nim:4881-4890` ("Nim's JS backend emits procs that take
 * `self` as a first parameter — they are NOT attached as methods on the JS
 * prototype"). `window.data.openTab` is therefore permanently `undefined`,
 * the `typeof ... === "function"` guard was permanently false, and every
 * helper built on it could only ever return `false`.
 *
 * There is no `openTab` field on `Data` and no `{.exportc.}` for it, so no
 * variant of that access can succeed.
 *
 * ---------------------------------------------------------------------------
 * THE LIVE PATH: the mechanism production actually uses
 * ---------------------------------------------------------------------------
 *
 * `data.ui.openViewOnCompleteMove` is a plain `array[EditorView, bool]` field
 * (`src/frontend/types.nim:2020`), reachable from JS through the
 * session-forwarding accessors installed on `window.data`
 * (`src/frontend/types.nim:2519+` defines enumerable get/set forwarders for
 * `ui`, `services`, `sourcemap`, ... onto `sessions[activeSessionIndex]`).
 * Writing an element of that array from `page.evaluate` mutates the very
 * array the frontend reads.
 *
 * On every complete-move, `EditorViewComponent.onCompleteMove` walks that
 * array and opens the armed views **from the Nim side**
 * (`src/frontend/ui/editor.nim:4254-4267`):
 *
 *     for view, isEnabled in self.data.ui.openViewOnCompleteMove:
 *       if isEnabled:
 *         case view:
 *         of ViewInstructions:
 *           ... self.data.openInstructions(self.data.services.debugger.cLocation.asmName)
 *         of ViewTargetSource:
 *           ... self.data.openTargetSource(self.data.services.debugger.cLocation.path)
 *
 * Those calls are Nim-to-Nim, so they resolve normally. So the recipe is:
 * set the flag from JS, then take one step — and the product opens the view
 * for us.
 *
 * This is *more* faithful than the old `openTab` call, not less: arming
 * `openViewOnCompleteMove` is exactly how `renderer.openTargetSource` /
 * `renderer.openInstructions` arm themselves
 * (`src/frontend/renderer.nim:989-995`). It also means the test no longer has
 * to reconstruct the assembly tab name: `asmName` is a free Nim proc too, and
 * on this path Nim computes it itself.
 *
 * Nothing ever resets `openViewOnCompleteMove` (the only writes in the tree
 * are the two `= true` sites in `renderer.nim`), so once armed the view is
 * re-opened on each subsequent move — which is what the stepping tests want.
 */

import type { Page } from "@playwright/test";
import { retry } from "./retry-helpers";

/**
 * `EditorView` ordinals, from
 * `src/common/common_types/debugger_features/debugger.nim:63-73`. The enum has
 * no explicit values, so ordinals follow declaration order from 0, and Nim's
 * JS backend represents enum values as plain integers.
 */
export const ViewSource = 0;
export const ViewTargetSource = 1;
export const ViewInstructions = 2;

export type AlternativeView = typeof ViewTargetSource | typeof ViewInstructions;

/** Human-readable name for an `EditorView` ordinal, for failure messages. */
export function viewName(view: number): string {
  switch (view) {
    case ViewSource:
      return "ViewSource";
    case ViewTargetSource:
      return "ViewTargetSource (generated C)";
    case ViewInstructions:
      return "ViewInstructions (assembly)";
    default:
      return `EditorView(${view})`;
  }
}

/**
 * A snapshot of everything that decides whether an alternative view can open.
 * Captured in one `page.evaluate` so a failure message can name the precise
 * missing precondition instead of saying "switch failed".
 */
export interface AlternativeViewState {
  hasData: boolean;
  hasFlags: boolean;
  sourcemapLoaded: boolean;
  /** `cLocation.path` — what `openTargetSource` is handed for the C view. */
  cPath: string;
  /** `cLocation.functionName` — the second half of the assembly tab name. */
  cFunctionName: string;
  /** `location.path` — the high-level (Nim) position, for context. */
  sourcePath: string;
  /** `editorView` ordinals of every currently open editor. */
  openViews: number[];
}

export async function readAlternativeViewState(
  page: Page,
): Promise<AlternativeViewState> {
  return await page.evaluate(() => {
    const w = window as any; // eslint-disable-line @typescript-eslint/no-explicit-any
    const data = w.data;
    const str = (v: unknown): string => (typeof v === "string" ? v : "");

    const dbg = data?.services?.debugger;
    const editors = data?.ui?.editors;
    const openViews: number[] = [];
    if (editors) {
      for (const key of Object.keys(editors)) {
        const view = editors[key]?.editorView;
        if (typeof view === "number") openViews.push(view);
      }
    }

    return {
      hasData: !!data,
      hasFlags: Array.isArray(data?.ui?.openViewOnCompleteMove),
      sourcemapLoaded: data?.sourcemap?.loaded === true,
      cPath: str(dbg?.cLocation?.path),
      cFunctionName: str(dbg?.cLocation?.functionName),
      sourcePath: str(dbg?.location?.path),
      openViews,
    };
  });
}

/** Renders a state snapshot into a one-line diagnostic for an error message. */
export function describeState(state: AlternativeViewState): string {
  return (
    `hasData=${state.hasData} hasFlags=${state.hasFlags} ` +
    `sourcemapLoaded=${state.sourcemapLoaded} ` +
    `cLocation.path=${state.cPath || "(empty)"} ` +
    `cLocation.functionName=${state.cFunctionName || "(empty)"} ` +
    `location.path=${state.sourcePath || "(empty)"} ` +
    `openEditorViews=[${state.openViews.join(",")}]`
  );
}

/**
 * Arms `data.ui.openViewOnCompleteMove[view]` so the next complete-move opens
 * that view. Returns whether the write landed (it reads the flag back).
 */
export async function armAlternativeView(
  page: Page,
  view: AlternativeView,
): Promise<boolean> {
  return await page.evaluate((v: number) => {
    const w = window as any; // eslint-disable-line @typescript-eslint/no-explicit-any
    const flags = w.data?.ui?.openViewOnCompleteMove;
    if (!flags) return false;
    flags[v] = true;
    return flags[v] === true;
  }, view);
}

/** Whether an editor with the given `editorView` ordinal is currently open. */
export async function isViewOpen(page: Page, view: number): Promise<boolean> {
  return await page.evaluate((v: number) => {
    const w = window as any; // eslint-disable-line @typescript-eslint/no-explicit-any
    const editors = w.data?.ui?.editors;
    if (!editors) return false;
    return Object.keys(editors).some((k) => editors[k]?.editorView === v);
  }, view);
}

/**
 * Opens the generated-C or assembly view and waits until it is actually there.
 *
 * THROWS (never skips) when the view cannot be opened, with a message naming
 * the missing precondition. A permanently-skipped test is a check that passes
 * by not running; these preconditions are fixed properties of the pinned Nim
 * trace rather than per-run flake, so an unmet one is a real defect and must
 * be visible as a failure.
 *
 * @param step  Takes one debugger step. Opening is driven by the
 *              complete-move handler, so a step is how the armed view is
 *              actually realised.
 */
export async function openAlternativeView(
  page: Page,
  view: AlternativeView,
  step: () => Promise<void>,
): Promise<void> {
  const before = await readAlternativeViewState(page);

  if (!before.hasData || !before.hasFlags) {
    throw new Error(
      `Cannot open ${viewName(view)}: the frontend never exposed ` +
        `data.ui.openViewOnCompleteMove to the page. ${describeState(before)}`,
    );
  }

  // Both alternative views for a Nim trace are keyed off `cLocation`:
  // `openTargetSource` takes `cLocation.path` and `openInstructions` takes
  // `cLocation.asmName`, which is `path:functionName`
  // (src/frontend/ui/editor.nim:4260-4266).
  if (before.cPath.length === 0) {
    throw new Error(
      `Cannot open ${viewName(view)}: the debugger never resolved a ` +
        `generated-C location for this frame, so there is nothing to open. ` +
        `This usually means the trace was recorded without --sourcemap:on or ` +
        `without the patched Nim compiler. ${describeState(before)}`,
    );
  }

  if (view === ViewInstructions && before.cFunctionName.length === 0) {
    throw new Error(
      `Cannot open ${viewName(view)}: cLocation.functionName is empty, so ` +
        `the assembly tab name (path:functionName) cannot be formed. ` +
        `${describeState(before)}`,
    );
  }

  if (!(await armAlternativeView(page, view))) {
    throw new Error(
      `Cannot open ${viewName(view)}: writing ` +
        `data.ui.openViewOnCompleteMove[${view}] did not take effect. ` +
        `${describeState(before)}`,
    );
  }

  // The armed flag is consumed by `EditorViewComponent.onCompleteMove`, so it
  // takes a move to realise. The flag is never cleared, so extra steps are
  // harmless if the first move lands mid-initialisation.
  await step();

  try {
    await retry(async () => isViewOpen(page, view), {
      maxAttempts: 20,
      delayMs: 1000,
    });
  } catch {
    const after = await readAlternativeViewState(page);
    throw new Error(
      `${viewName(view)} was armed via data.ui.openViewOnCompleteMove[${view}] ` +
        `and a step was taken, but no editor with that view ever opened. ` +
        `before: ${describeState(before)} | after: ${describeState(after)}`,
    );
  }
}
