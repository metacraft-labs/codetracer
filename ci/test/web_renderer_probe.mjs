// web_renderer_probe.mjs — load a built Noir Studio bundle in a real browser
// and report what a user would see.
//
// WHY A BROWSER AND NOT A GREP
// ----------------------------
// Every check this repository had over the web bundle read BYTES: the renderer
// compiled, the document referenced it, the file was served at the size it was
// uploaded at, the boot arm printed `ok`. All four were true of a deployment
// that painted a blank page for a week, because none of them is *a page that
// paints*. Verification-Harness-Traps.md calls this trap 2 — "a chain of
// `success: true` is not a result; assert the artefact" — and the artefact here
// is a DOM.
//
// This program does not assert anything. It reports facts and lets
// `web-renderer-mounts.sh` count assertions over them, so that the mutation
// arms and the control arm read the same instrument.
//
// The single most important field is `pageErrors`. The defect that shipped was
// an uncaught `ReferenceError` thrown after the boot line, and traps doc 3 says
// why nothing saw it: "a module that fails to load leaves no in-page error".
// A harness that does not subscribe to `pageerror` cannot tell a renderer that
// mounted from one that died on its first statement.

import { chromium } from 'playwright';

const url = process.argv[2];
const settleMs = Number(process.argv[3] || 9000);
if (!url) {
  console.error('usage: web_renderer_probe.mjs <url> [settleMs]');
  process.exit(2);
}

const browser = await chromium.launch();
const page = await browser.newPage({ viewport: { width: 1440, height: 900 } });

const pageErrors = [];
const consoleLines = [];
const failedRequests = [];

page.on('pageerror', (e) =>
  pageErrors.push(String((e && e.message) || e).slice(0, 300)));
page.on('console', (m) => consoleLines.push(`${m.type()}: ${m.text().slice(0, 400)}`));
page.on('response', (r) => {
  if (r.status() >= 400) failedRequests.push(`${r.status()} ${r.url()}`);
});

let loadError = '';
try {
  await page.goto(url, { waitUntil: 'load', timeout: 60000 });
  await page.waitForTimeout(settleMs);
} catch (e) {
  loadError = String((e && e.message) || e).slice(0, 300);
}

let dom = {};
try {
  dom = await page.evaluate(() => {
    const root = document.getElementById('dom-root');
    const text = (document.body.innerText || '').trim();
    return {
      // The subject of every assertion below it. Reported separately from its
      // contents so "the probe looked at nothing" and "the probe looked at an
      // empty page" are different sentences — traps doc 4, the empty haystack.
      domRootPresent: !!root,
      domRootHtmlLength: root ? root.innerHTML.trim().length : -1,
      domRootElementCount: root ? root.querySelectorAll('*').length : -1,
      // The product's OWN class constants, from
      // viewmodel/views/isonim_welcome_screen_view.nim. A class name is what
      // the view code emits, so a check on it reads the renderer's output
      // rather than the document's skeleton — the skeleton is in index.html
      // and would satisfy an id-based check while empty.
      welcomeScreenRoots: document.querySelectorAll('.welcome-screen-root').length,
      startOptions: document.querySelectorAll('.start-option').length,
      recentPanels:
        document.querySelectorAll('.recent-folders, .recent-traces').length,
      // What a person reads off the screen. `innerText` is defined over the
      // RENDERED text — it is the field that answers "is there a product on
      // this page", and the only one of the two that a screenshot agrees with.
      visibleText: text.slice(0, 1200),
      visibleTextLength: text.length,
      // ...and what the DOM merely CONTAINS. Reported beside it and asserted
      // by nothing, because the pair is a diagnostic and not a verdict: when
      // `domTextLength` is large and `visibleTextLength` is 0, the markup is
      // right and the browser drew nothing, which is a fault in the machine
      // running the check rather than in the thing being checked. Reading
      // this one INSTEAD would make the gate pass over the blank page it
      // exists to catch, so it stays out of every assertion.
      domTextLength: (document.body.textContent || '').trim().length,
      title: document.title,
    };
  });
} catch (e) {
  dom = { evaluateError: String((e && e.message) || e).slice(0, 300) };
}

let screenshotWritten = '';
if (process.env.CT_PROBE_SCREENSHOT) {
  try {
    await page.screenshot({ path: process.env.CT_PROBE_SCREENSHOT });
    screenshotWritten = process.env.CT_PROBE_SCREENSHOT;
  } catch (e) {
    /* a screenshot is a convenience, never a verdict */
  }
}

await browser.close();

console.log(
  JSON.stringify(
    {
      url,
      loadError,
      dom,
      pageErrors,
      failedRequests: [...new Set(failedRequests)],
      // The two arms' own sentences, picked out of the console rather than the
      // DOM: the renderer hides its status element on success, and a headless
      // check must not depend on a diagnostic staying visible to a user.
      bootLine:
        consoleLines.find((l) => l.includes('codetracer-web-boot:')) || '',
      rendererLine:
        consoleLines.find((l) => l.includes('codetracer-web-renderer:')) || '',
      consoleErrorCount: consoleLines.filter((l) => l.startsWith('error:')).length,
      screenshotWritten,
    },
    null,
    2
  )
);
