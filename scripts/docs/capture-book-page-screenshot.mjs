import fs from "node:fs";
import path from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

import { chromium } from "playwright";

const scriptDir = path.dirname(fileURLToPath(import.meta.url));
const repoRoot = path.resolve(scriptDir, "..", "..");
const bookPage = process.env.CODETRACER_BOOK_PAGE
  ?? path.join(repoRoot, "docs", "book", "book", "usage_guide", "visual_recordings.html");
const outputPath = process.env.CODETRACER_BOOK_PAGE_SCREENSHOT
  ?? path.join(repoRoot, "docs", "book", "src", "generated", "book_pages", "visual-recordings-page.png");

function resolveChromiumExecutable() {
  if (process.env.PLAYWRIGHT_CHROMIUM_EXECUTABLE_PATH) {
    return process.env.PLAYWRIGHT_CHROMIUM_EXECUTABLE_PATH;
  }

  const browsersDir = process.env.PLAYWRIGHT_BROWSERS_PATH;
  if (browsersDir && fs.existsSync(browsersDir)) {
    const chromiumDir = fs
      .readdirSync(browsersDir)
      .filter((d) => d.startsWith("chromium-") && !d.includes("headless"))
      .sort()
      .pop();
    if (chromiumDir) {
      const chromiumBase = path.join(browsersDir, chromiumDir);
      if (process.platform === "win32") {
        const chromeSubdir = fs
          .readdirSync(chromiumBase)
          .find((d) => d.startsWith("chrome-win"));
        if (chromeSubdir) {
          return path.join(chromiumBase, chromeSubdir, "chrome.exe");
        }
      } else {
        const chromeSubdir = fs
          .readdirSync(chromiumBase)
          .find((d) => d.startsWith("chrome-linux"));
        if (chromeSubdir) {
          return path.join(chromiumBase, chromeSubdir, "chrome");
        }
      }
    }
  }

  const nixChromium = "/run/current-system/sw/bin/chromium";
  if (fs.existsSync(nixChromium)) {
    return nixChromium;
  }
  return undefined;
}

if (!fs.existsSync(bookPage)) {
  throw new Error(`Book page does not exist: ${bookPage}. Run \`just build-docs\` first.`);
}

fs.mkdirSync(path.dirname(outputPath), { recursive: true });

const executablePath = resolveChromiumExecutable();
const browser = await chromium.launch(executablePath ? { executablePath } : {});
const page = await browser.newPage({ viewport: { width: 1440, height: 1400 } });
await page.goto(pathToFileURL(bookPage).href);
await page.locator("main").waitFor({ state: "visible" });
await page.screenshot({ path: outputPath, fullPage: true });
await browser.close();

console.log(outputPath);
