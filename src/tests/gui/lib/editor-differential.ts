/**
 * The editor differential: one scenario, sent as user input to the desktop's
 * editor pane, observed from the screen — once with Monaco and once with the
 * shared editor (the `sharedEditor` developer setting) — and the two lists of
 * observations compared.
 *
 * SHAPED FOR THE SCENARIO FORMAT. A scenario here is DATA — steps that send
 * input (`click`, `press`, `type`, `glyph`) and `observe` points — the way a
 * DemoVideoScript scenario is (DemoVideoScript-Format.md §4: actions and
 * assertions over a page object's roles). The step runner and the observation
 * reader below are the editor role's Playwright binding; porting to the
 * CodeTracer page-object pack is moving `EDITOR_STEPS` into a scenario file
 * and these two functions behind the pack's `editor` role, with no change to
 * what is sent or read.
 *
 * Each step kind is one scenario-format step (DemoVideoScript-Format §4,
 * the CodeTracer pack's roles):
 *
 *   { kind: "click", line, column, count }  ->
 *       click: { at: 'editor/line[number="<line>"]', anchor: text-start,
 *                column: <column>, count: <count> }
 *   { kind: "glyph", line }                 ->
 *       click: { at: 'editor/line[number="<line>"]/glyph' }
 *   { kind: "press", keys }                 -> key: { keys: <keys> }
 *   { kind: "type", text }                  -> type: { text: <text> }
 *   { kind: "settle", ms }                  -> wait: { for: <ms>ms }
 *   { kind: "observe", label }              -> expect: { at: editor,
 *       assert: "matches-recorded(<label>)" }, the observation this file
 *       reads being the editor role's properties (lines, the execution line,
 *       glyphs, the caret, the selection, the value chips).
 *
 * WHAT IS OBSERVED is what the user sees, read from the DOM both editors
 * build (Monaco's structure, which the shared editor keeps): the drawn lines'
 * text (non-breaking spaces read as spaces — Monaco draws spaces as U+00A0),
 * the execution pointer in the gutter, the glyph column's marks, the active
 * line number, the selected text and the caret (through the editor API both
 * answer, `getSelections` / `getPosition`), and the value chips the flow
 * draws.
 */
import type { Page } from "@playwright/test";

export type ScenarioStep =
  | { kind: "observe"; label: string }
  | { kind: "click"; line: number; column: number; count?: number; modifiers?: string[] }
  | { kind: "press"; keys: string }
  | { kind: "type"; text: string }
  | { kind: "glyph"; line: number }
  | { kind: "settle"; ms: number };

export interface EditorObservation {
  label: string;
  /** The drawn lines, top to bottom, as `<number>: <text>`. */
  lines: string[];
  /** The line the gutter's execution arrow is on, 0 for none. */
  executionLine: number;
  /** Glyph marks per line, `<line>: <classes>`. */
  glyphs: string[];
  /** The active line number in the gutter. */
  activeLine: number;
  caret: { line: number; column: number };
  selections: string[];
  /** The value chips the flow draws, in document order. */
  values: string[];
}

/** Wait until the active editor is drawn and has a model. */
export async function editorReady(page: Page): Promise<void> {
  await page.waitForSelector(".monaco-editor .view-line", { timeout: 120_000 });
  await page.waitForFunction(() => {
    const d = (globalThis as any).data;
    return !!d?.ui?.editors?.[d?.services?.editor?.active]?.monacoEditor?.getModel?.();
  }, undefined, { timeout: 60_000 });
}

/** Whether the active editor is the shared editor. */
export async function activeEditorIsShared(page: Page): Promise<boolean> {
  return page.evaluate(() => {
    const d = (globalThis as any).data;
    const e = d?.ui?.editors?.[d?.services?.editor?.active]?.monacoEditor;
    return !!e?.getDomNode?.()?.hasAttribute?.("data-ct-shared-editor");
  });
}

async function pointOf(page: Page, line: number, column: number) {
  return page.evaluate(({ line, column }) => {
    const d = (globalThis as any).data;
    const e = d.ui.editors[d.services.editor.active].monacoEditor;
    e.revealLineInCenterIfOutsideViewport(line);
    const box = e.getDomNode().getBoundingClientRect();
    const v = e.getScrolledVisiblePosition({ lineNumber: line, column });
    return { x: box.left + v.left + 2, y: box.top + v.top + v.height / 2 };
  }, { line, column });
}

async function glyphPoint(page: Page, line: number) {
  return page.evaluate((line) => {
    const d = (globalThis as any).data;
    const e = d.ui.editors[d.services.editor.active].monacoEditor;
    e.revealLineInCenterIfOutsideViewport(line);
    const box = e.getDomNode().getBoundingClientRect();
    const l = e.getLayoutInfo();
    const lh = e.getOption((globalThis as any).monaco.editor.EditorOption.lineHeight);
    return {
      x: box.left + l.glyphMarginLeft + l.glyphMarginWidth / 2,
      y: box.top + e.getTopForLineNumber(line) - e.getScrollTop() + lh / 2,
    };
  }, line);
}

/** Read what the editor shows now. */
export async function observeEditor(page: Page, label: string): Promise<EditorObservation> {
  const seen = await page.evaluate(() => {
    const d = (globalThis as any).data;
    const e = d.ui.editors[d.services.editor.active].monacoEditor;
    const root: Element = e.getDomNode();
    const text = (el: Element | null) =>
      (el?.textContent ?? "").replace(/ /g, " ").replace(/\s+$/, "");
    const rowsOf = (sel: string) =>
      Array.from(root.querySelectorAll(sel)).map((el) => ({
        el, top: parseFloat((el as HTMLElement).style.top || "0"),
      })).sort((a, b) => a.top - b.top);
    // A line's number is the gutter row at the same top.
    const numberAt = new Map<number, number>();
    for (const row of rowsOf(".margin-view-overlays > div")) {
      const n = parseInt(text(row.el.querySelector(".line-numbers")).replace(/[^0-9]/g, ""), 10);
      if (!Number.isNaN(n)) numberAt.set(Math.round(row.top), n);
    }
    const lines: string[] = [];
    const values: string[] = [];
    for (const row of rowsOf(".view-lines > .view-line")) {
      const n = numberAt.get(Math.round(row.top)) ?? 0;
      lines.push(`${n}: ${text(row.el)}`);
    }
    for (const chip of Array.from(root.querySelectorAll(
      ".flow-value, .flow-chip, [class*='flow-parallel-value'], [class*='flow-inline-value']"))) {
      const t = text(chip);
      if (t.length > 0) values.push(t);
    }
    // The glyph column's marks are decorations, and Monaco draws them in a
    // layer of its own (`.glyph-margin-widgets`) rather than in the margin's
    // rows; read them as `lib/glyph-column.ts` does, from the model, for the
    // drawn lines.
    const glyphs: string[] = [];
    for (const n of Array.from(new Set(numberAt.values())).sort((a, b) => a - b)) {
      const classes = (e.getModel().getLineDecorations(n) ?? [])
        .map((d: any) => d.options?.glyphMarginClassName as string | undefined)
        .filter((c: string | undefined) => !!c && c.includes("gutter-glyph"))
        .flatMap((c: string) => c.trim().split(/\s+/))
        .filter((c: string) => c.startsWith("gutter-glyph"));
      if (classes.length > 0) glyphs.push(`${n}: ${classes.sort().join(" ")}`);
    }
    const active = root.querySelector(".gutter-highlight-active")?.closest("[data-line]");
    const executionLine = active
      ? parseInt(active.getAttribute("data-line") ?? "0", 10) || 0 : 0;
    const activeNumber = text(root.querySelector(".line-numbers.active-line-number"))
      .replace(/[^0-9]/g, "");
    const pos = e.getPosition();
    return {
      lines, values, glyphs, executionLine,
      activeLine: parseInt(activeNumber, 10) || 0,
      caret: { line: pos?.lineNumber ?? 0, column: pos?.column ?? 0 },
      selections: e.getSelections().map((s: any) => e.getModel().getValueInRange(s) as string),
    };
  });
  return { label, ...seen };
}

/** Send the scenario's input and collect its observations. */
export async function runEditorScenario(
  page: Page, steps: ScenarioStep[],
): Promise<EditorObservation[]> {
  const out: EditorObservation[] = [];
  for (const step of steps) {
    switch (step.kind) {
      case "observe":
        out.push(await observeEditor(page, step.label));
        break;
      case "click": {
        const p = await pointOf(page, step.line, step.column);
        for (const m of step.modifiers ?? []) await page.keyboard.down(m);
        await page.mouse.click(p.x, p.y, { clickCount: step.count ?? 1 });
        for (const m of (step.modifiers ?? []).reverse()) await page.keyboard.up(m);
        await page.waitForTimeout(600);
        break;
      }
      case "press":
        await page.keyboard.press(step.keys);
        await page.waitForTimeout(400);
        break;
      case "type":
        await page.keyboard.type(step.text);
        await page.waitForTimeout(400);
        break;
      case "glyph": {
        const p = await glyphPoint(page, step.line);
        await page.mouse.click(p.x, p.y);
        await page.waitForTimeout(600);
        break;
      }
      case "settle":
        await page.waitForTimeout(step.ms);
        break;
    }
  }
  return out;
}
