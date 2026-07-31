// Parity corpus — `tick_ledger` browser tier.
//
// Twenty-four exported calls, which is what makes this module the one
// the snapshot and slice properties are asserted over: at
// `--snapshot-every 4` a replay produces six snapshots, and every one of
// them has real state behind it and a real DWARF-driven trace in front
// of it.

import { record, fail } from "/shared/harness.js";

/**
 * The deltas. Twenty-four of them, with repeats, so a seek to the middle
 * of the recording lands somewhere the arguments alone cannot describe.
 */
const DELTAS = [
  17, 4, 250, 33, 8, 91, 17, 512, 6, 44, 120, 3, 77, 17, 900, 21, 5, 64, 1000,
  12, 38, 7, 256, 19,
];

record({
  program: "tick-ledger",
  moduleName: "tick_ledger",
  // `>>> 0`: see the note in `loop_digest`'s page.
  calls: (instance) => DELTAS.map((d) => instance.exports.tick(d) >>> 0),
}).catch(fail);
