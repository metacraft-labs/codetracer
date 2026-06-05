import { test, expect } from "../../lib/fixtures";

/**
 * M4 — Visual Replay keyboard shortcuts (in-scope).
 *
 * Verifies every shortcut documented in the spec drives the matching
 * VideoPlayerVM transition when the Video Player panel is focused (or the
 * cursor is hovering its frame canvas).
 *
 * The Playwright hook ``window.__CODETRACER_TEST__.videoPlayerAction`` —
 * installed by ``ui/video_player.nim`` when ``startOptions.inTest`` is true —
 * bypasses focus scoping so the spec doesn't depend on a real focused +
 * hovered Video Player.  Focus scoping itself is verified separately by
 * ``video-player-keyboard-focus-scope.spec.ts``.
 *
 * Spec: codetracer-specs/GUI/Debugging-Features/Visual-Replay.md §Keyboard
 *       Shortcuts.
 * Milestone: codetracer-specs/GUI/Debugging-Features/Visual-Replay.milestones.org M4.
 */

test.describe("MCR visual replay keyboard shortcuts", () => {
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

  test("video-player/keyboard-shortcuts drive the VM", async ({ ctPage }) => {
    // Wait for the Video Player panel and the test hook to exist.
    await expect(ctPage.locator(".video-player-component")).toBeVisible();
    await expect
      .poll(async () =>
        ctPage.evaluate(
          () => typeof (window as any).__CODETRACER_TEST__?.videoPlayerAction,
        ),
      )
      .toBe("function");

    const invoke = async (name: string) =>
      ctPage.evaluate(
        (action) =>
          (window as any).__CODETRACER_TEST__.videoPlayerAction(action),
        name,
      );

    // Play / pause via Space / K.
    expect(await invoke("VideoPlayerTogglePlay")).toBeTruthy();
    await expect(ctPage.locator(".video-player-rate-badge")).toContainText(/[▶◀]/);
    expect(await invoke("VideoPlayerTogglePlay")).toBeTruthy();
    await expect(ctPage.locator(".video-player-rate-badge")).toContainText("Paused");

    // Fast forward: 1× → 2× → 4× → 8× → wrap to 1×.
    await invoke("VideoPlayerFastForward");
    await expect(ctPage.locator(".video-player-rate-badge")).toContainText("1×");
    await invoke("VideoPlayerFastForward");
    await expect(ctPage.locator(".video-player-rate-badge")).toContainText("2×");
    await invoke("VideoPlayerFastForward");
    await expect(ctPage.locator(".video-player-rate-badge")).toContainText("4×");
    await invoke("VideoPlayerFastForward");
    await expect(ctPage.locator(".video-player-rate-badge")).toContainText("8×");
    await invoke("VideoPlayerFastForward");
    await expect(ctPage.locator(".video-player-rate-badge")).toContainText("1×");

    // Rewind flips direction.
    await invoke("VideoPlayerRewind");
    await expect(ctPage.locator(".video-player-rate-badge")).toContainText("◀");

    // Pause to enable frame stepping.
    await invoke("VideoPlayerTogglePlay");
    await expect(ctPage.locator(".video-player-rate-badge")).toContainText("Paused");

    // Jump to start.
    await invoke("VideoPlayerJumpStart");
    await expect(ctPage.locator(".video-player-frame-label")).toContainText("Frame 0");

    // Step frame forward / back.
    await invoke("VideoPlayerStepFrameForward");
    await expect(ctPage.locator(".video-player-frame-label")).toContainText("Frame 1");
    await invoke("VideoPlayerStepFrameBack");
    await expect(ctPage.locator(".video-player-frame-label")).toContainText("Frame 0");

    // Draw call stepping is exercised against a backed fixture; we only
    // assert the hook returns a consumption signal (the call itself does not
    // raise and the frame label may or may not change depending on the
    // fixture's draw-call wiring).
    expect(await invoke("VideoPlayerStepDrawForward")).toBeTruthy();
    expect(await invoke("VideoPlayerStepDrawBack")).toBeTruthy();

    // Jump to end clamps to the last frame.
    await invoke("VideoPlayerJumpEnd");
    await expect(ctPage.locator(".video-player-frame-label"))
      .toContainText(/Frame \d+/);

    // Picker mode: toggle, the canvas overlay should switch into the
    // .picker class state.
    await invoke("VideoPlayerTogglePicker");
    await expect(ctPage.locator(".video-player-component.picker-active"))
      .toBeVisible();

    // Cancel picker via Esc-equivalent — VideoPlayerCancelPicker returns
    // ``true`` (consumed) when picker is active.
    expect(await invoke("VideoPlayerCancelPicker")).toBeTruthy();
    await expect(ctPage.locator(".video-player-component.picker-active"))
      .toHaveCount(0);

    // After cancel, the ClientAction must report fall-through (false) so
    // the global Esc binding can still drive ``aEscape``.
    expect(await invoke("VideoPlayerCancelPicker")).toBeFalsy();
  });
});
