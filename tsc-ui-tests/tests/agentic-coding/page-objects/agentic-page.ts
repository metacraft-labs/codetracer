/**
 * Page objects for the Agentic Coding Integration (M9) E2E tests.
 *
 * Encapsulates all selectors and common interactions for the three main
 * components added by M9:
 *
 * 1. **AgentWorkspacePage** -- The agent workspace view with file list,
 *    Monaco editor, and DeepReview coverage overlay.
 *    (CSS class prefix: ``agent-workspace-``)
 *
 * 2. **CaptionBarProgressPage** -- The caption bar progress indicator
 *    with milestone progress, state display, and workspace view toggling.
 *    (CSS class prefix: ``caption-progress-``)
 *
 * 3. **ActivityDeepReviewPage** -- The collapsible activity pane showing
 *    DeepReview summary cards, per-file coverage table, test results,
 *    and recent notifications.
 *    (CSS class prefix: ``activity-dr-``)
 *
 * Selector names are derived from the CSS classes emitted by the
 * corresponding Nim components in ``src/frontend/ui/``.
 */

import type { Locator, Page } from "@playwright/test";

// ---------------------------------------------------------------------------
// Agent Workspace file item
// ---------------------------------------------------------------------------

/** A single file entry in the agent workspace file list sidebar. */
export class AgentWorkspaceFileItem {
  readonly page: Page;
  readonly root: Locator;

  constructor(page: Page, root: Locator) {
    this.page = page;
    this.root = root;
  }

  /** Get the displayed file basename (e.g. "feature.rs"). */
  async name(): Promise<string> {
    return (await this.root.locator(".agent-workspace-file-name").textContent()) ?? "";
  }

  /** Get the full file path shown below the basename. */
  async fullPath(): Promise<string> {
    return (await this.root.locator(".agent-workspace-file-path").textContent()) ?? "";
  }

  /**
   * Get the coverage badge text (e.g. "15/20"), or "--" when no coverage
   * data is available for the file.
   */
  async coverageBadge(): Promise<string> {
    const badge = this.root.locator(".agent-workspace-coverage-badge");
    const count = await badge.count();
    if (count === 0) return "";
    return (await badge.textContent()) ?? "";
  }

  /** Whether the flow badge ("flow") is displayed for this file. */
  async hasFlowBadge(): Promise<boolean> {
    const flowBadge = this.root.locator(".agent-workspace-flow-badge");
    return (await flowBadge.count()) > 0;
  }

  /** Whether this file item has the ``selected`` CSS class. */
  async isSelected(): Promise<boolean> {
    const classes = (await this.root.getAttribute("class")) ?? "";
    return classes.includes("selected");
  }

  /** Click this file item to switch the editor view. */
  async click(): Promise<void> {
    await this.root.click();
  }
}

// ---------------------------------------------------------------------------
// Agent Workspace page object
// ---------------------------------------------------------------------------

/**
 * Page object for the Agent Workspace view.
 *
 * The workspace shows the agent's working directory files with DeepReview
 * coverage annotations overlaid on a Monaco editor. It is activated when the
 * user clicks the caption bar progress indicator.
 *
 * CSS selectors correspond to classes in
 * ``src/frontend/ui/agent_workspace.nim``.
 */
export class AgentWorkspacePage {
  readonly page: Page;

  constructor(page: Page) {
    this.page = page;
  }

  // -- Container -----------------------------------------------------------

  /** The top-level agent workspace container. */
  container(): Locator {
    return this.page.locator(".agent-workspace-container");
  }

  /** The empty-state message shown when no agent session is active. */
  emptyMessage(): Locator {
    return this.page.locator(".agent-workspace-empty");
  }

  // -- Header --------------------------------------------------------------

  /** The workspace header bar. */
  header(): Locator {
    return this.page.locator(".agent-workspace-header");
  }

  /** The label showing which workspace is active ("User Workspace" / "Agent Workspace"). */
  headerLabel(): Locator {
    return this.page.locator(".agent-workspace-header-label");
  }

  /** The agent workspace path display in the header. */
  headerPath(): Locator {
    return this.page.locator(".agent-workspace-header-path");
  }

  /** The view toggle button ("Switch to Agent" / "Switch to User"). */
  viewToggle(): Locator {
    return this.page.locator(".agent-workspace-view-toggle");
  }

  // -- Summary bar ---------------------------------------------------------

  /** The summary bar with coverage, test, and function statistics. */
  summaryBar(): Locator {
    return this.page.locator(".agent-workspace-summary");
  }

  /** All summary items (coverage, tests, functions traced). */
  summaryItems(): Locator {
    return this.page.locator(".agent-workspace-summary-item");
  }

  /** The coverage overlay toggle button ("Show Coverage" / "Hide Coverage"). */
  overlayToggle(): Locator {
    return this.page.locator(".agent-workspace-overlay-toggle");
  }

  // -- File list sidebar ---------------------------------------------------

  /** The file list sidebar container. */
  fileList(): Locator {
    return this.page.locator(".agent-workspace-file-list");
  }

  /** All file items in the sidebar. */
  async fileItems(): Promise<AgentWorkspaceFileItem[]> {
    const locators = await this.page.locator(".agent-workspace-file-item").all();
    return locators.map((loc) => new AgentWorkspaceFileItem(this.page, loc));
  }

  /** Get a specific file item by 0-based index. */
  fileItemByIndex(index: number): AgentWorkspaceFileItem {
    return new AgentWorkspaceFileItem(
      this.page,
      this.page.locator(".agent-workspace-file-item").nth(index),
    );
  }

  // -- Editor area ---------------------------------------------------------

  /** The agent workspace editor area. */
  editorArea(): Locator {
    return this.page.locator(".agent-workspace-editor-area");
  }

  /** The Monaco editor div. */
  editor(): Locator {
    return this.page.locator(".agent-workspace-editor");
  }

  // -- Coverage decorations ------------------------------------------------

  /** Lines with the ``deepreview-line-executed`` decoration (coverage overlay). */
  executedLines(): Locator {
    return this.page.locator(".deepreview-line-executed");
  }

  /** Lines with the ``deepreview-line-unreachable`` decoration (coverage overlay). */
  unreachableLines(): Locator {
    return this.page.locator(".deepreview-line-unreachable");
  }

  // -- Convenience ---------------------------------------------------------

  /**
   * Wait for the agent workspace container to appear in the DOM.
   * This is the primary readiness signal after workspace view switching.
   */
  async waitForReady(timeoutMs = 15000): Promise<void> {
    await this.page.waitForSelector(".agent-workspace-container", {
      timeout: timeoutMs,
    });
  }

  /**
   * Wait for the Monaco editor to initialise inside the agent workspace.
   * Monaco is lazily initialised after the DOM container renders.
   */
  async waitForEditorReady(timeoutMs = 20000): Promise<void> {
    await this.page.waitForSelector(".agent-workspace-editor .view-lines", {
      timeout: timeoutMs,
    });
  }
}

// ---------------------------------------------------------------------------
// Caption Bar Progress page object
// ---------------------------------------------------------------------------

/** Represents a single milestone row in the expanded milestone list. */
export class MilestoneItem {
  readonly page: Page;
  readonly root: Locator;

  constructor(page: Page, root: Locator) {
    this.page = page;
    this.root = root;
  }

  /** Get the status icon text (e.g. "[x]", "[>]", "[ ]"). */
  async statusIcon(): Promise<string> {
    return (
      (await this.root.locator(".caption-progress-milestone-icon").textContent()) ?? ""
    );
  }

  /** Get the milestone content/description text. */
  async content(): Promise<string> {
    return (
      (await this.root.locator(".caption-progress-milestone-content").textContent()) ?? ""
    );
  }

  /** Whether this milestone has a "HIGH" priority badge. */
  async hasHighPriority(): Promise<boolean> {
    const badge = this.root.locator(".caption-progress-milestone-priority");
    return (await badge.count()) > 0;
  }

  /**
   * Get the milestone status CSS class (e.g. "milestone-completed").
   * The class is applied to the ``caption-progress-milestone-item`` element.
   */
  async statusClass(): Promise<string> {
    const classes = (await this.root.getAttribute("class")) ?? "";
    // Extract the milestone-specific class from the class list.
    const match = classes.match(/milestone-\w+/);
    return match ? match[0] : "";
  }
}

/**
 * Page object for the Caption Bar Progress indicator.
 *
 * Shows the agent state, progress bar, milestone count, and current
 * milestone name. Clicking toggles workspace views; hovering expands
 * the milestone checklist.
 *
 * CSS selectors correspond to classes in
 * ``src/frontend/ui/caption_bar_progress.nim``.
 */
export class CaptionBarProgressPage {
  readonly page: Page;

  constructor(page: Page) {
    this.page = page;
  }

  // -- Container -----------------------------------------------------------

  /** The top-level caption progress container. */
  container(): Locator {
    return this.page.locator(".caption-progress-container");
  }

  /** Whether the container has the ``caption-progress-active`` class. */
  async isActive(): Promise<boolean> {
    const classes = (await this.container().getAttribute("class")) ?? "";
    return classes.includes("caption-progress-active");
  }

  // -- Compact view --------------------------------------------------------

  /** The compact view container (always visible). */
  compactView(): Locator {
    return this.page.locator(".caption-progress-compact");
  }

  /** The agent state label (e.g. "Working", "Idle", "Completed"). */
  stateLabel(): Locator {
    return this.page.locator(".caption-progress-state");
  }

  /** The task name display. */
  taskName(): Locator {
    return this.page.locator(".caption-progress-task");
  }

  /** The progress bar container. */
  progressBar(): Locator {
    return this.page.locator(".caption-progress-bar");
  }

  /** The progress bar fill element (its ``width`` style reflects progress). */
  progressBarFill(): Locator {
    return this.page.locator(".caption-progress-bar-fill");
  }

  /** The milestone count display (e.g. "3/7"). */
  milestoneCount(): Locator {
    return this.page.locator(".caption-progress-count");
  }

  /** The current milestone name display. */
  currentMilestone(): Locator {
    return this.page.locator(".caption-progress-current");
  }

  // -- State CSS classes ---------------------------------------------------

  /**
   * Get the state-specific CSS class from the compact view
   * (e.g. "caption-progress-working").
   */
  async stateCssClass(): Promise<string> {
    const classes = (await this.compactView().getAttribute("class")) ?? "";
    const match = classes.match(/caption-progress-(?:idle|initializing|working|waiting|paused|completed|failed)/);
    return match ? match[0] : "";
  }

  // -- Expanded milestone list (visible on hover) --------------------------

  /** The expanded milestone list container (visible when hovering). */
  milestoneList(): Locator {
    return this.page.locator(".caption-progress-milestones");
  }

  /** All milestone items in the expanded list. */
  async milestoneItems(): Promise<MilestoneItem[]> {
    const locators = await this.page
      .locator(".caption-progress-milestone-item")
      .all();
    return locators.map((loc) => new MilestoneItem(this.page, loc));
  }

  /** The empty milestone message ("No milestones defined"). */
  milestoneEmpty(): Locator {
    return this.page.locator(".caption-progress-milestone-empty");
  }

  // -- Convenience ---------------------------------------------------------

  /**
   * Wait for the caption progress container to appear in the DOM.
   * The component is always rendered but may start in the inactive state.
   */
  async waitForReady(timeoutMs = 15000): Promise<void> {
    await this.page.waitForSelector(".caption-progress-container", {
      timeout: timeoutMs,
    });
  }

  /**
   * Wait for the caption progress to show active state (agent is working).
   * The ``caption-progress-active`` class is added when state != AgentIdle.
   */
  async waitForActive(timeoutMs = 15000): Promise<void> {
    await this.page.waitForSelector(".caption-progress-active", {
      timeout: timeoutMs,
    });
  }

  /**
   * Hover over the container to trigger the expanded milestone list.
   * The component sets ``self.expanded = true`` on mouseenter and renders
   * the milestone list if milestones exist.
   */
  async hoverToExpand(): Promise<void> {
    await this.container().hover();
  }

  /**
   * Move the mouse away from the container to collapse the milestone list.
   * The component sets ``self.expanded = false`` on mouseleave.
   */
  async unhoverToCollapse(): Promise<void> {
    // Move the mouse to the top-left corner of the page to trigger mouseleave.
    await this.page.mouse.move(0, 0);
  }

  /** Click the container to toggle workspace view. */
  async clickToToggleView(): Promise<void> {
    await this.container().click();
  }
}

// ---------------------------------------------------------------------------
// Activity Pane DeepReview page object
// ---------------------------------------------------------------------------

/** A single file row in the activity pane's per-file coverage table. */
export class ActivityFileRow {
  readonly page: Page;
  readonly root: Locator;

  constructor(page: Page, root: Locator) {
    this.page = page;
    this.root = root;
  }

  /** Get the displayed file basename. */
  async name(): Promise<string> {
    return (
      (await this.root.locator(".activity-dr-files-col-name").textContent()) ?? ""
    );
  }

  /** Get the coverage text (e.g. "15/20"). */
  async coverageText(): Promise<string> {
    return (
      (await this.root.locator(".activity-dr-files-col-coverage").textContent()) ?? ""
    );
  }

  /** Whether this file has a flow indicator ("yes" / "--"). */
  async flowText(): Promise<string> {
    return (
      (await this.root.locator(".activity-dr-files-col-flow").textContent()) ?? ""
    );
  }
}

/** A single test result item in the activity pane's test results section. */
export class ActivityTestItem {
  readonly page: Page;
  readonly root: Locator;

  constructor(page: Page, root: Locator) {
    this.page = page;
    this.root = root;
  }

  /** Get the status text ("PASS" or "FAIL"). */
  async status(): Promise<string> {
    return (
      (await this.root.locator(".activity-dr-test-status").textContent()) ?? ""
    );
  }

  /** Get the test name. */
  async name(): Promise<string> {
    return (
      (await this.root.locator(".activity-dr-test-name").textContent()) ?? ""
    );
  }

  /** Get the duration text (e.g. "42ms"). */
  async duration(): Promise<string> {
    return (
      (await this.root.locator(".activity-dr-test-duration").textContent()) ?? ""
    );
  }

  /** Whether this test item has the "pass" CSS class. */
  async isPassed(): Promise<boolean> {
    const classes = (await this.root.getAttribute("class")) ?? "";
    return classes.includes("activity-dr-test-pass");
  }
}

/**
 * Page object for the Agent Activity DeepReview pane.
 *
 * Displays DeepReview summary cards, per-file coverage table, test results,
 * and recent notifications as a collapsible section within the agent
 * activity view.
 *
 * CSS selectors correspond to classes in
 * ``src/frontend/ui/agent_activity_deepreview.nim``.
 */
export class ActivityDeepReviewPage {
  readonly page: Page;

  constructor(page: Page) {
    this.page = page;
  }

  // -- Container -----------------------------------------------------------

  /** The top-level activity DeepReview container. */
  container(): Locator {
    return this.page.locator(".activity-dr-container");
  }

  // -- Collapsible header --------------------------------------------------

  /** The collapsible header bar ("DeepReview"). */
  header(): Locator {
    return this.page.locator(".activity-dr-header");
  }

  /** The chevron icon in the header ("v" when expanded, ">" when collapsed). */
  chevron(): Locator {
    return this.page.locator(".activity-dr-chevron");
  }

  /** The header label ("DeepReview"). */
  headerLabel(): Locator {
    return this.page.locator(".activity-dr-header-label");
  }

  /**
   * The collapsed-state badge showing coverage percentage.
   * Only visible when the section is collapsed.
   */
  headerBadge(): Locator {
    return this.page.locator(".activity-dr-header-badge");
  }

  // -- Summary cards -------------------------------------------------------

  /** The summary section containing coverage, tests, and functions cards. */
  summary(): Locator {
    return this.page.locator(".activity-dr-summary");
  }

  /** All summary cards (coverage, tests, functions). */
  summaryCards(): Locator {
    return this.page.locator(".activity-dr-card");
  }

  /** All card value elements (the large number/percentage display). */
  cardValues(): Locator {
    return this.page.locator(".activity-dr-card-value");
  }

  /** All card label elements ("Coverage", "Tests", "Functions"). */
  cardLabels(): Locator {
    return this.page.locator(".activity-dr-card-label");
  }

  /** Warning detail text (shown when tests have failures). */
  cardWarning(): Locator {
    return this.page.locator(".activity-dr-card-warn");
  }

  // -- Per-file coverage table ---------------------------------------------

  /** The per-file coverage table container. */
  filesTable(): Locator {
    return this.page.locator(".activity-dr-files");
  }

  /** The empty-state message for the files table. */
  filesEmpty(): Locator {
    return this.page.locator(".activity-dr-files-empty");
  }

  /** All file rows in the coverage table. */
  async fileRows(): Promise<ActivityFileRow[]> {
    const locators = await this.page.locator(".activity-dr-files-row").all();
    return locators.map((loc) => new ActivityFileRow(this.page, loc));
  }

  /** Get the count of file rows without fetching all elements. */
  fileRowCount(): Locator {
    return this.page.locator(".activity-dr-files-row");
  }

  // -- Test results --------------------------------------------------------

  /** The test results section container. */
  testsSection(): Locator {
    return this.page.locator(".activity-dr-tests");
  }

  /** The empty-state message for the tests section. */
  testsEmpty(): Locator {
    return this.page.locator(".activity-dr-tests-empty");
  }

  /** The test results header (e.g. "Test Results (3)"). */
  testsHeader(): Locator {
    return this.page.locator(".activity-dr-tests-header");
  }

  /** All test result items. */
  async testItems(): Promise<ActivityTestItem[]> {
    const locators = await this.page.locator(".activity-dr-test-item").all();
    return locators.map((loc) => new ActivityTestItem(this.page, loc));
  }

  /** Get the count of test items without fetching all elements. */
  testItemCount(): Locator {
    return this.page.locator(".activity-dr-test-item");
  }

  // -- Recent notifications ------------------------------------------------

  /** The recent notifications section container. */
  notificationsSection(): Locator {
    return this.page.locator(".activity-dr-notifs");
  }

  /** The empty-state message for notifications. */
  notificationsEmpty(): Locator {
    return this.page.locator(".activity-dr-notifs-empty");
  }

  /** Individual notification items. */
  notificationItems(): Locator {
    return this.page.locator(".activity-dr-notif-item");
  }

  /** Notification items with coverage styling. */
  coverageNotifications(): Locator {
    return this.page.locator(".activity-dr-notif-coverage");
  }

  /** Notification items with flow styling. */
  flowNotifications(): Locator {
    return this.page.locator(".activity-dr-notif-flow");
  }

  /** Notification items with test-pass styling. */
  testPassNotifications(): Locator {
    return this.page.locator(".activity-dr-notif-test-pass");
  }

  /** Notification items with test-fail styling. */
  testFailNotifications(): Locator {
    return this.page.locator(".activity-dr-notif-test-fail");
  }

  /** Notification items with collection-complete styling. */
  completeNotifications(): Locator {
    return this.page.locator(".activity-dr-notif-complete");
  }

  // -- Convenience ---------------------------------------------------------

  /**
   * Wait for the activity DeepReview container to appear in the DOM.
   * The component is rendered as a collapsible section within the
   * agent activity view.
   */
  async waitForReady(timeoutMs = 15000): Promise<void> {
    await this.page.waitForSelector(".activity-dr-container", {
      timeout: timeoutMs,
    });
  }

  /** Click the header to toggle the collapsed/expanded state. */
  async toggleExpanded(): Promise<void> {
    await this.header().click();
  }
}
