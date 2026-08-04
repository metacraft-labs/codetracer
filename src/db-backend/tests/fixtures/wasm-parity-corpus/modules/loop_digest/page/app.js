// Parity corpus — `loop_digest` browser tier.
//
// The module imports nothing and owns its memory, so the page is the
// minimum a recording needs: instantiate, call, stop. Everything
// interesting is inside the module, which is the point — the boundary
// recording carries six argument/result pairs and the materialised trace
// carries the loop, the three-deep call nest and every local along the
// way, none of which the recording mentions.

import { record, fail } from "/shared/harness.js";

/**
 * The samples, chosen so the ring both fills (`WINDOW` is 4) and wraps.
 * Two of them repeat a value already absorbed, which is what makes the
 * "the same argument twice gives two different answers" guard mean
 * something.
 */
const SAMPLES = [3, 11, 29, 7, 3, 101];

record({
  program: "loop-digest",
  moduleName: "loop_digest",
  // `>>> 0` because the WebAssembly JS API hands an `i32` result to
  // JavaScript as a *signed* number, while the module's own type is
  // `u32` and the offline replay reports it unsigned. The bits are the
  // same either way; recording the unsigned rendering is what lets the
  // committed ground truth be compared against the replay's without
  // either side re-deriving the other's convention.
  calls: (instance) => SAMPLES.map((s) => instance.exports.absorb(s) >>> 0),
}).catch(fail);
