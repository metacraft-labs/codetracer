// Cross-process origin demo — browser JavaScript tier.
//
// This is ordinary application code. Nothing in CodeTracer or its
// recorders special-cases this file: it is instrumented by the same
// Vite plugin a user would install, and the two `__ct.markCorrelation`
// calls below are the documented public API for declaring that a value
// crossed a process boundary.
//
// CodeTracer deliberately installs no protocol shims — it does not hook
// `fetch`, `WebAssembly`, or anything else. The program itself declares
// its boundaries, because the program is the only thing that knows
// *which* identifier correlates the two sides.
//
// Value flow through the demo:
//
//   userId / amount (source literals here)
//        -> compute_balance() in WebAssembly        [realm boundary]
//        -> POST /balance to the Node server        [HTTP boundary]
//        -> `balance` local in the server's handler
//
// An origin query on that server-side `balance`, with all three
// recordings loaded as one session, walks the arrows backwards.

import { loadWasm, stopRecording } from "./bootstrap.js";

/** Correlation key for the HTTP boundary; shared with the server. */
const BOUNDARY_HTTP = "account-balance";

/**
 * Compute a balance in WebAssembly and store it on the server.
 *
 * @param {number} userId
 * @param {number} amount
 * @param {string} requestId Correlates this request with the server's
 *   handler; any stable per-request identifier works.
 */
async function submitBalance(userId, amount, requestId) {
  const wasm = await loadWasm();

  // The JS -> WASM crossing needs no marker here: the instrumented
  // module emits realm-boundary tokens itself and the recorder mirrors
  // them onto both recordings automatically.
  const result = wasm.compute_balance(userId, amount);

  // Declare the HTTP crossing.
  //   key      pairs this send with the server's recv
  //   payload  the human-readable label shown on the boundary hop
  //   "result" names the binding the value came from — an origin chain
  //            arriving from the server resumes its walk on that name,
  //            which is what lets it continue back into `compute_balance`
  __ct.markCorrelation("send", BOUNDARY_HTTP, requestId, String(result), "result");

  const response = await fetch("/balance", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ requestId, balance: result }),
  });
  const payload = await response.json();

  const target = document.querySelector("#status");
  if (target !== null) {
    target.textContent = payload.stored === true ? "stored" : "error";
  }
  return payload;
}

// Source literals: these are the terminal leaves of the expected origin
// chain. Kept on their own lines so each has a distinct recorded step.
const userId = 42;
const amount = 100;
const requestId = "req-0001";

submitBalance(userId, amount, requestId)
  .catch((err) => {
    const target = document.querySelector("#status");
    if (target !== null) {
      target.textContent = `error: ${err}`;
    }
  })
  .finally(() => {
    // Finalise both recordings once the exchange is complete. The
    // harness waits for `#status` before closing the page, but flushing
    // explicitly means the trace does not depend on `pagehide` timing.
    stopRecording();
  });
