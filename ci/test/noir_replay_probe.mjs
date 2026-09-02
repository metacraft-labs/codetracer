// noir_replay_probe.mjs — Run a Noir program in a real tab, then step the
// trace it produced and report whether a user can SEE the source.
//
// WHY THIS EXISTS BESIDE `noir_build_probe.mjs`
// --------------------------------------------
// That probe drives a Build and reports what the BUILD pane painted. This one
// continues past it: a Run produces a `MemoryTrace`, the tab hands it to a
// replay engine it fetched, and the claim under test is that the debugger then
// WORKS — steps advance, positions resolve, and the source of the line being
// executed is on screen.
//
// THE TWO FALSE PASSES THIS PROGRAM EXISTS TO EXPOSE, both of which report
// success at every step:
//
//   1. A TRACE THAT LOADS AND CARRIES ZERO STEPS. An artifact compiled without
//      debug instrumentation traces to one event and no steps; both wasm
//      modules answer `ok`, the engine accepts the `trace.json`, and the
//      session opens onto an empty timeline. So `stepCount` and
//      `distinctLines` are reported as NUMBERS, not as a boolean.
//   2. A SESSION THAT RESOLVES POSITIONS THAT ARE ALL `missingPath`. In a
//      browser every recorded path is that case unless the trace's own source
//      is written into the engine's VFS under the recorded key. So
//      `missingPathCount` is reported alongside `resolvedCount`, and the
//      editor's painted text is read separately from either.
//
// PAINTED TEXT, NOT `innerText`. `web-renderer-mounts.sh` records why: its
// "there is a product on this page" check was satisfied almost entirely by a
// 379-character developer diagnostic that sat at (0,0) under the topbar and
// that no user could see. Every line reported below is hit-tested with
// `elementFromPoint` at its own start.
//
// This program asserts nothing. It reports facts and lets
// `ci/test/noir-replay-in-browser.sh` count assertions over them, so the arms
// and the control read one instrument.

import { chromium } from 'playwright';

const url = process.argv[2];
const settleMs = Number(process.argv[3] || 45000);
const steps = Number(process.argv[4] || 6);
if (!url) {
  console.error('usage: noir_replay_probe.mjs <url> [settleMs] [steps]');
  process.exit(2);
}

const browser = await chromium.launch();
const page = await browser.newPage({ viewport: { width: 1600, height: 1000 } });

const pageErrors = [];
const consoleLines = [];
const wasmRequests = [];

// A Nim exception reaching the top level is an OBJECT, not an `Error`, so
// `String(e)` renders it as the useless literal "Object" — which is exactly
// what this gate reported for two runs while the interesting fact (the
// message) sat one property away. Every shape is tried, and the raw JSON is
// the last resort so the report can never be a word with no content.
const describeError = (e) => {
  if (!e) return 'undefined';
  const parts = [];
  if (e.message) parts.push(`message=${e.message}`);
  if (e.msg) parts.push(`msg=${e.msg}`);
  if (e.name) parts.push(`name=${e.name}`);
  if (e.stack) parts.push(`stack=${String(e.stack).slice(0, 400)}`);
  if (parts.length === 0) {
    try { parts.push(`json=${JSON.stringify(e).slice(0, 400)}`); }
    catch (x) { parts.push(`unstringifiable=${Object.prototype.toString.call(e)}`); }
  }
  return parts.join(' | ').slice(0, 700);
};

page.on('pageerror', (e) => pageErrors.push(describeError(e)));
// ERRORS ARE KEPT WHOLE. A 500-character slice is fine for progress chatter
// and wrong for the one message that matters: `console_error_panic_hook` is
// installed in the engine (`lib.rs:234`), so a Rust panic in the wasm arrives
// here as a `console.error` whose FIRST line names the panic site — and the
// stack that follows it pushed that line out of the slice, leaving this gate
// reporting six `RuntimeError: unreachable` traps with no identity. That is
// the fifth time on this gate that the instrument, not the product, was the
// thing withholding the answer.
page.on('console', (m) => {
  const text = m.text();
  const limit = m.type() === 'error' ? 4000 : 500;
  consoleLines.push(`${m.type()}: ${text.slice(0, limit)}`);
});
page.on('response', (r) => {
  const u = r.url();
  if (!u.endsWith('.wasm')) return;
  const headers = r.headers();
  const length = headers['content-length'];
  wasmRequests.push({
    url: u,
    status: r.status(),
    contentType: headers['content-type'] || '',
    bytes: length ? Number(length) : -1,
  });
});

// THE INSTRUMENT, installed before a single page script runs.
//
// Two things are wrapped. `Worker.prototype.postMessage` records every message
// the page sends a worker — the Noir worker's `configure`/`start` and the
// replay worker's `configure`/`vfs-write`/`start` — which is how "the engine
// was reached" is measured rather than inferred. Unlike the Build probe this
// one records the message TYPE for objects rather than discarding them:
// `vfs-write` carries a `Uint8Array` and cannot be a string, and the count of
// those is exactly the "did the source get into the container" question.
await page.addInitScript(() => {
  window.__ctThrown = [];
  window.addEventListener('error', (ev) => {
    const e = ev && ev.error;
    try {
      window.__ctThrown.push(
        (e && (e.message || e.msg)) ? String(e.message || e.msg)
          : (e ? JSON.stringify(e).slice(0, 400) : String(ev.message)));
    } catch (x) { window.__ctThrown.push('unstringifiable'); }
  });
  window.__ctWorkerMessages = [];
  window.__ctVfsWrites = [];
  const original = Worker.prototype.postMessage;
  Worker.prototype.postMessage = function (message, ...rest) {
    try {
      if (typeof message === 'string') {
        window.__ctWorkerMessages.push(message.slice(0, 400));
      } else if (message && typeof message === 'object') {
        window.__ctWorkerMessages.push(`OBJ:${message.type || message.command || '?'}`);
        if (message.type === 'vfs-write') {
          window.__ctVfsWrites.push({
            path: String(message.path),
            bytes: message.data && message.data.length ? message.data.length : 0,
          });
        }
      }
    } catch (e) { /* never let the instrument break the subject */ }
    return original.call(this, message, ...rest);
  };
});

const report = {
  url,
  loadError: '',
  mounted: false,
  buildPaneOpened: false,
  runVerdictRows: [],
  runVerdictRowsAll: [],
  runVerdictRowCount: -1,
  replayLines: [],
  workerMessages: [],
  vfsWrites: [],
  wasmRequests: [],
  engineFetched: false,
  engineRequests: [],
  stepCount: 0,
  sourceViewsWritten: 0,
  distinctLines: [],
  resolvedCount: 0,
  missingPathCount: 0,
  editorPaintedLines: [],
  editorPaintedChars: 0,
  editorPaintedCharsBeforeDismiss: -1,
  editorRawLineCount: -1,
  editorRejected: [],
  editorWidgetCount: -1,
  stepButtonPresent: false,
  stepButtonWaitMs: -1,
  debugHost: '',
  caretPositions: [],
  gestureError: '',
  noSourceVisible: false,
  openTabTitles: [],
  pageErrors: [],
  thrown: [],
  consoleLines: [],
};

// The editor's painted content. Monaco renders each source line as a
// `.view-line`; a line is counted only when something is actually at its own
// start point, which is what separates "rendered" from "visible".
const paintedEditorScript = () => {
  const lines = [];
  let chars = 0;
  // EVERY REASON A LINE WAS NOT COUNTED, and the RAW element count beside the
  // painted one. `editorPaintedChars: 0` is equally consistent with "no editor
  // on this layout" and "an editor behind the BUILD pane", and those need
  // opposite fixes — so a zero that cannot tell them apart is not a
  // measurement. The row probe in this same file needed exactly this
  // correction first; this is the same fix in the place the acceptance
  // criterion actually reads.
  const rejected = [];
  const all = document.querySelectorAll('.view-line');
  for (const el of all) {
    const r = el.getBoundingClientRect();
    const cs = getComputedStyle(el);
    const text = (el.innerText || el.textContent || '')
      .replace(/\u00a0/g, ' ').trimEnd();
    const why = (reason) => rejected.push(
      reason + ' rect=' + Math.round(r.x) + ',' + Math.round(r.y) + ' ' +
      Math.round(r.width) + 'x' + Math.round(r.height) + ' :: ' + text.slice(0, 40));
    if (r.width === 0 || r.height === 0) { why('zero-size'); continue; }
    if (cs.visibility === 'hidden' || cs.display === 'none' || cs.opacity === '0') {
      why('css-' + cs.visibility + '/' + cs.display + '/' + cs.opacity);
      continue;
    }
    const px = r.x + Math.min(6, r.width / 2);
    const py = r.y + r.height / 2;
    const top = document.elementFromPoint(px, py);
    if (!top) { why('nothing-at-point'); continue; }
    if (!(top === el || el.contains(top) || top.contains(el))) {
      why('covered-by-' + top.tagName + '.' + String(top.className || '').slice(0, 40));
      continue;
    }
    if (text.trim().length === 0) { why('empty-text'); continue; }
    lines.push(text);
    chars += text.trim().length;
  }
  // The NO SOURCE view is the other half of the question: a session that
  // resolved nothing paints this instead, and a gate that only counted editor
  // lines would read its absence as "no source yet" rather than as "the
  // product said it has none".
  let noSource = false;
  for (const el of document.querySelectorAll('*')) {
    if (el.children.length > 0) continue;
    const t = (el.textContent || '').trim();
    if (!t.startsWith('We were not able to open the given location path')) continue;
    const r = el.getBoundingClientRect();
    if (r.width === 0 || r.height === 0) continue;
    noSource = true;
    break;
  }
  const tabs = Array.from(document.querySelectorAll('.lm_tab .lm_title'))
    .map((e) => (e.innerText || e.textContent || '').trim())
    .filter((t) => t.length > 0);
  // Is there an editor on this layout AT ALL? `.monaco-editor` is the widget's
  // own root, so its absence is "no editor here" and its presence with zero
  // painted lines is "an editor that is covered or empty" — the distinction
  // the raw count exists to make.
  const editors = document.querySelectorAll('.monaco-editor').length;
  return { lines, chars, noSource, tabs, rejected, raw: all.length, editors };
};

const buildRowsScript = () => {
  const container = document.getElementById('build');
  if (!container) return { rows: [], all: [], count: -1 };
  const out = [];
  // EVERY ROW'S TEXT IS REPORTED, painted or not, alongside the container's
  // own child count. A hit test that rejects everything and a pane with no
  // rows produce the same empty list, and they are different faults — the
  // first is the instrument and the second is the product.
  // `noir_build_probe.mjs`'s header records having met exactly that, in the
  // file that warns about it; this probe met it too, and reported a row that
  // was there as absent.
  const all = [];
  for (const row of container.children) {
    const text = (row.innerText || row.textContent || '').replace(/\u00a0/g, ' ').trim();
    if (text.length > 0) all.push(text);
    const r = row.getBoundingClientRect();
    if (r.width === 0 || r.height === 0) continue;
    const px = r.x + Math.min(20, r.width / 2);
    const py = r.y + r.height / 2;
    const top = document.elementFromPoint(px, py);
    if (!top) continue;
    if (!(top === row || row.contains(top) || top.contains(row))) continue;
    if (text.length === 0) continue;
    out.push(text);
  }
  return { rows: out, all, count: container.children.length };
};

try {
  await page.goto(url, { waitUntil: 'load', timeout: 60000 });
  for (let i = 0; i < 80; i += 1) {
    if (consoleLines.some((l) => l.includes('codetracer-web-renderer: ok'))) break;
    await page.waitForTimeout(250);
  }
  report.mounted = consoleLines.some((l) => l.includes('codetracer-web-renderer: ok'));

  // The mount line is not the end of start-up: `ui/layout.nim` registers the
  // auto-hide panes on a `setTimeout` after GoldenLayout has built every
  // container, and a gesture issued into the middle of that races it.
  await page.waitForTimeout(2500);

  // Blur the editor before a chord: Mousetrap's default `stopCallback`
  // ignores one raised inside a TEXTAREA, and Monaco's input surface is one.
  try {
    await page.click('#menu', { position: { x: 5, y: 5 }, timeout: 3000 });
  } catch (e) { /* a missing topbar is reported by `mounted` */ }

  // RUN is `ctrl+enter` — deliberately not `ctrl+r` or `F5`, both of which are
  // the browser's own reload on every platform.
  await page.keyboard.press('Control+Enter');

  for (let i = 0; i < 60; i += 1) {
    if (await page.evaluate(() => !!document.getElementById('build'))) {
      report.buildPaneOpened = true;
      break;
    }
    await page.waitForTimeout(250);
  }

  // Settle: a first Run fetches ~16 MB of compiler and ~4.6 MB of tracer,
  // compiles, traces, and then fetches 18 MB of engine and instantiates it.
  const deadline = Date.now() + settleMs;
  while (Date.now() < deadline) {
    const done = await page.evaluate(() =>
      (window.__ctWorkerMessages || []).some((m) => m === 'OBJ:start') ||
      (window.__ctWorkerMessages || []).some((m) => String(m).includes('worker-error')));
    if (done) break;
    await page.waitForTimeout(500);
  }
  // Let the engine finish `launch` / `configurationDone` and the first move.
  await page.waitForTimeout(6000);

  // STEP, by clicking the product's own control. `.step-forward` is the ▶ in
  // `isonim_debug_controls_view.nim`, so what is exercised is the gesture a
  // user makes rather than a ViewModel call a user cannot reach. A shortcut
  // was the first shape and it measured Mousetrap's `stopCallback` more than
  // it measured the debugger.
  // WAITED FOR, NOT SAMPLED ONCE. The debug toolbar mounts when the layout
  // swap has rebuilt the menu shell and the repair has re-run, which is
  // several asynchronous steps after the `start` message this probe settles
  // on — an 18 MB engine has to instantiate, answer a handshake and report a
  // position first. A single `querySelector` immediately after the settle
  // read `false` over a control the renderer mounted moments later, and the
  // console said `mount COMPLETE` in the same run.
  //
  // Absence after a BOUNDED wait is still absence, so this does not weaken
  // the assertion; `stepButtonWaitMs` is reported so a control that only
  // appears after an implausible delay is visible as such rather than as a
  // clean pass.
  {
    const deadline = Date.now() + 20000;
    while (Date.now() < deadline) {
      if (await page.evaluate(() => !!document.querySelector('#next-image'))) break;
      await page.waitForTimeout(500);
    }
    // `#next-image`, NOT `.step-forward`. Both live in
    // `isonim_debug_controls_view.nim`; only one is what production renders.
    // The `.step-forward` variant is the other shape in that file, and asking
    // for it reported "the toolbar is not mounted" for three passes over a
    // toolbar that was mounted, stable, and on screen — the fourth time on
    // this gate that the MEASUREMENT was the broken thing. `#next-image` is
    // Next (F10), whose click runs `stepClick(vm, "next")`: the gesture a
    // user performs to step over.
    report.stepButtonPresent = await page.evaluate(
      () => !!document.querySelector('#next-image'));
    // WHAT IS ACTUALLY IN THE HOST. The toolbar reports `mount COMPLETE` and
    // stays mounted, so "no `.step-forward`" is a claim about the mounted
    // CONTENT, not about whether a mount happened — and those need different
    // fixes. Reporting the host's own children turns the next question from a
    // guess into a read, which is how the previous three faults on this gate
    // were found.
    report.debugHost = await page.evaluate(() => {
      const host = document.getElementById('isonim-debug-controls');
      if (!host) return 'NO HOST ELEMENT';
      const kids = Array.from(host.querySelectorAll('*'))
        .slice(0, 12)
        .map((e) => e.tagName + '.' + String(e.className || ''));
      return `children=${host.children.length} :: ${kids.join(' | ')}`.slice(0, 600);
    });
    report.stepButtonWaitMs = 20000 - Math.max(0, deadline - Date.now());
  }
  // The debug controls live in a pane the EDIT layout does not mount, so the
  // control is asked for and its absence RECORDED rather than treated as a
  // harness failure: whether a replay session brings the debugger panes up is
  // itself part of what this gate measures, and a probe that forced them open
  // would be measuring its own click.
  // WHERE THE CARET IS, read the way a user sees it. `editor.nim:675` gives
  // the current step's line the Monaco decoration class `on`, so the overlay
  // element carrying it IS the highlight on screen. Its vertical offset is
  // recorded after every step: a set of distinct offsets larger than one is
  // the caret having MOVED, which is the gesture under test — "a step control
  // exists" and "stepping moves the caret in the painted editor" are different
  // claims, and only the second is a debugger.
  const caretTop = () => page.evaluate(() => {
    const marks = document.querySelectorAll('.view-overlays .on, .view-line .on, .on');
    for (const m of marks) {
      const r = m.getBoundingClientRect();
      if (r.width === 0 || r.height === 0) continue;
      return Math.round(r.y);
    }
    return -1;
  });

  if (report.stepButtonPresent) {
    const tops = new Set();
    const first = await caretTop();
    if (first >= 0) tops.add(first);
    for (let i = 0; i < steps; i += 1) {
      try {
        await page.click('#next-image', { timeout: 3000 });
      } catch (e) {
        report.gestureError = String((e && e.message) || e).slice(0, 200);
        break;
      }
      await page.waitForTimeout(900);
      const t = await caretTop();
      if (t >= 0) tops.add(t);
    }
    report.caretPositions = Array.from(tops);
  } else {
    report.gestureError = 'no #next-image control is mounted in this layout';
  }

  // MEASURED TWICE, BEFORE AND AFTER THE USER'S NEXT GESTURE.
  //
  // The BUILD pane opened by Ctrl+Enter is a DISMISSIBLE auto-hide overlay —
  // `Planned-Features/Auto-Hide-Panes.md` §3.3 — and it sits over the editor.
  // The first measurement found 2 editor widgets and 22 rendered `.view-line`
  // elements carrying the template's real source, every one rejected
  // `covered-by-DIV`. That is not "the product painted nothing"; it is "the
  // product painted it behind the pane the same keystroke opened".
  //
  // So the reading BEFORE dismissal is kept and reported, and the gate
  // asserts on the reading after — because the claim under test is that a
  // user can SEE the source of the line being executed, and a user who has
  // just run a program dismisses the output overlay to look at their code.
  // Both numbers are reported so relaxing one cannot hide the other.
  report.editorPaintedCharsBeforeDismiss =
    (await page.evaluate(paintedEditorScript)).chars;
  try {
    await page.keyboard.press('Escape');
    await page.waitForTimeout(600);
  } catch (e) { /* a layout with no overlay is the same measurement twice */ }
  const painted = await page.evaluate(paintedEditorScript);
  report.editorPaintedLines = painted.lines;
  report.editorPaintedChars = painted.chars;
  report.editorRawLineCount = painted.raw;
  report.editorRejected = painted.rejected;
  report.editorWidgetCount = painted.editors;
  report.noSourceVisible = painted.noSource;
  report.openTabTitles = painted.tabs;
  const rowReport = await page.evaluate(buildRowsScript);
  report.runVerdictRows = rowReport.rows;
  report.runVerdictRowsAll = rowReport.all;
  report.runVerdictRowCount = rowReport.count;
  report.workerMessages = await page.evaluate(
    () => (window.__ctWorkerMessages || []).slice());
  report.vfsWrites = await page.evaluate(
    () => (window.__ctVfsWrites || []).slice());
  report.thrown = await page.evaluate(() => (window.__ctThrown || []).slice());
} catch (e) {
  report.loadError = String((e && e.message) || e).slice(0, 400);
}

// The renderer's own replay milestones, which `web_replay_host.nim` writes as
// `codetracer-replay: ...`. Read from the console rather than the DOM for the
// reason the Build probe gives: a progress check that scraped the layout would
// be measuring the layout.
report.replayLines = consoleLines
  .filter((l) => l.includes('codetracer-replay:'))
  .map((l) => l.slice(l.indexOf('codetracer-replay:')));

const stepsLine = report.replayLines.find((l) => l.includes('trace accepted:'));
if (stepsLine) {
  const m = stepsLine.match(/(\d+) steps/);
  if (m) report.stepCount = Number(m[1]);
  const sv = stepsLine.match(/(\d+) source view/);
  if (sv) report.sourceViewsWritten = Number(sv[1]);
}

// EVERY MOVE THE SESSION MADE, from the renderer's own report. `path:line`
// with the engine's verdict on whether it could reach the source — the two
// numbers that separate "the session stepped" from "the session stepped and
// could show you where".
const seen = new Set();
for (const line of report.replayLines) {
  const m = line.match(/^codetracer-replay: move (.*):(\d+) missingPath=(true|false)$/);
  if (!m) continue;
  seen.add(`${m[1]}:${m[2]}`);
  if (m[3] === 'true') report.missingPathCount += 1;
  else report.resolvedCount += 1;
}
report.distinctLines = Array.from(seen);
report.wasmRequests = wasmRequests;
// THE ENGINE, MATCHED BY STEM AND ANSWERED WITH A STATUS AND A TYPE.
//
// Three defects have lived in this one predicate, and the merge keeps the cure
// for all three.
//
// `includes('db_backend_bg.wasm')` required `_bg` to be followed immediately
// by `.wasm`, and the published name is now `db_backend_bg.<16 hex>.wasm` — so
// it would answer `false` forever on a working deployment, reddening the
// control AND turning mutation arm A ("the engine was not fetched") green for
// the wrong reason. A predicate that stops matching is worse than one that
// breaks, because one of the two verdicts it feeds looks like success.
//
// It also asked only whether the URL was REQUESTED, which is true whether the
// answer was 18 MB or a 404 — measured, when arm A began reporting the engine
// as fetched over a tree it had just been deleted from.
//
// And the status alone is not enough: this harness applies the bundle's own
// `_redirects`, and Cloudflare Pages was measured answering an absent `.wasm`
// with the entry document at 200 `text/html`. `application/wasm` is what
// `WebAssembly.compileStreaming` requires, so the predicate and the browser
// agree on what counts as an engine arriving.
const isEnginePath = (url) => {
  try {
    return /\/db_backend_bg(\.[0-9a-f]{6,})?\.wasm$/.test(new URL(url).pathname);
  } catch (e) {
    return false;
  }
};
report.engineRequests = wasmRequests.filter((r) => isEnginePath(r.url));
report.engineFetched = report.engineRequests.some(
  (r) => r.status === 200 && String(r.contentType).includes('wasm'));
report.pageErrors = pageErrors;
// THE FILTER IS PART OF THE INSTRUMENT, and it hid the answer twice. The
// renderer's own mount traces are `cdebug` lines carrying a module name and no
// `codetracer-` prefix, so a filter keyed on that prefix reported an empty set
// for a question the page had already answered out loud. Anything naming a
// mount, a panel or the debug toolbar is kept.
report.consoleLines = consoleLines.filter((l) =>
  l.includes('codetracer-') || l.includes('Error') || l.includes('error:') ||
  l.includes('Mount') || l.includes('mount') || l.includes('isonim') ||
  l.includes('DebugControls') || l.includes('retries') ||
  l.includes('panicked') || l.includes('unreachable'));

await browser.close();
console.log(JSON.stringify(report, null, 2));
