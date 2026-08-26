use serde::{Deserialize, Serialize};

use crate::lang::Lang;
use crate::task::{Action, Breakpoint, CtLoadLocalsArguments, LoadHistoryArg, Location, ProgramEvent};
use crate::value::ValueRecordWithType;

/// [`crate::task::CtLoadLocalsArguments`] as it travels the native replay
/// worker socket.
///
/// Field-for-field identical to the DAP-facing struct except that `lang` is
/// carried as its [`Lang::wire_name`] rather than as its `#[repr(u8)]`
/// ordinal.  The DAP-facing struct cannot simply change representation: the
/// Nim frontend sends `lang` as an integer on the `ct/load-locals` hop
/// (`src/frontend/viewmodel/store/replay_data_store.nim` builds it by hand),
/// and that hop is out of scope here.  The worker socket is a different hop
/// between two Rust crates and is de-ordinalised.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Default)]
#[serde(rename_all = "camelCase")]
pub struct WireLoadLocalsArguments {
    pub rr_ticks: i64,
    pub count_budget: i64,
    pub min_count_limit: i64,
    #[serde(with = "crate::lang::lang_wire")]
    pub lang: Lang,
    pub watch_expressions: Vec<String>,
    pub depth_limit: i64,
}

impl From<CtLoadLocalsArguments> for WireLoadLocalsArguments {
    fn from(arg: CtLoadLocalsArguments) -> Self {
        WireLoadLocalsArguments {
            rr_ticks: arg.rr_ticks,
            count_budget: arg.count_budget,
            min_count_limit: arg.min_count_limit,
            lang: arg.lang,
            watch_expressions: arg.watch_expressions,
            depth_limit: arg.depth_limit,
        }
    }
}

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
        arg: WireLoadLocalsArguments,
    },
    LoadReturnValue {
        #[serde(with = "crate::lang::lang_wire")]
        lang: Lang,
        depth_limit: Option<usize>,
    },
    LoadValue {
        expression: String,
        #[serde(with = "crate::lang::lang_wire")]
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
    SeekToTicks {
        ticks: i64,
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
    /// Remove all active watchpoints. Used by the RR origin loop because
    /// `ReverseContinue` may internally recreate the watchpoint and return a
    /// different live id than the one originally installed.
    DeleteWatchpoints,
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

    /// The one cross-repo channel that used to carry `Lang` as an integer.
    /// It must now carry a name; an ordinal here would be read by
    /// `codetracer-native-backend`'s *differently laid out* enum.
    #[test]
    fn load_value_carries_the_language_by_name_not_ordinal() {
        let json = serde_json::to_string(&ReplayQuery::LoadValue {
            expression: "x".to_string(),
            lang: Lang::Cpp,
            depth_limit: Some(3),
        })
        .unwrap();
        assert_eq!(
            json,
            r#"{"kind":"LoadValue","expression":"x","lang":"cpp","depth_limit":3}"#
        );
        assert!(!json.contains(r#""lang":1"#), "ordinal leaked onto the wire: {json}");
    }

    #[test]
    fn load_return_value_carries_the_language_by_name() {
        let json = serde_json::to_string(&ReplayQuery::LoadReturnValue {
            lang: Lang::Nim,
            depth_limit: None,
        })
        .unwrap();
        assert_eq!(json, r#"{"kind":"LoadReturnValue","lang":"nim","depth_limit":null}"#);
    }

    /// The exact byte string here is parsed back by
    /// `codetracer-native-backend`'s
    /// `query::tests::parses_the_codetracer_cores_load_locals_wire_shape`.
    /// The two crates are never linked together, so the wire is the only
    /// place the contract can be pinned.
    #[test]
    fn load_locals_carries_the_language_by_name() {
        let arg = CtLoadLocalsArguments {
            rr_ticks: 7,
            count_budget: 3000,
            min_count_limit: 50,
            lang: Lang::C,
            watch_expressions: vec!["a".to_string()],
            depth_limit: -1,
        };
        let json = serde_json::to_string(&ReplayQuery::LoadLocals { arg: arg.into() }).unwrap();
        assert_eq!(
            json,
            r#"{"kind":"LoadLocals","arg":{"rrTicks":7,"countBudget":3000,"minCountLimit":50,"lang":"c","watchExpressions":["a"],"depthLimit":-1}}"#
        );
    }

    /// A language the native backend cannot debug still travels as a name, so
    /// the worker can refuse it *and say which one*.  An ordinal would leave
    /// it nothing to name.
    #[test]
    fn load_locals_carries_backend_only_languages_by_name_too() {
        let arg = CtLoadLocalsArguments {
            lang: Lang::Php,
            ..CtLoadLocalsArguments::default()
        };
        let json = serde_json::to_string(&ReplayQuery::LoadLocals { arg: arg.into() }).unwrap();
        assert!(json.contains(r#""lang":"php""#), "{json}");
        assert!(!json.contains(r#""lang":39"#), "ordinal leaked onto the wire: {json}");
    }

    /// Every language must survive the socket, including the ones the native
    /// backend does not support — rejecting them is the *worker's* job, and it
    /// must be able to name what it is rejecting.
    #[test]
    fn every_language_round_trips_through_the_worker_socket() {
        for lang in Lang::ALL {
            let json = serde_json::to_string(&ReplayQuery::LoadValue {
                expression: "x".to_string(),
                lang,
                depth_limit: None,
            })
            .unwrap();
            assert!(
                json.contains(&format!(r#""lang":"{}""#, lang.wire_name())),
                "{lang:?} -> {json}"
            );
            match serde_json::from_str::<ReplayQuery>(&json).unwrap() {
                ReplayQuery::LoadValue { lang: decoded, .. } => assert_eq!(decoded, lang),
                other => panic!("unexpected decoded query: {other:?}"),
            }
        }
    }

    /// A bare integer must no longer be accepted: silently reading `1` as
    /// `Cpp` is exactly the contract this change removes.
    #[test]
    fn an_ordinal_on_the_wire_is_rejected() {
        let err = serde_json::from_str::<ReplayQuery>(
            r#"{"kind":"LoadValue","expression":"x","lang":1,"depth_limit":null}"#,
        )
        .expect_err("an ordinal must not deserialize as a language");
        let message = err.to_string();
        assert!(message.contains("string"), "unhelpful error: {message}");
    }

    #[test]
    fn an_unknown_language_name_is_rejected_and_named() {
        let err = serde_json::from_str::<ReplayQuery>(
            r#"{"kind":"LoadValue","expression":"x","lang":"perl","depth_limit":null}"#,
        )
        .expect_err("an unknown language name must not deserialize");
        assert!(err.to_string().contains("perl"), "error does not name it: {err}");
    }

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
