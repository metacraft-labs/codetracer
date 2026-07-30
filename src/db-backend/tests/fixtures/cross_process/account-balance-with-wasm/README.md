# Cross-process origin demo — Account Balance

A small three-tier application, recorded three times in one run, that
demonstrates **cross-process value origin**: right-clicking a value in
the server recording and walking its history backwards across two
process boundaries into the browser source expression that produced it.

This directory is both a runnable demo and the fixture the cross-process
tests consume. Nothing in CodeTracer or its recorders special-cases it —
it is ordinary application code using the documented public APIs.

## What the application does

```
frontend/app.js            userId = 42, amount = 100
     |                          (JS -> WASM realm boundary)
     v
wasm-src/lib.rs            compute_balance(42, 100) -> 620
     |                          (JS -> server HTTP boundary)
     v
backend/server.js          balance = payload.balance  -> 620
```

Three tiers, three recordings:

| Recording          | Tier                | Recorder                                     |
| ------------------ | ------------------- | -------------------------------------------- |
| `frontend.ct`      | browser JavaScript  | `@codetracer/vite-plugin` -> `ct record-web`  |
| `frontend-wasm.ct` | in-browser WASM     | `ct-instrument` -> `ct record-web`            |
| `backend.ct`       | Node.js HTTP server | `codetracer-js-recorder record` (CTFS)        |

`session.toml` binds all three into a single debugger session.

## How the boundaries are declared

CodeTracer installs **no protocol shims** — it does not hook `fetch`,
HTTP servers, or `WebAssembly`. A program declares its own boundaries,
because only the program knows which identifier correlates the two
sides. There are two boundaries here, declared two different ways:

**HTTP** — explicitly, with the public marker API. The browser records
that a value is leaving; the server records that it arrived. They pair
because both pass the same `requestId`:

```js
// frontend/app.js
__ct.markCorrelation("send", "account-balance", requestId, String(result));
await fetch("/balance", { method: "POST", body: JSON.stringify({ requestId, balance: result }) });

// backend/server.js
__ct.markCorrelation("recv", "account-balance", payload.requestId, String(payload.balance));
const balance = payload.balance;
```

**JS ↔ WASM** — automatically. `ct-instrument` rewrites every
import/export edge of the module to emit realm-boundary tokens, and the
host runtime mirrors each crossing onto both recordings. No annotation
is needed in `lib.rs`.

The same rewrite records the *values* that cross those edges: every
argument of an exported call, and every value it returns. That is the
whole of what the browser observes — the module's interior is
deliberately not recorded (see
[`WASM-Instrumentation-Layer.md`](../../../../../../../codetracer-specs/Recording-Backends/WASM-Instrumentation-Layer.md)
§§ 2–4). `compute_balance` computes in locals through two private
helpers and writes nothing to linear memory; the recording contains its
two arguments and its result, attributed to a line of `lib.rs`.

Nothing in `wasm-src/lib.rs` is arranged to suit the recorder, and that
is the point being tested. An earlier version of this demo staged its
computation through a four-slot linear-memory "ledger" so that a
store-instrumenting rewrite would have something to observe. That model
is withdrawn: stores cannot see locals or operand-stack values at all,
*which* values reach memory is decided by the optimiser rather than by
the source, and it was measured at +2955 % runtime against +11 % for
boundary capture. Spec § 11 names the tell — "the demo module has to be
rewritten to keep its values in memory in order for anything to be
recorded" — and this fixture used to be it.

The step-level interior is not lost, only deferred: re-executing the
same `.wasm` against the recorded boundary log reconstructs locals,
helper frames and per-line steps offline (spec § 6).

Source locations come from DWARF, read out of the module by
`ct-instrument` — which is why `wasm-src` builds with the `dev` profile:
release LTO discards the line programs.

## Producing the recordings

```bash
cd <workspace>/codetracer
nix develop .          # or your usual dev shell
./src/db-backend/tests/fixtures/cross_process/account-balance-with-wasm/regenerate.sh
```

The script builds the WASM tier, instruments it, builds the browser
bundle through the Vite plugin, starts the recording daemon and the
recorded Node server, drives the page once in headless Chromium, and
writes the three `.ct` directories plus `session.toml`.

It refuses to run rather than emit anything fake: a missing prerequisite
exits `75` with a list of what to install, and a stage that runs and
fails exits `1`. There is no path that produces a placeholder recording.

Prerequisites (all present in the codetracer dev shell):

- `cargo` with the `wasm32-unknown-unknown` target
- `node` / `npx`
- `codetracer-js-recorder` built (`just build` in that repo)
- `ct-instrument` built (`cargo build --release -p ct-instrument-cli`)
- `session-manager` built (`cargo build` in `src/backend-manager`)
- Playwright (installed into `frontend/` on first run)

Useful overrides:

| Variable                            | Purpose                                    |
| ----------------------------------- | ------------------------------------------ |
| `DEMO_BACKEND_PORT`                 | server port (default `8080`)                |
| `DEMO_PREVIEW_PORT`                 | `vite preview` port (default `4173`)        |
| `DEMO_RECORD_WEB_PORT`              | recording daemon port (default `9230`)      |
| `DEMO_HEADFUL=1`                    | show the browser instead of running headless |
| `CT_INSTRUMENT_BIN`                 | explicit path to `ct-instrument`            |
| `CODETRACER_RECORD_WEB_BIN`         | explicit path to `session-manager`          |

The default backend port is a popular one; if something else on your
machine already holds it the script says so and stops rather than
recording a server that never bound.

`DEMO_BACKEND_PORT` and `DEMO_RECORD_WEB_PORT` are both **build-time**
inputs to the browser bundle, not just run-time ones — a page cannot
read the environment, and the recorder runtimes resolve their WebSocket
endpoint once, at construction. `vite.config.js` bakes both in, which is
why `regenerate.sh` passes them to `vite build` as well as to the
processes. If you drive the pipeline by hand, rebuild the bundle after
changing either, or the page will keep dialling the previous port —
and a page that cannot reach the daemon still loads and runs, so the
symptom is an empty `record-web` output directory rather than an error.

## Loading it in the CodeTracer GUI

```bash
cd <workspace>/codetracer
just build-once                       # if the Electron app is not built yet
./src/build-debug/bin/ct replay --trace-folder \
    src/db-backend/tests/fixtures/cross_process/account-balance-with-wasm
```

Either the directory or the `session.toml` inside it may be named; both
open the whole session. `ct host --trace-path <same-path>` does the same
for the browser-hosted UI. What makes this a multi-process session is
the manifest, not the individual recordings: `ct` registers the session
folder as one entry in the recording index, and the replay engine loads
every `[[trace]]` behind a single session (see
`src/ct/trace/session_import.nim`). Once it opens:

1. The **process tree** lists all three recordings by their manifest
   roles: `frontend-js`, `frontend-wasm`, `backend`.
2. Select the `backend` process and open `backend/server.js`.
3. Step to the `const balance = payload.balance;` line.
4. Right-click `balance` in the State pane → **Show value origin**.
5. The origin chain crosses the HTTP boundary into `frontend.ct`,
   then the realm boundary into `frontend-wasm.ct`, rendering one
   breadcrumb chip per recording. Clicking a chip switches the active
   process; clicking a hop navigates to its source line.

## Inspecting the recordings from the command line

`ct print` reads every trace shape the demo produces, which is the
quickest way to check whether the boundaries actually paired:

```bash
ct print --filter markers frontend.ct
ct print --filter markers frontend-wasm.ct
ct print --filter markers backend.ct/server.ct
```

Expected output — note how the keys line up across recordings:

```
frontend.ct        send js-wasm-realm   key=1           # into compute_balance
                   recv js-wasm-realm   key=2           # back from it
                   send account-balance key=req-0001    # to the server
frontend-wasm.ct   recv js-wasm-realm   key=1
                   send js-wasm-realm   key=2
backend.ct         recv account-balance key=req-0001
```

`compute_balance` is the module's only export and the page calls it
once, so the realm keys are just 1 and 2.

A boundary that fails to pair shows up here immediately: a missing
marker, a key that differs between the two sides, or a direction
recorded the wrong way round. Without this view the same failure
surfaces only as an origin chain that stops early, with nothing to
explain why.

Other views: `ct print <trace>` for a summary, `ct print --format json
<trace>` for the fully decoded document, and `ct-print --markers` /
`--full` / `--events` from `codetracer-trace-format-nim` for the same
data with more options.

## On-disk shapes of the three recordings

The three recording directories are **not** all the same shape, and that
is deliberate — each carries what its recorder actually writes:

| Directory          | Shape                                    | Contents                                                     |
| ------------------ | ---------------------------------------- | ------------------------------------------------------------ |
| `backend.ct`       | CTFS container                           | `server.ct` (+ `files/`)                                      |
| `frontend.ct`      | materialized `runtime_tracing` directory | `trace.json`, `trace_metadata.json`, `trace_paths.json`        |
| `frontend-wasm.ct` | materialized `runtime_tracing` directory | `trace.json`, `trace_metadata.json`, `trace_paths.json`        |

The two browser recordings are materialized because that is what `ct
record-web` emits: the browser streams events to the recording daemon,
which writes them out directly rather than sealing a CTFS container.
Both shapes are first-class — the replay engine autodetects them
(`db-backend/src/dap_server.rs::auto_detect_materialized_trace_file`),
and since M41 so does `ct`
(`src/ct/trace/trace_container.nim::detectTraceFolderShape`), so each of
the three directories can also be opened on its own:

```bash
ct replay --trace-folder .../account-balance-with-wasm/frontend.ct
```

Converting the browser recordings to CTFS was considered and rejected
for this fixture: `db-backend/tests/m25b_event_log_test.rs` reads
`frontend.ct/trace.json` directly (it asserts the path *is a file*), so
the conversion would have had to rewrite a headless test in order to
make a GUI test launch. The `.ct` suffix on the directory names is a
naming convention from `session.toml`, not a claim that each is a
container file.

Opening a recording is read-only for the two materialized directories —
the import normalizes the copy in the recording store, not the fixture.
`backend.ct` is the exception: opening it directly still writes a
`paths.json` beside `server.ct`, because the CTFS import materializes
its sources in place. That is pre-existing CTFS behaviour, not something
the session path does — opening the session (the folder, or
`session.toml`) writes nothing here — but `git status` after a bare
`ct host --trace-path .../backend.ct` will show the stray file, and it
should be discarded rather than committed.

## What is committed

The three `.ct` directories and `session.toml` are committed, so the
tests run without a browser or Rust toolchain. Build intermediates
(`frontend/node_modules`, `frontend/dist`, `wasm-src/target`, the
instrumented `.wasm` and its manifest) are ignored — see `.gitignore`.

Re-run `regenerate.sh` after changing any of the demo's source files,
and commit the refreshed recordings alongside the change: the tests
assert against the source lines these recordings reference, so the two
have to move together.
