// run.mjs — measure every Call Trace row, at several root font sizes, in a
// real browser styled by the real stylesheet and the real fonts.
//
// The root font size is set on `documentElement.style.fontSize`, which is
// exactly what the desktop's zoom does (`ui_js.nim` `updateLayout`), and
// nothing else is said to the page.
//
// This program asserts nothing. It reports facts and lets
// `ci/test/calltrace-row-box-in-browser.sh` count assertions over them, so
// the control and the mutation arm read one instrument.
//
// Usage: node run.mjs <url> [screenshot.png]
// Prints a `PROBE_JSON=` line; exits 2 if the page could not be driven.

import { chromium } from 'playwright';

const url = process.argv[2];
const shot = process.argv[3];
if (!url) {
  console.error('usage: run.mjs <url> [screenshot.png]');
  process.exit(2);
}

// The root sizes the desktop reaches: the default (16, `data.ui.fontSize`),
// zoomed in (20), and zoomed out (13 and 12). 13 px makes the row box a
// non-integer (20.3125 px), so a layout that is right only on whole pixels
// is caught.
const ROOT_SIZES = [16, 20, 13, 12];

const errors = [];
const browser = await chromium.launch({ executablePath: process.env.CT_CHROME });
const page = await browser.newPage({ viewport: { width: 900, height: 1500 } });
page.on('pageerror', (e) => errors.push('pageerror: ' + e.message));
page.on('console', (m) => { if (m.type() === 'error') errors.push('console: ' + m.text()); });

await page.goto(url, { waitUntil: 'load' });

const settle = async () => {
  // Fonts load lazily, when text that uses them is laid out; `ready` waits
  // for every load that layout started. Then two frames for the view's
  // deferred measurement and any resize notification.
  await page.evaluate(() => document.fonts.ready);
  await page.evaluate(() => new Promise((res) =>
    requestAnimationFrame(() => requestAnimationFrame(res))));
  await page.waitForTimeout(150);
  await page.evaluate(() => document.fonts.ready);
};

const report = { url, sizes: [] };
report.summary = await page.evaluate(
  () => (document.querySelector('#ct-probe-summary') || {}).textContent || '');

for (const root of ROOT_SIZES) {
  await page.evaluate((px) => { document.documentElement.style.fontSize = px + 'px'; }, root);
  await settle();
  const m = await page.evaluate(() => {
    // A text's BASELINE, relative to its row's top: the top of a 0x0
    // inline-block appended to it, which sits on the baseline
    // (https://www.w3.org/TR/CSS2/visudet.html#propdef-vertical-align) and,
    // being zero-height, cannot move the line it measures. Removed at once.
    const baseline = (el, rowTop) => {
      if (!el) return null;
      const mark = document.createElement('span');
      mark.style.cssText = 'display:inline-block;width:0;height:0;vertical-align:baseline';
      el.appendChild(mark);
      const y = mark.getBoundingClientRect().top - rowTop;
      mark.remove();
      return y;
    };
    const rows = [...document.querySelectorAll('.isonim-calltrace .calltrace-call-line')];
    return rows.map((row) => {
      const r = row.getBoundingClientRect();
      const toggle = row.querySelector('.toggle-call');
      const ret = row.querySelector('.return-text');
      const hasRet = !!(ret && ret.textContent);
      return {
        top: r.top,
        height: r.height,
        toggle: toggle ? toggle.getBoundingClientRect().height : -1,
        returnText: ret ? ret.textContent : '',
        nameBaseline: baseline(row.querySelector('.call-text'), r.top),
        arrowBaseline: hasRet ? baseline(row.querySelector('.return-arrow'), r.top) : null,
        valueBaseline: hasRet ? baseline(ret, r.top) : null,
        args: row.querySelectorAll('.call-arg').length,
        selected: row.classList.contains('event-selected'),
      };
    });
  });
  report.sizes.push({ root, rows: m });
}

// INSTRUMENT CONTROL — THE FONTS. The defect is a disagreement between two
// typefaces' metrics; with either one missing, the fallback face decides the
// layout and the reading is about the fallback, not the product. So the gate
// requires both faces LOADED (not merely declared), and the two halves of a
// return value to actually be set in them.
report.fonts = await page.evaluate(() =>
  [...document.fonts].map((f) => ({ family: f.family.replace(/["']/g, ''), weight: f.weight, status: f.status })));
report.returnFaces = await page.evaluate(() => {
  const row = [...document.querySelectorAll('.isonim-calltrace .calltrace-call-line')]
    .find((r) => (r.querySelector('.return-text') || {}).textContent);
  if (!row) return null;
  const face = (sel) => getComputedStyle(row.querySelector(sel)).fontFamily.replace(/["']/g, '');
  return { arrow: face('.return-arrow'), value: face('.return-text') };
});

report.pageErrors = errors.filter((e) => !/ERR_FILE_NOT_FOUND/.test(e));
console.log('PROBE_JSON=' + JSON.stringify(report));
if (shot) {
  await page.evaluate(() => { document.documentElement.style.fontSize = '16px'; });
  await settle();
  await page.screenshot({ path: shot });
}
await browser.close();
