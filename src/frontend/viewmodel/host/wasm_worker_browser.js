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

// THREE FAULTS, THREE SENTENCES — and they must never collapse into one.
//
// A sibling campaign lost hours to a single message that covered two different
// faults: a missing asset and a broken feature read identically, so the
// investigation started in the wrong half of the system and stayed there. The
// three states below are reached by different mistakes and fixed by different
// people, so `load` names which one it is:
//
//   NOT DELIVERED    this deployment ships no such module. The entry document
//                    declared no URL for it. Nobody is broken — the deployment
//                    is smaller than the product. The registry normally
//                    answers this before anything reaches the worker; if it
//                    gets here, the page and the registry disagree.
//   NOT SERVED       a URL was declared and the server does not have it. This
//                    is a BROKEN DEPLOY: the document promises bytes the
//                    publish directory lacks. `deployGuardDefects` exists to
//                    make this unreachable, and this message is what it looks
//                    like when the guard was bypassed.
//   BROKEN           the bytes arrived and are not a usable module — truncated,
//                    an HTML error page with a 200, or built against a
//                    different ABI. The only one of the three that is a bug in
//                    the module itself.
const NOT_DELIVERED = 'not-delivered';
const NOT_SERVED = 'not-served';
const BROKEN = 'broken';

const loadFault = (kind, id, detail) => {
  const error = new Error(detail);
  error.ctFault = kind;
  error.ctModule = id;
  return error;
};

async function load(id) {
  if (modules.has(id)) return modules.get(id);
  const url = moduleUrls[id];
  if (!url) {
    throw loadFault(NOT_DELIVERED, id,
      `this deployment does not ship the \`${id}\` wasm module, so it was ` +
      `never fetched. Nothing is broken: the module is absent, not failing.`);
  }

  let response;
  try {
    response = await fetch(url);
  } catch (e) {
    // A network-level failure is still "not served" from the page's point of
    // view: the bytes did not arrive. Distinguished from a 404 only in the
    // detail, because the remedy — look at what the deployment published — is
    // the same.
    throw loadFault(NOT_SERVED, id,
      `\`${id}\` is declared at ${url} and the request for it did not ` +
      `complete: ${e && e.message ? e.message : e}`);
  }
  if (!response.ok) {
    throw loadFault(NOT_SERVED, id,
      `\`${id}\` is declared at ${url} and this deployment does not serve ` +
      `it (HTTP ${response.status}). The page and the published files ` +
      `disagree; the module itself has not been reached.`);
  }

  // A 200 IS NOT PROOF THE MODULE IS THERE, and on this product's own host it
  // frequently is not. Cloudflare Pages answers a request for an absent path
  // with the entry document — `HTTP 200`, `content-type: text/html` — which was
  // MEASURED against the live deployment, not assumed:
  //
  //   $ curl -sI https://web-codetracer.pages.dev/assets/noir_wasm.wasm
  //     HTTP/2 200
  //     content-type: text/html; charset=utf-8
  //
  // Without this branch that HTML reaches `WebAssembly.compile`, fails on the
  // magic word, and is reported as BROKEN — "the module was served and is not
  // usable" — when the truth is that it was never deployed. That is precisely
  // the conflation of a missing asset with a broken feature that cost a sibling
  // campaign hours, arriving through the CDN instead of through the code.
  //
  // So the response is classified before it is compiled. Streaming is kept for
  // the good case, which is the one that matters for a 16 MB module: a correct
  // `application/wasm` goes straight to `compileStreaming` and is never
  // buffered.
  const contentType = (response.headers && typeof response.headers.get === 'function'
    ? response.headers.get('content-type') : '') || '';
  const looksLikeWasm = contentType.includes('application/wasm');

  let exports;
  let buffered = null;
  if (!looksLikeWasm) {
    // Not advertised as wasm. It may still BE wasm (a host serving
    // `application/octet-stream`), so the magic word decides rather than the
    // header — a header alone would turn a misconfigured but working host into
    // a hard failure.
    buffered = await response.arrayBuffer();
    const magic = new Uint8Array(buffered, 0, Math.min(4, buffered.byteLength));
    const isWasm = magic.length === 4 && magic[0] === 0x00 && magic[1] === 0x61 &&
                   magic[2] === 0x73 && magic[3] === 0x6d;
    if (!isWasm) {
      throw loadFault(NOT_SERVED, id,
        `\`${id}\` is declared at ${url} and this deployment answered with ` +
        `${contentType || 'an unknown content type'} rather than a wasm ` +
        `module (${buffered.byteLength} bytes). A static host commonly serves ` +
        `its index page for a path it does not have, so this almost always ` +
        `means the module was not published — not that it is broken.`);
    }
  }

  // The bytes are here and they are wasm. Everything from this point on is the
  // module's own fault, and is reported as such.
  try {
    let mod;
    if (buffered !== null) {
      mod = await WebAssembly.compile(buffered);
    } else {
      try {
        mod = await WebAssembly.compileStreaming(response.clone());
      } catch (e) {
        // An engine without streaming compile. Not worth surfacing on its own:
        // the only observable difference is peak memory, and a genuinely bad
        // module fails the buffered path too — where it is reported as BROKEN,
        // below, rather than being blamed on the header.
        mod = await WebAssembly.compile(await response.arrayBuffer());
      }
    }
    ({ exports } = await WebAssembly.instantiate(mod, stubImports(mod)));
  } catch (e) {
    throw loadFault(BROKEN, id,
      `\`${id}\` was served from ${url} as a wasm module and is not a usable ` +
      `one: ${e && e.message ? e.message : e}`);
  }
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
    // `fault` is carried as its own field rather than being spelled into the
    // message, so a reader can BRANCH on which of the three it was without
    // matching prose. `wasm_worker.nim`'s `deliver` ignores fields it does not
    // know, so this is additive to the protocol.
    const message = String(e && e.message ? e.message : e);
    const fault = (e && e.ctFault) || '';
    post(fault
      ? { seq, kind: 'failed', message, fault, module: (e && e.ctModule) || '' }
      : { seq, kind: 'failed', message });
  }
};
