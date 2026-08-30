// probe_reverse.mjs — is reverse stepping always broken on wasm32, or only
// when a step reaches a trace boundary and the engine tries to notify?
import { Worker } from 'node:worker_threads';
import { readFile } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));
const HOST = path.join(here, 'worker_host.mjs');
const TRACE = process.argv[2];
const FORWARD = parseInt(process.argv[3] || '1', 10);

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
  return waitFor((m) => m && m.type === 'response' && m.request_seq === s, ms, command);
}
async function line() {
  const st = await dap('stackTrace', { threadId: 1 });
  const f = st.body && st.body.stackFrames && st.body.stackFrames[0];
  return f ? f.line : null;
}

await waitFor((m) => m && m.type === 'wasm-loaded', 60000, 'wasm-loaded');
w.postMessage({ type: 'vfs-write', path: 'trace/trace.ct', data: new Uint8Array(await readFile(TRACE)) });
await waitFor((m) => m && m.type === 'vfs-ack', 20000, 'vfs-ack');
w.postMessage({ type: 'start' });
await waitFor((m) => m === 'ready', 30000, 'ready');

await dap('initialize', { clientID: 'probe', adapterID: 'codetracer' });
await dap('launch', { traceFolder: 'trace' });
await dap('configurationDone', {});

console.log(`trace: ${path.basename(TRACE)}  forward steps before reversing: ${FORWARD}`);
console.log('  entry line:', await line());
for (let i = 0; i < FORWARD; i++) {
  const r = await dap('next', { threadId: 1 });
  console.log(`  next #${i + 1}: success=${r.success} -> line ${await line()}`);
}
try {
  const r = await dap('stepBack', { threadId: 1 }, 8000);
  console.log(`  stepBack: success=${r.success} msg=${r.message || ''} -> line ${await line()}`);
} catch (e) {
  console.log('  stepBack: WORKER TRAPPED —', e.message);
}
await w.terminate();
process.exit(0);
