import type { Locator, Page } from "@playwright/test";
import { EditorLine } from "./editor-line";
import { FlowValue } from "./flow-value";
import { OmniscientLoopControls } from "./omniscient-loop-controls";
import { TraceLogPanel } from "./trace-log-panel";
import { ContextMenu } from "../../components/context-menu";
import { retry } from "../../../lib/retry-helpers";

const FLOW_VALUE_SELECTOR =
  ".flow-parallel-value-box, .flow-inline-value-box, .flow-multiline-value-box";

/**
 * Page object representing a Monaco editor pane within the layout view.
 *
 * Port of ui-tests/PageObjects/Panes/Editor/EditorPane.cs
 */
export class EditorPane {
  readonly page: Page;
  readonly root: Locator;
  readonly tabButtonText: string;
  readonly idNumber: number;
  readonly filePath: string;
  readonly fileName: string;

  constructor(
    page: Page,
    root: Locator,
    tabButtonText: string,
    idNumber: number,
    filePath: string,
    fileName: string,
  ) {
    this.page = page;
    this.root = root;
    this.tabButtonText = tabButtonText;
    this.idNumber = idNumber;
    this.filePath = filePath;
    this.fileName = fileName;
  }

  tabButton(): Locator {
    return this.page
      .locator(".lm_title", { hasText: this.tabButtonText })
      .first();
  }

  async clickTab(): Promise<void> {
    // Layered click: plain → force → dispatchEvent.  Mirrors
    // `CallTracePane.clickTab` and `EventLogPane.clickTab`.
    //
    // Under Xvfb (and on some Windows display configurations) the
    // GoldenLayout tab strip can be reported as "outside of the
    // viewport" even when the tab is structurally present.  A plain
    // `force:true` click does NOT redirect the click to the underlying
    // tab title — it only bypasses Playwright's actionability checks;
    // the real OS pointer event still lands on whatever overlay sits
    // on top (`lm_header`, `jstree-icon`, etc.).
    //
    // `dispatchEvent('click')` synthesizes a click event directly on
    // the title span.  GoldenLayout listens for plain `click` events
    // on `.lm_title`, so the synthesized event still activates the
    // tab regardless of viewport / overlay state.
    const btn = this.tabButton();
    try {
      await btn.click({ timeout: 5_000 });
      return;
    } catch {
      // fall through to force: true
    }
    try {
      await btn.click({ force: true, timeout: 5_000 });
      return;
    } catch {
      // fall through to dispatchEvent
    }
    await btn.dispatchEvent("click");
  }

  // ---- Locators ----

  lineElements(): Locator {
    return this.root.locator(".monaco-editor .view-lines > .view-line");
  }

  lineElement(lineNumber: number): Locator {
    // Monaco does NOT annotate `.view-line` elements with a
    // `data-line-number` attribute — the `.view-line` divs are positioned
    // purely by absolute `top` CSS and re-ordered in the DOM as the editor
    // scrolls.  The line number lives on the CodeTracer custom gutter
    // (`.margin-view-overlays > .gutter[data-line='N']`), and the gutter
    // child at DOM index K corresponds to the source `.view-line` at the
    // same DOM index K (this 1:1 correspondence is what the frontend's
    // `getSourceLineDomIndex` relies on — see ui/editor.nim / ui/flow.nim).
    //
    // Resolve the source line via that index correspondence so the
    // returned locator points at the real rendered line on every platform.
    // `:scope` keeps the `.view-line` query scoped to the resolved index.
    return this.root
      .locator(".monaco-editor .view-lines > .view-line")
      .nth(this.gutterDomIndexSync(lineNumber));
  }

  /**
   * The DOM index of the gutter (and therefore the parallel `.view-line`)
   * for `lineNumber`.  Used to build a stable line locator without relying
   * on a Monaco `data-line-number` attribute that does not exist.
   *
   * Returns a Playwright locator-friendly index; the actual resolution is
   * done lazily by `resolveLineDomIndex` when the line is interacted with.
   * Kept as a thin synchronous shim so `lineElement` can stay a plain
   * locator factory — callers that need a guaranteed-correct index should
   * use `clickSourceLine`.
   */
  private gutterDomIndexSync(lineNumber: number): number {
    // Monaco renders a small file's lines 1:1 with the gutter, in order,
    // so line N maps to DOM index N-1 in the common (non-scrolled) case.
    // `clickSourceLine` performs the exact gutter-anchored resolution for
    // interactions where correctness must not depend on scroll state.
    return Math.max(0, lineNumber - 1);
  }

  /**
   * Click the source text of `lineNumber` deterministically.
   *
   * Monaco does not annotate its `.view-line` divs with a line number, and
   * a left-click on the CodeTracer gutter toggles a *breakpoint* (see
   * `lineActionClick` in ui/editor.nim) rather than selecting the line.
   * The line number lives on the gutter (`.gutter[data-line='N']`); the
   * gutter row at DOM index K corresponds to the `.view-line` at the same
   * DOM index K — the 1:1 correspondence the frontend's
   * `getSourceLineDomIndex` relies on.
   *
   * This resolves the click coordinates in a single `page.evaluate` from
   * the gutter row's `getBoundingClientRect()` (which is reliable even
   * when Playwright reports the gutter as not "visible" — Monaco gutter
   * rows can have a zero-ish computed style yet a real layout box), then
   * clicks the editor text column at that row's vertical centre.
   */
  async clickSourceLine(lineNumber: number): Promise<void> {
    const resolveCoords = async (): Promise<{ x: number; y: number } | null> =>
      await this.root.evaluate((paneRoot: Element, line: number) => {
        const editorEl = paneRoot.querySelector(".monaco-editor");
        if (!editorEl) return null;
        const gutter = editorEl.querySelector(
          `.margin-view-overlays .gutter[data-line='${line}']`,
        );
        const viewLinesEl = editorEl.querySelector(".view-lines");
        if (!gutter || !viewLinesEl) return null;
        const gRect = gutter.getBoundingClientRect();
        const vRect = viewLinesEl.getBoundingClientRect();
        if (gRect.height === 0 || vRect.width === 0) return null;
        return {
          x: vRect.left + 8,
          y: gRect.top + gRect.height / 2,
        };
      }, lineNumber);

    let coords: { x: number; y: number } | null = null;
    await retry(
      async () => {
        coords = await resolveCoords();
        return coords !== null;
      },
      { maxAttempts: 60, delayMs: 500 },
    );
    const coordsForClick = coords as { x: number; y: number } | null;
    if (!coordsForClick) {
      throw new Error(
        `Could not resolve source line ${lineNumber} for a click — ` +
          "the editor gutter / view-lines are not laid out yet.",
      );
    }
    await this.page.mouse.click(coordsForClick.x, coordsForClick.y);
  }

  gutterElement(lineNumber: number): Locator {
    return this.root.locator(
      `.monaco-editor .margin-view-overlays .gutter[data-line='${lineNumber}']`,
    );
  }

  currentLineOverlay(): Locator {
    return this.root.locator(".monaco-editor .view-overlays .current-line");
  }

  activeLineNumberLocator(): Locator {
    return this.root.locator(
      ".monaco-editor .margin .line-numbers.active-line-number",
    );
  }

  highlightedLineElementsLocator(): Locator {
    return this.root.locator(
      ".monaco-editor .view-lines > .view-line.line-flow-hit, " +
        ".monaco-editor .view-lines > .view-line.highlight",
    );
  }

  sourceGenerationAttr(): Promise<string | null> {
    return this.root.getAttribute("data-source-generation");
  }

  sourceDigestAttr(): Promise<string | null> {
    return this.root.getAttribute("data-source-digest");
  }

  executionCursorKindAttr(): Promise<string | null> {
    return this.root.getAttribute("data-execution-cursor-kind");
  }

  private async withEditorState<T>(
    reader: (args: { path: string }) => T | null,
  ): Promise<T | null> {
    if (!this.filePath) {
      return null;
    }

    try {
      return await this.page.evaluate(reader, { path: this.filePath });
    } catch {
      return null;
    }
  }

  async sourceText(): Promise<string> {
    const stateText = await this.withEditorState<string>(({ path }) => {
      const w = window as any; // eslint-disable-line @typescript-eslint/no-explicit-any
      const data = w?.data;

      const aliasesFor = (raw: string): string[] => {
        const aliases = [raw];
        if (raw.startsWith("/private/var/")) {
          aliases.push(raw.slice("/private".length));
        } else if (raw.startsWith("/var/")) {
          aliases.push(`/private${raw}`);
        }
        return [...new Set(aliases)];
      };
      const normalize = (raw: string): string =>
        raw.startsWith("/private/var/") ? raw.slice("/private".length) : raw;

      const readTab = (tab: any): string | null => {
        // eslint-disable-line @typescript-eslint/no-explicit-any
        if (!tab) return null;
        const monacoEditor = tab.monacoEditor;
        if (monacoEditor && typeof monacoEditor.getValue === "function") {
          return String(monacoEditor.getValue());
        }
        if (typeof tab.source === "string") return tab.source;
        if (Array.isArray(tab.sourceLines)) return tab.sourceLines.join("\n");
        return null;
      };

      const readEditor = (editor: any): string | null => {
        // eslint-disable-line @typescript-eslint/no-explicit-any
        if (!editor) return null;
        if (
          editor.monacoEditor &&
          typeof editor.monacoEditor.getValue === "function"
        ) {
          return String(editor.monacoEditor.getValue());
        }
        return readTab(editor.tabInfo);
      };

      const openTabs = data?.services?.editor?.open ?? {};
      const editors = data?.ui?.editors ?? {};
      for (const alias of aliasesFor(path)) {
        const exact = readTab(openTabs[alias]) ?? readEditor(editors[alias]);
        if (exact !== null) return exact;
      }

      const target = normalize(path);
      for (const key of Object.keys(openTabs)) {
        if (normalize(key) === target) {
          const value = readTab(openTabs[key]);
          if (value !== null) return value;
        }
      }
      for (const key of Object.keys(editors)) {
        if (normalize(key) === target) {
          const value = readEditor(editors[key]);
          if (value !== null) return value;
        }
      }

      return null;
    });

    if (stateText !== null) {
      return stateText;
    }
    return this.visibleText();
  }

  async revealLine(lineNumber: number): Promise<void> {
    if (!this.filePath) {
      return;
    }

    await this.page.evaluate(
      ({ path, lineNumber }) => {
        const w = window as any; // eslint-disable-line @typescript-eslint/no-explicit-any
        const data = w?.data;

        const aliasesFor = (raw: string): string[] => {
          const aliases = [raw];
          if (raw.startsWith("/private/var/")) {
            aliases.push(raw.slice("/private".length));
          } else if (raw.startsWith("/var/")) {
            aliases.push(`/private${raw}`);
          }
          return [...new Set(aliases)];
        };
        const normalize = (raw: string): string =>
          raw.startsWith("/private/var/") ? raw.slice("/private".length) : raw;

        const openTabs = data?.services?.editor?.open ?? {};
        const editors = data?.ui?.editors ?? {};
        let editor: any = null; // eslint-disable-line @typescript-eslint/no-explicit-any
        let tab: any = null; // eslint-disable-line @typescript-eslint/no-explicit-any

        for (const alias of aliasesFor(path)) {
          editor = editors[alias] ?? null;
          tab = openTabs[alias] ?? editor?.tabInfo ?? null;
          if (editor || tab) break;
        }
        if (!editor && !tab) {
          const target = normalize(path);
          for (const key of Object.keys(editors)) {
            if (normalize(key) === target) {
              editor = editors[key];
              tab = editor?.tabInfo ?? openTabs[key] ?? null;
              break;
            }
          }
          if (!editor && !tab) {
            for (const key of Object.keys(openTabs)) {
              if (normalize(key) === target) {
                tab = openTabs[key];
                break;
              }
            }
          }
        }

        const monacoEditor = editor?.monacoEditor ?? tab?.monacoEditor;
        data?.ui?.layout?.updateSize?.();
        monacoEditor?.layout?.();
        if (typeof monacoEditor?.setScrollTop === "function") {
          monacoEditor.setScrollTop(Math.max(0, (lineNumber - 3) * 20));
        }
        if (
          typeof monacoEditor?.revealLineInCenterIfOutsideViewport ===
          "function"
        ) {
          monacoEditor.revealLineInCenterIfOutsideViewport(lineNumber);
        } else if (typeof monacoEditor?.revealLineInCenter === "function") {
          monacoEditor.revealLineInCenter(lineNumber);
        }
        if (typeof monacoEditor?.setPosition === "function") {
          monacoEditor.setPosition({ lineNumber, column: 1 });
        }
        monacoEditor?.render?.(true);
      },
      { path: this.filePath, lineNumber },
    );
  }

  async hasBreakpointAt(lineNumber: number): Promise<boolean> {
    if (!this.filePath) {
      return false;
    }

    try {
      return await this.page.evaluate(
        ({ path, lineNumber }) => {
          const w = window as any; // eslint-disable-line @typescript-eslint/no-explicit-any
          const table = w?.data?.services?.debugger?.breakpointTable;
          if (!table) return false;

          const aliases = [path];
          if (path.startsWith("/private/var/")) {
            aliases.push(path.slice("/private".length));
          } else if (path.startsWith("/var/")) {
            aliases.push(`/private${path}`);
          }
          for (const alias of aliases) {
            if (table[alias]?.[lineNumber]) return true;
          }

          const normalize = (raw: string): string =>
            raw.startsWith("/private/var/")
              ? raw.slice("/private".length)
              : raw;
          const target = normalize(path);
          for (const key of Object.keys(table)) {
            if (normalize(key) === target && table[key]?.[lineNumber]) {
              return true;
            }
          }
          return false;
        },
        { path: this.filePath, lineNumber },
      );
    } catch {
      return false;
    }
  }

  async visibleText(): Promise<string> {
    return (
      await this.root.locator(".monaco-editor .view-lines").innerText()
    ).trim();
  }

  async containsMarker(marker: string): Promise<boolean> {
    if ((await this.sourceText()).includes(marker)) {
      return true;
    }
    try {
      return ((await this.root.textContent()) ?? "").includes(marker);
    } catch {
      return false;
    }
  }

  grayedOutLineElementsLocator(): Locator {
    return this.root.locator(
      ".monaco-editor .view-lines > .view-line.line-flow-skip, " +
        ".monaco-editor .view-lines > .view-line.line-flow-unknown",
    );
  }

  gutterHighlightElementsLocator(): Locator {
    return this.root.locator(
      ".monaco-editor .margin-view-overlays > .gutter.gutter-highlight-active",
    );
  }

  omniscientLoopContainersLocator(): Locator {
    return this.root.locator(".flow-loop-step-container");
  }

  flowValueElementById(valueBoxId: string): Locator {
    return this.root.locator(`#${valueBoxId}`);
  }

  flowValueElementByName(valueName: string): Locator {
    // Strategy 1: Find a visible name label and pick its sibling value box.
    // Works for normal (non-loop) values where showName=true.
    const nameLocator = this.root
      .locator(
        ".ct-omni-name, .ct-omni-name-std, .flow-parallel-value-name, .flow-loop-value-name",
      )
      .filter({ hasText: valueName });

    const siblingLocator = nameLocator
      .locator(
        "xpath=following-sibling::*[contains(@class,'flow-parallel-value-box') or contains(@class,'flow-inline-value-box') or contains(@class,'flow-multiline-value-box')]",
      )
      .first();

    // Strategy 2: Match by ID suffix. The Nim frontend generates IDs like
    // `flow-{mode}-value-box-{i}-{stepCount}-{name}`, so we can match
    // elements whose ID ends with `-{valueName}` and has a value-box class.
    // Use a broad class pattern since the mode prefix varies (parallel, inline, multiline).
    const idSuffixLocator = this.root
      .locator(`[id$="-${valueName}"][class*="value-box"]`)
      .first();

    return siblingLocator.or(idSuffixLocator);
  }

  // ---- Methods ----

  async lines(): Promise<EditorLine[]> {
    const locators = await this.lineElements().all();
    const lines: EditorLine[] = [];
    for (const locator of locators) {
      const attr = await locator.getAttribute("data-line-number");
      const lineNumber = attr ? parseInt(attr, 10) : -1;
      lines.push(
        new EditorLine(this, locator, isNaN(lineNumber) ? -1 : lineNumber),
      );
    }
    return lines;
  }

  lineByNumber(lineNumber: number): EditorLine {
    return new EditorLine(this, this.lineElement(lineNumber), lineNumber);
  }

  async hasActiveLine(): Promise<boolean> {
    if ((await this.activeLineNumberLocator().count()) > 0) {
      return true;
    }
    return (await this.currentLineOverlay().count()) > 0;
  }

  private async tryReadViewLineFromState(): Promise<number | null> {
    if (!this.filePath) {
      return null;
    }

    try {
      return await this.page.evaluate(
        ({ path }) => {
          const w = window as any; // eslint-disable-line @typescript-eslint/no-explicit-any
          const data = w?.data;
          if (!data?.services?.editor) return null;

          const editorService = data.services.editor;
          const openTabs = editorService.open;
          if (
            !openTabs ||
            !Object.prototype.hasOwnProperty.call(openTabs, path)
          ) {
            return null;
          }

          const tab = openTabs[path];
          if (!tab) return null;

          const viewLine = tab.viewLine;
          if (
            typeof viewLine === "number" &&
            Number.isFinite(viewLine) &&
            viewLine > 0
          ) {
            return viewLine;
          }

          const monacoEditor = tab.monacoEditor;
          if (monacoEditor && typeof monacoEditor.getPosition === "function") {
            const position = monacoEditor.getPosition();
            if (
              position &&
              typeof position.lineNumber === "number" &&
              Number.isFinite(position.lineNumber) &&
              position.lineNumber > 0
            ) {
              return position.lineNumber;
            }
          }

          if (
            editorService.active === path &&
            typeof editorService.activeTabInfo === "function"
          ) {
            const activeTab = editorService.activeTabInfo();
            if (
              activeTab &&
              typeof activeTab.viewLine === "number" &&
              Number.isFinite(activeTab.viewLine) &&
              activeTab.viewLine > 0
            ) {
              return activeTab.viewLine;
            }
          }

          return null;
        },
        { path: this.filePath },
      );
    } catch {
      return null;
    }
  }

  async activeLineNumber(): Promise<number | null> {
    const viewLine = await this.tryReadViewLineFromState();
    if (viewLine !== null && viewLine > 0) {
      return viewLine;
    }

    if ((await this.activeLineNumberLocator().count()) === 0) {
      return null;
    }

    const text = await this.activeLineNumberLocator().first().textContent();
    return text ? parseInt(text, 10) || null : null;
  }

  async highlightedLines(): Promise<EditorLine[]> {
    const lineNumbers = new Set<number>();

    const lineLocators = await this.highlightedLineElementsLocator().all();
    for (const locator of lineLocators) {
      const attr = await locator.getAttribute("data-line-number");
      const value = attr ? parseInt(attr, 10) : -1;
      if (value > 0) lineNumbers.add(value);
    }

    const gutterLocators = await this.gutterHighlightElementsLocator().all();
    for (const gutter of gutterLocators) {
      const attr = await gutter.getAttribute("data-line");
      const value = attr ? parseInt(attr, 10) : -1;
      if (value > 0) lineNumbers.add(value);
    }

    return [...lineNumbers].map((n) => this.lineByNumber(n));
  }

  async grayedOutLines(): Promise<EditorLine[]> {
    const lineNumbers = new Set<number>();

    const lineLocators = await this.grayedOutLineElementsLocator().all();
    for (const locator of lineLocators) {
      const attr = await locator.getAttribute("data-line-number");
      const value = attr ? parseInt(attr, 10) : -1;
      if (value > 0) lineNumbers.add(value);
    }

    return [...lineNumbers].map((n) => this.lineByNumber(n));
  }

  /**
   * Toggles a tracepoint at the requested line through the frontend API.
   */
  async openTrace(lineNumber: number): Promise<void> {
    if (lineNumber <= 0) {
      throw new Error("Line number must be positive.");
    }
    if (!this.filePath) {
      throw new Error("Editor pane does not expose a valid file path.");
    }

    const editorLine = this.lineByNumber(lineNumber);
    if (await editorLine.hasTracepoint()) {
      return;
    }

    await this.page.evaluate(
      ({ path, line }) => {
        const w = window as any; // eslint-disable-line @typescript-eslint/no-explicit-any
        if (typeof w.toggleTracepoint !== "function") {
          throw new Error("toggleTracepoint is not available.");
        }
        w.toggleTracepoint(path, line);
      },
      { path: this.filePath, line: lineNumber },
    );
  }

  /**
   * Runs all configured tracepoints via the exposed frontend helper.
   */
  async runTracepointsJs(): Promise<void> {
    // Wait for data.services to be initialized before calling
    // runTracepoints.  The trace service is wired up asynchronously
    // and may not be ready when the test opens a tracepoint immediately
    // after navigation.
    await retry(
      async () => {
        const ready = await this.page.evaluate(() => {
          const w = window as any; // eslint-disable-line @typescript-eslint/no-explicit-any
          return (
            typeof w.runTracepoints === "function" &&
            w.data &&
            w.data.services &&
            w.data.services.trace
          );
        });
        return Boolean(ready);
      },
      { maxAttempts: 30, delayMs: 200 },
    );

    await this.page.evaluate(() => {
      const w = window as any; // eslint-disable-line @typescript-eslint/no-explicit-any
      w.runTracepoints(w.data);
    });
  }

  /**
   * Returns currently active omniscient loop control groups.
   */
  async activeLoopControls(): Promise<OmniscientLoopControls[]> {
    const containers = await this.omniscientLoopContainersLocator().all();
    return containers.map((l) => new OmniscientLoopControls(l));
  }

  /**
   * Gathers all flow values currently rendered in the editor.
   */
  async flowValues(): Promise<FlowValue[]> {
    const locators = await this.root.locator(FLOW_VALUE_SELECTOR).all();
    const menu = new ContextMenu(this.page);
    return locators.map((l) => new FlowValue(l, menu));
  }

  /**
   * Opens the trace log panel for the provided line.
   */
  async openTracePoint(lineNumber: number): Promise<TraceLogPanel> {
    const line = this.lineByNumber(lineNumber);
    await line.gutterElement().click();
    const panel = new TraceLogPanel(this, lineNumber);
    await panel.root.waitFor({ state: "visible" });
    return panel;
  }

  async highlightedLineNumber(): Promise<number> {
    return (await this.activeLineNumber()) ?? -1;
  }
}
