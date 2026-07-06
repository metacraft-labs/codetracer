// Cross-Tracer Origin E2E — Fixture A' "Account Balance with WASM"
// (three-tracer variant per Cross-Tracer-Origin-Test.audit.md § TCT-M4).
//
// This is the front-end JavaScript entry point. The Vite bundler
// resolves `./balance-calc.wasm` (built from ../wasm-src/lib.rs) and
// instantiates it under the codetracer-js-recorder host, which
// emits a `js-wasm-realm` send marker (M27 ABI + M25 marker family)
// on each `compute_balance` call into WASM and a matching receive
// marker when the WASM export returns.
//
// The HTTP boundary into the Python backend rides on the existing
// HTTP correlation-marker family: the recorder auto-stamps the
// `X-Codetracer-Origin` header from the configured `boundary_id =
// "account-balance-with-wasm"` family and the backend's aiohttp
// recorder hooks pair them by the header value (per
// `codetracer-specs/Trace-Files/Correlation-Markers.md` § 4 — the
// HTTP boundary auto-marker subsection).
//
// The whole point of the fixture is that walking the origin of
// the backend-side `balance` variable hops THREE recordings:
// backend Python → frontend WASM (compute_balance return) →
// frontend JS (the `userId = 42` + `amount = 100` source literals).

// Vite resolves the relative import to the wasm-bindgen JS glue
// emitted under ./pkg/ during `regenerate.sh`.
import init, { compute_balance } from "./pkg/balance_calc.js";

// Source-line literals: these are the two terminal leaves of the
// expected three-trace origin chain (see ../ANSWERS.md § Terminal).
// Keep on dedicated lines so the per-hop source-line resolution
// has a stable column-aware target.
const userId = 42;
const amount = 100;

async function postBalance() {
  // codetracer: send "js-wasm-realm" key=callId show=callId desc="JS->WASM compute_balance call"
  //
  // wasm-bindgen's generated `init()` instantiates the WASM module
  // under the codetracer-js-recorder host; the host's M27 ABI
  // shim wraps every WASM import/export edge with a
  // `__ct_emit_realm_boundary(direction, fn_kind, fn_index, token)`
  // tuple — pair_index() resolves the JS↔WASM crossing from
  // those tuples per the M25 `js-wasm-realm` family.
  await init();
  const result = compute_balance(userId, amount);

  // codetracer: send "account-balance-with-wasm" key=result show=result desc="POST /balance request"
  //
  // The recorder injects the `X-Codetracer-Origin` header from the
  // boundary's match key (the computed `result`) so the backend's
  // recv-side marker pairs deterministically.
  const balance = Number(result);
  const response = await fetch("/balance", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ balance }),
  });
  const payload = await response.json();

  // Render the response so the Vite dev-server smoke is observable
  // and the regenerator can wait for a DOM update before tearing
  // down the browser session.
  const target = document.querySelector("#status");
  if (target !== null) {
    target.textContent = payload.stored === true ? "stored" : "error";
  }
  return payload;
}

// Drive a single request when the module loads. The Playwright /
// headless-browser harness used by regenerate.sh waits for the
// `#status` element to flip to `stored` before closing the page.
postBalance().catch((err) => {
  const target = document.querySelector("#status");
  if (target !== null) {
    target.textContent = `error: ${err}`;
  }
});
