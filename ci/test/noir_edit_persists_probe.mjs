// The gesture, driven in a real browser: edit, save, RELOAD, read it back.
//
// Emits one JSON document on stdout. `ci/test/noir-edit-persists.sh` asserts
// against it; nothing here decides pass or fail, so an arm cannot be green
// because the probe was lenient.
//
// WHY A RELOAD AND NOT A ROUND TRIP. A same-page check — write, read back,
// compare — is satisfied by a variable. The claim under test is that the work
// is in ORIGIN STORAGE, and the only way to observe that is to destroy every
// piece of JavaScript state that could be holding it. `page.reload()` does
// exactly that and keeps the origin, so OPFS is the only channel by which a
// byte can cross.
//
// AND WHY A SECOND, FRESH CONTEXT. "The marker is present after a reload"
// would also be true of a bundle that happened to contain the marker. The
// `fresh` arm opens a brand-new browser context — a new origin storage
// partition, same bytes — and requires the marker to be ABSENT there. Together
// the two say: it came from storage, not from the bundle.

import { chromium } from 'playwright';
import http from 'http';
import fs from 'fs';
import path from 'path';

const bundle = process.argv[2];
const MARKER = process.argv[3] || 'EDIT_PERSISTS_MARKER';

const TYPES = {
  '.html': 'text/html', '.js': 'text/javascript', '.css': 'text/css',
  '.wasm': 'application/wasm', '.json': 'application/json',
  '.map': 'application/json', '.ttf': 'font/ttf', '.woff': 'font/woff',
  '.woff2': 'font/woff2', '.svg': 'image/svg+xml', '.png': 'image/png',
};

const server = http.createServer((req, res) => {
  const p = decodeURIComponent(req.url.split('?')[0]);
  let f = path.join(bundle, p);
  // The deployment serves the entry document for every route it owns; this is
  // the 200-rewrite `renderRewriteConfig` emits, which is what makes `/noir`
  // reach the renderer with its path intact.
  if (!fs.existsSync(f) || fs.statSync(f).isDirectory()) {
    f = path.join(bundle, 'index.html');
  }
  res.writeHead(200, {
    'Content-Type': TYPES[path.extname(f)] || 'application/octet-stream',
  });
  fs.createReadStream(f).pipe(res);
});

await new Promise((r) => server.listen(0, '127.0.0.1', r));
const url = `http://127.0.0.1:${server.address().port}/noir`;

const out = {
  mounted: false, mountedAfterReload: false,
  // The durability sentence, as the product now delivers it: a Notification in
  // the shared status-bar toast stack.
  legacyBannerPresent: null,
  noticeFound: false, noticeText: '', noticeChars: 0, noticePainted: false,
  noticeClass: '', noticeHasDismiss: false, noticeHasExport: false,
  noticeDismissed: null,
  // HOW MANY OF IT THERE ARE, and how far the lowest one clears the bar.
  // Both reported from the live page; the caller compares
  // `noticeGapToStatusBar` against `noticeRowGap` rather than against a
  // number, so the spacing can change without editing an assertion.
  noticeCount: 0, toastCount: 0,
  noticeRowGap: null, noticeInterGap: null, noticeGapToStatusBar: null,
  noticeLowestBottom: null, noticeBarTop: null,
  noticeLowestBottomCovered: null, noticeLowestBottomHit: '',
  // `ui/status.nim`'s delivery counter, either side of the load.
  statsBefore: null, statsAfter: null,
  // Diagnostics for a duplication report; nothing asserts on these.
  notificationFanout: [], statusRegistrations: [],
  // THE COMPLAINT, MEASURED. The banner was `position:fixed; bottom:0;
  // z-index:2147483646` and the status bar is the bottom strip underneath it.
  statusBarFound: false, statusBarUnobscured: false,
  statusBarProbePoints: 0, statusBarCoveredBy: [],
  statusBarRect: null,
  // Once per browser session, not once per load.
  noticeAfterReload: null,
  noticeInFreshContext: null,
  markerBeforeReload: false, markerAfterReload: false,
  editedContent: '', restoredContent: '', bundledContent: '',
  freshContextMarker: null,
  sawNoHostForSaveFile: false, sawSavedFile: false,
  editorModels: 0, error: '',
};

const browser = await chromium.launch();

async function waitForEditMode(page) {
  await page.waitForFunction(
    () => document.querySelectorAll('.monaco-editor').length > 0,
    null, { timeout: 60000 });
  // The mount continues after the first Monaco node exists: `onNoTrace` opens
  // the initial tab and the host answers `tab-load` a task later.
  await page.waitForFunction(
    () => !!window.monaco &&
      window.monaco.editor.getModels().some((m) => m.getValue().length > 0),
    null, { timeout: 60000 });
  await page.waitForTimeout(1200);
}

// Hit-tested, not read out of `innerText`. The instrument failure this codebase
// records: 379 characters of diagnostic were counted by `innerText`, laid out in
// the page, and visible to nobody because another element painted over them. So
// the sentence must BE the element the browser finds at its own centre.
//
// It is now a Notification in `#active-notifications` — the toast stack in
// `ui/status.nim` that every other message in this product goes through —
// rather than a bespoke `<div id="codetracer-durability">` appended to
// `document.body` at `bottom:0` with the largest representable z-index. The
// old surface is asserted ABSENT below; it is the thing that covered the bar.
async function durabilityNotice(page) {
  return await page.evaluate(() => {
    const out = {
      legacyBanner: !!document.getElementById('codetracer-durability'),
      found: false, text: '', chars: 0, painted: false, cls: '',
      hasDismiss: false, hasExport: false,
    };
    const host = document.getElementById('active-notifications');
    if (!host) return out;
    const items = Array.from(host.querySelectorAll('.status-notification'));
    // Identified by the gesture it names rather than by position in the stack,
    // so an unrelated toast arriving first cannot be mistaken for it.
    const el = items.find((n) => (n.textContent || '').includes('Ctrl+Shift+E'));
    if (!el) return out;
    out.found = true;
    out.cls = el.className || '';
    const msg = el.querySelector('.notification-message');
    out.text = ((msg ? msg.textContent : el.textContent) || '').trim();
    out.chars = out.text.length;
    out.hasDismiss = !!el.querySelector('.dismiss-notification-button');
    out.hasExport = Array.from(el.querySelectorAll('.notification-action-button'))
      .some((a) => /export/i.test(a.textContent || ''));
    const r = el.getBoundingClientRect();
    if (r.width < 1 || r.height < 1) return out;
    const cx = r.left + r.width / 2, cy = r.top + r.height / 2;
    if (cx < 0 || cy < 0 || cx > innerWidth || cy > innerHeight) return out;
    const hit = document.elementFromPoint(cx, cy);
    const style = getComputedStyle(el);
    out.painted = !!hit && (hit === el || el.contains(hit)) &&
      style.visibility !== 'hidden' && style.display !== 'none' &&
      parseFloat(style.opacity || '1') > 0.05 && out.chars > 0;
    return out;
  });
}

// THE ACCEPTANCE. Not "a notification appears" — "the status bar is not
// covered", measured while the notice is on screen, which is when the banner
// used to cover it.
//
// `el.contains(hit)` alone would be satisfied vacuously by `document.body`,
// which contains everything: an obscuring overlay is a child of body too. So
// the test walks UP from the hit element and requires `#status` on the way —
// "the pixel at this point belongs to the status bar" — and records what it
// found when it does not.
async function statusBarUnobscured(page) {
  return await page.evaluate(() => {
    const bar = document.getElementById('status-base');
    if (!bar) return { found: false, unobscured: false, points: 0, coveredBy: [], rect: null };
    const r = bar.getBoundingClientRect();
    const rect = { x: r.left, y: r.top, w: r.width, h: r.height };
    if (r.width < 1 || r.height < 1) {
      return { found: true, unobscured: false, points: 0, coveredBy: ['zero-sized'], rect };
    }
    const owned = (node) => {
      let n = node;
      while (n) { if (n.id === 'status') return true; n = n.parentElement; }
      return false;
    };
    const describe = (n) => !n ? 'nothing' :
      (n.tagName.toLowerCase() +
       (n.id ? '#' + n.id : '') +
       (typeof n.className === 'string' && n.className
         ? '.' + n.className.trim().split(/\s+/).join('.') : ''));
    const cy = r.top + r.height / 2;
    // Three points across the bar, not one: the old banner spanned the full
    // width, but a narrower overlay covering only the location readout on the
    // right would be just as much of a defect and a single centre probe would
    // miss it.
    const xs = [0.15, 0.5, 0.85].map((f) => r.left + r.width * f);
    const coveredBy = [];
    let points = 0;
    for (const cx of xs) {
      if (cx < 0 || cy < 0 || cx > innerWidth || cy > innerHeight) continue;
      points += 1;
      const hit = document.elementFromPoint(cx, cy);
      if (!owned(hit)) coveredBy.push(describe(hit));
    }
    return {
      found: true,
      unobscured: points > 0 && coveredBy.length === 0,
      points,
      coveredBy,
      rect,
    };
  });
}

// HOW MANY, AND HOW FAR ABOVE THE BAR. Two measurements the checks above
// could not make, both from a report against the live site: three identical
// copies of the durability notice, the lowest of them clipped by the status
// bar.
//
// NEITHER DEFECT WAS VISIBLE TO THE ASSERTIONS BESIDE THIS ONE, and that is
// worth stating because both gates were green while both defects shipped:
//
//   * `durabilityNotice` uses `items.find(...)`, which takes the FIRST match
//     and cannot report that there were three. A duplicate is indistinguishable
//     from the intended single notice through that lens.
//   * `statusBarUnobscured` asks whether the BAR is covered by a toast. This
//     defect is the other direction — the bar covers the TOAST — and a bar
//     that is fully painted is exactly what a clipped toast underneath it
//     looks like.
//   * `noticePainted` hit-tests the toast's CENTRE. A toast whose bottom two
//     pixels are behind the bar still answers for its own centre.
//
// So the count is counted, and the clearance is measured against the spacing
// the stack already uses between toasts rather than against a number written
// here. `gap` is read from the live computed style, so this stays correct when
// the design changes the spacing — a test naming the number would have to be
// edited in the same commit and would pass for the wrong reason if it were not.
async function noticeGeometry(page) {
  return await page.evaluate(() => {
    const out = {
      count: 0, total: 0, rowGap: null, interGap: null, gapToStatusBar: null,
      lowestBottomCovered: null, lowestBottomHit: '', barTop: null,
      lowestBottom: null,
    };
    const host = document.getElementById('active-notifications');
    const bar = document.getElementById('status-base');
    if (!host || !bar) return out;
    const items = Array.from(host.querySelectorAll('.status-notification'));
    out.total = items.length;
    // Counted by the same identification `durabilityNotice` uses to FIND one,
    // so "how many" and "which" cannot disagree about what they are talking
    // about.
    const mine = items.filter((n) => (n.textContent || '').includes('Ctrl+Shift+E'));
    out.count = mine.length;
    if (!items.length) return out;

    // THE INTER-NOTIFICATION SPACING, RESOLVED BY THE BROWSER. This is the
    // value the user asked the bottom clearance to match, read from the live
    // page rather than restated, so the assertion is a relation between two
    // measurements and not a comparison against a constant.
    const cs = getComputedStyle(host);
    const g = parseFloat(cs.rowGap === 'normal' ? cs.gap : cs.rowGap);
    out.rowGap = Number.isFinite(g) ? Math.round(g * 100) / 100 : null;

    // Sorted by screen position. `#active-notifications` is
    // `flex-direction: column-reverse`, so DOM order is NOT screen order and
    // "the last one" would name the wrong element half the time.
    const rects = items.map((n) => n.getBoundingClientRect())
      .sort((a, b) => a.top - b.top);
    if (rects.length >= 2) {
      const a = rects[rects.length - 2];
      const b = rects[rects.length - 1];
      out.interGap = Math.round((b.top - a.bottom) * 100) / 100;
    }
    const lowest = rects[rects.length - 1];
    const br = bar.getBoundingClientRect();
    out.lowestBottom = Math.round(lowest.bottom * 100) / 100;
    out.barTop = Math.round(br.top * 100) / 100;
    out.gapToStatusBar = Math.round((br.top - lowest.bottom) * 100) / 100;

    // AND THE COMPLAINT ITSELF, HIT-TESTED: is the bottom edge of the lowest
    // toast the thing the browser finds there? A positive `gapToStatusBar`
    // that some other element still covers would be a pass on the arithmetic
    // and a failure on the screen.
    const cx = lowest.left + lowest.width / 2;
    const cy = lowest.bottom - 2;
    if (cx >= 0 && cy >= 0 && cx <= innerWidth && cy <= innerHeight) {
      const hit = document.elementFromPoint(cx, cy);
      const inHost = !!hit && host.contains(hit);
      out.lowestBottomCovered = !inHost;
      out.lowestBottomHit = !hit ? 'nothing' :
        (hit.tagName.toLowerCase() + (hit.id ? '#' + hit.id : '') +
         (typeof hit.className === 'string' && hit.className
           ? '.' + hit.className.trim().split(/\s+/).join('.') : ''));
    }
    return out;
  });
}

// The status bar's own bookkeeping — `ui/status.nim`'s `notificationsDelivered`,
// exposed on the existing `window.__ctStatusRenderStats` hook. Absent on a
// build that predates it, which is reported as null rather than as 0: a
// missing instrument and an instrument reading zero are different facts and
// the caller asserts on them differently.
async function statusStats(page) {
  return await page.evaluate(() => {
    if (typeof window.__ctStatusRenderStats !== 'function') return null;
    try {
      const s = window.__ctStatusRenderStats();
      return {
        passes: s.passes, rebuilds: s.rebuilds,
        delivered: typeof s.delivered === 'number' ? s.delivered : null,
      };
    } catch (e) { return null; }
  });
}

// DISMISSIBLE, PROVED BY DISMISSING IT. "A warning that cannot be dismissed is
// a banner by another name", which is the complaint this change answers, so
// the affordance is exercised rather than merely located.
async function dismissDurabilityNotice(page) {
  const clicked = await page.evaluate(() => {
    const host = document.getElementById('active-notifications');
    if (!host) return false;
    const el = Array.from(host.querySelectorAll('.status-notification'))
      .find((n) => (n.textContent || '').includes('Ctrl+Shift+E'));
    if (!el) return false;
    const btn = el.querySelector('.dismiss-notification-button');
    if (!btn) return false;
    btn.click();
    return true;
  });
  if (!clicked) return false;
  await page.waitForTimeout(600);
  const still = await durabilityNotice(page);
  return !still.found;
}

try {
  // -- the session that edits ------------------------------------------------
  const ctx = await browser.newContext();
  const page = await ctx.newPage();
  const logs = [];
  page.on('console', (m) => logs.push(m.text()));

  await page.goto(url, { waitUntil: 'load' });

  // THE BASELINE, TAKEN BEFORE THE NOTICE CAN HAVE BEEN RAISED. `load` has
  // fired but `startWebArm` mounts the renderer and only then walks up to a
  // status bar, so nothing has been delivered yet. Reading the counter here
  // rather than assuming it starts at zero is what makes the delta below a
  // measurement of THIS page load: if the hook is ever pre-warmed, or the
  // baseline is already non-zero for a reason nobody predicted, the delta is
  // still right and the raw numbers are in the JSON to be looked at.
  out.statsBefore = await statusStats(page);

  await waitForEditMode(page);
  out.mounted = true;

  // AFTER LAYOUT HAS SETTLED, not merely after the element exists. `waitForEditMode`
  // ends on a 1200ms settle, and the geometry below is read after the notice has
  // been located — a rect read while the stack is still being built returns the
  // previous frame's number, which is wrong in whichever direction the stale
  // value points and says nothing about it, whereas a missing element throws.
  const notice = await durabilityNotice(page);
  out.legacyBannerPresent = notice.legacyBanner;
  out.noticeFound = notice.found;
  out.noticeText = notice.text;
  out.noticeChars = notice.chars;
  out.noticePainted = notice.painted;
  out.noticeClass = notice.cls;
  out.noticeHasDismiss = notice.hasDismiss;
  out.noticeHasExport = notice.hasExport;

  // WHILE THE NOTICE IS STILL ON SCREEN. Measuring after dismissing it would
  // prove nothing about the state the user complained of.
  const bar = await statusBarUnobscured(page);
  out.statusBarFound = bar.found;
  out.statusBarUnobscured = bar.unobscured;
  out.statusBarProbePoints = bar.points;
  out.statusBarCoveredBy = bar.coveredBy;
  out.statusBarRect = bar.rect;

  // HOW MANY, AND HOW HIGH ABOVE THE BAR — also while the notice is on screen,
  // and before the dismissal below removes the thing being measured.
  const geom = await noticeGeometry(page);
  out.noticeCount = geom.count;
  out.toastCount = geom.total;
  out.noticeRowGap = geom.rowGap;
  out.noticeInterGap = geom.interGap;
  out.noticeGapToStatusBar = geom.gapToStatusBar;
  out.noticeLowestBottom = geom.lowestBottom;
  out.noticeBarTop = geom.barTop;
  out.noticeLowestBottomCovered = geom.lowestBottomCovered;
  out.noticeLowestBottomHit = geom.lowestBottomHit;

  // DIAGNOSTIC, NOT AN ASSERTION. `communication.nim`'s `emit` already logs
  // the length of the fan-out list for the event it is emitting, and `receive`
  // logs how many handlers it is about to call. If a notice ever appears N
  // times these lines say WHICH multiplicity produced it — N subscribers on
  // `viewsApi`, or N handlers re-emitting — without adding instrumentation to
  // the product. Kept in the JSON so a future duplication report starts from a
  // measurement instead of a re-derivation.
  out.notificationFanout = logs
    .filter((l) => /CtNotification/.test(l))
    .slice(0, 40);
  out.statusRegistrations = logs
    .filter((l) => /register component Status|api for Status/.test(l))
    .slice(0, 20);

  // The same counter, now that the notice has been delivered. The DELTA is
  // what the caller asserts on: `after - before` is how many notifications
  // this page load produced, and a run in which nothing was delivered leaves
  // it at 0 rather than at a plausible-looking 1.
  out.statsAfter = await statusStats(page);

  out.noticeDismissed = await dismissDurabilityNotice(page);

  // THE EDIT, as keystrokes. Not `model.setValue`: that would bypass Monaco's
  // change listener, which is what marks the tab dirty and therefore what
  // `saveTargets` reads. Typing exercises the path a visitor takes.
  await page.click('.monaco-editor');
  await page.keyboard.press('Control+A');
  await page.keyboard.type(`// ${MARKER}\nfn main(x: Field, y: pub Field) {\n`);
  await page.waitForTimeout(500);

  const mainBefore = await page.evaluate(
    (mk) => {
      const m = window.monaco.editor.getModels()
        .find((x) => x.getValue().includes(mk));
      return m ? m.getValue() : '';
    }, MARKER);
  out.markerBeforeReload = mainBefore.length > 0;
  out.editedContent = mainBefore;

  // THE SAVE.
  await page.keyboard.press('Control+S');
  await page.waitForTimeout(2500);

  out.sawNoHostForSaveFile =
    logs.some((l) => l.includes('no host for CODETRACER::save-file') &&
                     !l.includes('save-file-error'));

  // -- A DEBUG SESSION, IN BETWEEN --------------------------------------
  //
  // Reported: "when I enter a debug sesion and hit the Stop button, the
  // contents of some files become empty. What's worse is that this seems to be
  // persisted even after I refresh the tab. It's cleared only when I clear the
  // browser data for the web-site."
  //
  // WITHOUT THIS LEG THE GATE CANNOT SEE IT. Everything above types, saves and
  // reloads without ever leaving Edit mode, and the defect needs the mode
  // transition: a GoldenLayout swap orphans a Monaco widget, nothing ever nils
  // `tabInfo.monacoEditor`, and Monaco's `getValue()` answers `''` for a widget
  // whose model is gone rather than throwing. The next save — and Run itself
  // saves, unconditionally — then wrote that empty string through to OPFS,
  // where the reload read it back.
  //
  // Recorded as its own fields rather than folded into the reload check, so a
  // failure says whether the bytes were lost at the Run, at the Stop, or in
  // storage.
  out.debugLegAttempted = false;
  out.debugLegEnteredDebug = false;
  out.debugLegReturnedToEdit = false;
  out.contentAfterStop = null;
  try {
    // WAITED FOR, not sampled. The edit toolbar mounts outside Karax's VDOM
    // and a bare `$()` immediately after the save raced it — the first run of
    // this leg reported "the Run button was not reachable" for that reason and
    // skipped the whole sequence, which is a silent hole in the gate rather
    // than a failure.
    const runButton = await page
      .waitForSelector('#run-image', { timeout: 30000 })
      .catch(() => null);
    if (runButton) {
      out.debugLegAttempted = true;
      await runButton.click();
      await page.waitForSelector('.isonim-debug-controls', { timeout: 180000 });
      out.debugLegEnteredDebug = true;
      await page.waitForTimeout(1500);

      await page.click('#stop-image');
      await page.waitForSelector('.edit-mode-toolbar', { timeout: 180000 });
      await page.waitForSelector('.view-line', { timeout: 60000 });
      out.debugLegReturnedToEdit = true;
      await page.waitForTimeout(2000);

      // What the editor holds now, BEFORE the reload. If the bytes are already
      // gone here the loss happened in memory; if they are here and gone after
      // the reload it happened in the store.
      out.contentAfterStop = await page.evaluate(() => {
        const vals = window.monaco.editor.getModels().map((m) => m.getValue());
        const nonEmpty = vals.filter((v) => v.length > 0);
        return {
          models: vals.length,
          empty: vals.length - nonEmpty.length,
          longest: nonEmpty.length > 0
            ? nonEmpty.reduce((a, b) => (a.length >= b.length ? a : b))
            : '',
        };
      });

      // Flattened for the shell, which reads top-level keys only. The LONGEST
      // non-empty model rather than a count: a count of models is satisfied by
      // three empty ones, which is exactly the state under test.
      out.contentAfterStopLength = out.contentAfterStop.longest.length;
      out.markerAfterStop = out.contentAfterStop.longest.includes(MARKER);
      out.emptyModelsAfterStop = out.contentAfterStop.empty;

      // A SECOND SAVE AFTER THE TRANSITION, deliberately. This is the gesture
      // that actually wrote the empty string: the orphaned widget is only read
      // when something asks it to save, and pressing Ctrl+S here is the
      // cheapest way to ask. Without it the gate would pass on a build where
      // the wipe is merely deferred to the user's next save.
      await page.click('.monaco-editor');
      await page.keyboard.press('Control+S');
      await page.waitForTimeout(2500);
    }
  } catch (err) {
    out.debugLegError = String((err && err.message) || err).slice(0, 300);
  }

  // Refusals the truncation guard raised, if any. A refusal is the product
  // WORKING — it is what stops the wipe — so it is recorded rather than
  // treated as an error, and the gate reports it alongside the round trip.
  out.truncationRefusals = logs
    .filter((l) => /refused to truncate|Refused to save an empty/.test(l))
    .slice(0, 10);

  // THE RELOAD — every byte of JS state is destroyed here.
  await page.reload({ waitUntil: 'load' });
  await waitForEditMode(page);
  out.mountedAfterReload = true;

  // EXACT EQUALITY, not a substring. "The marker is present" would also be
  // true of a restore that dropped half the file, or that merged the bundled
  // copy back in on top. The claim is that the tab came back holding the bytes
  // it had when it was saved, so that is what is compared.
  const after = await page.evaluate((mk) => {
    const vals = window.monaco.editor.getModels().map((m) => m.getValue());
    const hit = vals.find((v) => v.includes(mk));
    return { marker: !!hit, content: hit || '', models: vals.length };
  }, MARKER);
  out.markerAfterReload = after.marker;
  out.restoredContent = after.content;
  out.editorModels = after.models;

  // ONCE PER BROWSER SESSION. `sessionStorage` survives `page.reload()` and
  // dies with the context, so the same tab must NOT be told again — the reload
  // is the case the old banner got wrong, re-announcing on every load.
  out.noticeAfterReload = (await durabilityNotice(page)).found;
  await ctx.close();

  // -- THE CONTROL: a fresh origin partition, the same bytes -----------------
  const fresh = await browser.newContext();
  const freshPage = await fresh.newPage();
  await freshPage.goto(url, { waitUntil: 'load' });
  await waitForEditMode(freshPage);
  const freshInfo = await freshPage.evaluate((mk) => {
    const vals = window.monaco.editor.getModels().map((v) => v.getValue());
    const nonEmpty = vals.filter((v) => v.length > 0);
    return {
      marker: vals.some((v) => v.includes(mk)),
      // The bundled bytes, read from a partition that has never been written
      // to. This is the value the restored content must NOT equal -- it is how
      // "restored from storage" is told apart from "fell back to the bundle".
      bundled: nonEmpty.length > 0 ? nonEmpty[0] : '',
    };
  }, MARKER);
  out.freshContextMarker = freshInfo.marker;
  out.bundledContent = freshInfo.bundled;
  // …AND IT COMES BACK FOR A NEW ONE. The twin of `noticeAfterReload`: without
  // this, "once per session" would be indistinguishable from "suppressed
  // forever", and a notice that never appears again is not a fix, it is the
  // message being lost.
  out.noticeInFreshContext = (await durabilityNotice(freshPage)).found;
  await fresh.close();
} catch (e) {
  out.error = String(e && e.message ? e.message : e);
}

await browser.close();
server.close();
process.stdout.write(JSON.stringify(out, null, 2) + '\n');
