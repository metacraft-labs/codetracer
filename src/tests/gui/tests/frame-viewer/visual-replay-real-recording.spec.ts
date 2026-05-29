import { test, expect } from "../../lib/fixtures";
import { resolveRealVisualTracePath } from "../../lib/real-visual-trace";

const visualTracePath = resolveRealVisualTracePath();

test.describe("MCR visual replay real recording GUI integration", () => {
  test.describe.configure({ mode: "serial" });
  test.setTimeout(240_000);
  test.use({
    sourcePath: "unused-for-real-visual-trace",
    launchMode: "trace",
    deploymentMode: "web",
    visualReplayTracePath: visualTracePath,
  });

  test.beforeEach(() => {
    delete process.env.CODETRACER_VISUAL_REPLAY_FAKE_PLAYER;
  });

  test("recorded GL trace supports GUI scrubbing and pixel-level debugging", async ({ ctPage }) => {
    await expect(ctPage.locator(".lm_tab", { hasText: "FRAME VIEWER" })).toBeVisible();
    await expect(ctPage.locator(".frame-viewer-component")).toBeVisible();
    await expect(ctPage.locator(".frame-viewer-connection-status")).toContainText(
      "Visual replay connected",
      { timeout: 120_000 },
    );
    await expect(ctPage.locator(".frame-viewer-player-url")).toContainText(
      "http://127.0.0.1:",
    );

    const drawCalls = ctPage.locator(".frame-viewer-draw-call");
    await expect(drawCalls.first()).toBeVisible({ timeout: 120_000 });
    await expect.poll(async () => drawCalls.count()).toBeGreaterThan(4);

    const firstImageSrc = await ctPage.locator(".frame-viewer-image").getAttribute("src");
    const scrubResponse = ctPage.waitForResponse(
      (response) => response.url().includes("/frame?draw=") && response.ok(),
    );
    await drawCalls.nth(4).click();
    await scrubResponse;
    await expect(ctPage.locator(".frame-viewer-image")).toBeVisible();
    await expect
      .poll(async () => ctPage.locator(".frame-viewer-image").getAttribute("src"))
      .not.toBe(firstImageSrc);

    const image = ctPage.locator(".frame-viewer-image");
    const imageBox = await image.boundingBox();
    expect(imageBox).not.toBeNull();

    const pixelHistoryResponsePromise = ctPage.waitForResponse(
      (response) =>
        response.url().includes("/pixel-history")
        && response.request().method() === "POST"
        && response.ok(),
    );
    const shaderDebugResponsePromise = ctPage.waitForResponse(
      (response) =>
        response.url().includes("/shader-debug")
        && response.request().method() === "POST"
        && response.ok(),
    );
    await image.click({
      position: {
        x: imageBox!.width * 0.25,
        y: imageBox!.height * 0.25,
      },
    });
    const pixelHistoryResponse = await pixelHistoryResponsePromise;
    const pixelHistoryPayload = await pixelHistoryResponse.json();
    expect(Array.isArray(pixelHistoryPayload)).toBe(true);
    expect(pixelHistoryPayload.length).toBeGreaterThan(0);
    const shaderDebugResponse = await shaderDebugResponsePromise;
    const shaderDebugPayload = await shaderDebugResponse.json();
    expect(
      shaderDebugPayload.fragmentShaderSource
        ?? shaderDebugPayload.shaderSource
        ?? shaderDebugPayload.source,
    ).toContain("fragColor");

    await ctPage.locator(".lm_tab", { hasText: "PIXEL HISTORY" }).click();
    await expect(ctPage.locator(".pixel-history-component")).toBeVisible();
    await expect(ctPage.locator(".pixel-history-entry").first()).toBeVisible({
      timeout: 60_000,
    });

    await ctPage.locator(".lm_tab", { hasText: "SHADER DEBUG" }).click();
    await expect(ctPage.locator(".shader-debug-component")).toBeVisible();
    await expect(ctPage.locator(".shader-debug-source")).toBeVisible();
    await expect(ctPage.locator(".shader-debug-source")).toContainText("fragColor");
  });
});
