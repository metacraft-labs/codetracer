/**
 * Shared helpers for column-aware Playwright tests.
 *
 * The Column-Aware Replay Navigation campaign
 * (codetracer-specs/Planned-Features/Column-Aware-Navigation.status.org)
 * exercises three GUI surfaces against many recorder backends:
 *
 *   - M1: programmatic column breakpoints via
 *     `data.services.debugger.addColumnBreakpoint(path, line, col)`.
 *   - M6: Monaco Alt+click on a column inside the editor text.
 *   - Continue + landing column assertions.
 *
 * Every per-recorder GUI spec (Solidity/EVM, Solana, Cairo, PolkaVM,
 * Move, Cadence/Flow, …) needs the same column-aware probe.  Factor
 * the wire-level details out here so each per-language spec only
 * has to know the column it is targeting and the expected landing
 * column.  This keeps the per-recorder additions short (a few lines)
 * and prevents drift between the GUI specs as the M1/M6 surface
 * evolves.
 *
 * All helpers are defensive: they never throw past the test boundary
 * for setup-only errors (e.g. missing Monaco) — they throw with a
 * specific message that surfaces in the Playwright failure log so a
 * regression is easy to attribute.
 */

import type { Page } from "@playwright/test";

import { test, expect, readyOnEntryTest as readyOnEntry } from "./fixtures";
import { LayoutPage } from "../page-objects/layout-page";
import { EditorPane } from "../page-objects/panes/editor/editor-pane";

/**
 * A snapshot of the breakpoint registered at `(path, line)` in the
 * frontend's `data.services.debugger.breakpointTable`.  Mirrors the
 * shape the M1/M6 specs already inline.
 */
export interface BreakpointSnapshot {
  line: number;
  column: number;
  enabled: boolean;
  path: string;
}

/**
 * Read the breakpoint at `(path, line)` from the frontend's
 * `breakpointTable`.  Returns `null` when no breakpoint exists at
 * that key.  Tolerates `/private/var/...` ↔ `/var/...` path
 * aliasing the way the existing column specs do — macOS tmp paths
 * round-trip through the OS as the `/private/var/...` form even
 * when the frontend stored the un-prefixed alias.
 */
export async function readBreakpoint(
  editor: EditorPane,
  line: number,
): Promise<BreakpointSnapshot | null> {
  return editor.page.evaluate(
    ({ path: p, line: l }) => {
      const w = window as any; // eslint-disable-line @typescript-eslint/no-explicit-any
      const table = w?.data?.services?.debugger?.breakpointTable;
      if (!table) return null;
      const aliases = [p];
      if (p.startsWith("/private/var/")) {
        aliases.push(p.slice("/private".length));
      } else if (p.startsWith("/var/")) {
        aliases.push("/private" + p);
      }
      for (const alias of aliases) {
        const bp = table[alias]?.[l];
        if (bp) {
          return {
            line: bp.line,
            column: bp.column ?? 0,
            enabled: !!bp.enabled,
            path: alias,
          };
        }
      }
      return null;
    },
    { path: editor.filePath, line },
  );
}

/**
 * Register a column-aware breakpoint by calling the frontend's
 * M1 `addColumnBreakpoint(path, line, column)` service directly.
 *
 * Recorder-agnostic: each recorder lands `DbStep.column` values on
 * different scales (1-indexed byte offsets for most source-based
 * recorders, instruction columns for some VM/bytecode recorders),
 * but the M1 wire path is identical — the breakpoint propagates
 * to the replay-server's `(line, column)` matcher unchanged.
 */
export async function addColumnBreakpoint(
  editor: EditorPane,
  line: number,
  column: number,
): Promise<void> {
  await editor.page.evaluate(
    ({ path: p, line: l, column: c }) => {
      const w = window as any; // eslint-disable-line @typescript-eslint/no-explicit-any
      const fn = w?.data?.services?.debugger?.addColumnBreakpoint;
      if (typeof fn !== "function") {
        throw new Error(
          "data.services.debugger.addColumnBreakpoint is not a function; " +
            "the M1 frontend wiring is missing",
        );
      }
      fn.call(w.data.services.debugger, p, l, c);
    },
    { path: editor.filePath, line, column },
  );
}

/**
 * Current execution location, as exposed by the frontend's
 * `data.services.debugger.location`.  Returns `null` when the
 * frontend has not received a `stopped` event yet.
 */
export async function getCurrentLine(editor: EditorPane): Promise<number | null> {
  return editor.page.evaluate(() => {
    const w = window as any; // eslint-disable-line @typescript-eslint/no-explicit-any
    const loc = w?.data?.services?.debugger?.location;
    if (!loc || typeof loc.line !== "number") return null;
    return loc.line;
  });
}

export async function getCurrentColumn(editor: EditorPane): Promise<number | null> {
  return editor.page.evaluate(() => {
    const w = window as any; // eslint-disable-line @typescript-eslint/no-explicit-any
    const loc = w?.data?.services?.debugger?.location;
    if (!loc || typeof loc.column !== "number") return null;
    return loc.column;
  });
}

/**
 * Resolve viewport coordinates for Monaco's view of `(line, column)`
 * inside the given editor pane.  Used by Alt+click affordances.
 *
 * Wraps Monaco's `editor.getOffsetForColumn(line, column)` plus the
 * glyph half-width so the click lands inside the column N glyph
 * box rather than at its left edge (sub-pixel rounding ambiguity
 * documented in the M6 GUI spec).
 *
 * Throws when:
 *   - The pane has no Monaco editor yet (the trace has not loaded).
 *   - The requested line is not rendered (e.g. scrolled off-screen
 *     in a huge file).
 */
export async function resolveColumnClickTarget(
  editor: EditorPane,
  line: number,
  column: number,
): Promise<{ x: number; y: number }> {
  const target = await editor.root.evaluate(
    (paneRoot: Element, { line, column }) => {
      const editorEl = paneRoot.querySelector(".monaco-editor");
      if (!editorEl) return null;
      const w = window as any; // eslint-disable-line @typescript-eslint/no-explicit-any
      const data = w?.data;
      const monacoEditor =
        data?.ui?.editors?.[data?.services?.editor?.active]?.monacoEditor;
      if (!monacoEditor) return null;
      const gutter = editorEl.querySelector(
        `.margin-view-overlays .gutter[data-line='${line}']`,
      );
      const viewLinesEl = editorEl.querySelector(".view-lines");
      if (!gutter || !viewLinesEl) return null;
      const gRect = gutter.getBoundingClientRect();
      const vRect = viewLinesEl.getBoundingClientRect();
      if (gRect.height === 0 || vRect.width === 0) return null;
      const offsetX = monacoEditor.getOffsetForColumn(line, column);
      const nextOffsetX = monacoEditor.getOffsetForColumn(line, column + 1);
      // Glyph advance from Monaco itself; fall back to 6 px when the
      // model has no following column (e.g. line end).
      const glyphWidth = nextOffsetX > offsetX ? nextOffsetX - offsetX : 6;
      const halfGlyph = glyphWidth / 2;
      return {
        x: vRect.left + offsetX + halfGlyph,
        y: gRect.top + gRect.height / 2,
      };
    },
    { line, column },
  );
  if (!target) {
    throw new Error(
      `resolveColumnClickTarget: could not resolve viewport coords for (line=${line}, column=${column}); ` +
        "Monaco editor or target line not ready.",
    );
  }
  return target;
}

/**
 * Dispatch an Alt+mousedown directly on the element at `(x, y)`,
 * mirroring the M6 GUI spec's workaround.  See
 * `column_breakpoint_gutter.spec.ts` for the rationale: Playwright's
 * CDP-synthesised pointer events under Xvfb drop the `altKey`
 * modifier before Monaco's `MouseHandler` sees them, so we
 * synthesise a real `MouseEvent` with `altKey: true` and let
 * Monaco's own `MouseTargetFactory` resolve the click coordinates
 * to a `(line, column)` IMouseTarget.
 */
export async function altMouseDownAt(page: Page, x: number, y: number): Promise<void> {
  const dispatched = await page.evaluate(
    ({ x, y }) => {
      const el = document.elementFromPoint(x, y);
      if (!el) return false;
      const dispatchOn = (target: Element, type: string): void => {
        const evt = new MouseEvent(type, {
          bubbles: true,
          cancelable: true,
          view: window,
          button: 0,
          buttons: type === "mousedown" ? 1 : 0,
          clientX: x,
          clientY: y,
          screenX: x,
          screenY: y,
          altKey: true,
          ctrlKey: false,
          shiftKey: false,
          metaKey: false,
        });
        target.dispatchEvent(evt);
      };
      dispatchOn(el, "mousedown");
      dispatchOn(el, "mouseup");
      return true;
    },
    { x, y },
  );
  if (!dispatched) {
    throw new Error(
      `altMouseDownAt: no element under viewport coordinate (${x}, ${y})`,
    );
  }
}

/**
 * Convenience: Alt+click the Monaco rendering of `(line, column)`
 * inside the given editor pane.  Mirrors what an end-user does in
 * the M6 affordance.
 */
export async function altClickAtColumn(
  editor: EditorPane,
  line: number,
  column: number,
): Promise<void> {
  const target = await resolveColumnClickTarget(editor, line, column);
  await altMouseDownAt(editor.page, target.x, target.y);
}

/**
 * Probe the column-anchored Monaco decorations on a line, used by
 * the M6 marker assertions.  Returns the list of marker decoration
 * ranges + hover text the frontend has applied to the line.
 */
export async function getColumnMarkerDecorations(
  editor: EditorPane,
  line: number,
): Promise<{ startColumn: number; endColumn: number; hoverText: string | null }[]> {
  return editor.page.evaluate(
    ({ line }) => {
      const w = window as any; // eslint-disable-line @typescript-eslint/no-explicit-any
      const data = w?.data;
      const editorComp = data?.ui?.editors?.[data?.services?.editor?.active];
      const monacoEditor = editorComp?.monacoEditor;
      if (!monacoEditor) return [];
      const model = monacoEditor.getModel?.();
      if (!model) return [];
      const decos = model.getLineDecorations
        ? model.getLineDecorations(line)
        : [];
      const out: {
        startColumn: number;
        endColumn: number;
        hoverText: string | null;
      }[] = [];
      for (const d of decos) {
        const cls = d?.options?.inlineClassName;
        if (cls !== "ct-column-breakpoint-marker") continue;
        const hover = d?.options?.hoverMessage;
        let hoverText: string | null = null;
        if (hover) {
          if (typeof hover === "string") hoverText = hover;
          else if (typeof hover?.value === "string") hoverText = hover.value;
        }
        out.push({
          startColumn: d?.range?.startColumn ?? 0,
          endColumn: d?.range?.endColumn ?? 0,
          hoverText,
        });
      }
      return out;
    },
    { line },
  );
}

/**
 * Recorder-specific configuration for the column-aware breakpoint
 * test suite emitted by `defineRecorderColumnBreakpointSuite`.
 */
export interface RecorderColumnSuiteConfig {
  /** Display name used in `test.describe` (e.g. `"cairo_example"`). */
  language: string;
  /** Skip message when the recorder pipeline is unavailable. */
  skipReason: string;
  /** `true` when the recorder pipeline is ready (recorder binary +
   *  toolchain + test program).  Skips the suite when `false`. */
  pipelineAvailable: boolean;
  /** Absolute or repo-relative path passed to `test.use({ sourcePath })`. */
  sourcePath: string;
  /** Basename of the source file as it appears in the editor tab. */
  sourceFileName: string;
  /** Line number to target with column-aware ops.  Should be inside a
   *  function body that runs before the trace's first stop. */
  targetLine: number;
  /** Column number to target on `targetLine`.  Mid-line columns (not 1)
   *  are recommended — Monaco's pixel→column resolver is unreliable
   *  at the leading edge under Xvfb. */
  targetColumn: number;
}

/**
 * Emit the canonical 2-test column-aware breakpoint suite for a
 * recorder backend.  Mirrors the JS-fixture M1/M6 specs
 * (`column_breakpoint.spec.ts`, `column_breakpoint_gutter.spec.ts`)
 * but parameterised so each per-recorder spec file
 * (`cairo_example.spec.ts`, `move_example.spec.ts`, …) reduces to a
 * single call.
 *
 * The suite is gated by `cfg.pipelineAvailable`: when the recorder
 * pipeline is absent, both tests skip with `cfg.skipReason`.  When
 * present, the suite exercises:
 *
 *   1. Alt+click on the (line, column) registers a column-aware
 *      breakpoint via the M6 affordance, and the M6 marker
 *      decoration anchors to the bound column.
 *   2. The M1 programmatic `addColumnBreakpoint` followed by
 *      Continue halts at the targeted line (column is
 *      recorder-specific — we only assert it is a real recorded
 *      value > 0 since each recorder's column convention is
 *      distinct).
 */
export function defineRecorderColumnBreakpointSuite(
  cfg: RecorderColumnSuiteConfig,
): void {
  test.describe(`${cfg.language} — column-aware breakpoint`, () => {
    test.skip(!cfg.pipelineAvailable, cfg.skipReason);

    test.setTimeout(120_000);
    test.use({ sourcePath: cfg.sourcePath, launchMode: "trace" });

    const findEditor = async (
      ctPage: Page,
    ): Promise<EditorPane | undefined> => {
      const layout = new LayoutPage(ctPage);
      await layout.runToEntryButton().click();
      await expect(ctPage.locator(".location-path")).not.toHaveText(":0#0", {
        timeout: 30_000,
      });
      const editors = await layout.editorTabs(true);
      return editors.find((e) => e.fileName === cfg.sourceFileName);
    };

    test("alt_click_sets_column_breakpoint_and_marker", async ({ ctPage }) => {
      await readyOnEntry(ctPage);
      const editor = await findEditor(ctPage);
      expect(
        editor,
        `${cfg.sourceFileName} editor tab should be open`,
      ).toBeDefined();
      if (!editor) return;

      // Drive the M6 Alt+click affordance.  Monaco's pixel→column
      // resolver maps the click to `targetColumn`.
      await altClickAtColumn(editor, cfg.targetLine, cfg.targetColumn);

      // The frontend MUST register a column-aware breakpoint with
      // `bp.column == cfg.targetColumn` — the M1 wire-contract each
      // recorder is expected to satisfy on the replay-engine side.
      await expect
        .poll(
          async () =>
            (await readBreakpoint(editor, cfg.targetLine))?.column ?? -1,
        )
        .toBe(cfg.targetColumn);
      const bp = await readBreakpoint(editor, cfg.targetLine);
      expect(
        bp,
        "column-aware breakpoint should be registered",
      ).not.toBeNull();
      expect(bp!.enabled).toBe(true);

      // The M6 column marker decoration MUST anchor at the bound
      // column — proves the "visible at column" deliverable.
      const decorations = await getColumnMarkerDecorations(
        editor,
        cfg.targetLine,
      );
      const found = decorations.find(
        (d) => d.startColumn === cfg.targetColumn,
      );
      expect(
        found,
        `column marker at startColumn=${cfg.targetColumn} should exist`,
      ).toBeDefined();
    });

    test("programmatic_column_breakpoint_continues_to_target", async ({
      ctPage,
    }) => {
      await readyOnEntry(ctPage);
      const editor = await findEditor(ctPage);
      expect(
        editor,
        `${cfg.sourceFileName} editor tab should be open`,
      ).toBeDefined();
      if (!editor) return;

      // M1 programmatic surface: bypass Alt+click entirely.  After
      // Continue the cursor MUST land on `targetLine`.  We don't pin
      // the exact landed column because each recorder's column
      // convention (byte offset, Sierra-derived, instruction column,
      // …) is out of this suite's scope; only that the column is a
      // real recorded value > 0.
      await addColumnBreakpoint(editor, cfg.targetLine, cfg.targetColumn);
      const bp = await readBreakpoint(editor, cfg.targetLine);
      expect(bp?.column).toBe(cfg.targetColumn);

      const layout = new LayoutPage(ctPage);
      await layout.continueButton().click();
      await expect
        .poll(async () => await getCurrentLine(editor))
        .toBe(cfg.targetLine);
      const landedCol = await getCurrentColumn(editor);
      expect(landedCol).not.toBeNull();
      expect(landedCol ?? 0).toBeGreaterThan(0);
    });
  });
}
