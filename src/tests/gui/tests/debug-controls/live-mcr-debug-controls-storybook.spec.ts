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

test.describe("Live MCR debug controls StoryBook", () => {
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

  test("e2e_live_mcr_toolbar_routes_commands", async ({ page }) => {
    await page.goto(
      `${baseUrl}/iframe.html?id=codetracer-panels--live-mcr-debug-controls&viewMode=story`,
    );

    await expect(page.locator("#debug-toolbar-mode")).toContainText("Live MCR");
    await expect(page.locator("#recording-head-indicator")).toContainText("Head: 400");
    await expect(page.locator("#jump-to-live-debug")).toBeVisible();
    await expect(page.locator("#jump-to-live-debug")).toBeEnabled();
    await expect(page.locator("#reverse-continue-debug")).toBeDisabled();

    const commandLog = page.locator("#live-mcr-command-log");
    await expect.poll(async () => JSON.parse((await commandLog.textContent()) || "[]")).toEqual([
      { command: "ct/mcr-get-recording-head", args: {} },
    ]);

    await page.locator("#next-debug").click();
    await expect
      .poll(async () => JSON.parse((await commandLog.textContent()) || "[]"))
      .toContainEqual({
        command: "ct/mcr-live-step",
        args: { action: "next", threadId: 1 },
      });

    const afterStep = JSON.parse((await commandLog.textContent()) || "[]");
    expect(afterStep.some((entry: { command: string }) => entry.command === "next")).toBe(false);

    await page.locator("#jump-to-live-debug").click();
    await expect
      .poll(async () => JSON.parse((await commandLog.textContent()) || "[]"))
      .toContainEqual({
        command: "ct/mcr-restore-at",
        args: { rrTicks: 400, jumpToLive: true },
      });
    await expect(page.locator("#debug-toolbar-mode")).toContainText("Live MCR");
    await expect(page.locator("#recording-head-indicator")).toContainText("Head: 400");
  });
});
