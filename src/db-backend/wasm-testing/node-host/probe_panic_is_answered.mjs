// probe_panic_is_answered.mjs — every request to the wasm32 replay engine is
// answered, including one whose handler panics.
//
// The Debug Adapter Protocol requires a response to every request
// (https://microsoft.github.io/debug-adapter-protocol/overview#requests). On
// `wasm32-unknown-unknown` a panic aborts: the engine traps inside the message
// handler, so before the panic net (`browser_panic_net` in
// `src/db-backend/src/dap.rs`) the request that panicked got no response and
// neither did any request after it — each client call waited out its own
// timeout.
//
// What this checks, against the REAL engine run by the real `worker.js` in a
// `worker_threads` worker (`worker_host.mjs`):
//
//   1. Unarmed: `scopes` with a `frameId` no frame has is refused by name,
//      without a panic, and the engine goes on serving `stackTrace` as before.
//   2. Armed (`CT_ENGINE_TEST_PANIC_ON_COMMAND=scopes`, which makes the
//      engine's `scopes` handler panic on purpose — no real request is
//      guaranteed to panic, so the test needs a deliberate one): the
//      panicking `scopes` is answered `success: false`, naming the command,
//      its seq and the panic; every request after it is answered
//      `success: false` saying the engine has stopped, at once.
//
// Exits 0 when every check holds, 1 naming each one that does not.
//
// Usage: node probe_panic_is_answered.mjs <trace.ct>
import { Worker } from 'node:worker_threads';
import { readFile } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));
const HOST = path.join(here, 'worker_host.mjs');
const TRACE = process.argv[2];
if (!TRACE) {
  console.error('usage: node probe_panic_is_answered.mjs <trace.ct>');
  process.exit(2);
}

// An answer that has not arrived in this long is not coming: a refusal and a
// panic both answer at once.
const ANSWER_MS = 8000;
const UNKNOWN_FRAME_ID = 987654321;

const failures = [];
function check(ok, what) {
  console.log(`${ok ? 'ok  ' : 'FAIL'} ${what}`);
  if (!ok) failures.push(what);
}

async function session(panicOn) {
  const env = { ...process.env, CT_SILENCE_ENGINE_LOG: '1' };
  if (panicOn) {
    env.CT_ENGINE_TEST_PANIC_ON_COMMAND = panicOn;
  } else {
    delete env.CT_ENGINE_TEST_PANIC_ON_COMMAND;
  }
  const w = new Worker(HOST, { env });
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
    const t = setTimeout(() => rej(new Error(`no ${label} within ${ms} ms`)), ms);
    waiters.push({ pred, resolve: (m) => { clearTimeout(t); res(m); } });
  });
  let seq = 0;
  const dap = async (command, args = {}, ms = 20000) => {
    const s = ++seq;
    w.postMessage({ seq: s, type: 'request', command, arguments: args });
    const r = await waitFor((m) => m && m.type === 'response' && m.request_seq === s, ms, `response to ${command} (seq ${s})`);
    return { ...r, seq: s };
  };

  await waitFor((m) => m && m.type === 'wasm-loaded', 60000, 'wasm-loaded');
  w.postMessage({ type: 'vfs-write', path: 'trace/trace.ct', data: new Uint8Array(await readFile(TRACE)) });
  await waitFor((m) => m && m.type === 'vfs-ack', 20000, 'vfs-ack');
  w.postMessage({ type: 'start' });
  await waitFor((m) => m === 'ready', 30000, 'ready');
  await dap('initialize', { clientID: 'probe', adapterID: 'codetracer' });
  await dap('launch', { traceFolder: 'trace' });
  await dap('configurationDone', {});
  return { w, dap };
}

async function answered(dap, command, args) {
  try {
    return await dap(command, args, ANSWER_MS);
  } catch (e) {
    return { unanswered: String(e) };
  }
}

console.log('=== the wasm32 engine answers every request, including one that panics ===');
console.log('trace:', TRACE, '\n');

// --- 1: an id that names nothing is refused by name, without a panic -------
{
  const { w, dap } = await session(null);
  const before = await answered(dap, 'stackTrace', { threadId: 1 });
  check(before.success === true, `unarmed: stackTrace succeeds (${before.message || before.unanswered || ''})`);
  const r = await answered(dap, 'scopes', { frameId: UNKNOWN_FRAME_ID });
  const message = r.message || '';
  check(r.success === false && message.includes(`no frame has frameId ${UNKNOWN_FRAME_ID}`) && !message.includes('panicked'),
    `unarmed: scopes with an unknown frameId is refused by name (${message || r.unanswered})`);
  const after = await answered(dap, 'stackTrace', { threadId: 1 });
  check(after.success === true && JSON.stringify(after.body) === JSON.stringify(before.body),
    `unarmed: stackTrace answers after the refusal as before (${after.message || after.unanswered || ''})`);
  await w.terminate();
}

// --- 2: a handler panic is answered, and so is everything after it ---------
{
  const { w, dap } = await session('scopes');
  const before = await answered(dap, 'stackTrace', { threadId: 1 });
  check(before.success === true, `armed: stackTrace succeeds before the panic (${before.message || before.unanswered || ''})`);
  const r = await answered(dap, 'scopes', { frameId: 0 });
  const message = r.message || '';
  check(r.success === false && r.command === 'scopes' && message.includes('panicked')
      && message.includes(`seq ${r.seq}`),
    `armed: the panicking scopes is answered naming the command, seq and panic (${message || r.unanswered})`);
  for (const [command, args] of [['stackTrace', { threadId: 1 }], ['threads', {}]]) {
    const later = await answered(dap, command, args);
    const text = later.message || '';
    check(later.success === false && later.command === command && text.includes('panicked')
        && text.includes('stopped'),
      `armed: ${command} after the panic is refused, saying the engine stopped (${text || later.unanswered})`);
  }
  await w.terminate();
}

if (failures.length > 0) {
  console.log(`\n${failures.length} check(s) failed`);
  process.exit(1);
}
console.log('\nall checks hold');
process.exit(0);
