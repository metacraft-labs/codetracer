// The `/noir/demo` demo path, driven in a real tab and reported as facts.
//
// WHAT THIS IS FOR, and what it refuses to be. `noir-demo-template.sh` proves
// the demo's SOURCES are right and that its bug is reachable under `nargo`.
// That is not the same claim as "the demo works", because the demo is an
// EXPERIENCE: a visitor arrives, presses Run, and reads four panes. Every step
// of that can fail with the template perfectly intact — and two of them did,
// which is why this file exists rather than being a nicety:
//
//   * the theme stylesheet was composed as a RELATIVE href, so at a
//     two-segment address it resolved into the SPA rewrite and the whole
//     application rendered with zero CSS rules. Nothing about the template was
//     wrong; the page was simply unreadable.
//   * `onOutput` accumulated the trace with `.add`, which `nim js` compiles to
//     `push.apply` — so any trace over ~100 KB threw `RangeError` and Run
//     reported "the tracer did not produce a trace" over a perfectly good one.
//
// Neither is visible to a source-level gate, and neither would be caught by
// "the route returns 200". So the assertions below are about what a visitor
// can SEE.
//
// THE ONE THAT MATTERS MOST is `onePassFrames`. The demo's whole thesis is
// that the pass count is a thing the calltrace SHOWS rather than a loop bound
// a reader must evaluate — `sort::ascending` calls a named function once per
// pass for exactly that reason. If that stops being three visible frames, the
// demo has lost its point even though every test still passes.
//
// Usage: noir_demo_path_probe.mjs <baseUrl>   (prints one JSON object)
import { chromium } from 'playwright';

const base = process.argv[2];
if (!base) { console.error('usage: noir_demo_path_probe.mjs <baseUrl>'); process.exit(2); }

// Generous, because this compiles a circuit and traces it in a tab. A short
// wait here would make the gate flaky in the one direction that is worst: it
// would report the product broken when it was merely slow.
const MOUNT_MS = Number(process.env.CT_DEMO_MOUNT_MS || 12000);
const RUN_MS = Number(process.env.CT_DEMO_RUN_MS || 60000);

const browser = await chromium.launch();
const page = await browser.newPage({ viewport: { width: 1680, height: 1050 } });
const pageErrors = [];
page.on('pageerror', (e) => pageErrors.push(String((e && e.message) || e).slice(0, 300)));
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const out = {};

// --- arrival ---------------------------------------------------------------
await page.goto(`${base}/noir/demo`, { waitUntil: 'load' });
await sleep(MOUNT_MS);

// CSS RULES, COUNTED. The theme defect painted a complete DOM with no styling,
// so "the page loaded" and "the file tree has rows" were both true while the
// application was unusable. A rule count is the cheapest thing that would have
// caught it.
out.cssRules = await page.evaluate(() => {
  let rules = 0;
  for (const sheet of document.styleSheets) {
    try { rules += sheet.cssRules.length; } catch (e) { /* cross-origin: not ours */ }
  }
  return rules;
});
out.themeHref = await page.evaluate(() => {
  const l = document.querySelector('#theme');
  return l ? l.href : null;
});

const bodyMentions = (p) => p.evaluate(() => {
  const t = document.body.innerText;
  return {
    oracle: t.includes('oracle_settlement'),
    sort: t.includes('sort.nr'),
    aggregate: t.includes('aggregate.nr'),
    hello: t.includes('hello_noir'),
    utils: t.includes('utils.nr'),
  };
});
out.demoMounted = await bodyMentions(page);

// The Constraints pane, on arrival. The demo and the starter must not report
// the same circuit cost — they did until the counts moved onto the template.
out.constraintsText = await page.evaluate(() => {
  const el = document.getElementById('constraintsComponent-0');
  return el ? (el.innerText || '').replace(/\s+/g, ' ').slice(0, 400) : null;
});

// --- the contrast: /noir must still be the starter -------------------------
const starterPage = await browser.newPage({ viewport: { width: 1280, height: 900 } });
await starterPage.goto(`${base}/noir`, { waitUntil: 'load' });
await sleep(MOUNT_MS);
out.starterMounted = await bodyMentions(starterPage);
await starterPage.close();

// --- Run -------------------------------------------------------------------
await page.bringToFront();
await page.keyboard.press('Control+Enter');
await sleep(RUN_MS);

out.topbarSurface = await page.evaluate(() => {
  const el = document.querySelector('[data-topbar-surface]');
  return el ? el.getAttribute('data-topbar-surface') : null;
});
out.buildText = await page.evaluate(() => {
  const el = document.getElementById('buildComponent-0');
  return el ? (el.innerText || '').replace(/\s+/g, ' ').slice(0, 600) : null;
});

// --- the calltrace, and the three frames the demo is about -----------------
//
// Counted on LEAF nodes. Taking `innerText.match(/one_pass/g)` off the pane
// would count each frame once per ancestor that contains it and answer a
// number that looks plausible and means nothing.
out.onePassFrames = await page.evaluate(() => {
  const el = document.getElementById('calltraceComponent-0');
  if (!el) return -1;
  return Array.from(el.querySelectorAll('*'))
    .filter((n) => n.children.length === 0 && (n.textContent || '').includes('one_pass'))
    .length;
});
out.calltraceText = await page.evaluate(() => {
  const el = document.getElementById('calltraceComponent-0');
  return el ? (el.innerText || '').replace(/\s+/g, ' ').slice(0, 700) : null;
});

// --- the event log ---------------------------------------------------------
out.eventLog = await page.evaluate(() => {
  const el = document.getElementById('eventLogComponent-0');
  if (!el) return null;
  const t = el.innerText || '';
  return {
    freshCount: t.includes('fresh reports: 6'),
    wrongPrice: t.includes('242990'),
    assertion: t.includes('not the median'),
    text: t.replace(/\s+/g, ' ').slice(0, 400),
  };
});

// --- clicking the third frame opens the sort, and the flow view paints -----
out.clickedThirdFrame = await page.evaluate(() => {
  const el = document.getElementById('calltraceComponent-0');
  if (!el) return false;
  const hits = Array.from(el.querySelectorAll('*'))
    .filter((n) => n.children.length === 0 && (n.textContent || '').includes('one_pass'));
  if (hits.length < 3) return false;
  (hits[2].closest('div') || hits[2]).click();
  return true;
});
await sleep(6000);

// The flow view's own per-iteration rows. `line-flow-hit` is the class the
// renderer puts on a line it has values for, so its presence is the pane
// working rather than merely existing.
out.flow = await page.evaluate(() => {
  const containers = Array.from(
    document.querySelectorAll('[id^="flow-loop-step-container"]'));
  const rows = containers.map((c) => (c.innerText || '').replace(/\s+/g, ' ').trim())
    .filter(Boolean);
  return {
    hitLines: document.querySelectorAll('.line-flow-hit').length,
    rowCount: rows.length,
    // The third pass RETURNING the low outlier at index 3 — the slot
    // `median_of` reads. This is the moment the demo is about, and it is what
    // makes step 7 of the path (Noir-Studio.md §1b.7) something a visitor can
    // see rather than be told.
    //
    // IT IS NOT A BUG DETECTOR, and saying so is the point of this note. A
    // mutation applying the one-line repair leaves it GREEN, and that is
    // CORRECT rather than a hole: passes 1 to 3 are identical whatever
    // `SETTLE_PASSES` is, so the third frame returns the same array in both
    // circuits. The repair does not change this pass; it adds three more
    // AFTER it.
    //
    // So what discriminates the broken circuit from the fixed one is the
    // NUMBER of frames (`onePassFrames`) and the settled price in the event
    // log — both verified to redden under that mutation. This field asserts
    // the flow view still PAINTS, with values a reader can follow. Do not
    // rewrite it into a bug check; there is nothing at this position to
    // detect.
    //
    // Matched on `return` and on position: requiring exactly three values
    // before 242990 pins it to index 3, so a flow view rendering some other
    // array cannot satisfy it.
    showsOutlierAtMedian: rows.some(
      (r) => /return\s*@\[\s*\d+,\s*\d+,\s*\d+,\s*242990\b/.test(r)),
    sample: rows.slice(0, 8),
  };
});
out.openTabs = await page.evaluate(() =>
  Array.from(document.querySelectorAll('.lm_title')).map((t) => t.textContent.trim()).slice(0, 8));

out.pageErrors = pageErrors.slice(0, 10);
console.log(JSON.stringify(out, null, 2));
await browser.close();
