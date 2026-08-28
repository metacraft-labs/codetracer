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

# Omniscience's renderer-neutral layout: where each inline value goes, which
# expression heads which column, how deep a line is nested, which steps belong
# to which pass of a loop, and whether a label reads `[x=10]`, `[→230]` or
# `[x: 10→20]`.
#
# It is exported beside `FlowVM` because without it `FlowVM` is not a usable
# Omniscience surface — it carries the loop selection and the loaded window, but
# every *placement* decision the spec's "Value Positioning" section names lived
# in `ui/flow.nim`, which §3.2 excludes from this package twice over (Monaco,
# and "any rendering"). A consumer given only `FlowVM` would have to
# reimplement, or copy, the arithmetic that decides which label belongs beside
# which expression.
#
# It is IN this package rather than one layer up because it is a computation
# over trace data and source text and contains no pixel, no unit, no CSS class
# and no DOM node — which is also what lets `ci/test/sdk-facade-boundary.sh`
# keep it here.
import viewmodels/flow_layout
export flow_layout

# Value Origin Tracking's ViewModel (Value-Origin-Tracking.milestones.org M4).
#
# The capability — `ct/originChain`, the chain model, the breadcrumb stack, the
# pinned chains, the batched placeholder fill — has been built, tested and
# shipped on the desktop since the campaign closed
# (Value-Origin-Campaign-Closeout.md, 2026-06-18). It was simply not reachable
# from an embedder, because this facade did not name it: §7 makes anything not
# exported here private.
#
# Exporting it adds NOTHING to the facade's import graph, and not as an
# estimate: `session_vm` already imports `origin_chain_vm`, and `state_vm` and
# `scratchpad_vm` already import `origin_chain_types`, so both modules have been
# inside the graph `ci/test/sdk-facade-boundary.sh` walks all along —
# unreachable only because this file did not name them. The measured count is
# 49 modules with and without these four lines.
#
# In particular it introduces no chain concept, and that is
# checkable by reading `origin_chain_types.nim` rather than by taking this
# comment's word: `OriginChain` is `queryVariable`, `queryStepId`, a `seq` of
# `OriginHop` and a `Terminator`; a hop carries a source expression, an
# `OriginLocation` of `path`/`line`/`rrTicks`, and operand snapshots. There is
# no block, no transaction, no address and no chain id anywhere in the type —
# an origin CHAIN is a chain of causes, which value came from which earlier
# value. `ci/test/sdk-facade-boundary.sh` is the enforcement.
import viewmodels/origin_chain_types
export origin_chain_types

import viewmodels/origin_chain_vm
export origin_chain_vm

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
