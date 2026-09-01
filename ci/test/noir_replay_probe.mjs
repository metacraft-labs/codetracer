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

page.on('pageerror', (e) =>
  pageErrors.push(String((e && e.message) || e).slice(0, 300)));
page.on('console', (m) => consoleLines.push(`${m.type()}: ${m.text().slice(0, 500)}`));
page.on('response', (r) => {
  const u = r.url();
  if (!u.endsWith('.wasm')) return;
  const length = r.headers()['content-length'];
  wasmRequests.push({ url: u, status: r.status(), bytes: length ? Number(length) : -1 });
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
  stepCount: 0,
  sourceViewsWritten: 0,
  distinctLines: [],
  resolvedCount: 0,
  missingPathCount: 0,
  editorPaintedLines: [],
  editorPaintedChars: 0,
  stepButtonPresent: false,
  gestureError: '',
  noSourceVisible: false,
  openTabTitles: [],
  pageErrors: [],
  consoleLines: [],
};

// The editor's painted content. Monaco renders each source line as a
// `.view-line`; a line is counted only when something is actually at its own
// start point, which is what separates "rendered" from "visible".
const paintedEditorScript = () => {
  const lines = [];
  let chars = 0;
  for (const el of document.querySelectorAll('.view-line')) {
    const r = el.getBoundingClientRect();
    const cs = getComputedStyle(el);
    if (r.width === 0 || r.height === 0) continue;
    if (cs.visibility === 'hidden' || cs.display === 'none' || cs.opacity === '0') continue;
    const px = r.x + Math.min(6, r.width / 2);
    const py = r.y + r.height / 2;
    const top = document.elementFromPoint(px, py);
    if (!top) continue;
    if (!(top === el || el.contains(top) || top.contains(el))) continue;
    const text = (el.innerText || el.textContent || '').replace(/ /g, ' ').trimEnd();
    if (text.trim().length === 0) continue;
    lines.push(text);
    chars += text.trim().length;
  }
  // The NO SOURCE view is the other half of the question: a session that
  // resolved nothing paints this instead, and a gate that only counted
  // editor lines would read its absence as "no source yet" rather than as
  // "the product said it has none".
  let noSource = false;
  for (const el of document.querySelectorAll('*')) {
    if (el.children.length > 0) continue;
    const text = (el.textContent || '').trim();
    if (!text.startsWith('We were not able to open the given location path')) continue;
    const r = el.getBoundingClientRect();
    if (r.width === 0 || r.height === 0) continue;
    noSource = true;
    break;
  }
  const tabs = Array.from(document.querySelectorAll('.lm_tab .lm_title'))
    .map((e) => (e.innerText || e.textContent || '').trim())
    .filter((t) => t.length > 0);
  return { lines, chars, noSource, tabs };
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
  report.stepButtonPresent = await page.evaluate(
    () => !!document.querySelector('.step-forward'));
  // The debug controls live in a pane the EDIT layout does not mount, so the
  // control is asked for and its absence RECORDED rather than treated as a
  // harness failure: whether a replay session brings the debugger panes up is
  // itself part of what this gate measures, and a probe that forced them open
  // would be measuring its own click.
  if (report.stepButtonPresent) {
    for (let i = 0; i < steps; i += 1) {
      try {
        await page.click('.step-forward', { timeout: 3000 });
      } catch (e) {
        report.gestureError = String((e && e.message) || e).slice(0, 200);
        break;
      }
      await page.waitForTimeout(900);
    }
  } else {
    report.gestureError = 'no .step-forward control is mounted in this layout';
  }

  const painted = await page.evaluate(paintedEditorScript);
  report.editorPaintedLines = painted.lines;
  report.editorPaintedChars = painted.chars;
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
report.engineFetched = wasmRequests.some((r) => r.url.includes('db_backend_bg.wasm'));
report.pageErrors = pageErrors;
report.consoleLines = consoleLines.filter((l) =>
  l.includes('codetracer-') || l.includes('Error') || l.includes('error:'));

await browser.close();
console.log(JSON.stringify(report, null, 2));
