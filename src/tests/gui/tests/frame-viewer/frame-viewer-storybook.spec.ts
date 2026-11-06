import * as fs from "node:fs";
import * as http from "node:http";
import * as path from "node:path";
import { test, expect, type Page } from "@playwright/test";

const repoRoot = path.resolve(__dirname, "../../../../..");
const staticRoot = path.join(repoRoot, "storybook", "storybook-static");

function contentType(filePath: string): string {
  if (filePath.endsWith(".html")) return "text/html";
  if (filePath.endsWith(".js")) return "text/javascript";
  if (filePath.endsWith(".css")) return "text/css";
  if (filePath.endsWith(".json")) return "application/json";
  if (filePath.endsWith(".svg")) return "image/svg+xml";
  return "application/octet-stream";
}

// StoryBook announces the end of a story's render, after its play function
// has run, on the preview's channel ("storyRendered"). The Frame Viewer
// story's play steps a frame forward and back; driving the viewer before it
// is done would race it. Capture the channel as the preview creates it so the
// event cannot be missed, and wait for it before touching the story.
async function gotoStoryAndAwaitPlay(page: Page, url: string): Promise<void> {
  await page.addInitScript(() => {
    const w = window as unknown as { __ctStoryEvents: string[]; __STORYBOOK_ADDONS_CHANNEL__?: unknown };
    w.__ctStoryEvents = [];
    let channel: { on: (name: string, cb: () => void) => void } | undefined;
    Object.defineProperty(window, "__STORYBOOK_ADDONS_CHANNEL__", {
      configurable: true,
      get: () => channel,
      set: (value) => {
        channel = value;
        for (const name of ["storyRendered", "storyErrored", "storyThrewException", "playFunctionThrewException"]) {
          value.on(name, () => w.__ctStoryEvents.push(name));
        }
      },
    });
  });
  await page.goto(url);
  await page.waitForFunction(() => (window as unknown as { __ctStoryEvents: string[] }).__ctStoryEvents.length > 0);
  // The story rendered and its play check passed: anything else is a failure.
  expect(await page.evaluate(() => (window as unknown as { __ctStoryEvents: string[] }).__ctStoryEvents)).toEqual([
    "storyRendered",
  ]);
}

test.describe("Frame Viewer StoryBook", () => {
  let server: http.Server;
  let baseUrl: string;

  test.beforeAll(async () => {
    if (!fs.existsSync(path.join(staticRoot, "iframe.html"))) {
      throw new Error("Missing StoryBook static build. Run `just storybook-build` first.");
    }

    server = http.createServer((req, res) => {
      const url = new URL(req.url ?? "/", "http://127.0.0.1");
      const cleanPath = decodeURIComponent(url.pathname).replace(/^\/+/, "") || "index.html";
      const filePath = path.normalize(path.join(staticRoot, cleanPath));
      if (!filePath.startsWith(staticRoot)) {
        res.writeHead(403);
        res.end("Forbidden");
        return;
      }
      fs.readFile(filePath, (error, data) => {
        if (error) {
          res.writeHead(404);
          res.end("Not found");
          return;
        }
        res.writeHead(200, { "content-type": contentType(filePath) });
        res.end(data);
      });
    });

    await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve));
    const address = server.address();
    if (!address || typeof address === "string") throw new Error("No StoryBook server address");
    baseUrl = `http://127.0.0.1:${address.port}`;
  });

  test.afterAll(async () => {
    await new Promise<void>((resolve, reject) => {
      server.close((error) => (error ? reject(error) : resolve()));
    });
  });

  test("renders a non-empty frame and updates on frame change", async ({ page }) => {
    await gotoStoryAndAwaitPlay(page, `${baseUrl}/iframe.html?id=codetracer-panels--frame-viewer&viewMode=story`);

    const image = page.locator(".frame-viewer-image");
    await expect(image).toBeVisible();
    await expect(page.locator(".frame-viewer-draw-call").first()).toBeVisible();

    await expect
      .poll(async () =>
        image.evaluate((img: HTMLImageElement) => ({
          width: img.naturalWidth,
          height: img.naturalHeight,
          src: img.currentSrc || img.src,
        })),
      )
      .toMatchObject({ width: 320, height: 180 });

    // The play check leaves the viewer on the frame it opened on.
    await expect(page.locator(".frame-viewer-frame-label")).toContainText("GEID 120");
    const firstSrc = await image.getAttribute("src");
    expect(firstSrc).toContain("data:image/svg+xml");

    const sample = await image.evaluate((img: HTMLImageElement) => {
      const canvas = document.createElement("canvas");
      canvas.width = img.naturalWidth;
      canvas.height = img.naturalHeight;
      const ctx = canvas.getContext("2d");
      if (!ctx) return 0;
      ctx.drawImage(img, 0, 0);
      const data = ctx.getImageData(0, 0, canvas.width, canvas.height).data;
      let nonEmpty = 0;
      for (let i = 0; i < data.length; i += 4) {
        if (data[i] !== 0 || data[i + 1] !== 0 || data[i + 2] !== 0 || data[i + 3] !== 0) {
          nonEmpty += 1;
        }
      }
      return nonEmpty;
    });
    expect(sample).toBeGreaterThan(0);

    await page.locator(".frame-viewer-next-frame").click();
    await expect.poll(() => image.getAttribute("src")).not.toBe(firstSrc);
    await expect(page.locator(".frame-viewer-frame-label")).toContainText("GEID 220");
  });

  test("e2e_mcr_visual_layout_contains_frame_viewer", async ({ page }) => {
    await page.goto(`${baseUrl}/iframe.html?id=codetracer-layouts--mcr-visual-debug&viewMode=story`);

    await expect(page.locator(".lm_tab", { hasText: "FRAME VIEWER" })).toBeVisible();
    await expect(page.locator(".frame-viewer-component")).toBeVisible();
    await expect(page.locator(".frame-viewer-connection-status")).toContainText(
      "Visual replay connected",
    );
    // The editor shows the file the replay is stopped in: every story's
    // replay stops in iterate_asteroids, at src/shield.nr:7.
    await expect(page.locator(".lm_tab", { hasText: "src/shield.nr" })).toBeVisible();
    await expect(page.locator(".lm_tab", { hasText: "VARIABLES" })).toBeVisible();
    await expect(page.locator(".lm_tab", { hasText: "CALLTRACE" })).toBeVisible();
    await expect(page.locator(".lm_tab", { hasText: "EVENT LOG" })).toBeVisible();
    await expect(page.locator(".lm_tab", { hasText: "TERMINAL OUTPUT" })).toBeVisible();
  });
});
