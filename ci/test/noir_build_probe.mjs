// noir_build_probe.mjs — press Build in a real browser and report what the
// compiler actually did.
//
// WHY THIS EXISTS BESIDE `web_renderer_probe.mjs`
// ----------------------------------------------
// That probe loads a page and reports what is on it. This one has to DRIVE the
// page: the claim under test is not "a surface mounted" but "a gesture reached
// 19 MB of Noir compiler and a result came back", and the only instrument for
// that is a browser that performs the gesture.
//
// THE MEASUREMENT THAT DEFINED THE PROBLEM, and the one this program repeats.
// Instrumenting `Worker.postMessage` before page scripts ran and then
// exercising Run test, the BUILD pane's ▶ and ■, a test row, F5, Ctrl+B,
// Ctrl+Shift+B and Ctrl+R produced ONE `configure` message, ZERO `start`
// messages, and ZERO `.wasm` network requests. Every check over that
// deployment was green, because each one asserted a step. So the three fields
// this program exists to report are:
//
//   workerMessages   every string handed to `Worker.postMessage`, in order
//   wasmRequests     every response whose URL ends `.wasm`, with its size
//   buildPanePainted the BUILD pane's rows, hit-tested, as a USER reads them
//
// `addInitScript` runs before any page script, which is the only position from
// which `Worker.postMessage` can be wrapped without racing the bundle.
//
// PAINTED TEXT, NOT `innerText`. `web-renderer-mounts.sh` records why: its
// "there is a product on this page" check was being satisfied almost entirely
// by a 379-character developer diagnostic that sat at (0,0) under the topbar
// and that no user could see. `innerText` is defined over rendered text, and
// the text WAS rendered — it was covered. So every row reported below is
// hit-tested with `elementFromPoint` at its own centre.
//
// This program asserts nothing. It reports facts and lets
// `ci/test/noir-build-in-browser.sh` count assertions over them, so the arms
// and the control read one instrument.

import { chromium } from 'playwright';

const url = process.argv[2];
const gesture = process.argv[3] || 'shortcut';   // shortcut | button | run
const settleMs = Number(process.argv[4] || 12000);
if (!url) {
  console.error('usage: noir_build_probe.mjs <url> [gesture] [settleMs]');
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
page.on('response', async (r) => {
  const u = r.url();
  if (!u.endsWith('.wasm')) return;
  let bytes = -1;
  try {
    const length = r.headers()['content-length'];
    bytes = length ? Number(length) : -1;
  } catch (e) { /* a response body may be unavailable; the URL is the fact */ }
  wasmRequests.push({ url: u, status: r.status(), bytes });
});

// THE INSTRUMENT, installed before a single page script runs.
//
// `Worker.prototype.postMessage` is wrapped rather than `Worker` itself,
// because the transport constructs its worker inside a Nim closure and a
// replaced constructor would have to reproduce the real one exactly. Wrapping
// the method leaves construction alone and still sees every message.
//
// The messages are recorded as STRINGS, which is not a lossy convenience: the
// protocol is text in both directions by design (`wasm_worker.nim`'s header
// records the day a sibling campaign lost to an engine that sent objects one
// way and JSON the other), so anything arriving here that is NOT a string is
// itself a finding and is recorded as its `typeof`.
await page.addInitScript(() => {
  window.__ctWorkerMessages = [];
  const original = Worker.prototype.postMessage;
  Worker.prototype.postMessage = function (message, ...rest) {
    try {
      window.__ctWorkerMessages.push(
        typeof message === 'string'
          ? message.slice(0, 2000)
          : `NON-STRING(${typeof message})`);
    } catch (e) { /* never let the instrument break the subject */ }
    return original.call(this, message, ...rest);
  };
});

const report = {
  url, gesture,
  loadError: '',
  gestureError: '',
  mounted: false,
  buildPaneOpened: false,
  workerMessages: [],
  wasmRequests: [],
  buildPanePainted: [],
  buildPaneRejected: [],
  buildPaneRowCount: -1,
  problemRowsPainted: [],
  runButtonPresent: false,
  stopButtonEnabled: false,
  headerText: '',
  pageErrors: [],
  consoleLines: [],
};

// The rows of the BUILD pane, hit-tested. `#build` is the output container's
// id in `viewmodel/views/isonim_build_view.nim`; each row is a `div` whose
// class `lineClass` picks.
const paintedRowsScript = () => {
  const container = document.getElementById('build');
  if (!container) return { rows: [], count: -1, header: '', run: false, stopEnabled: false };
  const painted = [];
  // EVERY ROW IS REPORTED WITH ITS VERDICT, not merely accepted or dropped.
  //
  // A hit test that rejects everything and a pane with no rows produce the
  // same empty list, and they are different faults: the first is the
  // instrument and the second is the product. `rejected` is what tells them
  // apart in the gate's dump, and it exists because the first version of this
  // probe reported zero painted rows over a pane that a screenshot showed
  // plainly — the measurement failure this file's own header warns about,
  // arriving in the file that warns about it.
  const rejected = [];
  for (const row of container.children) {
    const r = row.getBoundingClientRect();
    const cs = getComputedStyle(row);
    const text = (row.innerText || row.textContent || '')
      .replace(/\u00a0/g, ' ').trim();
    const why = (reason) => rejected.push(
      reason + ' rect=' + Math.round(r.x) + ',' + Math.round(r.y) + ' ' +
      Math.round(r.width) + 'x' + Math.round(r.height) + ' :: ' +
      text.slice(0, 60));
    if (r.width === 0 || r.height === 0) { why('zero-size'); continue; }
    if (cs.visibility === 'hidden' || cs.display === 'none' ||
        cs.opacity === '0') {
      why('css-' + cs.visibility + '/' + cs.display + '/' + cs.opacity);
      continue;
    }
    // The LEFT of the row, not its centre. A row is as wide as the pane and
    // its text is at the start of it; probing the middle of a 1592px row asks
    // about empty space, which any later sibling with a margin can own.
    const px = r.x + Math.min(20, r.width / 2);
    const py = r.y + r.height / 2;
    const top = document.elementFromPoint(px, py);
    if (!top) { why('nothing-at-point'); continue; }
    if (!(top === row || row.contains(top) || top.contains(row))) {
      why('covered-by-' + top.tagName + '.' +
          String(top.className || '').slice(0, 40));
      continue;
    }
    if (text.length === 0) { why('empty-text'); continue; }
    painted.push(text);
  }
  const headerEl = document.querySelector('.build-header, .build-status');
  const runBtn = document.querySelector('.build-run-btn');
  const stopBtn = document.querySelector('.build-stop-btn');
  const problems = Array.from(
    document.querySelectorAll('.build-output-line.build-clickable')
  ).map((e) => (e.innerText || e.textContent || '').trim());
  return {
    rows: painted,
    rejected,
    count: container.children.length,
    header: headerEl ? (headerEl.innerText || '').trim() : '',
    run: !!runBtn,
    stopEnabled: !!stopBtn && !stopBtn.className.includes('disabled'),
    problems,
  };
};

try {
  await page.goto(url, { waitUntil: 'load', timeout: 60000 });
  // Wait for the renderer to say it mounted. The line is the same one
  // `web-renderer-mounts.sh` reads, so "the surface came up" is one fact with
  // one spelling across both gates.
  for (let i = 0; i < 60; i += 1) {
    if (consoleLines.some((l) => l.includes('codetracer-web-renderer: ok'))) break;
    await page.waitForTimeout(250);
  }
  report.mounted = consoleLines.some((l) => l.includes('codetracer-web-renderer: ok'));

  // THE MOUNT LINE IS NOT THE END OF START-UP. `ui/layout.nim` registers the
  // standalone auto-hide panes on a `setTimeout` that runs after GoldenLayout
  // has created every container, and the strip is rebuilt from scratch each
  // time `autoHideState.onChanged` fires. A gesture issued into the middle of
  // that races it. A user cannot press a key before the page has drawn either,
  // so waiting here measures the product rather than a state no one is in.
  await page.waitForTimeout(2500);

  // BLUR THE EDITOR FIRST, and this is a real property of the product rather
  // than a harness convenience. Mousetrap's default `stopCallback` ignores a
  // chord raised inside an INPUT / TEXTAREA / contenteditable, and Monaco's
  // input surface is a textarea that takes focus when the editor pane mounts.
  // A user pressing Ctrl+B with the caret in the editor is in exactly that
  // state, so if the chord has to be reached from elsewhere, the gate should
  // find that out rather than paper over it: the click below targets the
  // topbar, which is where a user's pointer is when they have just used a
  // menu, and the assertion that the build ran is what says whether it was
  // enough.
  try {
    await page.click('#menu', { position: { x: 5, y: 5 }, timeout: 3000 });
  } catch (e) { /* no topbar is itself reported by the mount assertions */ }

  if (gesture === 'run') {
    // RUN is `ctrl+enter`, deliberately not `ctrl+r` or `F5` — both are the
    // browser's own reload on every platform, and a studio that ate either
    // would be taking a key away from the user rather than giving them one.
    await page.keyboard.press('Control+Enter');
  } else {
    await page.keyboard.press('Control+b');
  }

  // The pane is created on demand by `openLayoutTab(Content.Build)`, then the
  // IsoNim view mounts into it. Both are asynchronous.
  for (let i = 0; i < 40; i += 1) {
    const seen = await page.evaluate(() => !!document.getElementById('build'));
    if (seen) { report.buildPaneOpened = true; break; }
    await page.waitForTimeout(250);
  }

  if (gesture === 'button') {
    // THE SECOND GESTURE, and the one the acceptance names. The first opened
    // the pane; this one is a user clicking ▶ in it.
    //
    // THE FIRST BUILD IS WAITED OUT FIRST, and that is not politeness:
    // `startNoirBuild` refuses while a run is in flight
    // (`reason=already-running`), which is the correct product behaviour —
    // two concurrent compiles over one worker and one pane would interleave
    // their output. A click issued during the first compile therefore
    // produces ONE start message, and a gate that asserted two would be
    // asserting that the guard is absent.
    for (let i = 0; i < 60; i += 1) {
      const ready = await page.evaluate(() => {
        const btn = document.querySelector('.build-run-btn');
        const stop = document.querySelector('.build-stop-btn');
        const rows = (document.getElementById('build') || { children: [] })
          .children.length;
        const idle = !stop || stop.className.includes('disabled');
        return !!btn && idle && rows > 0;
      });
      if (ready) break;
      await page.waitForTimeout(250);
    }
    await page.click('.build-run-btn', { timeout: 5000 });
  }

  // Settle. A first compile has to FETCH ~16 MB of wasm off the local server,
  // compile it, and then compile the project — measured at ~2.5 s for the
  // fetch-and-instantiate and ~0.4 s for the project on this machine, so the
  // budget is generous and the loop exits as soon as the pane has settled.
  // WAIT FOR THE BUILD'S OWN EXIT LINE, not for a class name.
  //
  // This predicate used to be `rows > 0 && !(running &&
  // !running.className.includes('disabled'))`, and both halves are unsound as a
  // settle signal. `rows > 0` is true from the FIRST diagnostic row, mid-
  // compile. And reading `className.includes('disabled')` to decide whether a
  // build is still running is the one check that cannot tell a live control
  // from a dead one — the blindness that produced a false defect report in this
  // campaign, here doing worse work than it did there, because a wait that
  // returns early does not fail: it hands the fixed delay below the job of
  // being the real wait, silently.
  //
  // `web_noir_build.onExit` reports `$phase & "-exit"`, so a finished compile
  // says so on the console with its own verdict. That is the event, it is
  // already captured, and it cannot be satisfied by a partially painted pane.
  const deadline = Date.now() + settleMs;
  let buildExitLine = '';
  while (Date.now() < deadline) {
    buildExitLine = consoleLines.find(
      (l) => l.includes('codetracer-noir-build:') && l.includes('-exit')) || '';
    if (buildExitLine) break;
    await page.waitForTimeout(250);
  }
  report.buildExitLine = buildExitLine;
  await page.waitForTimeout(750);

  const painted = await page.evaluate(paintedRowsScript);
  report.buildPanePainted = painted.rows;
  report.buildPaneRejected = painted.rejected || [];
  report.buildPaneRowCount = painted.count;
  report.headerText = painted.header;
  report.runButtonPresent = painted.run;
  report.stopButtonEnabled = painted.stopEnabled;
  report.problemRowsPainted = painted.problems || [];
  report.workerMessages = await page.evaluate(
    () => (window.__ctWorkerMessages || []).slice());
} catch (e) {
  report.loadError = String((e && e.message) || e).slice(0, 400);
}

report.wasmRequests = wasmRequests;
report.pageErrors = pageErrors;
report.consoleLines = consoleLines.filter((l) =>
  l.includes('codetracer-') || l.includes('Error') || l.includes('error:'));

await browser.close();
console.log(JSON.stringify(report, null, 2));
