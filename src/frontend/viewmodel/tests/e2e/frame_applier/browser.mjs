// browser.mjs — IsoNim's frame applier and frame renderer in a real browser,
// driven by real input.
//
// Usage: node browser.mjs <built-dir> <chromium|firefox>
//
// Serves the built page over HTTP and, for each core build (`nim js` and
// wasm32), performs every event the shipped panes listen for — click, input,
// focus, blur, change, submit, keydown, paste, wheel — through Playwright's
// input APIs, then reads the document. Each handler in the core writes what it
// received through the frame renderer, so a pass means the whole round trip
// held: host listener → payload → core handler → frame → applier → document,
// and the handler's preventDefault / stopPropagation reached the real event.
//
// No mocks: every event comes from Playwright's keyboard and mouse, the paste
// included (a real copy from a textarea, then a real paste into the shell).
// A page-constructed `ClipboardEvent` was tried first and rejected: Firefox
// replaces the `clipboardData` it is given with an empty one.
//
// Prints `FRAME-APPLIER ok engine=… arm=…` per arm and exits 0 when both arms
// produced the expected document and the same one; 1 on a failed check; 2 when
// Playwright or the engine is missing.

import http from 'node:http';
import fs from 'node:fs';
import path from 'node:path';
import { createRequire } from 'node:module';

const [dir, engine] = process.argv.slice(2);
if (!dir || !['chromium', 'firefox'].includes(engine || '')) {
  console.error('usage: node browser.mjs <built-dir> <chromium|firefox>');
  process.exit(2);
}
const root = path.resolve(dir);
const repo = process.env.CT_REPO || process.cwd();
let pw;
try {
  pw = createRequire(path.join(repo, 'package.json'))('playwright');
} catch (e) {
  console.error('browser.mjs: node_modules/playwright is absent — run inside the dev shell');
  process.exit(2);
}

const types = { '.html': 'text/html', '.js': 'text/javascript', '.wasm': 'application/wasm' };
const server = http.createServer((req, res) => {
  const p = path.join(root, decodeURIComponent(new URL(req.url, 'http://x').pathname));
  if (!p.startsWith(root) || !fs.existsSync(p) || fs.statSync(p).isDirectory()) {
    res.writeHead(404); res.end(); return;
  }
  res.writeHead(200, { 'Content-Type': types[path.extname(p)] || 'application/octet-stream' });
  fs.createReadStream(p).pipe(res);
});
await new Promise((ok) => server.listen(0, '127.0.0.1', ok));
const url = `http://127.0.0.1:${server.address().port}/page.html`;

const EXPECTED = [
  'click 1', 'click 2', 'focus', 'input hello', 'blur hello', 'change two',
  'submit go', 'keydown ctrl+V', 'paste ls -la', 'keydown ctrl+shift+ArrowDown', 'wheel down',
  'inner',
].join('\n');

let browser;
try {
  browser = await pw[engine].launch();
} catch (e) {
  console.error(`browser.mjs: ${engine} could not be launched: ${e.message.split('\n')[0]}`);
  server.close();
  process.exit(2);
}

let failures = 0;
const logs = {};
for (const arm of ['js', 'wasm']) {
  const page = await browser.newPage();
  const errors = [];
  page.on('pageerror', (e) => errors.push(String(e)));
  await page.goto(`${url}?arm=${arm}`);
  await page.waitForFunction(() => globalThis.feReady || globalThis.feError, null, { timeout: 30000 });
  const bootError = await page.evaluate(() => globalThis.feError || null);
  if (bootError) {
    console.log(`  FAIL: ${engine}/${arm} did not boot: ${bootError}`);
    failures++; await page.close(); continue;
  }

  await page.click('#fe-button');
  await page.click('#fe-button');
  await page.click('#fe-field');
  await page.fill('#fe-field', 'hello');
  await page.click('#fe-select');            // moves focus: the field blurs
  await page.selectOption('#fe-select', 'two');
  await page.fill('#fe-form-field', 'go');
  await page.press('#fe-form-field', 'Enter');
  // A real copy and a real paste, through the browser's own clipboard.
  await page.focus('#fe-clip');
  await page.keyboard.press('ControlOrMeta+A');
  await page.keyboard.press('ControlOrMeta+C');
  // Clicked, not only focused: Firefox sends a paste to the element holding
  // the document's selection, and an earlier click left it in the button.
  await page.click('#fe-shell');
  await page.keyboard.press('ControlOrMeta+V');
  await page.focus('#fe-shell');
  await page.keyboard.press('Control+Shift+ArrowDown');
  await page.hover('#fe-shell');
  await page.mouse.wheel(0, 120);
  await page.waitForFunction(() => document.getElementById('fe-log').textContent.includes('wheel'),
                             null, { timeout: 10000 }).catch(() => {});
  await page.click('#fe-inner');

  const got = await page.evaluate(() => ({
    log: document.getElementById('fe-log').textContent,
    parity: document.getElementById('fe-button').getAttribute('data-parity'),
    prevented: globalThis.fePrevented,
    state: globalThis.feState(),
    url: location.href,
  }));
  logs[arm] = got.log;
  const problems = [];
  if (got.log !== EXPECTED) problems.push(`the log reads ${JSON.stringify(got.log)}`);
  if (got.parity !== 'even') problems.push(`data-parity is ${got.parity} after two presses`);
  for (const t of ['submit:true', 'paste:true', 'wheel:true']) {
    if (!got.prevented.includes(t)) problems.push(`the page did not see ${t} (saw ${got.prevented.join(',')})`);
  }
  if (got.state.readCrossings !== 0) problems.push(`${got.state.readCrossings} read crossing(s)`);
  if (!got.url.endsWith(`?arm=${arm}`)) problems.push(`the page navigated to ${got.url}`);
  if (errors.length) problems.push(`page errors: ${errors.join(' | ')}`);
  if (problems.length) {
    for (const p of problems) console.log(`  FAIL: ${engine}/${arm}: ${p}`);
    failures++;
  } else {
    console.log(`FRAME-APPLIER ok engine=${engine} arm=${arm} events=${EXPECTED.split('\n').length}` +
                ` applied_ops=${got.state.applied}`);
    console.log(`  ok: ${engine}/${arm}: every event reached the core and drew the expected document`);
  }
  await page.close();
}
if (logs.js !== undefined && logs.wasm !== undefined && logs.js !== logs.wasm) {
  console.log(`  FAIL: ${engine}: the js and wasm cores drew different logs`);
  failures++;
}
await browser.close();
server.close();
process.exit(failures ? 1 : 0);
