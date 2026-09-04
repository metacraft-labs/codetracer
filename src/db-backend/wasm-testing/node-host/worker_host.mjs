// worker_host.mjs — run the REAL `wasm-testing/worker.js` inside a Node
// `worker_threads` worker.
//
// This file supplies only the browser globals Node lacks. It does not
// reimplement any part of the worker or the WASM engine:
//
//   * `self` / `postMessage` / `addEventListener` — mapped onto `parentPort`.
//   * `DedicatedWorkerGlobalScope` — the Rust side does
//     `js_sys::global().dyn_into::<DedicatedWorkerGlobalScope>()`
//     (src/db-backend/src/lib.rs:293, src/transport.rs:57). Node has no such
//     constructor, so `dyn_into` would fail and `wasm_start()` would return
//     "Not running inside a DedicatedWorkerGlobalScope". A `Symbol.hasInstance`
//     shim makes the `instanceof` check true for the global object without
//     touching Node's prototype chain.
//   * `fetch` for `file:` URLs — the browser fetches the `.wasm` and any
//     `load-trace` files over HTTP; Node's `fetch` rejects `file:`. Reading
//     from disk and returning a real `Response` keeps `worker.js` unmodified.
//
// Everything below `import('../worker.js')` is the production artifact.

import { parentPort } from 'node:worker_threads';
import { readFile } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';

if (!parentPort) {
  throw new Error('worker_host.mjs must be run as a worker_threads Worker');
}

// --- optional log silencing (opt-in; off by default) -----------------------
//
// `wasm_logger` is initialised at `Config::default()`, so the engine emits a
// `console.log` per DAP request and several per navigation. Those lines are
// exactly what a probe wants to read — and exactly what a BENCHMARK must not
// measure. In a `worker_threads` worker, `console.log` writes to the parent's
// stdout through a cross-thread stream, so the logging is charged to the worker
// arm and not to an in-process one: leaving it on makes the transport look
// expensive for a reason that has nothing to do with the transport.
//
// Opt-in, so every existing probe keeps its diagnostics unchanged.
if (process.env.CT_SILENCE_ENGINE_LOG === '1') {
  const noop = () => {};
  console.log = noop;
  console.debug = noop;
  console.info = noop;
  console.warn = noop;
  console.error = noop;
}

// --- DedicatedWorkerGlobalScope -------------------------------------------
class DedicatedWorkerGlobalScope {
  static [Symbol.hasInstance](value) {
    return value === globalThis;
  }
}
globalThis.DedicatedWorkerGlobalScope = DedicatedWorkerGlobalScope;

// --- self / postMessage / onmessage ---------------------------------------
globalThis.self = globalThis;

globalThis.postMessage = (msg) => parentPort.postMessage(msg);

// `self.onmessage = fn` is assigned twice: once by worker.js's bootstrap
// handler and once by `wasm_start()` from Rust. The setter forwards to
// whichever handler is currently installed, so the hand-off works exactly as
// it does in a browser.
let currentOnMessage = null;
Object.defineProperty(globalThis, 'onmessage', {
  configurable: true,
  get: () => currentOnMessage,
  set: (fn) => { currentOnMessage = fn; },
});

const listeners = { error: [], unhandledrejection: [], message: [] };
globalThis.addEventListener = (type, fn) => {
  if (!listeners[type]) listeners[type] = [];
  listeners[type].push(fn);
};
globalThis.removeEventListener = (type, fn) => {
  if (!listeners[type]) return;
  const i = listeners[type].indexOf(fn);
  if (i >= 0) listeners[type].splice(i, 1);
};

parentPort.on('message', (data) => {
  const event = { data };
  for (const fn of listeners.message) {
    try { fn(event); } catch (err) { reportError(err); }
  }
  if (currentOnMessage) {
    try {
      const r = currentOnMessage(event);
      if (r && typeof r.catch === 'function') r.catch(reportError);
    } catch (err) {
      reportError(err);
    }
  }
});

function reportError(err) {
  const message = err instanceof Error ? `${err.name}: ${err.message}` : String(err);
  for (const fn of listeners.error) {
    try { fn({ message, error: err, filename: '', lineno: 0, colno: 0 }); } catch (_) { /* ignore */ }
  }
  parentPort.postMessage({ type: 'worker-error', error: message });
}

process.on('uncaughtException', reportError);
process.on('unhandledRejection', (reason) => {
  for (const fn of listeners.unhandledrejection) {
    try { fn({ reason }); } catch (_) { /* ignore */ }
  }
  reportError(reason);
});

// --- fetch() over file: ----------------------------------------------------
const nodeFetch = globalThis.fetch;
globalThis.fetch = async (input, init) => {
  const url = typeof input === 'string' ? input : (input && input.url) || String(input);
  if (url.startsWith('file:')) {
    try {
      const bytes = await readFile(fileURLToPath(url));
      return new Response(bytes, {
        status: 200,
        headers: { 'content-type': 'application/wasm' },
      });
    } catch (err) {
      return new Response(null, { status: 404, statusText: String(err) });
    }
  }
  return nodeFetch(input, init);
};

// --- the real worker -------------------------------------------------------
await import('../worker.js');
