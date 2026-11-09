/**
 * E2E test for the language-dynamic View-menu items.
 *
 * `appendLanguageSpecificViewItems` in src/frontend/ui_js.nim adds four
 * Nim-specific items to the View folder for Nim traces:
 *   - "View Generated C Source"
 *   - "View Disassembly"
 *   - "Trace Macro at Cursor"
 *   - "Trace Static Block at Cursor"
 *
 * Non-Nim traces have an empty per-language area (no such items appear
 * in the View folder).
 *
 * The menu is the same source of truth on Linux (in-app MenuComponent)
 * and macOS (Menu.setApplicationMenu): both consume `data.ui.menuNode`,
 * which the renderer rebuilds via `webTechMenu` whenever a trace is
 * loaded.  Asserting at that level covers both OSes by inspecting the
 * menu tree shape rather than OS-native widgets.
 *
 * This spec also indirectly guards a latent macOS bug fixed alongside
 * the per-language injection: previously `defineMenu`'s macro
 * expansion called `registerMenu` BEFORE any runtime injection
 * (launch configs, per-language items) ran.  macOS users therefore
 * received a stale menu without the dynamic items.  The fix moves
 * `registerMenu` to the END of `webTechMenu` so every dynamic
 * mutation is captured before the OS menu bar is registered.
 */

import { test, expect } from "../../lib/fixtures";
import type { Page } from "@playwright/test";
import { LayoutPage } from "../../page-objects/layout-page";

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/** Labels the renderer attaches to the per-language View-menu items. */
const NIM_VIEW_ITEM_LABELS = [
  "View Generated C Source",
  "View Disassembly",
  "Trace Macro at Cursor",
  "Trace Static Block at Cursor",
] as const;

/**
 * Shape of the JSON serialisation we extract from `data.ui.menuNode`.
 *
 * `MenuNode` (frontend/types.nim) is a Nim `ref object` exposed on
 * `window.data.ui.menuNode`.  We only care about the label tree, so
 * we narrow to a minimal recursive type when crossing the page
 * boundary.
 */
interface MenuNodeShape {
  name: string;
  kind: number; // MenuNodeKind enum ordinal: 0 = MenuFolder, 1 = MenuElement
  children: MenuNodeShape[];
}

/**
 * The loaded trace as the renderer sees it when it builds the menu,
 * plus the menu it built.
 */
interface LoadedTraceMenu {
  /** `session.trace.lang` as the ordinal of Nim's `Lang` enum. */
  lang: number;
  /** `session.trace.program`. */
  program: string;
  /**
   * The renderer's `effectiveTraceLang` (ui_js.nim) resolves to
   * `LangNim` for this trace — the condition under which
   * `appendLanguageSpecificViewItems` adds the Nim items.
   */
  isNim: boolean;
  menuNode: MenuNodeShape;
}

/**
 * Wait until a trace is loaded and the menu built for it, then read
 * both.  Trace load is async (DAP handshake -> run-to-entry), and
 * `onTraceLoaded` (ui_js.nim) sets `data.trace` and rebuilds
 * `data.ui.menuNode` in the same synchronous step, so once the
 * session carries a loaded trace its menu reflects that trace and not
 * the pre-trace menu.
 *
 * The wait does NOT depend on the trace's language.  It used to wait
 * for a `trace.program` ending in `.nim`, which never happens for a
 * recorded `.nim` source: `ct record` compiles it and records the
 * binary, so the program has no extension (codetracer-pm issue
 * 2026-11-09-language-dynamic-menu-nim-case-waits-for-a-program-named-dot-nim).
 * The language is instead classified the way the renderer does, and
 * the caller asserts on it.
 */
async function readMenuNodeWhenReady(page: Page): Promise<LoadedTraceMenu> {
  // `Data.trace`, `Data.ui` and friends are Nim `template`s that
  // resolve to `data.sessions[data.activeSessionIndex].<field>`,
  // so we have to walk the same path from the JS side (templates do
  // not erase to actual fields on the JS object).
  await page.waitForFunction(
    () => {
      const d = (window as unknown as { data?: any }).data;
      if (!d) return false;
      const idx = typeof d.activeSessionIndex === "number"
        ? d.activeSessionIndex
        : 0;
      const session = Array.isArray(d.sessions) ? d.sessions[idx] : null;
      if (!session?.ui?.menuNode) return false;
      return String(session.trace?.program ?? "").length > 0;
    },
    undefined,
    { timeout: 60_000 },
  );

  return await page.evaluate((): LoadedTraceMenu => {
    // Ordinals mirrored from Nim enums as numeric literals, because
    // Playwright cannot import Nim sources and the JS backend erases
    // enums to their ordinals:
    //   - `MenuNodeKind` (frontend/types.nim): MenuFolder = 0,
    //     MenuElement = 1.
    //   - `Lang` (common/common_lang.nim): LangUnknown = 0,
    //     LangNim = 4.  Those ordinals are pinned against the Rust
    //     enum by src/tests/cli/lang_enum_contract_test.nim.
    const LANG_UNKNOWN = 0;
    const LANG_NIM = 4;
    const d = (window as unknown as { data?: any }).data;
    const idx = typeof d.activeSessionIndex === "number"
      ? d.activeSessionIndex
      : 0;
    const session = d.sessions[idx];
    const lang = typeof session.trace.lang === "number"
      ? session.trace.lang
      : -1;
    const program = String(session.trace.program ?? "");
    // Mirror of `effectiveTraceLang` in ui_js.nim: `trace.lang` is
    // the canonical signal; only a `LangUnknown` trace falls back to
    // the program's `.nim` extension.
    const isNim = lang === LANG_NIM ||
      (lang === LANG_UNKNOWN && program.toLowerCase().endsWith(".nim"));
    const toShape = (n: any): MenuNodeShape => ({
      name: typeof n?.name === "string" ? n.name : String(n?.name ?? ""),
      kind: typeof n?.kind === "number" ? n.kind : -1,
      children: Array.isArray(n?.elements)
        ? n.elements.map(toShape)
        : [],
    });
    return { lang, program, isNim, menuNode: toShape(session.ui.menuNode) };
  });
}

/**
 * Locate the "View" folder among the top-level entries of the
 * webTechMenu tree.  The top-level node is the program name
 * (e.g. "ct"), with each menu folder sitting one level below.
 */
function findViewFolder(root: MenuNodeShape): MenuNodeShape | null {
  // MenuFolder kind ordinal = 0.
  const candidates =
    root.kind === 0 && root.children.length > 0
      ? root.children
      : [root];
  for (const top of candidates) {
    if (top.name === "View" && top.kind === 0) return top;
  }
  // Some menu shells nest one level deeper (the top-level is the
  // program node containing the folders).  Recurse one level to
  // tolerate that without making the assertion brittle.
  for (const top of candidates) {
    for (const child of top.children) {
      if (child.name === "View" && child.kind === 0) return child;
    }
  }
  return null;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test.describe("language-dynamic View-menu items", () => {
  test.describe("Nim trace", () => {
    test.use({
      sourcePath: "nim_static_block/main.nim",
      launchMode: "trace",
    });
    test.setTimeout(240_000);

    test(
      "View folder exposes the four Nim-specific items",
      async ({ ctPage }) => {
        const layout = new LayoutPage(ctPage);
        await layout.waitForBaseComponentsLoaded();

        const loaded = await readMenuNodeWhenReady(ctPage);
        expect(
          loaded.isNim,
          "the loaded trace must resolve to Nim the way the renderer " +
            `resolves it (trace.lang=${loaded.lang}, ` +
            `program=${JSON.stringify(loaded.program)})`,
        ).toBe(true);
        const viewFolder = findViewFolder(loaded.menuNode);
        expect(
          viewFolder,
          "View folder must exist in the menu tree",
        ).not.toBeNull();
        const labels = (viewFolder?.children ?? []).map((c) => c.name);
        for (const required of NIM_VIEW_ITEM_LABELS) {
          expect(
            labels,
            `View folder must contain "${required}" for Nim traces ` +
              `(got: ${JSON.stringify(labels)})`,
          ).toContain(required);
        }
      },
    );
  });

  test.describe("Python trace", () => {
    test.use({
      sourcePath: "py_console_logs/main.py",
      launchMode: "trace",
    });
    test.setTimeout(240_000);

    test(
      "View folder does NOT expose the Nim-specific items",
      async ({ ctPage }) => {
        const layout = new LayoutPage(ctPage);
        await layout.waitForBaseComponentsLoaded();

        const loaded = await readMenuNodeWhenReady(ctPage);
        expect(
          loaded.isNim,
          "the loaded trace must not resolve to Nim " +
            `(trace.lang=${loaded.lang}, ` +
            `program=${JSON.stringify(loaded.program)})`,
        ).toBe(false);
        const viewFolder = findViewFolder(loaded.menuNode);
        expect(
          viewFolder,
          "View folder must exist in the menu tree",
        ).not.toBeNull();
        const labels = (viewFolder?.children ?? []).map((c) => c.name);
        for (const forbidden of NIM_VIEW_ITEM_LABELS) {
          expect(
            labels,
            `View folder must NOT contain "${forbidden}" for non-Nim ` +
              `traces (got: ${JSON.stringify(labels)})`,
          ).not.toContain(forbidden);
        }
      },
    );
  });
});
