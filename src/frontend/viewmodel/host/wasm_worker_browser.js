// The wasm worker's script, for a BROWSER — the thing that was missing.
//
// NS3 landed the registry (`platform/wasm_registry.nim`), the protocol
// (`platform/wasm_worker.nim`), the transport and
// `newBrowserWasmHost(registry, scriptUrl)` in `host/web_browser.nim`. All of
// it is tested and none of it is reachable, and `newBrowserWasmHost`'s own doc
// comment says exactly why:
//
//   "Not called by `newBrowserBridge` yet, and that is the honest state: the
//   worker script that instantiates the Noir modules and drives their `nv_*` /
//   `ct_*` ABIs is not in the bundle"
//
// This is that script. It is the file `scriptUrl` points at.
//
// ## Why a separate asset rather than an inlined blob
//
// `new Worker(url)` wants a URL, and `newBrowserWasmHost` already takes one —
// the design decided this before the file existed. Inlining the script and
// constructing a `blob:` URL would work in a demo and fail in the product: a
// `Content-Security-Policy` worth setting rejects `worker-src blob:`, and a
// blob URL is uncacheable, so every reload re-parses it. As a real file it is
// an ordinary hashed static asset — the `ccStaticAsset` row
// `platform/web_deployment.nim` already defines.
//
// ## Why the wasm modules are FETCHED and not bundled
//
// They are ~16 MB (`noir_wasm`) and ~4.6 MB (`noir_tracer_wasm`). Base64 in a
// JS bundle inflates by a third and must be parsed as source before anything
// runs, which would put ~27 MB in front of first paint for a feature most
// sessions never use. Fetched, they are content-addressed immutable assets —
// `ccImmutable` in the same table — cached indefinitely after the first run and
// loaded lazily, on the first command that needs one.
//
// `WebAssembly.compileStreaming` is used for the same reason, and it is not
// merely faster: it compiles while the body is still arriving, so a 16 MB
// module never has to exist as one ArrayBuffer in the tab. The fallback below
// exists because `compileStreaming` REQUIRES `Content-Type: application/wasm`,
// and a host serving `.wasm` as `application/octet-stream` would otherwise fail
// with a TypeError that names nothing useful.
//
// ## The protocol is `ci/test/noir-wasm-worker/worker.mjs`'s, message for message
//
// That file is the node twin, driven by `ci/test/noir-wasm-worker-e2e.sh`,
// which compiles and traces a real Noir package through this protocol and
// through an in-process path and compares the two traces by digest AND for
// non-triviality. Keeping the two identical is what lets that e2e stand as
// evidence for this file: the halves that differ are `fetch` vs `readFileSync`
// and `self.onmessage` vs `parentPort.on`, and nothing else.
//
// TEXT IN, TEXT OUT, both directions, no exceptions. The Nim side's `deliver`
// takes a `string`. `wasm_worker.nim`'s header records what the alternative
// cost a sibling campaign: an engine that sent objects one way and JSON strings
// the other, and a reader that classified by message type and reported a
// timeout over an engine that had answered.

'use strict';

const post = (message) => self.postMessage(JSON.stringify(message));

// Every declared import is stubbed to THROW rather than to no-op. The Noir
// modules are built to need none, so "reached no import" is a property worth
// measuring; a silent no-op stub would let a module that quietly depends on
// WASI produce wrong answers instead of an error naming the import.
const stubImports = (mod) => {
  const imports = {};
  for (const { module: m, name } of WebAssembly.Module.imports(mod)) {
    imports[m] ??= {};
    imports[m][name] = () => { throw new Error(`reached ${m}.${name}`); };
  }
  return imports;
};

// Supplied by a `configure` message rather than baked in: the bundle's asset
// URLs are content-addressed and so are not known when this file is written.
let moduleUrls = {};
const modules = new Map();

async function load(id) {
  if (modules.has(id)) return modules.get(id);
  const url = moduleUrls[id];
  if (!url) throw new Error(`no url declared for wasm module ${id}`);

  const response = await fetch(url);
  if (!response.ok) {
    throw new Error(`fetching ${id} from ${url} failed: HTTP ${response.status}`);
  }
  let mod;
  try {
    mod = await WebAssembly.compileStreaming(response.clone());
  } catch (e) {
    // Wrong Content-Type, or an engine without streaming compile. Not worth
    // surfacing: the only observable difference is peak memory.
    mod = await WebAssembly.compile(await response.arrayBuffer());
  }
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
  const exports = await load('noir-compiler');
  const [ptr, len] = put(exports, 'nv_alloc', JSON.stringify(request));
  const resPtr = exports.nv_compile_vfs(ptr, len);
  const resLen = exports.nv_result_len();
  return JSON.parse(new TextDecoder().decode(
    new Uint8Array(exports.memory.buffer, resPtr, resLen).slice()));
}

async function traceArtifact(artifact, inputs) {
  const exports = await load('noir-tracer');
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

self.onmessage = async (event) => {
  // `String(...)` for the same reason the Nim transport coerces: the protocol
  // is text, and a structured-clone object arriving here would be a silent
  // second shape — the asymmetry `wasm_worker.nim`'s header forbids.
  let request;
  try {
    request = JSON.parse(String(event.data));
  } catch (e) {
    post({ seq: 0, kind: 'failed', message: `worker got a non-JSON request: ${e.message}` });
    return;
  }

  const seq = request.seq;
  try {
    // The bundle tells the worker where its modules live, once, before any run.
    // An ordinary protocol message rather than `workerData` (browsers have no
    // such thing) or a query string (which would put the URLs into the worker
    // script's own cache key).
    if (request.kind === 'configure') {
      moduleUrls = request.moduleUrls || {};
      post({ seq, kind: 'output', stream: 'stdout', text: '' });
      post({ seq, kind: 'exit', exitCode: 0, signalled: false });
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
      // The exit code follows the RESPONSE, not the fact that the call
      // returned. A compiler reporting `ok: false` has failed, and resolving
      // its run as a success is the "chain of agreements" shape this
      // protocol's header names.
      post({ seq, kind: 'exit', exitCode: response.ok ? 0 : 1, signalled: false });
    } else if (sub === 'trace') {
      const payload = JSON.parse(request.stdin);
      const text = await traceArtifact(payload.artifact, payload.inputs);
      post({ seq, kind: 'output', stream: 'stdout', text });
      post({ seq, kind: 'exit', exitCode: 0, signalled: false });
    } else {
      // Case 3 of `wasm_registry.nim`'s five: a module is registered but was
      // not built with this subcommand. Distinct from "no module at all",
      // which the registry answers before anything reaches this worker.
      post({ seq, kind: 'failed', message: `no wasm build for subcommand ${sub}` });
    }
  } catch (e) {
    post({ seq, kind: 'failed', message: String(e && e.message ? e.message : e) });
  }
};
