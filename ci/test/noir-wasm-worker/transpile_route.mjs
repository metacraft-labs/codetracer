// transpile_route.mjs — drive `wasm_worker_browser.js` ITSELF over its own protocol.
//
// The other file in this directory (`worker.mjs`) is a Node TWIN of the browser worker, kept
// message-for-message identical minus `fetch` and `parentPort`. A twin cannot answer the
// question this file asks — *does the shipped worker route `transpile`?* — because a twin is a
// second implementation and routing is exactly what would differ between them.
//
// So this loads THE SHIPPED FILE, supplying only the two globals a browser would
// (`self` and `fetch`), and speaks the real protocol at it: `configure`, then `start` with
// `args: ['compile']`, then `start` with `args: ['transpile']` carrying the artifact the first
// run returned.
//
// WHAT WOULD MAKE THIS PASS VACUOUSLY, and what stops it. A worker that answered `exit 0` over
// an empty string would satisfy "the run completed". So the transpiled artifact is parsed, its
// functions counted, and its bytecode compared against the COMPILED artifact's — the same
// anti-passthrough assertion the page arm makes, here at the protocol boundary.

import { readFileSync } from 'node:fs';
import { pathToFileURL } from 'node:url';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
const repoRoot = resolve(here, '..', '..', '..');
const workerPath = join(repoRoot, 'src', 'frontend', 'viewmodel', 'host',
  'wasm_worker_browser.js');

const compiler = process.env.CT_NOIR_WASM_COMPILER;
const transpiler = process.env.CT_AVM_TRANSPILER_WASM;
const vfsPath = process.env.CT_JOIN_VFS;
for (const [name, value] of [['CT_NOIR_WASM_COMPILER', compiler],
  ['CT_AVM_TRANSPILER_WASM', transpiler], ['CT_JOIN_VFS', vfsPath]]) {
  if (!value) { console.error(`SKIP: ${name} is not set. This is a skip, not a pass.`); process.exit(2); }
}

// ---- the two globals the worker expects ------------------------------------------------
const outbox = [];
const listeners = [];
globalThis.self = {
  set onmessage(fn) { listeners.push(fn); },
  postMessage: (text) => outbox.push(JSON.parse(String(text))),
};
// A `fetch` that answers from disk, with the header the worker's own classifier reads. The
// module-fault path this worker carries (NOT_SERVED / BROKEN) is about a deployment, not about
// this check, so the good case is what is served here.
globalThis.fetch = async (url) => {
  const path = String(url).startsWith('file://') ? fileURLToPath(url) : String(url);
  const bytes = readFileSync(path);
  return {
    ok: true,
    headers: { get: (h) => (h.toLowerCase() === 'content-type' ? 'application/wasm' : null) },
    arrayBuffer: async () => bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.length),
    clone() { return this; },
  };
};

await import(pathToFileURL(workerPath).href);
const onmessage = listeners[listeners.length - 1];
if (typeof onmessage !== 'function') {
  console.error('the worker did not install an onmessage handler');
  process.exit(1);
}

const send = async (request) => {
  const before = outbox.length;
  await onmessage({ data: JSON.stringify(request) });
  return outbox.slice(before);
};
const settle = async (request) => {
  // The worker's one-shot chain posts `output` then `exit` synchronously within the awaited
  // handler, so draining after the await is enough. A `failed` is returned as-is and asserted on.
  const messages = await send(request);
  const out = messages.filter((m) => m.kind === 'output').map((m) => m.text).join('');
  const exit = messages.find((m) => m.kind === 'exit');
  const failed = messages.find((m) => m.kind === 'failed');
  return { out, exit, failed, messages };
};

let failures = 0;
const ok = (m) => console.log(`  [OK]     ${m}`);
const bad = (m) => { console.log(`  [FAILED] ${m}`); failures++; };

console.log('=== the shipped browser worker routes `transpile` ===');

await settle({ seq: 1, kind: 'configure', moduleUrls: {
  'noir-compiler': compiler, 'avm-transpiler': transpiler } });

const files = JSON.parse(readFileSync(vfsPath, 'utf8'));
const compileRun = await settle({
  seq: 2, kind: 'start', module: 'noir', command: 'nargo', args: ['compile'], workingDir: '',
  stdin: JSON.stringify({ files, package_dir: process.env.CT_JOIN_PACKAGE_DIR || 'contract',
    mode: 'contract' }),
});
if (compileRun.failed) { bad(`compile failed: ${compileRun.failed.message}`); process.exit(1); }
const compiled = JSON.parse(compileRun.out);
if (compiled.ok) ok(`compile ran through the worker: ${compiled.artifact.name}, ` +
  `${compiled.artifact.functions.length} functions`);
else bad(`the worker's compile refused: ${compiled.message}`);

// ---- the route this file exists for ----------------------------------------------------
const transpileRun = await settle({
  seq: 3, kind: 'start', module: 'noir', command: 'avm-transpiler', args: ['transpile'],
  workingDir: '', stdin: JSON.stringify({ artifact: compiled.artifact }),
});
if (transpileRun.failed) {
  bad(`the worker refused to route transpile: ${transpileRun.failed.message}`);
} else if (!transpileRun.exit || transpileRun.exit.exitCode !== 0) {
  bad(`transpile exited ${transpileRun.exit && transpileRun.exit.exitCode}`);
} else {
  ok('the worker routed `transpile` and exited 0');
  const transpiled = JSON.parse(transpileRun.out);
  const before = new Map(compiled.artifact.functions.map((f) => [f.name, f.bytecode]));
  const changed = (transpiled.functions || [])
    .filter((f) => before.has(f.name) && before.get(f.name) !== f.bytecode);
  if (transpiled.functions.length === compiled.artifact.functions.length) {
    ok(`and returned ${transpiled.functions.length} functions, the same count`);
  } else {
    bad(`the function count moved ${compiled.artifact.functions.length} -> ` +
        `${transpiled.functions.length}`);
  }
  // THE ANTI-PASSTHROUGH ASSERTION, at the protocol boundary.
  if (changed.length > 0) ok(`and ${changed.length} functions' bytecode CHANGED, so the ` +
    `worker ran a transpile rather than echoing its input`);
  else bad('NO bytecode changed — the route returned its input');
}

// ---- an unrouted subcommand is still refused BY NAME ------------------------------------
// Without this, "the worker routes transpile" is consistent with a worker that routes anything.
const bogus = await settle({
  seq: 4, kind: 'start', module: 'noir', command: 'nargo', args: ['fmt'], workingDir: '',
  stdin: '{}',
});
if (bogus.failed && bogus.failed.message.includes('fmt')) {
  ok('an unrouted subcommand is still refused by name');
} else {
  bad(`an unrouted subcommand was not refused by name: ${JSON.stringify(bogus.messages)}`);
}

console.log(failures === 0
  ? '\nRESULT: OK — the shipped worker compiles and transpiles over its own protocol'
  : `\nRESULT: FAILED — ${failures} check(s)`);
process.exit(failures === 0 ? 0 : 1);
