// NOT-A-CI-GATE: documentation asset capture.
//
// The same claim, in the same words, that its six siblings under `scripts/docs/`
// make about themselves — it produces a screenshot for the book, and asserts
// nothing about the product. It came into view on 2026-09-04 only because
// `shell-gate-coverage.sh` widened its subject past `*.sh`; the `.sh` capture
// tools beside it have carried this marker since 2026-09-01.

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

// EXISTENCE IS NOT FRESHNESS, and `docs/book/book/` is a BUILD OUTPUT that is
// never cleaned. The check above passes on a page mdBook rendered weeks ago
// from Markdown that has since changed, and the screenshot then goes into
// `docs/book/src/generated/` — into the same book — as a picture of a page that
// no longer reads that way. The remedy the message already names,
// `just build-docs`, is exactly the thing whose absence goes undetected.
//
// So the rendered page must be newer than the source it was rendered from.
// Same comparison and the same conservatism as `ctdr_require_not_stale` in
// `scripts/docs/deep-review-capture-lib.sh`, which asks this of the build tree
// for the DeepReview captures: a source that merely LOOKS newer is a refusal,
// because the remedy is a rebuild and the alternative is a published picture
// nobody can reproduce.
//
// Skipped when the page was supplied by hand (`CODETRACER_BOOK_PAGE`), because
// then it is not necessarily this repository's book at all.
if (!process.env.CODETRACER_BOOK_PAGE) {
  const bookSrc = path.join(repoRoot, "docs", "book", "src");
  if (fs.existsSync(bookSrc)) {
    const renderedAt = fs.statSync(bookPage).mtimeMs;
    // The generated tree this script WRITES INTO lives under `src/generated`,
    // so it is excluded: its own output would otherwise be newer than the page
    // on every second run and the check would refuse every time.
    const generated = path.join(bookSrc, "generated");
    let newest = null;
    const walk = (dir) => {
      for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
        if (newest) return;
        const full = path.join(dir, entry.name);
        if (full === generated) continue;
        if (entry.isDirectory()) { walk(full); continue; }
        if (!entry.isFile()) continue;
        if (fs.statSync(full).mtimeMs > renderedAt) {
          newest = full;
          return;
        }
      }
    };
    walk(bookSrc);
    if (newest) {
      throw new Error(
        `Stale book: ${bookPage} is older than its source ${newest}.\n` +
        "This screenshot would show a page the book no longer contains.\n" +
        "Rebuild with `just build-docs`, then run this again.",
      );
    }
  }
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
