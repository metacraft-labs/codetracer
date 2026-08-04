// Parity corpus — the boilerplate every corpus page shares.
//
// Four pages record four modules and differ only in what they import,
// what they stage in memory, and which arguments they call with. Keeping
// the rest here means the *recording procedure* is one piece of code:
// one place decides when `stop()` is called, one place refuses to
// publish a recording the producer knows is incomplete, and one place
// declares the completion signal `drive.mjs` waits for. A per-page copy
// of that would let two of the four drift into recording something
// subtly different, which is the failure a parity corpus is least able
// to notice.
//
// The recorder runtime is loaded straight out of the instrumenter
// checkout (`serve.mjs` mounts it at `/recorder-runtime/`), so the
// recordings this fixture commits are made by the working tree's
// producer rather than by a copy of it frozen into a bundle.

import { createBrowserWasmRecorder } from "/recorder-runtime/browser_session.js";

/**
 * Set the page's status line. `drive.mjs` polls this and treats
 * anything other than `running` as the end of the run.
 *
 * @param {string} text
 */
function status(text) {
  const target = document.querySelector("#status");
  if (target !== null) target.textContent = text;
}

/**
 * Record one module.
 *
 * @param {object} spec
 * @param {string} spec.program      Recording name; becomes `<program>.ct`.
 * @param {string} spec.moduleName   Base name of the instrumented `.wasm`.
 * @param {(recorder: any) => object} [spec.imports]
 *   Extra import namespaces, built before instantiation. Anything that
 *   needs the instance (a host callback reading linear memory, say) must
 *   close over a mutable binding the caller fills in from `ready`.
 * @param {(instance: WebAssembly.Instance, recorder: any) => void} [spec.ready]
 *   Runs after `WebAssembly.instantiate` and before the first exported
 *   call. This is the only window spec §3.3 host-supplied initial state
 *   can be staged in.
 * @param {(instance: WebAssembly.Instance) => unknown[]} spec.calls
 *   Makes the exported calls and returns what they answered. The return
 *   value becomes the fixture's ground truth.
 */
export async function record(spec) {
  const manifest = await (
    await fetch(`./${spec.moduleName}.instrumented.wasm.manifest.json`)
  ).json();

  const recorder = createBrowserWasmRecorder({
    program: spec.program,
    manifest,
  });

  const extra = spec.imports ? spec.imports(recorder) : {};
  const bytes = await (
    await fetch(`./${spec.moduleName}.instrumented.wasm`)
  ).arrayBuffer();
  const { instance } = await WebAssembly.instantiate(bytes, {
    __codetracer: recorder.imports,
    ...extra,
  });

  if (spec.ready) spec.ready(instance, recorder);

  const answers = spec.calls(instance);

  const diagnostics = recorder.hostStateDiagnostics;
  recorder.stop();

  // Checked as a set rather than field by field, so a counter the
  // recorder gains later cannot be silently ignored here. A recording
  // the producer already knows is incomplete must never be mistaken for
  // a good one: it would replay to a divergence far from its cause.
  if (Object.values(diagnostics).some((count) => count !== 0)) {
    status(`incomplete: ${JSON.stringify(diagnostics)}`);
    return;
  }

  // The driver reads this and writes it to `expected.json`, so the
  // offline replay is checked against what the browser really observed
  // rather than against arithmetic re-derived on this side.
  //
  // Every answer is a *list* of results, even when the export returns
  // one, because `pair_stats` returns two and a corpus whose ground
  // truth changed shape per module would need a per-module reader on the
  // Go side — one more place for three modules to be checked one way and
  // the fourth another.
  const normalised = answers.map((a) => (Array.isArray(a) ? a : [a]));
  globalThis.__corpusAnswers = normalised;
  status(`done ${JSON.stringify(normalised)}`);
}

/**
 * Report a page-side failure in the one place the driver looks.
 *
 * @param {unknown} err
 */
export function fail(err) {
  const message = err && /** @type {Error} */ (err).message ? /** @type {Error} */ (err).message : err;
  status(`error: ${message}`);
}
