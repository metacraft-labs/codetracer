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
/** What a tab whose component state names no `content` reads as. */
export const UnknownContent = -1;

/** How many tabs the editor's own stack holds: the editor alone. */
const EditorStackTabs = 1;
/** The tab count of a stack the mode default emptied, which it drops. */
const EmptyStackTabs = 0;

const repoRoot = path.resolve(__dirname, "..", "..", "..", "..");

/** The part of a GoldenLayout component's state these helpers read. */
interface ComponentState {
  content?: unknown;
}

/**
 * A node of a GoldenLayout config document (`default_layout.json`): the
 * document itself carries `root`, every item `type` and `content`.
 */
interface ConfigItem {
  type?: unknown;
  root?: ConfigItem;
  content?: ConfigItem[];
  componentState?: ComponentState;
}

/** A content item of the LIVE GoldenLayout tree — the fields read here. */
interface LiveItem {
  type?: string;
  contentItems?: LiveItem[];
  toConfig?: () => { componentState?: ComponentState };
}

/**
 * The renderer global the desktop keeps its GoldenLayout instance on. `document`
 * is there so `window` is assignable to it without a cast: a type whose every
 * member is optional shares nothing with `Window`, and TypeScript refuses it.
 */
interface DesktopWindow {
  document: Document;
  data?: { ui?: { layout?: { rootItem?: LiveItem } } };
}

/**
 * The stacks of the live GoldenLayout tree in `page`, in document order.
 * A tab whose component state names no `content` reads as `UnknownContent`.
 */
export async function stackContents(page: Page): Promise<number[][]> {
  // The callback runs in the renderer, so it cannot close over module
  // constants; the sentinel goes in as the argument.
  return await page.evaluate((unknown: number): number[][] => {
    const desktop: DesktopWindow = window;
    const root = desktop.data?.ui?.layout?.rootItem;
    const out: number[][] = [];
    const tabContent = (tab: LiveItem): number => {
      const content = tab.toConfig?.().componentState?.content;
      return typeof content === "number" ? content : unknown;
    };
    const walk = (item: LiveItem | undefined): void => {
      if (item === undefined) return;
      if (item.type === "stack") {
        out.push((item.contentItems ?? []).map(tabContent));
        return;
      }
      for (const child of item.contentItems ?? []) walk(child);
    };
    walk(root);
    return out;
  }, UnknownContent);
}

/** Whether any stack holds a tab of `content`. */
export function hasContent(stacks: number[][], content: number): boolean {
  return stacks.some((s) => s.includes(content));
}

/** The first stack holding a tab of `content`, or `undefined`. */
export function stackHolding(stacks: number[][], content: number): number[] | undefined {
  return stacks.find((s) => s.includes(content));
}

/**
 * `stacks` without the editor's own stack. The editor is not in
 * `default_layout.json` at all: the desktop inserts it at the root row's
 * index 1 at runtime (`utils.nim`), so comparing a live arrangement with a
 * config drops it.
 */
export function withoutEditor(stacks: number[][]): number[][] {
  return stacks.filter((s) => !(s.length === EditorStackTabs && s.includes(EditorContent)));
}

/**
 * The stacks of a GoldenLayout config document, in document order — the same
 * shape `stackContents` reads off the live layout. Works on the bundled
 * default and on the file the desktop saves (the same schema, re-serialised
 * on one line). `doc` is parsed JSON, so nothing about its shape is trusted:
 * a node that is not an object is skipped.
 */
export function configStacks(doc: unknown): number[][] {
  const out: number[][] = [];
  const tabContent = (tab: ConfigItem): number => {
    const content = tab.componentState?.content;
    return typeof content === "number" ? content : UnknownContent;
  };
  const walk = (node: unknown): void => {
    if (typeof node !== "object" || node === null) return;
    const item = node as ConfigItem;
    if (item.type === "stack") {
      out.push((item.content ?? []).map(tabContent));
      return;
    }
    walk(item.root);
    for (const child of item.content ?? []) walk(child);
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
    .filter((s) => s.length !== EmptyStackTabs);
  const files = out.find((s) => s.includes(FilesystemContent));
  if (files !== undefined) files.push(TestResultsContent);
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
  const configured = process.env.CODETRACER_BUILD_DIR ?? "";
  const build = configured === ""
    ? path.join(repoRoot, "src", "build-debug")
    : configured;
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
  return prepared === "" ? buildPrefix() : prepared;
}

/** The shipped `config/default_layout.json` of `prefix`. */
export function shippedLayoutFile(prefix: string): string {
  return path.join(prefix, "config", "default_layout.json");
}
