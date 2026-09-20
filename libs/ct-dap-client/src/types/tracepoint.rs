use serde::{Deserialize, Serialize};
use serde_repr::{Deserialize_repr, Serialize_repr};
use std::collections::HashMap;

use super::common::ProgramEvent;
use super::values::StringAndValueTuple;

#[derive(Debug, Default, Copy, Clone, PartialEq, Serialize_repr, Deserialize_repr)]
#[repr(u8)]
pub enum TracepointMode {
    #[default]
    TracInlineCode,
    TracExpandable,
    TracVisual,
}

#[derive(Debug, Default, Copy, Clone, PartialEq, Serialize_repr, Deserialize_repr)]
#[repr(u8)]
pub enum StopType {
    #[default]
    Trace,
    History,
    State,
    FollowHistory,
    NoEvent,
}

#[derive(Debug, Default, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Tracepoint {
    pub tracepoint_id: usize,
    pub mode: TracepointMode,
    pub line: usize,
    pub offset: i64,
    pub name: String,
    pub expression: String,
    pub last_render: usize,
    pub is_disabled: bool,
    pub is_changed: bool,
    // No `lang` field (LRS-1): the one that used to be here put the `Lang`
    // ORDINAL on `ct/run-tracepoints`, the db-backend never read it, and it
    // was deleted on both sides rather than moved to a name.  Mirrors
    // `db_backend::task::Tracepoint`.
    pub results: Vec<Stop>,
    pub tracepoint_error: String,
}

#[derive(Debug, Default, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Stop {
    pub tracepoint_id: usize,
    pub time: u64,
    pub line: i64,
    pub path: String,
    pub offset: usize,
    pub address: String,
    pub iteration: usize,
    pub result_index: usize,
    pub event: usize,
    pub mode: TracepointMode,
    pub locals: Vec<StringAndValueTuple>,
    pub when_max: usize,
    pub when_min: usize,
    pub error_message: String,
    pub event_type: StopType,
    pub description: String,
    pub rr_ticks: usize,
    pub function_name: String,
    pub key: String,
    // No `lang` field (LRS-1); see `Tracepoint`.  Mirrors
    // `db_backend::task::Stop`, which never set it.
}

#[derive(Debug, Default, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct TraceSession {
    pub tracepoints: Vec<Tracepoint>,
    pub found: Vec<Stop>,
    pub last_count: usize,
    pub results: HashMap<i64, Vec<Stop>>,
    pub id: usize,
}

#[derive(Debug, Default, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct RunTracepointsArg {
    pub session: TraceSession,
    pub stop_after: i64,
}

#[derive(Debug, Default, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct TracepointResultsAggregate {
    pub session_id: usize,
    pub results: Vec<Stop>,
    pub errors: HashMap<usize, String>,
}

#[derive(Debug, Default, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct TraceUpdate {
    #[serde(rename = "updateID")]
    pub update_id: usize,
    pub first_update: bool,
    #[serde(rename = "sessionID")]
    pub session_id: usize,
    pub tracepoint_errors: HashMap<usize, String>,
    pub count: usize,
    pub total_count: usize,
    pub refresh_event_log: bool,
}

#[derive(Debug, Default, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct TracepointId {
    pub id: usize,
}

#[derive(Debug, Default, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct TracepointResults {
    pub session_id: usize,
    pub tracepoint_id: usize,
    pub tracepoint_values: Vec<Vec<StringAndValueTuple>>,
    pub events: Vec<ProgramEvent>,
    pub last_in_session: bool,
    pub first_update: bool,
}

#[cfg(test)]
mod tests {
    use super::*;

    fn a_tracepoint() -> Tracepoint {
        Tracepoint {
            tracepoint_id: 1,
            mode: TracepointMode::TracInlineCode,
            line: 5,
            offset: -1,
            name: "main.c".to_string(),
            expression: "log(x)".to_string(),
            last_render: 0,
            is_disabled: false,
            is_changed: true,
            results: vec![],
            tracepoint_error: String::new(),
        }
    }

    /// LRS-1: the request this client sends on `ct/run-tracepoints` carries
    /// no `lang` key — the `Lang` ordinal that used to ride here is gone, not
    /// renamed.  The db-backend's own pin is `task::tests::
    /// run_tracepoints_payload_carries_no_lang`.
    #[test]
    fn run_tracepoints_request_carries_no_lang() {
        let args = RunTracepointsArg {
            session: TraceSession {
                tracepoints: vec![a_tracepoint()],
                found: vec![],
                last_count: 0,
                results: Default::default(),
                id: 1,
            },
            stop_after: -1,
        };
        let json = serde_json::to_string(&args).expect("serialise");
        assert!(!json.contains("\"lang\""), "{json}");
        assert!(json.contains(r#""tracepointId":1"#), "{json}");
    }

    /// The `ct/tracepoint-results` event as the db-backend emits it since
    /// LRS-1 — no `lang` on a `Stop` — decodes; and so does the shape an
    /// older db-backend emits, with `"lang": 0`, because this side never read
    /// the field either.
    #[test]
    fn tracepoint_results_decode_with_and_without_a_legacy_lang() {
        let stop = r#"{"tracepointId":1,"time":0,"line":5,"path":"main.c","offset":0,"address":"main.c:5","iteration":0,"resultIndex":0,"event":3,"mode":0,"locals":[],"whenMax":0,"whenMin":0,"errorMessage":"","eventType":0,"description":"","rrTicks":3,"functionName":"main","key":"""#;
        for tail in ["}", r#","lang":0}"#, r#","lang":"c"}"#] {
            let text = format!(r#"{{"sessionId":1,"results":[{stop}{tail}],"errors":{{}}}}"#);
            let decoded: TracepointResultsAggregate =
                serde_json::from_str(&text).unwrap_or_else(|e| panic!("{tail}: {e}"));
            assert_eq!(decoded.results.len(), 1);
            assert_eq!(decoded.results[0].rr_ticks, 3);
        }
        let json = serde_json::to_string(&Stop::default()).expect("serialise");
        assert!(!json.contains("\"lang\""), "{json}");
    }
}
