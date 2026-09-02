import { chromium } from 'playwright';
const url = process.argv[2];
const errors = [];
const browser = await chromium.launch({ executablePath: process.env.CT_CHROME });
const page = await browser.newPage();
page.on('pageerror', e => errors.push('pageerror: ' + e.message));
page.on('console', m => { if (m.type() === 'error') errors.push('console: ' + m.text()); });
// INSTRUMENT CONTROL, per ci/test/web-renderer-mounts.sh: this gate once
// blocked a deploy reporting "0 characters on screen" over a DOM that renders
// fine, because the nix Chromium had no fonts and laid out every string with
// zero glyphs. A zero reading from an instrument that cannot produce a
// non-zero one is not evidence. So: prove it can draw letters FIRST.
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
  const rows = q('.low-level-code-instruction');
  const badge = r => (r.querySelector('.low-level-code-instruction-fidelity') || {}).textContent || '';
  const tally = {};
  rows.forEach(r => { const b = badge(r); tally[b] = (tally[b] || 0) + 1; });
  const sync = document.querySelector('.low-level-code-sync');
  const notice = document.querySelector('.low-level-code-notice');
  return {
    summary: (document.getElementById('ct-probe-summary')||{}).textContent || '',
    paneMounted: !!document.querySelector('.component-container.low-level-code'),
    rowCount: rows.length,
    fidelityTally: tally,
    firstRowText: rows.length ? rows[0].innerText.replace(/\s+/g,' ').trim().slice(0,120) : '',
    lastRowText: rows.length ? rows[rows.length-1].innerText.replace(/\s+/g,' ').trim().slice(0,120) : '',
    syncText: sync ? sync.textContent : null,
    syncClass: sync ? sync.className : null,
    noticeText: notice ? notice.textContent : null,
    noticeClass: notice ? notice.className : null,
    countColumns: q('.low-level-code-instruction-count').length,
    paintedChars: document.body.innerText.replace(/\s+/g,' ').trim().length,
  };
});
result.pageErrors = errors;
console.log(JSON.stringify(result, null, 2));
console.log('PROBE_JSON=' + JSON.stringify(result));

// Flip the toggle by clicking it — a real gesture, not a VM call.
await page.click('.low-level-code-sync');
await page.waitForTimeout(300);
const after = await page.evaluate(() => ({
  syncText: document.querySelector('.low-level-code-sync').textContent,
  syncClass: document.querySelector('.low-level-code-sync').className,
  noticeText: (document.querySelector('.low-level-code-notice')||{}).textContent,
  noticeClass: (document.querySelector('.low-level-code-notice')||{}).className,
  fidelityStillDrawn: document.querySelectorAll('.low-level-code-instruction-fidelity').length,
}));
console.log('AFTER CLICK: ' + JSON.stringify(after, null, 2));
await browser.close();
