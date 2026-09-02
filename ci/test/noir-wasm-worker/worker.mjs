// The wasm worker's script, in the shape `platform/wasm_worker.nim` speaks to.
//
// It instantiates a Noir wasm module and drives its bare C ABI. There is no
// wasm-bindgen glue: `WebAssembly.instantiate` with every declared import
// stubbed to throw, which is how the modules are built and what makes
// "reached no import" a measurement rather than a hope.
//
// TEXT IN, TEXT OUT. Every message this posts is a JSON string, matching what
// the Nim side's `deliver` accepts. The protocol's own header says why: an
// engine that sent objects one way and strings the other cost a sibling
// campaign a day, and a reader that classified by message type reported a
// timeout over an engine that had answered.
import { readFileSync } from 'node:fs';
import { parentPort, workerData } from 'node:worker_threads';

const post = (message) => parentPort.postMessage(JSON.stringify(message));

const stubImports = (mod) => {
  const imports = {};
  for (const { module: m, name } of WebAssembly.Module.imports(mod)) {
    imports[m] ??= {};
    imports[m][name] = () => { throw new Error(`reached ${m}.${name}`); };
  }
  return imports;
};

const modules = new Map();
async function load(id, path) {
  if (modules.has(id)) return modules.get(id);
  const mod = await WebAssembly.compile(readFileSync(path));
  const { exports } = await WebAssembly.instantiate(mod, stubImports(mod));
  modules.set(id, exports);
  return exports;
}

function put(exports, alloc, str) {
  const bytes = new TextEncoder().encode(str);
  const ptr = exports[alloc](bytes.length);
  new Uint8Array(exports.memory.buffer, ptr, bytes.length).set(bytes);
  return [ptr, bytes.length];
}

async function compileVfs(request) {
  const exports = await load('noir-compiler', workerData.compiler);
  const [ptr, len] = put(exports, 'nv_alloc', JSON.stringify(request));
  const resPtr = exports.nv_compile_vfs(ptr, len);
  const resLen = exports.nv_result_len();
  return JSON.parse(new TextDecoder().decode(
    new Uint8Array(exports.memory.buffer, resPtr, resLen).slice()));
}

async function testVfs(request) {
  // THE SAME MODULE AS `compileVfs`: `nv_test_vfs` is an export of
  // `noir_wasm.wasm` beside `nv_compile_vfs`, and shares its allocator and its
  // `nv_result_len`. The tracer is not involved — a test run produces a
  // verdict, not a recording.
  const exports = await load('noir-compiler', workerData.compiler);
  const [ptr, len] = put(exports, 'nv_alloc', JSON.stringify(request));
  const resPtr = exports.nv_test_vfs(ptr, len);
  const resLen = exports.nv_result_len();
  return JSON.parse(new TextDecoder().decode(
    new Uint8Array(exports.memory.buffer, resPtr, resLen).slice()));
}

async function traceArtifact(artifact, inputs) {
  const exports = await load('noir-tracer', workerData.tracer);
  const [aPtr, aLen] = put(exports, 'ct_alloc', JSON.stringify(artifact));
  const [iPtr, iLen] = put(exports, 'ct_alloc', inputs);
  const tPtr = exports.ct_trace(aPtr, aLen, iPtr, iLen, 0);
  const tLen = exports.ct_result_len();
  const isErr = exports.ct_result_is_error() !== 0;
  const text = new TextDecoder().decode(
    new Uint8Array(exports.memory.buffer, tPtr, tLen).slice());
  if (isErr) throw new Error(`tracing failed inside wasm: ${text.slice(0, 300)}`);
  return text;
}

parentPort.on('message', async (raw) => {
  // `String(raw)` for the same reason the browser transport coerces: the
  // protocol is text, and a structured-clone object arriving here would be a
  // silent second shape.
  let request;
  try {
    request = JSON.parse(String(raw));
  } catch (e) {
    post({ seq: 0, kind: 'failed', message: `worker got a non-JSON request: ${e.message}` });
    return;
  }
  const seq = request.seq;
  try {
    // THE TWIN HAD ALREADY DRIFTED, and this arm is the correction. The
    // browser worker has handled `configure` since the handshake landed, and
    // `platform/wasm_worker.configure` sends one at construction — so a Nim
    // driver pointed at this file received `unknown request kind configure`
    // for its first message. Nothing broke, because the reply lands on
    // sequence 0 and `deliver` discards a `configure` acknowledgement either
    // way; but "the two files are identical message for message" is what lets
    // the e2e stand as evidence for the browser one, and it was not true.
    //
    // The URLs are ignored here on purpose: this worker reads its modules
    // from `workerData` paths, which is the one difference the header allows.
    // Answering rather than refusing is what keeps the vocabularies equal.
    if (request.kind === 'configure') {
      post({ seq, kind: 'output', stream: 'stdout', text: '' });
      post({ seq, kind: 'exit', exitCode: 0, signalled: false });
      return;
    }

    // SESSIONS are the browser worker's, and this file does NOT host them.
    // That is a deliberate difference and it is named rather than silent: the
    // services a session runs are browser-side, and a twin that refused them
    // with `unknown request kind` would say the protocol has no such verb
    // instead of that this host has no such service. The distinction is the
    // one `wasm_registry.nim` spends its header on — "no module at all"
    // against "a module that was not built with this subcommand" — and the
    // e2e's whole value is that the two files do not disagree by accident.
    if (request.kind === 'input' || request.kind === 'close') {
      post({ seq, kind: 'failed', fault: 'no-session',
             message: `this node twin hosts no sessions, so \`${request.kind}\` ` +
                      `has nothing to address. Sessions are a browser-worker ` +
                      `capability; see host/wasm_worker_browser.js.` });
      return;
    }

    if (request.kind !== 'start') {
      post({ seq, kind: 'failed', message: `unknown request kind ${request.kind}` });
      return;
    }
    const sub = (request.args || []).find((a) => !a.startsWith('-'));
    if (sub === 'compile') {
      const response = await compileVfs(JSON.parse(request.stdin));
      post({ seq, kind: 'output', stream: 'stdout', text: JSON.stringify(response) });
      post({ seq, kind: 'exit', exitCode: response.ok ? 0 : 1, signalled: false });
    } else if (sub === 'test') {
      const response = await testVfs(JSON.parse(request.stdin));
      post({ seq, kind: 'output', stream: 'stdout', text: JSON.stringify(response) });
      // `ok` means the suite RAN; the exit code has to also account for a test
      // that failed, or a red suite would resolve as a successful run. Same
      // rule, same spelling, as the browser worker — this file's whole value is
      // that the two do not disagree by accident.
      const failed = !response.ok || (response.failed || 0) > 0;
      post({ seq, kind: 'exit', exitCode: failed ? 1 : 0, signalled: false });
    } else if (sub === 'trace') {
      const payload = JSON.parse(request.stdin);
      const text = await traceArtifact(payload.artifact, payload.inputs);
      post({ seq, kind: 'output', stream: 'stdout', text });
      post({ seq, kind: 'exit', exitCode: 0, signalled: false });
    } else {
      post({ seq, kind: 'failed', message: `no wasm build for subcommand ${sub}` });
    }
  } catch (e) {
    post({ seq, kind: 'failed', message: String(e && e.message ? e.message : e) });
  }
});
