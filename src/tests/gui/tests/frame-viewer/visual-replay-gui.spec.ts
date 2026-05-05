import { test, expect } from "../../lib/fixtures";

test.describe("MCR visual replay real GUI layout", () => {
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

  test("visual-capable trace opens Frame Viewer in production layout", async ({ ctPage }) => {
    await expect(ctPage.locator(".lm_tab", { hasText: "FRAME VIEWER" })).toBeVisible();
    await expect(ctPage.locator(".frame-viewer-component")).toBeVisible();
    await expect(ctPage.locator(".frame-viewer-connection-status")).toContainText(
      "Visual replay connected",
    );
    await expect(ctPage.locator(".frame-viewer-player-url")).toContainText(
      "http://127.0.0.1:",
    );
    await expect(ctPage.locator(".lm_tab", { hasText: /main\.(py|nr)/ })).toBeVisible();
    await expect(ctPage.locator(".lm_tab", { hasText: "STATE" })).toBeVisible();
    await expect(ctPage.locator(".lm_tab", { hasText: "CALLTRACE" })).toBeVisible();
    await expect(ctPage.locator(".lm_tab", { hasText: "EVENT LOG" })).toBeVisible();
    await expect(ctPage.locator(".lm_tab", { hasText: "TERMINAL OUTPUT" })).toBeVisible();
  });
});

test.describe("MCR visual replay player failure", () => {
  test.describe.configure({ mode: "serial" });
  test.setTimeout(120_000);
  test.use({
    sourcePath: "py_console_logs/main.py",
    launchMode: "trace",
    deploymentMode: "web",
    visualReplayTrace: true,
  });

  test.beforeEach(() => {
    process.env.CODETRACER_VISUAL_REPLAY_FAKE_PLAYER = "fail";
  });

  test.afterEach(() => {
    delete process.env.CODETRACER_VISUAL_REPLAY_FAKE_PLAYER;
  });

  test("e2e_visual_player_failure_shows_status_error", async ({ ctPage }) => {
    await expect(ctPage.locator(".lm_tab", { hasText: "FRAME VIEWER" })).toBeVisible();
    await expect(ctPage.locator(".frame-viewer-component")).toBeVisible();
    await expect(ctPage.locator(".frame-viewer-connection-status")).toContainText(
      "Visual replay not connected",
    );
    await expect(ctPage.locator(".frame-viewer-error")).toContainText(
      "Unable to start the visual replay player.",
    );

    await expect(ctPage.locator(".lm_tab", { hasText: /main\.(py|nr)/ })).toBeVisible();
    await expect(ctPage.locator(".lm_tab", { hasText: "STATE" })).toBeVisible();
    await expect(ctPage.locator(".lm_tab", { hasText: "CALLTRACE" })).toBeVisible();
    await expect(ctPage.locator(".lm_tab", { hasText: "EVENT LOG" })).toBeVisible();
    await expect(ctPage.locator(".lm_tab", { hasText: "TERMINAL OUTPUT" })).toBeVisible();
  });
});
