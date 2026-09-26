// chromium-run.mjs — run a Nim suite compiled for the BROWSER target
// (`nim js`, no `-d:nodejs`) inside a real page in headless Chromium, and
// deliver the keys it asks for through Chromium's own input pipeline.
//
// The `renderer-chromium` lane's runner (ci/lib/run-nim-test-lane.sh, backend
// `js-chromium`). It exists for suites whose claim is about what a BROWSER
// does — a real document, real focus, trusted keyboard events — which
// `jsdom-run.mjs` cannot make: jsdom is a DOM, not a browser, and it has no
// input pipeline, no top layer and no `showModal()`.
//
// WHAT THE PAGE GETS
//
//   window.ctPress(selector, key)  -> Promise
//       Focus the element `selector` names (skipped when `selector` is empty:
//       the key then goes to whatever holds focus), then press `key` with
//       Playwright's `keyboard.press`, which Chromium receives as a TRUSTED
//       key event — `isTrusted` is true, and the browser's default actions
//       run unless a handler prevents them. That is the whole difference from
//       a suite dispatching `new KeyboardEvent(...)` at an element itself.
//       Focus is taken with `element.focus()`, the same call a reader's click
//       or Tab ends in; an element the browser will not focus (inert, hidden,
//       disabled) keeps focus where it was, which is what a suite asserting
//       exclusivity needs.
//   window.ctFinish(exitCode)
//       The suite is done. The runner exits with the larger of this code and
//       its own verdict (a page error, or a `[FAILED]` line, is a failure).
//
// The suite's `echo` output arrives as console messages and is printed
// verbatim, so the lane runner counts `[OK]` / `[FAILED]` / `CHECKS:` lines
// exactly as it does for every other backend.
//
// NEEDS `node_modules/playwright` and Playwright's Chromium, both of which the
// dev shell provides (`PLAYWRIGHT_BROWSERS_PATH`). It fails, exit 2, rather
// than skipping when either is missing.
//
// Usage: node src/frontend/tests/chromium-run.mjs <compiled-suite.js>
import path from 'node:path';
import fs from 'node:fs';
import { createRequire } from 'node:module';
import { fileURLToPath } from 'node:url';

const require = createRequire(import.meta.url);
const HERE = path.dirname(fileURLToPath(import.meta.url));
const REPO = path.resolve(HERE, '../../..');

const suite = process.argv[2];
if (!suite || !fs.existsSync(suite)) {
  console.error(`chromium-run.mjs: needs the compiled suite as argv[2]; got ${suite}`);
  process.exit(2);
}

let chromium;
try {
  ({ chromium } = require(path.join(REPO, 'node_modules/playwright')));
} catch (e) {
  console.error('chromium-run.mjs: node_modules/playwright is absent — run inside the dev ' +
    `shell, which links it (${e.message})`);
  process.exit(2);
}

const timeoutMs = Number(process.env.CT_CHROMIUM_SUITE_TIMEOUT_MS || 180000);

let browser;
try {
  browser = await chromium.launch();
} catch (e) {
  console.error('chromium-run.mjs: could not launch Playwright\'s Chromium — the dev shell ' +
    `sets PLAYWRIGHT_BROWSERS_PATH to it (${String(e.message).split('\n')[0]})`);
  process.exit(2);
}

let verdict = 0;
let sawFailedLine = false;
try {
  const page = await browser.newPage();
  page.on('console', (msg) => {
    const text = msg.text();
    if (text.includes('[FAILED]')) sawFailedLine = true;
    console.log(text);
  });
  page.on('pageerror', (err) => {
    console.log(`  [FAILED] uncaught page error: ${String(err).split('\n')[0]}`);
    sawFailedLine = true;
  });

  let finish;
  const finished = new Promise((resolve) => { finish = resolve; });
  await page.exposeFunction('ctFinish', (code) => finish(Number(code) || 0));
  // `keyboard.press` knows only the keys of a US layout; a combining mark or
  // an emoji is an "Unknown key". Those go through the DevTools protocol's
  // `Input.dispatchKeyEvent` — the call `keyboard.press` itself makes — with
  // the character as both `key` and `text`, so Chromium still receives a
  // trusted key event through its input pipeline.
  const cdp = await page.context().newCDPSession(page);
  await page.exposeFunction('ctPress', async (selector, key) => {
    if (selector) {
      await page.evaluate((sel) => {
        const el = document.querySelector(sel);
        if (el) el.focus();
      }, selector);
    }
    const chars = [...key];
    if (chars.length === 1 && key.codePointAt(0) > 0x7e) {
      await cdp.send('Input.dispatchKeyEvent',
        { type: 'keyDown', key, text: key, unmodifiedText: key });
      await cdp.send('Input.dispatchKeyEvent', { type: 'keyUp', key });
    } else {
      await page.keyboard.press(key);
    }
  });

  await page.setContent('<!DOCTYPE html><html><head><meta charset="utf-8"></head>' +
    '<body></body></html>');
  await page.addScriptTag({ path: path.resolve(suite) });

  const timedOut = new Promise((resolve) =>
    setTimeout(() => resolve('timeout'), timeoutMs));
  const code = await Promise.race([finished, timedOut]);
  if (code === 'timeout') {
    console.log(`  [FAILED] the suite did not call ctFinish within ${timeoutMs} ms`);
    verdict = 1;
  } else {
    verdict = code;
  }
} finally {
  await browser.close();
}
if (sawFailedLine && verdict === 0) verdict = 1;
process.exit(verdict);
