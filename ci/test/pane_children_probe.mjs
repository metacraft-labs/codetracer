// pane_children_probe.mjs — do the State, Call Trace and Timeline panes hold
// anything once the replay layout has been built?
//
// ## Why this probe and not `noir_replay_probe.mjs`
//
// That probe already loads a served web bundle, edits `main.nr`, presses Run
// and waits for the engine — this reuses that flow verbatim. What it does NOT
// do is ask whether the debug panes hold anything. It reads
// `debugPanesPresent` from `document.querySelector(sel)`, which answers "does
// the CONTAINER exist", and the container is built by GoldenLayout whether or
// not anything ever mounted into it. A blank State pane and a working one are
// indistinguishable to that check, and both were reported by it as present.
//
// Its selector list is `#stateComponent-0`, `#calltraceComponent-0`,
// `#eventLogComponent-0`, `#traceComponent-0` — **`#timelineComponent-0` is
// not in it, and neither is any pane's child count.** So no probe in this
// repository has ever asked the Timeline anything at all, which is of a piece
// with `ui/trace.nim` having logged its give-up at DEBUG.
//
// ## What this asks
//
// `document.getElementById(id).childElementCount` for each pane, BY NAME. A
// pane that mounted has an IsoNim tree under its container; a pane whose mount
// gave up has a container with zero children. That is the exact distinction
// the 25 desktop session logs describe and the one no existing check makes.
//
// Reported per pane rather than aggregated: "some pane mounted" cannot fail
// for its own reason, and the three panes fail independently — on the web
// surface State and Call Trace mount from `register` and the Timeline does
// not, so an aggregate would have been green over the defect.
//
// Asserts nothing. Prints one JSON report; the caller compares two runs.
//
// Usage: node ci/test/pane_children_probe.mjs <url> [settleMs]

import { chromium } from 'playwright';

const url = process.argv[2];
const settleMs = Number(process.argv[3] || 60000);
if (!url) {
  console.error('usage: node pane_children_probe.mjs <url> [settleMs]');
  process.exit(2);
}

// THE PANES, and why each is here.
//
//   state / calltrace / timeline — the three the desktop logs showed blank.
//   eventLog / terminal         — the same shape, moved into the factory by
//                                 the same commit, listed so a regression in
//                                 them is visible rather than inferred.
//
// THE HARNESS CONTROL is `replayReached` and `buildPaneOpened`, not another
// pane. The first shape of this probe used `#filesystemComponent-0` as the
// "if this is empty the run never got anywhere" control and it read ABSENT on
// a run where all five panes above were populated — the Noir replay layout
// does not carry a Filesystem pane, so the control would have failed over a
// working product. `replayReached` reads `#next-image`, the Next button the
// debug toolbar only renders once the engine has answered its handshake and
// reported a position, which is the thing that actually has to have happened
// for a zero below to mean "gave up" rather than "never started".
const PANES = [
  ['state', 'stateComponent-0'],
  ['calltrace', 'calltraceComponent-0'],
  ['timeline', 'timelineComponent-0'],
  ['eventLog', 'eventLogComponent-0'],
  ['terminal', 'terminalComponent-0'],
];

const readPanes = (paneList) => {
  const out = {};
  for (const [name, id] of paneList) {
    const el = document.getElementById(id);
    if (!el) {
      out[name] = { id, present: false, children: 0, descendants: 0, sample: '' };
      continue;
    }
    const kids = Array.from(el.querySelectorAll('*'));
    out[name] = {
      id,
      present: true,
      children: el.childElementCount,
      descendants: kids.length,
      sample: kids.slice(0, 6)
        .map((e) => e.tagName.toLowerCase() + (e.id ? '#' + e.id : '') +
          (e.className ? '.' + String(e.className).split(/\s+/)[0] : ''))
        .join(' | ')
        .slice(0, 300),
    };
  }
  return out;
};

const report = {
  url,
  mounted: false,
  buildPaneOpened: false,
  replayReached: false,
  panes: null,
  panesBeforeRun: null,
  giveUpLines: [],
  pageErrors: [],
};

const browser = await chromium.launch();
const page = await browser.newPage({ viewport: { width: 1600, height: 1000 } });

const consoleLines = [];
page.on('console', (m) => {
  const t = m.text();
  consoleLines.push(t);
  // THE GIVE-UP, CAPTURED BY ITS OWN WORDS. `ui/state.nim`, `ui/calltrace.nim`
  // and (since this change) `ui/trace.nim` all log "not ready after 200
  // retries, giving up" when the poll exhausts its budget. Collecting the line
  // means a blank pane can be attributed rather than merely observed.
  if (t.includes('not ready after 200 retries') ||
      t.includes('IsoNim timeline panel: not ready')) {
    report.giveUpLines.push(t.slice(0, 300));
  }
});
page.on('pageerror', (e) => report.pageErrors.push(String(e.message).slice(0, 300)));

try {
  await page.goto(url, { waitUntil: 'load', timeout: 60000 });
  for (let i = 0; i < 80; i += 1) {
    if (consoleLines.some((l) => l.includes('codetracer-web-renderer: ok'))) break;
    await page.waitForTimeout(250);
  }
  report.mounted = consoleLines.some((l) => l.includes('codetracer-web-renderer: ok'));
  await page.waitForTimeout(2500);

  // BEFORE THE RUN. In edit mode the replay panes are not in the layout at
  // all, so every count here should be absent — recorded so that a populated
  // pane after Run is a CHANGE this probe watched happen, not a state it
  // walked in on.
  report.panesBeforeRun = await page.evaluate(readPanes, PANES);

  // Blur the editor: Mousetrap ignores a chord raised inside a TEXTAREA, and
  // Monaco's input surface is one.
  try {
    await page.click('#menu', { position: { x: 5, y: 5 }, timeout: 3000 });
  } catch { /* a missing topbar shows up as `mounted: false` */ }

  // RUN. `ctrl+enter`, not `ctrl+r`/F5, both of which are the browser's reload.
  await page.keyboard.press('Control+Enter');

  for (let i = 0; i < 60; i += 1) {
    if (await page.evaluate(() => !!document.getElementById('build'))) {
      report.buildPaneOpened = true;
      break;
    }
    await page.waitForTimeout(250);
  }

  // Settle: a first Run fetches the compiler and tracer wasm, compiles, traces,
  // then fetches and instantiates the replay engine.
  const deadline = Date.now() + settleMs;
  while (Date.now() < deadline) {
    const done = await page.evaluate(() =>
      (window.__ctWorkerMessages || []).some((m) => m === 'OBJ:start') ||
      (window.__ctWorkerMessages || []).some((m) => String(m).includes('worker-error')));
    if (done) break;
    await page.waitForTimeout(500);
  }
  // Let the engine finish `launch` / `configurationDone` and the first move,
  // and let every pane's 200-retry poll EXHAUST — 200 x 10 ms is ~2 s, so a
  // pane read before that has not yet had the chance to fail, and a zero would
  // be premature rather than terminal. This is the wait that makes a zero mean
  // "gave up" instead of "not yet".
  await page.waitForTimeout(12000);
  report.replayReached = await page.evaluate(
    () => !!document.querySelector('#next-image'));

  report.panes = await page.evaluate(readPanes, PANES);
} catch (e) {
  report.harnessError = String(e && e.message).slice(0, 400);
} finally {
  await browser.close();
}

console.log(JSON.stringify(report, null, 2));
