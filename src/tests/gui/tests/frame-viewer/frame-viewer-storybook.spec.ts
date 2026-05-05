import * as fs from "node:fs";
import * as http from "node:http";
import * as path from "node:path";
import { test, expect } from "@playwright/test";

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
    await page.goto(`${baseUrl}/iframe.html?id=codetracer-panels--frame-viewer&viewMode=story`);

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
});
