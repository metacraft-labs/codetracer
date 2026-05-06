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
    await expect(ctPage.locator(".lm_tab", { hasText: /\.(py|rb|nr)\b/ })).toBeVisible();
    await expect(ctPage.locator(".lm_tab", { hasText: "STATE" })).toBeVisible();
    await expect(ctPage.locator(".lm_tab", { hasText: "CALLTRACE" })).toBeVisible();
    await expect(ctPage.locator(".lm_tab", { hasText: "EVENT LOG" })).toBeVisible();
    await expect(ctPage.locator(".lm_tab", { hasText: "TERMINAL OUTPUT" })).toBeVisible();
  });

  test("e2e_step_updates_frame_viewer", async ({ ctPage }) => {
    await expect(ctPage.locator(".frame-viewer-component")).toBeVisible();
    await expect(ctPage.locator(".frame-viewer-connection-status")).toContainText(
      "Visual replay connected",
    );
    await expect(ctPage.locator(".frame-viewer-player-url")).toContainText(
      "http://127.0.0.1:",
    );
    await expect
      .poll(async () =>
        ctPage.evaluate(() => typeof (window as any).__CODETRACER_TEST__?.fakeMcrStepGeid),
      )
      .toBe("function");

    const image = ctPage.locator(".frame-viewer-image");
    const before = await image.getAttribute("src");

    const frameResponse = ctPage.waitForResponse(
      (response) => response.url().includes("/frame?geid=246") && response.ok(),
    );
    await ctPage.evaluate(() => (window as any).__CODETRACER_TEST__.fakeMcrStepGeid(246));
    await frameResponse;

    await expect(ctPage.locator(".frame-viewer-loading")).toBeHidden();
    await expect(ctPage.locator(".frame-viewer-frame-label")).toContainText("GEID 246");
    await expect(image).toBeVisible();
    await expect
      .poll(async () => {
        const src = await image.getAttribute("src");
        return !!src && src !== before && /GEID(%20| )246/.test(src);
      })
      .toBe(true);
  });

  test("e2e_pixel_history_click_navigates_source", async ({ ctPage }) => {
    await expect(ctPage.locator(".frame-viewer-component")).toBeVisible();
    await expect
      .poll(async () =>
        ctPage.evaluate(() => typeof (window as any).__CODETRACER_TEST__?.fakeMcrStepGeid),
      )
      .toBe("function");

    const frameResponse = ctPage.waitForResponse(
      (response) => response.url().includes("/frame?geid=246") && response.ok(),
    );
    await ctPage.evaluate(() => (window as any).__CODETRACER_TEST__.fakeMcrStepGeid(246));
    await frameResponse;

    const image = ctPage.locator(".frame-viewer-image");
    const imageBox = await image.boundingBox();
    expect(imageBox).not.toBeNull();
    const clickPosition = { x: imageBox!.width / 2, y: imageBox!.height / 2 };
    const expectedX = 160;
    const expectedY = 90;

    const pixelHistoryResponsePromise = ctPage.waitForResponse(
      (response) => response.url().includes("/pixel-history?x=") && response.ok(),
    );
    await image.click({ position: clickPosition });
    const pixelHistoryResponse = await pixelHistoryResponsePromise;
    const pixelHistoryUrl = new URL(pixelHistoryResponse.url());
    const requestedX = Number(pixelHistoryUrl.searchParams.get("x"));
    const requestedY = Number(pixelHistoryUrl.searchParams.get("y"));
    expect(Math.abs(requestedX - expectedX)).toBeLessThanOrEqual(1);
    expect(Math.abs(requestedY - expectedY)).toBeLessThanOrEqual(1);
    expect(pixelHistoryUrl.searchParams.get("frame")).toBe("2");

    await ctPage.locator(".lm_tab", { hasText: "PIXEL HISTORY" }).click();
    await expect(ctPage.locator(".pixel-history-component")).toBeVisible();
    await expect(ctPage.locator(".pixel-history-entry")).toHaveCount(2);
    await expect(ctPage.locator(".pixel-history-entry").nth(1)).toContainText("GEID 220");

    await ctPage.locator(".pixel-history-entry").nth(1).click();

    await expect
      .poll(async () =>
        ctPage.evaluate(() => {
          const requests = (window as any).__CODETRACER_TEST__?.vmBackendRequests ?? [];
          return requests.findLast?.((request: any) => request.command === "ct/seek-to-geid")
            ?? [...requests].reverse().find((request: any) => request.command === "ct/seek-to-geid");
        }),
      )
      .toMatchObject({ command: "ct/seek-to-geid", args: { geid: 220 } });
  });

  test("e2e_shader_debug_panel_shows_source_and_values", async ({ ctPage }) => {
    await expect(ctPage.locator(".frame-viewer-component")).toBeVisible();
    await expect
      .poll(async () =>
        ctPage.evaluate(() => typeof (window as any).__CODETRACER_TEST__?.fakeMcrStepGeid),
      )
      .toBe("function");

    const frameResponse = ctPage.waitForResponse(
      (response) => response.url().includes("/frame?geid=246") && response.ok(),
    );
    await ctPage.evaluate(() => (window as any).__CODETRACER_TEST__.fakeMcrStepGeid(246));
    await frameResponse;

    const image = ctPage.locator(".frame-viewer-image");
    const imageBox = await image.boundingBox();
    expect(imageBox).not.toBeNull();

    const shaderResponsePromise = ctPage.waitForResponse(
      (response) => response.url().includes("/shader-debug") && response.ok(),
    );
    await image.click({ position: { x: imageBox!.width / 2, y: imageBox!.height / 2 } });
    await shaderResponsePromise;

    await ctPage.locator(".lm_tab", { hasText: "SHADER DEBUG" }).click();
    await expect(ctPage.locator(".shader-debug-component")).toBeVisible();
    await expect(ctPage.locator(".shader-debug-source")).toContainText("out_color");
    await expect(ctPage.locator(".shader-debug-source-line.current")).toContainText(
      "v_uv",
    );
    await expect(ctPage.locator(".shader-debug-variables-table")).toContainText("v_uv");
    await expect(ctPage.locator(".shader-debug-registers-table")).toContainText("%12");

    await ctPage.locator(".shader-debug-step-forward").click();
    await expect(ctPage.locator(".shader-debug-source-line.current")).toContainText(
      "base",
    );
    await expect(ctPage.locator(".shader-debug-variables-table")).toContainText("base");
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
