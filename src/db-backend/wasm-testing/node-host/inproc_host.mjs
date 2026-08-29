// inproc_host.mjs — run the REAL `wasm-testing/worker.js` **in the calling
// process**, with `postMessage` wired to a direct in-process callback instead
// of a `worker_threads` port.
//
// ## Why this exists
//
// M0's last deliverable asks whether replacing the JSON `postMessage` hop
// between the front-end and the WASM engine with a direct FFI call is worth
// doing, and says to *profile before committing to it*. This module is the
// control arm of that measurement.
//
// It is byte-for-byte the same engine, the same `worker.js`, and the same
// `dap.rs` JSON encode/decode as the worker path. The ONE thing it removes is
// the worker boundary itself: no `worker_threads` thread, no structured clone,
// no event-loop hop between two threads. `postMessage` from Rust lands in a
// plain JS function call in the same isolate.
//
// So `worker round-trip − in-process round-trip` is exactly the cost of the
// thread hop and the structured clone — the part of "replace postMessage with
// a direct FFI call" that is actually about the transport. The remaining JSON
// cost (`JSON.stringify` at dap.rs, the double `serde_json` deserialize, and
// `serde_json::to_string` on the way out) is present in BOTH arms and is
// measured separately by the benchmark.
//
// ## This is a MEASUREMENT harness, not a proposed architecture
//
// Running the engine in the calling isolate is precisely what the worker exists
// to avoid: replay would run on the browser's main thread and block the UI.
// Making a direct FFI seam non-blocking requires `SharedArrayBuffer` +
// `Atomics`, which requires cross-origin isolation (COOP/COEP) — a hard ask for
// an SDK embedded in third-party sites. Nothing here should be read as
// endorsing that trade; it exists to put a number on what the trade would buy.
//
// Usage:
//   const { dap, close } = await startInProcessEngine({ wasmDir, tracePath });

import { readFile } from 'node:fs/promises';
import { fileURLToPath, pathToFileURL } from 'node:url';
import path from 'node:path';

/// Install the browser globals `worker.js` and the Rust side need, wired to
/// `onOutbound` instead of a worker port.
function installGlobals(onOutbound) {
  class DedicatedWorkerGlobalScope {
    static [Symbol.hasInstance](value) {
      return value === globalThis;
    }
  }
  globalThis.DedicatedWorkerGlobalScope = DedicatedWorkerGlobalScope;
  globalThis.self = globalThis;

  // The whole point: a direct call, not a port post.
  globalThis.postMessage = (msg) => onOutbound(msg);

  let currentOnMessage = null;
  Object.defineProperty(globalThis, 'onmessage', {
    configurable: true,
    get: () => currentOnMessage,
    set: (fn) => {
      currentOnMessage = fn;
    },
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

  const nodeFetch = globalThis.fetch;
  globalThis.fetch = async (input, init) => {
    const url = typeof input === 'string' ? input : (input && input.url) || String(input);
    if (url.startsWith('file:')) {
      const bytes = await readFile(fileURLToPath(url));
      return new Response(bytes, { status: 200, headers: { 'content-type': 'application/wasm' } });
    }
    return nodeFetch(input, init);
  };

  return {
    deliver(data) {
      const event = { data };
      for (const fn of listeners.message) fn(event);
      if (currentOnMessage) currentOnMessage(event);
    },
  };
}

/// Boot the engine in-process and return a DAP driver over it.
export async function startInProcessEngine({ workerUrl, tracePath, traceVfsPath = 'trace' }) {
  const inbox = [];
  const waiters = [];

  const dispatch = (msg) => {
    const parsed = typeof msg === 'string' && (msg[0] === '{' || msg[0] === '[') ? JSON.parse(msg) : msg;
    inbox.push({ raw: msg, parsed });
    for (let i = waiters.length - 1; i >= 0; i -= 1) {
      const w = waiters[i];
      const hit = inbox.find(w.pred);
      if (hit) {
        waiters.splice(i, 1);
        w.resolve(hit);
      }
    }
  };

  const host = installGlobals(dispatch);
  await import(workerUrl);

  const waitFor = (pred, what, timeoutMs = 60_000) =>
    new Promise((resolve, reject) => {
      const hit = inbox.find(pred);
      if (hit) {
        resolve(hit);
        return;
      }
      const timer = setTimeout(() => reject(new Error(`timed out waiting for ${what}`)), timeoutMs);
      waiters.push({
        pred,
        resolve: (v) => {
          clearTimeout(timer);
          resolve(v);
        },
      });
    });

  await waitFor((m) => m.parsed && m.parsed.type === 'wasm-loaded', 'wasm-loaded');

  const bytes = await readFile(tracePath);
  host.deliver({ type: 'vfs-write', path: traceVfsPath, data: new Uint8Array(bytes) });
  await waitFor((m) => m.parsed && m.parsed.type === 'vfs-ack', 'vfs-ack');

  host.deliver({ type: 'start' });
  await waitFor((m) => m.raw === 'ready', 'ready');

  let seq = 0;
  const dap = (command, args = {}) => {
    seq += 1;
    const mySeq = seq;
    const request = { seq: mySeq, type: 'request', command, arguments: args };
    // The worker path structured-clones an object; this path hands the same
    // object straight in. Both reach `dap.rs`'s `JSON.stringify(event.data)`
    // identically, so the JSON cost is shared and only the hop differs.
    const settled = waitFor(
      (m) => m.parsed && m.parsed.type === 'response' && m.parsed.request_seq === mySeq,
      `response to ${command}`,
    );
    host.deliver(request);
    return settled;
  };

  return {
    dap,
    inbox,
    close() {
      /* nothing to tear down: the engine lives in this isolate */
    },
  };
}

/// Resolve `wasm-testing/worker.js` as a module URL from this file's location.
export function defaultWorkerUrl() {
  const here = path.dirname(fileURLToPath(import.meta.url));
  return pathToFileURL(path.join(here, '..', 'worker.js')).href;
}
