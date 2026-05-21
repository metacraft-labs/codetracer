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
 * Wait until `window.data.ui.menuNode` is populated and a Nim
 * `data.trace.lang` is reflected on the page.  Trace load is async
 * (DAP handshake -> run-to-entry) and the menu is rebuilt inside the
 * same handler, so we poll for both to settle before asserting on
 * the tree shape.
 */
async function readMenuNodeWhenReady(
  page: Page,
  expectedLang: "nim" | "non-nim",
): Promise<MenuNodeShape> {
  // The MenuNode kind ordinals come straight from Nim's MenuNodeKind
  // enum (MenuFolder = 0, MenuElement = 1).  Mirroring them as
  // numeric literals here keeps the assertion infrastructure
  // self-contained — Playwright cannot import Nim sources.
  //
  // `Data.trace`, `Data.ui` and friends are Nim `template`s that
  // resolve to `data.sessions[data.activeSessionIndex].<field>`,
  // so we have to walk the same path from the JS side (templates do
  // not erase to actual fields on the JS object).
  //
  // The menu is rebuilt every time the renderer finishes loading a
  // trace (`onTraceLoaded` in ui_js.nim).  Wait until both
  // `session.ui.menuNode` is populated AND `session.trace.program`
  // names a file of the expected family — `data.trace.lang` is the
  // canonical signal, but historical recordings classified by an
  // earlier importer can have `lang === LangUnknown` even for Nim
  // traces (see `effectiveTraceLang` in ui_js.nim).  Asserting on
  // the program filename mirrors the renderer's own fallback so the
  // test still anchors on the loaded trace, not on a stale
  // pre-trace menu.
  await page.waitForFunction(
    (expected: string) => {
      const d = (window as unknown as { data?: any }).data;
      if (!d) return false;
      const idx = typeof d.activeSessionIndex === "number"
        ? d.activeSessionIndex
        : 0;
      const session = Array.isArray(d.sessions) ? d.sessions[idx] : null;
      if (!session?.ui?.menuNode) return false;
      const program = String(session.trace?.program ?? "");
      if (program.length === 0) return false;
      // Match the renderer's `effectiveTraceLang` heuristic by
      // extension.  The Lang enum (`common_lang.nim`) labels `.nim`
      // as LangNim; any other extension is treated as "not Nim"
      // for this test (the spec only contrasts Nim vs. non-Nim).
      const isNim = program.toLowerCase().endsWith(".nim");
      return expected === "nim" ? isNim : !isNim;
    },
    expectedLang,
    { timeout: 60_000 },
  );

  return await page.evaluate((): MenuNodeShape => {
    const d = (window as unknown as { data?: any }).data;
    const idx = typeof d.activeSessionIndex === "number"
      ? d.activeSessionIndex
      : 0;
    const session = d.sessions[idx];
    const toShape = (n: any): MenuNodeShape => ({
      name: typeof n?.name === "string" ? n.name : String(n?.name ?? ""),
      kind: typeof n?.kind === "number" ? n.kind : -1,
      children: Array.isArray(n?.elements)
        ? n.elements.map(toShape)
        : [],
    });
    return toShape(session.ui.menuNode);
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

        const menuNode = await readMenuNodeWhenReady(ctPage, "nim");
        const viewFolder = findViewFolder(menuNode);
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

        const menuNode = await readMenuNodeWhenReady(ctPage, "non-nim");
        const viewFolder = findViewFolder(menuNode);
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
