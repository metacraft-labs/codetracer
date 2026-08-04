# Cross-process origin demo — Account Balance

A small three-tier application — browser JavaScript, in-browser
WebAssembly, and a Node.js HTTP server — recorded three times in one run.
It demonstrates **cross-process value origin**: right-clicking a value in
the server recording and walking its history backwards across two process
boundaries into the browser source expression that produced it.

This directory is both a runnable demo and the fixture the cross-process
tests consume. Nothing in CodeTracer or its recorders special-cases it —
it is ordinary application code using the documented public APIs.

It is meant to be *played with*. You can run the app with no recording at
all, edit any of the three tiers, record it by hand while you drive the
page, or watch snapshots being derived live as the page runs. All of that
is below, in that order.

---

## Quick start

From a CodeTracer dev shell, at the repository root:

```bash
cd <workspace>/codetracer
nix develop .            # or `direnv allow`, if you use direnv

FIXTURE=src/db-backend/tests/fixtures/cross_process/account-balance-with-wasm

# 1. Produce the three recordings + session.toml (~1 minute).
#    Port 8080 is the default and is a popular one; override if taken.
DEMO_BACKEND_PORT=8137 "$FIXTURE/regenerate.sh"

# 2. Open all three as one debugger session.
./src/build-debug/bin/ct replay --trace-folder "$FIXTURE"

# 3. Or just look at the boundary markers, no GUI needed.
./src/build-debug/bin/ct print --filter markers "$FIXTURE/frontend.ct"
```

Step 1 is not optional on a fresh checkout — the recordings are not
committed. It is also usually unnecessary to run by hand: the tests
produce them for themselves through
[`scripts/materialize-recording.sh`](../../../../../../scripts/materialize-recording.sh),
which caches under the gitignored `target/test-recordings/` and re-records
whenever any recorder binary changes. Run it here when you want the
recordings beside the sources to poke at.

| I want to… | Go to |
| --- | --- |
| understand what the app does | [What the application does](#what-the-application-does) |
| run it as a plain web app, no recording | [1. Run it as an ordinary web app](#1-run-it-as-an-ordinary-web-app) |
| change something and see a different number | [2. Play with it](#2-play-with-it) |
| record it while I drive the page myself | [3. Record it by hand](#3-record-it-by-hand) |
| record it in one command | [4. Record it in one command](#4-record-it-in-one-command) |
| open a finished recording | [5. Load the recording](#5-load-the-recording) |
| watch it being derived *while the page runs* | [Live, during recording](#live-during-recording) |
| read the recordings from a terminal | [6. Inspect from the command line](#6-inspect-from-the-command-line) |

---

## What the application does

```
frontend/app.js            userId = 42, amount = 100
     |                          (JS -> WASM realm boundary)
     v
wasm-src/lib.rs            compute_balance(42, 100) -> 620
     |                          (browser -> server HTTP boundary)
     v
backend/server.js          balance = payload.balance  -> 620
```

`compute_balance` is `user_id * 10 + amount * 2`, so `42 * 10 + 100 * 2`
is `620`. The page has no button: loading it runs the whole flow once and
flips `#status` from `pending` to `stored`. Reload to run it again.

Three tiers, three recordings:

| Recording          | Tier                | Recorder                                     |
| ------------------ | ------------------- | -------------------------------------------- |
| `frontend.ct`      | browser JavaScript  | `@codetracer/vite-plugin` -> `ct record-web`  |
| `frontend-wasm.ct` | in-browser WASM     | `ct-instrument` -> `ct record-web`            |
| `backend.ct`       | Node.js HTTP server | `codetracer-js-recorder record` (CTFS)        |

`session.toml` binds all three into a single debugger session.

### Layout

```
backend/server.js        the Node tier; serves ONE request, then exits
frontend/app.js          the page's JavaScript; the tier a user would write
frontend/bootstrap.js    installs window.__ct and the WASM recorder;
                         deliberately excluded from instrumentation
frontend/index.html      loads app.js as a module; the whole UI
frontend/vite.config.js  the integration point — the plugin as a plain
                         Vite plugin, plus the dev/preview proxy
frontend/drive.mjs       headless-Chromium driver used by regenerate.sh
wasm-src/lib.rs          the WebAssembly tier (Rust cdylib, no wasm-bindgen)
regenerate.sh            the whole recording pipeline, one command
stream-snapshots-demo.sh the live-streaming check (see below)
session.toml[.template]  the three-recording session manifest
ANSWERS.md               what the recordings actually contain
```

---

## Prerequisites

Everything below is in the CodeTracer dev shell except the sibling repos'
build outputs, which you build once:

| Need | Check / build |
| --- | --- |
| `cargo` with the `wasm32-unknown-unknown` target | `rustc --print target-list \| grep -x wasm32-unknown-unknown` |
| `node` / `npx` | `node --version` (22.x in the dev shell) |
| `codetracer-js-recorder` built | `just build` in `../codetracer-js-recorder` — produces `packages/cli/dist/index.js` |
| `ct-instrument` built | `cargo build --release -p ct-instrument-cli` in `../codetracer-wasm-instrumenter` |
| `session-manager` built | `cargo build` in `src/backend-manager`, or `just build-once` |
| Playwright + a Chromium | `npm install` in `frontend/`; the dev shell sets `PLAYWRIGHT_BROWSERS_PATH` |
| the `ct` binary (GUI/CLI) | `just build-once` — produces `src/build-debug/bin/ct` |
| `wazero-snapshots` (live streaming only) | `just build-snapshots` in `../codetracer-wasm-recorder` |

`regenerate.sh` and `stream-snapshots-demo.sh` both check all of these up
front and exit `75` with the list of what is missing, rather than emitting
a placeholder recording.

**Ports.** The demo uses four, all overridable, and all bound on
`127.0.0.1`:

| Port | Default | Variable | Used by |
| --- | --- | --- | --- |
| backend | `8080` | `DEMO_BACKEND_PORT` | `backend/server.js` |
| Vite dev server | `5173` | `DEMO_DEV_PORT` | `npx vite` |
| Vite preview | `4173` | `DEMO_PREVIEW_PORT` | `npx vite preview` |
| recording daemon | `9230` | `DEMO_RECORD_WEB_PORT` | `session-manager record-web` |

`8080` is a popular port. If something already holds it, set
`DEMO_BACKEND_PORT` — every command below is shown with `8137`, which is
what this fixture's authors use.

---

## 1. Run it as an ordinary web app

No recording, no CodeTracer daemon. This is the "what *is* this thing"
step.

The page still needs the WebAssembly module and its manifest sidecar
(`bootstrap.js` imports the manifest statically), so build those first:

```bash
cd src/db-backend/tests/fixtures/cross_process/account-balance-with-wasm

# Build the WASM tier and produce frontend/balance_calc.wasm{,.manifest.json}.
( cd wasm-src && cargo build --target wasm32-unknown-unknown )
../../../../../../../codetracer-wasm-instrumenter/target/release/ct-instrument \
  wasm-src/target/wasm32-unknown-unknown/debug/balance_calc.wasm \
  --output   frontend/balance_calc.wasm \
  --manifest frontend/balance_calc.wasm.manifest.json \
  --source-path wasm-src/lib.rs
```

which prints:

```
ct-instrument: recovered 1904 DWARF line rows, 2846 function declarations
ct-instrument: wasm-src/target/wasm32-unknown-unknown/debug/balance_calc.wasm -> frontend/balance_calc.wasm (manifest: frontend/balance_calc.wasm.manifest.json)
```

Now start the two servers, in two terminals.

**Terminal A — the backend.** `server.js` calls `__ct.markCorrelation`
unconditionally, because that call is the whole point of the file: it is
the public API by which a program declares a boundary crossing. Outside a
recorder there is no `__ct`, so plain `node backend/server.js` dies with
`ReferenceError: __ct is not defined`. Supply a no-op:

```bash
DEMO_BACKEND_PORT=8137 node \
  -e 'globalThis.__ct = { markCorrelation() {} }; require("./backend/server.js")'
# demo backend listening on http://127.0.0.1:8137
```

**Terminal B — the page.**

```bash
cd frontend
npm install                       # first time only
DEMO_BACKEND_PORT=8137 npx vite --host 127.0.0.1
#   ➜  Local:   http://127.0.0.1:5173/
```

`--host 127.0.0.1` is worth passing: Vite otherwise binds `localhost`,
which on a dual-stack machine is `[::1]` only, and `http://127.0.0.1:5173`
is refused.

Open <http://127.0.0.1:5173/> in any browser. The page shows

```
Account Balance
Status: stored
```

The DevTools console will show two failed WebSocket connections to
`ws://127.0.0.1:9230/ct-stream`. That is expected and harmless: the
recorder runtimes dial the daemon, and a page that cannot reach one still
loads and runs. It is also the reason a mis-set `DEMO_RECORD_WEB_PORT`
produces an *empty* recording directory rather than an error. The one
other console error, a 404, is `/favicon.ico`; the demo ships no icon.

**The backend serves exactly one request and then exits** (`server.close()`
in the request handler, so the recorder can seal its trace on a normal
process exit). Reloading the page a second time leaves `#status` on
`pending` — restart Terminal A before each run.

---

## 2. Play with it

The interesting inputs are three source literals near the bottom of
`frontend/app.js`:

```js
const userId = 42;
const amount = 100;
const requestId = "req-0001";
```

and the arithmetic in `wasm-src/lib.rs`:

```rust
fn loyalty_bonus(user_id: u32) -> u32 { user_id * 10 }
fn amount_credit(amount: u32) -> u32  { amount * 2 }
```

Change either and the balance the server stores changes with it. What you
have to rebuild depends on which tier you touched:

| Edited | Rebuild |
| --- | --- |
| `frontend/app.js`, `frontend/index.html` | nothing — the dev server re-transforms on the fly; reload the page |
| `wasm-src/lib.rs` | `cargo build --target wasm32-unknown-unknown` in `wasm-src/`, then re-run `ct-instrument` as in step 1, then reload |
| `backend/server.js` | restart the Node process |
| anything, when serving with `vite preview` | `npx vite build` in `frontend/` |

Every reload also needs a fresh backend, since the old one exited after
the one request it served.

Watch the exchange in the browser's Network tab: one `POST /balance` with
`{"requestId":"req-0001","balance":620}`, answered with
`{"stored":true,"balance":620}`.

> **After you edit one of these files.** The recordings reference the
> exact source lines, and the tests assert against them —
> `cross-tracer-three-recording.spec.ts` and
> `cross_process_three_trace_dap_test.rs` both locate
> `const balance = payload.balance` by searching `backend/server.js`
> rather than hard-coding its line, so an edit moves them silently.
> The recordings themselves need no action: an edit changes the
> cache key of `materialize-recording.sh` and the next test run records again. Refresh
> [`ANSWERS.md`](ANSWERS.md), which is prose and cannot re-derive itself.

---

## 3. Record it by hand

This is what `regenerate.sh` automates. Doing it by hand is worth it once,
because it is the only way to drive the page yourself — open DevTools,
watch the requests, take as long as you like — and still get recordings
out. (One run per backend, still: to record a second exchange, restart
Terminal B.)

Four terminals, all starting from the fixture directory. Pick the scratch
directory first and export it into each terminal:

```bash
cd <workspace>/codetracer/src/db-backend/tests/fixtures/cross_process/account-balance-with-wasm
export OUT=$(mktemp -d)   # recordings land here, NOT in the fixture
echo "$OUT"               # ...and paste that into the other terminals
```

**Terminal A — the recording daemon.** One `.ct` directory per browser
recorder connection; this page opens two.

```bash
../../../../../backend-manager/target/debug/session-manager record-web \
  --bind 127.0.0.1:9230 \
  --out-dir "$OUT/recordings" \
  --workdir "$PWD"
# codetracer browser-stream host listening on ws://127.0.0.1:9230/ct-stream
```

(The dev shell also puts a `session-manager` on `PATH`, from
`src/build-debug/bin`. The explicit path above is the one `regenerate.sh`
prefers, and it works whether or not you are in the shell.)

**Terminal B — the backend, under its recorder.** No `__ct` stub this
time: the recorder installs the real one.

```bash
DEMO_BACKEND_PORT=8137 node \
  ../../../../../../../codetracer-js-recorder/packages/cli/dist/index.js record \
  --out-dir "$OUT/backend" \
  ./backend/server.js
# demo backend listening on http://127.0.0.1:8137
```

**Terminal C — the page.** Build it first: both ports are **build-time**
inputs. A browser bundle cannot read the environment, and both recorder
runtimes resolve their WebSocket endpoint once, at construction, so
`vite.config.js` bakes `DEMO_RECORD_WEB_PORT` in through a `define` and
`bootstrap.js` reads it. Change either port and rebuild, or the page keeps
dialling the previous one.

```bash
cd frontend
DEMO_BACKEND_PORT=8137 DEMO_RECORD_WEB_PORT=9230 npx vite build
DEMO_BACKEND_PORT=8137 npx vite preview --host 127.0.0.1 --port 4173
#   ➜  Local:   http://127.0.0.1:4173/
```

**Terminal D — you.** Open <http://127.0.0.1:4173/>, watch `#status` go to
`stored`. The page closes both browser recordings itself, in its own
`finally` block, so there is nothing to press. Terminal A logs:

```
browser-stream writer: manifest accepted (1 path(s), 4 function(s), 41 site(s))
browser-stream writer: manifest accepted (2 path(s), 4 function(s), 4 site(s))
browser-stream host: recording persisted to .../frontend-wasm.ct
browser-stream host: recording persisted to .../frontend.ct
```

Then stop the daemon with **Ctrl-C** (Terminal A). Terminal B's server has
already exited on its own after the single request.

**Collect the three recordings into one session:**

```bash
cd <the fixture directory>
SESSION=$(mktemp -d)
cp -R "$OUT/recordings/frontend.ct" "$OUT/recordings/frontend-wasm.ct" "$SESSION/"
cp -R "$OUT"/backend/trace-*                                            "$SESSION/backend.ct"
sed -e "s|{{frontend_js_recording_id}}|$(uuidgen)|" \
    -e "s|{{frontend_wasm_recording_id}}|$(uuidgen)|" \
    -e "s|{{backend_recording_id}}|$(uuidgen)|" \
    session.toml.template > "$SESSION/session.toml"

<workspace>/codetracer/src/build-debug/bin/ct replay --trace-folder "$SESSION"
```

`session.toml`'s `path` entries are relative, so any directory holding the
three `.ct`s plus the manifest is a valid session — which is what lets the
recordings live in the `materialize-recording.sh` cache while the sources stay here.
(`regenerate.sh` stamps fixed recording ids into `session.toml` rather than
fresh UUIDs, so `ANSWERS.md` and the tests can name them.)

### Recording through the dev server: works, but loses source lines

You *can* point the recorders at `npx vite` instead of `vite preview` —
the page records and both `.ct` directories appear. But the JavaScript
recording lands on `<browser>` with placeholder function names:

```
$ cat frontend.ct/trace_paths.json
["<browser>"]                          # dev server
["…/frontend/app.js"]                  # vite build + preview
```

The reason is in the daemon's own log — `manifest accepted (0 path(s), 0
function(s), 0 site(s))`. The Vite plugin accumulates its site manifest as
it transforms modules and bakes the finished table into the HTML at
`generateBundle`; on the dev server modules are transformed lazily, so the
table injected at page load is still empty. The WASM recording is
unaffected, because its manifest comes from `ct-instrument` rather than
from the plugin.

So: dev server for playing with the app, `vite build` + `vite preview` for
a recording you intend to debug.

---

## 4. Record it in one command

```bash
cd <workspace>/codetracer
DEMO_BACKEND_PORT=8137 \
  ./src/db-backend/tests/fixtures/cross_process/account-balance-with-wasm/regenerate.sh
```

The script runs the five stages of section 3 — build and instrument the
WASM tier, build the browser bundle through the Vite plugin, start the
daemon and the recorded Node server, drive the page once in headless
Chromium, collect the recordings and stamp `session.toml` — and finishes
with:

```
[regenerate] done:
    .../account-balance-with-wasm/frontend.ct
    .../account-balance-with-wasm/frontend-wasm.ct
    .../account-balance-with-wasm/backend.ct
    .../account-balance-with-wasm/session.toml
```

It refuses to run rather than emit anything fake: a missing prerequisite
exits `75` (`EX_TEMPFAIL`) with a list of what to install, and a stage that
runs and fails exits `1`. There is no path that produces a placeholder
recording.

A port collision is checked **before** anything is deleted:

```
[regenerate] 127.0.0.1:8080 is already in use.
[regenerate] Stop the process holding it (or set DEMO_BACKEND_PORT) and re-run.
[regenerate] Nothing was written or deleted.
```

Useful overrides:

| Variable | Purpose |
| --- | --- |
| `DEMO_BACKEND_PORT` | server port (default `8080`) |
| `DEMO_PREVIEW_PORT` | `vite preview` port (default `4173`) |
| `DEMO_RECORD_WEB_PORT` | recording daemon port (default `9230`) |
| `DEMO_HEADFUL=1` | show the browser instead of running headless |
| `DEMO_BACKEND_TIMEOUT_MS` | backend idle timeout before it gives up (default `120000`) |
| `CT_INSTRUMENT_BIN` | explicit path to `ct-instrument` |
| `CODETRACER_RECORD_WEB_BIN` | explicit path to `session-manager` |
| `CODETRACER_JS_RECORDER_PATH` | explicit path to the `codetracer-js-recorder` checkout |
| `CODETRACER_WASM_INSTRUMENTER_PATH` | explicit path to the `codetracer-wasm-instrumenter` checkout |

### What re-recording changes

`frontend.ct` and `frontend-wasm.ct` are **byte-identical** across runs —
the scripted run and the hand-driven one of section 3 produce the same
bytes. A diff between two runs of the same tree means something really
changed.

`backend.ct` is not byte-stable, and that is not a defect. It has two
sources of per-run variation, neither of which means anything changed:

- the **recording id** in the CTFS metadata block — a fresh UUIDv7 every
  run, and on its own enough to guarantee the container bytes differ;
- the Node async-resource **`thread_id`** carried on the
  `sekThreadStart` / `sekThreadSwitch` steps, which follows whatever ids
  the runtime happened to hand out and may or may not repeat.

So `git status` will show `backend.ct/server.ct` modified after every
regenerate, whether or not anything meaningful changed. Compare the
decoded streams rather than the container bytes to find out which:

```bash
CT_PRINT=../../../../../../../codetracer-trace-format-nim/ct-print

"$CT_PRINT" --events backend.ct/server.ct > /tmp/before.jsonl
DEMO_BACKEND_PORT=8137 ./regenerate.sh
"$CT_PRINT" --events backend.ct/server.ct > /tmp/after.jsonl
diff /tmp/before.jsonl /tmp/after.jsonl
```

An unchanged demo yields a diff that is either empty or confined to
`"thread_id":` — the recording id is not carried in this view, which is
what makes an empty diff the ordinary result here rather than a
suspicious one. Anything else is a real change, and `ANSWERS.md` needs
updating with it.

---

## 5. Load the recording

### After the fact

```bash
cd <workspace>/codetracer
just build-once                       # if the Electron app is not built yet
./src/build-debug/bin/ct replay --trace-folder \
    src/db-backend/tests/fixtures/cross_process/account-balance-with-wasm
```

Either the directory or the `session.toml` inside it may be named; both
open the whole session. `ct host --trace-path <same-path> --port 8791`
does the same for the browser-hosted UI, and prints what it resolved
(`--port` is required, and any free port will do):

```
ct host: importing session manifest: .../account-balance-with-wasm/session.toml
ct host: session .../session.toml resolves to 3 recording(s):
ct host:   018f0000-0000-7000-8000-frontendjs01 (frontend-js)   .../frontend.ct
ct host:   018f0000-0000-7000-8000-frontendwsm1 (frontend-wasm) .../frontend-wasm.ct
ct host:   018f0000-0000-7000-8000-backendnode1 (backend)       .../backend.ct
ct host: opened session .../session.toml
```

What makes this a multi-process session is the manifest, not the
individual recordings: `ct` registers the session folder as one entry in
the recording index, and the replay engine loads every `[[trace]]` behind
a single session (see `src/ct/trace/session_import.nim`).

Once the window is up:

1. The **process tree** lists all three recordings by their manifest
   roles: `frontend-js`, `frontend-wasm`, `backend`. The session opens on
   the first `[[trace]]`, which is `frontend-js`.
2. Click the **`backend`** row. This moves the replay cursor into that
   recording, opens `backend/server.js` in the editor, and repopulates the
   State pane with the server's locals.
3. Reach `const balance = payload.balance;`. Two gestures work: click the
   `handleBalance` frame in the **Call Trace** pane, or press **step
   into** repeatedly from the entry point. *Step over* is the one to
   avoid here — it stalls at the last statement of the top-level module
   and never enters the request handler.
4. Right-click `balance` in the State pane → **Show value origin**.
5. The origin chain crosses the HTTP boundary into `frontend.ct`, then the
   realm boundary into `frontend-wasm.ct`. The panel renders one
   breadcrumb chip per recording — `backend`, `frontend-js`,
   `frontend-wasm`, all three substantive — and the boundary-crossing hop
   carries a badge reading `account-balance`. Clicking a chip switches the
   active process; the chain panel is owned by the session and survives
   the switch.

The chain you should see, read back from a fresh recording:

```
spans:  backend        hops 0..1
        frontend-js    hops 2..2
        frontend-wasm  hops 3..3

hops:   [0] FieldAccess   backend/server.js:72   balance <- payload.balance
        [1] TrivialCopy   backend/server.js:64   payload <- JSON.parse(raw)
        [2] FunctionCall  frontend/app.js:43     result  <- wasm.compute_balance(userId, amount)
        [3] Unknown       wasm-src/lib.rs:71     compute_balance:ret0
```

Three spans, no trailing placeholder. See [`ANSWERS.md`](ANSWERS.md) for
why the walk stops in `frontend-wasm.ct` rather than re-crossing the
boundary it arrived on, and for the empty fourth span this chain used to
carry.

This is covered end to end by
`src/tests/gui/tests/value-origin/cross-tracer-process-tree.spec.ts`
(`origin_chain_panel_spans_all_three_recordings`) and headlessly by
`src/db-backend/tests/cross_process_three_trace_dap_test.rs` (5 tests).
`scripts/test-cross-process.sh` is the CI envelope that runs the lot.

Each of the three directories can also be opened on its own:

```bash
ct replay --trace-folder .../account-balance-with-wasm/frontend.ct
```

### Live, during recording

Snapshots and slices are derived **as the page runs**, not by a pass over
a finished file (design: `Recording-Backends/WASM-Replay-Snapshots-And-Slices.md`
§2, in the internal `codetracer-specs` repo).
`stream-snapshots-demo.sh` demonstrates that end to end:

```bash
cd <workspace>/codetracer
DEMO_BACKEND_PORT=8137 \
  ./src/db-backend/tests/fixtures/cross_process/account-balance-with-wasm/stream-snapshots-demo.sh
```

It starts `record-web` with `--snapshot-consumer`, so each recording's
`trace.json` bytes are teed into a spawned `wazero-snapshots run
--boundary-stream -`, then drives a page that calls `compute_balance`
eight times, two seconds apart. (The demo page calls it once, and one
call is one quiescent point — a slice can only be *sealed* when the next
point opens, so a one-call workload has no intermediate slice to time. The
extra calls are patched into a **scratch copy**; the fixture's own sources
are untouched, and the recorders' flush policy is left at its shipped
defaults.)

Real output from a run on this machine:

```
[stream-demo] consumer stdout:
    replayed 8 exported call(s) and 0 imported call(s) from /tmp/…/frontend-wasm.ct
    wrote 8 slice(s) covering quiescent points 0..8, manifest at /tmp/…/slices/slices.manifest.json
      slice 0: points [0,1], 1 call(s), 2 snapshot(s), 389120 bytes -> frontend-wasm-0000.ct
      slice 1: points [1,2], 1 call(s), 2 snapshot(s), 454656 bytes -> frontend-wasm-0001.ct
      …
      slice 7: points [7,8], 1 call(s), 2 snapshot(s), 454656 bytes -> frontend-wasm-0007.ct

[stream-demo] t=0 is the moment the recording stopped being produced
[stream-demo] slice containers, by the time they were sealed:
    frontend-wasm-0000.ct        t= -15.471s  BEFORE the recording finished
    frontend-wasm-0001.ct        t= -14.058s  BEFORE the recording finished
    frontend-wasm-0002.ct        t= -12.080s  BEFORE the recording finished
    frontend-wasm-0003.ct        t=  -9.860s  BEFORE the recording finished
    frontend-wasm-0004.ct        t=  -8.062s  BEFORE the recording finished
    frontend-wasm-0005.ct        t=  -6.052s  BEFORE the recording finished
    frontend-wasm-0006.ct        t=  -3.871s  BEFORE the recording finished
    frontend-wasm-0007.ct        t=  -2.043s  BEFORE the recording finished

[stream-demo] PASS: 8 of 8 slice container(s) were sealed while the
[stream-demo]       browser was still recording
```

`t = 0` is the mtime of `frontend-wasm.ct/trace.json` — the `]` that closed
its array, i.e. the instant the recording stopped being produced. A
negative offset therefore means the slice existed while the page was still
recording. The exit status is the verdict: `0` if any slice was sealed
early, `1` if none was, `75` if a prerequisite is missing. The extra
prerequisite over `regenerate.sh` is `wazero-snapshots` from
`codetracer-wasm-recorder` — the plain `wazero` binary will not do, since
the snapshot half is behind the `ctsnapshots` build tag.

Nothing this script writes lands in the fixture: the page is built and
served from a scratch copy, and the recordings go to a temporary
directory. (It does populate `wasm-src/target/`, which is `.gitignore`d.)

---

## 6. Inspect from the command line

`ct print` reads every trace shape the demo produces, which is the
quickest way to check whether the boundaries actually paired:

```bash
cd .../account-balance-with-wasm
ct print --filter markers frontend.ct
ct print --filter markers frontend-wasm.ct
ct print --filter markers backend.ct/server.ct
```

Real output:

```
program: frontend
correlation markers: 3

  #  direction  boundary                  key                  step  shown
----------------------------------------------------------------------------------------
  1  send       js-wasm-realm             1                      16  wasm export #1
  2  recv       js-wasm-realm             2                      16  wasm export #1
  3  send       account-balance           req-0001               18  620

program: frontend-wasm
correlation markers: 2

  #  direction  boundary                  key                  step  shown
----------------------------------------------------------------------------------------
  1  recv       js-wasm-realm             1                       2  wasm export #1
  2  send       js-wasm-realm             2                       3  wasm export #1

program: .../account-balance-with-wasm/backend/server.js
correlation markers: 1

  #  direction  boundary                  key                  step  shown
----------------------------------------------------------------------------------------
  1  recv       account-balance           req-0001               48  620
```

The keys line up across recordings: `js-wasm-realm` key `1` is the call
into WebAssembly, key `2` the return from it, and `account-balance` key
`req-0001` the HTTP request. `compute_balance` is the module's only export
and the page calls it once, so the realm keys are just 1 and 2.

A boundary that fails to pair shows up here immediately: a missing marker,
a key that differs between the two sides, or a direction recorded the
wrong way round. Without this view the same failure surfaces only as an
origin chain that stops early, with nothing to explain why.

Other views. `ct` is on `PATH` inside the dev shell; `ct-print` is not —
it lives at `../../../../../../../codetracer-trace-format-nim/ct-print`.

| Command | Shows |
| --- | --- |
| `ct print <trace>` | event-kind counts and the marker total |
| `ct print --format json <trace>` | the fully decoded document |
| `ct-print --markers <f.ct>` | the same marker table, plus `--json-out` |
| `ct-print --meta-json <f.ct>` | program / workdir / feature flags + counts, without decoding the streams |
| `ct-print --events <f.ct>` | JSONL, one event per line — the diff-friendly view |
| `ct-print --full <f.ct>` | pretty JSON with fully decoded values |

Two sharp edges worth knowing:

- **`--filter` only implements `markers`.** The other values `ct print
  --help` names (`calls`, `steps`, `http`, `errors`) fall through to the
  same summary the unfiltered command prints. Use `--format json` or
  `ct-print --events` when you want the stream itself.
- **`ct-print` reads CTFS containers only.** It works on
  `backend.ct/server.ct` and rejects the two materialized browser
  directories with `Error: failed to read file: failed to read CTFS file:
  frontend.ct`. `ct print --verify=on` has the same blind spot from the
  other direction: it reports `PASS` for `backend.ct/server.ct` and a
  spurious `FAIL — Legacy materialized trace … no longer supported` for
  `frontend.ct`, even though `ct print --filter markers` reads that same
  directory perfectly well. Do not read that verdict as a broken
  recording.

---

## How the boundaries are declared

CodeTracer installs **no protocol shims** — it does not hook `fetch`, HTTP
servers, or `WebAssembly`. A program declares its own boundaries, because
only the program knows which identifier correlates the two sides. There
are two boundaries here, declared two different ways:

**HTTP** — explicitly, with the public marker API. The browser records
that a value is leaving; the server records that it arrived. They pair
because both pass the same `requestId`:

```js
// frontend/app.js
__ct.markCorrelation("send", "account-balance", requestId, String(result), "result");
await fetch("/balance", { method: "POST", body: JSON.stringify({ requestId, balance: result }) });

// backend/server.js
__ct.markCorrelation("recv", "account-balance", payload.requestId, String(payload.balance), "balance");
const balance = payload.balance;
```

The trailing argument names the binding the value came from, which is what
lets an origin chain arriving from the other side resume its walk.

**JS ↔ WASM** — automatically. `ct-instrument` rewrites every
import/export edge of the module to emit realm-boundary tokens, and the
host runtime mirrors each crossing onto both recordings. No annotation is
needed in `lib.rs`.

### What the WebAssembly recording contains

The same rewrite records the *values* that cross those edges: every
argument of an exported call, and every value it returns. That is the
whole of what the browser observes — the module's interior is deliberately
not recorded (design: `Recording-Backends/WASM-Instrumentation-Layer.md`
§§ 2–4, in the internal `codetracer-specs` repo).
`compute_balance` computes in locals through two private helpers
and writes nothing to linear memory; the recording contains its two
arguments and its result, attributed to a line of `lib.rs`.

Nothing in `wasm-src/lib.rs` is arranged to suit the recorder, and that is
the point being tested. An earlier version of this demo staged its
computation through a four-slot linear-memory "ledger" so that a
store-instrumenting rewrite would have something to observe. That model is
withdrawn: stores cannot see locals or operand-stack values at all,
*which* values reach memory is decided by the optimiser rather than by the
source, and it was measured at +2955 % runtime against +11 % for boundary
capture. Spec § 11 names the tell — "the demo module has to be rewritten
to keep its values in memory in order for anything to be recorded" — and
this fixture used to be it.

The step-level interior is not lost, only deferred: re-executing the same
`.wasm` against the recorded boundary log reconstructs locals, helper
frames and per-line steps offline (spec § 6). That is exactly what
`wazero-snapshots` does in [Live, during recording](#live-during-recording).

Source locations come from DWARF, read out of the module by
`ct-instrument` — which is why `wasm-src` builds with the `dev` profile:
release LTO discards the line programs.

---

## On-disk shapes of the three recordings

The three recording directories are **not** all the same shape, and that
is deliberate — each carries what its recorder actually writes:

| Directory          | Shape                                    | Contents                                                |
| ------------------ | ---------------------------------------- | ------------------------------------------------------- |
| `backend.ct`       | CTFS container                           | `server.ct` (+ `files/`)                                 |
| `frontend.ct`      | materialized `runtime_tracing` directory | `trace.json`, `trace_metadata.json`, `trace_paths.json`  |
| `frontend-wasm.ct` | materialized `runtime_tracing` directory | `trace.json`, `trace_metadata.json`, `trace_paths.json`  |

The two browser recordings are materialized because that is what `ct
record-web` emits: the browser streams events to the recording daemon,
which writes them out directly rather than sealing a CTFS container. Both
shapes are first-class — the replay engine autodetects them
(`db-backend/src/dap_server.rs::auto_detect_materialized_trace_file`), and
since M41 so does `ct`
(`src/ct/trace/trace_container.nim::detectTraceFolderShape`).

Converting the browser recordings to CTFS was considered and rejected for
this fixture: `db-backend/tests/m25b_event_log_test.rs` reads
`frontend.ct/trace.json` directly (it asserts the path *is a file*), so the
conversion would have had to rewrite a headless test in order to make a
GUI test launch. The `.ct` suffix on the directory names is a naming
convention from `session.toml`, not a claim that each is a container file.

Opening a recording is read-only for the two materialized directories —
the import normalizes the copy in the recording store, not the fixture.
`backend.ct` is the exception: opening it *directly* still writes a
`paths.json` beside `server.ct`, because the CTFS import materializes its
sources in place. That is pre-existing CTFS behaviour, not something the
session path does — opening the session (the folder, or `session.toml`)
writes nothing here — but `git status` after a bare
`ct host --trace-path .../backend.ct` will show the stray file, and it
should be discarded rather than committed.

---

## What is committed, and what is not

**Only the sources.** The three `.ct` directories and `session.toml` are
not committed; nor is anything the build produces (`frontend/node_modules`,
`frontend/dist`, `frontend/package-lock.json`, `wasm-src/target`, the
instrumented `.wasm` and its manifest) — see [`.gitignore`](.gitignore).

They used to be, on the reasoning that re-recording on every CI run would
make the suite depend on a browser and a Rust toolchain. It does, and that
is the price of the tests meaning anything. A recording written by the
current recorders and replayed by the current replayer proves the two agree
with each other, and keeps proving it after a recorder changes underneath
it — the suite goes green about a pipeline that no longer exists. A
recording is worth committing only when it was made by a version that can
no longer be built, which is true of exactly one artefact in this
workspace and is not true of these.

So the tests record instead:
[`scripts/materialize-recording.sh`](../../../../../../scripts/materialize-recording.sh)
runs this directory's `regenerate.sh` once per build (~40 s) into the
gitignored `target/test-recordings/`, under a file lock so every consumer
shares one production, keyed on this fixture's sources **and on the content
of `ct-instrument`, the `record-web` binary, the instrumenter's
`recorder-runtime/` and the JS recorder's built packages**. Rebuild any of
them and the key moves and the demo is recorded again. There is no outcome
that means "skip": a missing prerequisite is a hard failure listing every
gap.

Editing a demo source therefore needs no recording step — the key moves and
the next run records. [`ANSWERS.md`](ANSWERS.md) is prose about what the
recordings contain and does need refreshing by hand.

---

## Related fixtures

Two newer WebAssembly fixtures sit beside `cross_process/`, under
`src/db-backend/tests/fixtures/`. Each has its own `README.md` and a
`verify.sh` that records from the current tree and replays the result;
`just verify-wasm-recordings` runs all of them.
They cover module shapes this demo deliberately cannot:

- [`../../wasm-memory-calldata/`](../../wasm-memory-calldata/) —
  **host-supplied WebAssembly state.** Its module imports its linear
  memory and reads its inputs out of it, so it exercises both host-state
  records the boundary model defines: state written before the first
  exported call, and state written by the host from inside an imported
  call. `compute_balance(user_id, amount)` here is a pure function of two
  scalar arguments and needs neither.
- [`../../wasm-nan-payloads/`](../../wasm-nan-payloads/) — **float NaN
  payloads across the browser boundary.** An `f32` signalling NaN, an
  `f64` payload NaN and `-0.0`: three values a JavaScript `Number` cannot
  carry intact, recorded as integer bit patterns.

<!-- cspell:words mktemp uuidgen TEMPFAIL ctsnapshots frontendjs frontendwsm backendnode -->
