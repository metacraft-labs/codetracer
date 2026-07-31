// Host-supplied-state demo — browser tier.
//
// Ordinary host glue: it creates the module's linear memory, stages the
// calldata in it, and answers the module's fee lookups by writing into
// the same memory. Nothing here is arranged for the recorder beyond the
// two `trackHostMemory` / `stop` calls that any page recording a module
// with an imported memory would make.
//
// This page is deliberately **not** bundled. It loads
// `browser_session.js` straight out of the instrumenter checkout as a
// native ES module, so the recording it produces is made by the working
// tree's producer and not by a snapshot of it baked into a bundle.
//
// Value flow:
//
//   host stages LEDGER[i].{account_id, principal}   [spec §3.3]
//        -> settle(i) reads them out of linear memory
//        -> fetch_fee_bps(account_id) — the host writes
//           LEDGER[i].fee_bps and returns only a status  [spec §3.4]
//        -> settle(i) reads the fee, settles, accumulates
//        -> returns the running total

import { createBrowserWasmRecorder } from "./recorder-runtime/browser_session.js";

/** Byte size of one `Record` in `wasm-src/lib.rs`. */
const LEDGER_RECORD_STRIDE = 16;
/** Field offsets inside a `Record`. */
const OFF_ACCOUNT_ID = 0;
const OFF_PRINCIPAL = 4;
const OFF_FEE_BPS = 8;
/** Status the module expects from `fetch_fee_bps`. */
const FEE_OK = 1;

/**
 * The calldata the host stages before the first exported call.
 *
 * These numbers are the fixture's ground truth: the committed
 * `ANSWERS.md` derives the expected trace from them.
 */
const REQUESTS = [
  { accountId: 1001, principal: 250_000 },
  { accountId: 1002, principal: 80_000 },
  { accountId: 1003, principal: 12_345 },
];

/**
 * The host's fee table. It lives here, in the host, which is the whole
 * reason the module cannot compute its own answer: this data never
 * enters the `.wasm`.
 */
const FEE_TABLE = new Map([
  [1001, 150],
  [1002, 25],
  [1003, 900],
]);

const status = (text) => {
  const target = document.querySelector("#status");
  if (target !== null) target.textContent = text;
};

async function main() {
  const manifest = await (
    await fetch("./ledger_settle.instrumented.wasm.manifest.json")
  ).json();

  const recorder = createBrowserWasmRecorder({
    program: "ledger-settle",
    manifest,
  });

  // The module imports its memory, so the *host* owns it. Two pages is
  // one more than `-zstack-size=65536` needs; the maximum is declared so
  // the recording carries the host limit spec §7 makes `memory.grow`
  // depend on.
  const memory = new WebAssembly.Memory({ initial: 2, maximum: 4 });

  // Address of the module's `LEDGER` block, learned from the instance
  // below. Declared here because the fee lookup reads it, and the lookup
  // has to exist before `WebAssembly.instantiate` can be handed it.
  let ledgerBase = 0;

  /**
   * The module's fee lookup.
   *
   * Answers by **writing into linear memory** and returning only a
   * status code. While this function runs the module is suspended, which
   * is exactly the window spec §3.4 defines.
   *
   * @param {number} accountId
   * @returns {number}
   */
  function fetch_fee_bps(accountId) {
    const rate = FEE_TABLE.get(accountId);
    if (rate === undefined) return 0;
    // Find the staged record this account belongs to. The host reads the
    // block it staged itself; the module never told it an index.
    const view = new DataView(memory.buffer);
    for (let i = 0; i < REQUESTS.length; i++) {
      const base = ledgerBase + i * LEDGER_RECORD_STRIDE;
      if (view.getUint32(base + OFF_ACCOUNT_ID, true) !== accountId) continue;
      view.setUint32(base + OFF_FEE_BPS, rate, true);
      return FEE_OK;
    }
    return 0;
  }

  const bytes = await (
    await fetch("./ledger_settle.instrumented.wasm")
  ).arrayBuffer();
  const { instance } = await WebAssembly.instantiate(bytes, {
    __codetracer: recorder.imports,
    env: { memory, fetch_fee_bps },
  });

  // Registered *after* instantiation, on purpose: the baseline is taken
  // now, so the module's own data segments — which the replayer applies
  // from the `.wasm` itself — stay out of the §3.3 record and what
  // remains is exactly the host's contribution.
  recorder.trackHostMemory({
    module: "env",
    name: "memory",
    memory,
    maxPages: 4,
  });

  // `rust-lld` exports the address of the `LEDGER` symbol as a global.
  // Reading it crosses no recorded boundary, which is what lets the host
  // stage its calldata *before* the first exported call — the only place
  // spec §3.3 can put it.
  ledgerBase = instance.exports.LEDGER.value;

  const staging = new DataView(memory.buffer);
  REQUESTS.forEach((request, i) => {
    const base = ledgerBase + i * LEDGER_RECORD_STRIDE;
    staging.setUint32(base + OFF_ACCOUNT_ID, request.accountId, true);
    staging.setUint32(base + OFF_PRINCIPAL, request.principal, true);
  });

  const totals = REQUESTS.map((_, i) => instance.exports.settle(i));

  const diagnostics = recorder.hostStateDiagnostics;
  recorder.stop();

  // Checked as a set rather than field by field, so a counter the
  // recorder gains later cannot be silently ignored by this page.
  if (Object.values(diagnostics).some((count) => count !== 0)) {
    // A recording the producer knows is incomplete must not be mistaken
    // for a good one: it would replay to a divergence far from the cause.
    status(`incomplete: ${JSON.stringify(diagnostics)}`);
    return;
  }
  // The page publishes what it observed so the driver can compare it
  // against the replay without re-deriving the arithmetic.
  globalThis.__demoTotals = totals;
  status(`settled ${totals.join(",")}`);
}

main().catch((err) => {
  status(`error: ${err && err.message ? err.message : err}`);
});
