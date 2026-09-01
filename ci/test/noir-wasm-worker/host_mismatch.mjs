// host_mismatch.mjs — a module this worker cannot host says so, and does not say BROKEN.
//
// THE DEFECT THIS PINS. `load` satisfied every declared import with a throwing FUNCTION. An
// import that is not a function — `avm.wasm` imports its own linear memory as `env.memory` —
// cannot be satisfied that way, so instantiation failed at LINK time and the `catch` reported
// `broken`: "was served from <url> as a wasm module and is not a usable one". Every load-bearing
// part of that sentence was false. The module IS usable, it WAS served correctly, and the fault
// is in the host. A reader would have gone to re-examine the module and the deployment — the
// wrong half of the system, which is the exact cost the three-fault rule was written to avoid.
//
// Run:
//   CT_AVM_WASM=<avm.wasm> CT_NOIR_WASM_COMPILER=<noir_wasm.wasm> node host_mismatch.mjs
//
// HOW THE AVM IS REACHED. The loader is not exported, so the classification is asserted through
// the surface the product uses: `configure` declares a module URL by id and a route loads it.
// `avm-transpiler` is pointed at `avm.wasm` for that purpose. The route is irrelevant — what is
// asserted is which fault `load` produced, and it produces it before any route logic runs.
//
// THE CONTROL IS NOT DECORATION. `noir_wasm.wasm` declares 28 function imports that this host
// CAN stub, and it must still load and compile. Without it, "the AVM is refused" is equally
// consistent with a loader that refuses everything.

import { readFileSync } from 'node:fs';
import { pathToFileURL, fileURLToPath } from 'node:url';
import { dirname, resolve } from 'node:path';

const here = dirname(fileURLToPath(import.meta.url));
const workerPath = resolve(here, '..', '..', '..',
  'src', 'frontend', 'viewmodel', 'host', 'wasm_worker_browser.js');

const avm = process.env.CT_AVM_WASM;
const compiler = process.env.CT_NOIR_WASM_COMPILER;
for (const [n, v] of [['CT_AVM_WASM', avm], ['CT_NOIR_WASM_COMPILER', compiler]]) {
  if (!v) { console.error(`SKIP: ${n} is not set. This is a skip, not a pass.`); process.exit(2); }
}

const outbox = [];
const listeners = [];
globalThis.self = {
  set onmessage(fn) { listeners.push(fn); },
  postMessage: (t) => outbox.push(JSON.parse(String(t))),
};
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

const settle = async (request) => {
  const before = outbox.length;
  await onmessage({ data: JSON.stringify(request) });
  const messages = outbox.slice(before);
  return {
    messages,
    failed: messages.find((m) => m.kind === 'failed'),
    out: messages.filter((m) => m.kind === 'output').map((m) => m.text).join(''),
  };
};

let failures = 0;
const ok = (m) => console.log(`  [OK]     ${m}`);
const bad = (m) => { console.log(`  [FAILED] ${m}`); failures++; };

console.log('=== a module the worker cannot host is not called BROKEN ===');

await settle({ seq: 1, kind: 'configure', moduleUrls: {
  'avm-transpiler': avm, 'noir-compiler': compiler } });

const attempt = await settle({
  seq: 2, kind: 'start', module: 'avm', command: 'avm-transpiler', args: ['transpile'],
  workingDir: '', stdin: JSON.stringify({ artifact: {} }),
});

if (!attempt.failed) {
  bad(`loading the AVM produced no failure: ${JSON.stringify(attempt.messages).slice(0, 300)}`);
} else {
  const { fault, message } = attempt.failed;
  if (fault === 'host-mismatch') ok('the fault is `host-mismatch`, not `broken`');
  else bad(`the fault is \`${fault}\` — expected \`host-mismatch\`. Message: ${message}`);

  // Naming the import AND its kind is what makes the message actionable; "it did not link" is
  // not something a reader can do anything with.
  if (message.includes('memory env.memory')) {
    ok('and it names the offending import by KIND: `memory env.memory`');
  } else {
    bad(`the message does not name the import kind: ${message}`);
  }
  if (!/not a usable one|was not published/.test(message)) {
    ok('and it does not claim the module is unusable, nor that it was never published');
  } else {
    bad(`the message still blames the module or the deploy: ${message}`);
  }
}

// ---- CONTROL ----------------------------------------------------------------------------
await settle({ seq: 3, kind: 'configure', moduleUrls: { 'noir-compiler': compiler } });
const control = await settle({
  seq: 4, kind: 'start', module: 'noir', command: 'nargo', args: ['compile'], workingDir: '',
  stdin: JSON.stringify({
    files: {
      'p/Nargo.toml': '[package]\nname = "p"\ntype = "bin"\n',
      'p/src/main.nr': 'fn main(x: Field) -> pub Field { x + 1 }\n',
    },
    package_dir: 'p', mode: 'debug',
  }),
});
if (control.failed) {
  bad(`the CONTROL module failed to load: ${control.failed.fault} ${control.failed.message}`);
} else if (JSON.parse(control.out).ok) {
  ok('CONTROL: a module with only function imports still loads and compiles');
} else {
  bad(`the control compiled but refused: ${control.out.slice(0, 200)}`);
}

console.log(failures === 0
  ? "\nRESULT: OK — an unhostable module is diagnosed as the host's limit, not the module's fault"
  : `\nRESULT: FAILED — ${failures} check(s)`);
process.exit(failures === 0 ? 0 : 1);
