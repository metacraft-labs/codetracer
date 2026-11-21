// browser.mjs — the browser front-end's ViewModel core, opened on a real
// recording by a real replay-server, in a real browser.
//
// Usage: node browser.mjs <built-dir> <chromium|firefox> <replay-server> <recording> [steps]
//
// Starts relay.mjs (HTTP for the page, a WebSocket per page relayed to its own
// `replay-server dap-server --stdio`), then for each core build — wasm32 and
// `nim js` — opens the page, waits for the session to be ready and the panes
// to draw, and steps forward `steps` times. After the open and after every
// step it records the three panes' documents, once the frame stream has gone
// quiet. It passes when both builds:
//
//   * reached `ready` and drew rows in the variables pane and Call Trace;
//   * moved on every step (the reported position changed at least once);
//   * crossed no read operation (the boundary stayed write-only);
//   * drew the SAME documents, phase for phase — the wasm core against the
//     same core compiled the current way.
//
// No mocks: the engine, the recording, the browser and the input are real.
// The relay is transport, not a stand-in: it frames bytes and reads none.
//
// Exit 0 on a pass, 1 on a failed check, 2 when Playwright, the engine or the
// recording is missing.

import fs from 'node:fs';
import path from 'node:path';
import { spawn } from 'node:child_process';
import { createRequire } from 'node:module';

const [dir, engine, replayServer, recording, stepsArg] = process.argv.slice(2);
if (!dir || !['chromium', 'firefox'].includes(engine || '') || !replayServer || !recording) {
  console.error('usage: node browser.mjs <built-dir> <chromium|firefox> <replay-server> <recording> [steps]');
  process.exit(2);
}
for (const p of [replayServer, recording]) {
  if (!fs.existsSync(p)) { console.error(`browser.mjs: ${p} does not exist`); process.exit(2); }
}
const STEPS = Number(stepsArg || 4);
// Every pane the desktop's panel host mounts beyond the three, drawn by the
// core on request (`ctwMountPane`).
const EXTRA_PANES = ['build', 'command-palette', 'errors', 'filesystem', 'low-level-code',
  'point-list', 'repl', 'scratchpad', 'search-results', 'step-list', 'terminal-output',
  'trace-log'];
// A stop that has not settled in this long is a failure, not a snapshot.
const SETTLE_MS = Number(process.env.CT_WEB_CORE_SETTLE_MS || 120000);
const repo = process.env.CT_REPO || process.cwd();
let pw;
try {
  pw = createRequire(path.join(repo, 'package.json'))('playwright');
} catch (e) {
  console.error('browser.mjs: node_modules/playwright is absent — run inside the dev shell');
  process.exit(2);
}

const here = path.dirname(new URL(import.meta.url).pathname);
const relay = spawn(process.execPath, [path.join(here, 'relay.mjs'), dir, replayServer],
                    { stdio: ['ignore', 'pipe', 'inherit'], env: { ...process.env, CT_REPO: repo } });
const port = await new Promise((ok, no) => {
  let out = '';
  relay.stdout.on('data', (d) => {
    out += d;
    const m = /RELAY listening (\d+)/.exec(out);
    if (m) ok(Number(m[1]));
  });
  relay.on('exit', (c) => no(new Error(`the relay exited ${c}`)));
});

let browser;
try {
  browser = await pw[engine].launch();
} catch (e) {
  console.error(`browser.mjs: ${engine} could not be launched: ${e.message.split('\n')[0]}`);
  relay.kill();
  process.exit(2);
}

const sleep = (ms) => new Promise((ok) => setTimeout(ok, ms));

async function settle(page, timeoutMs, notAt) {
  // Settled: the debugger reports a real stop (a line, and not the one it was
  // at before the action), no step and no fresh request is in flight, and no frame has been
  // applied for 2 s — the panes have drawn what that stop loads (a pane debounces its viewport before it asks).
  const start = Date.now();
  const end = start + timeoutMs;
  let last = -1;
  let quietSince = Date.now();
  let readyAt = 0;
  while (Date.now() < end) {
    const s = await page.evaluate(() => {
      const st = globalThis.ctwHost.state();
      // A pane still showing a loading indicator is still waiting for the
      // engine: the stop has not finished drawing, however quiet the frames.
      // The three panes a stop reloads; another pane's placeholder (a pane
      // with nothing to show yet) is not a load in flight.
      const loads = [...document.querySelectorAll(
        '[data-pane=state] *, [data-pane=calltrace] *, [data-pane=event-log] *')].filter((el) =>
        el.children.length === 0 && /loading/i.test(el.className + ' ' + el.textContent) &&
        getComputedStyle(el).display !== 'none' && el.offsetParent !== null);
      st.loading = loads.length > 0;
      st.inFlight = globalThis.ctwInFlight ? globalThis.ctwInFlight() : st.pending;
      st.loadingWhat = loads.slice(0, 3).map((el) => el.className || el.tagName).join(' | ');
      return st;
    });
    const stopped = /:[1-9][0-9]*$/.test(s.position) && s.position !== notAt;
    const busy = s.stepping || !stopped || s.loading || s.inFlight > 0;
    // The latency is to the stop drawn: moved, not stepping, nothing loading.
    // A request still in flight then (a section the engine superseded) is
    // not part of what the user waits for.
    const drawn = !s.stepping && stopped && !s.loading;
    if (!drawn) readyAt = 0;
    else if (!readyAt) readyAt = Date.now();
    if (s.frames !== last || busy) { last = s.frames; quietSince = Date.now(); }
    else if (Date.now() - quietSince >= 2000) return { ...s, settled: true, readyMs: readyAt - start + (notAt ? 50 : 0) };
    await sleep(25);
  }
  const s = await page.evaluate(() => globalThis.ctwHost.state());
  const what = await page.evaluate(() => [...document.querySelectorAll(
    '[data-pane=state] *, [data-pane=calltrace] *, [data-pane=event-log] *')].filter((el) =>
      el.children.length === 0 && /loading/i.test(el.className + ' ' + el.textContent) &&
      getComputedStyle(el).display !== 'none' && el.offsetParent !== null)
    .map((el) => (el.closest('.ct-web-core-pane') || {}).dataset?.pane + ':' + el.className).join(' | '));
  console.log(`  unsettled: position=${s.position} stepping=${s.stepping} pending=${s.pending}` +
              ` frames=${s.frames} lastFrames=${last} loading=[${what}]` +
              ` unanswered=[${await page.evaluate(() => (globalThis.ctwUnanswered ? globalThis.ctwUnanswered() : []).join(', '))}]`);
  return { ...s, settled: false };
}

async function snapshot(page) {
  return page.evaluate(() => {
    const out = {};
    for (const el of document.querySelectorAll('.ct-web-core-pane')) {
      // The core's document. The scrubbers are the host's own elements, drawn
      // from layout on a timer of their own, and are left out.
      const copy = el.cloneNode(true);
      for (const n of copy.querySelectorAll('.ct-list-scrubber, .ct-hscrubber')) n.remove();
      out[el.dataset.pane] = copy.innerHTML;
    }
    out.stateRows = document.querySelectorAll('[data-pane=state] .value-expanded-name[data-variable-name]').length;
    out.callRows = document.querySelectorAll('[data-pane=calltrace] .calltrace-call-line').length;
    out.decorated = document.querySelectorAll('.ct-web-core-pane[data-ctw-decorated="1"]').length;
    return out;
  });
}

let failures = 0;
const runs = {};
const timings = {};
for (const arm of ['wasm', 'js']) {
  const page = await browser.newPage();
  const errors = [];
  page.on('pageerror', (e) => errors.push(String(e)));
  const url = `http://127.0.0.1:${port}/page.html?arm=${arm}&folder=${encodeURIComponent(path.resolve(recording))}` +
              `&extra=${EXTRA_PANES.join(',')}`;
  const t0 = Date.now();
  await page.goto(url);
  await page.waitForFunction(() => globalThis.ctwHost || globalThis.ctwError, null, { timeout: 60000 });
  const bootError = await page.evaluate(() => globalThis.ctwError || null);
  if (bootError) {
    console.log(`  FAIL: ${engine}/${arm} did not start: ${bootError}`);
    failures++; await page.close(); continue;
  }
  await page.waitForFunction(() => ['ready', 'failed'].includes(globalThis.ctwHost.state().phase),
                             null, { timeout: 60000 }).catch(() => {});
  let s = await settle(page, SETTLE_MS);
  const unsettled = [];
  const stepMs = [];
  if (!s.settled) unsettled.push('open');
  const openMs = Date.now() - t0;
  const problems = [];
  if (s.phase !== 'ready') problems.push(`the session is ${s.phase}: ${s.failure}`);
  const phases = [await snapshot(page)];
  const positions = [s.position];
  for (let i = 0; i < STEPS && s.phase === 'ready'; i++) {
    await page.evaluate(() => globalThis.ctwHost.step(0));   // sdForward: `next`
    await sleep(50);
    s = await settle(page, SETTLE_MS, positions[positions.length - 1]);
    if (!s.settled) unsettled.push(`step ${i + 1}`);
    else stepMs.push(s.readyMs);
    phases.push(await snapshot(page));
    positions.push(s.position);
  }
  if (!phases.some((p) => p.callRows > 0)) problems.push('Call Trace drew no rows at any stop');
  if (!phases.some((p) => p.stateRows > 0)) problems.push('the variables pane drew no rows at any stop');
  if (new Set(positions).size < 2) problems.push(`the position never moved: ${positions.join(' ')}`);
  // Expanding a wide value through the core's own press procedure (the one
  // the desktop's pointer performs): its rows must appear, and the time from
  // the press to the first frame that holds them is the expand latency.
  const wide = await page.evaluate(() => {
    const row = [...document.querySelectorAll('[data-pane=state] [data-variable-path]')]
      .find((e) => /^wide_/.test(e.getAttribute('data-variable-path') || '')) ||
      // Before the program builds its wide values, the module's builtins
      // are the stop's largest value (some hundred and fifty members).
      [...document.querySelectorAll('[data-pane=state] [data-variable-path]')]
        .find((e) => e.getAttribute('data-variable-path') === '__builtins__');
    if (!row) {
      return { missing: [...document.querySelectorAll('[data-pane=state] [data-variable-path]')]
        .slice(0, 12).map((e) => e.getAttribute('data-variable-path')) };
    }
    const before = document.querySelectorAll('[data-pane=state] [data-variable-path]').length;
    globalThis.ctwExpandT0 = performance.now();
    const acted = globalThis.ctwHost.press('variables.toggle-expand', row);
    return { path: row.getAttribute('data-variable-path'), before, acted };
  });
  let expandMs = null;
  if (wide && wide.missing) console.log(`  note: ${engine}/${arm}: no wide_ value to expand among ${wide.missing.join(', ')}`);
  if (wide && !wide.missing) {
    if (!wide.acted) problems.push(`the core did not act on a press to expand ${wide.path}`);
    const grown = await page.waitForFunction((n) =>
      document.querySelectorAll('[data-pane=state] [data-variable-path]').length > n + 100,
      wide.before, { timeout: 120000, polling: 'raf' }).then(() => true, () => false);
    if (!grown) problems.push(`expanding ${wide.path} did not draw its members`);
    else expandMs = await page.evaluate(() => performance.now() - globalThis.ctwExpandT0);
  }
  timings[arm] = { stepMs, expandMs };
  // The guide layer the core draws from the host's measurement.
  const guides = await page.evaluate(() =>
    document.querySelectorAll('[data-pane=calltrace] svg#svg-content-0 line').length);
  if (!(guides > 0)) problems.push(`Call Trace drew ${guides} guide line(s)`);
  // The watch form: a submitted expression becomes a watched row.
  await page.fill('[data-pane=state] #watch-0', 'ctw_watch_probe');
  await page.press('[data-pane=state] #watch-0', 'Enter');
  const watched = await page.waitForFunction(() =>
    [...document.querySelectorAll('[data-pane=state] [data-variable-name]')]
      .some((el) => el.getAttribute('data-variable-name') === 'ctw_watch_probe'), null, { timeout: 30000 })
    .then(() => true, () => false);
  if (!watched) problems.push('a watch submitted through the form did not appear');
  if (phases[phases.length - 1].decorated !== 3) problems.push(`${phases[phases.length - 1].decorated} of 3 panes decorated by the host`);
  const drawn = await page.evaluate((names) => names.filter((n) => {
    const el = document.querySelector(`.ct-web-core-pane[data-pane="${n}"]`);
    return !el || el.children.length === 0;
  }), EXTRA_PANES);
  if (drawn.length) problems.push(`panes not drawn: ${drawn.join(', ')}`);
  if (unsettled.length) problems.push(`did not settle within ${SETTLE_MS} ms after: ${unsettled.join(', ')}`);
  if (s.readCrossings !== 0) problems.push(`${s.readCrossings} read crossing(s)`);
  if (errors.length) problems.push(`page errors: ${errors.join(' | ')}`);
  runs[arm] = { phases, positions };
  if (problems.length) {
    for (const p of problems) console.log(`  FAIL: ${engine}/${arm}: ${p}`);
    failures++;
  } else {
    console.log(`WEB-CORE ok engine=${engine} arm=${arm} open_ms=${openMs} steps=${STEPS}` +
                ` positions=${positions.join(',')} state_rows=${phases.map((p) => p.stateRows).join(',')}` +
                ` call_rows=${phases.map((p) => p.callRows).join(',')} applied_ops=${s.applied}`);
  }
  await page.close();
}

if (runs.wasm && runs.js) {
  const a = runs.wasm, b = runs.js;
  if (a.positions.join(' ') !== b.positions.join(' ')) {
    console.log(`  FAIL: ${engine}: the cores stopped at different positions: wasm ${a.positions.join(' ')} js ${b.positions.join(' ')}`);
    failures++;
  }
  for (let i = 0; i < Math.min(a.phases.length, b.phases.length); i++) {
    for (const pane of ['state', 'calltrace', 'event-log', ...EXTRA_PANES]) {
      if (a.phases[i][pane] !== b.phases[i][pane]) {
        const x = a.phases[i][pane] || '', y = b.phases[i][pane] || '';
        let at = 0;
        while (at < x.length && x[at] === y[at]) at++;
        console.log(`  FAIL: ${engine}: phase ${i} ${pane}: the wasm and js documents differ at character ${at}:` +
                    ` wasm ${JSON.stringify(x.slice(at, at + 80))} js ${JSON.stringify(y.slice(at, at + 80))}`);
        failures++;
      }
    }
  }
  if (!failures) console.log(`WEB-CORE-PARITY ok engine=${engine} phases=${a.phases.length}`);
}

const med = (xs) => { const a = [...xs].sort((x, y) => x - y); return a.length ? a[Math.floor(a.length / 2)] : null; };
for (const [arm, t] of Object.entries(timings)) {
  console.log(`WEB-CORE-LATENCY engine=${engine} arm=${arm} step_ms_median=${med(t.stepMs)} step_ms=${t.stepMs.join(',')}` +
              ` expand_ms=${t.expandMs === null ? 'na' : t.expandMs.toFixed(1)}`);
}
await browser.close();
relay.kill();
process.exit(failures ? 1 : 0);
