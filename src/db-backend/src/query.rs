use serde::{Deserialize, Serialize};

use crate::lang::Lang;
use crate::task::{Action, Breakpoint, CtLoadLocalsArguments, LoadHistoryArg, Location, ProgramEvent};
use crate::value::ValueRecordWithType;

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "kind")]
pub enum ReplayQuery {
    RunToEntry,
    LoadLocation,
    /// Load the current location with Nim sourcemap translation applied.
    ///
    /// Returns a `LocationWithSourcemap` where the location has `high_level_*`
    /// fields set to the Nim source and `low_level_*` fields set to the
    /// generated C location, plus a separate `c_location` for the C-level view.
    LoadLocationWithSourcemap,
    Step {
        action: Action,
        forward: bool,
    },
    LoadLocals {
        arg: CtLoadLocalsArguments,
    },
    LoadReturnValue {
        lang: Lang,
        depth_limit: Option<usize>,
    },
    LoadValue {
        expression: String,
        lang: Lang,
        depth_limit: Option<usize>,
    },
    AddBreakpoint {
        path: String,
        line: i64,
    },
    DeleteBreakpoint {
        breakpoint: Breakpoint,
    },
    DeleteBreakpoints,
    ToggleBreakpoint {
        breakpoint: Breakpoint,
    },
    EnableBreakpoints,
    DisableBreakpoints,
    JumpToCall {
        location: Location,
    },
    LoadAllEvents,
    LoadCallstack,
    LoadHistory {
        arg: LoadHistoryArg,
    },
    EventJump {
        program_event: ProgramEvent,
    },
    CallstackJump {
        depth: usize,
    },
    TracepointJump {
        event: ProgramEvent,
    },
    LocationJump {
        location: Location,
    },
    TtdTracepointEvaluate {
        request: TtdTracepointEvalRequest,
    },
    RestoreAt {
        geid: u64,
        tid: Option<u32>,
        tick: Option<u64>,
        phase: Option<String>,
    },
    GetRecordingHead,
    SeekToGeid {
        geid: u64,
    },
    /// Query the process table from the trace.
    ///
    /// For RR traces, the worker shells out to `rr ps` and returns the parsed
    /// process tree. For MCR traces, the worker reads process metadata from
    /// the trace. The returned JSON payload is `Vec<ProcessInfo>` (see
    /// [`crate::task::ProcessInfo`]).
    ///
    /// Used by the DAP `threads` request to enumerate processes in a
    /// multi-process recording so that VS Code / DAP clients show one thread
    /// per recorded process instead of a single synthetic thread.
    GetProcessInfo,
    // -----------------------------------------------------------------
    // Value-Origin (M11) — RR-driver primitives.
    //
    // These mirror the same-named queries on the native-backend worker
    // (`codetracer-native-backend/src/query.rs`). The db-backend
    // `recreator_session::origin_chain` implementation in spec §6.3
    // forwards through `dispatch_replay_query` so existing transport
    // wiring (UnixStream / TcpStream) carries them verbatim.
    // -----------------------------------------------------------------
    /// Resolve the address and size of `expression` at the current
    /// replay tick. The worker walks DWARF to find the variable's
    /// storage location and returns `{ "address": u64, "size": usize }`
    /// (per spec §6.3 "evaluate_with_address").
    EvaluateWithAddress {
        expression: String,
    },
    /// Install a hardware watchpoint at `(address, size)` and fire on
    /// `is_write`. The worker returns a numeric watchpoint id which the
    /// caller must pass to `DeleteWatchpoint` for cleanup.
    AddWatchpoint {
        address: u64,
        size: usize,
        is_write: bool,
    },
    /// Remove the watchpoint identified by `id`. Defensive cleanup —
    /// the M11 origin loop calls this on every hop transition AND on
    /// error.
    DeleteWatchpoint {
        id: i64,
    },
    /// Reverse-continue until any breakpoint/watchpoint fires or the
    /// recording start is reached. Worker returns a stop-reason record
    /// `{ "reason": "watchpoint" | "recording-start" | ..., "watchpointId": i64 }`.
    ReverseContinue,
    /// Read the current program counter — used for the stack-slot
    /// reuse guard (spec §6.3 "verify the writing instruction").
    CurrentPc,
    /// Read the currently-selected thread id. Used by the cross-thread
    /// guard (spec §6.3) to detect writes from a non-querying thread.
    CurrentThread,
    /// Switch the replay session to thread `tid`. Used after the
    /// cross-thread guard fires so the operand-snapshot read targets
    /// the writing thread's frame.
    SelectThread {
        tid: u32,
    },
    /// Re-execute the half-open tick interval `[tick_lo, tick_hi)` in the replay
    /// worker and return materialized omniscient map images for that interval.
    ///
    /// The response is a [`MaterializeIntervalResponse`] JSON envelope whose
    /// `memwrites_base64` field contains an authoritative `WLOG` image. When
    /// present, `linehits_base64` contains an authoritative `LHTS|v1` image. The
    /// db-backend production adapter decodes both through the same
    /// `server_prep_encoding` paths used by collapse/warm restart.
    MaterializeInterval {
        tick_lo: u64,
        tick_hi: u64,
    },
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum TtdTracepointEvalMode {
    ReadOnlyExpression,
    EmulatedFunction,
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum TtdTracepointCallingConvention {
    Win64,
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum TtdTracepointValueClass {
    Void,
    Bool,
    I64,
    U64,
    Pointer,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct TtdTracepointFunctionSignature {
    pub calling_convention: TtdTracepointCallingConvention,
    pub return_class: TtdTracepointValueClass,
    pub argument_classes: Vec<TtdTracepointValueClass>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct TtdTracepointFunctionCallRequest {
    pub target_expression: String,
    #[serde(default)]
    pub call_expression: Option<String>,
    #[serde(default)]
    pub signature: Option<TtdTracepointFunctionSignature>,
    #[serde(default)]
    pub arguments: Vec<u64>,
    pub return_address: Option<u64>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct TtdTracepointEvalRequest {
    pub mode: TtdTracepointEvalMode,
    pub expression: Option<String>,
    pub function_call: Option<TtdTracepointFunctionCallRequest>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct TtdTracepointFunctionInvocationSummary {
    pub target_expression: String,
    pub resolved_address: u64,
    pub argument_count: usize,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct TtdTracepointEvalDiagnostic {
    pub code: String,
    pub message: String,
    pub detail: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TtdTracepointEvalResponseEnvelope {
    pub mode: TtdTracepointEvalMode,
    pub replay_state_preserved: bool,
    pub value: Option<ValueRecordWithType>,
    #[serde(default)]
    pub return_value: Option<ValueRecordWithType>,
    #[serde(default)]
    pub return_value_class: Option<TtdTracepointValueClass>,
    pub return_value_u64: Option<u64>,
    pub invocation: Option<TtdTracepointFunctionInvocationSummary>,
    pub diagnostic: Option<TtdTracepointEvalDiagnostic>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct MaterializeIntervalResponse {
    pub tick_lo: u64,
    pub tick_hi: u64,
    pub format: String,
    pub memwrites_base64: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub linehits_base64: Option<String>,
}

#[cfg(test)]
#[allow(clippy::panic, clippy::unwrap_used)]
mod tests {
    use super::*;

    #[test]
    fn materialize_interval_query_serializes_with_worker_wire_shape() {
        let query = ReplayQuery::MaterializeInterval {
            tick_lo: 100,
            tick_hi: 200,
        };
        let json = serde_json::to_string(&query).unwrap();

        assert_eq!(json, r#"{"kind":"MaterializeInterval","tick_lo":100,"tick_hi":200}"#);
        let decoded: ReplayQuery = serde_json::from_str(&json).unwrap();
        match decoded {
            ReplayQuery::MaterializeInterval { tick_lo, tick_hi } => {
                assert_eq!(tick_lo, 100);
                assert_eq!(tick_hi, 200);
            }
            other => panic!("unexpected decoded query: {other:?}"),
        }
    }

    #[test]
    fn materialize_interval_response_serializes_worker_payload() {
        let response = MaterializeIntervalResponse {
            tick_lo: 100,
            tick_hi: 200,
            format: "WLOG".to_string(),
            memwrites_base64: "V0xPRw==".to_string(),
            linehits_base64: None,
        };

        assert_eq!(
            serde_json::to_string(&response).unwrap(),
            r#"{"tickLo":100,"tickHi":200,"format":"WLOG","memwritesBase64":"V0xPRw=="}"#
        );
    }

    #[test]
    fn materialize_interval_response_serializes_optional_linehits_payload() {
        let response = MaterializeIntervalResponse {
            tick_lo: 100,
            tick_hi: 200,
            format: "WLOG".to_string(),
            memwrites_base64: "V0xPRw==".to_string(),
            linehits_base64: Some("TEhUUw==".to_string()),
        };

        assert_eq!(
            serde_json::to_string(&response).unwrap(),
            r#"{"tickLo":100,"tickHi":200,"format":"WLOG","memwritesBase64":"V0xPRw==","linehitsBase64":"TEhUUw=="}"#
        );
    }
}
