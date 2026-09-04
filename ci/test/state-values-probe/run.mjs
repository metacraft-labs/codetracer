// run.mjs — read what the State pane put in front of a reader.
//
// Two panes on one page, measured the same way:
//
//   A (#ct-state-pane)     the backend's recorded values, mapped by the
//                          product's own `localsToStoreRows`.
//   B (#ct-ordering-pane)  the pane at the end of the boot -> worker ->
//                          first-move sequence.
//
// This program asserts nothing. It reports facts and lets
// `ci/test/state-values-in-browser.sh` count assertions over them, so the
// arms and the control read one instrument.
//
// THE VALUE CELL IS READ SEPARATELY FROM THE ROW, and RAW. The defect is a
// difference between `@[100, 2000, 200, 14]` and a four-line dump whose
// lines are those same numbers, so a reading that collapses whitespace
// cannot tell them apart -- `innerText.replace(/\s+/g,' ')` turns the dump
// into "Sequence(Seq [Field; 4]): 100 2000 200 14", which contains every
// number the correct rendering contains. So `.value-expanded-text` is read
// with its newlines intact, and the assertions are about the WHOLE string.

import { chromium } from 'playwright';

const url = process.argv[2];
const shot = process.argv[3];
if (!url) {
  console.error('usage: run.mjs <url> [screenshot.png]');
  process.exit(2);
}

const errors = [];
const browser = await chromium.launch({ executablePath: process.env.CT_CHROME });
const page = await browser.newPage({ viewport: { width: 1120, height: 720 } });
page.on('pageerror', (e) => errors.push('pageerror: ' + e.message));
page.on('console', (m) => { if (m.type() === 'error') errors.push('console: ' + m.text()); });

// INSTRUMENT CONTROL, per `ci/test/low-level-code-browser.sh`: a sibling gate
// once blocked a deploy reporting "0 characters on screen" over a DOM that
// renders fine, because its nix Chromium had no fonts and laid every string
// out with zero glyphs. A zero from an instrument that cannot produce a
// non-zero is not evidence. So: prove it can draw letters FIRST.
await page.setContent('<div id="ctrl">the instrument can draw letters</div>');
const controlLen = await page.evaluate(() => document.body.innerText.trim().length);
if (controlLen === 0) {
  console.log(JSON.stringify({ instrument: 'CANNOT DRAW TEXT — result would be meaningless' }));
  await browser.close();
  process.exit(3);
}
console.log('instrument control: ' + controlLen + ' chars drawn');

await page.goto(url, { waitUntil: 'load' });
await page.waitForTimeout(900);

// Read a pane's rows the way a reader sees them: LAID OUT, hit-tested at
// their own start point. A row in the DOM with a zero-height box, or one
// covered by something else, is not a row a user can read.
const readRows = (paneSel) => page.evaluate((sel) => {
  const out = [];
  const rejected = [];
  for (const el of document.querySelectorAll(sel + ' [data-variable-name]')) {
    const name = el.getAttribute('data-variable-name') || '';
    const r = el.getBoundingClientRect();
    if (r.width === 0 || r.height === 0) { rejected.push(name + ': zero-size'); continue; }
    const cs = getComputedStyle(el);
    if (cs.visibility === 'hidden' || cs.display === 'none' || cs.opacity === '0') {
      rejected.push(name + ': css-' + cs.visibility + '/' + cs.display); continue;
    }
    const top = document.elementFromPoint(r.x + Math.min(8, r.width / 2), r.y + r.height / 2);
    if (!top) { rejected.push(name + ': nothing-at-point'); continue; }
    if (!(top === el || el.contains(top) || top.contains(el))) {
      rejected.push(name + ': covered-by-' + top.tagName); continue;
    }
    // THE VALUE CELL, raw. `textContent` and not `innerText`, because
    // `innerText` reports what CSS made of the newlines and the defect is
    // about the newlines.
    const cell = el.querySelector('.value-expanded-text');
    out.push({
      name,
      text: (el.innerText || el.textContent || '').replace(/\s+/g, ' ').trim(),
      value: cell ? (cell.textContent || '') : null,
    });
  }
  // ONE ROW PER NAME. The view stamps `data-variable-name` on two nested
  // elements per row (the row and its name span), so every row matches
  // twice and the inner one can be zero-sized while the outer is laid out.
  // Keeping the entry that actually HAS a value cell, then the longest,
  // picks the element carrying the whole row rather than just the label.
  const byName = new Map();
  for (const r of out) {
    const seen = byName.get(r.name);
    if (!seen) { byName.set(r.name, r); continue; }
    if (seen.value === null && r.value !== null) { byName.set(r.name, r); continue; }
    if (r.text.length > seen.text.length && (r.value !== null || seen.value === null)) {
      byName.set(r.name, r);
    }
  }
  const kept = Array.from(byName.values());
  const keptNames = new Set(kept.map((r) => r.name));
  return { rows: kept, rejected: rejected.filter((r) => !keptNames.has(r.split(':')[0])) };
}, paneSel);

const loadingVisible = (paneSel) => page.evaluate((sel) => {
  const el = document.querySelector(sel + ' .loading-indicator');
  if (!el) return false;
  const r = el.getBoundingClientRect();
  return r.width > 0 && r.height > 0;
}, paneSel);

const report = { url };
report.summary = await page.evaluate(
  () => (document.querySelector('#ct-probe-summary') || {}).textContent || '');
report.panelAMounted = await page.evaluate(
  () => !!document.querySelector('#ct-state-pane .state-component'));
report.panelBMounted = await page.evaluate(
  () => !!document.querySelector('#ct-ordering-pane .state-component'));

// ---- A. the LOCALS tab, holding the recorded locals ----------------------
{
  const r = await readRows('#ct-state-pane');
  report.localsRows = r.rows;
  report.localsRejected = r.rejected;
}

// ---- A. the WATCHES tab, holding the refused watch ----------------------
//
// Reached by a click on the product's own tab button. Absence is a result,
// not a crash: the click is attempted and everything after it runs either
// way, so an arm that removes the button reports a product reading rather
// than an instrument failure.
report.watchesTabClicked = false;
try {
  await page.click('#ct-state-pane .tab-watches', { timeout: 4000 });
  report.watchesTabClicked = true;
} catch (e) {
  report.watchesTabError = String((e && e.message) || e).split('\n')[0];
}
await page.waitForTimeout(400);
{
  const r = await readRows('#ct-state-pane');
  report.watchRows = r.rows;
  report.watchRejected = r.rejected;
}
report.loadingVisibleA = await loadingVisible('#ct-state-pane');

// ---- B. the pane at the end of the ordering sequence --------------------
{
  const r = await readRows('#ct-ordering-pane');
  report.orderingRows = r.rows;
  report.orderingRejected = r.rejected;
}
report.loadingVisibleB = await loadingVisible('#ct-ordering-pane');

// The timeline the probe recorded, lifted out of the summary line so the
// gate can print it beside the verdicts.
report.ordering = await page.evaluate(() => {
  const text = (document.querySelector('#ct-probe-summary') || {}).textContent || '';
  const at = text.indexOf('ordering=');
  if (at < 0) return null;
  try { return JSON.parse(text.slice(at + 'ordering='.length)); } catch (_) { return null; }
});

report.paintedChars = await page.evaluate(
  () => document.body.innerText.replace(/\s+/g, ' ').trim().length);
report.pageErrors = errors.filter((e) => !/ERR_FILE_NOT_FOUND/.test(e));

console.log(JSON.stringify(report, null, 2));
console.log('PROBE_JSON=' + JSON.stringify(report));
if (shot) await page.screenshot({ path: shot });
await browser.close();
