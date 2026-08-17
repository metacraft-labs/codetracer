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
 * ``vcs-file-*`` CSS classes from ``src/frontend/ui/vcs.nim``. The call
 * trace likewise lives in the GL CALLTRACE panel, not inside the DeepReview
 * component — those two columns are the only things ``glEmbedded``
 * suppresses.
 *
 * NOTE: this block used to say that Full Files mode and the mode toggle
 * were "not available in GL-embedded mode". That was never a design
 * decision — it documented issue #610, in which DeepReview startup replaced
 * the whole GoldenLayout with a three-panel preset and the view hid its own
 * mode toggle behind ``glEmbedded``, which is set for every ``--deepreview``
 * session. Both are fixed: startup now ADDS the review surface to the
 * user's layout (so FILES, STATE, SCRATCHPAD, CALLTRACE, AGENT ACTIVITY,
 * EVENT LOG, TIMELINE and TERMINAL OUTPUT are all present), and the mode
 * toggle renders in every mode.
 *
 * Still outstanding, and the reason some Full Files assertions below remain
 * skipped: in ``--deepreview`` mode the index process never loads a
 * recording, so the replay-backed panels are present but empty and the
 * Monaco inline-value decorations have no data to show.
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

  /**
   * Scope a selector to the DeepReview panel itself.
   *
   * The panel's diff markup (``deepreview-unified-*``, ``deepreview-expand-*``,
   * ``deepreview-flow-values``) is shared with the VCS panel's unified diff
   * *editor tabs*, which a review now opens (DeepReview-GUI.md §3/§7). A
   * page-wide locator would therefore mix the two surfaces together; the tabs
   * have their own accessors below (``diffTabs``, ``diffTabFor``).
   */
  private inPanel(selector: string): Locator {
    return this.container().locator(selector);
  }

  // -- Surrounding GoldenLayout --------------------------------------------

  /**
   * Titles of every GoldenLayout tab currently attached.
   *
   * DeepReview is one panel inside the user's layout, not a replacement for
   * it (issue #610), so the standard panel titles must be present alongside
   * the review surface. Titles come from ``convertTabTitle``
   * (``src/frontend/ui/layout.nim``): "FILES", "VCS", "STATE",
   * "SCRATCHPAD", "CALLTRACE", "AGENT ACTIVITY", "EVENT LOG", "TIMELINE",
   * "TERMINAL OUTPUT", "DEEP REVIEW".
   */
  async layoutTabTitles(): Promise<string[]> {
    const titles = await this.page.locator(".lm_tab .lm_title").allTextContents();
    return titles.map((t) => t.trim());
  }

  /**
   * Titles of the GoldenLayout tabs that are the *active* tab of their stack,
   * i.e. the ones whose content is on screen.
   *
   * GoldenLayout marks them with ``lm_active``.
   */
  async activeTabTitles(): Promise<string[]> {
    const titles = await this.page
      .locator(".lm_tab.lm_active .lm_title")
      .allTextContents();
    return titles.map((t) => t.trim());
  }

  // -- Editor-area diff tabs -----------------------------------------------

  /**
   * The unified-diff editor tabs opened from the VCS panel's Changed Files
   * list (DeepReview-GUI.md §3/§4: "Clicking a file opens it in the editor").
   *
   * Since DR-R4 a diff tab is a Monaco document of its own
   * (``Content.UnifiedDiff``), not a second VCS panel instance —
   * VCS-Panel.md, "Unified Diff View (Editor Integration)": "Uses the standard
   * CodeTracer Monaco editor".
   */
  diffTabs(): Locator {
    return this.page.locator(".unified-diff-container");
  }

  /**
   * The rendered lines of the active diff tab's Monaco editor.
   *
   * Monaco renders the model text into ``.view-line`` elements, so this is
   * the diff text a reader actually sees.  (Named ``diffTabLines`` rather
   * than ``diffLines`` because ``DeepReviewFileItem.diffLines`` already means
   * a changed-file row's "+8-3" summary.)
   */
  diffTabLines(): Locator {
    return this.diffTabs().locator(".monaco-editor .view-line");
  }

  /** The `@@ -N,M +N,M @@` section dividers, as rendered lines. */
  diffHunkHeaderLines(): Locator {
    // `\s` rather than a literal space, and unanchored: Monaco renders runs
    // of spaces as U+00A0 to preserve their width, and matches `hasText`
    // regexes against the element's raw text rather than a normalized copy.
    return this.diffTabLines().filter({ hasText: /@@\s-\d+,\d+\s\+\d+,\d+\s@@/ });
  }

  // -- Context expansion in the diff tab (DR-R5) ---------------------------
  //
  // The controls are LINES of the Monaco model, not DOM chrome
  // (`diff_document.nim`: `dlkExpandAbove` / `dlkExpandBelow`), so they are
  // located and clicked as rendered lines like the `@@` dividers above.
  // Their `ct-diff-line-expand*` classes live on the decoration layer, which
  // is a sibling of the line, so filtering by text is what identifies them
  // here.

  /** The "Expand N lines above" control line of ``tab``. */
  static expandAboveLine(tab: Locator): Locator {
    return tab
      .locator(".monaco-editor .view-line")
      .filter({ hasText: /Expand\s+\d+\s+lines\s+above/ });
  }

  /** The "Expand N lines below" control line of ``tab``. */
  static expandBelowLine(tab: Locator): Locator {
    return tab
      .locator(".monaco-editor .view-line")
      .filter({ hasText: /Expand\s+\d+\s+lines\s+below/ });
  }

  /**
   * The whole-line decorations marking lines that context expansion revealed
   * (``DiffRevealedClass``).  Monaco renders them into ``.view-overlays``.
   */
  static revealedDecorations(tab: Locator): Locator {
    return tab.locator(".view-overlays .ct-diff-line-revealed");
  }

  /**
   * The dual old/new gutter labels of ``tab``, whitespace-normalised.
   *
   * Asserting the revealed *line numbers* rather than only the revealed line
   * count is what distinguishes "expansion revealed the right lines" from
   * "expansion revealed some lines" — the off-by-one this milestone's clamping
   * tests exist for would pass the second and fail the first.
   */
  static async diffLineNumbers(tab: Locator): Promise<string[]> {
    const raw = await tab
      .locator(".margin-view-overlays .line-numbers")
      .allTextContents();
    // Monaco preserves the label's padding with U+00A0, which no `\s` class
    // matches, so it is normalised to an ordinary space first.
    return raw.map((t) => t.replace(/ /g, " ").trim().replace(/\s+/g, " "));
  }

  // -- The docked VCS panel ------------------------------------------------

  /**
   * The docked VCS panel — the one that lists the changeset.
   */
  vcsPanel(): Locator {
    return this.page
      .locator(".vcs-container")
      .filter({ has: this.page.locator(".vcs-changed-files") });
  }

  /**
   * The trace-context selector in the VCS panel header.
   *
   * DeepReview-GUI.md §2: "Trace context selector | The VCS panel header,
   * populated only in DeepReview mode". Scoped to the VCS panel on purpose —
   * the standalone DeepReview panel renders its own copy of this control
   * until DR-R8 deletes it, and a page-wide locator would match both.
   */
  vcsTraceContextSelector(): Locator {
    return this.vcsPanel().locator(".vcs-review-trace-selector");
  }

  /** The trace-context dropdown inside the VCS panel header. */
  vcsTraceContextSelect(): Locator {
    return this.vcsPanel().locator(".vcs-review-trace-select");
  }

  /**
   * The review's session title in the VCS panel header.
   *
   * DeepReview-GUI.md §2: "Session title / stats | The VCS panel header".
   * The header reuses the branch-name element; in review mode it carries the
   * review title instead of a branch.
   */
  vcsReviewTitle(): Locator {
    return this.vcsPanel().locator(".vcs-branch-name");
  }

  /** The review stats (file count and total +/-) in the VCS panel header. */
  vcsReviewStats(): Locator {
    return this.vcsPanel().locator(".vcs-review-stats");
  }

  // -- Agent Activity panel: the review's DeepReview section ---------------

  /**
   * The AGENT ACTIVITY panel — DeepReview's third pillar.
   *
   * DeepReview-GUI.md §2.1: "The Agent Activity panel is the third pillar,
   * not an adjacent feature... The section is part of the existing Agent
   * Activity panel. It is not a separate panel and does not get its own
   * layout slot."
   */
  agentActivityPanel(): Locator {
    return this.page.locator(".agent-ha-container");
  }

  /** The DeepReview section rendered inside the AGENT ACTIVITY panel. */
  reviewActivitySection(): Locator {
    return this.agentActivityPanel().locator(".activity-dr-container");
  }

  /** The section's coverage summary card. */
  reviewActivityCoverageCard(): Locator {
    return this.reviewActivitySection().locator(".activity-dr-card-coverage");
  }

  /** The section's test-results card. */
  reviewActivityTestsCard(): Locator {
    return this.reviewActivitySection().locator(".activity-dr-card-tests");
  }

  /** One row per file in the section's per-file coverage table. */
  reviewActivityFileRows(): Locator {
    return this.reviewActivitySection().locator(".activity-dr-files-row");
  }

  /** The selected row of the per-file coverage table. */
  reviewActivitySelectedFileRow(): Locator {
    return this.reviewActivitySection().locator(
      ".activity-dr-files-row-selected",
    );
  }

  /** The section's collapse/expand header. */
  reviewActivityHeader(): Locator {
    return this.reviewActivitySection().locator(".activity-dr-header");
  }

  /**
   * The diff tab showing ``filePath``'s diff, if one is open.
   *
   * Matched on the file-header line of the Monaco document (DeepReview-GUI.md
   * §4.1, "A file header with path and diff metadata"), which since DR-R4 is
   * a line of the model rather than DOM chrome.
   */
  diffTabFor(filePath: string): Locator {
    return this.diffTabs().filter({
      has: this.page.locator(".monaco-editor .view-line", {
        hasText: filePath,
      }),
    });
  }

  /**
   * Title GoldenLayout gives a diff tab for ``filePath``.
   *
   * Mirrors the ``file:``-target branch of ``convertTabTitle``'s caller in
   * ``src/frontend/ui/layout.nim``.
   */
  static diffTabTitle(filePath: string): string {
    const slash = filePath.lastIndexOf("/");
    return `Diff: ${slash >= 0 ? filePath.slice(slash + 1) : filePath}`;
  }

  // -- Header --------------------------------------------------------------

  // The header accessors below are scoped to the standalone DeepReview panel
  // for the same reason as the diff markup above: DR-R2 moved the review's
  // trace-context selector and stats into the VCS panel header, where they
  // adopt the panel-agnostic `deepreview-stats` / `deepreview-trace-select`
  // rules rather than duplicating them. Two surfaces therefore carry those
  // classes until DR-R8 deletes this panel, and a page-wide locator would
  // match both. The VCS panel's copies have their own accessors
  // (`vcsTraceContextSelect`, `vcsReviewStats`, …).

  /** The header bar showing commit info and summary stats. */
  header(): Locator {
    return this.inPanel(".deepreview-header");
  }

  /** The commit SHA display in the header. */
  commitDisplay(): Locator {
    return this.inPanel(".deepreview-commit");
  }

  /** The stats display (file count, recording count, time). */
  statsDisplay(): Locator {
    return this.inPanel(".deepreview-stats");
  }

  // -- Session title -------------------------------------------------------

  /** The session title displayed in the header bar. */
  sessionTitle(): Locator {
    return this.inPanel(".deepreview-session-title");
  }

  // -- Trace context selector ----------------------------------------------

  /** The trace context selector container. */
  traceContextSelector(): Locator {
    return this.inPanel(".deepreview-trace-selector");
  }

  /** The trace context dropdown element. */
  traceContextSelect(): Locator {
    return this.inPanel(".deepreview-trace-select");
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
    return this.inPanel(".deepreview-unified-diff");
  }

  /** All file sections in the unified diff view. */
  unifiedFileHeaders(): Locator {
    return this.inPanel(".deepreview-unified-file-header");
  }

  /** All file path spans within unified diff file headers. */
  unifiedFilePaths(): Locator {
    return this.inPanel(".deepreview-unified-file-path");
  }

  /** All hunk header elements (the @@ lines). */
  unifiedHunkHeaders(): Locator {
    return this.inPanel(".deepreview-unified-hunk-header");
  }

  /** All added lines in the unified diff. */
  unifiedAddedLines(): Locator {
    return this.inPanel(".deepreview-unified-line-added");
  }

  /** All removed lines in the unified diff. */
  unifiedRemovedLines(): Locator {
    return this.inPanel(".deepreview-unified-line-removed");
  }

  /** All context lines in the unified diff. */
  unifiedContextLines(): Locator {
    return this.inPanel(".deepreview-unified-line-context");
  }

  /** All lines (of any type) in the unified diff. */
  unifiedAllLines(): Locator {
    return this.inPanel(".deepreview-unified-line");
  }

  // -- Context expansion ----------------------------------------------------

  /** All "Expand above/below" rows in the unified diff. */
  expandRows(): Locator {
    return this.inPanel(".deepreview-expand-row");
  }

  /** All expanded context lines (lines added via expand buttons). */
  expandedContextLines(): Locator {
    return this.inPanel(".deepreview-expanded-context");
  }

  // -- Omniscience overlay (inline values on diff lines) ---------------------

  /** All omniscience flow value containers in the unified diff. */
  omniscienceValues(): Locator {
    return this.inPanel(".deepreview-flow-values");
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
