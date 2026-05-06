import * as fs from "node:fs";
import * as path from "node:path";

import { test, expect } from "../../lib/fixtures";
import type { Locator, Page } from "@playwright/test";

const visualTracePath = process.env.CODETRACER_REAL_VISUAL_TRACE ?? "";
const repoRoot = path.resolve(__dirname, "..", "..", "..", "..", "..");
const outputDir = process.env.CODETRACER_BOOK_SCREENSHOT_DIR
  ?? path.join(repoRoot, "docs", "book", "src", "generated", "visual_recordings");

async function captureBookScreenshot(
  target: Page | Locator,
  fileName: string,
): Promise<void> {
  fs.mkdirSync(outputDir, { recursive: true });
  await target.screenshot({
    path: path.join(outputDir, fileName),
  });
}

test.describe("visual recording book screenshots", () => {
  test.describe.configure({ mode: "serial" });
  test.setTimeout(240_000);
  test.use({
    sourcePath: "unused-for-visual-recording-book-screenshots",
    launchMode: "trace",
    deploymentMode: "web",
    visualReplayTracePath: visualTracePath,
  });

  test.beforeEach(() => {
    delete process.env.CODETRACER_VISUAL_REPLAY_FAKE_PLAYER;
    if (!visualTracePath) {
      throw new Error("CODETRACER_REAL_VISUAL_TRACE must point to a recorded .ct trace");
    }
  });

  test("captures the visual replay workflow for the CodeTracer book", async ({ ctPage }) => {
    await ctPage.setViewportSize({ width: 1440, height: 900 });

    await expect(ctPage.locator(".lm_tab", { hasText: "FRAME VIEWER" })).toBeVisible();
    await expect(ctPage.locator(".frame-viewer-component")).toBeVisible();
    await expect(ctPage.locator(".frame-viewer-connection-status")).toContainText(
      "Visual replay connected",
      { timeout: 120_000 },
    );

    const drawCalls = ctPage.locator(".frame-viewer-draw-call");
    await expect(drawCalls.first()).toBeVisible({ timeout: 120_000 });
    await expect.poll(async () => drawCalls.count()).toBeGreaterThan(4);

    await drawCalls.nth(4).click();
    await expect(ctPage.locator(".frame-viewer-image")).toBeVisible();
    await captureBookScreenshot(ctPage.locator(".frame-viewer-body"), "frame-viewer.png");

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
    await pixelHistoryResponsePromise;
    await shaderDebugResponsePromise;

    await ctPage.locator(".lm_tab", { hasText: "PIXEL HISTORY" }).click();
    await expect(ctPage.locator(".pixel-history-component")).toBeVisible();
    await expect(ctPage.locator(".pixel-history-entry").first()).toBeVisible({
      timeout: 60_000,
    });
    await captureBookScreenshot(ctPage.locator(".pixel-history-component"), "pixel-history.png");

    await ctPage.locator(".lm_tab", { hasText: "SHADER DEBUG" }).click();
    await expect(ctPage.locator(".shader-debug-component")).toBeVisible();
    await expect(ctPage.locator(".shader-debug-source")).toContainText("fragColor");
    await captureBookScreenshot(ctPage.locator(".shader-debug-source"), "shader-debugger.png");
  });
});
