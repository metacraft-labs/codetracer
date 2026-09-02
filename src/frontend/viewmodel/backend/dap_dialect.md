# The DAP dialect gap: ViewModels vs. the wasm32 replay engine

**Status:** measured 2026-08-29 against the real `db-backend` WASM engine, driven
through `WorkerBackendService` over `src/db-backend/wasm-testing/worker.js` and a
real `.ct` container
(`src/db-backend/tests/fixtures/stylus-fund-trace/stylus_fund_tracking_demo.ct`).
Every row below was reproduced by execution, not by reading.

> **Update (2026-08-29).** Rows 1, 3-D1..D4, 4, 5 and 6 have since been fixed
> and re-measured against a rebuilt engine; the per-row **Status** notes below
> say how, and where the regression test lives. The measurements in each row —
> including §4a's — are preserved as written because they are what the fix was
> verified against, so read them as "what this did", not "what this does".
> Rows 2, 7 and 8 are untouched, and row 7 is still open.
>
> **Added 2026-08-30.** §9 records the **reverse-step-in / reverse-step-out**
> extension, measured the same way. It is not a defect and never was — it is
> the one place the dialect *deliberately* exceeds DAP, and it was the only such
> place with nothing written down.

This file exists because the gap is not one bug. It is a *dialect* difference —
the ViewModel layer and the replay engine each have a coherent, self-consistent
view of the protocol, and they disagree in nine places. Fixing them one at a
time from a bug tracker loses the shape. `backend/dap_commands.nim`'s header
already promises to keep the frontend's command set in sync with
`EVENT_KIND_TO_DAP_MAPPING`; this document is the same promise extended across
the language boundary, to the engine that actually answers.

Reproducers live in `src/db-backend/wasm-testing/node-host/`:

* `probe_engine_defects.mjs` — the four wasm32 traps (§3).
* `probe_reverse_step_in.mjs` — the reverse-direction step vocabulary (§9).
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

**Fixed on the engine side**, not the frontend. Swapping the two `step` calls
would have made this one client work while leaving the engine intolerant of an
order the native path accepts — the next client to send it would rediscover the
same silence. `handle_message_browser` now runs the VFS setup from a shared
`browser_setup_from_vfs_when_ready` called by *both* the `launch` and the
`configurationDone` arm, firing on whichever completes the pair; this is the
browser counterpart of the two native fallbacks quoted above.

The `no handler yet, dropping` arm is gone too: a request that arrives before
the handshake completes is now *answered* `success: false` with a message naming
which halves have been seen. A dropped request was the whole reason this cost a
day to find.

**Status: fixed.** `dap_server.rs::browser_setup_from_vfs_when_ready`. Tests:
`dap_server.rs` `mod browser_handshake` (both orders end-to-end through a real
`setup_from_vfs`; the cases are the `#[test]` fns in that module — run them
rather than counting from here), run with
`cargo test --features browser-transport --lib browser_handshake`.

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
| D2 | any step reaching a **trace boundary** | `task.rs::Notification::new` | reverse stepping dies at the ends of the trace |
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
`setup_from_vfs`). It is **not** reached via `HistoryResult::new` (`task.rs`),
which has the same hazardous body but is dead code — zero callers in the crate —
nor via `db.rs:2519`, which is `load_history`, a different command.

**D2** is `dap_handler.rs:2096` choosing `"beginning"`/`"end"`, then `:2097`
calling `send_notification` -> `Notification::new` (`task.rs`). The blast
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

`Stop::new` (`task.rs`) shares the pattern and is live (called from
`dap_handler.rs:4337`, `event_db.rs:595`). `Instant::now()` — equally unsupported
— appears at `emulator_origin.rs:283`, `omniscient_origin.rs:319`,
`recreator_origin.rs:233`/`:345`.

**Status: fixed, as a class rather than four call sites.** `src/db-backend/src/wall_clock.rs`
is now the crate's only clock, with two functions because there are two needs:
`monotonic_ms()` for durations (budgets, `elapsed_ms`) and `unix_seconds()` for
the informational stamps that are serialised and never read back. Native reads
`std::time`; the browser reads `js_sys::Date::now()`; a wasm build without
`browser-transport` reads `0`, which makes a wall-clock budget non-binding
rather than fatal — the right trade, since a budget that never fires costs
latency and a trap costs the process.

Every reachable site was converted, not just the four observed:
`WallClockDeadline` (`origin_query.rs`, the funnel behind D1 and D3),
`Notification::new` and `Stop::new` and `HistoryResult::new` (`task.rs`),
`Db::load_history` and the continuation-token `issued_at` (`db.rs`), and the
`Instant::now()` pairs in `emulator_origin.rs`, `omniscient_origin.rs`,
`recreator_origin.rs`, `deepreview/collector.rs` and `autoformat.rs`.
`recreator_session.rs`'s four reads are inside `#[cfg(unix)]`/`#[cfg(windows)]`
items and `ctfs_trace_reader/mod.rs`'s six are inside `#[cfg(test)]`, so neither
reaches a wasm build.

**D4 is fixed differently**, because the wait itself was wrong and not merely
unavailable: `handle_message_browser` no longer delegates `disconnect` to
`handle_message`. The browser transport writes synchronously — `dap.rs`'s
closure drains the channel and `postMessage`s each message as soon as the
handler returns — so there is no writer thread to wait for and
`disconnect_response_written` is never set by anybody. Both arms now share
`write_disconnect_response`; only the native one keeps the flush wait.

Tests: `src/db-backend/tests/wall_clock_sweep_test.rs` scans every source file
and fails on any raw `SystemTime::now` / `Instant::now` / `chrono::*::now`
outside a documented, counted allowlist — the point being that fixing the four
observed sites is not fixing the class. `dap_server.rs`'s
`disconnect_is_answered_without_waiting_for_a_writer_thread` covers D4 and
asserts the call does not take the native path's 2s wait.

Runtime evidence: `probe_engine_defects.mjs` against the stylus-fund `.ct`
fixture and a rebuilt engine now reports `D1 success=true`, `D2 success=true`,
`D3 success=true`, `D4 success=true`.

Note for anyone tempted by a stronger check: grepping the linked `.wasm` for
std's `time not implemented on this platform` string does **not** work. It is
present before and after the fix, because `std::sync::mpmc::Channel::send` — the
DAP response channel — contains a guarded `Instant::now()` on its
`deadline: Some(_)` path. Our sends always pass `None`, so it is unreachable,
but the string is linked either way.

---

## 4. `ct/load-flow`: the ViewModel sends a payload the engine cannot parse

`viewmodels/flow_vm.nim:357-360` sends

    let args = %*{
      "rrTicks": ticks,
      "flowMode": modeStr,      # $mode -> "fmCall"
    }

The engine wants `CtLoadFlowArguments` (`src/db-backend/src/task.rs`), which at
the time of this write-up read:

    #[derive(Serialize, Deserialize, Debug, PartialEq, Default, Clone, JsonSchema)]
    #[serde(rename_all = "camelCase")]
    pub struct CtLoadFlowArguments {
        pub flow_mode: FlowMode,
        pub location: Location,
    }

Three separate disagreements:

1. **`flowMode` encoding.** Rust's `FlowMode` (`task.rs`) derived
   `Deserialize_repr` with `#[repr(u8)]` — it accepted a JSON **number only**.
   The string `"fmCall"` failed with *invalid type: string, expected variant
   index*.
2. **`location` is required**, not `Option`. No `#[serde(default)]` at container
   or field level.
3. **`rrTicks` is at the wrong level.** The struct does not declare it; the real
   tick lives *inside* `Location` (`task.rs`). At the time there was no
   `deny_unknown_fields` on this struct, so the top-level `rrTicks` was silently
   discarded. That is no longer true: b6f39ca7 added
   `#[serde(deny_unknown_fields)]` to `CtLoadFlowArguments`, so a stray
   top-level `rrTicks` is now a hard deserialisation error rather than a silent
   drop — see the Status below, where the sender stopped sending it.

**The vocabularies also differ in size:** Rust `FlowMode` is `Call | Diff`;
Nim's (`flow_vm.nim:50-54`) is `fmCall | fmLine | fmFunction`. Two of Nim's three
have no Rust counterpart even once the encoding is fixed.

`flow_vm.nim:170` sends the same stringified mode for `ct/flow-jump`.
`flow_vm.nim:341-343` already documents the mismatch in a comment.

**Measured:** `{"flowMode": 0, "location": {...}}` succeeds and additionally
emits `ct/updated-flow` as an unsolicited event. The Rust side's own test agrees
(`src/db-backend/tests/leo_search_calltrace_test.rs:159` sends `"flowMode": 0`).

### 4a. The response is a placeholder; the window is the event, and the event queues

Measured against the native `replay-server` while capturing
`tests/fixtures/flow/zk_shields_flow_window.json` beside this file
(`capture_zk_shields_flow.nim`), and it is the half a client gets wrong:

* The **response** to `ct/load-flow` carries a placeholder window, not the
  loaded one. A client that reads the response and stops has an empty flow pane
  and no error to explain it.
* The real window is `ct/updated-flow`'s `body.viewUpdates[0]`.
* Events **queue**. `ct/load-flow` is sent after a `continue`/breakpoint
  sequence that has already produced `ct/updated-flow` events for earlier
  positions, so a `waitForEvent("ct/updated-flow")` issued without draining
  first returns a window computed for a **previous** location. It parses, it has
  steps and loops, and it is wrong — a silent wrong answer rather than an error,
  which is why it costs an hour rather than a minute.

The working sequence is therefore: drain, request, then wait for the event.
(This was measured while `flowMode` was still an ordinal; it is a name now —
see the Status below, which also records that `flow_vm` consumes the event.)

**Status: fixed on both sides, and the ordinal is gone.** Making the ordinal
work would have left the worse half of the defect in place: two enums of
different cardinality serialised as a position means a wrong value is
indistinguishable from a right one — `fmLine` as `1` is `Diff`, a different
query that answers with a plausible window for the wrong thing. That is a
silent wrong answer, not a parse error, and no test on either side could see it.

So the wire form is now a **name**:

* `src/common/flow_mode_wire.nim` is the single Nim source of the vocabulary
  (`"call"`, `"diff"`), a leaf module with no imports so `common_types` and the
  IsoNim ViewModel layer can both hold it and a Rust test can read it as text.
* Rust `FlowMode` serialises to that name and parses it, still accepting the
  legacy ordinal inbound (the Karax renderer serialises the canonical Nim enum
  through `toJs`, and several Rust suites write `"flowMode": 0`) but rejecting
  an out-of-range one instead of defaulting.
* `flow_vm.nim` routes its three-valued view granularity through one named
  `engineFlowModeWireName`, whose `case` is exhaustive so a fourth `fm*` member
  will not compile until someone decides what it means to the engine. It sends
  the required `location` (path, line, `rrTicks`, `callstackDepth`) and no
  longer sends a top-level `rrTicks` the engine never read.
* The dedup guard still keys on the *view* mode, so switching granularity keeps
  re-requesting exactly as before; only the wire field changed.

**And the panel now consumes the event, not just the reply.** `ct/load-flow`'s
real answer is the queued `ct/updated-flow` event (`dap.rs:329`); the
backend-manager converts it into a response for some deployments
(`backend_manager.rs:1001`), so `flow_vm` feeds both paths into
`applyFlowUpdate`. Consuming only the reply is how a panel stays empty against
the engine while every mock-driven test passes.

Tests: `src/db-backend/tests/flow_mode_wire_test.rs` **reads
`src/common/flow_mode_wire.nim`** and fails if the two vocabularies differ, so
adding a member on one side without the other fails there; it also pins that the
old `{"rrTicks", "flowMode": "fmCall"}` shape is rejected by name and that
ordinal `2` is an error. `src/common/common_types/codetracer_features/flow.nim`
carries a `static: doAssert` tying its enum's cardinality to the same list.
`tests/flow/flow_vm_test.nim`'s `FlowVM — the ct/load-flow engine boundary`
suite covers the Nim half including both event spellings.

`ct/flow-jump` is deliberately left on the panel's own vocabulary: it has no
engine handler at all, so there is no second enum for it to agree with.

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

**Status: fixed by removing the assumption rather than the microtask.** No
synchronous drain can pump a JS microtask, so `launch` stopped treating "sent"
as "answered". `markReady` is now reached only from a `settle` that runs when
every command actually issued has had its callback; on a synchronous transport
that still happens before `launch` returns (nothing observable changes for the
mock or stdio), and on a genuinely async one the session stays `dspLaunching`
until the responses arrive and then moves to `dspReady` or `dspFailed` from the
callback. A session still `dspLaunching` after `launch` returns is a correct
state; claiming `dspReady` without having seen a response is the thing that must
never happen. The first refusal now wins rather than whichever answer lands
last, which short-circuiting the sends can no longer guarantee.

Tests: `MockBackendService.deferResponses` is a genuinely asynchronous
transport — on JS a hand-rolled *thenable*, so it takes the same
`onComplete` branch a real promise does, while `settleDeferred` lets the test
deliver answers deterministically; on C a `Future` completed later and drained
through `poll(0)`. `test_sdk_facade.nim`'s
`§6.3 over an asynchronous transport` suite (7 cases) runs in **both**
`vm-unit` and `vm-unit-js`; four of them fail against the previous
optimistic `markReady`.

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

**Status: the engine now refuses by name.** The browser source kinds are still
unimplemented — `bytes` never puts its bytes on the wire, `opfs` and `custom`
are consumer-side handles, and `http-range` needs an async fetch the synchronous
browser dispatch cannot make — so implementing them was not tractable here. What
was tractable, and is the required outcome, is that the engine stops answering
with a serde artefact or with nothing at all.

`LaunchRequestArguments` now declares `traceSource` (keeping
`deny_unknown_fields`, which is load-bearing and is asserted by a test), and the
`launch` arm answers a `success: false` **launch response** naming the kind, the
reason, and the supported alternative. A response, not an `Err`: the native
server loop only `error!`s an `Err`, so returning one leaves the client with the
same permanent silence row 1 was about. The message contains the word
"unsupported", which is what `classifyBackendFailure` keys on to reach
`dseUnsupportedTraceKind` rather than the catch-all bucket — a coupling now
asserted from both sides.

An unrecognised sixth kind gets a message naming *it*, not serde's
`unknown variant`, and the refusal lists the known vocabulary. A refused launch
leaves no trace folder and is not stored for `configurationDone` to replay.

Tests: `src/db-backend/tests/launch_trace_source_test.rs` (7 cases, including
that a `local-folder` launch still succeeds so the refusal cannot be "fixed" by
refusing everything) and, on the Nim side, `test_sdk_facade.nim`'s
`the trace-source vocabulary is the one the engine names back` and
`an engine refusal of a browser kind is UnsupportedTraceKind`.

The separate silent-success hazard noted above — a launch carrying neither
`traceFolder` nor `program` still answering `success: true` — is **not** fixed
here. It is a native-path behaviour with unknown consumers (`pid` attach,
`__restart`), and changing it was out of scope for a browser-replay fix.

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

### 7a. Dispatched-but-silent — a category worse than unimplemented

§7's nine commands are **unimplemented**: they reach no arm, and
`handle_request`'s fallthrough refuses them by name with `command <x> not
supported here`. A caller gets an error it can render.

There is a second, worse category, and it is not visible from any mapping table
because the commands *are* in one. These commands **are** dispatched, **do**
their work, **do** emit their events — and never send a **response**. DAP
correlates a reply to a request by `request_seq`; a handler that emits only
events never settles the caller's future. There is no error, no refusal, and no
timeout from the engine's side. The caller waits forever.

Measured against the published wasm engine over `zk_shields.ct`:
`ct/calltrace-jump` was dispatched, moved the session, emitted its `stopped`
event, and returned nothing in 20 s while the worker stayed healthy and answered
every later request on the same session.

The cause is uniform and visible in the signature: the handler takes its request
as `_req` — deliberately unused — and ends at `complete_move(...)` without the
`respond_dap(req, 0, sender)` that every other move handler
(`next_or_step_back_dap`, `dap_handler.rs`) ends with.

| command | handler | status |
| --- | --- | --- |
| `ct/calltrace-jump` | `dap_handler.rs::calltrace_jump` | **fixed** — now responds |
| `ct/event-jump` | `dap_handler.rs::event_jump` | **fixed** — now responds |
| `restart` | `run_to_entry` | silent |
| `ct/collapse-calls` | `collapse_calls` | silent — dispatched without a `sender` at all, so it *cannot* respond |
| `ct/expand-calls` | `expand_calls` | silent — same |
| `ct/history-jump` | `history_jump` | silent |
| `ct/trace-jump` | `trace_jump` | silent |
| `ct/tracepoint-delete` | `tracepoint_delete` | silent |
| `ct/tracepoint-toggle` | `tracepoint_toggle` | silent |
| `ct/local-step-jump` | `local_step_jump` | silent |
| `ct/setup-trace-session` | `setup_trace_session` | silent |

The two `*-jump` commands are fixed because they are the row-click commands a
pane awaits directly. The remaining nine are recorded rather than changed: two of
them are not even handed a `sender`, so fixing them is a dispatch-signature
change rather than a one-line addition, and the rest want a caller that actually
awaits them before their response shape is decided.

**For consumers:** do not `await` any command in the "silent" rows above without
your own deadline. `hydrate.nim` is unaffected today only because it uses
`ct/goto-ticks` — which does respond — for call-trace row clicks.

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

## 9. `reverse-step-in` / `reverse-step-out` — the dialect's own extension

Every other row here is a place the two sides disagree. This one is a place they
agree, on a vocabulary **DAP does not have**, and it is recorded because it had
never been written down: the desktop toolbar renders eight buttons and two of
them cannot be expressed in the standard protocol at all.

**DAP's reverse vocabulary is two commands.** `stepBack` and `reverseContinue`
are the whole of it. `stepIn` and `stepOut` take a `granularity`
(`statement` | `line` | `instruction`) and **no direction**, and there is no
granularity that means "into the callee". So the honest model of this toolbar is
**granularity × direction**, and DAP supplies only three of the eight cells.
CodeTracer fills the missing two with `ct/reverseStepIn` and
`ct/reverseStepOut`.

**Where each side spells it:**

| layer | spelling | site |
| --- | --- | --- |
| toolbar action id | `reverse-step-in` | `views/isonim_debug_controls_view.nim:211-213`, `ui_js.nim:4110` |
| ViewModel | `DebugControlsVM.reverseStepIn` | `viewmodels/debug_controls_vm.nim:143`, dispatched from `:188` |
| store → wire | `ct/reverseStepIn` | `store/replay_data_store.nim:915` (`sdReverseStepIn`) |
| command set | `ct/reverseStepIn`, `ct/reverseStepOut` | `backend/dap_commands.nim:43-44` |
| event kind | `CtReverseStepIn` → `CtReverseStepInResponse` | `src/frontend/dap.nim:101`, `:299` |
| engine | `(Action::StepIn, is_reverse = true)` | `src/db-backend/src/dap_server.rs:2037-2038`, in `dap_command_to_step_action` |
| Python bridge | `reverse_step_in` → `ct/reverseStepIn` | `src/backend-manager/src/python_bridge.rs:1123` |

The engine's mapping is where the semantics live, and it is worth quoting
because the pairing is not obvious from the names:

    "stepBack"          => (Action::Next,    reverse)
    "ct/reverseStepIn"  => (Action::StepIn,  reverse)
    "ct/reverseStepOut" => (Action::StepOut, reverse)

So `stepBack` is a **reverse next**, not a reverse step-in. A client that
reached for DAP's reverse command expecting to enter the callee gets the
sibling-level move instead — silently, because both succeed.

**Measured**, against the real wasm32 engine
(`probe_reverse_step_in.mjs`, stylus-fund fixture, 14 steps / 7 calls):

    command                                ok     from -> to    fn
    stepIn                                 true     49 -> 60    fund
    stepOut                                true     49 -> 60    fund
    stepBack                               true     49 -> 38    new
    stepBack {"granularity":"statement"}   true     49 -> 38    new
    stepBack {"granularity":"instruction"} true     49 -> 38    new
    reverseStepIn                          false    49 -> 49    new
        message: command reverseStepIn not supported here
    reverseStepOut                         false    49 -> 49    new
        message: command reverseStepOut not supported here
    ct/reverseStepIn                       true     49 -> 38    new
    ct/reverseStepOut                      true     49 -> 59    fund

Three things in that table, in descending order of how much they cost to
rediscover:

1. **`granularity` is not direction.** `stepBack` lands on the same step with
   `statement`, with `instruction`, and with no granularity at all. There is no
   argument that turns DAP's reverse step into a reverse step-in.
2. **The DAP-shaped guesses are refused BY NAME.** `reverseStepIn` and
   `reverseStepOut` — the spellings a client writes first, because every other
   reverse command in this dialect is `ct/`-prefixed and these two look like
   they should not be — return `success: false` with
   `command <name> not supported here`. That is the *good* outcome and the same
   standard §6 sets: a legible refusal rather than a serde artefact or silence.

   The refusal originates in `dap_command_to_step_action`'s `_` arm, but the
   message does not: that arm builds `not a recognized dap step action:
   <command>`, and its caller (`dap_server.rs:2327-2332`) matches `Err(_e)`,
   drops it, and substitutes the generic sentence. So the text a client reads
   names the command but not the reason, and the more specific string never
   leaves the engine. Worth knowing before grepping the sources for a message
   that is only ever constructed at the call site.
3. **`ct/reverseStepIn` is a distinct move, not an alias of `stepBack`.** A
   single anchor cannot show this, because a reverse-next and a reverse-step-in
   agree everywhere except at a call boundary — from line 49 both land on 38.
   So the probe sweeps every anchor in the trace and reports where they part:

       ticks  from        stepBack    ct/reverseStepIn  ct/reverseStepOut
           8  49:new      38:new      38:new            59:fund
           9  60:fund     59:fund     49:new            49:new     <- IN differs
          10  61:fund     60:fund     60:fund           49:new

   At tick 9 the cursor is on line 60 of `fund`, immediately after the call to
   `new` returned. `stepBack` goes to the previous statement of `fund`;
   `ct/reverseStepIn` goes to **line 49 of `new`** — the last step of the call
   that just returned. That is the move, and it is the move no DAP command
   makes.

   Over the whole 14-step trace: `ct/reverseStepIn` differs from `stepBack` at
   2 of 16 anchors and `ct/reverseStepOut` at 11 of 16. The first number is
   small because the fixture is shallow, not because the commands are close;
   it is reported rather than rounded away, and the probe says so explicitly
   when a fixture produces zero.

### 9a. A zero that is about the ANCHORS — how to sweep for this correctly

BlockTracer's port of these tests (`tests/e2e/noir_engine_dap.nim`, §9d) runs
the same sweep over `zk_shields.ct` and measures `ct/reverseStepIn` differing
from `stepBack` at **0 of 82 anchors** — and concludes the two are aliases. They
are not. The anchor set is the problem, and the failure mode is worth recording
because the suite explicitly argues it has ruled the possibility out.

Its 82 anchors are the tick column of `client/fixtures/demo-session/flow.json` —
the FLOW WINDOW's rows. Measured over the container directly:

| anchors | count |
| --- | --- |
| total | 82 |
| whose previous step is at a **shallower** depth (call ENTRY) | 13 |
| whose previous step is at a **deeper** depth (call RETURN) | **0** |

A call RETURN is the only place the two commands can differ — that is point 3
above. At a call ENTRY, reverse-next and reverse-step-in both land on the
caller's call site, identically and by construction. So a sweep with no return
anchor cannot tell the commands apart no matter how many anchors it has.

The reason there are none: a flow window's rows are the statement-level steps of
the frame being viewed, and the step immediately following a return lands back on
the line that made the call — a line the window already has a row for. The
returns are real in the trace; they are simply not what `flow.json` enumerates.

The positive twin, over the same container, sweeping the **79 real call-return
steps** instead:

    call-return steps in the trace:                        79
    stepBack vs ct/reverseStepIn differ at:            79 of 79

    step 94:  stepBack -> step 57  (iterate_asteroids, line 12)
              ct/reverseStepIn -> step 93  (calculate_shield_regeneration, line 66)

So on this container the two commands differ at **every** call return, and at
none of the anchors the port happens to use. A sweep that wants to distinguish
them must select anchors by DEPTH TRANSITION — steps whose predecessor is
deeper — not by whatever row set a fixture happens to carry.

**Status: recorded, not a defect, and nothing to fix.** Both commands are in
`dap_commands.nim`'s `VALID_DAP_COMMANDS_SEQ`, both have a `CtEventKind` and a
response kind in `src/frontend/dap.nim`, both are in `collab/authority.nim`'s
authoritative set, and both are dispatched by the engine. This is the one
extension in the dialect that is *complete on both sides* — which is precisely
why it was invisible and why it went eight rows without an entry.

What made it worth writing down is a second consumer. BlockTracer renders this
toolbar on the web (`Debugger-Integration.md` §3 in `codetracer-specs`), whose
own note reads: *"The eighth control, `reverse-step-in`, is already a CodeTracer
dialect extension … §2 commits to 'no new protocol', so the honest model for
this set is granularity × direction and the extension has to be recorded in the
dialect diff rather than only rendered as a button here."* An extension that
exists only as a button is an extension the next client has to rediscover — by
sending `reverseStepIn` and reading a refusal.

Tests: `src/tests/gui/tests/debug-controls/debug_controls_vm_test.nim:38-40`
pins the eight step commands the VM may emit — six DAP spellings plus the two
`ct/`-prefixed extensions — and
`viewmodel/tests/unit/test_sync.nim:688-692` asserts that the `reverseStepIn`
action reaches the backend as `ct/reverseStepIn`. Both drive
`MockBackendService`, which is why the ENGINE half needed the probe: a mock
accepts any string, so no existing test could have told `ct/reverseStepIn` from
`reverseStepIn`.

---

## Summary: what blocks a transaction page loading the debugger

| # | gap | side fixed | status |
| --- | --- | --- | --- |
| 1 | handshake order | **engine** (order-independent, as the native path already is) | fixed |
| 3-D1 | `ct/load-locals` traps | engine | fixed (`wall_clock`) |
| 3-D2 | boundary step traps | engine | fixed (`wall_clock`) |
| 3-D3 | `ct/originChain` traps | engine | fixed (`wall_clock`) |
| 3-D4 | `disconnect` traps | engine | fixed (no writer-thread wait in the browser arm) |
| 4 | `ct/load-flow` payload | both, via a shared named vocabulary | fixed |
| 5 | `drainPlatformCallbacks` | the SDK (`launch` no longer assumes) | fixed |
| 6 | `TraceSource` browser kinds | engine | refused by name; kinds still unimplemented |
| 7 | nine unmapped commands | frontend | **open** |
| 9 | reverse step-in / step-out | neither — it is the dialect's own extension | recorded; complete on both sides |

§2, §8 and §9 are recorded facts, not defects.
