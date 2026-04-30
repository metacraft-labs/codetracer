/**
 * Page object for the DeepReview GUI component.
 *
 * Encapsulates all selectors and common interactions for the DeepReview
 * standalone view, which is activated via the ``--deepreview <path>`` CLI
 * argument. The component renders:
 *
 * - A header bar with commit info and statistics.
 * - A file list in the VCS panel (class ``vcs-file-item``) with per-file
 *   coverage badges and diff status indicators.
 * - A unified diff view with coverage overlays and omniscience values.
 * - A call trace tree panel.
 *
 * In GL-embedded mode, the file list lives in the VCS panel rather than in
 * the DeepReview component itself. Selectors for file items use the
 * ``vcs-file-*`` CSS classes from ``src/frontend/ui/vcs.nim``.
 *
 * Full Files mode (Monaco editor, execution slider, loop slider, mode
 * toggle) is not available in GL-embedded mode. The corresponding page
 * object methods are retained for future use when VCS panel "Open File"
 * mode is implemented.
 */

import type { Locator, Page } from "@playwright/test";

// ---------------------------------------------------------------------------
// File list item (VCS panel)
// ---------------------------------------------------------------------------

/**
 * Represents a single entry in the VCS panel file list.
 *
 * In GL-embedded mode the file list is rendered by the VCS panel
 * (``src/frontend/ui/vcs.nim``) using ``vcs-file-*`` CSS classes.
 */
export class DeepReviewFileItem {
  readonly page: Page;
  readonly root: Locator;

  constructor(page: Page, root: Locator) {
    this.page = page;
    this.root = root;
  }

  /** Get the displayed file basename (from ``vcs-file-name``). */
  async name(): Promise<string> {
    return (await this.root.locator(".vcs-file-name").textContent()) ?? "";
  }

  /**
   * Get the full file path.
   *
   * The VCS panel only renders the basename, so this returns the same
   * value as ``name()``. Retained for API compatibility.
   */
  async fullPath(): Promise<string> {
    return this.name();
  }

  /**
   * Get the coverage badge text (e.g. "8/10"), or empty string if absent.
   *
   * The VCS panel renders coverage in a ``vcs-file-coverage`` span.
   */
  async coverageBadge(): Promise<string> {
    const badge = this.root.locator(".vcs-file-coverage");
    const count = await badge.count();
    if (count === 0) return "";
    return (await badge.textContent()) ?? "";
  }

  /**
   * Get the diff status indicator text (e.g. "A", "M", "D"), or empty
   * string if absent.
   *
   * The VCS panel renders the status letter in a ``vcs-file-status`` span.
   */
  async diffStatus(): Promise<string> {
    const indicator = this.root.locator(".vcs-file-status");
    const count = await indicator.count();
    if (count === 0) return "";
    return (await indicator.textContent())?.trim() ?? "";
  }

  /**
   * Get the diff lines summary text (e.g. "+8-3"), or empty string if
   * absent.
   *
   * The VCS panel renders added/removed counts in separate
   * ``vcs-stat-added`` / ``vcs-stat-deleted`` spans inside a
   * ``vcs-file-stats`` container.
   */
  async diffLines(): Promise<string> {
    const stats = this.root.locator(".vcs-file-stats");
    const count = await stats.count();
    if (count === 0) return "";
    return (await stats.textContent()) ?? "";
  }

  /**
   * Get the CSS classes on the diff status indicator element.
   *
   * The VCS panel uses ``vcs-status-added``, ``vcs-status-modified``,
   * ``vcs-status-deleted`` classes on the ``vcs-file-status`` span.
   */
  async diffStatusClasses(): Promise<string> {
    const indicator = this.root.locator(".vcs-file-status");
    const count = await indicator.count();
    if (count === 0) return "";
    return (await indicator.getAttribute("class")) ?? "";
  }

  /**
   * Whether this file item is selected.
   *
   * The VCS panel adds a ``vcs-file-selected`` class to the selected item.
   */
  async isSelected(): Promise<boolean> {
    const classes = (await this.root.getAttribute("class")) ?? "";
    return classes.includes("vcs-file-selected");
  }

  /** Click this file item to select it. */
  async click(): Promise<void> {
    await this.root.click();
  }
}

// ---------------------------------------------------------------------------
// Call trace node
// ---------------------------------------------------------------------------

/** Represents a single node in the call trace tree. */
export class DeepReviewCallTraceNode {
  readonly page: Page;
  readonly root: Locator;

  constructor(page: Page, root: Locator) {
    this.page = page;
    this.root = root;
  }

  /** Get the function name for this call trace node. */
  async name(): Promise<string> {
    return (
      (await this.root.locator(".deepreview-calltrace-name").first().textContent()) ?? ""
    );
  }

  /** Get the execution count text (e.g. " x1"). */
  async countText(): Promise<string> {
    return (
      (await this.root.locator(".deepreview-calltrace-count").first().textContent()) ?? ""
    );
  }
}

// ---------------------------------------------------------------------------
// Main page object
// ---------------------------------------------------------------------------

/**
 * Page object for the full DeepReview view.
 *
 * Provides access to all sub-components: header, file list, editor area
 * (sliders and Monaco decorations), and the call trace panel.
 */
export class DeepReviewPage {
  readonly page: Page;

  constructor(page: Page) {
    this.page = page;
  }

  // -- Container -----------------------------------------------------------

  /** The top-level DeepReview container. */
  container(): Locator {
    return this.page.locator(".deepreview-container");
  }

  /** The error message shown when no data is loaded. */
  errorMessage(): Locator {
    return this.page.locator(".deepreview-error");
  }

  // -- Header --------------------------------------------------------------

  /** The header bar showing commit info and summary stats. */
  header(): Locator {
    return this.page.locator(".deepreview-header");
  }

  /** The commit SHA display in the header. */
  commitDisplay(): Locator {
    return this.page.locator(".deepreview-commit");
  }

  /** The stats display (file count, recording count, time). */
  statsDisplay(): Locator {
    return this.page.locator(".deepreview-stats");
  }

  // -- Session title -------------------------------------------------------

  /** The session title displayed in the header bar. */
  sessionTitle(): Locator {
    return this.page.locator(".deepreview-session-title");
  }

  // -- Trace context selector ----------------------------------------------

  /** The trace context selector container. */
  traceContextSelector(): Locator {
    return this.page.locator(".deepreview-trace-selector");
  }

  /** The trace context dropdown element. */
  traceContextSelect(): Locator {
    return this.page.locator(".deepreview-trace-select");
  }

  /**
   * Set the trace context via the exposed test helper.
   * @param id The trace context id to select.
   */
  async setTraceContext(id: number): Promise<void> {
    await this.page.evaluate(
      (val) => {
        const fn = (window as any).__deepreviewSetTraceContext;
        if (typeof fn === "function") {
          fn(val);
        } else {
          throw new Error("__deepreviewSetTraceContext not found on window");
        }
      },
      id,
    );
  }

  // -- File list (VCS panel) ------------------------------------------------

  /**
   * The file list container in the VCS panel.
   *
   * In GL-embedded mode the file list is rendered by the VCS panel
   * using the ``vcs-file-list`` class.
   */
  fileList(): Locator {
    return this.page.locator(".vcs-file-list");
  }

  /** All file items in the VCS panel. */
  async fileItems(): Promise<DeepReviewFileItem[]> {
    const locators = await this.page.locator(".vcs-file-item").all();
    return locators.map((loc) => new DeepReviewFileItem(this.page, loc));
  }

  /** Get a specific file item by index (0-based). */
  fileItemByIndex(index: number): DeepReviewFileItem {
    return new DeepReviewFileItem(
      this.page,
      this.page.locator(".vcs-file-item").nth(index),
    );
  }

  // -- Editor area ---------------------------------------------------------

  /** The editor area (contains sliders and the Monaco editor div). */
  editorArea(): Locator {
    return this.page.locator(".deepreview-editor-area");
  }

  /** The Monaco editor container div. */
  editor(): Locator {
    return this.page.locator(".deepreview-editor");
  }

  // -- Execution slider ----------------------------------------------------

  /** The execution slider container. */
  executionSlider(): Locator {
    return this.page.locator(".deepreview-slider").first();
  }

  /** The execution slider <input type="range"> element. */
  executionSliderInput(): Locator {
    return this.executionSlider().locator(".deepreview-slider-input");
  }

  /** The execution slider info label (e.g. "1/3 (main)"). */
  executionSliderInfo(): Locator {
    return this.executionSlider().locator(".deepreview-slider-info");
  }

  /** The execution slider label text (e.g. "Execution:"). */
  executionSliderLabel(): Locator {
    return this.executionSlider().locator(".deepreview-slider-label");
  }

  /**
   * Set the execution slider to a specific value.
   *
   * Uses the Playwright ``fill`` approach for range inputs: we evaluate
   * a script to set the value and dispatch an ``input`` event, since
   * ``fill`` does not work for range inputs.
   */
  async setExecutionSliderValue(value: number): Promise<void> {
    // Karax's event handling for range inputs can make programmatic
    // ``dispatchEvent`` calls unreliable. Instead, call the exposed
    // test helper which directly updates the component state and
    // triggers a Karax re-render.
    await this.page.evaluate(
      (val) => {
        const fn = (window as any).__deepreviewSetExecution;
        if (typeof fn === "function") {
          fn(val);
        } else {
          throw new Error("__deepreviewSetExecution not found on window");
        }
      },
      value,
    );
  }

  // -- Loop slider ---------------------------------------------------------

  /**
   * The loop iteration slider container.
   *
   * The loop slider is the second ``.deepreview-slider`` element, but it is
   * only rendered when the selected file has loop data. If absent, the locator
   * will have count 0.
   */
  loopSlider(): Locator {
    // The loop slider is rendered after the execution slider. Both have
    // the class ``deepreview-slider``, but the loop slider has the label
    // "Iteration:". We locate it by looking for the label text.
    return this.page
      .locator(".deepreview-slider")
      .filter({ has: this.page.locator(".deepreview-slider-label", { hasText: "Iteration:" }) });
  }

  /** The loop slider <input type="range"> element. */
  loopSliderInput(): Locator {
    return this.loopSlider().locator(".deepreview-slider-input");
  }

  /** The loop slider info text (e.g. "1/6"). */
  loopSliderInfo(): Locator {
    return this.loopSlider().locator(".deepreview-slider-info");
  }

  /** Set the loop slider to a specific value. */
  async setLoopSliderValue(value: number): Promise<void> {
    // Karax's event handling for range inputs can make programmatic
    // ``dispatchEvent`` calls unreliable. Instead, call the exposed
    // test helper which directly updates the component state and
    // triggers a Karax re-render.
    await this.page.evaluate(
      (val) => {
        const fn = (window as any).__deepreviewSetIteration;
        if (typeof fn === "function") {
          fn(val);
        } else {
          throw new Error("__deepreviewSetIteration not found on window");
        }
      },
      value,
    );
  }

  // -- Coverage decorations ------------------------------------------------

  /**
   * Get all elements matching a Monaco decoration class.
   *
   * Monaco applies CSS classes to whole-line decorations via
   * ``<div class="... deepreview-line-executed ...">``. This method
   * locates elements by their decoration class name.
   *
   * Note: Monaco only renders lines that are visible in the viewport,
   * so the count may be less than the total number of decorated lines
   * if the editor needs scrolling.
   */
  decoratedLines(decorationClass: string): Locator {
    return this.page.locator(`.${decorationClass}`);
  }

  /** Lines with the ``deepreview-line-executed`` decoration. */
  executedLines(): Locator {
    return this.decoratedLines("deepreview-line-executed");
  }

  /** Lines with the ``deepreview-line-unreachable`` decoration. */
  unreachableLines(): Locator {
    return this.decoratedLines("deepreview-line-unreachable");
  }

  /** Lines with the ``deepreview-line-partial`` decoration. */
  partialLines(): Locator {
    return this.decoratedLines("deepreview-line-partial");
  }

  // -- Diff line decorations (Full Files mode) -----------------------------

  /** Lines with the ``deepreview-diff-line-added`` decoration (green border). */
  diffAddedLines(): Locator {
    return this.decoratedLines("deepreview-diff-line-added");
  }

  /** Lines with the ``deepreview-diff-line-modified`` decoration (yellow border). */
  diffModifiedLines(): Locator {
    return this.decoratedLines("deepreview-diff-line-modified");
  }

  // -- Inline value decorations --------------------------------------------

  /**
   * Get all inline variable value decorations.
   *
   * These are Monaco ``afterContent`` decorations with the class
   * ``deepreview-inline-value``. Each contains text like
   * ``"  // x = 10, y = 20"``.
   */
  inlineValues(): Locator {
    return this.page.locator(".deepreview-inline-value");
  }

  // -- Call trace panel ----------------------------------------------------

  /** The call trace panel container. */
  callTracePanel(): Locator {
    return this.page.locator(".deepreview-calltrace");
  }

  /** The "Call Trace" header text. */
  callTraceHeader(): Locator {
    return this.page.locator(".deepreview-calltrace-header");
  }

  /** The "No call trace data" message shown when call trace is absent. */
  callTraceEmpty(): Locator {
    return this.page.locator(".deepreview-calltrace-empty");
  }

  /** The call trace body (contains tree nodes). */
  callTraceBody(): Locator {
    return this.page.locator(".deepreview-calltrace-body");
  }

  /** All call trace tree nodes. */
  async callTraceNodes(): Promise<DeepReviewCallTraceNode[]> {
    const locators = await this.page.locator(".deepreview-calltrace-node").all();
    return locators.map((loc) => new DeepReviewCallTraceNode(this.page, loc));
  }

  /** All call trace entry rows (name + count, including children). */
  callTraceEntries(): Locator {
    return this.page.locator(".deepreview-calltrace-entry");
  }

  // -- View mode toggle ----------------------------------------------------

  /** The view mode toggle container. */
  modeToggle(): Locator {
    return this.page.locator(".deepreview-mode-toggle");
  }

  /** The "Full Files" mode toggle button. */
  fullFilesButton(): Locator {
    return this.page.locator(".deepreview-mode-btn", { hasText: "Full Files" });
  }

  /** The "Unified Diff" mode toggle button. */
  unifiedDiffButton(): Locator {
    return this.page.locator(".deepreview-mode-btn", { hasText: "Unified Diff" });
  }

  /**
   * Switch to Unified Diff mode via the exposed test helper.
   * Falls back to clicking the button if the helper is unavailable.
   */
  async switchToUnifiedDiff(): Promise<void> {
    await this.page.evaluate(() => {
      const fn = (window as any).__deepreviewSetViewMode;
      if (typeof fn === "function") {
        fn("unified");
      } else {
        throw new Error("__deepreviewSetViewMode not found on window");
      }
    });
  }

  /**
   * Switch to Full Files mode via the exposed test helper.
   */
  async switchToFullFiles(): Promise<void> {
    await this.page.evaluate(() => {
      const fn = (window as any).__deepreviewSetViewMode;
      if (typeof fn === "function") {
        fn("fullfiles");
      } else {
        throw new Error("__deepreviewSetViewMode not found on window");
      }
    });
  }

  // -- Unified diff view ----------------------------------------------------

  /** The unified diff scroll container. */
  unifiedDiff(): Locator {
    return this.page.locator(".deepreview-unified-diff");
  }

  /** All file sections in the unified diff view. */
  unifiedFileHeaders(): Locator {
    return this.page.locator(".deepreview-unified-file-header");
  }

  /** All file path spans within unified diff file headers. */
  unifiedFilePaths(): Locator {
    return this.page.locator(".deepreview-unified-file-path");
  }

  /** All hunk header elements (the @@ lines). */
  unifiedHunkHeaders(): Locator {
    return this.page.locator(".deepreview-unified-hunk-header");
  }

  /** All added lines in the unified diff. */
  unifiedAddedLines(): Locator {
    return this.page.locator(".deepreview-unified-line-added");
  }

  /** All removed lines in the unified diff. */
  unifiedRemovedLines(): Locator {
    return this.page.locator(".deepreview-unified-line-removed");
  }

  /** All context lines in the unified diff. */
  unifiedContextLines(): Locator {
    return this.page.locator(".deepreview-unified-line-context");
  }

  /** All lines (of any type) in the unified diff. */
  unifiedAllLines(): Locator {
    return this.page.locator(".deepreview-unified-line");
  }

  // -- Context expansion ----------------------------------------------------

  /** All "Expand above/below" rows in the unified diff. */
  expandRows(): Locator {
    return this.page.locator(".deepreview-expand-row");
  }

  /** All expanded context lines (lines added via expand buttons). */
  expandedContextLines(): Locator {
    return this.page.locator(".deepreview-expanded-context");
  }

  // -- Omniscience overlay (inline values on diff lines) ---------------------

  /** All omniscience flow value containers in the unified diff. */
  omniscienceValues(): Locator {
    return this.page.locator(".deepreview-flow-values");
  }

  /**
   * Expand context above a specific hunk via the exposed test helper.
   * @param fileIdx 0-based file index
   * @param hunkIdx 0-based hunk index within the file
   */
  async expandAbove(fileIdx: number, hunkIdx: number): Promise<void> {
    await this.page.evaluate(
      ({ fi, hi }) => {
        const fn = (window as any).__deepreviewExpandAbove;
        if (typeof fn === "function") {
          fn(fi, hi);
        } else {
          throw new Error("__deepreviewExpandAbove not found on window");
        }
      },
      { fi: fileIdx, hi: hunkIdx },
    );
  }

  /**
   * Expand context below a specific hunk via the exposed test helper.
   * @param fileIdx 0-based file index
   * @param hunkIdx 0-based hunk index within the file
   */
  async expandBelow(fileIdx: number, hunkIdx: number): Promise<void> {
    await this.page.evaluate(
      ({ fi, hi }) => {
        const fn = (window as any).__deepreviewExpandBelow;
        if (typeof fn === "function") {
          fn(fi, hi);
        } else {
          throw new Error("__deepreviewExpandBelow not found on window");
        }
      },
      { fi: fileIdx, hi: hunkIdx },
    );
  }

  // -- Convenience ---------------------------------------------------------

  /**
   * Wait for the DeepReview container to appear in the DOM.
   *
   * This is the primary readiness signal: once ``.deepreview-container``
   * exists, the component has rendered its initial state.
   */
  async waitForReady(timeoutMs = 15000): Promise<void> {
    await this.page.waitForSelector(".deepreview-container", { timeout: timeoutMs });
  }

  /**
   * Wait for the Monaco editor to initialise inside the DeepReview view.
   *
   * Monaco is lazily initialised after the DOM container renders, so
   * ``.view-lines`` (Monaco's rendered line container) may appear slightly
   * after ``.deepreview-container``.
   */
  async waitForEditorReady(timeoutMs = 20000): Promise<void> {
    await this.page.waitForSelector(".deepreview-editor .view-lines", {
      timeout: timeoutMs,
    });
  }
}
