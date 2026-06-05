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
 * Theme coverage (M5-followup: light-theme storybook coverage)
 * ------------------------------------------------------------
 *  - Dark theme is the default and the only one the production
 *    Electron host currently ships.  The dark ``test.describe`` block
 *    mirrors the original M5 suite.
 *  - Light theme is exercised via the
 *    ``__CODETRACER_TEST__.setTheme("light")`` hook installed by
 *    ``ui/video_player.nim`` when ``data.startOptions.inTest``.  The
 *    hook adds ``theme-light`` to ``<body>``; the CSS-variable
 *    override block at the bottom of
 *    ``styles/components/video_player.styl`` swaps the chrome colours
 *    at runtime — no Stylus rebuild required.
 *  - Snapshot baselines live under
 *    ``video-player-storybook.spec.ts-snapshots/`` with ``dark/`` and
 *    ``light/`` subfolders; regenerate with
 *    ``just test-gui --update-snapshots video-player-storybook``.
 *
 * Spec: codetracer-specs/GUI/Debugging-Features/Visual-Replay.md
 *       §Status Indicators / §Frame Rate and Buffering.
 * Milestone: codetracer-specs/GUI/Debugging-Features/Visual-Replay.milestones.org M5
 *            and M5-followup: light-theme storybook coverage.
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

type ThemeName = "dark" | "light";

// A tiny coloured PNG we feed as the frame image so each story renders
// the same visuals across runs without depending on the fake fixture.
// 4×4 grey square, base64-encoded.
const STUB_FRAME =
  "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAQAAAAECAYAAACp8Z5+AAAAFklEQVQIW2P8z8DwnwEEGNFEYRwQDQAxYwL/r3FfggAAAABJRU5ErkJggg==";

async function activateVideoPlayerTab(ctPage: any): Promise<void> {
  // GoldenLayout marks inactive stack siblings ``display: none``.  The
  // Video Player tab is appended after the editor (M3 additive placement)
  // so the editor is the active tab.  Click the tab to bring the player
  // forward — once it's the active tab in its stack, the storybook
  // snapshots capture an actually-visible component instead of an empty
  // hidden div.
  const tab = ctPage.locator(".lm_tab", { hasText: "VIDEO PLAYER" });
  await expect(tab).toBeVisible();
  // GoldenLayout overlays a close-X on the right of each tab; for tabs
  // with long titles ("VIDEO PLAYER") the close button covers most of
  // the click area.  Aim at the left edge so the title — not the
  // close-X — receives the click.
  await tab.click({ position: { x: 6, y: 8 } });

  // The default test layout places the Video Player in the FILES stack
  // (the editor-stack heuristic falls through because the bundled
  // layout has no editor entry — see ``visual_replay_layout.nim``
  // §addVisualReplayTabs documentation).  That stack is only ~254 px
  // wide, which is enough for the tab strip but causes the transport
  // bar to overflow horizontally — ``overflow: hidden`` on the player
  // root clips the rate badge / buffering dot off-screen, which
  // breaks both ``toBeVisible`` assertions and ``toHaveScreenshot``.
  // Pin the panel into a fixed-position overlay sized to fit the
  // entire transport bar so the snapshots capture the production
  // chrome (rate badge, buffering dot) instead of a narrow strip.
  // Test-only tweak; the production placement is unaffected.
  await ctPage.evaluate(() => {
    const panel = document.querySelector(".video-player-component") as HTMLElement | null;
    if (!panel) return;
    panel.style.position = "fixed";
    panel.style.top = "60px";
    panel.style.left = "20px";
    panel.style.width = "1200px";
    panel.style.height = "640px";
    panel.style.zIndex = "9999";
    panel.style.background = "#1e1e1e";
    // Make sure the inner flex children re-flow against the new
    // 1200 px width.  Without these explicit ``minWidth`` hints the
    // transport bar honours its original 254 px host stack and the
    // rate badge / buffering dot stay clipped.
    const stage = panel.querySelector(".video-player-stage") as HTMLElement | null;
    if (stage) stage.style.minWidth = "1180px";
    const transport = panel.querySelector(".video-player-transport") as HTMLElement | null;
    if (transport) transport.style.minWidth = "1180px";
    const scrubber = panel.querySelector(".video-player-scrubber") as HTMLElement | null;
    if (scrubber) scrubber.style.minWidth = "1180px";
  });
  await ctPage.waitForTimeout(150);
}

async function applyTheme(ctPage: any, theme: ThemeName): Promise<void> {
  // The ``setTheme`` hook is installed alongside the Video Player VM
  // when ``data.startOptions.inTest`` (see ``ui/video_player.nim``),
  // so the panel must be visible before the hook is callable.  Wait
  // for the hook here too — this is the place each spec block lands
  // first, well before ``videoPlayerSetState`` is needed.
  await expect
    .poll(async () =>
      ctPage.evaluate(
        () => typeof (window as any).__CODETRACER_TEST__?.setTheme,
      ),
    )
    .toBe("function");
  await ctPage.evaluate(
    (name: ThemeName) => (window as any).__CODETRACER_TEST__.setTheme(name),
    theme,
  );
}

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

async function snapshot(
  ctPage: any,
  theme: ThemeName,
  name: string,
): Promise<void> {
  const panel = ctPage.locator(".video-player-component");
  await expect(panel).toHaveScreenshot([theme, `${name}.png`], {
    // Allow a small per-pixel drift to absorb font-rendering jitter
    // across hosts.  The structural elements (spinner, error
    // badge, buffering dot) are large enough that real regressions
    // still trip the diff well above this floor.
    maxDiffPixelRatio: 0.02,
    animations: "disabled",
  });
}

// The six scenarios — extracted into a fixture-style table so both
// the dark and light describe blocks share the same source of truth.
// Adding or tweaking a scenario only needs to land here; both themes
// pick the change up automatically.
const SCENARIOS: ReadonlyArray<{
  name: string;
  description: string;
  state: VideoPlayerScenario;
  assertions?: (ctPage: any) => Promise<void>;
}> = [
  {
    name: "video-player-paused",
    description: "paused state shows controls and the Paused badge",
    state: {
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
    },
    assertions: async (ctPage: any) => {
      await expect(ctPage.locator(".video-player-rate-badge")).toContainText(
        "Paused",
      );
    },
  },
  {
    name: "video-player-playing-1x",
    description: "playing 1x shows the forward arrow and 1x badge",
    state: {
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
    },
    assertions: async (ctPage: any) => {
      await expect(ctPage.locator(".video-player-rate-badge")).toContainText(
        "1×",
      );
    },
  },
  {
    name: "video-player-playing-8x",
    description: "playing 8x shows the rate badge at 8x",
    state: {
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
    },
    assertions: async (ctPage: any) => {
      await expect(ctPage.locator(".video-player-rate-badge")).toContainText(
        "8×",
      );
    },
  },
  {
    name: "video-player-picker-active",
    description:
      "picker active draws the blue ring and pressed picker button",
    state: {
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
    },
    assertions: async (ctPage: any) => {
      await expect(
        ctPage.locator(".video-player-component.picker-active"),
      ).toBeVisible();
      await expect(
        ctPage.locator(".video-player-picker.pressed"),
      ).toBeVisible();
    },
  },
  {
    name: "video-player-error",
    description:
      "player error renders the red bottom-left banner and disables controls",
    state: {
      playState: "paused",
      currentFrame: 0,
      frameCount: 0,
      error: "ct_gfx_player exited with status 1",
      visualReplayAvailable: true,
      playerUrl: "http://stub/",
    },
    assertions: async (ctPage: any) => {
      await expect(ctPage.locator(".video-player-error")).toBeVisible();
      await expect(
        ctPage.locator(".video-player-transport.disabled"),
      ).toBeVisible();
    },
  },
  {
    name: "video-player-buffering",
    description:
      "buffering active shows the yellow dot next to the rate badge",
    state: {
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
    },
    assertions: async (ctPage: any) => {
      await expect(ctPage.locator(".video-player-buffering")).toBeVisible();
    },
  },
];

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

  // Dark theme is the default the Electron host loads — no setTheme
  // call needed here, but we still apply it explicitly so a stray
  // ``theme-light`` left over from a previous serial test in the
  // same worker cannot leak into the dark snapshots.
  test.describe("dark theme", () => {
    for (const scenario of SCENARIOS) {
      test(scenario.description, async ({ ctPage }) => {
        await activateVideoPlayerTab(ctPage);
        await expect(ctPage.locator(".video-player-component")).toBeVisible();
        await applyTheme(ctPage, "dark");
        await withScenario(ctPage, scenario.state);
        if (scenario.assertions) {
          await scenario.assertions(ctPage);
        }
        await snapshot(ctPage, "dark", scenario.name);
      });
    }
  });

  // Light theme flips the ``theme-light`` class on ``<body>`` via the
  // M5-followup test hook; the CSS-variable override block in
  // ``styles/components/video_player.styl`` swaps the chrome colours
  // and the same six scenarios snapshot under ``light/<name>.png``.
  test.describe("light theme", () => {
    for (const scenario of SCENARIOS) {
      test(scenario.description, async ({ ctPage }) => {
        await activateVideoPlayerTab(ctPage);
        await expect(ctPage.locator(".video-player-component")).toBeVisible();
        await applyTheme(ctPage, "light");
        await withScenario(ctPage, scenario.state);
        if (scenario.assertions) {
          await scenario.assertions(ctPage);
        }
        await snapshot(ctPage, "light", scenario.name);
      });
    }
  });
});
