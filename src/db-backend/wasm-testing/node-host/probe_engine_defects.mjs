// probe_engine_defects.mjs — reproducers for four defects in the wasm32 build
// of db-backend, found by driving it from WorkerBackendService.
//
// D1-D3 share one root cause: `SystemTime::now()` is unimplemented on
// `wasm32-unknown-unknown` and panics, which compiles to an `unreachable`
// trap that kills the whole worker. `src/db-backend/src/vfs.rs` documents
// this hazard in its header and works around it for the VFS only; these
// paths were not covered. D4 is the same *shape* — an API that does not
// exist on wasm32 — but reached through `thread::sleep`.
//
//   D1  ct/load-locals — traps immediately, so the State pane cannot work
//       at all in the browser. The chain is the ORIGIN-SUMMARY one, not the
//       value-history one:
//         dap_server.rs:2068       -> Handler::load_locals
//         dap_handler.rs:978       -> build_origin_summary_for_local
//                                     (guarded by `trace_kind == Materialized`,
//                                      which the browser path always is —
//                                      dap_server.rs:1589)
//         dap_handler.rs:3421/3429 -> materialized_origin_chain
//         dap_handler.rs:2997      -> Db::origin_chain_inferred_with_metadata
//         db.rs:2915               -> WallClockDeadline::new
//         origin_query.rs:260      -> SystemTime::now()
//       NB `HistoryResult::new` (task.rs:1416) has the same hazardous body
//       but is DEAD CODE — zero callers in the crate — and `db.rs:2519` is
//       `load_history`, i.e. `ct/load-history`, a different command. An
//       earlier revision of this comment blamed both; neither is on the
//       `ct/load-locals` path.
//
//   D2  a step that reaches a trace boundary — traps. dap_handler.rs:2096
//       picks "beginning"/"end" and :2097 calls send_notification, which
//       builds a Notification (dap_handler.rs:5451 -> src/task.rs:1960).
//       Reverse stepping *mid-trace* is fine; only the boundary traps.
//       Blast radius is wider than this one call: `send_notification` has 13
//       call sites in dap_handler.rs, including "No breakpoints were hit!"
//       (:3734) and "can't jump to line" (:3829), so each of those traps too.
//
//   D3  ct/originChain — traps. Value-Origin-Tracking's query surface;
//       origin_query.rs:260/266 call SystemTime::now(). Same funnel as D1.
//
//   D4  disconnect — traps, and this one is newly REACHABLE rather than
//       merely latent, because `WorkerBackend.disconnect` sends a DAP
//       `disconnect` on every session teardown. The browser arm
//       (dap_server.rs:2779) delegates to the native one, which at
//       dap_server.rs:2609-2614 busy-waits on `ctx.disconnect_response_written`
//       — an AtomicBool set ONLY at dap_server.rs:3184, inside the native
//       `handle_client` sending thread, which does not exist in the browser.
//       So the loop never exits and `thread::sleep` (dap_server.rs:2613)
//       traps: `library/std/src/sys/thread/unsupported.rs:45`. This is the
//       defect BlockTracer.milestones.org M0 lists last and calls "Latent —
//       no test sends `disconnect`". It is no longer latent.
//
// Usage: node probe_engine_defects.mjs <trace.ct>
import { Worker } from 'node:worker_threads';
import { readFile } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));
const HOST = path.join(here, 'worker_host.mjs');
const TRACE = process.argv[2];

async function session() {
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
  const dap = async (command, args = {}, ms = 20000) => {
    const s = ++seq;
    w.postMessage({ seq: s, type: 'request', command, arguments: args });
    return waitFor((m) => m && m.type === 'response' && m.request_seq === s, ms, command);
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

console.log('=== db-backend wasm32 engine defects ===');
console.log('trace:', TRACE, '\n');

// --- D1: ct/load-locals ----------------------------------------------------
{
  const { w, dap } = await session();
  // Exactly what ReplayDataStore.requestLocals sends
  // (src/frontend/viewmodel/store/replay_data_store.nim:656-663).
  const args = {
    rrTicks: 0, countBudget: 100, minCountLimit: 10,
    depthLimit: 3, watchExpressions: [], lang: 0,
  };
  try {
    const r = await dap('ct/load-locals', args, 8000);
    console.log(`D1 ct/load-locals: responded success=${r.success} message=${r.message || ''}`);
  } catch (e) {
    console.log('D1 ct/load-locals: WORKER TRAPPED — no response ever arrives');
  }
  await w.terminate();
}

// --- D2: stepping to the trace boundary ------------------------------------
{
  const { w, dap } = await session();
  const line = async () => {
    const st = await dap('stackTrace', { threadId: 1 });
    const f = st.body && st.body.stackFrames && st.body.stackFrames[0];
    return f ? f.line : null;
  };
  console.log(`\nD2 entry line: ${await line()}`);
  await dap('next', { threadId: 1 });
  console.log(`D2 after one next: line ${await line()}`);
  // One reverse step from here walks back past the start of the trace.
  try {
    const r = await dap('stepBack', { threadId: 1 }, 8000);
    console.log(`D2 stepBack to boundary: responded success=${r.success} message=${r.message || ''}`);
  } catch (e) {
    console.log('D2 stepBack to boundary: WORKER TRAPPED — no response ever arrives');
  }
  await w.terminate();
}

// --- D3: ct/originChain ----------------------------------------------------
{
  const { w, dap } = await session();
  const st = await dap('stackTrace', { threadId: 1 });
  const f = st.body.stackFrames[0];
  const location = {
    path: f.source.path, line: f.line, rrTicks: 0,
    functionName: f.name, key: '', globalCallKey: '', callstackDepth: 0,
  };
  try {
    const r = await dap('ct/originChain', { variableName: 'root', stepId: 0, location }, 8000);
    console.log(`\nD3 ct/originChain: responded success=${r.success} message=${r.message || ''}`);
  } catch (e) {
    console.log('\nD3 ct/originChain: WORKER TRAPPED — no response ever arrives');
  }
  await w.terminate();
}

// --- D4: disconnect --------------------------------------------------------
// Sent as a real DAP request and awaited, WITHOUT terminating the worker
// first. `WorkerBackend.disconnect` terminates immediately after posting, so
// the adapter masks this trap in normal use; the engine defect is still real.
{
  const { w, dap } = await session();
  const before = await dap('threads', {});
  console.log(`\nD4 pre-disconnect threads: success=${before.success}`);
  try {
    const r = await dap('disconnect', {}, 8000);
    console.log(`D4 disconnect: responded success=${r.success} message=${r.message || ''}`);
  } catch (e) {
    console.log('D4 disconnect: WORKER TRAPPED — no response ever arrives');
  }
  await w.terminate();
}

console.log('\nD1-D3 print "time not implemented on this platform" above, from');
console.log('library/std/src/sys/time/unsupported.rs. D4 prints an operation-not-');
console.log('supported panic from library/std/src/sys/thread/unsupported.rs:45.');
process.exit(0);
