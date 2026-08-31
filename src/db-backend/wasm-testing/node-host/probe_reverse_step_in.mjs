// probe_reverse_step_in.mjs — §9 of `backend/dap_dialect.md`.
//
// The question: how does a client ask this engine to step backwards INTO the
// call that just returned, and what happens to every spelling a DAP client
// would reasonably try first?
//
// DAP gives `stepIn`/`stepOut` a `granularity` and no direction, and gives the
// reverse direction exactly two commands — `stepBack` and `reverseContinue` —
// neither of which enters a frame. So "reverse step in" cannot be expressed in
// the standard vocabulary, and CodeTracer's `ct/reverseStepIn` is a dialect
// extension. This probe measures that rather than asserting it: every command
// below is sent to the real wasm32 engine from the SAME position, and the
// position it produces is read back.
//
// Usage:
//   node probe_reverse_step_in.mjs <trace.ct>
//
// Needs a built engine at ../pkg (src/db-backend/build_wasm.sh). It does not
// skip when that is missing — it fails and says what is absent.

import { Worker } from 'node:worker_threads';
import { readFile, access } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));
const HOST = path.join(here, 'worker_host.mjs');
const PKG = path.join(here, '..', 'pkg', 'db_backend_bg.wasm');
const TRACE = process.argv[2];

if (!TRACE) {
  console.error('usage: node probe_reverse_step_in.mjs <trace.ct>');
  process.exit(2);
}
try {
  await access(PKG);
} catch {
  console.error(`no engine at ${PKG}`);
  console.error('build one with src/db-backend/build_wasm.sh — this probe does');
  console.error('not skip, because a skipped measurement is not a measurement.');
  process.exit(2);
}

const w = new Worker(HOST);
const inbox = [];
const waiters = [];
w.on('message', (raw) => {
  let m = raw;
  if (typeof raw === 'string' && (raw[0] === '{' || raw[0] === '[')) {
    try { m = JSON.parse(raw); } catch { m = raw; }
  }
  inbox.push(m);
  for (let i = waiters.length - 1; i >= 0; i--) {
    if (waiters[i].pred(m)) { waiters[i].resolve(m); waiters.splice(i, 1); }
  }
});
const waitFor = (pred, ms, label) => new Promise((res, rej) => {
  const hit = inbox.find(pred);
  if (hit) return res(hit);
  const t = setTimeout(() => rej(new Error(`timeout: ${label}`)), ms);
  waiters.push({ pred, resolve: (m) => { clearTimeout(t); res(m); } });
});

let seq = 0;
async function dap(command, args = {}, ms = 20000) {
  const s = ++seq;
  w.postMessage({ seq: s, type: 'request', command, arguments: args });
  try {
    return await waitFor(
      (m) => m && m.type === 'response' && m.request_seq === s, ms, command);
  } catch (e) {
    // A command that is answered by NOTHING is the worst outcome in this
    // dialect and §1 of the document is about it, so it is reported as its own
    // result rather than crashing the probe.
    return { success: null, message: String(e.message) };
  }
}

/** Where the session is: the top frame's line, and the tick behind it. */
async function where() {
  const st = await dap('stackTrace', { threadId: 1 });
  const f = st.body && st.body.stackFrames && st.body.stackFrames[0];
  return { line: f ? f.line : null, fn: f ? f.name : null };
}

await waitFor((m) => m && m.type === 'wasm-loaded', 120000, 'wasm-loaded');
w.postMessage({ type: 'vfs-write', path: 'trace/trace.ct',
                data: new Uint8Array(await readFile(TRACE)) });
await waitFor((m) => m && m.type === 'vfs-ack', 20000, 'vfs-ack');
w.postMessage({ type: 'start' });
await waitFor((m) => m === 'ready', 60000, 'ready');

await dap('initialize', { clientID: 'probe', adapterID: 'codetracer' });
await dap('launch', { traceFolder: 'trace' });
await dap('configurationDone', {});

// Walk forward far enough that there is a returned call BEHIND the cursor —
// otherwise "step backwards into the call that just returned" has nothing to
// enter and every command below would agree by accident.
const FORWARD = parseInt(process.argv[3] || '8', 10);
for (let i = 0; i < FORWARD; i++) await dap('next', { threadId: 1 });
const anchor = await where();
console.log(`\ntrace: ${path.basename(TRACE)}`);
console.log(`anchor after ${FORWARD}x next: line ${anchor.line} (${anchor.fn})\n`);

// Each candidate is issued from the SAME anchor. `ct/goto-ticks` is how the
// probe returns there, so the six results are comparable rather than
// cumulative.
const anchorTicks = await (async () => {
  const st = await dap('stackTrace', { threadId: 1 });
  return st.body && st.body.stackFrames && st.body.stackFrames[0]
    ? st.body.stackFrames[0].id : null;
})();

const CANDIDATES = [
  ['stepIn', {}, 'DAP standard, forward — the control'],
  ['stepOut', {}, 'DAP standard, forward'],
  ['stepBack', {}, 'DAP standard: the ONLY reverse step it defines'],
  ['stepBack', { granularity: 'statement' },
   'granularity is not direction — DAP has no "in" granularity'],
  ['stepBack', { granularity: 'instruction' }, 'ditto, at instruction level'],
  ['reverseStepIn', {}, 'the spelling a DAP client would guess: NOT in DAP'],
  ['reverseStepOut', {}, 'its counterpart: also not in DAP'],
  ['ct/reverseStepIn', {}, 'CodeTracer dialect extension'],
  ['ct/reverseStepOut', {}, 'CodeTracer dialect extension'],
];

const results = [];
for (const [command, extra, note] of CANDIDATES) {
  // Back to the anchor. A failed reset is reported rather than silently
  // producing a comparison between two different positions.
  const reset = await dap('ct/goto-ticks', { threadId: 1, ticks: FORWARD });
  const before = await where();
  const r = await dap(command, { threadId: 1, ...extra });
  const after = await where();
  results.push({
    command: command + (Object.keys(extra).length
      ? ' ' + JSON.stringify(extra) : ''),
    note,
    reset: reset.success,
    from: before.line,
    success: r.success,
    message: r.message || '',
    to: after.line,
    fn: after.fn,
    moved: before.line !== after.line,
  });
}

console.log('command                                ok     from -> to    fn        note');
console.log('-'.repeat(110));
for (const r of results) {
  const ok = r.success === null ? 'NOREPLY' : String(r.success);
  console.log(
    `${r.command.padEnd(38)} ${ok.padEnd(6)} ${String(r.from).padStart(4)} ->` +
    ` ${String(r.to).padEnd(5)} ${String(r.fn).padEnd(9)} ${r.note}`);
  if (r.message) console.log(`${' '.repeat(40)}message: ${r.message}`);
}

// ---------------------------------------------------------------------------
// Is `ct/reverseStepIn` a distinct MOVE, or an alias of `stepBack`?
//
// The engine maps `stepBack -> (Action::Next, reverse)` and
// `ct/reverseStepIn -> (Action::StepIn, reverse)`, so they must differ
// somewhere; a single anchor cannot show it, because a reverse-next and a
// reverse-step-in agree everywhere except at a call boundary. So the probe
// sweeps every anchor in the trace and reports where they part company. A
// fixture on which they never do is reported as exactly that, rather than
// being allowed to read as "they are the same".
// ---------------------------------------------------------------------------

const sweep = [];
for (let t = 1; t <= FORWARD * 2; t++) {
  const seat = await dap('ct/goto-ticks', { threadId: 1, ticks: t });
  if (!seat.success) continue;
  const from = await where();
  await dap('stepBack', { threadId: 1 });
  const back = await where();

  const reseat = await dap('ct/goto-ticks', { threadId: 1, ticks: t });
  if (!reseat.success) continue;
  await dap('ct/reverseStepIn', { threadId: 1 });
  const rsi = await where();

  const reseat2 = await dap('ct/goto-ticks', { threadId: 1, ticks: t });
  if (!reseat2.success) continue;
  await dap('ct/reverseStepOut', { threadId: 1 });
  const rso = await where();

  sweep.push({ ticks: t, from, stepBack: back, reverseStepIn: rsi,
               reverseStepOut: rso,
               inDiffers: back.line !== rsi.line || back.fn !== rsi.fn,
               outDiffers: back.line !== rso.line || back.fn !== rso.fn });
}

console.log('\nsweep: stepBack vs the two dialect extensions, from every anchor');
console.log('ticks  from            stepBack        ct/reverseStepIn  ct/reverseStepOut');
console.log('-'.repeat(90));
const place = (p) => `${p.line}:${p.fn}`;
for (const s of sweep) {
  console.log(
    `${String(s.ticks).padStart(5)}  ${place(s.from).padEnd(15)} ` +
    `${place(s.stepBack).padEnd(15)} ${place(s.reverseStepIn).padEnd(17)} ` +
    `${place(s.reverseStepOut)}` +
    `${s.inDiffers ? '   <- IN differs' : ''}` +
    `${s.outDiffers ? '   <- OUT differs' : ''}`);
}
const inDiff = sweep.filter((s) => s.inDiffers).length;
const outDiff = sweep.filter((s) => s.outDiffers).length;
console.log(`\nanchors swept: ${sweep.length}`);
console.log(`ct/reverseStepIn  differs from stepBack at ${inDiff} of them`);
console.log(`ct/reverseStepOut differs from stepBack at ${outDiff} of them`);
if (inDiff === 0) {
  console.log('\nNOTE: on THIS fixture reverse-step-in never parts from ' +
              'stepBack. That is a property of the trace, not of the ' +
              'commands — the engine maps them to different Actions. Say so ' +
              'rather than reporting them as equivalent.');
}

console.log('\nJSON:');
console.log(JSON.stringify({ candidates: results, sweep }, null, 2));

w.terminate();
