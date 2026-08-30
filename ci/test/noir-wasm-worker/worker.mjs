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
    if (request.kind !== 'start') {
      post({ seq, kind: 'failed', message: `unknown request kind ${request.kind}` });
      return;
    }
    const sub = (request.args || []).find((a) => !a.startsWith('-'));
    if (sub === 'compile') {
      const response = await compileVfs(JSON.parse(request.stdin));
      post({ seq, kind: 'output', stream: 'stdout', text: JSON.stringify(response) });
      post({ seq, kind: 'exit', exitCode: response.ok ? 0 : 1, signalled: false });
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
