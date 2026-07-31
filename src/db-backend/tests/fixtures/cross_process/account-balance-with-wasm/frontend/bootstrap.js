// Cross-process origin demo — recorder bootstrap for the browser tier.
//
// This file installs the CodeTracer browser runtime as `window.__ct`
// before any instrumented module runs, and starts a second recording
// for the WebAssembly module.
//
// It is deliberately **excluded from instrumentation** (see the
// `exclude` glob in `vite.config.js`): the runtime cannot record its own
// setup, and instrumenting the file that defines `__ct` would call
// `__ct.step()` before `__ct` exists.
//
// Two independent recordings come out of this one page:
//
//   * `frontend.ct`      — the page's JavaScript
//   * `frontend-wasm.ct` — the WebAssembly module
//
// They are separate because they are separate execution realms; keeping
// them apart is what lets the debugger show them as distinct processes
// and lets an origin chain describe the JS -> WASM call as a boundary
// hop. Both connect to the same `record-web` daemon, which writes one
// `.ct` per connection.

import { createBrowserRuntime } from "@codetracer/runtime-browser";
import { createBrowserWasmRecorder } from "codetracer-wasm-instrumenter/recorder-runtime/browser_session.js";
// Sidecar emitted by `ct-instrument` next to the instrumented module.
// Statically imported so it is inlined into the bundle and available
// synchronously: the recorder announces its session — manifest
// included — the moment it is constructed, and a manifest that arrives
// later would leave the recording's frames anonymous.
import wasmManifest from "./balance_calc.wasm.manifest.json";

// Point both recorders at the `record-web` daemon.
//
// This has to be done here, before either runtime is constructed: both
// resolve their endpoint once, at construction, from
// `globalThis.__codetracer_endpoint` falling back to a compiled-in
// `ws://localhost:9230/ct-stream`. A browser bundle cannot read the
// environment, so without this line `DEMO_RECORD_WEB_PORT` would move
// the daemon while leaving the page dialling 9230 — the page would
// still load and run, and the recordings would simply never appear.
// `vite.config.js` bakes the port in at build time.
globalThis.__codetracer_endpoint = `ws://127.0.0.1:${__CT_RECORD_WEB_PORT__}/ct-stream`;

// The JS runtime picks up the endpoint and the instrumentation manifest
// from the globals the Vite plugin bakes into the page.
const jsRuntime = createBrowserRuntime({ program: "frontend" });
globalThis.__ct = jsRuntime;

// The WASM recorder must be created *after* `globalThis.__ct` exists: it
// mirrors every realm-boundary marker onto the JS side through it, and a
// missing `__ct` would silently leave those markers one-sided (and
// therefore unpairable).
//
// No `returnValueNames` here, and none needed: the value that crosses
// back out of a WebAssembly export *is* its result, so the recorder
// names the crossing binding itself from the result it just recorded.
// That option exists only for the unusual export whose return value is
// not the interesting one.
const wasmRecorder = createBrowserWasmRecorder({
  program: "frontend-wasm",
  manifest: wasmManifest,
});

/**
 * Instantiate the instrumented WASM module against the recorder's
 * import namespace.
 *
 * The module was rewritten by `ct-instrument`, so it imports the
 * `__codetracer` hooks; supplying them is what produces the WASM
 * recording. A plain `WebAssembly.instantiate` is all that is needed
 * because the module is a bare cdylib with a C ABI.
 */
async function loadWasm() {
  const response = await fetch(new URL("./balance_calc.wasm", import.meta.url));
  const bytes = await response.arrayBuffer();
  const { instance } = await WebAssembly.instantiate(bytes, {
    __codetracer: wasmRecorder.imports,
  });
  return instance.exports;
}

/**
 * Finalise both recordings.
 *
 * Order matters only in that both must be flushed before the page goes
 * away; the daemon finalises each `.ct` when its connection reports
 * `SessionEnd`.
 */
function stopRecording() {
  try {
    wasmRecorder.stop();
  } finally {
    jsRuntime.stop();
  }
}

export { loadWasm, stopRecording, jsRuntime, wasmRecorder };
