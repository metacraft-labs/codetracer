import { test, expect } from "../../lib/fixtures";

/**
 * The Video Player's keys as keymap rows, on the desktop (Input-Routing-And-
 * Keymaps.md §4.2, "A pane's modes are layers the pane owns";
 * Visual-Replay.md § Keyboard Shortcuts).
 *
 * Real key presses into the real Electron window, through the window's one
 * listener and the shared router: with the Video Player focused, `l` /
 * `Space` / `Home` / `Right` run the pane's rows; `p` turns the picker on and
 * pushes its layer, whose `Escape` turns it off; with the picker off,
 * `Escape` is not the player's.
 *
 * The one stand-in, and why it is not a mock: the player process is the
 * fixture's `CODETRACER_VISUAL_REPLAY_FAKE_PLAYER=ready`, the same one
 * `video-player-keyboard-shortcuts.spec.ts` uses; what this spec asserts is
 * where a KEY goes, which the player does not take part in.
 */

test.describe("the Video Player's keys are keymap rows", () => {
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

  test("keys reach the player's operations, Escape only while picking", async ({
    ctPage,
  }) => {
    await ctPage.locator(".lm_tab", { hasText: "VIDEO PLAYER" }).click();
    const panel = ctPage.locator(".video-player-component");
    await expect(panel).toBeVisible();
    // The pane's own element takes the focus, as a press into its body does.
    await ctPage
      .locator('[data-scope-kind="pane"][data-scope-id="videoPlayer"]')
      .first()
      .focus();
    const badge = ctPage.locator(".video-player-rate-badge");
    const frame = ctPage.locator(".video-player-frame-label");
    const trace = async () =>
      ctPage.evaluate(() => ((window as any).__ctKeyTrace || []).slice());

    await ctPage.keyboard.press("l");
    await expect(badge).toContainText("1×");
    await ctPage.keyboard.press("l");
    await expect(badge).toContainText("2×");
    await ctPage.keyboard.press("Space");
    await expect(badge).toContainText("Paused");
    await ctPage.keyboard.press("Home");
    await expect(frame).toContainText("Frame 0");
    await ctPage.keyboard.press("ArrowRight");
    await expect(frame).toContainText("Frame 1");
    expect(await trace()).toEqual(
      expect.arrayContaining([
        "video-player.fast-forward",
        "video-player.toggle-play",
        "video-player.jump-start",
        "video-player.step-frame-forward",
      ]),
    );

    // Escape with the picker off is not the player's.
    const before = (await trace()).length;
    await ctPage.keyboard.press("Escape");
    expect((await trace()).slice(before)).not.toContain(
      "video-player.cancel-picker",
    );

    // `p` turns the picker on; its layer's Escape turns it off.
    await ctPage.keyboard.press("p");
    await expect(ctPage.locator(".video-player-component.picker-active"))
      .toBeVisible();
    await ctPage.keyboard.press("Escape");
    await expect(ctPage.locator(".video-player-component.picker-active"))
      .toHaveCount(0);
    expect(await trace()).toContain("video-player.cancel-picker");
  });
});
