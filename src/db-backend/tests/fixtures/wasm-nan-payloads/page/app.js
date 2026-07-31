// NaN-payload demo (M52) — browser tier.
//
// Ordinary host glue. The page drives four exported calls with bit
// patterns it supplies as integers, and answers the module's two
// `observe_*` imports with plain no-op stubs. Nothing here is arranged
// for the recorder beyond constructing it and calling `stop()`.
//
// **The page deliberately never touches a float.** Every value it hands
// the module and every value it checks is an integer bit pattern,
// because a JavaScript `Number` is precisely the thing that cannot hold
// these values: `NaN` has no payload in JS, `JSON.stringify(NaN)` is
// `null`, and `String(-0)` is `"0"`. If this page compared floats it
// would be asserting on the damaged copies rather than on what the
// module produced, and would pass whether or not M52 worked.
//
// This page is **not** bundled. It loads `browser_session.js` straight
// out of the instrumenter checkout as a native ES module, so the
// recording it produces is made by the working tree's producer and not
// by a snapshot of it baked into a bundle.

import { createBrowserWasmRecorder } from "./recorder-runtime/browser_session.js";

/**
 * The bit patterns the fixture is about, as `[export, argument]` pairs.
 *
 * Each is passed to the module as an integer, turned into a float
 * *inside* the module, carried across the boundary twice (once as an
 * argument to an `observe_*` import, once as the export's own result),
 * and recorded by the `__ct_emit_f{32,64}_bits` hooks.
 */
const PROBES = [
  // f32 signalling NaN. The quiet bit (0x0040_0000) is clear, so any
  // quieting or `f32 -> f64 -> f32` round trip changes it.
  { fn: "probe_f32", arg: 0x7f800001 | 0, width: 32 },
  // f32 negative zero.
  { fn: "probe_f32", arg: 0x80000000 | 0, width: 32 },
  // f64 quiet NaN carrying a payload.
  { fn: "probe_f64", arg: BigInt.asIntN(64, 0x7ff80000deadbeefn), width: 64 },
  // f64 negative zero, computed rather than declared: the module
  // negates the +0.0 this passes in and multiplies by one.
  { fn: "probe_negated_f64", arg: 0n, width: 64 },
];

/** An i32 crossing, so the fixture also covers the non-float path. */
const INT_PROBE = { fn: "f32_bits_roundtrip", arg: 0x7f800001 | 0 };

const status = (text) => {
  const target = document.querySelector("#status");
  if (target !== null) target.textContent = text;
};

/** Render an f32 bit pattern the way the recording spells it. */
const f32Hex = (bits) =>
  `f32:0x${(bits >>> 0).toString(16).padStart(8, "0")}`;

/** Render an f64 bit pattern the way the recording spells it. */
const f64Hex = (bits) =>
  `f64:0x${BigInt.asUintN(64, bits).toString(16).padStart(16, "0")}`;

async function main() {
  const manifest = await (
    await fetch("./nan_payloads.instrumented.wasm.manifest.json")
  ).json();

  const recorder = createBrowserWasmRecorder({
    program: "nan-payloads",
    manifest,
  });

  // The imports do nothing. Their whole purpose is to be a boundary the
  // module's floats cross outbound, so the recording carries them as
  // §3.2 argument tuples.
  const observe_f32 = () => {};
  const observe_f64 = () => {};

  const bytes = await (
    await fetch("./nan_payloads.instrumented.wasm")
  ).arrayBuffer();
  const { instance } = await WebAssembly.instantiate(bytes, {
    __codetracer: recorder.imports,
    env: { observe_f32, observe_f64 },
  });

  // What the page believes it asked for, in the recording's own
  // spelling. The driver writes this out and the replay is checked
  // against it, so the expectation comes from the run rather than from
  // a table someone maintained by hand.
  const expected = [];
  for (const probe of PROBES) {
    instance.exports[probe.fn](probe.arg);
    expected.push(probe.width === 32 ? f32Hex(probe.arg) : f64Hex(probe.arg));
  }
  // `probe_negated_f64(0)` returns -0.0, not the +0.0 it was given, so
  // its expectation is the negated pattern.
  expected[3] = f64Hex(0x8000000000000000n);

  const intResult = instance.exports[INT_PROBE.fn](INT_PROBE.arg);

  recorder.stop();

  if (intResult !== INT_PROBE.arg) {
    // A module that cannot round-trip an integer is broken in a way
    // that would make every float conclusion below meaningless.
    status(`int roundtrip failed: ${intResult}`);
    return;
  }

  globalThis.__demoExpected = expected;
  status(`probed ${expected.length}`);
}

main().catch((err) => {
  status(`error: ${err && err.message ? err.message : err}`);
});
