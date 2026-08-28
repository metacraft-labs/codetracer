## codetracer_embed.nim — the CodeTracer Embed SDK facade.
##
## **This module is the SDK's entire public surface.** Everything a consumer
## may use is re-exported here; anything not re-exported here is private and
## may change without a version bump
## ([CodeTracer-Embed-SDK.md](../../../../codetracer-specs/Planned-Features/CodeTracer-Embed-SDK.md)
## §7: "Anything not exported from `index.js` / the Nim `codetracer_embed`
## module is private").
##
## A consumer writes:
##
## ```nim
## import codetracer_embed
##
## let backend = newMockBackendService(autoRespond = true).toBackendService()
## let session = newDebuggerSession(backend)
## session.launch(httpRangeTrace("https://cdn.example.com/t/ab/cd/abc.../"))
## echo session.position.file
## session.dispose()
## ```
##
## and never `import viewmodel/store/replay_data_store`. That rule is not a
## review convention: `ci/test/sdk-facade-boundary.sh` fails the build when a
## declared consumer reaches past this module, which is the enforcement
## [Client-SDK.md](../../../../codetracer-specs/BlockTracer/Client-SDK.md)
## §1.1 asks for and the mirror of BlockTracer's own
## `test_debugger_panes_use_only_sdk_facade`.
##
## ## What is here, and why (spec §3.1)
##
## | §3.1 row            | Exported                                                                 |
## | ------------------- | ------------------------------------------------------------------------ |
## | `ReplayDataStore`   | `store/replay_data_store`, `store/types`, `store/request_tracker`, `store/degraded_state` |
## | Panel ViewModels    | `CalltraceVM` `EventLogVM` `StateVM` `FlowVM` `EditorVM` `DebugControlsVM` `RequestPanelVM` |
## | `BackendService`    | `backend/backend_service`, `backend/mock_backend`, `backend/dap_commands` |
## | Session lifecycle   | `DebuggerSession`, `SessionViewModel`, `AppViewModel`                     |
## | `TraceSource`       | `sdk/trace_source`                                                        |
## | Clock               | `isonim/core/clock`, `isonim/testing/test_utils` (`withFakeTime`)         |
## | Types               | `store/types` — the trace, location, frame, value, event and span models  |
##
## Two rows of §3.1 have no Nim symbol and are therefore absent by
## construction rather than by omission:
##
##   * **Replay engine.** `db-backend` compiled to `wasm32` is a build
##     artifact (`src/db-backend/`), not a Nim module. It reaches a consumer
##     through the packaging described in §5, and through a `BackendService`
##     at runtime. There is nothing here to export.
##   * **Generated TypeScript declarations.** §6.4's generator is Mode J and
##     belongs to M3. The Nim types it will be generated *from* are
##     `store/types`, exported below.
##
## ## What is deliberately not here
##
## | Withheld                                       | Spec                                                                     |
## | ---------------------------------------------- | ------------------------------------------------------------------------ |
## | `viewmodel/views/*`, `app/isonim_app*`         | §3.2 row 1 — "any rendering, any CSS, any component"                     |
## | `backend/real_backend`                         | Electron/`jsffi` renderer bridge; §3.2 row 2                             |
## | `backend/stdio_backend`, `headless_session`    | spawn a local `replay-server` via `std/osproc`; a native harness, not an embeddable transport |
## | `collab/*`, `sync/*`, `agent_service`          | product surfaces of the desktop app, not the replay core                 |
## | The remaining 40+ ViewModels                   | §3.1 names seven panels; the rest are upstream's phase 5 (BlockTracer.milestones.org M2b) |
## | Any chain concept                              | §3.2 last row — transaction, block, chain id, generation. Resolving a chain's data to a trace is Client-SDK.md's layer, never this one |
##
## The last row is the one that will be under pressure, because BlockTracer is
## this SDK's first consumer and a chain concept added "just for BlockTracer"
## will always look local and reasonable. `ci/test/sdk-facade-boundary.sh`
## walks this module's transitive import graph and fails on one.
##
## ## Reactivity
##
## Mode N (§4.1) consumers read IsoNim signals directly — "signals cross no
## boundary". `isonim/core/[signals, computation, owner]` are re-exported so
## `store.debugger.val` and `createMemo` are in scope from this one import.
## IsoNim is a peer package, not an SDK internal: importing it directly is
## allowed and is not a boundary violation. The `Readable`/`subscribe` bridge
## of §6.1 is Mode J and belongs to M3.

# ---------------------------------------------------------------------------
# Reactivity contract (§4.1)
# ---------------------------------------------------------------------------
import isonim/core/[signals, computation, owner]
export signals, computation, owner

import isonim/viewmodel
export viewmodel

# ---------------------------------------------------------------------------
# Clock (§3.1) — IsoNim already ships exactly what the row asks for: a real
# clock, a TestClock, and `withFakeTime` for deterministic consumer tests.
# Re-exported rather than reimplemented.
# ---------------------------------------------------------------------------
import isonim/core/clock
export clock

import isonim/testing/test_utils
export test_utils

# ---------------------------------------------------------------------------
# BackendService (§3.1) — the injectable transport, the mock every consumer
# test drives, and `WorkerBackendService`, the DAP-over-`postMessage` driver
# for the WASM replay worker.
#
# `worker_backend` owns the protocol only; the `Worker` itself is injected as
# a pair of procs. That keeps `std/jsffi` and the §5.1 `assetBase` decision
# outside this graph — a consumer that already has a worker, and a consumer
# that wants the SDK to construct one, use the same driver.
# ---------------------------------------------------------------------------
import backend/backend_service
export backend_service

import backend/mock_backend
export mock_backend

import backend/worker_backend
export worker_backend

import backend/dap_commands
export dap_commands

# ---------------------------------------------------------------------------
# ReplayDataStore and the trace data models (§3.1, rows 1 and 8)
# ---------------------------------------------------------------------------
import store/types
export types

import store/request_tracker
export request_tracker

# The degraded-state catalogue (BlockTracer/Page-Descriptions.md §14) — the
# six rows a debugger over a trace can be in, as enums, plus the per-pane
# sensitivity sets and the one function that resolves them. Exported by name
# rather than relied upon through `replay_data_store`'s re-export, because a
# consumer's view renders these values directly and §7 makes only what is
# named here public.
import store/degraded_state
export degraded_state

import store/replay_data_store
export replay_data_store

# ---------------------------------------------------------------------------
# Panel ViewModels (§3.1, row 2)
#
# Exactly the seven the spec names. `RequestPanelVM` is the spans ViewModel:
# it is the VM over `ReplayDataStore.requestSpans`, which is what the spec's
# `SpansVM` refers to. The name difference is recorded rather than papered
# over — see the module note in `viewmodels/request_panel_vm.nim`.
# ---------------------------------------------------------------------------
import viewmodels/calltrace_vm
export calltrace_vm

import viewmodels/event_log_vm
export event_log_vm

import viewmodels/state_vm
export state_vm

import viewmodels/flow_vm
export flow_vm

import viewmodels/editor_vm
export editor_vm

import viewmodels/debug_controls_vm
export debug_controls_vm

import viewmodels/request_panel_vm
export request_panel_vm

# ---------------------------------------------------------------------------
# Session lifecycle (§3.1, row 4; §6)
# ---------------------------------------------------------------------------
import session_vm
export session_vm

import app/app_vm
export app_vm

import sdk/debugger_session
export debugger_session

# ---------------------------------------------------------------------------
# TraceSource (§3.1, row 5)
# ---------------------------------------------------------------------------
import sdk/trace_source
export trace_source

const
  CodeTracerEmbedFacadeModule* = "codetracer_embed"
    ## The one module name a consumer may import from this SDK. The import
    ## lint reads it from here rather than hardcoding a string, so renaming
    ## the facade cannot silently disarm the guard.
