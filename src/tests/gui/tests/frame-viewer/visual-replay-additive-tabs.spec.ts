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
    // GoldenLayout mounts every tab in the stack but only makes the active
    // one ``display: block`` — the others get ``display: none``.  We assert
    // DOM presence on the component (additive placement was done) and the
    // tab itself is visible because it is rendered in the tab strip.
    await expect(ctPage.locator(".lm_tab", { hasText: "VIDEO PLAYER" })).toBeVisible();
    await expect(ctPage.locator(".video-player-component")).toHaveCount(1);

    // The state-view tabs that were inserted alongside the Video Player.
    await expect(ctPage.locator(".lm_tab", { hasText: "PIXEL HISTORY" })).toBeVisible();
    await expect(ctPage.locator(".lm_tab", { hasText: "SHADER DEBUG" })).toBeVisible();

    // The user's existing layout must NOT have been clobbered: the standard
    // editor / state / calltrace / event-log / terminal panes must all be
    // intact.  This is what distinguishes additive insertion from the
    // pre-M3 replacement layout, where these panes were re-arranged into a
    // visual-replay-specific configuration.
    await expect(ctPage.locator(".lm_tab", { hasText: /\.(py|rb|nr)\b/ })).toBeVisible();
    await expect(ctPage.locator(".lm_tab", { hasText: "VARIABLES" })).toBeVisible();
    await expect(ctPage.locator(".lm_tab", { hasText: "CALLTRACE" })).toBeVisible();
    await expect(ctPage.locator(".lm_tab", { hasText: "EVENT LOG" })).toBeVisible();
    await expect(ctPage.locator(".lm_tab", { hasText: "TERMINAL OUTPUT" })).toBeVisible();

    // The Frame Viewer pane was retired — its tab must not exist anymore.
    await expect(ctPage.locator(".lm_tab", { hasText: "FRAME VIEWER" })).toHaveCount(0);

    // The additive insertion places Video Player in a stack that contains an
    // "editor-ish" host pane (``visual_replay_layout.nim
    // §stackContainsEditorContent``). The bundled default layout has no editor
    // entry when the walker runs (editor tabs appear when a file opens), so
    // Video Player takes the documented fallback: the stack Pixel History and
    // Shader Debug go to, which is the State stack in preference to the sidebar
    // (``§addVisualReplayTabs``). All three therefore share the VARIABLES stack.
    const stateStack = ctPage.locator(".lm_stack", {
      has: ctPage.locator(".lm_tab", { hasText: "VARIABLES" }),
    });
    await expect(
      stateStack.locator(".lm_tab", { hasText: "VIDEO PLAYER" }),
    ).toHaveCount(1);
    await expect(
      stateStack.locator(".lm_tab", { hasText: "PIXEL HISTORY" }),
    ).toHaveCount(1);
    await expect(
      stateStack.locator(".lm_tab", { hasText: "SHADER DEBUG" }),
    ).toHaveCount(1);

    // The Video Player tab still exists exactly once in the layout —
    // additivity is idempotent (``appendTabIfMissing``) even when the
    // walker re-fires.
    await expect(
      ctPage.locator(".lm_tab", { hasText: "VIDEO PLAYER" }),
    ).toHaveCount(1);
  });
});
