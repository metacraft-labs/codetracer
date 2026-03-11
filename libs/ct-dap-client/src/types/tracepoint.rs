use serde::{Deserialize, Serialize};
use serde_repr::{Deserialize_repr, Serialize_repr};
use std::collections::HashMap;

use super::common::{Lang, ProgramEvent};
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
    pub lang: Lang,
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
    pub lang: Lang,
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
