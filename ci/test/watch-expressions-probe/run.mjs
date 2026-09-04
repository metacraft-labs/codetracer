// run.mjs — drive the State pane in a real browser and TYPE a watch
// expression into it, the way a user does.
//
// Every interaction below is a gesture on the product's own controls: a
// click on the Watches tab button, keystrokes into `#watch-0`, Enter to
// submit the form. Nothing calls a ViewModel. That is the whole point —
// until the tab strip was added to the WebRenderer panel, `stWatches` was
// reachable only from `vm.selectTab`, so a probe that switched tabs that
// way would have passed against a product no user could navigate.
//
// This program asserts nothing. It reports facts and lets
// `ci/test/watch-expressions-in-browser.sh` count assertions over them, so
// the arms and the control read one instrument.

import { chromium } from 'playwright';

const url = process.argv[2];
const shot = process.argv[3];
if (!url) {
  console.error('usage: run.mjs <url> [screenshot.png]');
  process.exit(2);
}

const errors = [];
const browser = await chromium.launch({ executablePath: process.env.CT_CHROME });
const page = await browser.newPage({ viewport: { width: 900, height: 720 } });
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
await page.waitForTimeout(800);

// Read the pane's rows the way a reader sees them: LAID OUT, hit-tested at
// their own start point. A row in the DOM with a zero-height box, or one
// covered by something else, is not a row a user can read — and "the pane
// has content" that nobody can see is precisely the failure mode this
// campaign keeps finding.
const readRows = () => page.evaluate(() => {
  const out = [];
  const rejected = [];
  for (const el of document.querySelectorAll('#ct-state-pane [data-variable-name]')) {
    const name = el.getAttribute('data-variable-name') || '';
    const text = (el.innerText || el.textContent || '').replace(/\s+/g, ' ').trim();
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
    out.push({ name, text });
  }
  // ONE ROW PER NAME. The view stamps `data-variable-name` on two nested
  // elements per row (the row and its name span), so every row matches
  // twice and the inner one can be zero-sized while the outer is laid out.
  // Keeping the LONGEST text per name picks the element that carries the
  // whole row rather than just the label, and stops the rejection list from
  // reporting a healthy row as invisible.
  const byName = new Map();
  for (const r of out) {
    const seen = byName.get(r.name);
    if (!seen || r.text.length > seen.text.length) byName.set(r.name, r);
  }
  const kept = Array.from(byName.values());
  const keptNames = new Set(kept.map((r) => r.name));
  return { rows: kept, rejected: rejected.filter((r) => !keptNames.has(r.split(':')[0])) };
});

const tabState = () => page.evaluate(() => {
  const cls = (s) => {
    const el = document.querySelector('#ct-state-pane ' + s);
    return el ? el.className : null;
  };
  return {
    localsTab: cls('.tab-locals'),
    globalsTab: cls('.tab-globals'),
    watchesTab: cls('.tab-watches'),
    emptyOverlay: (() => {
      const el = document.querySelector('#ct-state-pane .empty-overlay');
      if (!el) return null;
      const r = el.getBoundingClientRect();
      return { text: (el.innerText || '').trim(), visible: r.width > 0 && r.height > 0 };
    })(),
  };
});

const report = { url };
report.summary = await page.evaluate(
  () => (document.querySelector('#ct-probe-summary') || {}).textContent || '');
report.paneMounted = await page.evaluate(
  () => !!document.querySelector('#ct-state-pane .state-component'));

// ---- 1. the tab strip exists at all, in the WEB renderer ----------------
report.tabsBefore = await tabState();
report.watchInputPresent = await page.evaluate(
  () => !!document.querySelector('#ct-state-pane #watch-0'));

// ---- 2. the LOCALS tab is what opens, and holds the recorded locals -----
{
  const r = await readRows();
  report.localsRows = r.rows;
  report.localsRejected = r.rejected;
}

// ---- 3. CLICK the Watches tab. A gesture, not a ViewModel call. --------
//
// ABSENCE IS A RESULT, NOT A CRASH. Mutation arm A removes the tab strip to
// reproduce the pre-fix WebRenderer, and a probe that threw on the missing
// button would report "the probe did not complete" — an instrument failure
// where the arm needs a product reading. So the click is attempted, its
// outcome recorded, and everything after it runs either way.
report.watchesTabClicked = false;
try {
  await page.click('#ct-state-pane .tab-watches', { timeout: 4000 });
  report.watchesTabClicked = true;
} catch (e) {
  report.watchesTabError = String((e && e.message) || e).split('\n')[0];
}
await page.waitForTimeout(400);
report.tabsAfterClick = await tabState();
{
  const r = await readRows();
  report.watchRows = r.rows;
  report.watchRejected = r.rejected;
}

// ---- 4. TYPE a new expression into the product's own input -------------
//
// Keystrokes and Enter, because the form's `submit` handler is the only
// path a user has to `StateVM.addWatch`; setting `.value` would bypass it.
try {
  await page.click('#ct-state-pane #watch-0', { timeout: 4000 });
  await page.type('#ct-state-pane #watch-0', 'landing_point.x', { delay: 15 });
  await page.press('#ct-state-pane #watch-0', 'Enter');
} catch (e) {
  report.typingError = String((e && e.message) || e).split('\n')[0];
}
await page.waitForTimeout(500);
report.inputClearedAfterSubmit = await page.evaluate(
  () => (document.querySelector('#ct-state-pane #watch-0') || {}).value === '');
{
  const r = await readRows();
  report.rowsAfterTyping = r.rows;
}

// ---- 5. and an expression the recording cannot answer -------------------
try {
  await page.click('#ct-state-pane #watch-0', { timeout: 4000 });
  await page.type('#ct-state-pane #watch-0', 'not_recorded_here', { delay: 15 });
  await page.press('#ct-state-pane #watch-0', 'Enter');
} catch (e) {
  report.refusalTypingError = String((e && e.message) || e).split('\n')[0];
}
await page.waitForTimeout(500);
{
  const r = await readRows();
  report.rowsAfterRefusal = r.rows;
}

// THE LOADING INDICATOR MUST BE GONE. A pane painting "Loading..." over
// rows that are already there is the same class of defect as a blank one:
// it tells the reader the value they are looking at is not to be trusted.
report.loadingVisible = await page.evaluate(() => {
  const el = document.querySelector('#ct-state-pane .loading-indicator');
  if (!el) return false;
  const r = el.getBoundingClientRect();
  return r.width > 0 && r.height > 0;
});

report.paintedChars = await page.evaluate(
  () => document.body.innerText.replace(/\s+/g, ' ').trim().length);
report.pageErrors = errors.filter((e) => !/ERR_FILE_NOT_FOUND/.test(e));

console.log(JSON.stringify(report, null, 2));
console.log('PROBE_JSON=' + JSON.stringify(report));
if (shot) await page.screenshot({ path: shot });
await browser.close();
