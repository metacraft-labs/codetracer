# CodeTracer DAP Requests

This document describes the Debug Adapter Protocol (DAP) requests that the
CodeTracer db-backend accepts, with emphasis on the custom `ct/*` commands.
For the base protocol and standard request shapes, see the DAP specification:
https://microsoft.github.io/debug-adapter-protocol/specification

Sources of truth in this repo:
- `src/db-backend/src/dap.rs`
- `src/db-backend/src/dap_server.rs`
- `src/db-backend/src/handler.rs`
- `src/db-backend/src/task.rs`
- `src/frontend/dap.nim`

## Standard DAP Requests (Supported)

These are standard DAP requests used by CodeTracer. They follow the upstream
spec and use the auto-generated DAP types in `src/db-backend/src/dap_types.rs`.

| Request | Arguments type | Response body | Notes |
| --- | --- | --- | --- |
| `initialize` | `InitializeRequestArguments` | `Capabilities` | Returns CodeTracer capabilities defined in `src/db-backend/src/dap.rs`. |
| `launch` | `LaunchRequestArguments` | `{}` | Uses CodeTracer-specific launch fields (see type reference below). |
| `configurationDone` | none | `{}` | Signals that configuration is complete. |
| `setBreakpoints` | `SetBreakpointsArguments` | `SetBreakpointsResponseBody` | Clears and re-applies breakpoints each request. |
| `threads` | `ThreadsArguments` | `ThreadsResponseBody` | Single-threaded model. |
| `stackTrace` | `StackTraceArguments` | `StackTraceResponseBody` | Uses db-backend call stack. |
| `scopes` | `ScopesArguments` | `ScopesResponseBody` | Standard variable scopes. |
| `variables` | `VariablesArguments` | `VariablesResponseBody` | Standard variables resolution. |
| `restart` | none | `{}` | Mapped to `ct/run-to-entry`. |
| `stepIn` / `stepOut` / `next` / `continue` / `stepBack` / `reverseContinue` | `StepInArguments` etc. | `{}` | Emit `stopped`, `ct/complete-move`, and `output` events. |

## Custom `ct/*` Requests

Many custom requests deliver their main payloads via custom events rather than
through the DAP response body. See handler implementations for the exact
response behavior per command.

| Request | Arguments | Response / Events |
| --- | --- | --- |
| `ct/load-locals` | `CtLoadLocalsArguments` | Response body `CtLoadLocalsResponseBody`. |
| `ct/update-table` | `UpdateTableArgs` | Emits `ct/updated-table` with `CtUpdatedTableResponseBody`. |
| `ct/event-load` | none | Emits `ct/updated-events` and `ct/updated-events-content`. |
| `ct/load-terminal` | none | Emits `ct/loaded-terminal`. |
| `ct/collapse-calls` | `CollapseCallsArgs` | Updates internal calltrace state. |
| `ct/expand-calls` | `CollapseCallsArgs` | Updates internal calltrace state. |
| `ct/load-calltrace-section` | `CalltraceLoadArgs` | Emits `ct/updated-calltrace`. |
| `ct/calltrace-jump` | `Location` | Emits `stopped`, `ct/complete-move`, `output`. |
| `ct/event-jump` | `ProgramEvent` | Emits `stopped`, `ct/complete-move`, `output`. |
| `ct/load-history` | `LoadHistoryArg` | Emits `ct/updated-history`. |
| `ct/history-jump` | `Location` | Emits `stopped`, `ct/complete-move`, `output`. |
| `ct/search-calltrace` | `CallSearchArg` | Emits `ct/calltrace-search-res`. |
| `ct/source-line-jump` | `SourceLocation` | Emits `stopped`, `ct/complete-move`, `output`. |
| `ct/source-call-jump` | `SourceCallJumpTarget` | Emits `stopped`, `ct/complete-move`, `output`, and may emit `ct/notification` on failure. |
| `ct/local-step-jump` | `LocalStepJump` | Emits `stopped`, `ct/complete-move`, `output`. |
| `ct/tracepoint-toggle` | `TracepointId` | Emits `ct/updated-trace` (refreshes trace log). |
| `ct/tracepoint-delete` | `TracepointId` | Emits `ct/updated-trace` (refreshes trace log). |
| `ct/trace-jump` | `ProgramEvent` | Emits `stopped`, `ct/complete-move`, `output`. |
| `ct/load-flow` | `CtLoadFlowArguments` | Emits `ct/updated-flow`. |
| `ct/run-to-entry` | none | Emits `stopped`, `ct/complete-move`, `output`. |
| `ct/run-tracepoints` | `RunTracepointsArg` | Emits `ct/updated-trace` per tracepoint. |
| `ct/setup-trace-session` | `RunTracepointsArg` | Prepares trace tables; no payload. |
| `ct/load-asm-function` | `FunctionLocation` | Response body `Instructions`. |
| `ct/reverseStepIn` | none | Reverse step-in; emits `stopped`, `ct/complete-move`, `output`. |
| `ct/reverseStepOut` | none | Reverse step-out; emits `stopped`, `ct/complete-move`, `output`. |

## Custom Events

| Event | Body type | Notes |
| --- | --- | --- |
| `ct/updated-trace` | `TraceUpdate` | Tracepoint progress + trace log refresh. |
| `ct/updated-flow` | `FlowUpdate` | Flow preloader updates. |
| `ct/updated-history` | `HistoryUpdate` | History query results. |
| `ct/calltrace-search-res` | `Vec<Call>` | Search results for calltrace. |
| `ct/updated-events` | `Vec<ProgramEvent>` | First page of events. |
| `ct/updated-events-content` | `String` | Raw event log content. |
| `ct/updated-calltrace` | `CallArgsUpdateResults` | Calltrace chunk data. |
| `ct/updated-table` | `CtUpdatedTableResponseBody` | Table data for DataTables. |
| `ct/complete-move` | `MoveState` | Current location + flow reset hint. |
| `ct/loaded-terminal` | `Vec<ProgramEvent>` | Filtered stdout write events. |
| `ct/notification` | `Notification` | UI notification payload. |

## Rust client example

Simple `load_flow` usage with the Rust DAP wrapper:

```rust
use db_backend::dap_client::{CtBackendDapWrapper, CtDapEvent, CtLaunchOptions};
use db_backend::dap_types::InitializeRequestArguments;
use db_backend::task::{CtLoadFlowArguments, FlowMode, Location};

let trace_path = std::path::PathBuf::from("/tmp/trace");
let ct_backend = CtBackendDapWrapper::new().expect("dap start");

let init_args = InitializeRequestArguments {
    adapter_id: "codetracer".to_string(),
    ..Default::default()
};
ct_backend.initialize(init_args).expect("initialize");
ct_backend
    .launch(trace_path, CtLaunchOptions::default())
    .expect("launch");

ct_backend
    .on(CtDapEvent::LoadedFlow, |event| {
        println!("event {event:?}");
    })
    .expect("subscribe");

let flow_args = CtLoadFlowArguments {
    flow_mode: FlowMode::Call,
    location: Location::default(),
};
ct_backend.load_flow(flow_args).expect("load flow");
```

## Type Reference (Custom)

Types live in `src/db-backend/src/task.rs` unless noted.

### LaunchRequestArguments (in `src/db-backend/src/dap.rs`)

| Field | Type | Notes |
| --- | --- | --- |
| `program` | `Option<String>` | Path to program (optional). |
| `traceFolder` | `Option<PathBuf>` | Folder with trace data. |
| `traceFile` | `Option<PathBuf>` | Single trace file path. |
| `rawDiffIndex` | `Option<String>` | Raw diff index payload. |
| `ctRRWorkerExe` | `Option<PathBuf>` | RR worker executable. |
| `restoreLocation` | `Option<Location>` | Restore UI to a saved location. |
| `pid` | `Option<u64>` | Attach pid (if applicable). |
| `cwd` | `Option<String>` | Working directory. |
| `noDebug` | `Option<bool>` | DAP standard noDebug flag. |
| `__restart` | `Option<Value>` | DAP restart payload passthrough. |
| `name` | `Option<String>` | Session name. |
| `request` | `Option<String>` | DAP request name. |
| `type` | `Option<String>` | DAP adapter type. |
| `__sessionId` | `Option<String>` | VS Code session id. |

### CtLoadLocalsArguments

| Field | Type | Notes |
| --- | --- | --- |
| `rrTicks` | `i64` | Step id / rr tick to sample. |
| `countBudget` | `i64` | Budget for value expansion. |
| `minCountLimit` | `i64` | Minimum expansion limit. |
| `lang` | `Lang` | Language enum. |
| `watchExpressions` | `Vec<String>` | Watch expressions. |
| `depthLimit` | `i64` | `-1` means no depth limit. |

### CtLoadLocalsResponseBody

| Field | Type |
| --- | --- |
| `locals` | `Vec<Variable>` |

### Variable

| Field | Type |
| --- | --- |
| `expression` | `String` |
| `value` | `Value` |
| `address` | `i64` |

### CtLoadFlowArguments

| Field | Type |
| --- | --- |
| `flowMode` | `FlowMode` |
| `location` | `Location` |

### FlowMode

| Variant | Value |
| --- | --- |
| `Call` | `0` |
| `Diff` | `1` |

### UpdateTableArgs

| Field | Type | Notes |
| --- | --- | --- |
| `tableArgs` | `TableArgs` | DataTables server-side args. |
| `selectedKinds` | `[bool; 14]` | Event kind filter. |
| `isTrace` | `bool` | Trace vs record table. |
| `traceId` | `usize` | Tracepoint id. |

### TableArgs

DataTables server-side parameters:
https://datatables.net/manual/server-side

| Field | Type |
| --- | --- |
| `columns` | `Vec<UpdateColumns>` |
| `draw` | `usize` |
| `length` | `usize` |
| `order` | `Vec<OrdValue>` |
| `search` | `SearchValue` |
| `start` | `usize` |

### CtUpdatedTableResponseBody

| Field | Type |
| --- | --- |
| `tableUpdate` | `TableUpdate` |

### CalltraceLoadArgs

| Field | Type |
| --- | --- |
| `location` | `Location` |
| `startCallLineIndex` | `GlobalCallLineIndex` |
| `depth` | `usize` |
| `height` | `usize` |
| `rawIgnorePatterns` | `String` |
| `autoCollapsing` | `bool` |
| `optimizeCollapse` | `bool` |
| `renderCallLineIndex` | `usize` |

### CollapseCallsArgs

| Field | Type |
| --- | --- |
| `callKey` | `String` |
| `nonExpandedKind` | `CalltraceNonExpandedKind` |
| `count` | `i64` |

### Location

| Field | Type |
| --- | --- |
| `path` | `String` |
| `line` | `i64` |
| `functionName` | `String` |
| `highLevelPath` | `String` |
| `highLevelLine` | `i64` |
| `highLevelFunctionName` | `String` |
| `lowLevelPath` | `String` |
| `lowLevelLine` | `i64` |
| `rrTicks` | `RRTicks` |
| `functionFirst` | `i64` |
| `functionLast` | `i64` |
| `event` | `i64` |
| `expression` | `String` |
| `offset` | `i64` |
| `error` | `bool` |
| `callstackDepth` | `usize` |
| `originatingInstructionAddress` | `i64` |
| `key` | `String` |
| `globalCallKey` | `String` |
| `expansionParents` | `Vec<usize>` |
| `missingPath` | `bool` |

### ProgramEvent

| Field | Type |
| --- | --- |
| `kind` | `EventLogKind` |
| `content` | `String` |
| `rrEventId` | `usize` |
| `highLevelPath` | `String` |
| `highLevelLine` | `i64` |
| `metadata` | `String` |
| `bytes` | `usize` |
| `stdout` | `bool` |
| `directLocationRRTicks` | `i64` |
| `tracepointResultIndex` | `i64` |
| `eventIndex` | `usize` |
| `base64Encoded` | `bool` |
| `maxRRTicks` | `i64` |

### FunctionLocation

| Field | Type |
| --- | --- |
| `path` | `String` |
| `name` | `String` |
| `key` | `String` |
| `forceReload` | `bool` |

### SourceLocation

| Field | Type |
| --- | --- |
| `path` | `String` |
| `line` | `usize` |

### SourceCallJumpTarget

| Field | Type |
| --- | --- |
| `path` | `String` |
| `line` | `usize` |
| `token` | `String` |

### CallSearchArg

| Field | Type |
| --- | --- |
| `value` | `String` |

### LoadHistoryArg

| Field | Type |
| --- | --- |
| `expression` | `String` |
| `location` | `Location` |
| `isForward` | `bool` |

### TracepointId

| Field | Type |
| --- | --- |
| `id` | `usize` |

### TraceSession

| Field | Type |
| --- | --- |
| `tracepoints` | `Vec<Tracepoint>` |
| `found` | `Vec<Stop>` |
| `lastCount` | `usize` |
| `results` | `HashMap<i64, Vec<Stop>>` |
| `id` | `usize` |

### RunTracepointsArg

| Field | Type |
| --- | --- |
| `session` | `TraceSession` |
| `stopAfter` | `i64` |

### LocalStepJump

| Field | Type |
| --- | --- |
| `path` | `String` |
| `line` | `i64` |
| `stepCount` | `i64` |
| `iteration` | `i64` |
| `firstLoopLine` | `i64` |
| `rrTicks` | `i64` |
| `reverse` | `bool` |

### Instructions (Response)

| Field | Type |
| --- | --- |
| `address` | `usize` |
| `instructions` | `Vec<Instruction>` |
| `error` | `String` |
