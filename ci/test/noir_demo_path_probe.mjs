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

// THE BUILD PANE IS SAMPLED WHILE IT IS ON SCREEN, NOT ONCE THE RUN IS OVER.
//
// This used to be `await sleep(RUN_MS)` followed by a single read of
// `#buildComponent-0`. That read the pane a full RUN_MS (60s) after Run, and
// was correct only for as long as nothing ever took the pane down again.
//
// Something now does, deliberately. BUILD is auto-hidden on this surface:
// `ensureBuildPaneVisible` reveals it through the auto-hide OVERLAY to show
// compiler output, and since `fix(replay): dismiss the BUILD overlay when the
// session mounts` the web path calls `build.autoDismissBuildPanel()` when the
// replay session mounts — it keeps the overlay up for 2 SECONDS so a success
// is readable, then hides it. That fix is not optional: while the overlay is
// up, `#auto-hide-backdrop` is a transparent `position: fixed` layer over the
// WHOLE VIEWPORT, so every pointer gesture over the workspace lands on it and
// the reported "in Debug mode there is no context menu at all" follows.
//
// So the pane reports the replay session, and 2s later `innerText` on a hidden
// element is the empty string. The old single read landed ~58s into that
// emptiness and the gate reported "the Build pane did not report a replay
// session:" with NOTHING after the colon — a true statement about the sample
// and a false one about the product. The replay session was demonstrably
// there: the calltrace, the flow view and the event log all rendered it in the
// same run.
//
// Polling is what makes the claim observable at all now. It is also the
// STRONGER claim: it asserts the pane put the message in front of a visitor
// during its visible window, rather than that the message was still lying
// around a minute later. Reading `innerText` dispatches no input events, so it
// cannot cancel the 2s dismiss (which cancels only on `pointerdown`/`keydown`
// over the overlay).
const readBuildText = () => page.evaluate(() => {
  const el = document.getElementById('buildComponent-0');
  return el ? (el.innerText || '').replace(/\s+/g, ' ').slice(0, 600) : null;
});
// A VERDICT is either of the two outcomes the gate distinguishes. Once one is
// on screen it is kept, so a later empty sample cannot overwrite it; before
// one appears the newest non-empty sample is kept, so a run that never reaches
// a verdict still reports what the pane last said instead of nothing.
const isVerdict = (t) => !!t
  && (t.includes('opening a replay session') || t.includes('did not produce a trace'));
// 200ms against a 2000ms window: ~10 samples inside it, so catching it does
// not depend on landing a single lucky read.
const BUILD_POLL_MS = 200;
const runStartedAt = Date.now();
let buildSamples = 0;
let buildNonEmptySamples = 0;
out.buildText = null;
out.buildTextObservedAtMs = null;
while (Date.now() - runStartedAt < RUN_MS) {
  const sample = await readBuildText();
  buildSamples += 1;
  if (sample && sample.trim() !== '') {
    buildNonEmptySamples += 1;
    if (!isVerdict(out.buildText)) {
      out.buildText = sample;
      out.buildTextObservedAtMs = Date.now() - runStartedAt;
    }
  }
  await sleep(BUILD_POLL_MS);
}
out.buildSamples = buildSamples;
out.buildNonEmptySamples = buildNonEmptySamples;
// What the pane says at the END of the run, kept separate from the sampled
// verdict so a failure can be told apart: an empty `buildTextFinal` next to a
// populated `buildText` is the pane correctly getting out of the way, while
// both empty is the pane never having reported at all.
out.buildTextFinal = await readBuildText();

// AND THAT IT GOT OUT OF THE WAY. The assertion above can now be satisfied by
// a 2-second appearance, so on its own it would no longer notice an overlay
// that went up and STAYED up — which is the defect the dismiss fixed, and
// which this path is where a visitor meets. Measured the way the defect was:
// what does the viewport hand back over the middle of the editor?
out.overlayAtEnd = await page.evaluate(() => {
  const overlay = document.getElementById('auto-hide-overlay');
  const backdrop = document.getElementById('auto-hide-backdrop');
  const desc = (el) => (el
    ? `${el.tagName.toLowerCase()}${el.id ? '#' + el.id : ''}`
    : null);
  // The LARGEST PAINTED editor, not `querySelector`'s first match. Restored
  // tabs leave several `.monaco-editor` nodes in the DOM and the first is
  // routinely an inactive one with a zero-area rect; centring on that would
  // make `elementFromPoint` answer about a point no visitor can click, and the
  // check would pass without having looked at the workspace at all.
  let editor = null;
  let editorArea = 0;
  for (const el of document.querySelectorAll('.monaco-editor')) {
    if (!el.querySelector('.view-lines')) continue;
    const r = el.getBoundingClientRect();
    const area = r.width * r.height;
    if (area > editorArea) { editor = el; editorArea = area; }
  }
  let hitAtEditorCentre = null;
  if (editor && editorArea > 0) {
    const r = editor.getBoundingClientRect();
    hitAtEditorCentre = desc(
      document.elementFromPoint(r.left + r.width / 2, r.top + r.height / 2));
  }
  return {
    overlayVisible: !!overlay && overlay.classList.contains('visible'),
    overlayTitle: (document.getElementById('auto-hide-overlay-title') || {}).textContent || '',
    backdropShown: !!backdrop
      && getComputedStyle(backdrop).display !== 'none',
    // Only true for an editor with a real area, so "no editor to check over"
    // fails the gate instead of quietly satisfying it.
    editorFound: !!editor && editorArea > 0 && hitAtEditorCentre !== null,
    editorArea: Math.round(editorArea),
    hitAtEditorCentre,
  };
});

out.topbarSurface = await page.evaluate(() => {
  const el = document.querySelector('[data-topbar-surface]');
  return el ? el.getAttribute('data-topbar-surface') : null;
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

// --- arm D: a RELOAD keeps the tabs, and the tabs keep their files ----------
//
// Reported as *"initially the editor has all files already opened as tab, but
// the tabs are not populated; I need to close the tabs and re-open the files to
// properly load their content"*.
//
// This needs its OWN context and a reload inside it, which is why it cannot be
// folded into the arrival page above. `browser.newPage()` gives each page a
// fresh context, and the whole defect lives in what a SECOND load does with
// what the first one persisted: since `2b480df0a` (on top of `eb597f69a`'s
// `CODETRACER_MODE_LAYOUT_EDIT`) the edit layout comes from localStorage, so
// the restored config names one `editorComponent` per tab the visitor had open.
// `renderer.createUIComponents` builds a component for each and nothing asks
// for its source, so every restored tab mounted blank — measured on the
// deployed `4e9cff5ae`: five tabs, `hasMonaco === false` on all five, and zero
// source models in the page.
//
// NAMED FILES WITH KNOWN CONTENT, not "some tab has text". The two files below
// are opened by this arm explicitly, so the assertion cannot be satisfied by
// whichever file the entry heuristic happens to pick, and it does not depend on
// the template's file LIST — a demo that gains a README still has to satisfy it.
{
  const ctx = await browser.newContext({ viewport: { width: 1680, height: 1050 } });
  const p = await ctx.newPage();
  const reloadErrors = [];
  p.on('pageerror', (e) => reloadErrors.push(String((e && e.message) || e).slice(0, 300)));
  await p.goto(`${base}/noir/demo`, { waitUntil: 'load' });
  await sleep(MOUNT_MS);

  const FS = '[id^="filesystemComponent"]';
  const opened = [];
  for (const f of ['config.nr', 'sort.nr']) {
    try {
      await p.locator(`${FS} >> text="${f}"`).first().click({ timeout: 15000 });
      opened.push(f);
      await sleep(2500);
    } catch (e) { /* reported below as a missing entry */ }
  }
  out.restoredOpened = opened;
  await sleep(4000);

  // THE RELOAD IS THE MEASUREMENT. No gesture after it: the workaround this
  // gate exists to make unnecessary is a close and a re-open, so performing one
  // here would assert the workaround rather than the fix.
  await p.reload({ waitUntil: 'load' });
  await sleep(MOUNT_MS + 6000);

  out.restoredTabs = await p.evaluate(() => {
    const d = window.data;
    const eds = (d && d.ui && d.ui.editors) || {};
    const res = {};
    for (const k of Object.keys(eds)) {
      const e = eds[k];
      let model = null;
      try { model = e && e.monacoEditor && e.monacoEditor.getModel && e.monacoEditor.getModel(); } catch (err) { /* not mounted */ }
      const dom = (e && e.monacoEditor && e.monacoEditor.getDomNode && e.monacoEditor.getDomNode()) || null;
      const lines = dom ? dom.querySelector('.view-lines') : null;
      res[String(k)] = {
        hasMonaco: !!(e && e.monacoEditor),
        len: model ? model.getValue().length : 0,
        text: model ? model.getValue().slice(0, 400) : '',
        rendered: lines ? (lines.innerText || '').trim().length : -1,
      };
    }
    return res;
  });
  out.restoredTabTitles = await p.evaluate(() =>
    Array.from(document.querySelectorAll('.lm_title')).map((t) => t.textContent.trim()).slice(0, 12));
  out.restoredPageErrors = reloadErrors.slice(0, 10);
  await ctx.close();
}

console.log(JSON.stringify(out, null, 2));
await browser.close();
