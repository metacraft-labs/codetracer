// chord_stopcallback_probe.mjs — what does the OVERRIDE actually buy?
//
// `ui/shortcuts.nim:318` replaces `Mousetrap.prototype.stopCallback` with one
// that returns `false` for everything. Mousetrap's default returns `true` —
// i.e. swallow the chord — when the event target is an INPUT / SELECT /
// TEXTAREA / `isContentEditable`, unless the element carries the class
// `mousetrap` or belongs to the instance's own target.
//
// So the override is load-bearing exactly where the DEFAULT would have said
// "stop". This program finds those elements in a real tab and names them,
// because the fix for the double-delivery hazard turns entirely on whether the
// override is still buying anything: Monaco in current Chromium takes its
// keystrokes on a `div.native-edit-context` under the EditContext API, not on
// the `textarea.inputarea` the default check was written against.
//
// Reports facts. The shell counts assertions.

import { chromium } from 'playwright';

const url = process.argv[2];
const settleMs = Number(process.argv[3] || 9000);
if (!url) {
  console.error('usage: chord_stopcallback_probe.mjs <url> [settleMs]');
  process.exit(2);
}

const browser = await chromium.launch({});
const page = await browser.newPage({ viewport: { width: 1440, height: 900 } });
const pageErrors = [];
page.on('pageerror', (e) =>
  pageErrors.push(String((e && e.message) || e).slice(0, 300)));

let loadError = '';
try {
  await page.goto(url, { waitUntil: 'load', timeout: 60000 });
  await page.waitForTimeout(settleMs);
} catch (e) {
  loadError = String((e && e.message) || e).slice(0, 300);
}

// Click into the editor so the Monaco edit host is real and focused.
try {
  const ed = await page.$('.monaco-editor .view-lines');
  if (ed) { await ed.click(); await page.waitForTimeout(400); }
} catch (e) { /* reported via focus below */ }

const report = await page.evaluate(() => {
  // Mousetrap's DEFAULT rule, transcribed from
  // `node_modules/mousetrap/mousetrap.js` (`Mousetrap.prototype.stopCallback`).
  // Written out here rather than called, because the product has already
  // replaced the real one — the question is what the default WOULD say.
  function defaultWouldStop(el) {
    if (!el) return null;
    if ((' ' + (el.className || '') + ' ').indexOf(' mousetrap ') > -1) {
      return false;
    }
    return el.tagName === 'INPUT' || el.tagName === 'SELECT' ||
      el.tagName === 'TEXTAREA' || el.isContentEditable;
  }

  const active = document.activeElement;

  // Every element in the page a caret could sit in, classified. This is the
  // set the override protects — or does not.
  const candidates = Array.from(document.querySelectorAll(
    'input, select, textarea, [contenteditable]'));

  const describe = (el) => ({
    tag: el.tagName,
    cls: String(el.className || '').slice(0, 70),
    id: String(el.id || '').slice(0, 40),
    contentEditable: !!el.isContentEditable,
    hasMousetrapClass:
      (' ' + (el.className || '') + ' ').indexOf(' mousetrap ') > -1,
    // TRUE means: without the override this element would swallow chords.
    defaultWouldStop: defaultWouldStop(el),
  });

  return {
    monacoEditors: document.querySelectorAll('.monaco-editor').length,
    // The element Monaco actually focuses in this browser.
    activeElement: active ? describe(active) : null,
    activeInsideMonaco: !!(active && active.closest &&
      active.closest('.monaco-editor')),
    // Legacy Monaco input host, for comparison with the EditContext one.
    hasTextareaInputArea:
      !!document.querySelector('.monaco-editor textarea.inputarea'),
    hasNativeEditContext:
      !!document.querySelector('.monaco-editor .native-edit-context'),
    candidateCount: candidates.length,
    // The ones that WOULD be blocked by the default — the override's whole
    // reason to exist, enumerated by name.
    blockedByDefault: candidates.filter((el) => defaultWouldStop(el) === true)
      .map(describe),
    // The ones already exempt because the product tagged them `mousetrap`.
    exemptByClass: candidates.filter((el) =>
      (' ' + (el.className || '') + ' ').indexOf(' mousetrap ') > -1)
      .map(describe),
  };
});

console.log(JSON.stringify({ url, loadError, pageErrors, report }, null, 2));
await browser.close();
