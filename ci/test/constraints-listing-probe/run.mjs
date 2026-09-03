import { chromium } from 'playwright';
const url = process.argv[2];
const shot = process.argv[3];
const errors = [];
const browser = await chromium.launch({ executablePath: process.env.CT_CHROME });
const page = await browser.newPage({ viewport: { width: 1300, height: 700 } });
page.on('pageerror', e => errors.push('pageerror: ' + e.message));
page.on('console', m => { if (m.type() === 'error') errors.push('console: ' + m.text()); });

// INSTRUMENT CONTROL, per ci/test/low-level-code-browser.sh: a sibling gate
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
await page.waitForTimeout(1500);

const result = await page.evaluate(() => {
  const q = s => Array.from(document.querySelectorAll(s));
  const txt = s => ((document.querySelector(s) || {}).textContent || '').trim();
  // LAID OUT, not merely present. A row in the DOM with a zero-height box is
  // not a row a user can read, and that is the exact difference this pane's
  // whole defect was about.
  const rows = q('#ct-listing-pane .constraints-opcode');
  const laid = rows.filter(r => {
    const b = r.getBoundingClientRect();
    return b.width > 0 && b.height > 0;
  });
  return {
    summary: txt('#ct-probe-summary'),
    paneMounted: !!document.querySelector('#ct-listing-pane .component-container.constraints'),
    headline: txt('#ct-listing-pane .constraints-headline'),
    opcodeRows: rows.length,
    opcodeRowsLaidOut: laid.length,
    functionHeadings: q('#ct-listing-pane .constraints-row').map(r => r.innerText.replace(/\s+/g, ' ').trim()),
    firstRowText: rows.length ? rows[0].innerText.replace(/\s+/g, ' ').trim() : '',
    lastRowText: rows.length ? rows[rows.length - 1].innerText.replace(/\s+/g, ' ').trim() : '',
    // The pane must SCROLL to the long field constants rather than clip them.
    listingScrollWidth: (document.querySelector('#ct-listing-pane .constraints') || {}).scrollWidth || 0,
    listingClientWidth: (document.querySelector('#ct-listing-pane .constraints') || {}).clientWidth || 0,
    countsNotice: txt('#ct-counts-pane .constraints-listing-notice'),
    countsRows: q('#ct-counts-pane .constraints-row').length,
    countsOpcodeRows: q('#ct-counts-pane .constraints-opcode').length,
    degradedHeadline: txt('#ct-degraded-pane .constraints-headline'),
    degradedNotice: txt('#ct-degraded-pane .constraints-listing-notice'),
    degradedRows: q('#ct-degraded-pane .constraints-row').length,
    paintedChars: document.body.innerText.replace(/\s+/g, ' ').trim().length,
  };
});
result.pageErrors = errors.filter(e => !/ERR_FILE_NOT_FOUND/.test(e));
console.log(JSON.stringify(result, null, 2));
console.log('PROBE_JSON=' + JSON.stringify(result));
if (shot) await page.screenshot({ path: shot });
await browser.close();
