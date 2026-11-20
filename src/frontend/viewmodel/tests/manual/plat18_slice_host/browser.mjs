// browser.mjs — the WebAssembly-core slice in a BROWSER, not Electron.
//
// Usage: node browser.mjs <slice-dir> <chromium|firefox|webkit>
//
// `main.js` runs the slice in an Electron renderer. Electron's renderer is a
// Chromium page, but it is not the browser front-end: that one is served
// over HTTP, runs in whatever engine the user has, and loads the module the
// way any web page does. This host does exactly that. It serves the built
// slice directory over HTTP from this process, opens `page.html` in a real
// browser through Playwright, runs the same driver, and prints the same
// `PLAT18-…` lines `main.js` prints, so `ci/test/plat18-electron-slice.sh`
// grades both hosts with the same code.
//
// Chromium (V8) and Firefox (SpiderMonkey) run from the dev shell's
// Playwright browsers. They have different WebAssembly and JS↔WASM boundary
// implementations, which is the comparison Uniform-WASM-Core.md §5 keeps a
// bucket for ("investigate further if the results differ sharply between
// Electron and the browser"). WebKit is accepted too, but the dev shell's
// Playwright bundle cannot launch it on NixOS (it looks for an Ubuntu build,
// `webkit_ubuntu20.04_x64_special-*`), so it fails there with exit 2.
//
// ## THE PAGE IS CROSS-ORIGIN ISOLATED
//
// The server sends `Cross-Origin-Opener-Policy: same-origin` and
// `Cross-Origin-Embedder-Policy: require-corp`. Browsers coarsen
// `performance.now()` for pages that are not isolated — Firefox to whole
// milliseconds — which would turn a sub-millisecond STEP into 0 or 1. With
// isolation the clock is fine enough to time it. The page's own behaviour is
// unchanged: it loads only same-origin resources.
//
// ## COLD START
//
// One arm per fresh browser CONTEXT (its own process-level state, no cache
// shared with the main page), loading `coldstart.html` exactly as `main.js`
// does in a fresh renderer. A resident-set figure is not reported here: a
// browser does not expose one to a page, and the memory criterion is
// measured in Electron.
//
// Exit 0 when the driver ran and every check held, 1 when a check failed,
// 2 when Playwright or the engine is missing — a failure, never a skip.

import http from 'node:http';
import fs from 'node:fs';
import path from 'node:path';
import { createRequire } from 'node:module';

const [dir, engine] = process.argv.slice(2);
if (!dir || !['chromium', 'firefox', 'webkit'].includes(engine || '')) {
  console.error('usage: node browser.mjs <slice-dir> <chromium|firefox|webkit>');
  process.exit(2);
}
const root = path.resolve(dir);
const repo = process.env.CT_P18_REPO || process.cwd();

let pw;
try {
  pw = createRequire(path.join(repo, 'package.json'))('playwright');
} catch (e) {
  console.error('browser.mjs: node_modules/playwright is absent — run inside the dev shell');
  process.exit(2);
}

const TYPES = {
  '.html': 'text/html; charset=utf-8',
  '.js': 'text/javascript; charset=utf-8',
  '.wasm': 'application/wasm',
  '.json': 'application/json',
};

const server = http.createServer((req, res) => {
  const url = new URL(req.url, 'http://localhost');
  const file = path.join(root, decodeURIComponent(url.pathname));
  if (!file.startsWith(root + path.sep) || !fs.existsSync(file) || fs.statSync(file).isDirectory()) {
    res.writeHead(404);
    res.end('not found');
    return;
  }
  res.writeHead(200, {
    'Content-Type': TYPES[path.extname(file)] || 'application/octet-stream',
    'Cross-Origin-Opener-Policy': 'same-origin',
    'Cross-Origin-Embedder-Policy': 'require-corp',
    'Cross-Origin-Resource-Policy': 'same-origin',
    'Cache-Control': 'no-store',
  });
  fs.createReadStream(file).pipe(res);
});
await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
const base = `http://127.0.0.1:${server.address().port}`;

let browser;
try {
  browser = await pw[engine].launch({
    executablePath: engine === 'chromium'
      ? (process.env.PLAYWRIGHT_CHROMIUM_EXECUTABLE_PATH || undefined) : undefined,
  });
} catch (e) {
  console.error(`browser.mjs: could not launch Playwright's ${engine}: ${e.message}`);
  server.close();
  process.exit(2);
}

function relay(page, label) {
  page.on('console', (msg) => {
    const text = msg.text();
    if (text.startsWith('PLAT18-')) console.log(text);
    else console.error(`${label}: ${text}`);
  });
  page.on('pageerror', (err) => console.error(`${label}: page error: ${err.message}`));
}

let failed = false;
try {
  const context = await browser.newContext();
  const page = await context.newPage();
  relay(page, engine);
  await page.goto(`${base}/page.html`);
  const isolated = await page.evaluate(() => globalThis.crossOriginIsolated === true);
  console.log(`PLAT18-SLICE-BROWSER engine=${engine} version=${browser.version()}` +
              ` cross_origin_isolated=${isolated ? 1 : 0}`);
  const result = await page.evaluate(async () => {
    const t0 = performance.now();
    await globalThis.loadP18Wasm();
    console.log('PLAT18-SLICE-COLDSTART wasm_instantiate_ms=' +
                (performance.now() - t0).toFixed(3));
    return globalThis.ctP18Run();
  });
  await context.close();

  for (const arm of [
    { name: 'js-direct', src: 'arm_js_direct.js', wasm: 0 },
    { name: 'js-crossing', src: 'arm_js_crossing.js', wasm: 0 },
    { name: 'wasm-crossing', src: 'arm_wasm.js', wasm: 1 },
  ]) {
    const ctx = await browser.newContext();
    const p = await ctx.newPage();
    relay(p, `coldstart(${arm.name})`);
    await p.goto(`${base}/coldstart.html?arm=${arm.name}&src=${arm.src}&wasm=${arm.wasm}`);
    await p.evaluate(() => globalThis.ctP18ColdStart());
    await ctx.close();
  }
  console.log('PLAT18-SLICE-VERDICT ' + (result === 'ok' ? 'ok' : 'FAIL ' + result));
  failed = result !== 'ok';
} catch (err) {
  console.log('PLAT18-SLICE-VERDICT FAIL ' + (err && err.message ? err.message : String(err)));
  failed = true;
}
await browser.close();
server.close();
process.exit(failed ? 1 : 0);
