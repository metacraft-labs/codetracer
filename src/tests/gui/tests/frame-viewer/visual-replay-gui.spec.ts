import { test, expect } from "../../lib/fixtures";

async function activateVideoPlayerTab(ctPage: any): Promise<void> {
  const tab = ctPage.locator(".lm_tab", { hasText: "VIDEO PLAYER" });
  await expect(tab).toBeVisible();
  await tab.click();
  await expect(ctPage.locator(".video-player-component")).toBeVisible();
}

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

  test("visual-capable trace opens Video Player in production layout", async ({
    ctPage,
  }) => {
    await activateVideoPlayerTab(ctPage);
    const image = ctPage.locator(".video-player-image");
    await expect(image).toBeVisible();
    await expect
      .poll(async () => (await image.getAttribute("src")) ?? "")
      .toMatch(/^data:image\/svg\+xml.*GEID/);
    await expect(ctPage.locator(".video-player-startup")).toBeHidden();
    await expect(ctPage.locator(".video-player-error")).toBeHidden();
    await expect(ctPage.locator(".video-player-scrub-range")).toHaveAttribute(
      "max",
      "3",
    );
    await expect(
      ctPage.locator(".lm_tab", { hasText: /\.(py|rb|nr)\b/ }),
    ).toBeVisible();
    await expect(ctPage.locator(".lm_tab", { hasText: "STATE" })).toBeVisible();
    await expect(
      ctPage.locator(".lm_tab", { hasText: "CALLTRACE" }),
    ).toBeVisible();
    await expect(
      ctPage.locator(".lm_tab", { hasText: "EVENT LOG" }),
    ).toBeVisible();
    await expect(
      ctPage.locator(".lm_tab", { hasText: "TERMINAL OUTPUT" }),
    ).toBeVisible();
  });

  test("e2e_step_updates_video_player", async ({ ctPage }) => {
    await activateVideoPlayerTab(ctPage);
    await expect
      .poll(async () =>
        ctPage.evaluate(
          () => typeof (window as any).__CODETRACER_TEST__?.fakeMcrStepGeid,
        ),
      )
      .toBe("function");

    const image = ctPage.locator(".video-player-image");
    await expect(image).toBeVisible();
    const before = await image.getAttribute("src");

    const frameResponse = ctPage.waitForResponse(
      (response) => response.url().includes("/frame?geid=246") && response.ok(),
    );
    await ctPage.evaluate(() =>
      (window as any).__CODETRACER_TEST__.fakeMcrStepGeid(246),
    );
    await frameResponse;

    await expect(ctPage.locator(".video-player-loading")).toBeHidden();
    await expect(ctPage.locator(".video-player-frame-label")).toContainText(
      /Frame 2\b/,
    );
    await expect(image).toBeVisible();
    await expect
      .poll(async () => {
        const src = await image.getAttribute("src");
        return !!src && src !== before && /GEID(%20| )246/.test(src);
      })
      .toBe(true);
  });

  test("e2e_pixel_history_click_navigates_source", async ({ ctPage }) => {
    await activateVideoPlayerTab(ctPage);
    await expect
      .poll(async () =>
        ctPage.evaluate(
          () => typeof (window as any).__CODETRACER_TEST__?.fakeMcrStepGeid,
        ),
      )
      .toBe("function");

    const frameResponse = ctPage.waitForResponse(
      (response) => response.url().includes("/frame?geid=246") && response.ok(),
    );
    await ctPage.evaluate(() =>
      (window as any).__CODETRACER_TEST__.fakeMcrStepGeid(246),
    );
    await frameResponse;

    const image = ctPage.locator(".video-player-image");
    await expect(image).toBeVisible();
    const imageBox = await image.boundingBox();
    expect(imageBox).not.toBeNull();
    const expectedX = 160;
    const expectedY = 90;

    const pixelHistoryResponsePromise = ctPage.waitForResponse(
      (response) =>
        response.url().includes("/pixel-history?x=") &&
        response.request().method() === "POST" &&
        response.ok(),
    );
    await ctPage.mouse.click(
      imageBox!.x + imageBox!.width / 2,
      imageBox!.y + imageBox!.height / 2,
    );
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
    await expect(ctPage.locator(".pixel-history-entry").nth(1)).toContainText(
      "GEID 220",
    );

    await ctPage.locator(".pixel-history-entry").nth(1).click();

    await expect
      .poll(async () =>
        ctPage.evaluate(() => {
          const requests =
            (window as any).__CODETRACER_TEST__?.vmBackendRequests ?? [];
          return (
            requests.findLast?.(
              (request: any) => request.command === "ct/seek-to-geid",
            ) ??
            [...requests]
              .reverse()
              .find((request: any) => request.command === "ct/seek-to-geid")
          );
        }),
      )
      .toMatchObject({ command: "ct/seek-to-geid", args: { geid: 220 } });
  });

  test("e2e_shader_debug_panel_shows_source_and_values", async ({ ctPage }) => {
    await activateVideoPlayerTab(ctPage);
    await expect
      .poll(async () =>
        ctPage.evaluate(
          () => typeof (window as any).__CODETRACER_TEST__?.fakeMcrStepGeid,
        ),
      )
      .toBe("function");

    const frameResponse = ctPage.waitForResponse(
      (response) => response.url().includes("/frame?geid=246") && response.ok(),
    );
    await ctPage.evaluate(() =>
      (window as any).__CODETRACER_TEST__.fakeMcrStepGeid(246),
    );
    await frameResponse;

    const image = ctPage.locator(".video-player-image");
    await expect(image).toBeVisible();
    const imageBox = await image.boundingBox();
    expect(imageBox).not.toBeNull();

    const shaderResponsePromise = ctPage.waitForResponse(
      (response) => response.url().includes("/shader-debug") && response.ok(),
    );
    await ctPage.mouse.click(
      imageBox!.x + imageBox!.width / 2,
      imageBox!.y + imageBox!.height / 2,
    );
    await shaderResponsePromise;

    await ctPage.locator(".lm_tab", { hasText: "SHADER DEBUG" }).click();
    await expect(ctPage.locator(".shader-debug-component")).toBeVisible();
    await expect(ctPage.locator(".shader-debug-source")).toContainText(
      "out_color",
    );
    await expect(
      ctPage.locator(".shader-debug-source-line.current"),
    ).toContainText("v_uv");
    await expect(ctPage.locator(".shader-debug-variables-table")).toContainText(
      "v_uv",
    );
    await expect(ctPage.locator(".shader-debug-registers-table")).toContainText(
      "%12",
    );

    await ctPage.locator(".shader-debug-step-forward").click();
    await expect(
      ctPage.locator(".shader-debug-source-line.current"),
    ).toContainText("base");
    await expect(ctPage.locator(".shader-debug-variables-table")).toContainText(
      "base",
    );
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
    await activateVideoPlayerTab(ctPage);
    await expect(ctPage.locator(".video-player-error")).toContainText(
      "Unable to start the visual replay player.",
    );
    await expect(
      ctPage.locator(".video-player-transport.disabled"),
    ).toBeVisible();
    await expect(ctPage.locator(".video-player-startup")).toBeHidden();
    await expect(ctPage.locator(".video-player-image")).toBeHidden();

    await expect(
      ctPage.locator(".lm_tab", { hasText: /main\.(py|nr)/ }),
    ).toBeVisible();
    await expect(ctPage.locator(".lm_tab", { hasText: "STATE" })).toBeVisible();
    await expect(
      ctPage.locator(".lm_tab", { hasText: "CALLTRACE" }),
    ).toBeVisible();
    await expect(
      ctPage.locator(".lm_tab", { hasText: "EVENT LOG" }),
    ).toBeVisible();
    await expect(
      ctPage.locator(".lm_tab", { hasText: "TERMINAL OUTPUT" }),
    ).toBeVisible();
  });
});
