// probe_seekable_container.mjs — drive the REAL wasm32 db-backend engine over a
// REAL new-format (split-stream, seekable) `.ct` container.
//
// This is M0's runtime evidence for `test_browser_opens_new_format_container`.
// The Rust suite `tests/browser_seekable_container_test.rs` proves the reader
// on the host; this proves the same container opens and navigates *in the
// engine that actually ships to a browser tab*, where `CTFSTraceReader::open`
// does not exist (no filesystem, no Nim FFI) and `from_bytes` is the only way
// in.
//
// Before M0 every check below failed at `launch`: `setup_from_vfs` reached
// `CTFSTraceReader::from_bytes`, which returned
//   "CTFS new format (nim-reader) is not supported via from_bytes;
//    only old-format containers can be loaded from in-memory data".
//
// ## No skip path
//
// Exits non-zero, naming what is missing, if the engine or the container is
// absent, and exits non-zero if any check fails. Nothing here can go green
// because its subject is absent.
//
// Usage:
//   node probe_seekable_container.mjs <seekable.ct>

import { Worker } from 'node:worker_threads';
import { readFile, stat } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));
const HOST = path.join(here, 'worker_host.mjs');
const PKG = path.join(here, '..', 'pkg', 'db_backend_bg.wasm');
const TRACE = process.argv[2];

function fail(what) {
  console.error(`FAIL: ${what}`);
  process.exit(1);
}

if (!TRACE) fail('usage: probe_seekable_container.mjs <seekable.ct>');

for (const [label, file] of [
  ['the wasm engine', PKG],
  ['the seekable container', TRACE],
]) {
  try {
    const s = await stat(file);
    if (!s.isFile() || s.size === 0) fail(`${label} at ${file} is empty`);
  } catch {
    fail(`missing required input: ${label} at ${file}
  (build the engine with src/db-backend/build_wasm.sh; produce the container with
   cargo run --example write_seekable_fixture -- <out.ct>)`);
  }
}

const traceBytes = new Uint8Array(await readFile(TRACE));
if (!(traceBytes[0] === 0xc0 && traceBytes[1] === 0xde && traceBytes[2] === 0x72)) {
  fail(`${TRACE} is not a CTFS container (bad magic)`);
}

async function session() {
  const w = new Worker(HOST);
  const inbox = [];
  const waiters = [];
  // A wasm trap kills the isolate without ever reaching the worker's own error
  // handler, so the ONLY place it surfaces is the Worker's 'error'/'exit'
  // events. Without these a trap is indistinguishable from a slow engine.
  w.on('error', (err) => {
    console.error(`  worker error: ${err && err.stack ? err.stack : err}`);
  });
  w.on('exit', (code) => {
    if (code !== 0) console.error(`  worker exited with code ${code}`);
  });
  w.on('message', (raw) => {
    let m = raw;
    if (typeof raw === 'string' && (raw[0] === '{' || raw[0] === '[')) {
      try {
        m = JSON.parse(raw);
      } catch {
        m = raw;
      }
    }
    inbox.push(m);
    for (let i = waiters.length - 1; i >= 0; i -= 1) {
      if (waiters[i].pred(m)) {
        waiters[i].resolve(m);
        waiters.splice(i, 1);
      }
    }
  });
  const waitFor = (pred, ms, label) =>
    new Promise((res, rej) => {
      const hit = inbox.find(pred);
      if (hit) return res(hit);
      const t = setTimeout(() => rej(new Error(`timeout: ${label}`)), ms);
      waiters.push({
        pred,
        resolve: (m) => {
          clearTimeout(t);
          res(m);
        },
      });
    });
  let seq = 0;
  const dap = (command, args = {}, ms = 30000) => {
    seq += 1;
    const s = seq;
    w.postMessage({ seq: s, type: 'request', command, arguments: args });
    return waitFor((m) => m && m.type === 'response' && m.request_seq === s, ms, command);
  };

  await waitFor((m) => m && m.type === 'wasm-loaded', 120000, 'wasm-loaded');
  w.postMessage({ type: 'vfs-write', path: 'trace/trace.ct', data: traceBytes });
  await waitFor((m) => m && m.type === 'vfs-ack', 30000, 'vfs-ack');
  w.postMessage({ type: 'start' });
  await waitFor((m) => m === 'ready', 60000, 'ready');
  return { w, dap, inbox };
}

const results = [];
function check(name, ok, detail) {
  results.push({ name, ok, detail });
  console.log(`  ${ok ? 'PASS' : 'FAIL'}  ${name}${detail ? ` — ${detail}` : ''}`);
}

console.log('=== M0: a seekable split-stream container in the real wasm32 engine ===');
console.log(`  engine: ${PKG}`);
console.log(`  trace:  ${TRACE} (${traceBytes.length} bytes)\n`);

const { w, dap, inbox } = await session();
const inboxTail = () =>
  inbox.slice(-6).map((m) => {
    const text = typeof m === 'string' ? m : JSON.stringify(m);
    return text.length > 300 ? `${text.slice(0, 300)}...` : text;
  });

try {
  // 1. The handshake. `launch` is where the old constructor refused the
  //    container outright.
  const init = await dap('initialize', { clientID: 'm0-probe', adapterID: 'codetracer' });
  check('initialize', init.success === true, init.message || '');

  const launch = await dap('launch', { traceFolder: 'trace' });
  check(
    'launch opens the NEW-FORMAT container',
    launch.success === true,
    launch.message || launch.body?.error || '',
  );

  const t0 = process.hrtime.bigint();
  const configured = await dap('configurationDone', {}, 300000);
  const setupMs = Number(process.hrtime.bigint() - t0) / 1e6;
  console.log(`  (configurationDone took ${setupMs.toFixed(1)} ms)`);
  check('configurationDone', configured.success === true, configured.message || '');

  // 2. The engine has a live session over it.
  const threads = await dap('threads', {});
  const threadCount = threads.body?.threads?.length ?? 0;
  check('threads', threads.success === true && threadCount > 0, `${threadCount} thread(s)`);

  const stack = await dap('stackTrace', { threadId: 1 });
  const frames = stack.body?.stackFrames ?? [];
  check(
    'stackTrace over the seekable step stream',
    stack.success === true && frames.length > 0,
    frames.length ? `top frame ${frames[0].name}:${frames[0].line}` : 'no frames',
  );
  const startLine = frames[0]?.line;

  // 3. Navigation. Forward, then reverse — each of these is a point lookup
  //    into `steps.dat` served through the wasm32 seekable stream source that
  //    used to be a stub returning None.
  let moved = 0;
  for (let i = 0; i < 8; i += 1) {
    const next = await dap('next', { threadId: 1 });
    if (next.success !== true) break;
    moved += 1;
  }
  check('8 x step-over on the seekable stream', moved === 8, `${moved}/8 succeeded`);

  const afterForward = await dap('stackTrace', { threadId: 1 });
  const forwardLine = afterForward.body?.stackFrames?.[0]?.line;
  check(
    'stepping actually moved',
    typeof forwardLine === 'number' && forwardLine !== startLine,
    `line ${startLine} -> ${forwardLine}`,
  );

  let back = 0;
  for (let i = 0; i < 4; i += 1) {
    const prev = await dap('stepBack', { threadId: 1 });
    if (prev.success !== true) break;
    back += 1;
  }
  check('4 x reverse step on the seekable stream', back === 4, `${back}/4 succeeded`);

  // 4. Locals — served from the seekable `values.dat` stream, which was also a
  //    stub on wasm32 (`variables_at` returned None).
  const locals = await dap('ct/load-locals', {
    rrTicks: 0,
    countBudget: 100,
    minCountLimit: 10,
    depthLimit: 3,
    watchExpressions: [],
    lang: 0,
  });
  check('ct/load-locals over the seekable value stream', locals.success === true, locals.message || '');

  // 5. Teardown answers (the M0 deliverable fixed on 2026-08-29 — asserted here
  //    against the new-format path too, not only the legacy one).
  const bye = await dap('disconnect', {}, 10000);
  check('disconnect answers', bye.success === true, bye.message || '');
} catch (e) {
  check('probe ran to completion', false, String(e && e.message ? e.message : e));
  // A timeout usually means the worker trapped rather than that the engine was
  // slow, and the difference matters. Dump what the worker did say, so the
  // failure names a cause instead of just a deadline.
  const tail = inboxTail();
  if (tail.length) {
    console.error('  last messages from the worker:');
    for (const m of tail) console.error(`    ${m}`);
  } else {
    console.error('  the worker sent nothing further — it trapped or died silently');
  }
} finally {
  await w.terminate();
}

const failed = results.filter((r) => !r.ok);
console.log(`\n${results.length - failed.length}/${results.length} checks passed`);
if (failed.length) {
  console.error(`FAIL: ${failed.length} check(s) failed: ${failed.map((f) => f.name).join(', ')}`);
  process.exit(1);
}
console.log('=== seekable container OK in the real wasm32 engine ===');
