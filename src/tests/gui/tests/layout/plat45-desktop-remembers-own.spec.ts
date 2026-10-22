/**
 * plat45-desktop-remembers-own.spec.ts — PLAT-45 deliverable 8, the desktop's
 * half: the desktop remembers ITS OWN last layout, in its own file, restores it
 * on the next start, and View > Reset Layout returns it to the one shared
 * default while deleting only the desktop's own saved layout files.
 *
 * Two launches of the real Electron app on the `calc` recording, one worker,
 * one `XDG_CONFIG_HOME` (the fixture's), in order:
 *
 *   1. FIRST RUN — no saved layout at all: the index process installs the
 *      DEBUG MODE'S DEFAULT of the prefix's generated
 *      `config/default_layout.json` (PLAT-47: TESTS a tab of FILES, no
 *      CONSTRAINTS — the arrangement every front-end opens with), stack for
 *      stack (the runtime-inserted editor aside). The test then REARRANGES —
 *      the VCS pane is closed through GoldenLayout's own API, exactly what the
 *      tab's × does — and the desktop's write-through persists it.
 *   2. RESTART — the saved file is left as the first run left it
 *      (`preserveUserLayout`): the arrangement comes back without VCS.
 *      Native layout files planted in the native products' state root
 *      (`$CODETRACER_HOME/state` under the fixtures; `lib/ct-home.ts`) are the
 *      terminal's and the GPUI window's; View > Reset Layout is invoked, the
 *      same window shows the shared default (VCS back, the editor
 *      re-created), the desktop's
 *      saved file holds the Debug-mode default's stacks again — and the two
 *      native files are byte-identical.
 *
 * The prefix (`PLAT45_DESKTOP_PREFIX`, else `CODETRACER_TEST_PREFIX`) must
 * carry THIS checkout's desktop JavaScript — the reset action is new — and its
 * generated default; the recipe that builds one is
 * `scripts/plat45-desktop-prefix.sh`.
 *
 * No mocks: a real recording, the real `ct`, a real `replay-server`, the real
 * Electron app, real files.
 */

import * as fs from "fs";
import * as path from "path";
import { ctNativeStateDir, ctUserConfigDir } from "../../lib/ct-home";
import {
  ConstraintsContent,
  EditorContent,
  buildPrefix,
  debugDefaultStacks,
  fileStacks,
  hasContent,
  shippedLayoutFile,
  stackContents,
  withoutEditor,
} from "../../lib/layout-stacks";

import { expect, test } from "../../lib/fixtures";

// The pane the case rearranges away: VCS (`Content.VCS`). PLAT-45 closed
// CONSTRAINTS; since PLAT-47 the first run's Debug-mode default does not place
// CONSTRAINTS at all, so the case closes a pane that default does place.
const ClosedContent = 41;

// THE RECORDING IS MADE BY THE RUN ITSELF: `launchMode: "trace"` records
// `test-programs/calc/main.py` with the `ct` under test before the app opens,
// as every DB-based spec does. It used to read the terminal suites' cached
// `test-logs/tui-fixtures/calc-*` and threw at LOAD when that cache was cold —
// which is every CI job, since none of them runs the terminal lanes first.
const calcProgram = "calc/main.py";
// An existing `calc` recording to open instead of recording one
// (`launchMode: "trace-folder"`), for a host whose recorder cannot record —
// the arrangement under test does not depend on which recording of `calc` is
// open. Unset: the run records its own, as before.
const calcTrace = process.env.PLAT45_CALC_TRACE ?? "";

// The prepared prefix this spec launches, or "" for the build itself:
// `PLAT45_DESKTOP_PREFIX`, else the `CODETRACER_TEST_PREFIX` every other spec
// honours (`lib/fixtures.ts`). The fallback matters: this spec sets its own
// `codetracerPrefixOverride`, which REPLACES the fixture's default, so with
// only the suite-wide variable set it used to launch the build in
// `CODETRACER_BUILD_DIR` — another checkout's, in a dev shell entered there —
// and judge that checkout's desktop against this one's expectations.
const preparedPrefix =
  process.env.PLAT45_DESKTOP_PREFIX || process.env.CODETRACER_TEST_PREFIX || "";

function prefix(): string {
  // With no prepared prefix the spec runs against the BUILD itself — in CI's
  // GUI job the build is this checkout, carrying its own desktop JavaScript and
  // generated default. A worktree whose `src/build-debug` is another
  // checkout's needs `scripts/plat45-desktop-prefix.sh` and one of the two
  // variables above.
  return preparedPrefix.length > 0 ? preparedPrefix : buildPrefix();
}

function userLayoutPath(): string {
  return path.join(ctUserConfigDir(), "default_layout.json");
}


test.describe.serial("PLAT-45: the desktop remembers its own layout, and resets to the shared default", () => {
  test.describe("first run, then a rearrangement", () => {
    test.use({
      sourcePath: calcTrace || calcProgram,
      launchMode: calcTrace ? "trace-folder" : "trace",
      codetracerPrefixOverride: preparedPrefix,
    });
    test.setTimeout(300_000);

    test("the first run opens the shared default and a rearrangement is saved", async ({ ctPage }) => {
      prefix();
      await ctPage.waitForSelector(".view-line", { timeout: 90_000 });
      const before = await stackContents(ctPage);
      expect(hasContent(before, ClosedContent)).toBe(true);
      expect(hasContent(before, ConstraintsContent)).toBe(false);
      // THE FIRST RUN OPENED THE DEBUG MODE'S DEFAULT of the generated bundled
      // tree (PLAT-47): the live arrangement is `debugDefaultStacks` of the
      // prefix's `config/default_layout.json`, stack for stack, and the
      // desktop's own saved file (written on first run, then re-saved by the
      // write-through in its one-line form) holds the same stacks. Not a byte
      // comparison: the write-through rewrites the file as soon as the layout
      // settles.
      const shipped = debugDefaultStacks(
        fileStacks(shippedLayoutFile(prefix())));
      expect(withoutEditor(before)).toEqual(shipped);
      expect(fs.existsSync(userLayoutPath())).toBe(true);
      expect(fileStacks(userLayoutPath())).toEqual(shipped);

      // REARRANGE: close the VCS pane, as its tab's × would.
      await ctPage.evaluate((content) => {
        // eslint-disable-next-line @typescript-eslint/no-explicit-any
        const gl = (window as any).data.ui.layout;
        // eslint-disable-next-line @typescript-eslint/no-explicit-any
        const find = (item: any): any => {
          if (!item) return null;
          if (item.type === "component") {
            const st = item.toConfig().componentState ?? {};
            return st.content === content ? item : null;
          }
          for (const c of item.contentItems ?? []) {
            const hit = find(c);
            if (hit) return hit;
          }
          return null;
        };
        const target = find(gl.rootItem);
        target.parent.removeChild(target);
      }, ClosedContent);
      // THE WRITE-THROUGH: the saved file loses the pane without a restart.
      await expect.poll(() => fs.readFileSync(userLayoutPath(), "utf8")
        .includes(`"content":${ClosedContent}`), { timeout: 30_000 }).toBe(false);
    });
  });

  test.describe("restart, then reset", () => {
    test.use({
      sourcePath: calcTrace || calcProgram,
      launchMode: calcTrace ? "trace-folder" : "trace",
      preserveUserLayout: true,
      codetracerPrefixOverride: preparedPrefix,
    });
    test.setTimeout(300_000);

    test("the restart restores it; Reset Layout returns the shared default and deletes only the desktop's files", async ({ ctPage }) => {
      prefix();
      // The terminal's and the GPUI window's own files, planted.
      const nativeDir = ctNativeStateDir();
      fs.mkdirSync(nativeDir, { recursive: true });
      const tuiFile = path.join(nativeDir, "tui-layout.json");
      const gpuiFile = path.join(nativeDir, "gpui-layout.json");
      fs.writeFileSync(tuiFile, "{\"planted\": \"terminal\"}\n");
      fs.writeFileSync(gpuiFile, "{\"planted\": \"gpui\"}\n");

      await ctPage.waitForSelector(".view-line", { timeout: 90_000 });
      // THE RESTART RESTORED THE DESKTOP'S OWN LAST LAYOUT.
      const restored = await stackContents(ctPage);
      expect(hasContent(restored, ClosedContent)).toBe(false);

      // View > Reset Layout — the menu element exists, and its action runs.
      const menuHasIt = await ctPage.evaluate(() => {
        // eslint-disable-next-line @typescript-eslint/no-explicit-any
        const data = (window as any).data;
        // eslint-disable-next-line @typescript-eslint/no-explicit-any
        const walk = (node: any): boolean => {
          if (!node) return false;
          if (node.name === "Reset Layout") return true;
          for (const c of node.elements ?? []) if (walk(c)) return true;
          return false;
        };
        return walk(data.ui.menuNode);
      });
      expect(menuHasIt).toBe(true);
      await ctPage.evaluate(() => {
        // eslint-disable-next-line @typescript-eslint/no-explicit-any
        const data = (window as any).data;
        // `aResetLayout` is the last `ClientAction`, so the last handler.
        data.actions[data.actions.length - 1](null);
      });
      // THE SHARED DEFAULT IS BACK, in place — the same window, no restart…
      await expect.poll(async () => hasContent(await stackContents(ctPage), ClosedContent),
        { timeout: 30_000 }).toBe(true);
      // …WITH THE EDITOR, re-created where the first run creates it…
      await ctPage.waitForSelector(".view-line", { timeout: 30_000 });
      const reset = await stackContents(ctPage);
      expect(reset.some((s) => s.includes(EditorContent))).toBe(true);
      const shipped = debugDefaultStacks(
        fileStacks(shippedLayoutFile(prefix())));
      expect(withoutEditor(reset)).toEqual(shipped);
      // …THE DESKTOP'S SAVED FILE IS THE DEFAULT AGAIN (deleted, re-copied by
      // the first run's own loader, then re-saved from the live layout)…
      await expect.poll(() => fs.existsSync(userLayoutPath()) ? fileStacks(userLayoutPath()) : null,
        { timeout: 30_000 }).toEqual(shipped);
      // …AND THE OTHER PRODUCTS' FILES WERE NOT TOUCHED.
      expect(fs.readFileSync(tuiFile, "utf8")).toBe("{\"planted\": \"terminal\"}\n");
      expect(fs.readFileSync(gpuiFile, "utf8")).toBe("{\"planted\": \"gpui\"}\n");
    });
  });
});
