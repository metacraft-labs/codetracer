// Parity corpus — `vault_apply` browser tier.
//
// Ordinary host glue for a module whose linear memory is imported: the
// page creates the memory, stages the calldata in it, and answers the
// module's rate lookups by writing into the same memory. Nothing here is
// arranged for the recorder beyond the one `trackHostMemory` call any
// page recording an imported memory would make.
//
// Value flow:
//
//   host stages VAULT.slots[i].{key, amount}        [spec §3.3]
//        -> apply_slot(i) reads them out of memory
//        -> fetch_rate(key) — the host writes
//           VAULT.slots[i].rate_bps and returns only a status [spec §3.4]
//        -> apply_slot(i) reads the rate, applies it, accumulates
//        -> returns the running total
//
// The two imports come from **different host modules** on purpose. The
// memory is `env.memory` (that is the name `rust-lld --import-memory`
// emits and it is not configurable); the lookup is `host.fetch_rate`.
// `lib.rs` explains why: it is what lets the §10 parity property's
// direct-run leg supply the memory with a plain memory-defining module
// and the function with wazero's `HostModuleBuilder`, instead of needing
// the replayer's own provider synthesiser and so sharing the code under
// test between the two legs.

import { record, fail } from "/shared/harness.js";

/** Byte size of one `Slot` in `lib.rs`. */
const SLOT_STRIDE = 16;
/** Field offsets inside a `Slot`. */
const OFF_KEY = 0;
const OFF_AMOUNT = 4;
const OFF_RATE_BPS = 8;
/** Status the module expects from `fetch_rate`. */
const RATE_OK = 1;

/**
 * The calldata the host stages before the first exported call. These
 * numbers are the fixture's ground truth; they are not in the `.wasm`.
 */
const REQUESTS = [
  { key: 7001, amount: 480_000 },
  { key: 7002, amount: 15_500 },
  { key: 7003, amount: 96_240 },
];

/**
 * The host's rate table. It lives here, in the host, which is why the
 * module cannot compute its own answer: this data never enters the
 * `.wasm` and never crosses the boundary as a value.
 */
const RATE_TABLE = new Map([
  [7001, 250],
  [7002, 40],
  [7003, 1_125],
]);

// Two pages is one more than `-zstack-size=65536` needs; the maximum is
// declared so the recording carries the host limit spec §7 makes
// `memory.grow` depend on.
const memory = new WebAssembly.Memory({ initial: 2, maximum: 4 });

// Address of the module's `VAULT` block, learned from the instance. It
// is declared here because `fetch_rate` reads it, and `fetch_rate` has
// to exist before `WebAssembly.instantiate` can be handed it.
let vaultBase = 0;

/**
 * The module's rate lookup.
 *
 * Answers by **writing into linear memory** and returning only a status
 * code. While this function runs the module is suspended, which is
 * exactly the window spec §3.4 defines.
 *
 * @param {number} key
 * @returns {number}
 */
function fetch_rate(key) {
  const rate = RATE_TABLE.get(key);
  if (rate === undefined) return 0;
  // The host finds the slot it staged itself; the module never told it
  // an index.
  const view = new DataView(memory.buffer);
  for (let i = 0; i < REQUESTS.length; i++) {
    const base = vaultBase + i * SLOT_STRIDE;
    if (view.getUint32(base + OFF_KEY, true) !== key) continue;
    view.setUint32(base + OFF_RATE_BPS, rate, true);
    return RATE_OK;
  }
  return 0;
}

record({
  program: "vault-apply",
  moduleName: "vault_apply",
  imports: () => ({ env: { memory }, host: { fetch_rate } }),
  ready: (instance, recorder) => {
    // Registered *after* instantiation, on purpose: the baseline is
    // taken now, so the module's own data segments — which the replayer
    // applies from the `.wasm` itself — stay out of the §3.3 record and
    // what remains is exactly the host's contribution.
    recorder.trackHostMemory({
      module: "env",
      name: "memory",
      memory,
      maxPages: 4,
    });

    // `rust-lld` exports the address of the `VAULT` symbol as a global.
    // Reading it crosses no recorded boundary, which is what lets the
    // host stage its calldata *before* the first exported call — the
    // only place spec §3.3 can put it.
    vaultBase = instance.exports.VAULT.value;

    const staging = new DataView(memory.buffer);
    REQUESTS.forEach((request, i) => {
      const base = vaultBase + i * SLOT_STRIDE;
      staging.setUint32(base + OFF_KEY, request.key, true);
      staging.setUint32(base + OFF_AMOUNT, request.amount, true);
    });
  },
  // `>>> 0`: see the note in `loop_digest`'s page.
  calls: (instance) => REQUESTS.map((_, i) => instance.exports.apply_slot(i) >>> 0),
}).catch(fail);
