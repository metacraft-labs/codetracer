// wasm_session_probe.mjs — load the session harness in a real browser and
// report what the session actually did.
//
// WHY A BROWSER AND NOT A UNIT TEST
// ---------------------------------
// `test_wasm_worker.nim` already proves the session protocol on both backends
// against a fake transport, and it proves things a browser cannot express —
// "this future never settled" chief among them. What it cannot prove is that
// any of it is REACHED. This repository's signature defect is machinery that
// is present, correct and unreachable: `newBrowserWasmHost` went a milestone
// uncalled with a doc comment explaining why, and `wasm_worker_browser.js`
// handled a `configure` message from the day it was written while nothing in
// Nim ever sent one — so a deployment could serve both modules perfectly and
// fail every run.
//
// So the subject here is the assembled publish tree: a real `Worker` over the
// real `/assets/wasm-worker.js`, driven by the real `platform/wasm_worker.nim`
// through `host/web_browser.newBrowserWasmWorker`, in a real tab.
//
// THIS PROGRAM ASSERTS NOTHING. It reports facts; `wasm-worker-session.sh`
// counts assertions over them. That split is `web_renderer_probe.mjs`'s and it
// exists so the control arm and every mutation arm read the same instrument.
//
// `pageErrors` is the field that matters most and the reason this subscribes
// to `pageerror` rather than polling the DOM alone: a harness that died on its
// first statement leaves `#session-report` at `{}`, which is indistinguishable
// from a session that opened and said nothing unless somebody is listening for
// the throw.

import { chromium } from 'playwright';

const url = process.argv[2];
const budgetMs = Number(process.argv[3] || 15000);
if (!url) {
  console.error('usage: wasm_session_probe.mjs <url> [budgetMs]');
  process.exit(2);
}

const browser = await chromium.launch({});
const page = await browser.newPage();

const pageErrors = [];
const consoleErrors = [];
const workerRequests = [];
page.on('pageerror', (e) => pageErrors.push(String(e && e.message ? e.message : e)));
page.on('console', (m) => {
  if (m.type() === 'error') consoleErrors.push(m.text());
});
// Which worker script the tab actually fetched. A gate that assumed the URL
// would go green over a page that silently fell back to something else.
page.on('response', (r) => {
  const u = r.url();
  if (u.includes('wasm-worker') || u.includes('/__harness/')) {
    workerRequests.push({ url: u, status: r.status() });
  }
});

let report = {};
let settled = false;
let navigationError = '';

try {
  await page.goto(url, { waitUntil: 'load', timeout: budgetMs });
} catch (e) {
  navigationError = String(e && e.message ? e.message : e);
}

if (!navigationError) {
  // WAIT FOR THE HARNESS TO SAY IT IS DONE, not for a fixed sleep. The harness
  // writes `done: true` as its last act, so a run that stalled half way is a
  // TIMEOUT with a partial report — which names the step it stopped at — and
  // not a green run over three of eight measurements.
  try {
    await page.waitForFunction(() => {
      const el = document.getElementById('session-report');
      if (!el) return false;
      try { return JSON.parse(el.textContent || '{}').done === true; }
      catch (e) { return false; }
    }, null, { timeout: budgetMs });
    settled = true;
  } catch (e) {
    settled = false;
  }

  try {
    report = await page.evaluate(() => {
      const el = document.getElementById('session-report');
      if (!el) return {};
      try { return JSON.parse(el.textContent || '{}'); } catch (e) { return {}; }
    });
  } catch (e) {
    report = {};
  }
}

await browser.close();

console.log(JSON.stringify({
  url,
  navigationError,
  settled,
  // NON-VACUITY. Every assertion the shell makes is over `report`; if the page
  // never ran, `report` is `{}` and "no error was reported" would be true of
  // an empty object. The shell guards on `reportPresent` first, which is trap
  // 4 — the empty haystack — applied to this instrument.
  reportPresent: Object.keys(report).length > 0,
  pageErrors,
  consoleErrors,
  workerRequests,
  report,
}, null, 2));
