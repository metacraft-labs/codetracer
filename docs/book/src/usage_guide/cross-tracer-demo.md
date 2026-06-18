# Cross-Tracer Demo (`account-balance-with-wasm`)

The **cross-tracer demo** is a one-command launcher that opens the
canonical M29 three-trace fixture in the CodeTracer GUI for manual
inspection. The fixture records the same web request through three
independent recorders simultaneously, producing three `.ct` containers
glued together by a `session.toml` manifest. The GUI then lets you
right-click a value in any recording and follow its origin chain
across recording boundaries.

This demo is the user-facing counterpart of the automated
`test-cross-process` envelope: same fixture, same `session.toml`, but
launched interactively so you can chain-walk and switch recordings
yourself instead of asserting against a Playwright script.

## What the demo records

The fixture is a three-tier balance-update flow:

1. **Frontend (JavaScript).** A Vite-built single-page app posts
   `{ balance: N }` to the backend and renders the response. Recorded
   by the codetracer-js-recorder host
   (`browser_stream_receiver`).
2. **Frontend (WASM).** A `wasm-pack`-built Rust module that the
   frontend calls into to format the balance. Recorded by the
   codetracer-wasm-instrumenter shim under the same browser host. The
   `frontend-wasm.ct` and `frontend.ct` files share a realm boundary,
   not an OS-process boundary.
3. **Backend (Python aiohttp).** A small aiohttp server that handles
   `POST /balance` and returns the updated balance. Recorded by the
   codetracer Python recorder.

A single `POST /balance` request flows from the JS frontend, through
the WASM module, across an HTTP boundary into the Python backend, and
back. The `session.toml` manifest binds the three recordings together
with their `frontend-js` / `frontend-wasm` / `backend` role labels and
an eager-mode `[correlation]` section, so the cross-process composer
can index every send/recv marker upfront when the session opens.

The full scenario contract — including the exact `balance` value the
chain should resolve to — lives in the fixture's `ANSWERS.md`.

## How to run it

From the repository root:

```bash
just demo-cross-tracer
```

The recipe is idempotent:

- If the three `.ct` containers are already present, it skips the
  recorder pipeline and launches the GUI immediately.
- If any container is missing, it invokes
  `src/db-backend/tests/fixtures/cross_process/account-balance-with-wasm/regenerate.sh`,
  which materialises all three traces in place. The regenerator is
  honestly gated on its prerequisites (see below) and exits cleanly
  with an actionable diagnostic when any are missing — the recipe
  surfaces the same message.
- If `session.toml` is missing or still carries
  `{{frontend_js_recording_id}}`-style placeholders (e.g. after a
  partial fixture refresh), the recipe stamps fresh UUIDv7s into it
  from `session.toml.template` before launching, mirroring what
  `regenerate.sh` does in its final step.

The launch is `ct replay -t <fixture-dir>/session.toml`, which hands
the manifest to the same DAP session loader the M24 process-tree flow
uses (`src/db-backend/src/session_manifest.rs` +
`session_handler.rs`).

### Prerequisites

The recorder pipeline requires every component below. The recipe
exits with a single consolidated report when any are missing, so the
operator can fill the gaps one by one and re-run:

- `wasm-pack` plus `rustup target add wasm32-unknown-unknown`
- The CodeTracer Python recorder
  (`codetracer_python_recorder` importable from `python3` — shipped
  by the dev shell)
- `browser_stream_receiver` on `PATH` (the codetracer-js-recorder
  host, produced by `just build-once` or the dev shell)
- Playwright in the fixture's `frontend/` directory
  (`npm install playwright`)
- A built `ct` binary (`just build-once`)

These are the same prerequisites
`src/tests/gui/lib/value-origin-fixtures.ts::threeTraceFixtureSkipReason()`
probes for when the Playwright spec
`cross-tracer-three-recording.spec.ts` decides whether to run.

## What to expect in the GUI

Once the Electron window opens:

1. **Process tree.** The left-hand process tree mounts three entries
   labelled by their `role` (`frontend-js`, `frontend-wasm`,
   `backend`) and prefixed with the manifest's
   `default_thread_prefix` (`fe`, `wasm`, `be`). Each entry is
   expandable to its threads.
2. **Switch recordings.** Click any process-tree entry to make that
   recording active. The source pane, calltrace, and state pane all
   switch to that recording's timeline; the other two stay paused at
   their last-inspected step.
3. **Right-click chain walk.** In the backend recording, right-click
   the `balance` variable at the response site and pick **Show value
   origin**. The chain panel renders `CrossProcessSpan` breadcrumb
   chips at every cross-recording hop — one for the HTTP boundary
   between the backend and the JS frontend, one for the realm
   boundary between the JS frontend and the WASM module — terminating
   at the frontend expression that produced the input. Each chip's
   click target seeks the *receiving* recording to the matched
   message-arrival step.
4. **Seek across hops.** Clicking a `CrossProcessSpan` chip flips the
   active recording to the chip's target process and seeks to the
   matched step. The chain panel survives the switch — the breadcrumb
   chips stay in place so you can hop forward and backward through
   the chain without re-querying.

The full step-by-step contract (steps 1-9, including the exact chip
counts and the expected `frontend.js` expression at the terminator)
lives in
`codetracer-specs/Planned-Features/Cross-Tracer-Origin-Test.audit.md`
§ TCT-M5, which the Playwright spec
`src/tests/gui/tests/value-origin/cross-tracer-three-recording.spec.ts`
encodes as a single end-to-end pass/fail. The demo recipe is the
human-driven version of that same scenario.

## Further reading

- [Value Origin Tracking](./value-origin-tracking.md) — single-trace
  and cross-trace chain-walking surfaces (M29 milestone).
- `codetracer-specs/Planned-Features/Cross-Tracer-Origin-Test.audit.md`
  — TCT-M5 acceptance criteria the demo mirrors.
- `codetracer-specs/GUI/Test-Scenarios/Cross-Process-Origin-E2E-Test-Design.md`
  — design notes for the cross-process chain panel surface.
- The fixture sources at
  `src/db-backend/tests/fixtures/cross_process/account-balance-with-wasm/`
  — `frontend/`, `backend/`, `wasm-src/`, and the canonical
  `ANSWERS.md` describing the expected origin chain.
