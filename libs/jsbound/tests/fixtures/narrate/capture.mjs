// Records the fixture checkout session (site/) in headless Chromium with the
// generic boundary shim, and writes the session's boundary log (a
// `jsbound.log` stream, as the shim's `log()` returns it) for
// tests/narrate.rs. See README.md for how and when to run it.
//
//   node capture.mjs --recorder <codetracer-js-recorder checkout> \
//                    --variant base|extra-click --out <file.jsbound.log>
//
// Run it inside the codetracer-js-recorder dev shell, which provides
// playwright-core and Chromium (PLAYWRIGHT_CORE_PATH,
// PLAYWRIGHT_BROWSERS_PATH), after `npm run build` there. The shim is
// installed by that checkout's own CLI (`boundary-shim`), exactly as a site's
// deploy step installs it, and the site is served by a plain local server.

import { execFileSync } from "node:child_process";
import * as fs from "node:fs";
import * as http from "node:http";
import { createRequire } from "node:module";
import * as os from "node:os";
import * as path from "node:path";

const here = path.dirname(new URL(import.meta.url).pathname);

function option(name) {
  const i = process.argv.indexOf(name);
  if (i < 0 || i + 1 >= process.argv.length) {
    throw new Error(`missing ${name}`);
  }
  return process.argv[i + 1];
}

const recorder = path.resolve(option("--recorder"));
const variant = option("--variant");
const out = path.resolve(option("--out"));
if (variant !== "base" && variant !== "extra-click") {
  throw new Error(`unknown variant ${variant}`);
}

// The build hash the shim is installed with: any 64 hex digits will do, as
// nothing here checks it against an archive.
const BUILD_HASH = "5e1f".repeat(16);

const site = fs.mkdtempSync(path.join(os.tmpdir(), "narrate-site-"));
for (const f of fs.readdirSync(path.join(here, "site"))) {
  fs.copyFileSync(path.join(here, "site", f), path.join(site, f));
}
execFileSync(
  process.execPath,
  [
    path.join(recorder, "packages/cli/dist/index.js"),
    "boundary-shim",
    site,
    "--build-hash",
    BUILD_HASH,
  ],
  { stdio: "inherit" },
);

const types = { ".html": "text/html", ".js": "text/javascript" };
const server = http.createServer((req, res) => {
  const url = new URL(req.url, "http://localhost");
  if (req.method === "POST" && url.pathname === "/api/checkout") {
    req.resume();
    req.on("end", () => {
      res.writeHead(200, { "content-type": "application/json" });
      res.end(JSON.stringify({ order: "A-1001" }));
    });
    return;
  }
  if (req.method === "POST" && url.pathname === "/api/pay") {
    req.resume();
    req.on("end", () => {
      res.writeHead(200, { "content-type": "application/json" });
      res.end("{}");
    });
    return;
  }
  const file = path.join(site, url.pathname === "/" ? "index.html" : url.pathname);
  if (!file.startsWith(site) || !fs.existsSync(file)) {
    res.writeHead(404).end();
    return;
  }
  res.writeHead(200, { "content-type": types[path.extname(file)] ?? "text/plain" });
  res.end(fs.readFileSync(file));
});
// A fixed port, so the log's URLs are the same in every capture.
await new Promise((resolve) => server.listen(47811, "127.0.0.1", resolve));

const core = process.env.PLAYWRIGHT_CORE_PATH;
if (!core || !process.env.PLAYWRIGHT_BROWSERS_PATH) {
  throw new Error("run inside the codetracer-js-recorder dev shell (PLAYWRIGHT_CORE_PATH)");
}
const { chromium } = createRequire(import.meta.url)(core);
const browser = await chromium.launch({ headless: true });
try {
  const page = await browser.newPage();
  await page.goto("http://127.0.0.1:47811/index.html");
  await page.click("#add");
  await page.click("#details");
  if (variant === "extra-click") {
    // The one difference between the two captures: one more click.
    await page.click("#details");
  }
  await page.type("#name", "Ada");
  await page.type("#email", "ada-at-example.org");
  await page.click("#continue");
  await page.fill("#email", "");
  await page.type("#email", "ada@example.org");
  await page.click("#continue");
  // Polled from here, never with waitForFunction, whose polling in the page
  // would schedule timers or animation frames the shim records as the page's.
  const until = async (probe, what) => {
    for (let i = 0; ; i++) {
      if (await page.evaluate(probe)) return;
      if (i > 500) throw new Error("the page did not reach: " + what);
      await new Promise((r) => setTimeout(r, 20));
    }
  };
  await until(
    () => document.getElementById("status").textContent.startsWith("order"),
    "the order",
  );
  await page.click("#pay");
  await until(() => document.body.getAttribute("data-done") === "1", "done");
  const bytes = await page.evaluate(async () => {
    await window.__ctBoundaryShim.stop();
    return Array.from(window.__ctBoundaryShim.log());
  });
  fs.writeFileSync(out, Uint8Array.from(bytes));
  console.log(`wrote ${out} (${bytes.length} bytes)`);
} finally {
  await browser.close();
  server.close();
  fs.rmSync(site, { recursive: true, force: true });
}
