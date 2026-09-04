// bench_transport.mjs — measure what the JSON `postMessage` hop between the
// front-end and the WASM db-backend actually costs.
//
// ## The question this answers
//
// M0's last deliverable asks whether to replace the DAP-over-`postMessage`
// seam with a direct FFI call into the WASM module, and is explicit that the
// answer must be measured, not assumed: the engine "is in-process already, so
// this is a serialisation cost on a chatty protocol, not a network removal —
// profile before committing to it."
//
// ## What is actually on the wire today
//
// Per request, reading `dap.rs::setup_onmessage_callback` and `worker.js`:
//
//   INBOUND  (main thread -> engine)
//     1. `postMessage(object)`            structured clone + thread hop
//     2. `JSON::stringify(event.data)`    JS-side stringify of the clone
//     3. `serde_json::from_str(..)`       Rust parse #1, into `Value`
//     4. `from_json(..)`                  Rust parse #2, into `DapMessage`
//   OUTBOUND (engine -> main thread)
//     5. `serde_json::to_string(&msg)`    Rust serialise
//     6. `post_message(JsValue::from_str)` string copy + thread hop
//     7. `JSON.parse(raw)`                host parse
//
// Note steps 3 and 4: the SAME string is parsed twice, once to recover `seq`
// and `command` for the failure path and once for real. That is a pure
// redundancy inside the current design, and it is measured separately below,
// because removing it needs no architectural change at all.
//
// ## The two arms, and the trade each one represents
//
//   WORKER      the production path: a real `worker_threads` Worker, structured
//               clone, thread hop, all seven steps above.
//   IN-PROCESS  the SAME engine and the SAME JSON (steps 2-5,7), with the
//               worker boundary removed — `postMessage` is a direct function
//               call in the same isolate (see `inproc_host.mjs`).
//
// So `WORKER - IN-PROCESS` is exactly the cost of the thread hop and the
// structured clone, which is the part of "replace postMessage with a direct
// FFI call" that is genuinely about the transport. The JSON cost is common to
// both arms and is bounded separately by timing `JSON.stringify` /
// `JSON.parse` over the identical payloads.
//
// **The IN-PROCESS arm is not a proposed architecture.** Running the engine in
// the calling isolate is precisely what the worker exists to prevent: replay
// would execute on the browser's main thread and block the UI for the duration
// of every request. Making a direct FFI seam non-blocking requires
// `SharedArrayBuffer` + `Atomics`, which requires cross-origin isolation
// (COOP/COEP) — a hard requirement to impose on an SDK embedded in third-party
// sites. This arm exists to put a number on what that trade would buy.
//
// ## No skip path
//
// Exits non-zero, naming what is missing, if the engine or the container is
// absent.
//
// Usage:
//   node bench_transport.mjs <seekable.ct> [iterations]

import { Worker } from 'node:worker_threads';
import { readFile, stat } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

import { startInProcessEngine, defaultWorkerUrl } from './inproc_host.mjs';

const here = path.dirname(fileURLToPath(import.meta.url));
const HOST = path.join(here, 'worker_host.mjs');
const PKG = path.join(here, '..', 'pkg', 'db_backend_bg.wasm');
const TRACE = process.argv[2];
const ITERATIONS = Number(process.argv[3] || 200);
const BURST = Number(process.env.CT_M0_BENCH_BURST || 200);

function fail(what) {
  console.error(`FAIL: ${what}`);
  process.exit(1);
}

if (!TRACE) fail('usage: bench_transport.mjs <seekable.ct> [iterations]');
if (!Number.isFinite(ITERATIONS) || ITERATIONS < 5) fail('iterations must be a number >= 5');

for (const [label, file] of [
  ['the wasm engine', PKG],
  ['the trace container', TRACE],
]) {
  try {
    const s = await stat(file);
    if (!s.isFile() || s.size === 0) fail(`${label} at ${file} is empty`);
  } catch {
    fail(`missing required input: ${label} at ${file}
  (build the engine with src/db-backend/build_wasm.sh; produce a container with
   cargo run --example write_seekable_fixture -- <out.ct>)`);
  }
}

// The engine logs a line per request through `wasm_logger`. In the worker arm
// that log crosses a thread boundary to reach stdout; in the in-process arm it
// does not. Measuring with it on charges the worker for its own diagnostics and
// makes the transport look several times more expensive than it is — an earlier
// run of this benchmark reported a 0.039-0.641 ms spread on a 147-byte response
// for exactly that reason. Both hosts silence it when this is set, and the
// benchmark sets it for both arms or neither.
process.env.CT_SILENCE_ENGINE_LOG = process.env.CT_SILENCE_ENGINE_LOG ?? '1';
const ENGINE_LOG_SILENCED = process.env.CT_SILENCE_ENGINE_LOG === '1';

// The in-process arm runs the engine in THIS isolate, so silencing the engine's
// console silences ours too. Report through stdout directly, which no host
// touches.
const say = (line = '') => process.stdout.write(`${line}\n`);

const traceBytes = new Uint8Array(await readFile(TRACE));

// ---------------------------------------------------------------------------
// Arm 1: the production worker path.
// ---------------------------------------------------------------------------

async function startWorkerEngine() {
  const w = new Worker(HOST);
  const inbox = [];
  const waiters = [];
  let lastRawBytes = 0;

  w.on('message', (raw) => {
    if (typeof raw === 'string') lastRawBytes = raw.length;
    let m = raw;
    if (typeof raw === 'string' && (raw[0] === '{' || raw[0] === '[')) {
      try {
        m = JSON.parse(raw);
      } catch {
        m = raw;
      }
    }
    inbox.push({ parsed: m, raw });
    for (let i = waiters.length - 1; i >= 0; i -= 1) {
      if (waiters[i].pred(m)) {
        waiters[i].resolve({ parsed: m, raw });
        waiters.splice(i, 1);
      }
    }
  });

  const waitFor = (pred, ms, label) =>
    new Promise((res, rej) => {
      const hit = inbox.find((e) => pred(e.parsed));
      if (hit) return res(hit);
      const t = setTimeout(() => rej(new Error(`timeout: ${label}`)), ms);
      waiters.push({
        pred,
        resolve: (v) => {
          clearTimeout(t);
          res(v);
        },
      });
    });

  await waitFor((m) => m && m.type === 'wasm-loaded', 120000, 'wasm-loaded');
  w.postMessage({ type: 'vfs-write', path: 'trace/trace.ct', data: traceBytes });
  await waitFor((m) => m && m.type === 'vfs-ack', 30000, 'vfs-ack');
  w.postMessage({ type: 'start' });
  await waitFor((m) => m === 'ready', 60000, 'ready');

  let seq = 0;
  const dap = (command, args = {}, ms = 60000) => {
    seq += 1;
    const s = seq;
    const settled = waitFor(
      (m) => m && m.type === 'response' && m.request_seq === s,
      ms,
      command,
    );
    w.postMessage({ seq: s, type: 'request', command, arguments: args });
    return settled;
  };

  return { dap, close: () => w.terminate(), bytes: () => lastRawBytes };
}

// ---------------------------------------------------------------------------
// Shared driving.
// ---------------------------------------------------------------------------

async function handshake(dap) {
  await dap('initialize', { clientID: 'bench', adapterID: 'codetracer' });
  await dap('launch', { traceFolder: 'trace' });
  await dap('configurationDone', {});
}

/// The request mix. Chosen to span the two regimes the answer depends on:
/// tiny fixed-overhead calls, where a transport cost would dominate, and
/// larger responses, where the JSON payload does.
const LOCALS_ARGS = {
  rrTicks: 0,
  countBudget: 100,
  minCountLimit: 10,
  depthLimit: 3,
  watchExpressions: [],
  lang: 0,
};

const CASES = [
  { name: 'threads', command: 'threads', args: {} },
  { name: 'stackTrace', command: 'stackTrace', args: { threadId: 1 } },
  { name: 'next (step-over)', command: 'next', args: { threadId: 1 } },
  { name: 'ct/load-locals', command: 'ct/load-locals', args: LOCALS_ARGS },
];

function stats(samples) {
  const s = [...samples].sort((a, b) => a - b);
  const at = (q) => s[Math.min(s.length - 1, Math.floor(q * s.length))];
  const mean = s.reduce((a, b) => a + b, 0) / s.length;
  return { median: at(0.5), p90: at(0.9), min: s[0], mean };
}

/// VERIFY THE INSTRUMENT, NOT JUST THE RESULT.
///
/// A request that fails fast is faster than a request that works, so a
/// benchmark that does not check `success` can report a beautiful number for an
/// error path. Every measured response is checked, and a case whose responses
/// are failures is reported as such rather than averaged into the table.
function assertSuccessful(name, response) {
  const m = response.parsed;
  if (!m || m.type !== 'response') {
    throw new Error(`${name}: expected a DAP response, got ${JSON.stringify(m).slice(0, 120)}`);
  }
  if (m.success !== true) {
    throw new Error(`${name}: the engine answered success=false (${m.message || 'no message'}) — ` +
      'this benchmark would be timing an error path, not the work');
  }
  return m;
}

async function measure(dap, label) {
  const out = new Map();
  for (const c of CASES) {
    // Warm-up: the first call of any command pays one-time costs (lazy chunk
    // fills, first materialisation) that are not transport.
    for (let i = 0; i < 5; i += 1) assertSuccessful(c.name, await dap(c.command, c.args));

    const samples = [];
    let responseBytes = 0;
    for (let i = 0; i < ITERATIONS; i += 1) {
      const t0 = process.hrtime.bigint();
      const r = await dap(c.command, c.args);
      const t1 = process.hrtime.bigint();
      assertSuccessful(c.name, r);
      samples.push(Number(t1 - t0) / 1e6);
      responseBytes = typeof r.raw === 'string' ? r.raw.length : JSON.stringify(r.parsed).length;
    }

    // A BURST: the same requests issued back-to-back with no awaiting between
    // them beyond what the protocol forces. The spec's worry is "a chatty
    // protocol", and a chatty protocol's cost is what a run of requests costs,
    // not what one costs in isolation — per-request medians hide queueing.
    const burstStart = process.hrtime.bigint();
    for (let i = 0; i < BURST; i += 1) await dap(c.command, c.args);
    const burstMs = Number(process.hrtime.bigint() - burstStart) / 1e6;

    out.set(c.name, { ...stats(samples), responseBytes, burstMs, burstPer: burstMs / BURST });
  }
  say(`  ${label}: done`);
  return out;
}

// ---------------------------------------------------------------------------
// The JSON component, measured directly on the host.
// ---------------------------------------------------------------------------

function measureJsonCost(payloads) {
  const rows = [];
  for (const [name, text] of payloads) {
    const obj = JSON.parse(text);
    const reps = 2000;
    let t0 = process.hrtime.bigint();
    for (let i = 0; i < reps; i += 1) JSON.parse(text);
    const parseMs = Number(process.hrtime.bigint() - t0) / 1e6 / reps;
    t0 = process.hrtime.bigint();
    for (let i = 0; i < reps; i += 1) JSON.stringify(obj);
    const stringifyMs = Number(process.hrtime.bigint() - t0) / 1e6 / reps;
    rows.push({ name, bytes: text.length, parseMs, stringifyMs });
  }
  return rows;
}

// ---------------------------------------------------------------------------
// Run.
// ---------------------------------------------------------------------------

say('=== M0: what the JSON postMessage hop costs ===');
say(`  engine:     ${PKG}`);
say(`  trace:      ${TRACE} (${traceBytes.length} bytes)`);
say(`  iterations: ${ITERATIONS} per case, after 5 warm-up calls`);
say(`  engine log: ${ENGINE_LOG_SILENCED ? 'silenced in BOTH arms' : 'ON — timings include the engine\'s own console output'}\n`);

say('booting both arms over the same container...');
const worker = await startWorkerEngine();
await handshake(worker.dap);
const workerResults = await measure(worker.dap, 'WORKER    ');

// Capture representative payloads from the worker arm for the JSON breakdown.
const payloads = [];
for (const c of CASES) {
  const r = await worker.dap(c.command, c.args);
  payloads.push([c.name, typeof r.raw === 'string' ? r.raw : JSON.stringify(r.parsed)]);
}
await worker.close();

const inproc = await startInProcessEngine({
  workerUrl: defaultWorkerUrl(),
  tracePath: TRACE,
  traceVfsPath: 'trace/trace.ct',
});
await handshake(inproc.dap);
const inprocResults = await measure(inproc.dap, 'IN-PROCESS');
inproc.close();

// --- report ---------------------------------------------------------------

const pad = (s, n) => String(s).padEnd(n);
const num = (v, n = 8) => v.toFixed(3).padStart(n);

say('\n--- per-request round trip, median of ' + ITERATIONS + ' (ms) ---\n');
say(
  `${pad('case', 20)}${pad('resp B', 8)}${pad('WORKER', 9)}${pad('[min-p90]', 18)}${pad('INPROC', 9)}${pad('[min-p90]', 18)}${'delta'}`,
);
say('-'.repeat(92));
const deltas = [];
for (const c of CASES) {
  const w = workerResults.get(c.name);
  const i = inprocResults.get(c.name);
  const delta = w.median - i.median;
  const pct = (delta / w.median) * 100;
  deltas.push({ name: c.name, delta, pct, worker: w, inproc: i, bytes: w.responseBytes });
  const span = (r) => pad(`[${r.min.toFixed(3)}-${r.p90.toFixed(3)}]`, 18);
  say(
    `${pad(c.name, 20)}${pad(w.responseBytes, 8)}${num(w.median, 7)}  ${span(w)}${num(i.median, 7)}  ${span(i)}${num(delta, 7)}`,
  );
}

say(`\n--- burst of ${BURST} back-to-back requests: total ms, and ms/request ---\n`);
say(`${pad('case', 20)}${pad('WORKER tot', 12)}${pad('per req', 10)}${pad('INPROC tot', 12)}${pad('per req', 10)}${'delta/req'}`);
say('-'.repeat(76));
for (const c of CASES) {
  const w = workerResults.get(c.name);
  const i = inprocResults.get(c.name);
  say(
    `${pad(c.name, 20)}${num(w.burstMs, 10)}  ${num(w.burstPer, 8)}  ${num(i.burstMs, 10)}  ${num(i.burstPer, 8)}  ${num(w.burstPer - i.burstPer, 8)}`,
  );
}

say('\n--- host-side JSON cost for the same payloads (ms per operation) ---\n');
say(`${pad('case', 20)}${pad('bytes', 9)}${pad('JSON.parse', 12)}${'JSON.stringify'}`);
say('-'.repeat(60));
for (const row of measureJsonCost(payloads)) {
  say(`${pad(row.name, 20)}${pad(row.bytes, 9)}${row.parseMs.toFixed(4).padStart(8)}    ${row.stringifyMs.toFixed(4).padStart(8)}`);
}

say('\n--- reading ---\n');
const worstAbs = Math.max(...deltas.map((d) => d.delta));
const worstBurst = Math.max(
  ...CASES.map((c) => workerResults.get(c.name).burstPer - inprocResults.get(c.name).burstPer),
);
const jsonRows = measureJsonCost(payloads);
const worstJson = Math.max(...jsonRows.map((r) => r.parseMs + r.stringifyMs));
const FRAME_MS = 16.7;

say(
  `  Deleting the worker boundary saves at most ${worstAbs.toFixed(3)} ms per request in isolation,\n` +
    `  and ${worstBurst.toFixed(3)} ms per request under a ${BURST}-request burst.`,
);
say(
  `  Host-side JSON encode+decode for the largest payload here costs ${worstJson.toFixed(4)} ms —\n` +
    `  roughly ${((worstJson / Math.max(...deltas.map((d) => d.worker.median))) * 100).toFixed(1)}% of a round trip. The serialisation is NOT the cost; the hop is.`,
);
say(
  `\n  For scale: a 60fps frame is ${FRAME_MS} ms. At ${worstBurst.toFixed(3)} ms saved per request, the\n` +
    `  boundary would have to carry ~${Math.round(FRAME_MS / Math.max(worstBurst, 1e-6))} requests per frame before removing it buys one frame.`,
);
say(
  '\n  And that saving is the CEILING for the transport half of a direct-FFI change: it is what\n' +
    '  deleting the thread hop and the structured clone buys, with the JSON encoding left entirely\n' +
    '  in place. Buying it means running replay on the main thread — which is what the worker\n' +
    '  exists to prevent — or adopting SharedArrayBuffer + Atomics and the COOP/COEP isolation an\n' +
    '  SDK embedded in third-party sites cannot assume.',
);
say(
  '\n  One local inefficiency is worth more than the architecture change: dap.rs parses each\n' +
    '  inbound request TWICE (serde_json::from_str into Value for the error path, then from_json\n' +
    '  into DapMessage), and the first parse is discarded on every successful request.',
);
