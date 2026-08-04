// Parity corpus — `pair_stats` browser tier.
//
// The single export returns **two** results, which the WebAssembly JS
// API delivers as an `Array`. That is the whole reason this module is in
// the corpus: the recording has to carry a result *tuple*, and every
// layer between the module and the replay has to slice it back the same
// way — `ct-instrument` emitting one hook call per result slot,
// `browser_session.js` rendering `sample_pair:ret0` / `:ret1` value
// bindings, and `values.go` reassembling the pair.

import { record, fail } from "/shared/harness.js";

/**
 * The samples. `KEEP` is 6, so five calls leave the window still
 * filling; the repeated `40` is what makes the two answers for one
 * argument differ.
 */
const SAMPLES = [40, 12, 91, 40, 7];

record({
  program: "pair-stats",
  moduleName: "pair_stats",
  calls: (instance) =>
    // `sample_pair` returns `[mean, peak]`. Kept as arrays so the
    // committed ground truth records both halves and a replay that
    // dropped one would be caught.
    // `>>> 0`: see the note in `loop_digest`'s page.
    SAMPLES.map((s) => Array.from(instance.exports.sample_pair(s), (v) => v >>> 0)),
}).catch(fail);
