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
  // at before the action), no step and no request is in flight, and no frame has been
  // applied for 2 s — the panes have drawn what that stop loads (a pane debounces its viewport before it asks).
  const end = Date.now() + timeoutMs;
  let last = -1;
  let quietSince = Date.now();
  while (Date.now() < end) {
    const s = await page.evaluate(() => {
      const st = globalThis.ctwHost.state();
      // A pane still showing a loading indicator is still waiting for the
      // engine: the stop has not finished drawing, however quiet the frames.
      st.loading = [...document.querySelectorAll('.ct-web-core-pane *')].some((el) =>
        el.children.length === 0 && /loading/i.test(el.className + ' ' + el.textContent) &&
        getComputedStyle(el).display !== 'none' && el.offsetParent !== null);
      return st;
    });
    const stopped = /:[1-9][0-9]*$/.test(s.position) && s.position !== notAt;
    if (s.frames !== last || s.stepping || !stopped || s.loading || s.pending > 0) { last = s.frames; quietSince = Date.now(); }
    else if (Date.now() - quietSince >= 2000) return { ...s, settled: true };
    await sleep(100);
  }
  const s = await page.evaluate(() => globalThis.ctwHost.state());
  return { ...s, settled: false };
}

async function snapshot(page) {
  return page.evaluate(() => {
    const out = {};
    for (const el of document.querySelectorAll('.ct-web-core-pane')) {
      out[el.dataset.pane] = el.innerHTML;
    }
    out.stateRows = document.querySelectorAll('[data-pane=state] .value-expanded-name[data-variable-name]').length;
    out.callRows = document.querySelectorAll('[data-pane=calltrace] .calltrace-call-line').length;
    out.decorated = document.querySelectorAll('.ct-web-core-pane[data-ctw-decorated="1"]').length;
    return out;
  });
}

let failures = 0;
const runs = {};
for (const arm of ['wasm', 'js']) {
  const page = await browser.newPage();
  const errors = [];
  page.on('pageerror', (e) => errors.push(String(e)));
  const url = `http://127.0.0.1:${port}/page.html?arm=${arm}&folder=${encodeURIComponent(path.resolve(recording))}`;
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
    phases.push(await snapshot(page));
    positions.push(s.position);
  }
  if (!phases.some((p) => p.callRows > 0)) problems.push('Call Trace drew no rows at any stop');
  if (!phases.some((p) => p.stateRows > 0)) problems.push('the variables pane drew no rows at any stop');
  if (new Set(positions).size < 2) problems.push(`the position never moved: ${positions.join(' ')}`);
  if (phases[phases.length - 1].decorated !== 3) problems.push(`${phases[phases.length - 1].decorated} of 3 panes decorated by the host`);
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
    for (const pane of ['state', 'calltrace', 'event-log']) {
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

await browser.close();
relay.kill();
process.exit(failures ? 1 : 0);
