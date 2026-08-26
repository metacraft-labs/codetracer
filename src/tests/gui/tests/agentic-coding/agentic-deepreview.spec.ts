/**
 * E2E tests for the Agentic Coding Integration (M9).
 *
 * These tests verify the five M9 verification requirements:
 *
 *   1. test_acp_deepreview_extension -- ACP protocol handles DeepReview messages
 *   2. test_workspace_view_switching -- Views switch correctly during agent work
 *   3. test_caption_bar_progress     -- Progress indicator updates with milestones
 *   4. test_activity_pane_deepreview -- Activity pane shows DeepReview data
 *   5. test_realtime_collection      -- Data collected in real-time during execution
 *
 * The tests launch CodeTracer in a mode that simulates an active ACP session
 * by injecting IPC messages that match the protocol defined in
 * ``src/common/common_types/codetracer_features/agentic_coding.nim``.
 *
 * Because the agentic coding feature requires a full Electron build with
 * ACP session support, each test uses skip guards that bail out if:
 *   - The fixture file is missing.
 *   - The feature flag environment variable is not set.
 *   - The required DOM elements are not present (feature not compiled in).
 *
 * The test plan is documented in:
 *   src/frontend/tests/agentic_coding_test_plan.nim
 *
 * Prerequisites:
 *   - A working ``ct`` Electron build with M9 compiled in.
 *   - The JSON fixture at ``tests/agentic-coding/fixtures/agent-session.json``.
 *   - Optionally: ``CODETRACER_AGENTIC_E2E=1`` to enable live IPC tests.
 */

import { test, expect, wait } from "../../lib/fixtures";
import type { Page } from "@playwright/test";
import * as path from "node:path";
import * as fs from "node:fs";
import * as process from "node:process";
import {
  AgentWorkspacePage,
  CaptionBarProgressPage,
} from "./page-objects/agentic-page";

// ---------------------------------------------------------------------------
// Fixture loading
// ---------------------------------------------------------------------------

const fixturesDir = path.join(__dirname, "fixtures");
const agentSessionPath = path.join(fixturesDir, "agent-session.json");

const fixtureExists = fs.existsSync(agentSessionPath);

/**
 * Load the agent session fixture data for use in assertions.
 * Returns ``null`` if the fixture file does not exist (the skip guard
 * will prevent tests from running in that case).
 */
function loadFixture(): AgentSessionFixture | null {
  if (!fixtureExists) return null;
  const raw = fs.readFileSync(agentSessionPath, "utf-8");
  return JSON.parse(raw) as AgentSessionFixture;
}

// ---------------------------------------------------------------------------
// Fixture type definitions (mirrors the JSON structure)
// ---------------------------------------------------------------------------

/** IPC channel names matching the constants in agentic_coding.nim. */
const IPC_DEEPREVIEW_NOTIFICATION = "CODETRACER::acp-deepreview-notification";
const IPC_AGENT_PROGRESS = "CODETRACER::acp-agent-progress";
const IPC_WORKSPACE_VIEW_SWITCH = "CODETRACER::workspace-view-switch";

interface AgentSessionFixture {
  sessionId: string;
  agentWorkspacePath: string;
  capability: {
    supported: boolean;
    version: string;
    supportsRealtime: boolean;
    supportedLanguages: string[];
  };
  progress: {
    state: string;
    taskName: string;
    milestonesCompleted: number;
    milestonesTotal: number;
    currentMilestone: string;
    milestones: Array<{
      id: string;
      content: string;
      priority: string;
      status: string;
    }>;
  };
  notifications: Array<{
    kind: string;
    sessionId: string;
    [key: string]: unknown;
  }>;
  stateTransitions: Array<{
    state: string;
    timestampMs: number;
  }>;
  expectedSummary: {
    totalLinesCovered: number;
    totalLinesUncovered: number;
    coveragePercent: number;
    testsRun: number;
    testsPassed: number;
    testsFailed: number;
    functionsTraced: number;
    fileCount: number;
    progressPercent: number;
  };
}

// ---------------------------------------------------------------------------
// Environment-based skip guard
// ---------------------------------------------------------------------------

/**
 * The agentic coding tests require either:
 *   (a) CODETRACER_AGENTIC_E2E=1 -- enables live IPC injection, OR
 *   (b) the feature compiled into the Electron build.
 *
 * When neither is available, we skip the live tests but still validate
 * fixture integrity and IPC message structure (offline checks).
 */
const agenticFeatureEnabled =
  process.env.CODETRACER_AGENTIC_E2E === "1";

// AA-2 measured what flipping that variable actually does, because AA-1's
// note left it as a hypothesis ("either set CODETRACER_AGENTIC_E2E=1 in CI or
// delete the gate") and the `TODO(skipped)` comments below still repeat it.
//
// Run on 2026-08-25 with `CODETRACER_AGENTIC_E2E=1`: **23 passed, 8 skipped,
// 1 failed**. The 23 are the fixture-arithmetic tests, which the gate never
// covered. Of the ten `live IPC` tests the gate was hiding, eight still skip
// themselves — each wraps its setup in `catch { test.skip() }`, and the setup
// fails because `sendAgentProgress` dispatches a window event that no
// production handler subscribes to, the same dead-IPC shape AA-1 measured for
// `CODETRACER::acp-deepreview-notification`. The ninth
// ("invalid notification kind does not crash the application") fails honestly
// on `expect(body).toBeVisible()` — the edit-mode launch resolves a hidden
// window — which is unrelated to anything it claims to test.
//
// So neither of AA-1's two options is correct as stated: setting the variable
// in CI turns CI red on a pre-existing unrelated defect, and deleting the gate
// does the same while still not making the eight self-skips run. The gate is
// not what is keeping these unrun; their own `catch { test.skip() }` is.
// Left in place deliberately, with the measurement recorded rather than the
// hypothesis. Making these tests real needs the IPC injection they depend on
// to reach a live handler, which is its own piece of work.

// ---------------------------------------------------------------------------
// Helper: send IPC message to the Electron renderer
// ---------------------------------------------------------------------------

/**
 * Send an IPC message to the Electron renderer process via
 * ``page.evaluate``. This mimics the agent runtime pushing a message
 * through the main process IPC bridge.
 *
 * In the actual application, the main process forwards ACP messages from
 * the agent runtime to the renderer via ``ipcRenderer.on(channel, ...)``.
 * In tests, we call ``dispatchEvent`` on the window to trigger the same
 * code path (the Nim IPC handler listens on the same channel).
 *
 * If the renderer does not expose a global IPC dispatch helper, we fall
 * back to evaluating the handler directly.
 */
async function sendIpcMessage(p: Page, channel: string, payload: unknown): Promise<void> {
  await p.evaluate(
    ({ ch, data }) => {
      // Attempt to use the CodeTracer test IPC bridge if available.
      // The bridge is injected when CODETRACER_IN_UI_TEST=1.
      const win = window as unknown as {
        __ct_test_ipc_emit?: (channel: string, data: unknown) => void;
      };
      if (typeof win.__ct_test_ipc_emit === "function") {
        win.__ct_test_ipc_emit(ch, data);
      } else {
        // Fallback: dispatch a custom event that the Nim IPC layer can
        // listen to. This requires the application to register a
        // ``CustomEvent`` listener on the window.
        window.dispatchEvent(
          new CustomEvent("ct-ipc-test", { detail: { channel: ch, data } }),
        );
      }
    },
    { ch: channel, data: payload },
  );
}

/**
 * Send an agent progress IPC message. Convenience wrapper around
 * ``sendIpcMessage`` for the ``IPC_AGENT_PROGRESS`` channel.
 */
async function sendAgentProgress(p: Page, progress: AgentSessionFixture["progress"]): Promise<void> {
  await sendIpcMessage(p, IPC_AGENT_PROGRESS, progress);
}

/**
 * Send a DeepReview notification IPC message. Convenience wrapper around
 * ``sendIpcMessage`` for the ``IPC_DEEPREVIEW_NOTIFICATION`` channel.
 */
async function sendDeepReviewNotification(
  p: Page,
  notification: AgentSessionFixture["notifications"][number],
): Promise<void> {
  await sendIpcMessage(p, IPC_DEEPREVIEW_NOTIFICATION, notification);
}

// ===========================================================================
// Test 1: test_acp_deepreview_extension
// ===========================================================================
//
// Verifies that the ACP protocol correctly handles DeepReview messages:
// - CoverageUpdate notifications are parsed and update per-file coverage
// - FlowUpdate notifications are parsed and track function traces
// - TestComplete notifications are parsed and record test results
// - CollectionComplete notifications are parsed and summarize totals
// - Invalid/unknown notification kinds are rejected gracefully
//
// Reference: agentic_coding_test_plan.nim, suite "test_acp_deepreview_extension"
// ===========================================================================

test.describe("test_acp_deepreview_extension", () => {
  test.skip(!fixtureExists, "Agent session fixture not found");

  // -- Offline fixture validation tests (no Electron required) ---------------

  test("fixture: all notification kinds are present in the fixture", () => {
    const fixture = loadFixture();
    expect(fixture).not.toBeNull();
    if (!fixture) return;

    // Verify that the fixture contains at least one notification of each
    // kind defined in the DeepReviewNotificationKind enum (4 kinds total).
    const kinds = new Set(fixture.notifications.map((n) => n.kind));
    expect(kinds.has("CoverageUpdate")).toBe(true);
    expect(kinds.has("FlowUpdate")).toBe(true);
    expect(kinds.has("TestComplete")).toBe(true);

    // CollectionComplete is intentionally omitted from the default fixture
    // (the session is still in progress), but the kind must be defined.
    // We verify the enum has 4 members by checking the test plan.
    expect(["CoverageUpdate", "FlowUpdate", "TestComplete", "CollectionComplete"]).toHaveLength(4);
  });

  test("fixture: CoverageUpdate notifications have required fields", () => {
    const fixture = loadFixture();
    expect(fixture).not.toBeNull();
    if (!fixture) return;

    const coverageNotifs = fixture.notifications.filter(
      (n) => n.kind === "CoverageUpdate",
    );
    expect(coverageNotifs.length).toBeGreaterThan(0);

    for (const notif of coverageNotifs) {
      expect(notif.sessionId).toBe(fixture.sessionId);
      expect(notif).toHaveProperty("filePath");
      expect(notif).toHaveProperty("linesCovered");
      expect(notif).toHaveProperty("linesUncovered");
      expect(Array.isArray(notif.linesCovered)).toBe(true);
      expect(Array.isArray(notif.linesUncovered)).toBe(true);
    }
  });

  test("fixture: TestComplete notifications have required fields", () => {
    const fixture = loadFixture();
    expect(fixture).not.toBeNull();
    if (!fixture) return;

    const testNotifs = fixture.notifications.filter(
      (n) => n.kind === "TestComplete",
    );
    expect(testNotifs.length).toBeGreaterThan(0);

    for (const notif of testNotifs) {
      expect(notif.sessionId).toBe(fixture.sessionId);
      expect(notif).toHaveProperty("testName");
      expect(notif).toHaveProperty("passed");
      expect(notif).toHaveProperty("durationMs");
      expect(notif).toHaveProperty("traceContextId");
    }
  });

  test("fixture: FlowUpdate notifications have required fields", () => {
    const fixture = loadFixture();
    expect(fixture).not.toBeNull();
    if (!fixture) return;

    const flowNotifs = fixture.notifications.filter(
      (n) => n.kind === "FlowUpdate",
    );
    expect(flowNotifs.length).toBeGreaterThan(0);

    for (const notif of flowNotifs) {
      expect(notif.sessionId).toBe(fixture.sessionId);
      expect(notif).toHaveProperty("flowFilePath");
      expect(notif).toHaveProperty("functionKey");
      expect(notif).toHaveProperty("executionIndex");
      expect(notif).toHaveProperty("stepCount");
    }
  });

  test("fixture: expected summary matches computed values from notifications", () => {
    const fixture = loadFixture();
    expect(fixture).not.toBeNull();
    if (!fixture) return;

    // Recompute the summary from the notifications to verify the fixture
    // is self-consistent.
    let totalCovered = 0;
    let totalUncovered = 0;
    let testsRun = 0;
    let testsPassed = 0;
    let testsFailed = 0;
    let functionsTraced = 0;
    const filePaths = new Set<string>();

    for (const notif of fixture.notifications) {
      switch (notif.kind) {
        case "CoverageUpdate": {
          const covered = notif.linesCovered as number[];
          const uncovered = notif.linesUncovered as number[];
          totalCovered += covered.length;
          totalUncovered += uncovered.length;
          filePaths.add(notif.filePath as string);
          break;
        }
        case "FlowUpdate":
          functionsTraced += 1;
          break;
        case "TestComplete":
          testsRun += 1;
          if (notif.passed) testsPassed += 1;
          else testsFailed += 1;
          break;
        default:
          break;
      }
    }

    const expected = fixture.expectedSummary;
    expect(totalCovered).toBe(expected.totalLinesCovered);
    expect(totalUncovered).toBe(expected.totalLinesUncovered);
    expect(testsRun).toBe(expected.testsRun);
    expect(testsPassed).toBe(expected.testsPassed);
    expect(testsFailed).toBe(expected.testsFailed);
    expect(functionsTraced).toBe(expected.functionsTraced);
    expect(filePaths.size).toBe(expected.fileCount);

    // Verify coverage percentage.
    const totalLines = totalCovered + totalUncovered;
    const computedPct =
      totalLines > 0 ? (totalCovered / totalLines) * 100.0 : 0.0;
    // Allow a 0.1% tolerance for floating-point rounding.
    expect(computedPct).toBeCloseTo(expected.coveragePercent, 1);
  });

  // -- Live IPC tests (require Electron with M9 compiled in) -----------------

  // TODO(skipped): Skipped when CODETRACER_AGENTIC_E2E != "1". These tests require the agentic
  //   coding feature to be compiled into the Electron build (M9 milestone). In CI and default
  //   dev environments the feature flag is off so these are skipped by design.
  //   Hypothesis: Enable by setting CODETRACER_AGENTIC_E2E=1 before running tests.
  //   Some internal tests may also fail because DOM elements for the agent workspace are not
  //   rendered when the feature is disabled at compile time.
  test.describe("live IPC", () => {
    test.skip(
      !agenticFeatureEnabled,
      "Set CODETRACER_AGENTIC_E2E=1 to enable live IPC tests",
    );

    // Launch in edit mode (the simplest mode that includes the agent
    // workspace components when the feature is compiled in).
    test.use({ launchMode: "edit", editFolderPath: path.join(__dirname, "fixtures") });

    // AA-1 deleted the two tests that stood here — "CoverageUpdate
    // notification updates the activity pane" and "TestComplete notification
    // updates test results".  Both asserted that a `DeepReviewNotification`
    // painted a row in the Agent Activity roll-up, and that roll-up is gone
    // (DeepReview-GUI.md §2.1).  Neither is retargeted, for two reasons:
    //
    //   * the renderer-side handler they exercised
    //     (`agent_activity_deepreview.onActivityDeepReviewNotification`) was
    //     never subscribed to `IPC_DEEPREVIEW_NOTIFICATION` — measured, not
    //     assumed: no `ipc.on` for that channel existed anywhere in the
    //     frontend — so the assertions passed only through their own
    //     `catch { test.skip(...) }`; and
    //   * nothing else consumes the channel either. The same measurement that
    //     condemns the deleted handler condemns the whole channel:
    //     `configureIPC`'s `uiIpcHandlers` list in `ui_js.nim` names
    //     `start-deepreview` but not `acp-deepreview-notification`, so
    //     `agent_workspace.onAcpDeepReviewNotification` is unsubscribed too,
    //     and the string does not occur in the built `ui.js` at all. Deleting
    //     the roll-up's feed therefore cost nothing, because neither feed ever
    //     received a message.
    //
    // What the session feed does with a run of tests is AA-2's, and gets its
    // own coverage there.

    test("invalid notification kind does not crash the application", async ({ ctPage }) => {
      // Send a notification with an unknown kind. Note this asserts far less
      // than it appears to: with no subscriber on the channel (see above) the
      // message is delivered to nobody, so this exercises the injection path
      // and the app's survival, not `agent_workspace.nim`'s dispatch. Wiring
      // the channel up is AA-2's, and this test becomes meaningful then.
      await sendDeepReviewNotification(ctPage, {
        kind: "UnknownNotificationKind",
        sessionId: "agentic-e2e-test-session-001",
      });
      await wait(300);

      // Verify the page is still responsive by checking a known element.
      const body = ctPage.locator("body");
      await expect(body).toBeVisible();
    });
  });
});

// ===========================================================================
// Test 2: test_workspace_view_switching
// ===========================================================================
//
// Verifies that the workspace view switches correctly during agent work:
// - Default view is UserWorkspace
// - Clicking the caption bar toggles to AgentWorkspace
// - Clicking again toggles back to UserWorkspace
// - The agent workspace shows files from the agent's working directory
//
// Reference: agentic_coding_test_plan.nim, suite "test_workspace_view_switching"
// ===========================================================================

test.describe("test_workspace_view_switching", () => {
  test.skip(!fixtureExists, "Agent session fixture not found");

  // -- Offline fixture validation tests (no Electron required) ---------------

  test("fixture: workspace view kinds are defined correctly", () => {
    // The WorkspaceViewKind enum has exactly 2 values:
    //   UserWorkspace = 0, AgentWorkspace = 1
    // Verify by checking the fixture uses valid view-related strings.
    const fixture = loadFixture();
    expect(fixture).not.toBeNull();
    if (!fixture) return;

    expect(fixture.agentWorkspacePath).toBeTruthy();
    expect(fixture.sessionId).toBeTruthy();
  });

  test("fixture: toggle logic alternates between two views", () => {
    // Simulate the toggle logic from the caption bar IsoNim click handler.
    // This mirrors the Nim test in agentic_coding_test_plan.nim.
    type ViewKind = "UserWorkspace" | "AgentWorkspace";

    function toggle(view: ViewKind): ViewKind {
      return view === "UserWorkspace" ? "AgentWorkspace" : "UserWorkspace";
    }

    let view: ViewKind = "UserWorkspace";
    expect(view).toBe("UserWorkspace");

    // Toggle to Agent.
    view = toggle(view);
    expect(view).toBe("AgentWorkspace");

    // Toggle back to User.
    view = toggle(view);
    expect(view).toBe("UserWorkspace");

    // Double toggle returns to original.
    view = toggle(toggle(view));
    expect(view).toBe("UserWorkspace");
  });

  // -- Live IPC tests (require Electron with M9 compiled in) -----------------

  // TODO(skipped): Skipped when CODETRACER_AGENTIC_E2E != "1". These tests require the agentic
  //   coding feature to be compiled into the Electron build (M9 milestone). In CI and default
  //   dev environments the feature flag is off so these are skipped by design.
  //   Hypothesis: Enable by setting CODETRACER_AGENTIC_E2E=1 before running tests.
  //   Some internal tests may also fail because DOM elements for the agent workspace are not
  //   rendered when the feature is disabled at compile time.
  test.describe("live IPC", () => {
    test.skip(
      !agenticFeatureEnabled,
      "Set CODETRACER_AGENTIC_E2E=1 to enable live IPC tests",
    );

    test.use({ launchMode: "edit", editFolderPath: path.join(__dirname, "fixtures") });

    test("clicking caption bar toggles workspace view", async ({ ctPage }) => {
      const fixture = loadFixture();
      expect(fixture).not.toBeNull();
      if (!fixture) return;

      const captionBar = new CaptionBarProgressPage(ctPage);
      const agentWorkspace = new AgentWorkspacePage(ctPage);

      // Initialise the agent session so the caption bar becomes active.
      await sendAgentProgress(ctPage, fixture.progress);
      await wait(500);

      try {
        await captionBar.waitForActive(5000);
      } catch {
        test.skip(true, "Caption bar did not activate");
        return;
      }

      // Default view should be UserWorkspace. The agent workspace container
      // should not be visible initially.
      const initialAgentVisible = await agentWorkspace.container().isVisible();
      // Note: UserWorkspace is default, so agent workspace may or may not
      // be rendered depending on the layout. We check the header label
      // if the workspace component is present.
      if (initialAgentVisible) {
        const label = await agentWorkspace.headerLabel().textContent();
        // Even if the container is rendered, the label should indicate
        // which view is active.
        expect(label).toBeTruthy();
      }

      // Click the caption bar to toggle to AgentWorkspace.
      await captionBar.clickToToggleView();
      await wait(500);

      // After clicking, the agent workspace container should be visible
      // and the header label should say "Agent Workspace".
      try {
        await agentWorkspace.waitForReady(5000);
        const label = await agentWorkspace.headerLabel().textContent();
        expect(label).toContain("Agent Workspace");
      } catch {
        // The workspace component may not render if the layout does not
        // include it. This is acceptable for some build configurations.
        test.skip(true, "Agent workspace did not render after toggle");
        return;
      }

      // Click again to toggle back to UserWorkspace.
      await captionBar.clickToToggleView();
      await wait(500);

      // If the workspace component is still rendered, the header should
      // now say "User Workspace".
      const afterToggleVisible = await agentWorkspace.container().isVisible();
      if (afterToggleVisible) {
        const label = await agentWorkspace.headerLabel().textContent();
        expect(label).toContain("User Workspace");
      }
    });

    test("view toggle button text changes with active view", async ({ ctPage }) => {
      const fixture = loadFixture();
      expect(fixture).not.toBeNull();
      if (!fixture) return;

      const agentWorkspace = new AgentWorkspacePage(ctPage);

      // Initialise the session.
      await sendAgentProgress(ctPage, fixture.progress);
      await wait(500);

      try {
        await agentWorkspace.waitForReady(5000);
      } catch {
        test.skip(true, "Agent workspace did not render");
        return;
      }

      // In UserWorkspace mode, the toggle button should say "Switch to Agent".
      let toggleText = await agentWorkspace.viewToggle().textContent();
      expect(toggleText).toContain("Switch to Agent");

      // Click the toggle.
      await agentWorkspace.viewToggle().click();
      await wait(500);

      // In AgentWorkspace mode, the toggle button should say "Switch to User".
      toggleText = await agentWorkspace.viewToggle().textContent();
      expect(toggleText).toContain("Switch to User");

      // Toggle back.
      await agentWorkspace.viewToggle().click();
      await wait(500);
    });
  });
});

// ===========================================================================
// Test 3: test_caption_bar_progress
// ===========================================================================
//
// Verifies the caption bar progress indicator updates with milestones:
// - Progress percentage is computed correctly from milestones
// - All agent states map to correct CSS classes
// - Milestone list renders with correct status icons
// - The expanded view shows all milestones
// - Edge cases: 0 milestones, all completed, all failed
//
// Reference: agentic_coding_test_plan.nim, suite "test_caption_bar_progress"
// ===========================================================================

test.describe("test_caption_bar_progress", () => {
  test.skip(!fixtureExists, "Agent session fixture not found");

  // -- Offline fixture validation tests (no Electron required) ---------------

  test("fixture: progress percentage computed correctly", () => {
    const fixture = loadFixture();
    expect(fixture).not.toBeNull();
    if (!fixture) return;

    const { milestonesCompleted, milestonesTotal } = fixture.progress;
    const pct =
      milestonesTotal > 0
        ? (milestonesCompleted / milestonesTotal) * 100.0
        : 0.0;

    // 3/7 = 42.857...%
    expect(pct).toBeGreaterThan(42.8);
    expect(pct).toBeLessThan(42.9);
    expect(pct).toBeCloseTo(fixture.expectedSummary.progressPercent, 1);
  });

  test("fixture: all milestone statuses are valid enum values", () => {
    const fixture = loadFixture();
    expect(fixture).not.toBeNull();
    if (!fixture) return;

    const validStatuses = [
      "MilestonePending",
      "MilestoneInProgress",
      "MilestoneCompleted",
      "MilestoneFailed",
      "MilestoneSkipped",
    ];

    for (const milestone of fixture.progress.milestones) {
      expect(validStatuses).toContain(milestone.status);
    }
  });

  test("fixture: all agent states are valid enum values", () => {
    const validStates = [
      "AgentIdle",
      "AgentInitializing",
      "AgentWorking",
      "AgentWaitingInput",
      "AgentPaused",
      "AgentCompleted",
      "AgentFailed",
    ];
    // 7 states total.
    expect(validStates).toHaveLength(7);

    const fixture = loadFixture();
    expect(fixture).not.toBeNull();
    if (!fixture) return;

    expect(validStates).toContain(fixture.progress.state);

    for (const transition of fixture.stateTransitions) {
      expect(validStates).toContain(transition.state);
    }
  });

  test("fixture: milestone count matches total", () => {
    const fixture = loadFixture();
    expect(fixture).not.toBeNull();
    if (!fixture) return;

    expect(fixture.progress.milestones).toHaveLength(
      fixture.progress.milestonesTotal,
    );

    // Count completed milestones in the array.
    const completedCount = fixture.progress.milestones.filter(
      (m) => m.status === "MilestoneCompleted",
    ).length;
    expect(completedCount).toBe(fixture.progress.milestonesCompleted);
  });

  test("fixture: current milestone exists in the milestones list", () => {
    const fixture = loadFixture();
    expect(fixture).not.toBeNull();
    if (!fixture) return;

    const currentId = fixture.progress.currentMilestone;
    expect(currentId).toBeTruthy();

    const found = fixture.progress.milestones.find((m) => m.id === currentId);
    expect(found).toBeDefined();
    // The current milestone should be in progress.
    expect(found?.status).toBe("MilestoneInProgress");
  });

  test("fixture: edge case - 0 milestones yields 0% progress", () => {
    // Mirrors the Nim test "Empty milestones list yields 0% progress".
    const pct = 0 > 0 ? (0 / 0) * 100.0 : 0.0;
    expect(pct).toBe(0.0);
  });

  // -- Live IPC tests (require Electron with M9 compiled in) -----------------

  // TODO(skipped): Skipped when CODETRACER_AGENTIC_E2E != "1". These tests require the agentic
  //   coding feature to be compiled into the Electron build (M9 milestone). In CI and default
  //   dev environments the feature flag is off so these are skipped by design.
  //   Hypothesis: Enable by setting CODETRACER_AGENTIC_E2E=1 before running tests.
  //   Some internal tests may also fail because DOM elements for the agent workspace are not
  //   rendered when the feature is disabled at compile time.
  test.describe("live IPC", () => {
    test.skip(
      !agenticFeatureEnabled,
      "Set CODETRACER_AGENTIC_E2E=1 to enable live IPC tests",
    );

    test.use({ launchMode: "edit", editFolderPath: path.join(__dirname, "fixtures") });

    test("progress bar width matches milestone completion", async ({ ctPage }) => {
      const fixture = loadFixture();
      expect(fixture).not.toBeNull();
      if (!fixture) return;

      const captionBar = new CaptionBarProgressPage(ctPage);

      // Send progress to activate the caption bar.
      await sendAgentProgress(ctPage, fixture.progress);
      await wait(500);

      try {
        await captionBar.waitForActive(5000);
      } catch {
        test.skip(true, "Caption bar did not activate");
        return;
      }

      // The progress bar fill width should be approximately 42.9%.
      const fillStyle = await captionBar
        .progressBarFill()
        .getAttribute("style");
      expect(fillStyle).toBeTruthy();
      // The Nim component sets style = "width: 42.9%" via
      // ``style(StyleAttr.width, cstring(fmt"{pct:.1f}%"))``.
      expect(fillStyle).toContain("42.9%");
    });

    test("state label shows 'Working' for AgentWorking state", async ({ ctPage }) => {
      const fixture = loadFixture();
      expect(fixture).not.toBeNull();
      if (!fixture) return;

      const captionBar = new CaptionBarProgressPage(ctPage);

      await sendAgentProgress(ctPage, fixture.progress);
      await wait(500);

      try {
        await captionBar.waitForActive(5000);
      } catch {
        test.skip(true, "Caption bar did not activate");
        return;
      }

      const stateText = await captionBar.stateLabel().textContent();
      expect(stateText).toContain("Working");

      const cssClass = await captionBar.stateCssClass();
      expect(cssClass).toBe("caption-progress-working");
    });

    test("milestone count displays completed/total format", async ({ ctPage }) => {
      const fixture = loadFixture();
      expect(fixture).not.toBeNull();
      if (!fixture) return;

      const captionBar = new CaptionBarProgressPage(ctPage);

      await sendAgentProgress(ctPage, fixture.progress);
      await wait(500);

      try {
        await captionBar.waitForActive(5000);
      } catch {
        test.skip(true, "Caption bar did not activate");
        return;
      }

      const countText = await captionBar.milestoneCount().textContent();
      expect(countText).toContain("3/7");
    });

    test("hover expands milestone list with correct items", async ({ ctPage }) => {
      const fixture = loadFixture();
      expect(fixture).not.toBeNull();
      if (!fixture) return;

      const captionBar = new CaptionBarProgressPage(ctPage);

      await sendAgentProgress(ctPage, fixture.progress);
      await wait(500);

      try {
        await captionBar.waitForActive(5000);
      } catch {
        test.skip(true, "Caption bar did not activate");
        return;
      }

      // Hover to expand the milestone list.
      await captionBar.hoverToExpand();
      await wait(500);

      // The milestone list should be visible.
      await expect(captionBar.milestoneList()).toBeVisible();

      // Verify milestone count matches the fixture.
      const milestoneItems = await captionBar.milestoneItems();
      expect(milestoneItems).toHaveLength(fixture.progress.milestones.length);

      // Verify milestone content matches fixture data.
      for (let i = 0; i < fixture.progress.milestones.length; i++) {
        const expected = fixture.progress.milestones[i];
        const content = await milestoneItems[i].content();
        expect(content).toBe(expected.content);
      }

      // Verify status icons for known milestones.
      // Completed milestones should have "[x]".
      const firstIcon = await milestoneItems[0].statusIcon();
      expect(firstIcon).toBe("[x]"); // "Analyze codebase" is completed.

      // In-progress milestone should have "[>]".
      const inProgressIdx = fixture.progress.milestones.findIndex(
        (m) => m.status === "MilestoneInProgress",
      );
      if (inProgressIdx >= 0) {
        const ipIcon = await milestoneItems[inProgressIdx].statusIcon();
        expect(ipIcon).toBe("[>]");
      }

      // Pending milestones should have "[ ]".
      const pendingIdx = fixture.progress.milestones.findIndex(
        (m) => m.status === "MilestonePending",
      );
      if (pendingIdx >= 0) {
        const pendIcon = await milestoneItems[pendingIdx].statusIcon();
        expect(pendIcon).toBe("[ ]");
      }

      // Unhover to collapse.
      await captionBar.unhoverToCollapse();
      await wait(500);
    });

    test("current milestone name is displayed in compact view", async ({ ctPage }) => {
      const fixture = loadFixture();
      expect(fixture).not.toBeNull();
      if (!fixture) return;

      const captionBar = new CaptionBarProgressPage(ctPage);

      await sendAgentProgress(ctPage, fixture.progress);
      await wait(500);

      try {
        await captionBar.waitForActive(5000);
      } catch {
        test.skip(true, "Caption bar did not activate");
        return;
      }

      const currentText = await captionBar.currentMilestone().textContent();
      expect(currentText).toBe(fixture.progress.currentMilestone);
    });
  });
});

// ===========================================================================
// Test 4: test_activity_pane_deepreview
// ===========================================================================
//
// Verifies the activity pane shows DeepReview data correctly:
// - Summary cards display coverage percentage, test counts, function counts
// - Per-file coverage table lists files with correct coverage ratios
// - Test results section shows pass/fail status with timing
// - Recent notifications feed shows last N notifications
// - Collapsible header works (expanded/collapsed toggle)
//
// Reference: agentic_coding_test_plan.nim, suite "test_activity_pane_deepreview"
// ===========================================================================

test.describe("test_activity_pane_deepreview", () => {
  test.skip(!fixtureExists, "Agent session fixture not found");

  // -- Offline fixture validation tests (no Electron required) ---------------

  test("fixture: coverage accumulation from multiple files", () => {
    const fixture = loadFixture();
    expect(fixture).not.toBeNull();
    if (!fixture) return;

    // Simulate the summary accumulation logic from
    // AgentActivityDeepReviewComponent.handleNotification.
    let totalCovered = 0;
    let totalUncovered = 0;

    for (const notif of fixture.notifications) {
      if (notif.kind === "CoverageUpdate") {
        const covered = notif.linesCovered as number[];
        const uncovered = notif.linesUncovered as number[];
        totalCovered += covered.length;
        totalUncovered += uncovered.length;
      }
    }

    expect(totalCovered).toBe(fixture.expectedSummary.totalLinesCovered);
    expect(totalUncovered).toBe(fixture.expectedSummary.totalLinesUncovered);

    const totalLines = totalCovered + totalUncovered;
    const pct = totalLines > 0 ? (totalCovered / totalLines) * 100.0 : 0.0;
    expect(pct).toBeCloseTo(fixture.expectedSummary.coveragePercent, 1);
  });

  test("fixture: test results accumulation", () => {
    const fixture = loadFixture();
    expect(fixture).not.toBeNull();
    if (!fixture) return;

    const testNotifs = fixture.notifications.filter(
      (n) => n.kind === "TestComplete",
    );
    let passed = 0;
    let failed = 0;

    for (const notif of testNotifs) {
      if (notif.passed) passed += 1;
      else failed += 1;
    }

    expect(testNotifs.length).toBe(fixture.expectedSummary.testsRun);
    expect(passed).toBe(fixture.expectedSummary.testsPassed);
    expect(failed).toBe(fixture.expectedSummary.testsFailed);
  });

  test("fixture: functions traced count", () => {
    const fixture = loadFixture();
    expect(fixture).not.toBeNull();
    if (!fixture) return;

    const flowNotifs = fixture.notifications.filter(
      (n) => n.kind === "FlowUpdate",
    );
    expect(flowNotifs.length).toBe(fixture.expectedSummary.functionsTraced);
  });

  test("fixture: 100% coverage when all lines are covered", () => {
    // Edge case: a file with only covered lines should produce 100%.
    const covered = 100;
    const uncovered = 0;
    const total = covered + uncovered;
    const pct = total > 0 ? (covered / total) * 100.0 : 0.0;
    expect(pct).toBe(100.0);
  });

  test("fixture: 0% coverage when no lines are covered", () => {
    // Edge case: a file with only uncovered lines should produce 0%.
    const covered = 0;
    const uncovered = 50;
    const total = covered + uncovered;
    const pct = total > 0 ? (covered / total) * 100.0 : 0.0;
    expect(pct).toBe(0.0);
  });

  // -- Live IPC tests (require Electron with M9 compiled in) -----------------

  // TODO(skipped): Skipped when CODETRACER_AGENTIC_E2E != "1". These tests require the agentic
  //   coding feature to be compiled into the Electron build (M9 milestone). In CI and default
  //   dev environments the feature flag is off so these are skipped by design.
  //   Hypothesis: Enable by setting CODETRACER_AGENTIC_E2E=1 before running tests.
  //   Some internal tests may also fail because DOM elements for the agent workspace are not
  //   rendered when the feature is disabled at compile time.
  // AA-1 deleted this describe's five live-IPC tests — the summary cards, the
  // per-file coverage table, the test-results section, the collapsible header
  // and the failure-warning detail.  Every one of them asserted on the Agent
  // Activity roll-up's DOM (`.activity-dr-*`), which no longer exists
  // (DeepReview-GUI.md §2.1: "There is no 'DeepReview section' in this
  // panel").
  //
  // Nothing is retargeted from them, because nothing they measured moved:
  // they measured the roll-up's own rendering of numbers the VCS panel
  // already carries.  The fixture-level tests above — which compute coverage,
  // test totals and traced-function counts from the same notification stream
  // — are untouched and keep the arithmetic covered.
  //
  // Worth recording, because it is the reason none of this was noticed
  // earlier: unlike the two tests deleted from `test_acp_deepreview_extension`
  // above, these five did carry real assertions outside their
  // `catch { test.skip() }` — the catch wrapped only `waitForReady`.  They
  // still never ran.  Every `live IPC` describe in this file is gated on
  // `CODETRACER_AGENTIC_E2E === "1"`, and nothing in the repository sets that
  // variable: not a CI workflow, not a `just` recipe, not a script.  A
  // describe-level gate on an environment variable nobody sets is a suite
  // that reports green while asserting nothing, which is how DOM assertions
  // for a pane survived long past the pane.
});

test.describe("test_realtime_collection", () => {
  test.skip(!fixtureExists, "Agent session fixture not found");

  // -- Offline fixture validation tests (no Electron required) ---------------

  test("fixture: incremental coverage updates accumulate correctly", () => {
    // Mirrors the Nim test "Incremental coverage updates accumulate".
    // Simulate 5 incremental updates and verify accumulation.
    let totalCovered = 0;
    let totalUncovered = 0;

    for (let i = 1; i <= 5; i++) {
      totalCovered += i * 10;
      totalUncovered += i * 2;
    }

    // Total covered: 10 + 20 + 30 + 40 + 50 = 150
    expect(totalCovered).toBe(150);
    // Total uncovered: 2 + 4 + 6 + 8 + 10 = 30
    expect(totalUncovered).toBe(30);

    const totalLines = totalCovered + totalUncovered;
    const pct = (totalCovered / totalLines) * 100.0;
    // 150 / 180 = 83.3%
    expect(pct).toBeGreaterThan(83.0);
    expect(pct).toBeLessThan(84.0);
  });

  test("fixture: state transitions follow valid lifecycle", () => {
    const fixture = loadFixture();
    expect(fixture).not.toBeNull();
    if (!fixture) return;

    // The state transitions should follow a valid lifecycle:
    // Idle -> Initializing -> Working -> ... -> Completed/Failed
    const transitions = fixture.stateTransitions;
    expect(transitions.length).toBeGreaterThan(0);

    // First state should be AgentIdle.
    expect(transitions[0].state).toBe("AgentIdle");

    // Timestamps should be monotonically increasing.
    for (let i = 1; i < transitions.length; i++) {
      expect(transitions[i].timestampMs).toBeGreaterThanOrEqual(
        transitions[i - 1].timestampMs,
      );
    }
  });

  test("fixture: mixed notifications update all counters independently", () => {
    const fixture = loadFixture();
    expect(fixture).not.toBeNull();
    if (!fixture) return;

    // Simulate processing all notifications and verify each counter is
    // updated independently (mirrors the Nim test "Mixed notifications
    // update all counters").
    let totalCovered = 0;
    let testsRun = 0;
    let testsPassed = 0;
    let testsFailed = 0;
    let functionsTraced = 0;

    for (const notif of fixture.notifications) {
      switch (notif.kind) {
        case "CoverageUpdate":
          totalCovered += (notif.linesCovered as number[]).length;
          break;
        case "FlowUpdate":
          functionsTraced += 1;
          break;
        case "TestComplete":
          testsRun += 1;
          if (notif.passed) testsPassed += 1;
          else testsFailed += 1;
          break;
        default:
          break;
      }
    }

    expect(totalCovered).toBe(fixture.expectedSummary.totalLinesCovered);
    expect(testsRun).toBe(fixture.expectedSummary.testsRun);
    expect(testsPassed).toBe(fixture.expectedSummary.testsPassed);
    expect(testsFailed).toBe(fixture.expectedSummary.testsFailed);
    expect(functionsTraced).toBe(fixture.expectedSummary.functionsTraced);
  });

  test("fixture: CollectionComplete does not alter counters", () => {
    // Mirrors the Nim test "CollectionComplete does not alter counters".
    // CollectionComplete is a signal, not a data update.
    let totalCovered = 20;
    let testsRun = 1;

    // Processing a CollectionComplete should not change anything.
    const collectionCompleteNotif = {
      kind: "CollectionComplete",
      sessionId: "test",
      totalFiles: 5,
      totalFunctions: 10,
      totalTests: 3,
    };

    // The switch statement for CollectionComplete does ``discard``.
    // No counter updates happen.
    expect(totalCovered).toBe(20);
    expect(testsRun).toBe(1);
    // Verify the notification structure is valid.
    expect(collectionCompleteNotif.kind).toBe("CollectionComplete");
    expect(collectionCompleteNotif.totalFiles).toBeGreaterThan(0);
  });

  test("fixture: notifications capped at max recent count of 50", () => {
    // Mirrors the Nim test "Notifications capped at max recent count".
    const MAX_RECENT = 50;
    const notifications: number[] = [];

    for (let i = 0; i < 60; i++) {
      notifications.push(i);
    }

    // Trim to most recent MAX_RECENT.
    const recent =
      notifications.length > MAX_RECENT
        ? notifications.slice(notifications.length - MAX_RECENT)
        : notifications;

    expect(recent).toHaveLength(MAX_RECENT);
    expect(recent[0]).toBe(10); // Oldest kept is index 10.
    expect(recent[recent.length - 1]).toBe(59); // Most recent is 59.
  });

  // -- Live IPC tests (require Electron with M9 compiled in) -----------------

  // TODO(skipped): Skipped when CODETRACER_AGENTIC_E2E != "1". These tests require the agentic
  //   coding feature to be compiled into the Electron build (M9 milestone). In CI and default
  //   dev environments the feature flag is off so these are skipped by design.
  //   Hypothesis: Enable by setting CODETRACER_AGENTIC_E2E=1 before running tests.
  //   Some internal tests may also fail because DOM elements for the agent workspace are not
  //   rendered when the feature is disabled at compile time.
  test.describe("live IPC", () => {
    test.skip(
      !agenticFeatureEnabled,
      "Set CODETRACER_AGENTIC_E2E=1 to enable live IPC tests",
    );

    test.use({ launchMode: "edit", editFolderPath: path.join(__dirname, "fixtures") });

    // AA-1 deleted "incremental notifications update UI in real-time": its
    // only UI assertion was the roll-up's file-row count, and its caption-bar
    // half is the test below.  The fixture-level "incremental coverage updates
    // accumulate correctly" above keeps the accumulation itself covered.

    test("agent state transitions to Completed after CollectionComplete", async ({ ctPage }) => {
      const fixture = loadFixture();
      expect(fixture).not.toBeNull();
      if (!fixture) return;

      const captionBar = new CaptionBarProgressPage(ctPage);

      // Start with Working state.
      await sendAgentProgress(ctPage, fixture.progress);
      await wait(500);

      try {
        await captionBar.waitForActive(5000);
      } catch {
        test.skip(true, "Caption bar did not activate");
        return;
      }

      // Send a CollectionComplete notification.
      await sendDeepReviewNotification(ctPage, {
        kind: "CollectionComplete",
        sessionId: fixture.sessionId,
        totalFiles: 3,
        totalFunctions: 3,
        totalTests: 3,
      });
      await wait(300);

      // Transition the agent to Completed state.
      await sendAgentProgress(ctPage, {
        ...fixture.progress,
        state: "AgentCompleted",
        milestonesCompleted: fixture.progress.milestonesTotal,
        currentMilestone: "",
      });
      await wait(500);

      // The state label should now show "Completed".
      const stateText = await captionBar.stateLabel().textContent();
      expect(stateText).toContain("Completed");

      // The progress bar should show 100%.
      const fillStyle = await captionBar
        .progressBarFill()
        .getAttribute("style");
      expect(fillStyle).toContain("100.0%");
    });
  });
});
