import { test, expect } from "../../lib/fixtures";

/**
 * M3 — additive tab placement.
 *
 * The Video Player / Pixel History / Shader Debug tabs must be inserted into
 * the user's existing GoldenLayout rather than replacing it.  This spec asserts
 * that the standard editor / state / event-log / terminal panes that the
 * default user layout ships with are all still present after a visual-capable
 * trace is opened, in addition to the new visual-replay tabs.
 *
 * Spec: codetracer-specs/GUI/Debugging-Features/Visual-Replay.md §Activation
 * Milestone: codetracer-specs/GUI/Debugging-Features/Visual-Replay.milestones.org M3
 */

test.describe("MCR visual replay additive tab placement", () => {
  test.describe.configure({ mode: "serial" });
  test.setTimeout(120_000);
  test.use({
    sourcePath: "py_console_logs/main.py",
    launchMode: "trace",
    deploymentMode: "web",
    visualReplayTrace: true,
  });

  test.beforeEach(() => {
    process.env.CODETRACER_VISUAL_REPLAY_FAKE_PLAYER = "ready";
  });

  test.afterEach(() => {
    delete process.env.CODETRACER_VISUAL_REPLAY_FAKE_PLAYER;
  });

  test("visual-replay-layout/additive-tabs preserves user layout panes", async ({ ctPage }) => {
    // The Video Player tab must be present — it is the new home of the
    // rendered-frame canvas (the legacy Frame Viewer pane was retired in M3).
    await expect(ctPage.locator(".lm_tab", { hasText: "VIDEO PLAYER" })).toBeVisible();
    await expect(ctPage.locator(".video-player-component")).toBeVisible();

    // The state-view tabs that were inserted alongside the Video Player.
    await expect(ctPage.locator(".lm_tab", { hasText: "PIXEL HISTORY" })).toBeVisible();
    await expect(ctPage.locator(".lm_tab", { hasText: "SHADER DEBUG" })).toBeVisible();

    // The user's existing layout must NOT have been clobbered: the standard
    // editor / state / calltrace / event-log / terminal panes must all be
    // intact.  This is what distinguishes additive insertion from the
    // pre-M3 replacement layout, where these panes were re-arranged into a
    // visual-replay-specific configuration.
    await expect(ctPage.locator(".lm_tab", { hasText: /\.(py|rb|nr)\b/ })).toBeVisible();
    await expect(ctPage.locator(".lm_tab", { hasText: "STATE" })).toBeVisible();
    await expect(ctPage.locator(".lm_tab", { hasText: "CALLTRACE" })).toBeVisible();
    await expect(ctPage.locator(".lm_tab", { hasText: "EVENT LOG" })).toBeVisible();
    await expect(ctPage.locator(".lm_tab", { hasText: "TERMINAL OUTPUT" })).toBeVisible();

    // The Frame Viewer pane was retired — its tab must not exist anymore.
    await expect(ctPage.locator(".lm_tab", { hasText: "FRAME VIEWER" })).toHaveCount(0);

    // The additive insertion must place Video Player in the same stack as
    // the source editor.  We check this structurally by walking the DOM:
    // the tab list that contains the editor tab must also contain the
    // Video Player tab.
    const editorStackTabRow = ctPage.locator(".lm_stack", {
      has: ctPage.locator(".lm_tab", { hasText: /\.(py|rb|nr)\b/ }),
    });
    await expect(
      editorStackTabRow.locator(".lm_tab", { hasText: "VIDEO PLAYER" }),
    ).toBeVisible();

    // Similarly the state-view stack (State / Filesystem) must host the
    // Pixel History + Shader Debug tabs.
    const stateStack = ctPage.locator(".lm_stack", {
      has: ctPage.locator(".lm_tab", { hasText: "STATE" }),
    });
    await expect(
      stateStack.locator(".lm_tab", { hasText: "PIXEL HISTORY" }),
    ).toBeVisible();
    await expect(
      stateStack.locator(".lm_tab", { hasText: "SHADER DEBUG" }),
    ).toBeVisible();
  });
});
