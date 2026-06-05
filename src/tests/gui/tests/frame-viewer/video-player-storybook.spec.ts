import { test, expect } from "../../lib/fixtures";

/**
 * M5 — Visual Replay Video Player storybook screenshots.
 *
 * Six deterministic scenarios are driven into the live Video Player
 * panel through the ``__CODETRACER_TEST__.videoPlayerSetState`` hook
 * installed by ``ui/video_player.nim``.  Each scenario renders a
 * single pixel-stable state and we snapshot it via Playwright's
 * built-in ``toHaveScreenshot`` visual diff.
 *
 * Why this shape (and not Storybook-static):
 *  - The Nim renderer mounts directly into the Electron page; there is
 *    no separate Storybook story for the Video Player panel.  Driving
 *    the same VM the production code uses preserves end-to-end
 *    fidelity and keeps the diff harness honest about the actual
 *    DOM and CSS the user sees.
 *  - The hook just sets signal values; there is no fake client and no
 *    fake fetch latency math, so the visuals are exactly what the
 *    production view emits.
 *
 * Theme coverage: dark theme is the default and the only one the live
 * Electron harness ships with under the ``ctPage`` fixture today.  The
 * spec explicitly mentions light-theme screenshots; that requires a
 * theme toggle the test harness does not expose yet — tracked as a
 * follow-up in Visual-Replay.milestones.org.
 *
 * Spec: codetracer-specs/GUI/Debugging-Features/Visual-Replay.md
 *       §Status Indicators / §Frame Rate and Buffering.
 * Milestone: codetracer-specs/GUI/Debugging-Features/Visual-Replay.milestones.org M5.
 */

interface VideoPlayerScenario {
  playState?: "playing" | "paused";
  rate?: 1 | 2 | 4 | 8;
  direction?: "forward" | "reverse";
  buffering?: boolean;
  picker?: boolean;
  currentFrame?: number;
  frameCount?: number;
  error?: string;
  imageSrc?: string;
  visualReplayAvailable?: boolean;
  playerUrl?: string;
}

// A tiny coloured PNG we feed as the frame image so each story renders
// the same visuals across runs without depending on the fake fixture.
// 4×4 grey square, base64-encoded.
const STUB_FRAME =
  "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAQAAAAECAYAAACp8Z5+AAAAFklEQVQIW2P8z8DwnwEEGNFEYRwQDQAxYwL/r3FfggAAAABJRU5ErkJggg==";

test.describe("Visual Replay Video Player storybook", () => {
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

  async function withScenario(
    ctPage: any,
    scenario: VideoPlayerScenario,
  ): Promise<void> {
    // Wait for the panel and the hook.
    await expect(ctPage.locator(".video-player-component")).toBeVisible();
    await expect
      .poll(async () =>
        ctPage.evaluate(
          () => typeof (window as any).__CODETRACER_TEST__?.videoPlayerSetState,
        ),
      )
      .toBe("function");

    await ctPage.evaluate(
      (s: VideoPlayerScenario) =>
        (window as any).__CODETRACER_TEST__.videoPlayerSetState(s),
      scenario,
    );

    // Let the reactive effects settle so the snapshot captures the
    // post-update DOM rather than the intermediate frame.
    await ctPage.waitForTimeout(150);
  }

  async function snapshot(ctPage: any, name: string): Promise<void> {
    const panel = ctPage.locator(".video-player-component");
    await expect(panel).toHaveScreenshot(`${name}.png`, {
      // Allow a small per-pixel drift to absorb font-rendering jitter
      // across hosts.  The structural elements (spinner, error
      // badge, buffering dot) are large enough that real regressions
      // still trip the diff well above this floor.
      maxDiffPixelRatio: 0.02,
      animations: "disabled",
    });
  }

  test("paused state shows controls and the Paused badge", async ({ ctPage }) => {
    await withScenario(ctPage, {
      playState: "paused",
      rate: 1,
      direction: "forward",
      buffering: false,
      picker: false,
      currentFrame: 42,
      frameCount: 600,
      imageSrc: STUB_FRAME,
      visualReplayAvailable: true,
      playerUrl: "http://stub/",
    });
    await expect(ctPage.locator(".video-player-rate-badge")).toContainText(
      "Paused",
    );
    await snapshot(ctPage, "video-player-paused");
  });

  test("playing 1x shows the forward arrow and 1x badge", async ({ ctPage }) => {
    await withScenario(ctPage, {
      playState: "playing",
      rate: 1,
      direction: "forward",
      buffering: false,
      picker: false,
      currentFrame: 100,
      frameCount: 600,
      imageSrc: STUB_FRAME,
      visualReplayAvailable: true,
      playerUrl: "http://stub/",
    });
    await expect(ctPage.locator(".video-player-rate-badge")).toContainText("1×");
    await snapshot(ctPage, "video-player-playing-1x");
  });

  test("playing 8x shows the rate badge at 8x", async ({ ctPage }) => {
    await withScenario(ctPage, {
      playState: "playing",
      rate: 8,
      direction: "forward",
      buffering: false,
      picker: false,
      currentFrame: 250,
      frameCount: 600,
      imageSrc: STUB_FRAME,
      visualReplayAvailable: true,
      playerUrl: "http://stub/",
    });
    await expect(ctPage.locator(".video-player-rate-badge")).toContainText("8×");
    await snapshot(ctPage, "video-player-playing-8x");
  });

  test("picker active draws the blue ring and pressed picker button", async ({
    ctPage,
  }) => {
    await withScenario(ctPage, {
      playState: "paused",
      rate: 1,
      direction: "forward",
      buffering: false,
      picker: true,
      currentFrame: 142,
      frameCount: 600,
      imageSrc: STUB_FRAME,
      visualReplayAvailable: true,
      playerUrl: "http://stub/",
    });
    await expect(
      ctPage.locator(".video-player-component.picker-active"),
    ).toBeVisible();
    await expect(
      ctPage.locator(".video-player-picker.pressed"),
    ).toBeVisible();
    await snapshot(ctPage, "video-player-picker-active");
  });

  test("player error renders the red bottom-left banner and disables controls", async ({
    ctPage,
  }) => {
    await withScenario(ctPage, {
      playState: "paused",
      currentFrame: 0,
      frameCount: 0,
      error: "ct_gfx_player exited with status 1",
      visualReplayAvailable: true,
      playerUrl: "http://stub/",
    });
    await expect(ctPage.locator(".video-player-error")).toBeVisible();
    await expect(ctPage.locator(".video-player-transport.disabled")).toBeVisible();
    await snapshot(ctPage, "video-player-error");
  });

  test("buffering active shows the yellow dot next to the rate badge", async ({
    ctPage,
  }) => {
    await withScenario(ctPage, {
      playState: "playing",
      rate: 2,
      direction: "forward",
      buffering: true,
      picker: false,
      currentFrame: 320,
      frameCount: 600,
      imageSrc: STUB_FRAME,
      visualReplayAvailable: true,
      playerUrl: "http://stub/",
    });
    await expect(ctPage.locator(".video-player-buffering")).toBeVisible();
    await snapshot(ctPage, "video-player-buffering");
  });
});
