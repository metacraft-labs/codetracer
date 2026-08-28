# The DAP dialect gap: ViewModels vs. the wasm32 replay engine

**Status:** measured 2026-08-29 against the real `db-backend` WASM engine, driven
through `WorkerBackendService` over `src/db-backend/wasm-testing/worker.js` and a
real `.ct` container
(`src/db-backend/tests/fixtures/stylus-fund-trace/stylus_fund_tracking_demo.ct`).
Every row below was reproduced by execution, not by reading.

This file exists because the gap is not one bug. It is a *dialect* difference —
the ViewModel layer and the replay engine each have a coherent, self-consistent
view of the protocol, and they disagree in eight places. Fixing them one at a
time from a bug tracker loses the shape. `backend/dap_commands.nim`'s header
already promises to keep the frontend's command set in sync with
`EVENT_KIND_TO_DAP_MAPPING`; this document is the same promise extended across
the language boundary, to the engine that actually answers.

Reproducers live in `src/db-backend/wasm-testing/node-host/`:

* `probe_engine_defects.mjs` — the four wasm32 traps (§3).
* `worker_backend_wasm_e2e.nim` + `ci/test/worker-backend-wasm-e2e.sh` — the
  19-check end-to-end proof that the transport itself is sound.

Both need a built engine at `src/db-backend/wasm-testing/pkg/`
(`src/db-backend/build_wasm.sh`); that artifact is 18 MB and is not checked in.
Neither reproducer skips when it is absent — they fail and name what is missing.

---

## 1. Handshake order — a hard blocker, and the reason nothing else can be observed

`sdk/debugger_session.nim:377-383` sends:

    initialize -> configurationDone -> launch

The browser engine requires:

    initialize -> launch -> configurationDone

**Why.** `handle_message_browser`'s `configurationDone` arm
(`src/db-backend/src/dap_server.rs:2743-2775`) is the *only* place
`setup_from_vfs` runs, and therefore the only place the `Handler` is ever
constructed — `*handler = Some(h)` at `dap_server.rs:2770` is the single
assignment site in the crate. That arm is guarded by

    if handler.is_none() && !ctx.launch_trace_folder.as_os_str().is_empty()

and `ctx.launch_trace_folder` is populated *only* by the `launch` arm
(`dap_server.rs:2481-2484`). Arriving before `launch`, the guard's second
conjunct is false, the block is skipped silently, and the handler stays `None`
forever.

**Why it is silent.** The `configurationDone` arm delegates to `handle_message`
*first* (`dap_server.rs:2745`), which has already sent `success: true`. So the
SDK's `step()` sees a good response and proceeds. Then every subsequent request
falls to `dap_server.rs:2808-2810`:

    } else {
        warn!("handle_message_browser: no handler yet, dropping {:?}", req.command);
    }

A bare `warn!` — no response, no error, no `Err` return, so `dap.rs`'s
error-to-`success:false` path (`dap.rs:573-599`) is not taken either. The future
never settles. A pane spins forever.

**Measured**, both orders against the same engine:

    --- SDK's order: initialize -> configurationDone -> launch ---
      initialize         -> success=true
      configurationDone  -> success=true
      launch             -> success=true
      POST-HANDSHAKE threads      -> NO RESPONSE, future would hang forever
      POST-HANDSHAKE stackTrace   -> NO RESPONSE, future would hang forever
    --- engine's order: initialize -> launch -> configurationDone ---
      initialize         -> success=true
      launch             -> success=true
      configurationDone  -> success=true
      POST-HANDSHAKE threads      -> success=true items=1
      POST-HANDSHAKE stackTrace   -> success=true items=1

**The native path tolerates both orders; the browser path has neither
tolerance.** Native `launch` checks `ctx.received_configuration_done`
(`dap_server.rs:2516`, `:2533`) and native `configurationDone` replays
`ctx.launch_request` (`dap_server.rs:2580-2584`). Both are structurally inert in
the browser: each is `&&`-chained onto `let Some(to_stable_sender)`, and
`ctx.to_stable_sender` is `None` in the browser — its only assignment is
`dap_server.rs:3189-3190`, inside the native `handle_client`.

**Fix belongs on the frontend side** (swap the two `step` calls), because the
native path already accepts that order.

---

## 2. Wire framing is asymmetric

| direction | shape |
| --- | --- |
| main -> worker | structured-clone **object**; the engine does `JSON::stringify(event.data)` (`dap.rs:544`) |
| worker -> main, DAP traffic | JSON **string** — `post_message(&JsValue::from_str(&json))` (`dap.rs:570`) |
| worker -> main, bootstrap | plain **object**: `wasm-loaded`, `vfs-ack`, `vfs-exists-result`, `trace-loaded`, `trace-load-error`, `worker-error` |
| worker -> main, start | the **bare string** `"ready"` (`lib.rs:298`) |

`vfs-write` additionally carries raw bytes, which JSON cannot represent, so it
never crosses the adapter's text boundary at all.

This is absorbed by `worker_backend.nim`: `deliver` classifies by shape, and
bootstrap traffic is routed to a **separate** `onControl` channel rather than
`onEvent`. That separation is load-bearing — a `vfs-ack` reaching
`dapCommandToEventKind` (`src/frontend/dap.nim:234`) raises `ValueError` and
kills every subsequent reactive effect.

Not a defect. Recorded because it is invisible from either side alone.

---

## 3. Four commands trap the wasm32 engine outright

`SystemTime::now()` is unimplemented on `wasm32-unknown-unknown`; it panics,
which compiles to an `unreachable` trap that kills the whole worker. There is
**no `cfg` guard, feature gate or dependency shim** anywhere: `src/db-backend/Cargo.toml`
carries no `web-time`/`wasm-timer`/`instant` and no `[patch]`.
`src/db-backend/src/vfs.rs:1-11` documents exactly this hazard and works around
it — for the VFS only.

| # | command | trap | consequence |
| --- | --- | --- | --- |
| D1 | `ct/load-locals` | `origin_query.rs:260` | **the State pane cannot work at all** |
| D2 | any step reaching a **trace boundary** | `task.rs:1960` | reverse stepping dies at the ends of the trace |
| D3 | `ct/originChain` | `origin_query.rs:260`/`:266` | Value-Origin-Tracking's query surface |
| D4 | `disconnect` | `dap_server.rs:2613` | **every session teardown** |

**D1's chain is the origin-summary one**, and this is worth stating precisely
because it is easy to get wrong:

    dap_server.rs:2068       Handler::load_locals
    dap_handler.rs:978       build_origin_summary_for_local
    dap_handler.rs:3421/3429 materialized_origin_chain
    dap_handler.rs:2997      Db::origin_chain_inferred_with_metadata
    db.rs:2915               WallClockDeadline::new
    origin_query.rs:260      SystemTime::now()

The guard at `dap_handler.rs:978` is `trace_kind == TraceKind::Materialized`,
which the browser path *always* satisfies (`dap_server.rs:1589-1590`, inside
`setup_from_vfs`). It is **not** reached via `HistoryResult::new` (`task.rs:1416`),
which has the same hazardous body but is dead code — zero callers in the crate —
nor via `db.rs:2519`, which is `load_history`, a different command.

**D2** is `dap_handler.rs:2096` choosing `"beginning"`/`"end"`, then `:2097`
calling `send_notification` -> `Notification::new` (`task.rs:1960`). The blast
radius is wider than stepping: `send_notification` has 13 call sites in
`dap_handler.rs`, including `"No breakpoints were hit!"` (`:3734`) and
`"can't jump to line"` (`:3829`). Reverse stepping **mid-trace works** — the e2e
verifies a real `stepBack` returning to the previously visited line — only the
boundary traps.

**D4 was predicted and is no longer latent.** `BlockTracer.milestones.org` M0's
last deliverable reads: *"`disconnect` busy-waits on an `AtomicBool` only ever
set by the io-transport thread, and `thread::sleep` panics on wasm32 without
atomics. Latent — no test sends `disconnect`."* `WorkerBackend.disconnect` sends
one on every teardown. The browser arm (`dap_server.rs:2779`) delegates to the
native one, which busy-waits at `dap_server.rs:2609-2614` on
`ctx.disconnect_response_written` — set only at `dap_server.rs:3184`, inside the
native sending thread, which does not exist in the browser — so the loop never
exits and `thread::sleep` (`:2613`) traps at
`library/std/src/sys/thread/unsupported.rs:45`.

`WorkerBackend.disconnect` terminates the worker immediately after posting, so
in normal use the adapter *masks* D4. The engine defect is real regardless, and
any consumer that awaits a `disconnect` response hangs.

`Stop::new` (`task.rs:1347`) shares the pattern and is live (called from
`dap_handler.rs:4337`, `event_db.rs:595`). `Instant::now()` — equally unsupported
— appears at `emulator_origin.rs:283`, `omniscient_origin.rs:319`,
`recreator_origin.rs:233`/`:345`.

---

## 4. `ct/load-flow`: the ViewModel sends a payload the engine cannot parse

`viewmodels/flow_vm.nim:357-360` sends

    let args = %*{
      "rrTicks": ticks,
      "flowMode": modeStr,      # $mode -> "fmCall"
    }

The engine wants `CtLoadFlowArguments` (`src/db-backend/src/task.rs:58-64`):

    #[derive(Serialize, Deserialize, Debug, PartialEq, Default, Clone, JsonSchema)]
    #[serde(rename_all = "camelCase")]
    pub struct CtLoadFlowArguments {
        pub flow_mode: FlowMode,
        pub location: Location,
    }

Three separate disagreements:

1. **`flowMode` encoding.** Rust's `FlowMode` (`task.rs:49-56`) derives
   `Deserialize_repr` with `#[repr(u8)]` — it accepts a JSON **number only**. The
   string `"fmCall"` fails with *invalid type: string, expected variant index*.
2. **`location` is required**, not `Option`. No `#[serde(default)]` at container
   or field level.
3. **`rrTicks` is at the wrong level.** The struct does not declare it; the real
   tick lives *inside* `Location` (`task.rs:400`). There is no
   `deny_unknown_fields` here, so the top-level `rrTicks` is silently discarded.

**The vocabularies also differ in size:** Rust `FlowMode` is `Call | Diff`;
Nim's (`flow_vm.nim:50-54`) is `fmCall | fmLine | fmFunction`. Two of Nim's three
have no Rust counterpart even once the encoding is fixed.

`flow_vm.nim:170` sends the same stringified mode for `ct/flow-jump`.
`flow_vm.nim:341-343` already documents the mismatch in a comment.

**Measured:** `{"flowMode": 0, "location": {...}}` succeeds and additionally
emits `ct/updated-flow` as an unsolicited event. The Rust side's own test agrees
(`src/db-backend/tests/leo_search_calltrace_test.rs:159` sends `"flowMode": 0`).

---

## 5. `drainPlatformCallbacks()` cannot observe a real async transport on JS

`nim_everywhere/async_compat.onComplete` routes through the drainable
`pendingCallbacks` queue **only** when the future carries a `__syncResolved` /
`__syncFailed` marker — and those markers are written at exactly three sites, all
inside `newCompletedFuture` / `newFailedFuture`, always at construction. A future
built by `newPromise` and resolved later — which is what any genuinely
asynchronous transport produces — falls to the `else:` arm and is observed by a
real `.then` microtask that a synchronous drain cannot pump.

**Consequence.** `DebuggerSession.launch` (`sdk/debugger_session.nim:353-386`)
calls `drainPlatformCallbacks()` after each handshake step and then:

    if not handshakeFailed and s.phase.val == dspLaunching:
      s.markReady(trace)

Against `worker_backend.nim` (`newPromise`, `:159-162`) or `real_backend.nim`
(`newPromise`, `:89`), the drains observe nothing, `handshakeFailed` stays
`false`, and `markReady` runs unconditionally. CodeTracer-Embed-SDK.md §6.3's
error taxonomy is inert against a real backend.

**This is the second time this exact site has been wrong, for two different
reasons.** Commit `caaea86c` — *"fix(sdk): drain platform callbacks per handshake
step so launch sees refusals"* — added the drain to fix the *synchronously
resolved* case, which is `mock_backend.nim`'s (`newCompletedFuture`, `:128`,
`:141`, `:143`). Every suite that exercises `launch` today drives the mock, so
the fix was complete for everything under test and incomplete for everything in
production.

One nuance: `worker_backend.nim:148` returns `newCompletedFuture` on the
disconnected / worker-failed path, so *that* failure mode is still drainable. It
is only responses that actually cross the wire that are not.

---

## 6. `TraceSource`'s browser kinds are unimplemented on the engine

`sdk/trace_source.nim:181-206`'s `toLaunchArgs` emits:

| kind | payload |
| --- | --- |
| `tskLocalFolder` | `{"traceFolder": ...}` — **the only one that works** |
| `tskHttpRange` | `{"traceSource": {"kind": "http-range", "url": ...}}` |
| `tskOpfs` | `{"traceSource": {"kind": "opfs", "path": ...}}` |
| `tskBytes` | `{"traceSource": {"kind": "bytes", "byteLength": ...}}` |
| `tskCustom` | `{"traceSource": {"kind": "custom", "name": ...}}` |

`LaunchRequestArguments` (`src/db-backend/src/dap.rs:31-73`) has no `traceSource`
field, and a repo-wide grep for `traceSource`/`trace_source` across
`src/db-backend/src` returns **zero** hits. The concept does not exist in the
engine.

**Correction to an earlier reading of this defect, which matters for the fix.**
`dap.rs:30` *does* carry `#[serde(deny_unknown_fields)]`. So a browser-kind
launch does **not** deserialize to all-`None` and silently no-op. It hard-fails
at deserialization:

* on the **browser** path, `dap.rs:573-597` synthesises a `success: false`
  response carrying `unknown field 'traceSource'` — which is the *good* outcome,
  because it is legible;
* on the **native** path, `dap_server.rs:3314-3317` logs and swallows the `Err`,
  emitting no response at all, so the future hangs.

The silent-success hazard is real but reached by a *different* input: a launch
carrying neither `traceFolder` nor `program` skips both `if let` branches
(`dap_server.rs:2480`, `:2522`) and still falls through to `success: true` at
`dap_server.rs:2550`.

`tests/unit/test_sdk_facade.nim:160-162` pins the `traceSource` wire form against
no backend at all, which is why the gap survived.

---

## 7. Nine commands the ViewModels send exist in no mapping table

Absent from **both** `backend/dap_commands.nim` and `EVENT_KIND_TO_DAP_MAPPING`
(`src/frontend/dap.nim:69-186`) — and, as it turns out, from the Rust dispatch
tables too, so they have no engine implementation at all:

| command | send site |
| --- | --- |
| `ct/jump-location` | `viewmodels/errors_vm.nim:129`, `viewmodels/search_results_vm.nim:179` |
| `ct/load-step-lines` | `viewmodels/step_list_vm.nim:170` |
| `ct/line-step-jump` | `viewmodels/step_list_vm.nim:186` |
| `ct/asm-instruction-jump` | `viewmodels/low_level_code_vm.nim:202` |
| `ct/build-cancel` | `viewmodels/build_vm.nim:177` |
| `ct/load-recent-trace` | `viewmodels/welcome_screen_vm.nim:620` |
| `ct/load-recent-folder` | `viewmodels/welcome_screen_vm.nim:629` |
| `ct/launch-config` | `viewmodels/welcome_screen_vm.nim:661` |
| `ct/new-record` | `viewmodels/welcome_screen_vm.nim:689` |

This is precisely the drift `dap_commands.nim`'s header says the module exists to
prevent, and the file already records one prior instance (`ct/listProcesses`, at
`dap_commands.nim:102-106`). It survives because all nine are exercised only
through `mock_backend`, which does not validate against `VALID_DAP_COMMANDS`.
Against a real adapter, an unlisted string reaches `dapCommandToEventKind`
(`src/frontend/dap.nim:234`) and raises `ValueError`.

---

## 8. What is *not* a DAP command, contrary to a plausible grep

`flow`, `sources`, `source`, `origin-patterns`, `codetracer-bundled-sources` and
`sourcemap-translate` are **not** commands. They have no arm in either dispatch
table and no ViewModel sends them. In `dap_handler.rs` they are:

| string | what it actually is |
| --- | --- |
| `"flow"` | a replay-worker **task name** (`dap_handler.rs:1141`, `RecreatorReplaySession::new(name, ...)`) |
| `"sources"` | a **path component**, `meta_dat/sources` (`dap_handler.rs:3191`) |
| `"source"` | a **default literal** in `sanitize_view_name` (`dap_handler.rs:6248`) |
| `origin-patterns` | **path components**, `origin-patterns.toml` (`:62`, `:72`) and `meta_dat/origin-patterns` (`:3303`) |
| `codetracer-bundled-sources` | a **temp-dir path component** (`dap_handler.rs:3246`) |
| `sourcemap-translate` | a **cache-dir path component** (`dap_handler.rs:6201`) |

A related note for anyone navigating this code: **there is no dispatch table in
`dap_handler.rs` at all.** Both live in `dap_server.rs` — `handle_request`
(`:2043`, the full command table) and `handle_message_browser` (`:2676`, which
handles only `initialize`/`launch`/`configurationDone`/`disconnect` and delegates
everything else to `handle_request` at `:2787`). `dap_handler.rs` holds the
handler *methods* those arms call.

---

## Summary: what blocks a transaction page loading the debugger

| # | gap | side to fix | blocking? |
| --- | --- | --- | --- |
| 1 | handshake order | frontend (swap two lines) | **yes — nothing works without it** |
| 3-D1 | `ct/load-locals` traps | engine | **yes — State pane** |
| 3-D2 | boundary step traps | engine | degrades stepping |
| 3-D3 | `ct/originChain` traps | engine | Value-Origin-Tracking only |
| 3-D4 | `disconnect` traps | engine | teardown; masked by the adapter |
| 4 | `ct/load-flow` payload | frontend + shared vocabulary | **yes — Flow pane** |
| 5 | `drainPlatformCallbacks` | `nim-everywhere` or the SDK | error taxonomy inert |
| 6 | `TraceSource` browser kinds | engine (or drop the kinds) | blocks non-folder loading |
| 7 | nine unmapped commands | frontend | latent `ValueError` |

§2 and §8 are recorded facts, not defects.
