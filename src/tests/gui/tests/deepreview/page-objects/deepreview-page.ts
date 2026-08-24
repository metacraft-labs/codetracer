/**
 * Page object for a DeepReview session, activated with ``ct review <path>``.
 *
 * DeepReview has NO panel of its own. It is a combination of features of
 * three surfaces that exist independently of it
 * (``codetracer-specs/DeepReview/DeepReview-GUI.md`` §7):
 *
 * 1. The **VCS panel** — the changed-files list (``vcs-file-*``), the view
 *    mode toggle (``vcs-diff-toggle``), and the review's session title,
 *    stats and trace-context selector in its header (§2, §3).
 * 2. The **Editor** — a review's file opens as an ordinary editor document:
 *    a ``Content.UnifiedDiff`` Monaco tab (``unified-diff-container``) or
 *    the source file itself, depending on the toggle (§4, §5).
 * 3. The **Agent Activity panel** — the agent session that produced the
 *    review (``agent-ha-container``) (§2.1).  It carried a DeepReview roll-up
 *    (``activity-dr-*``) until AA-1 deleted it;
 *    ``reviewActivityRollUpArtefacts()`` is what asserts it stays deleted.
 *
 * Until DR-R8 there was also a standalone ``DEEP REVIEW`` GL panel with its
 * own header, file list, Monaco instance, sliders and call trace, addressed
 * through ``.deepreview-container``. It is deleted, and every accessor that
 * pointed into it is gone from this file. What its capabilities became:
 *
 * | was (panel)                       | is now                              |
 * | --------------------------------- | ----------------------------------- |
 * | ``.deepreview-file-list``         | ``fileItems()`` — the VCS panel     |
 * | ``.deepreview-session-title``     | ``vcsReviewTitle()``                |
 * | ``.deepreview-stats``             | ``vcsReviewStats()``                |
 * | ``.deepreview-trace-select``      | ``vcsTraceContextSelect()``         |
 * | ``.deepreview-mode-toggle``       | ``modeToggle()`` — the VCS panel    |
 * | ``.deepreview-unified-*``         | ``diffTabs()`` — a Monaco document  |
 * | ``.deepreview-expand-row``        | ``expandAboveLine`` / ``…BelowLine``|
 * | ``.deepreview-calltrace``         | the standard CALLTRACE panel        |
 * | its inline decorations            | the diff tab's own Monaco overlays  |
 * | its coverage                      | ``coverageBadge()`` — the VCS row   |
 *
 * The Omniscience overlay is no longer outstanding. DR-R6 recorded it as
 * blocked on a review loading its recording (M42b); RV-5 established that the
 * premise was wrong — a review dataset carries per-invocation flow per file,
 * and an adapter turns it into the ``FlowUpdate`` the editor already consumes
 * (DeepReview-GUI.md §7, "The overlay is driven by the dataset, not by a live
 * recording"). Tests 26-28 in ``deepreview-gui.spec.ts`` assert it on the diff
 * tab: the standard ``line-flow-hit`` / ``line-flow-skip`` classes, and the
 * in-editor invocation selector (``.review-invocation-selector``) that chooses
 * which call of a function is drawn.
 *
 * Still outstanding: in review mode the index process never loads a recording
 * (M42b), so the replay-backed panels — CALLTRACE, STATE, EVENT LOG — are
 * present but empty. Nothing in this file depends on them.
 */

import type { Locator, Page } from "@playwright/test";

/**
 * The code editor a unified diff tab actually renders into.
 *
 * Since UD-1 the tab holds a Monaco **diff editor**, which is two code
 * editors: `original-in-monaco-diff-editor` for the old revision and
 * `modified-in-monaco-diff-editor` for the new one.  In the unified (inline)
 * layout the modified editor is the scroll a reader reads — the old
 * revision's lines are drawn inside it as `view-lines line-delete` view zones
 * — and every overlay this file locates (the value chips, the revealed-line
 * decorations, the invocation selector) is attached to it.
 *
 * Scoping to it is what keeps these accessors returning ONE element each.
 * The diff tab's chrome — the file header, the `@@` divider, the expansion
 * controls — is present in BOTH models, byte-identical, so that Monaco reads
 * it as unchanged and draws it once; an unscoped `.monaco-editor .view-line`
 * therefore matches each of those lines twice and every accessor built on it
 * fails Playwright's strict mode.
 */
export const DIFF_BODY = ".monaco-editor.modified-in-monaco-diff-editor";

/** The old revision's editor — where a removed line's decorations live. */
export const DIFF_ORIGINAL = ".monaco-editor.original-in-monaco-diff-editor";

/**
 * The modified editor's OWN line container, excluding its view zones.
 *
 * `DIFF_BODY .view-lines` is not enough: in the unified layout the deleted
 * lines are drawn as `view-lines line-delete` view zones *inside* the modified
 * editor, and they come first in document order — so a `.first()` on the
 * looser selector picks a deleted-line zone rather than the document.  The
 * real container is a direct child of `.lines-content`; the zones are under
 * `.lines-content > .view-zones`.
 */
export const DIFF_BODY_LINES = `${DIFF_BODY} .lines-content > .view-lines`;


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
// Main page object
// ---------------------------------------------------------------------------

/**
 * Page object for a DeepReview session across the three panels that host it.
 */
export class DeepReviewPage {
  readonly page: Page;

  constructor(page: Page) {
    this.page = page;
  }

  // -- Surrounding GoldenLayout --------------------------------------------

  /**
   * Titles of every GoldenLayout tab currently attached.
   *
   * A review is data loaded into the layout the user already has, not a
   * replacement for it (issue #610), and it installs no surface of its own —
   * so "DEEP REVIEW" must never appear among these.
   *
   * WHICH titles are expected depends on the layout the launch opened, and
   * since RV-2 that is no longer "all of them". A dataset review
   * (`ct review <PATH>`) opens the EDITOR layout, which deliberately omits
   * the panels a dataset cannot populate — "CALLTRACE", "EVENT LOG",
   * "TIMELINE", "TERMINAL OUTPUT", "STATE" and "SCRATCHPAD" are *required to
   * be absent* there (DeepReview-GUI.md §1.1), and asserting their presence
   * is asserting the defect RV-2 fixed. What every review must show is the
   * three pillars: "FILES"/"VCS" and "AGENT ACTIVITY". Launch methods 2 and 3
   * have a recording and keep the debugging layout, where the replay panels
   * do belong.
   *
   * Titles come from ``convertTabTitle`` (``src/frontend/ui/layout.nim``),
   * which upper-cases and splits the ``Content`` enum name, with "FILES" and
   * "VCS" special-cased.
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
    return this.diffTabs().locator(`${DIFF_BODY} .view-line`);
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
      .locator(`${DIFF_BODY} .view-line`)
      .filter({ hasText: /Expand\s+\d+\s+lines\s+above/ });
  }

  /** The "Expand N lines below" control line of ``tab``. */
  static expandBelowLine(tab: Locator): Locator {
    return tab
      .locator(`${DIFF_BODY} .view-line`)
      .filter({ hasText: /Expand\s+\d+\s+lines\s+below/ });
  }

  /**
   * The whole-line decorations marking lines that context expansion revealed
   * (``DiffRevealedClass``).  Monaco renders them into ``.view-overlays``.
   */
  static revealedDecorations(tab: Locator): Locator {
    return tab.locator(`${DIFF_BODY} .view-overlays .ct-diff-line-revealed`);
  }

  /**
   * The gutter labels of one side of ``tab``'s diff editor, normalised.
   *
   * Asserting the revealed *line numbers* rather than only the revealed line
   * count is what distinguishes "expansion revealed the right lines" from
   * "expansion revealed some lines" — the off-by-one this milestone's clamping
   * tests exist for would pass the second and fail the first.
   *
   * DR-R4 had one model and therefore one gutter, so it padded the old and
   * the new number into a single label and this returned pairs like `"1 1"`.
   * UD-1 has two editors side by side, and each carries its own revision's
   * number in its own margin — the way VS Code's inline diff draws it — so
   * the pair is now read as two columns.  A line present in both revisions
   * appears in both; an addition only in the new column, a removal only in
   * the old one.
   */
  static async diffLineNumbersOn(
    tab: Locator,
    side: string,
  ): Promise<string[]> {
    const raw = await tab
      .locator(`${side} .margin-view-overlays .line-numbers`)
      .allTextContents();
    // Monaco preserves the label's padding with U+00A0, which no `\s` class
    // matches, so it is normalised to an ordinary space first.
    return raw.map((t) => t.replace(/\u00a0/g, " ").trim().replace(/\s+/g, " "));
  }

  /** The new revision's gutter column. */
  static diffNewLineNumbers(tab: Locator): Promise<string[]> {
    return DeepReviewPage.diffLineNumbersOn(tab, DIFF_BODY);
  }

  /** The old revision's column, where a deleted line keeps its number. */
  static diffOldLineNumbers(tab: Locator): Promise<string[]> {
    return DeepReviewPage.diffLineNumbersOn(tab, DIFF_ORIGINAL);
  }

  // -- The Omniscience overlay in the diff tab (RV-5) ----------------------
  //
  // DeepReview-GUI.md §4.4 requires the standard Omniscience appearance, and
  // §7 requires it as "Monaco decorations with the flow annotation classes".
  // The values are therefore *injected text* decorations rendered inside the
  // line's own DOM, carrying the debugger's own chip classes plus the two
  // `review-flow-value-*` markers that locate them here.

  /** Every inline value chip — name chips and value boxes alike. */
  static flowValueChips(tab: Locator): Locator {
    return tab.locator(`${DIFF_BODY_LINES} .review-flow-value`);
  }

  /** The name half of each inline value chip, e.g. ``<x>``. */
  static flowValueNames(tab: Locator): Locator {
    return tab.locator(`${DIFF_BODY_LINES} .review-flow-value-name`);
  }

  /** The value half of each inline value chip, e.g. ``10``. */
  static flowValueBoxes(tab: Locator): Locator {
    return tab.locator(`${DIFF_BODY_LINES} .review-flow-value-box`);
  }

  /**
   * Every chip of ``tab`` as one string, in document order.
   *
   * Chips are read as text rather than counted because a count cannot tell the
   * right invocation's values from the wrong one's — the axis the deleted
   * Tests 17/18 asserted on and the reason they are worth restoring.
   *
   * Two normalisations, both forced by how Monaco renders injected text:
   * spaces inside a rendered span arrive as U+00A0, and a long span is split
   * across several rendering chunks — so a single chip can yield more than one
   * element and its text must be rejoined without a separator inside a chip.
   * Chips are therefore separated by a single space here, and callers assert on
   * short values.
   */
  static async flowValueText(tab: Locator): Promise<string> {
    const chips = await DeepReviewPage.flowValueChips(tab).allTextContents();
    return chips.map((t) => t.replace(/[\s\u00a0]+/g, " ")).join(" ");
  }

  /** The in-editor invocation selectors of ``tab`` (§7). */
  static invocationSelectors(tab: Locator): Locator {
    return tab.locator(".review-invocation-selector");
  }

  /** The in-editor loop iteration controls of ``tab`` (§4.4). */
  static loopSelectors(tab: Locator): Locator {
    return tab.locator(".review-loop-selector");
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
   * populated only in DeepReview mode".
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

  // -- Agent Activity panel: the review's third pillar ---------------------

  /**
   * The AGENT ACTIVITY panel — DeepReview's third pillar.
   *
   * DeepReview-GUI.md §2.1: "The primary thing the panel shows in a review is
   * **the agent session that produced it**... There is no 'DeepReview
   * section' in this panel."
   */
  agentActivityPanel(): Locator {
    return this.page.locator(".agent-ha-container");
  }

  /**
   * Everything the deleted DeepReview roll-up used to draw, as one locator.
   *
   * AA-1 removed the roll-up — its coverage summary, test-results row,
   * per-file coverage table and notification feed — so this must always be
   * empty.  It is a page-object member rather than an inline selector because
   * two suites assert the deletion (`agent-activity-deepreview.spec.ts` and
   * `deepreview-gui.spec.ts`) and a deletion guard that lists its selectors
   * twice is a deletion guard that will be updated once.
   *
   * `agent-ha-deepreview-host` is included deliberately: it was the wrapper
   * the panel emitted for the roll-up *unconditionally*, even with no review
   * and no ViewModel, so it is the artefact a check for `.activity-dr-*`
   * alone would miss.
   */
  reviewActivityRollUpArtefacts(): Locator {
    return this.page.locator(
      [
        ".agent-ha-deepreview-host",
        ".activity-dr-container",
        ".activity-dr-header",
        ".activity-dr-summary",
        ".activity-dr-card",
        ".activity-dr-files",
        ".activity-dr-files-row",
        ".activity-dr-tests",
        ".activity-dr-test-item",
        ".activity-dr-notifs",
        ".activity-dr-notif-item",
      ].join(", "),
    );
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
      has: this.page.locator(`${DIFF_BODY} .view-line`, {
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

  // -- File list (the VCS panel's Changed Files section) --------------------

  /**
   * The changed-files list.
   *
   * DeepReview-GUI.md §2: "Modified files list | The **VCS panel**'s Changed
   * Files section (§3)".  It is rendered by ``src/frontend/ui/vcs.nim`` with
   * the ``vcs-file-*`` classes in review mode exactly as in normal git mode.
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

  // -- View mode toggle (the VCS panel) ------------------------------------
  //
  // VCS-Panel.md, "View mode toggle", and DeepReview-GUI.md §2: "Mode
  // switcher | The VCS panel's **view mode toggle**".  It is ONE switch, not
  // a pair of buttons: active means a file click opens a unified-diff tab,
  // inactive means it opens the file itself.  The standalone panel's
  // two-button `.deepreview-mode-toggle` is gone with the panel.

  /** The view-mode toggle row in the VCS panel. */
  modeToggle(): Locator {
    return this.vcsPanel().locator(".vcs-diff-toggle");
  }

  /** The toggle's clickable switch. */
  modeToggleButton(): Locator {
    return this.modeToggle().locator(".vcs-toggle-button");
  }

  /** True when the toggle is in its Unified Diff position. */
  async isUnifiedDiffMode(): Promise<boolean> {
    const classes = (await this.modeToggleButton().getAttribute("class")) ?? "";
    return classes.includes("vcs-toggle-active");
  }

  /**
   * Put the toggle in its Unified Diff position, clicking only if needed.
   *
   * Driven through the real control rather than a `window.__deepreview*`
   * test helper: those helpers lived on the deleted panel, and the toggle is
   * a user-facing switch that an E2E test should exercise as a user does.
   */
  async switchToUnifiedDiff(): Promise<void> {
    if (!(await this.isUnifiedDiffMode())) {
      await this.modeToggleButton().click();
    }
  }

  /** Put the toggle in its Open File ("Full Files") position. */
  async switchToFullFiles(): Promise<void> {
    if (await this.isUnifiedDiffMode()) {
      await this.modeToggleButton().click();
    }
  }

  // -- Editor-area source tabs ---------------------------------------------

  /**
   * The plain source tab for ``filePath``, if one is open.
   *
   * Full Files Mode (DeepReview-GUI.md §5) opens the file itself in the
   * standard editor rather than a diff document, so it is located by the
   * editor component's own container rather than by ``diffTabs()``.
   */
  sourceTabs(): Locator {
    return this.page.locator("[id^='editorComponent']");
  }

  /**
   * Lines the editor decorated as changed while a review is active
   * (DeepReview-GUI.md §5.1, "Per-file diff overlays").
   *
   * ``ui/editor.nim``'s ``deepReviewDiffStyleLines`` emits ``line-diff-added``
   * for a pure-addition hunk and ``line-diff-modified`` for a hunk that also
   * removes.  These replace the deleted panel's own
   * ``deepreview-diff-line-*`` decorations.
   */
  editorDiffAddedLines(): Locator {
    return this.page.locator(".view-overlays .line-diff-added");
  }

  /** Lines the editor decorated as modified while a review is active. */
  editorDiffModifiedLines(): Locator {
    return this.page.locator(".view-overlays .line-diff-modified");
  }

  // -- Diff-tab line decorations -------------------------------------------
  //
  // Since DR-R4 the unified diff is a Monaco document, so its "added",
  // "removed" and "context" lines are whole-line decorations on the overlay
  // layer (`viewmodels/diff_document.nim`) rather than `tdiv` elements
  // carrying `deepreview-unified-line-*`.

  /** Whole-line decorations of ``tab``'s added lines. */
  static diffTabAddedLines(tab: Locator): Locator {
    return tab.locator(".view-overlays .ct-diff-line-added");
  }

  /** Whole-line decorations of ``tab``'s removed lines. */
  static diffTabRemovedLines(tab: Locator): Locator {
    return tab.locator(".view-overlays .ct-diff-line-removed");
  }

  /** Whole-line decorations of ``tab``'s context lines. */
  static diffTabContextLines(tab: Locator): Locator {
    return tab.locator(".view-overlays .ct-diff-line-context");
  }

  /** The `@@ -N,M +N,M @@` section dividers of ``tab``, as rendered lines. */
  static diffHunkHeaderLinesIn(tab: Locator): Locator {
    // See `diffHunkHeaderLines` for why the regex avoids a literal space.
    return tab
      .locator(`${DIFF_BODY} .view-line`)
      .filter({ hasText: /@@\s-\d+,\d+\s\+\d+,\d+\s@@/ });
  }

  // -- Convenience ---------------------------------------------------------

  /**
   * Wait for the review to be on screen.
   *
   * The readiness signal is the VCS panel's Changed Files section: a review
   * populates it as step 1 of DeepReview-GUI.md §7, "Transition into a
   * Review", and it is the reviewer's primary navigation surface (§2: "The
   * VCS panel must be the **visible** tab of whichever stack hosts it when a
   * review starts").
   *
   * It replaces the deleted panel's ``.deepreview-container``, which was the
   * old signal.  Note that this waits for the SECTION, not for rows: an empty
   * review legitimately has none, and the empty-data tests assert exactly
   * that.
   */
  async waitForReady(timeoutMs = 15000): Promise<void> {
    await this.page.waitForSelector(".vcs-container .vcs-changed-files", {
      timeout: timeoutMs,
    });
  }
}
