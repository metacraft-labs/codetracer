/**
 * Reading a desktop arrangement as STACKS — the live GoldenLayout tree of a
 * running window and a saved/bundled `default_layout.json` alike — and
 * deriving the Debug mode's default from the bundled tree.
 *
 * Every helper reduces an arrangement to the same shape: the stacks in
 * document order, each as the `Content` ordinals of its tabs
 * (`frontend.nim`'s `Content` enum). That is what lets a spec compare what a
 * window SHOWS with what a file SAYS, stack for stack, without depending on
 * sizes, ids or the one-line form the desktop re-saves a layout in.
 *
 * Shared by the specs that assert which arrangement a launch opened:
 * `tests/layout/plat45-desktop-remembers-own.spec.ts` (the desktop's first
 * run, restart and Reset Layout) and
 * `tests/layout/fixture-default-layout.spec.ts` (the launch fixture's own
 * default).
 */

import * as fs from "node:fs";
import * as path from "node:path";
import type { Page } from "@playwright/test";

/** `Content.EditorView`. */
export const EditorContent = 2;
/** `Content.Filesystem` — the FILES pane. */
export const FilesystemContent = 9;
/** `Content.TestResults` — the TESTS pane. */
export const TestResultsContent = 48;
/** `Content.Constraints` — the CONSTRAINTS pane. */
export const ConstraintsContent = 49;

const repoRoot = path.resolve(__dirname, "..", "..", "..", "..");

/**
 * The stacks of the live GoldenLayout tree in `page`, in document order.
 * A tab whose component state names no `content` reads as -1.
 */
export async function stackContents(page: Page): Promise<number[][]> {
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

/** Whether any stack holds a tab of `content`. */
export function hasContent(stacks: number[][], content: number): boolean {
  return stacks.some((s) => s.includes(content));
}

/**
 * `stacks` without the editor's own stack. The editor is not in
 * `default_layout.json` at all: the desktop inserts it at the root row's
 * index 1 at runtime (`utils.nim`), so comparing a live arrangement with a
 * config drops it.
 */
export function withoutEditor(stacks: number[][]): number[][] {
  return stacks.filter((s) => !(s.length === 1 && s[0] === EditorContent));
}

/**
 * The stacks of a GoldenLayout config document, in document order — the same
 * shape `stackContents` reads off the live layout. Works on the bundled
 * default and on the file the desktop saves (the same schema, re-serialised
 * on one line).
 */
// eslint-disable-next-line @typescript-eslint/no-explicit-any
export function configStacks(doc: any): number[][] {
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

/** `configStacks` of the JSON layout file at `file`. */
export function fileStacks(file: string): number[][] {
  return configStacks(JSON.parse(fs.readFileSync(file, "utf8")));
}

/**
 * THE DEBUG MODE'S DEFAULT, from the bundled tree's stacks, by the rule the
 * product states (`frontend.paneHomesForMode` /
 * `modeDefaultOmittedContentIds`) — written out here, not imported: TESTS
 * joins the FILES stack as its last tab, CONSTRAINTS is not placed, and a
 * stack left empty is gone. The first run and View > Reset Layout both
 * install this (`index/config.installModeDefault`,
 * `index/mode_default_layout.modeDefaultLayout`): it is the arrangement every
 * CodeTracer front-end opens a recording with.
 */
export function debugDefaultStacks(bundled: number[][]): number[][] {
  const out = bundled
    .map((s) => s.filter((c) => c !== TestResultsContent && c !== ConstraintsContent))
    .filter((s) => s.length > 0);
  const files = out.find((s) => s.includes(FilesystemContent));
  if (files) files.push(TestResultsContent);
  return out;
}

/**
 * The prefix of the BUILD the suite launches when no prepared prefix is
 * named: `CODETRACER_BUILD_DIR`, else this checkout's `src/build-debug`. A job
 * that runs a PACKAGED `ct` (`CODETRACER_E2E_CT_PATH`, the nix build) has no
 * tup build directory; its `config/` is this checkout's `src/config/` copied
 * into the package, so that is the shipped default to compare with.
 */
export function buildPrefix(): string {
  const build = process.env.CODETRACER_BUILD_DIR && process.env.CODETRACER_BUILD_DIR.length > 0
    ? process.env.CODETRACER_BUILD_DIR
    : path.join(repoRoot, "src", "build-debug");
  if (!fs.existsSync(path.join(build, "config", "default_layout.json"))) {
    return path.join(repoRoot, "src");
  }
  return build;
}

/**
 * The prefix whose `config/default_layout.json` a launch that does NOT set
 * `codetracerPrefixOverride` itself reads: `CODETRACER_TEST_PREFIX` (the
 * fixture's suite-wide default, `lib/fixtures.ts`) when set, else
 * `buildPrefix()`.
 */
export function launchedPrefix(): string {
  const prepared = process.env.CODETRACER_TEST_PREFIX ?? "";
  return prepared.length > 0 ? prepared : buildPrefix();
}

/** The shipped `config/default_layout.json` of `prefix`. */
export function shippedLayoutFile(prefix: string): string {
  return path.join(prefix, "config", "default_layout.json");
}
