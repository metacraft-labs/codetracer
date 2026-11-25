// The DOM arm of the story-parity harness: one declared story, drawn by
// CodeTracer's own Electron, written as a PNG.
//
//   node tools/story-parity/capture-dom.mjs --www <dir> --story <kind>/<surface>/<fixture>
//     --out <png> [--title T] [--width 1600] [--height 1000] [--scale 1] [--theme dark]
//     [--electron <binary>] [--regions <json>]
//
// The page is the IsoNim Editor's page preview document for the story
// (`isonim_editor_codetracer.codeTracerPreviewDocument`, `page = true`): the
// app's stylesheets in `index.html`'s order, the theme's swapped, the
// StoryBook components bundle and `surfaces.js`, whose `renderSurface` frames
// and mounts the story exactly as StoryBook does. `--www` is the static tree
// `scripts/story-parity.sh` assembles (the editor's tree's layout). It is
// served from this process on a loopback port.
//
// The window is Electron's (the same Chromium the desktop draws with), its
// content `width` x `height` CSS pixels, at `--scale` device pixels per CSS
// pixel (`--force-device-scale-factor`). The capture waits for the story's
// mount, the document's fonts and two animation frames.
//
// `--regions` writes the border boxes of the elements that carry a pane's
// identity (`[data-ct-pane]`, GoldenLayout's header and content), in CSS
// pixels, for the per-region diff.

import { createRequire } from "node:module";
import { createServer } from "node:http";
import { mkdirSync, readFileSync, writeFileSync, existsSync, statSync, mkdtempSync } from "node:fs";
import { dirname, extname, join, normalize, resolve } from "node:path";
import { tmpdir } from "node:os";
import { execFileSync } from "node:child_process";

const require = createRequire(import.meta.url);
// Playwright comes from the dev shell's NODE_PATH, as for the editor's checks.
const { _electron } = require("playwright");

function arg(name, fallback = undefined) {
  const at = process.argv.indexOf(`--${name}`);
  if (at >= 0 && at + 1 < process.argv.length) return process.argv[at + 1];
  if (fallback === undefined) throw new Error(`missing --${name}`);
  return fallback;
}

const repo = resolve(dirname(new URL(import.meta.url).pathname), "..", "..");
const www = resolve(arg("www"));
const [kind, surface, fixture = "populated"] = arg("story").split("/");
const title = arg("title", "");
const out = resolve(arg("out"));
const width = Number(arg("width", "1600"));
const height = Number(arg("height", "1000"));
const scale = Number(arg("scale", "1"));
const theme = arg("theme", "dark");
const regionsOut = arg("regions", "");
const boxesOut = arg("boxes", "");
let electron = arg("electron", "");
if (!electron) electron = execFileSync("bash", ["-c", "command -v electron"]).toString().trim();

const THEME_FILES = { dark: "default_dark_theme_electron.css", light: "default_white_theme_electron.css" };

function attributeValue(tag, name) {
  const m = new RegExp(`\\s${name}=(["'])(.*?)\\1`, "i").exec(tag);
  return m ? m[2] : "";
}

// `<link rel="stylesheet">` of the app page, in order, as the editor reads
// them (`isonim_editor_codetracer.appStylesheets`).
function appStylesheets(html) {
  const links = [];
  for (const m of html.matchAll(/<link[^>]*>/gi)) {
    const tag = m[0];
    if (!attributeValue(tag, "rel").split(/\s+/).includes("stylesheet")) continue;
    let href = attributeValue(tag, "href");
    if (!href) continue;
    href = "/" + href.replace(/^(\.\/)+/, "").replace(/^\/+/, "");
    links.push({ id: attributeValue(tag, "id"), href });
  }
  return links;
}

function pageHtml() {
  const themeKey = THEME_FILES[theme] ? theme : "dark";
  let head = `<!doctype html><html data-codetracer-theme="${themeKey}"><head><meta charset="utf-8">`;
  for (const link of appStylesheets(readFileSync(join(repo, "src/frontend/index.html"), "utf8"))) {
    let href = link.href;
    if (link.id === "theme") href = href.slice(0, href.lastIndexOf("/") + 1) + THEME_FILES[themeKey];
    head += `<link rel="stylesheet" href="${href}"${link.id ? ` id="${link.id}"` : ""}>`;
  }
  head += "<style>html,body{margin:0;padding:0;height:100%;overflow:hidden}</style>";
  head += `<script src="/codetracer-storybook/components.js"></script>`;
  const story = JSON.stringify([kind, surface, fixture, title || null]);
  return head + `</head><body data-codetracer-story="${surface}/${fixture}"><script type="module">
import { renderSurface } from "/codetracer-storybook/lib/surfaces.js";
const [k, s, f, t] = ${story};
document.body.appendChild(renderSurface(k, s, f, t));
</script></body></html>`;
}

const TYPES = { ".html": "text/html", ".js": "text/javascript", ".mjs": "text/javascript",
  ".css": "text/css", ".svg": "image/svg+xml", ".png": "image/png", ".ttf": "font/ttf",
  ".woff2": "font/woff2", ".woff": "font/woff", ".json": "application/json", ".otf": "font/otf" };

const server = createServer((req, res) => {
  const path = decodeURIComponent(new URL(req.url, "http://x").pathname);
  if (path === "/story.html") {
    res.writeHead(200, { "content-type": "text/html" });
    res.end(pageHtml());
    return;
  }
  const file = normalize(join(www, path));
  if (!file.startsWith(www) || !existsSync(file) || !statSync(file).isFile()) {
    res.writeHead(404);
    res.end();
    return;
  }
  res.writeHead(200, { "content-type": TYPES[extname(file)] ?? "application/octet-stream" });
  res.end(readFileSync(file));
});
await new Promise((ok) => server.listen(0, "127.0.0.1", ok));
const url = `http://127.0.0.1:${server.address().port}/story.html`;

// A main process of our own: one window, its content the story's size.
const appDir = mkdtempSync(join(tmpdir(), "story-parity-electron-"));
writeFileSync(join(appDir, "package.json"), JSON.stringify({ name: "story-parity", main: "main.js" }));
writeFileSync(join(appDir, "main.js"), `
const { app, BrowserWindow } = require("electron");
app.whenReady().then(() => {
  const win = new BrowserWindow({ width: ${width}, height: ${height}, useContentSize: true,
    frame: false, resizable: false, backgroundColor: "#000000", show: true });
  win.loadURL(${JSON.stringify(url)});
});
`);

const args = [appDir, "--no-sandbox", "--disable-gpu", "--disable-gpu-compositing",
  "--disable-dev-shm-usage", `--force-device-scale-factor=${scale}`, "--hide-scrollbars=false"];
const app = await _electron.launch({ executablePath: electron, args });
let status = 0;
try {
  const page = await app.firstWindow();
  page.on("pageerror", (e) => console.error("page error:", e.message));
  await page.waitForLoadState("load");
  await page.waitForFunction(() => {
    const host = document.querySelector(".ct-storybook-panel-content, .ct-storybook-frame");
    return host && host.children.length > 0;
  }, null, { timeout: 30000 });
  await page.evaluate(() => document.fonts.ready);
  await page.evaluate(() => new Promise((ok) => requestAnimationFrame(() => requestAnimationFrame(ok))));
  const size = await page.evaluate(() => [innerWidth, innerHeight, devicePixelRatio]);
  if (size[0] !== width || size[1] !== height || size[2] !== scale) {
    throw new Error(`the window's content is ${size[0]}x${size[1]} @${size[2]}, not ${width}x${height} @${scale}`);
  }
  mkdirSync(dirname(out), { recursive: true });
  await page.screenshot({ path: out, scale: "device" });
  if (regionsOut) {
    const regions = await page.evaluate(() => {
      const found = [];
      const add = (name, el) => {
        const r = el.getBoundingClientRect();
        if (r.width > 0 && r.height > 0) found.push({ name, x: r.x, y: r.y, w: r.width, h: r.height });
      };
      document.querySelectorAll("[data-ct-pane]").forEach((el) => add(`pane:${el.getAttribute("data-ct-pane")}`, el));
      document.querySelectorAll(".lm_header").forEach((el, i) => add(`tabstrip:${i}`, el));
      document.querySelectorAll(".ct-storybook-panel-content").forEach((el, i) => add(`content:${i}`, el));
      return found;
    });
    writeFileSync(regionsOut, JSON.stringify({ width, height, scale, regions }, null, 2));
  }
  if (boxesOut) {
    // Every element under the surface, in document order, with its border
    // box: the walk `codetracer-zgui-story --boxes` takes, so the lists pair.
    const boxes = await page.evaluate(() => {
      const out = [];
      const walk = (el, d) => {
        const r = el.getBoundingClientRect();
        let label = el.id ? `#${el.id}` : "";
        if (el.classList.length) label += "." + [...el.classList].join(".");
        out.push({ d, t: el.tagName.toLowerCase(), e: label, x: r.x, y: r.y, w: r.width, h: r.height });
        for (const c of el.children) if (c.tagName !== "STYLE") walk(c, d + 1);
      };
      walk(document.querySelector(".ct-storybook-surface"), 0);
      return out;
    });
    writeFileSync(boxesOut, JSON.stringify(boxes, null, 0).replace(/},{/g, "},\n{"));
  }
  console.log(`wrote ${out} (${width * scale}x${height * scale})`);
} catch (e) {
  console.error(e.message);
  status = 1;
} finally {
  await app.close();
  server.close();
}
process.exit(status);
