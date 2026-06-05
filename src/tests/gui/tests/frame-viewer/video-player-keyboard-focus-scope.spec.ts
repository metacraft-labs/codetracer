import { test, expect } from "../../lib/fixtures";

/**
 * M4 — Visual Replay keyboard focus scoping.
 *
 * The spec requires that the player keyboard shortcuts only fire when the
 * Video Player panel is focused (or the cursor is over the frame canvas).
 * This is what prevents collisions with the debugger's global step shortcuts
 * (F10 / F11) and lets arrow keys reach Monaco normally inside the source
 * editor.
 *
 * Two asserts:
 *
 *   1. With focus inside the Monaco editor (Source tab), pressing F10 must
 *      drive the debugger — i.e. it issues a ``forwardNext`` step.  We
 *      observe this via the existing ``__CODETRACER_TEST__.vmBackendRequests``
 *      log that records every command sent to the backend.
 *
 *   2. With focus inside the Monaco editor, pressing ArrowLeft must NOT
 *      perturb the Video Player VM — the player's reported frame index and
 *      pickerState stay where they were.  (Monaco itself receives the arrow
 *      key per its own bindings; the Video Player overlay returns true /
 *      undefined to let the browser deliver the key.)
 *
 * Spec: codetracer-specs/GUI/Debugging-Features/Visual-Replay.md §Keyboard
 *       Shortcuts.
 * Milestone: codetracer-specs/GUI/Debugging-Features/Visual-Replay.milestones.org M4.
 */

test.describe("MCR visual replay keyboard focus scoping", () => {
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

  test("F10 still drives the debugger when focus is in the source editor",
       async ({ ctPage }) => {
    // Bring the Video Player tab to front so its component is no longer
    // ``display: none`` (M3 additive placement leaves the editor active).
    await ctPage.locator(".lm_tab", { hasText: "VIDEO PLAYER" }).click();
    await expect(ctPage.locator(".video-player-component")).toBeVisible();
    await expect(ctPage.locator(".monaco-editor").first()).toBeVisible();

    // Focus the Monaco editor.  Clicking inside its viewport reliably
    // moves activeElement onto the editor's textarea.
    await ctPage.locator(".monaco-editor .view-lines").first().click();

    // Reset the backend request log so the F10 step is the only entry we
    // need to find.
    await ctPage.evaluate(() => {
      const t = (window as any).__CODETRACER_TEST__ ?? {};
      t.vmBackendRequests = [];
      (window as any).__CODETRACER_TEST__ = t;
    });

    // Press F10 — the debugger should issue a forward-next.
    await ctPage.keyboard.press("F10");

    await expect
      .poll(async () =>
        ctPage.evaluate(() => {
          const requests =
            (window as any).__CODETRACER_TEST__?.vmBackendRequests ?? [];
          return requests.some((r: any) =>
            typeof r.command === "string"
            && (r.command.includes("next") || r.command.includes("step")),
          );
        }),
      )
      .toBe(true);
  });

  test("ArrowLeft in the source editor does not move the Video Player frame",
       async ({ ctPage }) => {
    // Bring the Video Player tab forward; otherwise its DOM is
    // ``display: none`` per GoldenLayout and the visibility check
    // below would fail.
    await ctPage.locator(".lm_tab", { hasText: "VIDEO PLAYER" }).click();
    await expect(ctPage.locator(".video-player-component")).toBeVisible();
    await expect
      .poll(async () =>
        ctPage.evaluate(
          () => typeof (window as any).__CODETRACER_TEST__?.videoPlayerAction,
        ),
      )
      .toBe("function");

    // Position the player at a known frame via the test hook (this hook
    // bypasses focus scoping intentionally).
    await ctPage.evaluate(() =>
      (window as any).__CODETRACER_TEST__.videoPlayerAction(
        "VideoPlayerJumpStart"));
    await ctPage.evaluate(() =>
      (window as any).__CODETRACER_TEST__.videoPlayerAction(
        "VideoPlayerStepFrameForward"));
    await expect(ctPage.locator(".video-player-frame-label"))
      .toContainText("Frame 1");

    // Focus the Monaco editor.
    await ctPage.locator(".monaco-editor .view-lines").first().click();

    // Press the left arrow.  Monaco will move its caret; the Video Player
    // must NOT receive the key (focus scope check returns false because the
    // editor is focused and the cursor is not over the player canvas).
    await ctPage.keyboard.press("ArrowLeft");

    // Frame label is unchanged.
    await expect(ctPage.locator(".video-player-frame-label"))
      .toContainText("Frame 1");

    // Defensive sanity check: the player VM hook still works when invoked
    // explicitly, proving the dispatcher is alive and the static value
    // didn't drift simply because the player code path was disabled.
    await ctPage.evaluate(() =>
      (window as any).__CODETRACER_TEST__.videoPlayerAction(
        "VideoPlayerStepFrameForward"));
    await expect(ctPage.locator(".video-player-frame-label"))
      .toContainText("Frame 2");
  });
});
