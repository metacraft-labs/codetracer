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
 *      Native layout files planted under `$XDG_STATE_HOME/codetracer/` are the
 *      terminal's and the GPUI window's; View > Reset Layout is invoked, the
 *      same window shows the shared default (VCS back, the editor
 *      re-created), the desktop's
 *      saved file holds the Debug-mode default's stacks again — and the two
 *      native files are byte-identical.
 *
 * The prefix (`PLAT45_DESKTOP_PREFIX`) must carry THIS checkout's desktop
 * JavaScript — the reset action is new — and its generated default; the
 * recipe that builds one is `scripts/plat45-desktop-prefix.sh`.
 *
 * No mocks: a real recording, the real `ct`, a real `replay-server`, the real
 * Electron app, real files.
 */

import * as fs from "fs";
import * as os from "os";
import * as path from "path";

import { expect, test } from "../../lib/fixtures";

const repoRoot = path.resolve(__dirname, "..", "..", "..", "..", "..");
// The pane the case rearranges away: VCS (`Content.VCS`). PLAT-45 closed
// CONSTRAINTS; since PLAT-47 the first run's Debug-mode default does not place
// CONSTRAINTS at all, so the case closes a pane that default does place.
const ClosedContent = 41;
const FilesystemContent = 9;
const TestResultsContent = 48;
const ConstraintsContent = 49;

// THE RECORDING IS MADE BY THE RUN ITSELF: `launchMode: "trace"` records
// `test-programs/calc/main.py` with the `ct` under test before the app opens,
// as every DB-based spec does. It used to read the terminal suites' cached
// `test-logs/tui-fixtures/calc-*` and threw at LOAD when that cache was cold —
// which is every CI job, since none of them runs the terminal lanes first.
const calcProgram = "calc/main.py";

function prefix(): string {
  // With no prepared prefix the spec runs against the BUILD itself — in CI's
  // GUI job the build is this checkout, carrying its own desktop JavaScript and
  // generated default. A worktree whose `src/build-debug` is another
  // checkout's needs `scripts/plat45-desktop-prefix.sh` and this variable.
  const value = process.env.PLAT45_DESKTOP_PREFIX ?? "";
  if (value.length > 0) return value;
  const build = process.env.CODETRACER_BUILD_DIR && process.env.CODETRACER_BUILD_DIR.length > 0
    ? process.env.CODETRACER_BUILD_DIR
    : path.join(repoRoot, "src", "build-debug");
  // A job that runs a PACKAGED `ct` (CODETRACER_E2E_CT_PATH, the nix build)
  // has no tup build directory; its `config/` is this checkout's `src/config/`
  // copied into the package, so that is the shipped default to compare with.
  if (!fs.existsSync(path.join(build, "config", "default_layout.json"))) {
    return path.join(repoRoot, "src");
  }
  return build;
}

function userLayoutPath(): string {
  const configHome = process.env.XDG_CONFIG_HOME ?? path.join(os.homedir(), ".config");
  return path.join(configHome, "codetracer", "default_layout.json");
}

// The native products' state root for this run — the terminal's and the GPUI
// window's own files live here, never under the desktop's config directory.
const nativeState = fs.mkdtempSync(path.join(os.tmpdir(), "plat45-native-state-"));
process.env.XDG_STATE_HOME = nativeState;

// eslint-disable-next-line @typescript-eslint/no-explicit-any
async function stackContents(page: any): Promise<number[][]> {
  return page.evaluate(() => {
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    const gl = (window as any).data?.ui?.layout;
    const out: number[][] = [];
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    const walk = (item: any) => {
      if (!item) return;
      if (item.type === "stack") {
        // eslint-disable-next-line @typescript-eslint/no-explicit-any
        out.push(item.contentItems.map((c: any) => {
          const cfg = c.toConfig ? c.toConfig() : {};
          const st = cfg.componentState ?? {};
          return typeof st.content === "number" ? st.content : -1;
        }));
        return;
      }
      for (const c of item.contentItems ?? []) walk(c);
    };
    walk(gl?.rootItem);
    return out;
  });
}

function hasContent(stacks: number[][], content: number): boolean {
  return stacks.some((s) => s.includes(content));
}

// The editor's stack is not in `default_layout.json` at all: the desktop
// inserts it at the root row's index 1 at runtime (`utils.nim`). Comparing a
// live arrangement with a config therefore drops it.
const EditorContent = 2;

function withoutEditor(stacks: number[][]): number[][] {
  return stacks.filter((s) => !(s.length === 1 && s[0] === EditorContent));
}

/**
 * The stacks of a GoldenLayout config document, in document order, each as
 * the `Content` ordinals of its tabs — the same shape `stackContents` reads
 * off the live layout. Works on the bundled default and on the file the
 * desktop saves (which is the same schema, re-serialised on one line).
 */
// eslint-disable-next-line @typescript-eslint/no-explicit-any
function configStacks(doc: any): number[][] {
  const out: number[][] = [];
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const walk = (item: any) => {
    if (!item || typeof item !== "object") return;
    if (item.type === "stack") {
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
      out.push((item.content ?? []).map((c: any) => {
        const st = c.componentState ?? {};
        return typeof st.content === "number" ? st.content : -1;
      }));
      return;
    }
    if (item.root) walk(item.root);
    for (const c of item.content ?? []) walk(c);
  };
  walk(doc);
  return out;
}

function fileStacks(file: string): number[][] {
  return configStacks(JSON.parse(fs.readFileSync(file, "utf8")));
}

// THE DEBUG MODE'S DEFAULT, from the bundled file, by the rule the product
// states (`frontend.paneHomesForMode` / `modeDefaultOmittedContentIds`) —
// written out here, not imported: TESTS joins the FILES stack as its last tab,
// CONSTRAINTS is not placed, and a stack left empty is gone. The first run and
// View > Reset Layout both install this (PLAT-47): it is the arrangement every
// CodeTracer front-end opens with.
function debugDefaultStacks(bundled: number[][]): number[][] {
  const out = bundled
    .map((s) => s.filter((c) => c !== TestResultsContent && c !== ConstraintsContent))
    .filter((s) => s.length > 0);
  const files = out.find((s) => s.includes(FilesystemContent));
  if (files) files.push(TestResultsContent);
  return out;
}

test.describe.serial("PLAT-45: the desktop remembers its own layout, and resets to the shared default", () => {
  test.describe("first run, then a rearrangement", () => {
    test.use({
      sourcePath: calcProgram,
      launchMode: "trace",
      noUserLayout: true,
      codetracerPrefixOverride: process.env.PLAT45_DESKTOP_PREFIX ?? "",
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
        fileStacks(path.join(prefix(), "config", "default_layout.json")));
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
      sourcePath: calcProgram,
      launchMode: "trace",
      preserveUserLayout: true,
      codetracerPrefixOverride: process.env.PLAT45_DESKTOP_PREFIX ?? "",
    });
    test.setTimeout(300_000);

    test("the restart restores it; Reset Layout returns the shared default and deletes only the desktop's files", async ({ ctPage }) => {
      prefix();
      // The terminal's and the GPUI window's own files, planted.
      const nativeDir = path.join(nativeState, "codetracer");
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
        fileStacks(path.join(prefix(), "config", "default_layout.json")));
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
