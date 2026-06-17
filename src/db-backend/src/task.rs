// use std::path::PathBuf;
use core::fmt;
use std::cmp::min;
use std::collections::HashMap;
use std::ops;
use std::time::{SystemTime, UNIX_EPOCH};

use codetracer_trace_types::{CallKey, EventLogKind, StepId, TypeKind};
use num_derive::FromPrimitive;
use serde::{Deserialize, Deserializer, Serialize};
use serde_repr::*;

/// Deserializes a `T` that may be JSON `null`, returning `T::default()` for null.
fn deserialize_null_default<'de, D, T>(deserializer: D) -> Result<T, D::Error>
where
    D: Deserializer<'de>,
    T: Default + Deserialize<'de>,
{
    Ok(Option::<T>::deserialize(deserializer)?.unwrap_or_default())
}

use crate::lang::*;
use crate::value::{Type, Value, ValueRecordWithType};
use schemars::JsonSchema;

// IMPORTANT: must keep in sync with `EventLogKind` definition in common_types.nim!
pub const EVENT_KINDS_COUNT: usize = 14;
const NO_DEPTH_LIMIT: i64 = -1;

/// args for `ct/load-locals`
#[derive(Serialize, Deserialize, Debug, PartialEq, Default, Clone, JsonSchema)]
#[serde(rename_all = "camelCase")]
pub struct CtLoadLocalsArguments {
    pub rr_ticks: i64,
    pub count_budget: i64,
    pub min_count_limit: i64,
    pub lang: Lang,
    pub watch_expressions: Vec<String>,
    pub depth_limit: i64, // for easier compat with our nim code: NO_DEPTH_LIMIT = -1 for None for now
}

/// response for `ct/load-locals`
#[derive(Serialize, Deserialize, Debug, PartialEq, Default, Clone, JsonSchema)]
#[serde(rename_all = "camelCase")]
pub struct CtLoadLocalsResponseBody {
    pub locals: Vec<Variable>,
}

/// flow mode for flow preloader
#[derive(Debug, Default, Copy, Clone, FromPrimitive, Serialize_repr, Deserialize_repr, PartialEq, JsonSchema)]
#[repr(u8)]
pub enum FlowMode {
    #[default]
    Call,
    Diff,
}

/// args for `ct/load-locals`
#[derive(Serialize, Deserialize, Debug, PartialEq, Default, Clone, JsonSchema)]
#[serde(rename_all = "camelCase")]
pub struct CtLoadFlowArguments {
    pub flow_mode: FlowMode,
    pub location: Location,
}

/// args for `ct/update-table`: actually Datatables.net produces those most of this: `TableArgs`
#[derive(Debug, Default, Clone, Serialize, Deserialize, JsonSchema)]
#[serde(rename_all(serialize = "camelCase", deserialize = "camelCase"))]
pub struct UpdateTableArgs {
    pub table_args: TableArgs,
    /// The Nim JS frontend serializes `array[EventLogKind, bool]` as a JSON
    /// object with string keys (`{"0": true, "1": true, ...}`), while the Rust
    /// side expects a JSON array.  Additionally, Nim 2.2's JS backend serializes
    /// `bool` values as numbers (1/0) rather than JSON booleans (true/false).
    /// This custom deserializer handles all three formats transparently.
    #[serde(deserialize_with = "deserialize_selected_kinds")]
    pub selected_kinds: [bool; EVENT_KINDS_COUNT],
    pub is_trace: bool,
    /// Index into the in-memory event-slot table (`EventDb::single_tables`):
    /// `0` is the global event log, slot `N + 1` is the result table for
    /// tracepoint `N`.  M-REC-4 renamed this from the historically
    /// overloaded `trace_id` to `event_slot`; "trace_id" is now reserved for
    /// OpenTelemetry W3C TraceContext (parent spec §2's third meaning).
    /// JSON wire-format key is `eventSlot` (serde camelCase); the matching
    /// Nim renames are M-REC-5 wire-format work.
    pub event_slot: usize,
}

/// Interpret a JSON value as a boolean, treating numeric values as truthy/falsy.
/// Nim 2.2's JS backend serializes `bool` values in `array[enum, bool]` as
/// numbers (1/0) rather than JSON booleans (true/false). This helper handles
/// both representations transparently.
fn value_as_truthy(v: &serde_json::Value) -> bool {
    match v {
        serde_json::Value::Bool(b) => *b,
        serde_json::Value::Number(n) => n.as_i64().unwrap_or(0) != 0,
        _ => false,
    }
}

fn deserialize_selected_kinds<'de, D>(deserializer: D) -> Result<[bool; EVENT_KINDS_COUNT], D::Error>
where
    D: serde::Deserializer<'de>,
{
    use serde::de;
    use serde_json::Value;

    let value = Value::deserialize(deserializer)?;
    match value {
        Value::Array(arr) => {
            if arr.len() != EVENT_KINDS_COUNT {
                return Err(de::Error::custom(format!(
                    "expected array of length {}, got {}",
                    EVENT_KINDS_COUNT,
                    arr.len()
                )));
            }
            let mut result = [false; EVENT_KINDS_COUNT];
            for (i, v) in arr.into_iter().enumerate() {
                result[i] = value_as_truthy(&v);
            }
            Ok(result)
        }
        Value::Object(map) => {
            // Handle Node.js Buffer format: {"data": [1,1,1,...], "type": "Buffer"}
            // Nim 2.2's JS backend serializes array[enum, bool] as a Buffer.
            if let Some(Value::Array(data_arr)) = map.get("data")
                && map.get("type").and_then(Value::as_str) == Some("Buffer")
            {
                let mut result = [false; EVENT_KINDS_COUNT];
                for (i, v) in data_arr.iter().enumerate() {
                    if i < EVENT_KINDS_COUNT {
                        result[i] = value_as_truthy(v);
                    }
                }
                return Ok(result);
            }
            // Handle plain object format: {"0": true, "1": true, ...}
            let mut result = [false; EVENT_KINDS_COUNT];
            for (key, val) in &map {
                if let Ok(idx) = key.parse::<usize>()
                    && idx < EVENT_KINDS_COUNT
                {
                    result[idx] = value_as_truthy(val);
                }
            }
            Ok(result)
        }
        _ => Err(de::Error::custom("selectedKinds must be an array or object")),
    }
}

/// response for `ct/updated-table`: wrapping mostly Datatables.net data (in `TableData` in `table_update.data`)
#[derive(Serialize, Deserialize, Debug, PartialEq, Default, Clone, JsonSchema)]
#[serde(rename_all = "camelCase")]
pub struct CtUpdatedTableResponseBody {
    pub table_update: TableUpdate,
}

/// documentation
#[derive(Debug, Default, Clone, Serialize, Deserialize, JsonSchema)]
#[serde(rename_all = "camelCase")]
pub struct CoreTrace {
    pub replay: bool,
    pub binary: String,
    pub program: Vec<String>,
    pub paths: Vec<String>,
    /// Recording identifier (UUIDv7, canonical lowercase hyphenated 36-char
    /// form).  M-REC-4 renamed this from the pre-migration `trace_id: i64`;
    /// the Nim sibling `CoreTraceObject.recordingId` (M-REC-3) already sends
    /// a string here, so this field's type also flipped to `String`.  The
    /// JSON wire-format key is `recordingId` (serde camelCase).
    pub recording_id: String,
    pub calltrace: bool,
    pub preload_enabled: bool,
    pub call_args_enabled: bool,
    pub trace_enabled: bool,
    pub history_enabled: bool,
    pub events_enabled: bool,
    pub telemetry: bool,
    pub imported: bool,
    pub test: bool,
    pub debug: bool,
    pub trace_output_folder: String,
    //   pub base: String
}

// #[derive(schemars::JsonSchema)]
// pub struct Definitions {
//     CoreTrace: CoreTrace,
//     ConfigureArg: ConfigureArg,
// }

#[derive(Debug, Default, Clone, Serialize, Deserialize, JsonSchema)]
#[serde(rename_all = "camelCase")]
pub struct ConfigureArg {
    pub lang: Lang,
    pub trace: CoreTrace,
}

#[derive(Debug, Default, Clone, Serialize, Deserialize, JsonSchema)]
#[serde(rename_all = "camelCase")]
pub struct StepArg {
    pub action: Action,
    pub reverse: bool,
    pub repeat: usize,
    pub complete: bool,
    pub skip_internal: bool,
    pub skip_no_source: bool,
}

#[derive(Debug, Default, Serialize, Deserialize)]
pub struct EmptyArg {}

/// Information about a single process recorded in a multi-process trace.
///
/// This mirrors `ct_native_replay::multiprocess::ProcessInfo` so that the
/// JSON payload returned by the worker's `GetProcessInfo` query deserializes
/// without any field renaming.
///
/// Used by the DAP `threads` handler to enumerate threads (one per process)
/// for multi-process recordings (fork/exec). For non-multiprocess traces the
/// backend returns a synthetic single-entry vector with `pid = 0` and
/// `name = "main"`.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct ProcessInfo {
    /// Process ID (as recorded; preserved across replay).
    pub pid: u32,
    /// Parent process ID. `0` for the root of the recording or when the
    /// parent was already running before recording started.
    pub ppid: u32,
    /// Exit status: `Some(code)` for normal exit, `Some(-signal)` for
    /// signal-terminated processes, `None` if unknown / still running.
    pub exit_code: Option<i32>,
    /// Command line of the process, including arguments.
    pub command: String,
}

#[derive(Debug, Default, Clone, Serialize, Deserialize, PartialEq, JsonSchema)]
#[serde(rename_all(serialize = "camelCase", deserialize = "camelCase"))]
pub struct Variable {
    pub expression: String,
    pub value: Value,
    // for db traces: usually NO_ADDRESS = -1
    // used for now for rr traces
    pub address: i64,
    /// Per spec §3.2.3, every value-bearing response carries a per-value
    /// `OriginSummary`. For `ct/load-locals` the summary is computed
    /// eagerly (see `Handler::build_origin_summary_for_local`). Omitted
    /// from the wire when not populated so legacy consumers stay
    /// compatible.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub origin_summary: Option<OriginSummary>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all(serialize = "camelCase", deserialize = "camelCase"))]
pub struct VariableWithRecord {
    pub expression: String,
    pub value: ValueRecordWithType,
    pub address: i64,
}

// pub struct ValueRecordAndType {
//     value: ValueRecord,
//     typ: Type,
// }

#[derive(Debug, Default, Clone, Serialize, Deserialize)]
#[serde(rename_all(serialize = "camelCase", deserialize = "camelCase"))]
pub struct Instruction {
    pub name: String,
    pub args: String,
    pub other: String,
    pub offset: i64,
    pub high_level_path: String,
    pub high_level_line: i64,
}

impl Instruction {
    pub fn empty(line: i64, path: &str, step_id: i64) -> Self {
        Instruction {
            args: "".to_string(),
            high_level_line: line,
            high_level_path: path.to_string(),
            name: "".to_string(),
            offset: step_id,
            other: "".to_string(),
        }
    }
}

#[derive(Debug, Default, Clone, Serialize, Deserialize)]
#[serde(rename_all(serialize = "camelCase", deserialize = "camelCase"))]
pub struct Instructions {
    pub address: usize,
    pub instructions: Vec<Instruction>,
    pub error: String,
}

pub const EMPTY_ARG: EmptyArg = EmptyArg {};
pub const NO_PATH: &str = "<unknown>";
pub const NO_POSITION: i64 = -1;
pub const NO_EVENT: i64 = -1;
pub const NO_OFFSET: i64 = -1;
pub const NO_INDEX: i64 = -1;
pub const NO_DEPTH: usize = 0;
pub const NO_KEY: &str = "-1";
pub const NO_STEP_ID: i64 = -1;
pub const NO_ADDRESS: i64 = -1;

#[derive(Debug, Default, Copy, Clone, FromPrimitive, Serialize_repr, Deserialize_repr, PartialEq)]
#[repr(u8)]
pub enum QueryKind {
    #[default]
    CommandQuery,
    FileQuery,
    ProgramQuery,
}

#[derive(Debug, Default, Clone, Serialize, Deserialize)]
#[serde(rename_all(serialize = "camelCase", deserialize = "camelCase"))]
pub struct CommandPanelResult {
    kind: QueryKind,
    value: String,
    value_highlighted: String,
    level: NotificationKind,

    // for now only ProgramQuery results
    // no file/command results
    code_snippet: CodeSnippet,
    location: Location,
}

impl CommandPanelResult {
    pub fn new(kind: QueryKind, level: NotificationKind, value: &str) -> Self {
        CommandPanelResult {
            kind,
            value: value.to_string(),
            value_highlighted: value.to_string(),
            level,
            code_snippet: CodeSnippet::default(),
            location: Location::default(),
        }
    }
    pub fn program_search_result(text: &str, code_snippet: CodeSnippet, location: Location) -> Self {
        CommandPanelResult {
            kind: QueryKind::ProgramQuery,
            value: text.to_string(),
            value_highlighted: text.to_string(),
            level: NotificationKind::Info,
            code_snippet,
            location,
        }
    }

    pub fn error(message: &str) -> Self {
        Self::new(QueryKind::ProgramQuery, NotificationKind::Error, message)
    }

    pub fn warning(message: &str) -> Self {
        Self::new(QueryKind::ProgramQuery, NotificationKind::Warning, message)
    }

    pub fn success(message: &str) -> Self {
        Self::new(QueryKind::ProgramQuery, NotificationKind::Success, message)
    }
}

#[derive(Debug, Default, Clone, Serialize, Deserialize)]
#[serde(rename_all(serialize = "camelCase", deserialize = "camelCase"))]
pub struct CodeSnippet {
    pub line: usize,
    pub source: String,
}

#[derive(Debug, Default, Clone, Serialize, Deserialize, PartialEq, JsonSchema)]
#[serde(default, rename_all(serialize = "camelCase", deserialize = "camelCase"))]
pub struct Location {
    #[serde(deserialize_with = "deserialize_null_default")]
    pub path: String,
    pub line: i64,
    /// M1 — 1-indexed column the step landed on, or `None` for
    /// recordings that don't carry column data (legacy line-only
    /// traces).  Surfaced through the DAP `ct/complete-move` event so
    /// the GUI's cursor / breakpoint marker can anchor at the right
    /// column on traces that recorded it.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub column: Option<i64>,
    #[serde(deserialize_with = "deserialize_null_default")]
    pub function_name: String,
    #[serde(deserialize_with = "deserialize_null_default")]
    pub high_level_path: String,
    pub high_level_line: i64,
    #[serde(deserialize_with = "deserialize_null_default")]
    pub high_level_function_name: String,
    #[serde(deserialize_with = "deserialize_null_default")]
    pub low_level_path: String,
    pub low_level_line: i64,
    pub rr_ticks: RRTicks,
    pub function_first: i64,
    pub function_last: i64,
    /// Source revision/generation for live sessions where one original path
    /// can have multiple debugger-visible contents. Legacy traces keep this at
    /// zero and fall back to path-only source identity.
    #[serde(default)]
    pub source_generation: i64,
    /// Optional digest for the source revision. Empty means the backend did
    /// not provide a stable content identity.
    #[serde(default, deserialize_with = "deserialize_null_default")]
    pub source_digest: String,
    pub event: i64,
    #[serde(deserialize_with = "deserialize_null_default")]
    pub expression: String,
    pub offset: i64,
    pub error: bool,
    pub callstack_depth: usize,
    pub originating_instruction_address: i64,
    #[serde(deserialize_with = "deserialize_null_default")]
    pub key: String,
    #[serde(deserialize_with = "deserialize_null_default")]
    pub global_call_key: String,

    /// Expansion parent chain: each entry is (path, line, expansion_first_line).
    /// Empty when the location is not inside a macro expansion.
    #[serde(default, deserialize_with = "deserialize_null_default")]
    pub expansion_parents: Vec<(String, i64, i64)>,
    /// Depth of the expansion chain (number of parent expansions).
    #[serde(default)]
    pub expansion_depth: usize,
    /// Index into the macro sourcemap's `expansions` array, or -1.
    #[serde(default)]
    pub expansion_id: i64,
    /// First line of the expansion range in the expanded file, or -1.
    #[serde(default)]
    pub expansion_first_line: i64,
    /// Last line of the expansion range in the expanded file, or -1.
    #[serde(default)]
    pub expansion_last_line: i64,
    /// Whether this location is inside a macro expansion.
    #[serde(default)]
    pub is_expanded: bool,

    pub missing_path: bool,
}

/// Response for `LoadLocationWithSourcemap` query from the native replay backend.
///
/// Contains the location with sourcemap translation applied (high_level = Nim source,
/// low_level = generated C) and a separate `c_location` for the C-level view.
#[derive(Debug, Default, Clone, Deserialize)]
#[serde(default, rename_all(serialize = "camelCase", deserialize = "camelCase"))]
pub struct LocationWithSourcemap {
    pub location: Location,
    pub c_location: Location,
}

impl Location {
    pub fn new(
        path: &str,
        line: i64,
        rr_ticks: RRTicks,
        function_name: &str,
        key: &str,
        global_call_key: &str,
        callstack_depth: usize,
    ) -> Location {
        Location {
            path: path.to_string(),
            line,
            // M1 — `Location::new` callers (the trace-reader path) do
            // not have a column at this layer.  The `load_location`
            // shim in `trace_reader.rs` overwrites `column` with the
            // step's recorded column right after this constructor
            // returns, so column-aware traces still surface the column
            // on the wire.
            column: None,
            high_level_path: path.to_string(),
            high_level_line: line,
            high_level_function_name: function_name.to_string(),
            low_level_path: path.to_string(),
            low_level_line: line,
            rr_ticks,
            function_name: function_name.to_string(),
            key: key.to_string(),
            global_call_key: global_call_key.to_string(),
            callstack_depth,

            function_first: NO_POSITION,
            function_last: NO_POSITION,
            source_generation: 0,
            source_digest: String::new(),
            event: NO_EVENT,
            expression: "".to_string(),
            offset: NO_OFFSET,
            error: false,
            originating_instruction_address: -1,
            expansion_parents: vec![],
            expansion_depth: 0,
            expansion_id: -1,
            expansion_first_line: -1,
            expansion_last_line: -1,
            is_expanded: false,
            missing_path: false,
        }
    }
}

#[derive(Debug, Default, Clone, Serialize, Deserialize)]
#[serde(rename_all(serialize = "camelCase", deserialize = "camelCase"))]
pub struct MoveState {
    pub status: String,
    pub location: Location,
    pub c_location: Location,
    pub main: bool,
    pub reset_flow: bool,
    pub stop_signal: RRGDBStopSignal,
    pub frame_info: FrameInfo,
}

#[derive(Debug, Default, Copy, Clone, FromPrimitive, Serialize_repr, Deserialize_repr, PartialEq)]
#[repr(u8)]
pub enum RRGDBStopSignal {
    #[default]
    NoStopSignal,
    SigsegvStopSignal,
    SigkillStopSignal,
    SighupStopSignal,
    SigintStopSignal,
    OtherStopSignal,
}

#[derive(Debug, Default, Copy, Clone, FromPrimitive, Serialize_repr, Deserialize_repr, PartialEq, JsonSchema)]
#[repr(u8)]
pub enum Action {
    #[default]
    StepIn,
    StepOut,
    Next,
    Continue,
    StepC,
    NextC,
    StepI,
    NextI,
    CoStepIn,
    CoNext,
    NonAction,
}

#[derive(Debug, Default, Clone, Serialize, Deserialize)]
#[serde(rename_all(serialize = "camelCase", deserialize = "camelCase"))]
pub struct FrameInfo {
    offset: usize,
    has_selected: bool,
}

#[derive(Debug, Default, Copy, Clone, PartialEq, Eq, Hash, Serialize, Deserialize, PartialOrd, Ord)]
pub struct Position(pub i64);

impl Position {
    pub fn inc(&self) -> Self {
        Position(self.0 + 1)
    }
}

#[derive(Debug, Default, Clone, Serialize, Deserialize, PartialEq, Eq, PartialOrd, Ord)]
pub struct StepCount(pub i64);

#[derive(Debug, Default, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct LoopId(pub i64);

#[derive(Debug, Default, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct LoopShapeId(pub i64);

#[derive(Debug, Default, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct Iteration(pub i64);

impl Iteration {
    pub fn inc(&mut self) {
        self.0 += 1;
    }
}

#[derive(Debug, Default, Clone, Serialize, Deserialize, PartialEq, Eq, PartialOrd, Ord, JsonSchema)]
pub struct RRTicks(pub i64);

#[derive(Debug, Default, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct BranchId(pub i64);

pub const NO_BRANCH_ID: BranchId = BranchId(-1);

pub const NO_LOOP_ID: LoopId = LoopId(-1);

pub const NOT_IN_A_LOOP: Iteration = Iteration(-1);

#[derive(Debug, Default, Clone, Serialize, Deserialize)]
pub struct FlowUpdateState {
    pub kind: FlowUpdateStateKind,
    #[serde(default)]
    pub steps: u64,
}

#[derive(Debug, Default, Copy, Clone, FromPrimitive, Serialize_repr, Deserialize_repr, PartialEq)]
#[repr(u8)]
pub enum FlowUpdateStateKind {
    #[default]
    FlowNotLoading,
    FlowWaitingForStart,
    FlowLoading,
    FlowFinished,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all(serialize = "camelCase", deserialize = "camelCase"))]
pub struct Loop {
    pub base: LoopId,
    pub base_iteration: Iteration,
    pub internal: Vec<LoopId>,
    pub first: Position,
    pub last: Position,
    pub registered_line: Position,
    pub iteration: Iteration,
    pub step_counts: Vec<StepCount>,
    pub rr_ticks_for_iterations: Vec<RRTicks>,
}

impl std::default::Default for Loop {
    fn default() -> Self {
        Loop {
            base: LoopId(0),
            base_iteration: Iteration(0),
            internal: vec![],
            first: Position(NO_POSITION),
            last: Position(NO_POSITION),
            registered_line: Position(NO_POSITION),
            iteration: Iteration(0),
            step_counts: vec![],
            rr_ticks_for_iterations: vec![],
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all(serialize = "camelCase", deserialize = "camelCase"))]
pub struct LoopShape {
    pub internal: Vec<LoopShapeId>,
    pub loop_id: LoopShapeId,
    pub base: LoopShapeId,
    pub first: Position,
    pub last: Position,
}

impl LoopShape {
    pub fn new(base: LoopShapeId, loop_id: LoopShapeId, first: Position, last: Position) -> Self {
        LoopShape {
            internal: vec![],
            base,
            loop_id,
            first,
            last,
        }
    }
}

impl Default for LoopShape {
    fn default() -> Self {
        Self {
            internal: vec![],
            base: LoopShapeId(0),
            loop_id: LoopShapeId(0),
            first: Position(NO_POSITION),
            last: Position(NO_POSITION),
        }
    }
}

#[derive(Debug, Default, Clone, Serialize, Deserialize)]
#[serde(rename_all(serialize = "camelCase", deserialize = "camelCase"))]
pub struct FlowEvent {
    pub kind: EventLogKind,
    pub text: String,
    // TODO: generalize this type/name as it is rr ticks for the system backend
    // and step id for db-backend
    pub rr_ticks: i64,
    pub metadata: String,
}

#[derive(Debug, Default, Clone, Serialize, Deserialize)]
#[serde(rename_all(serialize = "camelCase", deserialize = "camelCase"))]
pub struct FlowStep {
    pub position: Position,
    pub r#loop: LoopId,
    pub iteration: Iteration,
    pub step_count: StepCount,
    pub rr_ticks: RRTicks,
    pub before_values: HashMap<String, Value>,
    pub after_values: HashMap<String, Value>,
    pub expr_order: Vec<String>,
    pub events: Vec<FlowEvent>,
    /// Per spec §3.2.3, Omniscience-Flow overlay annotations carry a
    /// per-annotated-value `OriginSummary`. Keyed by variable name to
    /// match `before_values`/`after_values`. Each summary covers the
    /// origin of the after-value at this flow step (i.e. what the
    /// editor renders next to the annotation). On M2 (materialized
    /// trace, no omniscient DB) these are placeholders (per the
    /// §3.2.3 V1 defaults table).
    #[serde(default, skip_serializing_if = "HashMap::is_empty")]
    pub origin_summaries: HashMap<String, OriginSummary>,
}

// for now not sending last step id for line visit
// but this flow step object *can* contain info about several actual steps
// e.g. events from some of the next steps on the same line visit
// one can analyze the step id of the next step, or we can add this info to the object
impl FlowStep {
    pub fn new(
        position: i64,
        step_count: i64,
        step_id: StepId,
        iteration: Iteration,
        base: LoopId,
        events: Vec<FlowEvent>,
    ) -> Self {
        FlowStep {
            position: Position(position),
            r#loop: base,
            iteration,
            step_count: StepCount(step_count),
            rr_ticks: RRTicks(step_id.0),
            before_values: HashMap::default(),
            after_values: HashMap::default(),
            expr_order: vec![],
            events,
            origin_summaries: HashMap::default(),
        }
    }
}

#[derive(Debug, Default, Copy, Clone, FromPrimitive, Serialize_repr, Deserialize_repr, PartialEq)]
#[repr(u8)]
pub enum BranchState {
    #[default]
    Unknown,
    Taken,
    NotTaken,
}

#[derive(Debug, Default, Clone, Serialize, Deserialize)]
#[serde(rename_all(serialize = "camelCase", deserialize = "camelCase"))]
pub struct LoopIterationSteps {
    pub table: HashMap<usize, usize>,
}

#[derive(Debug, Default, Clone, Serialize, Deserialize)]
#[serde(rename_all(serialize = "camelCase", deserialize = "camelCase"))]
pub struct BranchesTaken {
    pub table: HashMap<usize, BranchState>,
}

#[derive(Debug, Default, Clone, Serialize, Deserialize)]
#[serde(rename_all(serialize = "camelCase", deserialize = "camelCase"))]
pub struct Branch {
    pub header_line: Position,
    pub code_first_line: Position,
    pub code_last_line: Position,
    pub branch_id: BranchId,
    pub opposite: Vec<BranchId>,
    pub status: BranchState,
    pub is_none: bool,
}

impl Branch {
    pub fn new() -> Branch {
        Branch {
            header_line: Position(NO_POSITION),
            code_first_line: Position(NO_POSITION),
            code_last_line: Position(NO_POSITION),
            branch_id: NO_BRANCH_ID,
            opposite: vec![],
            status: BranchState::Unknown,
            is_none: true,
        }
    }
}

#[derive(Debug, Default, Clone, Serialize, Deserialize)]
#[serde(rename_all(serialize = "camelCase", deserialize = "camelCase"))]
pub struct FlowViewUpdate {
    pub location: Location,
    pub position_step_counts: HashMap<Position, Vec<StepCount>>,
    pub steps: Vec<FlowStep>,
    pub loops: Vec<Loop>,
    pub branches_taken: Vec<Vec<BranchesTaken>>,
    pub loop_iteration_steps: Vec<Vec<LoopIterationSteps>>,
    pub relevant_step_count: Vec<usize>,
    pub comment_lines: Vec<Position>,
}

impl FlowViewUpdate {
    pub fn new(location: Location) -> Self {
        FlowViewUpdate {
            location,
            position_step_counts: HashMap::default(),
            steps: vec![],
            loops: vec![Loop::default()],
            branches_taken: vec![vec![BranchesTaken::default()]],
            loop_iteration_steps: vec![vec![LoopIterationSteps::default()]],
            relevant_step_count: vec![],
            comment_lines: vec![],
        }
    }

    pub fn add_step_count(&mut self, position: i64, step_count: i64) {
        self.position_step_counts
            .entry(Position(position))
            .or_default()
            .push(StepCount(step_count));
    }

    // ALSO: see note for load_flow in flow_preloader.rs
    // we know that branches_taken has at least
    // 1 element on two levels and also min with its size
    // is used to make sure the first index is correct
    #[allow(clippy::unwrap_used)]
    pub fn add_branches(&mut self, loop_id: i64, results: HashMap<usize, BranchState>) {
        let max_len = self.branches_taken.len() - 1;
        for (key, value) in results {
            self.branches_taken[min(loop_id, max_len as i64) as usize]
                .last_mut()
                .unwrap()
                .table
                .insert(key, value);
        }
    }
}

#[derive(Debug, Default, Clone, Serialize, Deserialize)]
#[serde(rename_all(serialize = "camelCase", deserialize = "camelCase"))]
pub struct FlowUpdate {
    pub view_updates: Vec<FlowViewUpdate>,
    pub location: Location,
    pub error: bool,
    pub error_message: String,
    pub finished: bool,
    pub status: FlowUpdateState,
}

impl FlowUpdate {
    pub fn new() -> Self {
        FlowUpdate {
            view_updates: vec![],
            location: Location::default(),
            error: false,
            error_message: "".to_string(),
            finished: false,
            status: FlowUpdateState {
                kind: FlowUpdateStateKind::FlowNotLoading,
                steps: 0,
            },
        }
    }

    pub fn error(error_message: &str) -> Self {
        FlowUpdate {
            view_updates: vec![],
            location: Location::default(),
            error: true,
            error_message: error_message.to_string(),
            finished: true,
            status: FlowUpdateState {
                kind: FlowUpdateStateKind::FlowNotLoading,
                steps: 0,
            },
        }
    }
}

#[derive(Debug, Default, Clone, Serialize, Deserialize, JsonSchema)]
#[serde(rename_all(serialize = "camelCase", deserialize = "camelCase"))]
pub struct ProgramEvent {
    pub kind: EventLogKind,
    /// Optional semantic display kind for rows whose trace-format enum is only
    /// a transport fallback. Empty means use `kind`.
    #[serde(default)]
    pub semantic_kind: String,
    pub content: String,
    pub rr_event_id: usize,
    pub high_level_path: String,
    pub high_level_line: i64,
    pub metadata: String,
    pub bytes: usize,
    pub stdout: bool,
    #[serde(rename = "directLocationRRTicks")]
    pub direct_location_rr_ticks: i64,
    pub tracepoint_result_index: i64,
    pub event_index: usize,
    #[serde(rename = "base64Encoded")]
    pub base64_encoded: bool,
    #[serde(rename = "maxRRTicks")]
    pub max_rr_ticks: i64,
    /// Source revision/generation for events whose location belongs to a
    /// versioned source identity. Legacy event streams keep this at zero.
    #[serde(default)]
    pub source_generation: i64,
    /// Optional stable source revision digest.
    #[serde(default)]
    pub source_digest: String,
}

#[derive(Debug, Default, Clone, Serialize, Deserialize)]
#[serde(rename_all(serialize = "camelCase", deserialize = "camelCase"))]
pub struct Call {
    pub key: String,

    // load calltrace only:
    pub children: Vec<Call>,
    // --
    pub depth: usize,
    pub location: Location,
    pub parent: Option<Box<Call>>,
    pub raw_name: String,

    // load-callstack only:
    pub args: Vec<CallArg>,
    pub return_value: Value,
    // --
    pub with_args_and_return: bool,
}

#[derive(Debug, Default, Clone, Serialize, Deserialize)]
#[serde(rename_all(serialize = "camelCase", deserialize = "camelCase"))]
pub struct FunctionLocation {
    pub path: String,
    pub name: String,
    pub key: String,
    pub force_reload: bool,
}

#[derive(Debug, Default, Clone, Serialize, Deserialize)]
pub struct SourceLocation {
    pub path: String,
    pub line: usize,
    /// Optional 1-indexed column for column-aware breakpoints (M1).
    /// `None` preserves the legacy line-only semantics.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub column: Option<i64>,
    /// Optional condition expression for the M9 column-aware
    /// conditional breakpoint surface.  `None` preserves the
    /// unconditional behaviour M1 shipped with.  Carried only by
    /// the breakpoint-set call sites; other consumers of
    /// `SourceLocation` (e.g. `get_closest_step_id`) ignore it.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub condition: Option<String>,
}

impl fmt::Display for SourceLocation {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self.column {
            Some(col) => write!(f, "{}:{}:{}", self.path, self.line, col),
            None => write!(f, "{}:{}", self.path, self.line),
        }
    }
}

#[derive(Debug, Default, Clone, Serialize, Deserialize)]
pub struct SourceCallJumpTarget {
    pub path: String,
    pub line: usize,
    pub token: String,
}

#[derive(Debug, Default, Clone, Serialize, Deserialize)]
pub struct CallSearchArg {
    pub value: String,
}

#[derive(Debug, Default, Clone, Serialize, Deserialize)]
#[serde(rename_all(serialize = "camelCase", deserialize = "camelCase"))]
pub struct LoadHistoryArg {
    pub expression: String,
    pub location: Location,
    pub is_forward: bool,
}

impl fmt::Display for SourceCallJumpTarget {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{}:{}:{}", self.token, self.path, self.line)
    }
}

#[derive(Debug, Default, Copy, Clone, FromPrimitive, Serialize_repr, Deserialize_repr, PartialEq)]
#[repr(u8)]
pub enum TracepointMode {
    #[default]
    TracInlineCode,
    TracExpandable,
    TracVisual,
}

#[derive(Debug, Default, Copy, Clone, FromPrimitive, Serialize_repr, Deserialize_repr, PartialEq)]
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
#[serde(rename_all(serialize = "camelCase", deserialize = "camelCase"))]
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
#[serde(rename_all(serialize = "camelCase", deserialize = "camelCase"))]
pub struct TraceResult {
    pub i: usize,
    pub result_index: usize,
    pub rr_ticks: usize,
}

#[derive(Debug, Default, Clone, Serialize, Deserialize)]
#[serde(rename_all(serialize = "camelCase", deserialize = "camelCase"))]
pub struct TracepointId {
    pub id: usize,
}

#[derive(Debug, Default, Clone, Serialize, Deserialize)]
#[serde(rename_all(serialize = "camelCase", deserialize = "camelCase"))]
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

impl TraceUpdate {
    pub fn new(
        session_id: usize,
        first_update: bool,
        tracepoint_id: usize,
        tracepoint_errors: HashMap<usize, String>,
    ) -> TraceUpdate {
        TraceUpdate {
            session_id,
            update_id: tracepoint_id,
            first_update,
            tracepoint_errors,
            count: 0,
            total_count: 0,
            refresh_event_log: false,
        }
    }
}

#[derive(Debug, Default, Clone, Serialize, Deserialize)]
#[serde(rename_all(serialize = "PascalCase", deserialize = "PascalCase"))]
pub struct StringAndValueTuple {
    pub field0: String,
    pub field1: Value,
}

/// a search value representation for server side processing
/// for datatables.net from our frontend
/// https://datatables.net/manual/server-side
#[derive(Debug, Default, Clone, Serialize, Deserialize, JsonSchema)]
#[serde(rename_all(serialize = "camelCase", deserialize = "camelCase"))]
pub struct SearchValue {
    pub value: String,
    pub regex: bool,
}

/// describes `orders` value for datatables.net from our frontend
/// https://datatables.net/manual/server-side#Sent-parameters
#[derive(Debug, Default, Clone, Serialize, Deserialize, JsonSchema)]
#[serde(rename_all(serialize = "camelCase", deserialize = "camelCase"))]
pub struct OrdValue {
    pub column: usize,
    pub dir: String,
}

/// fields for our datatables.net table rows in the frontend
#[derive(Debug, Default, Clone, Serialize, Deserialize, PartialEq, JsonSchema)]
#[serde(rename_all(serialize = "camelCase", deserialize = "camelCase"))]
pub struct TableRow {
    #[serde(rename = "directLocationRRTicks")]
    pub direct_location_rr_ticks: i64,
    #[serde(rename = "base64Encoded")]
    pub base64_encoded: bool,
    pub rr_event_id: usize,
    pub full_path: String,
    pub low_level_location: String,
    pub kind: EventLogKind,
    #[serde(default)]
    pub semantic_kind: String,
    pub content: String,
    pub metadata: String,
    pub stdout: bool,
    #[serde(default)]
    pub source_generation: i64,
    #[serde(default)]
    pub source_digest: String,
}

impl TableRow {
    pub fn new(event: &ProgramEvent) -> TableRow {
        TableRow {
            direct_location_rr_ticks: event.direct_location_rr_ticks,
            rr_event_id: event.rr_event_id,
            full_path: format!(
                "{}:{}",
                event
                    .high_level_path
                    .rsplit('/')
                    .next()
                    .unwrap_or(&event.high_level_path),
                event.high_level_line
            ),
            low_level_location: event.high_level_path.to_string(),
            kind: event.kind,
            semantic_kind: event.semantic_kind.clone(),
            content: event.content.to_string(),
            base64_encoded: event.base64_encoded,
            metadata: event.metadata.clone(),
            stdout: event.stdout,
            source_generation: event.source_generation,
            source_digest: event.source_digest.clone(),
        }
    }
}

/// describes what we use from Datatables.net ajax server side processing arg
/// https://datatables.net/manual/server-side
#[derive(Debug, Default, Clone, Serialize, Deserialize, PartialEq, JsonSchema)]
#[serde(rename_all(serialize = "camelCase", deserialize = "camelCase"))]
pub struct TableData {
    pub draw: usize,
    pub records_total: usize,
    pub records_filtered: usize,
    pub data: Vec<TableRow>,
}

/// data for a datatable (Datatables.net) update with some ct-specific trace fields
#[derive(Debug, Default, Clone, Serialize, Deserialize, PartialEq, JsonSchema)]
#[serde(rename_all(serialize = "camelCase", deserialize = "camelCase"))]
pub struct TableUpdate {
    pub data: TableData,
    pub is_trace: bool,
    /// Event-slot index this update belongs to (mirrors
    /// [`UpdateTableArgs::event_slot`]; see that field's doc for the
    /// M-REC-4 rename).  JSON wire-format key is `eventSlot`.
    pub event_slot: usize,
}

#[derive(Debug, Default, Clone, Serialize, Deserialize)]
#[serde(rename_all(serialize = "camelCase", deserialize = "camelCase"))]
pub struct TraceValues {
    pub id: usize,
    pub locals: Vec<Vec<StringAndValueTuple>>,
}

/// describes some aspects of datatables.net update columns objects
/// (https://datatables.net/)
#[derive(Debug, Default, Clone, Serialize, Deserialize, JsonSchema)]
#[serde(rename_all(serialize = "camelCase", deserialize = "camelCase"))]
pub struct UpdateColumns {
    pub data: String,
    pub name: String,
    pub orderable: bool,
    pub search: SearchValue,
    pub searchable: bool,
}

/// describing datatables.net args for server side processing
/// used from our frontend
/// https://datatables.net/manual/server-side
#[derive(Debug, Default, Clone, Serialize, Deserialize, JsonSchema)]
#[serde(rename_all(serialize = "camelCase", deserialize = "camelCase"))]
pub struct TableArgs {
    pub columns: Vec<UpdateColumns>,
    pub draw: usize,
    pub length: usize,
    pub order: Vec<OrdValue>,
    pub search: SearchValue,
    pub start: usize,
}

#[derive(Debug, Default, Clone, Serialize, Deserialize)]
#[serde(rename_all(serialize = "camelCase", deserialize = "camelCase"))]
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

impl Stop {
    #[allow(clippy::expect_used)]
    pub fn new(
        path: String,
        line: i64,
        locals: Vec<StringAndValueTuple>,
        step_id: usize,
        tracepoint_id: usize,
        result_index: usize,
        stop_type: StopType,
    ) -> Stop {
        let now = SystemTime::now();
        let time = now
            .duration_since(UNIX_EPOCH)
            .expect("expected now is always >= UNIX_EPOCH");
        let address = format!("{}:{}", path, line);
        Stop {
            tracepoint_id,
            time: time.as_secs(),
            line,
            path,
            address,
            result_index,
            event: step_id,
            locals,
            event_type: stop_type,
            rr_ticks: step_id,
            error_message: "".to_string(),
            ..Default::default()
        }
    }
}

#[derive(Debug, Default, Clone, Serialize, Deserialize)]
#[serde(rename_all(serialize = "camelCase", deserialize = "camelCase"))]
pub struct TraceSession {
    pub tracepoints: Vec<Tracepoint>,
    pub found: Vec<Stop>,
    pub last_count: usize,
    pub results: HashMap<i64, Vec<Stop>>,
    pub id: usize,
}

#[derive(Debug, Default, Clone, Serialize, Deserialize)]
#[serde(rename_all(serialize = "camelCase", deserialize = "camelCase"))]
pub struct RunTracepointsArg {
    pub session: TraceSession,
    pub stop_after: i64,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all(serialize = "camelCase", deserialize = "camelCase"))]
pub struct HistoryResultWithRecord {
    pub location: Location,
    pub value: ValueRecordWithType,
    pub time: u64,
    pub description: String, // copied from x; passed as arg from y; changed memory at addrs z;
}

#[derive(Debug, Default, Clone, Serialize, Deserialize)]
#[serde(rename_all(serialize = "camelCase", deserialize = "camelCase"))]
pub struct HistoryResult {
    pub location: Location,
    pub value: Value,
    pub time: u64,
    pub description: String,
    /// Per spec §3.2.3 the value-history popover entries carry a
    /// per-entry origin summary. Each summary is the origin of *that*
    /// historic value (not the current value). On a materialized trace
    /// without an omniscient DB (M2 default), these are emitted as
    /// placeholders (`is_placeholder: true`, non-null
    /// `placeholder_token`) — the frontend resolves them in batches
    /// via `ct/originSummary` (spec §5.3.2).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub origin_summary: Option<OriginSummary>,
}

impl HistoryResult {
    #[allow(clippy::expect_used)]
    pub fn new(loc: Location, val: Value, name: String) -> HistoryResult {
        let now = SystemTime::now();
        let time = now
            .duration_since(UNIX_EPOCH)
            .expect("expect that always now >= UNIX_EPOCH");
        HistoryResult {
            location: loc,
            value: val,
            time: time.as_secs(),
            description: name,
            origin_summary: None,
        }
    }
}

#[derive(Debug, Default, Clone, Serialize, Deserialize)]
#[serde(rename_all(serialize = "camelCase", deserialize = "camelCase"))]
pub struct HistoryUpdate {
    pub expression: String,
    pub address: i64,
    pub results: Vec<HistoryResult>,
    pub finish: bool,
}

impl HistoryUpdate {
    pub fn new(expression: String, address: i64, results: &[HistoryResult]) -> HistoryUpdate {
        HistoryUpdate {
            expression,
            address,
            results: results.to_vec(),
            finish: true,
        }
    }
}

// ===========================================================================
// Value Origin Tracking — wire types (M2).
//
// Mirrors the canonical types in spec §4.1 "Core types" of
// `codetracer-specs/GUI/Debugging-Features/Value-Origin-Tracking.md` and
// the DAP protocol in §5. The classifier-side `OriginKind` lives in the
// `origin-classifier` crate; here we keep an independent wire enum so the
// JSON-camelCase surface is stable independently of internal classifier
// renames. Conversion is implemented in `origin_query.rs`.
// ===========================================================================

/// Arguments for `ct/originChain` (spec §5.3 "Request").
///
/// The wire shape carries both the high-level query (variable + step) and
/// per-request budget knobs (`max_hops`, `lazy`). Field names match the
/// camelCase rendering the frontend already serialises.
#[derive(Debug, Default, Clone, Serialize, Deserialize)]
#[serde(rename_all(serialize = "camelCase", deserialize = "camelCase"))]
pub struct CtOriginChainArguments {
    /// The variable / expression to query.  V1 is identifier-only; dotted
    /// paths are reserved for M3.
    pub variable_name: String,
    /// Reserved for V1 — present so dotted paths can be added without a
    /// wire break. Empty means "use `variable_name` verbatim".
    #[serde(default)]
    pub variable_path: Vec<String>,
    /// Optional DAP frame id; absent or negative means "topmost frame".
    #[serde(default = "default_no_frame")]
    pub frame_id: i64,
    /// Optional StepId; absent or negative means "current step".
    #[serde(default = "default_no_step")]
    pub step_id: i64,
    /// Optional DAP thread id (single-thread today).
    #[serde(default)]
    pub thread_id: i64,
    /// Maximum hops to return in this batch. Spec §6.1 numerics: 16.
    #[serde(default = "default_max_hops")]
    pub max_hops: u32,
    /// If true, server may return early with a continuation token (spec
    /// §5.3.1).
    #[serde(default)]
    pub lazy: bool,
    /// Opaque base64url JSON resume cursor. When set, the server resumes
    /// the chain from the cursor instead of re-querying.
    #[serde(default)]
    pub continuation_token: Option<String>,
    /// Reserved session id for multi-`.ct` sessions (M29). Empty in V1.
    #[serde(default)]
    pub session_id: String,
    /// If false, skip the source-line classifier and only follow
    /// Assignment events. Defaults to true.
    #[serde(default = "default_true")]
    pub classify_source: bool,
}

fn default_no_frame() -> i64 {
    NO_KEY_I64
}
fn default_no_step() -> i64 {
    NO_STEP_ID
}
fn default_max_hops() -> u32 {
    DEFAULT_ORIGIN_MAX_HOPS
}
fn default_true() -> bool {
    true
}

const NO_KEY_I64: i64 = -1;
/// Spec §6.1.7 numerics: 16 is the V1 default.
pub const DEFAULT_ORIGIN_MAX_HOPS: u32 = 16;
/// Conservative default for the scan-step cap; high enough to never trip
/// on the canonical fixtures but low enough to surface the budget knob in
/// integration tests.
pub const DEFAULT_ORIGIN_MAX_STEPS_SCANNED: u64 = 100_000;
/// Conservative wall-clock cap. The classifier itself is microsecond-cheap
/// so the budget normally trips first via `max_steps_scanned`.
pub const DEFAULT_ORIGIN_WALL_CLOCK_MS: u32 = 5_000;
/// Snapshot cap for Computational hops (spec §6.1 `snapshot_operands`).
pub const ORIGIN_OPERAND_SNAPSHOT_CAP: usize = 16;

/// Per-request budget honoured by the backward scan (spec §6.1.7).
#[derive(Debug, Clone, Copy, Serialize, Deserialize)]
#[serde(rename_all(serialize = "camelCase", deserialize = "camelCase"))]
pub struct OriginBudget {
    pub max_hops: u32,
    pub wall_clock_ms: u32,
    pub max_steps_scanned: u64,
}

impl Default for OriginBudget {
    fn default() -> Self {
        OriginBudget {
            max_hops: DEFAULT_ORIGIN_MAX_HOPS,
            wall_clock_ms: DEFAULT_ORIGIN_WALL_CLOCK_MS,
            max_steps_scanned: DEFAULT_ORIGIN_MAX_STEPS_SCANNED,
        }
    }
}

/// Wire-side origin kind. Mirrors `origin_classifier::OriginKind` plus
/// `FunctionReturn` (returned by the materialised algorithm distinct from
/// the classifier's `ReturnCapture` for cases where the chain crosses a
/// frame boundary without an explicit `await`). The wire enum is the
/// closed type-space carried by every `OriginHop`.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum OriginKind {
    TrivialCopy,
    FieldAccess,
    IndexAccess,
    Computational,
    FunctionCall,
    Literal,
    /// Result of `await`/explicit return capture (`x = foo()`).
    ReturnCapture,
    /// Distinct alias of `ReturnCapture` carried when the algorithm
    /// re-emits the hop on the callee side. Reserved so future
    /// implementations may render them differently.
    FunctionReturn,
    /// Hop crosses into a callee via a parameter binding.
    ParameterPass,
    /// Hop crosses a thread boundary (RR/MCR backends — surfaced now).
    CrossThreadCopy,
    /// Garbled / unparseable line.
    Unknown,
}

impl From<origin_classifier_kind_alias::OriginKind> for OriginKind {
    fn from(value: origin_classifier_kind_alias::OriginKind) -> Self {
        use origin_classifier_kind_alias::OriginKind as Src;
        match value {
            Src::TrivialCopy => OriginKind::TrivialCopy,
            Src::FieldAccess => OriginKind::FieldAccess,
            Src::IndexAccess => OriginKind::IndexAccess,
            Src::Computational => OriginKind::Computational,
            Src::FunctionCall => OriginKind::FunctionCall,
            Src::Literal => OriginKind::Literal,
            Src::ReturnCapture => OriginKind::ReturnCapture,
            Src::ParameterPass => OriginKind::ParameterPass,
            Src::CrossThread => OriginKind::CrossThreadCopy,
            Src::Unknown => OriginKind::Unknown,
        }
    }
}

/// Tiny module-alias so the `From` impl above does not bloat the
/// `use` block at the top of the file (the classifier crate is the only
/// caller).
pub(crate) mod origin_classifier_kind_alias {
    pub use origin_classifier::OriginKind;
}

/// Wire-side terminator kind (spec §4.1).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum TerminatorKind {
    Literal,
    Computational,
    ParameterAtRecordStart,
    ReadFromExternal,
    RecordingStart,
    UnknownSource,
    UnknownVariable,
    DepthLimit,
    OutOfBudget,
}

/// Closed terminator descriptor surfaced in `OriginChain.terminator`.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all(serialize = "camelCase", deserialize = "camelCase"))]
pub struct Terminator {
    pub kind: TerminatorKind,
    /// Terminator expression (computational RHS / literal text / parameter
    /// descriptor / external descriptor). Empty when the chain ended
    /// without parsing a terminator hop.
    #[serde(default)]
    pub expression: String,
    /// Function containing the terminator, when known.
    #[serde(default)]
    pub function: Option<String>,
    /// Source line text of the terminator hop, when known.
    #[serde(default)]
    pub source_line: Option<String>,
}

impl Terminator {
    pub fn new(kind: TerminatorKind) -> Self {
        Terminator {
            kind,
            expression: String::new(),
            function: None,
            source_line: None,
        }
    }
}

/// One operand-value snapshot attached to a Computational hop (spec §6.1).
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all(serialize = "camelCase", deserialize = "camelCase"))]
pub struct OperandSnapshot {
    pub name: String,
    pub value: ValueRecordWithType,
    pub source_step: i64,
}

/// Per-hop frame-transition descriptor (spec §4.1 `FrameTransition`).
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all(serialize = "camelCase", deserialize = "camelCase"))]
pub struct FrameTransition {
    pub kind: FrameTransitionKind,
    pub from_function: String,
    pub to_function: String,
    pub call_key: i64,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum FrameTransitionKind {
    ParameterPass,
    ReturnCapture,
}

/// M29 cross-process span (spec §4.4). One per process the chain
/// visits. The `first_hop_index` / `last_hop_index` are 0-based
/// inclusive indices into `OriginChain.hops` identifying the
/// contiguous range owned by this process. `recording_id` is the
/// `session.toml` recording id; `role` is the manifest's role label
/// ("frontend" / "backend" / ...). The legacy `from_process` /
/// `to_process` / `correlator` fields are retained for wire
/// backward-compatibility (defaulted to empty strings when the
/// algorithm only populates the M29-aligned shape).
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all(serialize = "camelCase", deserialize = "camelCase"))]
pub struct CrossProcessSpan {
    /// Recording id (UUIDv7 string from `session.toml`) of the process
    /// that owns the contiguous hop range covered by this span.
    #[serde(default)]
    pub recording_id: String,
    /// Manifest-level role label (e.g. "frontend", "backend").
    #[serde(default)]
    pub role: String,
    /// 0-based inclusive index of the first hop in `OriginChain.hops`
    /// owned by this process.
    #[serde(default)]
    pub first_hop_index: u32,
    /// 0-based inclusive index of the last hop owned by this process.
    /// When the span contains no hops yet the value equals
    /// `first_hop_index` and the renderer treats it as a placeholder.
    #[serde(default)]
    pub last_hop_index: u32,
    /// Legacy field retained for wire backward-compat; new producers
    /// leave it empty.
    #[serde(default)]
    pub from_process: String,
    #[serde(default)]
    pub to_process: String,
    #[serde(default)]
    pub correlator: String,
}

/// M29 correlation-transition metadata attached to the boundary-
/// crossing hop. Spec §4.4 mandates carrying the matched sibling-trace
/// coordinates + the captured match-key + display-variable values so
/// the frontend can render the boundary chip without round-tripping
/// the pair index.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all(serialize = "camelCase", deserialize = "camelCase"))]
pub struct CorrelationTransition {
    /// Marker direction observed on the *current* hop's side. The
    /// boundary-crossing hop sits on the Receive side of the wire;
    /// the algorithm walks to the matched Send marker in the sibling
    /// trace.
    #[serde(default)]
    pub direction: String,
    /// Manifest-level recording id of the sibling trace the chain
    /// jumped into (i.e. the process that sent the value).
    #[serde(default)]
    pub correlated_recording_id: String,
    /// Step id inside the sibling trace at which the matched Send
    /// marker fired.
    #[serde(default)]
    pub correlated_step_id: i64,
    /// Boundary id from the marker (`session.toml` `[correlation]`
    /// authored value).
    #[serde(default)]
    pub boundary_id: String,
    /// Marker's match-key textual value (the user-authored key
    /// expression evaluated at marker time).
    #[serde(default)]
    pub match_key_value: String,
    /// Optional `show=<expr>` rendered value, when the marker declared
    /// one.
    #[serde(default)]
    pub display_variable_value: Option<String>,
    /// Optional human-friendly description (`desc=...`) the user
    /// supplied on the marker declaration.
    #[serde(default)]
    pub description: Option<String>,
    /// Legacy fields retained for wire backward-compat; new producers
    /// can leave them empty.
    #[serde(default)]
    pub correlator: String,
    #[serde(default)]
    pub channel: String,
}

/// One hop in a value-origin chain (spec §4.1).
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all(serialize = "camelCase", deserialize = "camelCase"))]
pub struct OriginHop {
    pub kind: OriginKind,
    pub target_expr: String,
    pub source_expr: String,
    pub source_variable: Option<String>,
    pub location: Location,
    pub source_text: String,
    pub step_id: i64,
    #[serde(default)]
    pub frame_transition: Option<FrameTransition>,
    #[serde(default)]
    pub operand_snapshots: Vec<OperandSnapshot>,
    #[serde(default)]
    pub truncated_operands: bool,
    pub confidence: f32,
    /// Classifier provenance string (`built-in: ...` / `personal: ...` /
    /// `trace-local: ...` / `embedded: <lib>: ...`). None for synthesised
    /// hops (`unknown` terminators).
    #[serde(default)]
    pub classification_provenance: Option<String>,
    #[serde(default)]
    pub correlation_transition: Option<CorrelationTransition>,
}

/// Per-chain metrics returned alongside the hops (spec §4.1 `metrics`).
#[derive(Debug, Default, Clone, Serialize, Deserialize)]
#[serde(rename_all(serialize = "camelCase", deserialize = "camelCase"))]
pub struct OriginMetrics {
    pub steps_scanned: u64,
    pub elapsed_ms: u64,
    pub classifier_hits: u32,
    /// M17 — number of hops served by Tier 1 (Nim undo-map last-mile
    /// lookup). Zero on any non-MCR backend; defaulted to keep
    /// pre-M17 traces deserialising unchanged.
    #[serde(default)]
    pub tier_one_hops: u32,
    /// M17 — number of hops served by Tier 2 (RR-style data-breakpoint
    /// + reverse-execution fallback). Zero on any non-MCR backend.
    #[serde(default)]
    pub tier_two_hops: u32,
    /// M22 — number of hops served by Tier 3 (WASM emulator data-watch
    /// primitive — the browser-replay path's pre-window fallback per
    /// spec §6.6). Zero on any non-MCR backend and zero whenever the
    /// chain is served entirely by Tier 1 / Tier 2.
    #[serde(default)]
    pub tier_three_hops: u32,
}

/// The full origin chain (spec §4.1).
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all(serialize = "camelCase", deserialize = "camelCase"))]
pub struct OriginChain {
    pub query_variable: String,
    pub query_step_id: i64,
    pub hops: Vec<OriginHop>,
    pub terminator: Terminator,
    pub truncated: bool,
    #[serde(default)]
    pub continuation_token: Option<String>,
    #[serde(default)]
    pub metrics: OriginMetrics,
    /// Reserved for M29; always empty in M2.
    #[serde(default)]
    pub cross_process_spans: Vec<CrossProcessSpan>,
    /// Minimum per-hop confidence; see spec §6.1.5.
    pub confidence: f32,
}

impl OriginChain {
    pub fn terminator_only(terminator: TerminatorKind, query_variable: &str, query_step_id: i64) -> Self {
        OriginChain {
            query_variable: query_variable.to_string(),
            query_step_id,
            hops: Vec::new(),
            terminator: Terminator::new(terminator),
            truncated: false,
            continuation_token: None,
            metrics: OriginMetrics::default(),
            cross_process_spans: Vec::new(),
            confidence: 0.0,
        }
    }
}

/// Compact summary attached to every value-bearing response (spec §4.1
/// `OriginSummary`). Powers the inline badge in §3.2.1 / §3.2.3.
#[derive(Debug, Default, Clone, Serialize, Deserialize, PartialEq, JsonSchema)]
#[serde(rename_all(serialize = "camelCase", deserialize = "camelCase"))]
pub struct OriginSummary {
    pub terminator_kind: TerminatorKindWire,
    pub terminator_expr: String,
    pub terminator_function: Option<String>,
    pub hop_count: u32,
    pub confidence: f32,
    pub is_placeholder: bool,
    pub placeholder_token: Option<String>,
}

/// Wire-side default-able terminator kind so `OriginSummary::default()` is
/// well-defined (placeholders).
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
#[serde(rename_all = "camelCase")]
pub enum TerminatorKindWire {
    #[default]
    UnknownSource,
    Literal,
    Computational,
    ParameterAtRecordStart,
    ReadFromExternal,
    RecordingStart,
    UnknownVariable,
    DepthLimit,
    OutOfBudget,
}

impl From<TerminatorKind> for TerminatorKindWire {
    fn from(k: TerminatorKind) -> Self {
        match k {
            TerminatorKind::Literal => TerminatorKindWire::Literal,
            TerminatorKind::Computational => TerminatorKindWire::Computational,
            TerminatorKind::ParameterAtRecordStart => TerminatorKindWire::ParameterAtRecordStart,
            TerminatorKind::ReadFromExternal => TerminatorKindWire::ReadFromExternal,
            TerminatorKind::RecordingStart => TerminatorKindWire::RecordingStart,
            TerminatorKind::UnknownSource => TerminatorKindWire::UnknownSource,
            TerminatorKind::UnknownVariable => TerminatorKindWire::UnknownVariable,
            TerminatorKind::DepthLimit => TerminatorKindWire::DepthLimit,
            TerminatorKind::OutOfBudget => TerminatorKindWire::OutOfBudget,
        }
    }
}

/// Args for the batch placeholder-fill endpoint `ct/originSummary`
/// (spec §5.3.2).
#[derive(Debug, Default, Clone, Serialize, Deserialize)]
#[serde(rename_all(serialize = "camelCase", deserialize = "camelCase"))]
pub struct CtOriginSummaryArguments {
    pub tokens: Vec<String>,
}

/// Response for `ct/originSummary` — parallel-array of filled summaries.
#[derive(Debug, Default, Clone, Serialize, Deserialize)]
#[serde(rename_all(serialize = "camelCase", deserialize = "camelCase"))]
pub struct CtOriginSummaryResponse {
    pub summaries: Vec<OriginSummary>,
}

/// Response body wrapper for `ct/load-locals` extended with origin
/// summaries (spec §3.2.3).
#[derive(Serialize, Deserialize, Debug, PartialEq, Default, Clone, JsonSchema)]
#[serde(rename_all = "camelCase")]
pub struct CtLoadLocalsWithOriginsBody {
    pub locals: Vec<Variable>,
    /// Parallel array of per-variable origin summaries. Same length as
    /// `locals`. Eager-mode entries are fully populated; placeholder-mode
    /// entries carry only `is_placeholder` + `placeholder_token`.
    #[serde(default)]
    pub origin_summaries: Vec<OriginSummary>,
}

#[derive(Debug, Default, Copy, Clone, FromPrimitive, Serialize_repr, Deserialize_repr, PartialEq)]
#[repr(u8)]
pub enum NotificationKind {
    #[default]
    Info,
    Warning,
    Error,
    Success,
}

#[derive(Debug, Default, Copy, Clone, FromPrimitive, Serialize_repr, Deserialize_repr, PartialEq)]
#[repr(u8)]
pub enum NotificationActionKind {
    #[default]
    ButtonAction,
}

#[derive(Debug, Default, Clone, Serialize, Deserialize)]
#[serde(rename_all(serialize = "camelCase", deserialize = "camelCase"))]
pub struct NotificationAction {
    pub kind: NotificationActionKind,
    pub name: String,
}

#[derive(Debug, Default, Clone, Serialize, Deserialize)]
#[serde(rename_all(serialize = "camelCase", deserialize = "camelCase"))]
pub struct Notification {
    pub kind: NotificationKind,
    pub time: u64,
    pub text: String,
    pub active: bool,
    pub seen: bool,
    pub timeout_id: usize,
    pub has_timeout: bool,
    pub is_operation_status: bool,
    pub actions: Vec<NotificationAction>,
}

impl Notification {
    #[allow(clippy::expect_used)]
    pub fn new(kind: NotificationKind, msg: &str, is_operation_status: bool) -> Notification {
        let now = SystemTime::now();
        let time = now
            .duration_since(UNIX_EPOCH)
            .expect("expect that always `now` >= UNIX_EPOCH");
        Notification {
            kind,
            text: msg.to_string(),
            is_operation_status,
            active: true,
            time: time.as_secs(),
            ..Default::default()
        }
    }
}

#[derive(Debug, Default, Clone, Serialize, Deserialize)]
pub struct CallArg {
    pub name: String,
    pub text: String,
    pub value: Value,
}

#[derive(Debug, Default, Clone, Serialize, Deserialize, PartialEq)]
#[serde(default, rename_all(serialize = "camelCase", deserialize = "camelCase"))]
pub struct CalltraceLoadArgs {
    pub location: Location,
    pub start_call_line_index: GlobalCallLineIndex,
    pub depth: usize,
    pub height: usize,
    pub raw_ignore_patterns: String,
    pub auto_collapsing: bool,
    pub optimize_collapse: bool,
    pub render_call_line_index: usize,
}

#[derive(Debug, Default, Clone, Serialize, Deserialize)]
#[serde(rename_all(serialize = "camelCase", deserialize = "camelCase"))]
pub struct CollapseCallsArgs {
    pub call_key: String,
    pub non_expanded_kind: CalltraceNonExpandedKind,
    pub count: i64,
}

#[derive(Debug, Default, Copy, Clone, Serialize, Deserialize)]
pub enum TaskKind {
    #[default]
    LoadFlow = 0,
    LoadFlowShape,
    RunTracepoints,
    LoadHistory,
    LoadHistoryWorker,
    CalltraceSearch,
    EventLoad,
    LoadCallArgs,
    CollapseCalls,
    ExpandCalls,
    ResetOperation,
    CalltraceJump,
    EventJump,
    HistoryJump,
    TraceJump,
    Stop,
    Configure,
    RunToEntry,
    Step,
    Start,
    LoadLocals,
    LoadCallstack,
    AddBreak,
    DeleteBreak,
    DebugGdb,
    LocalStepJump,
    SendToShell,
    LoadAsmFunction,
    SourceLineJump,
    SourceCallJump,
    DeleteAllBreakpoints,
    NimLoadCLocations,
    UpdateExpansionLevel,
    AddBreakC,
    Enable,
    Disable,
    UpdateWatches,
    ResetState,
    ExpandValue,
    LoadParsedExprs,
    CompleteMoveTask,
    RestartProcess,
    Raw, // resending the raw/reconstructed raw message to client
    Ready,
    UpdateTable,
    TracepointDelete,
    TracepointToggle,
    SearchProgram,
    LoadStepLines,
    RegisterEvents,
    RegisterTracepointLogs,
    LoadCalltrace,
    MissingTaskKind,
    SetupTraceSession,
    LoadTerminal,
}

#[derive(Debug, Default, Clone)]
pub struct TaskId(pub String);

#[derive(Debug, Default, Copy, Clone)]
pub enum EventKind {
    #[default]
    CompleteMove,
    DebuggerStarted,
    UpdatedEvents,
    UpdatedEventsContent,
    UpdatedFlow,
    UpdatedCallArgs,
    UpdatedTrace,
    UpdatedShell,
    UpdatedWatches,
    UpdatedHistory,
    UpdatedLoadStepLines,
    UpdatedTable,
    SentFlowShape,
    DebugOutput,
    NewNotification,
    TracepointLocals,
    ProgramSearchResults,
    UpdatedStepLines,
    UpdatedTracepointLogs,
    Error,
    MissingEventKind,
    LoadedTerminal,
}

#[derive(Debug, Default, Clone)]
pub struct EventId(String);

#[derive(Debug, Default, Copy, Clone, FromPrimitive, Serialize_repr, Deserialize_repr, PartialEq)]
#[repr(u8)]
pub enum CalltraceNonExpandedKind {
    #[default]
    Callstack,
    Children,
    Siblings,
    Calls,
    CallstackInternal,
    CallstackInternalChild,
}

#[derive(Debug, Default, Copy, Clone, FromPrimitive, Serialize_repr, Deserialize_repr, PartialEq)]
#[repr(u8)]
pub enum CallLineContentKind {
    #[default]
    Call,
    NonExpanded,
    WithHiddenChildren,
    CallstackInternalCount,
    StartCallstackCount,
    EndOfProgramCall,
}

#[derive(Debug, Default, Clone, Serialize, Deserialize)]
#[serde(rename_all(serialize = "camelCase", deserialize = "camelCase"))]
pub struct CallLineContent {
    pub kind: CallLineContentKind,
    pub call: Call,
    pub non_expanded_kind: CalltraceNonExpandedKind,
    pub count: usize,
    pub hidden_children: bool,
    pub is_error: bool,
}

#[derive(Debug, Default, Clone, Copy, Serialize, Deserialize, PartialEq, Eq, PartialOrd, Ord)]
pub struct GlobalCallLineIndex(pub usize);

impl From<GlobalCallLineIndex> for usize {
    fn from(val: GlobalCallLineIndex) -> Self {
        val.0
    }
}

impl ops::AddAssign<usize> for GlobalCallLineIndex {
    fn add_assign(&mut self, arg: usize) {
        self.0 += arg;
    }
}

#[derive(Debug, Default, Clone, Serialize, Deserialize)]
#[serde(rename_all(serialize = "camelCase", deserialize = "camelCase"))]
pub struct CallLineMetadataContent {
    pub kind: CallLineContentKind,
    // case kind*: CallLineContentKind:
    // of CallLineContentKind.Call:
    pub call_key: CallKey,
    // of CallLineContentKind.NonExpanded:
    pub non_expanded_kind: CalltraceNonExpandedKind,
    pub children_count: usize,
    pub hidden_children: bool,
    pub count: usize,
}

#[derive(Debug, Default, Clone, Serialize, Deserialize)]
#[serde(rename_all(serialize = "camelCase", deserialize = "camelCase"))]
pub struct CallLineMetadata {
    pub content: CallLineMetadataContent,
    pub depth: usize,
    pub global_call_line_index: GlobalCallLineIndex,
}

impl CallLineMetadata {
    pub fn call(
        call_key: CallKey,
        children_count: usize,
        hidden_children: bool,
        depth: usize,
        index: GlobalCallLineIndex,
    ) -> Self {
        CallLineMetadata {
            content: CallLineMetadataContent {
                kind: CallLineContentKind::Call,
                call_key,
                children_count,
                hidden_children,
                non_expanded_kind: CalltraceNonExpandedKind::default(), // not used in frontend, variant type
                count: 0,                                               // not used in frontend, variant type
            },
            depth,
            global_call_line_index: index,
        }
    }

    pub fn non_expanded_call(
        call_key: CallKey,
        children_count: usize,
        depth: usize,
        index: GlobalCallLineIndex,
    ) -> Self {
        CallLineMetadata {
            content: CallLineMetadataContent {
                kind: CallLineContentKind::NonExpanded,
                call_key,
                children_count,
                hidden_children: false,
                non_expanded_kind: CalltraceNonExpandedKind::Children,
                count: 0,
            },
            depth,
            global_call_line_index: index,
        }
    }

    pub fn callstack_count(
        call_key: CallKey,
        count: usize,
        depth: usize,
        index: GlobalCallLineIndex,
        content_kind: CallLineContentKind,
    ) -> Self {
        CallLineMetadata {
            content: CallLineMetadataContent {
                kind: content_kind,
                call_key,
                children_count: 0,
                hidden_children: true,
                non_expanded_kind: CalltraceNonExpandedKind::Callstack,
                count,
            },
            depth,
            global_call_line_index: index,
        }
    }

    pub fn end_of_program_call(index: GlobalCallLineIndex) -> Self {
        CallLineMetadata {
            content: CallLineMetadataContent {
                kind: CallLineContentKind::EndOfProgramCall,
                call_key: CallKey(-1),
                children_count: 0,
                hidden_children: false,
                non_expanded_kind: CalltraceNonExpandedKind::default(),
                count: 0,
            },
            depth: 0,
            global_call_line_index: index,
        }
    }
}

#[derive(Debug, Default, Clone, Serialize, Deserialize)]
#[serde(rename_all(serialize = "camelCase", deserialize = "camelCase"))]
pub struct CallLine {
    pub content: CallLineContent,
    pub depth: usize,
}

impl CallLine {
    pub fn call(call_arg: Call, hidden_children: bool, count: usize, depth: usize) -> Self {
        CallLine {
            content: CallLineContent {
                kind: CallLineContentKind::Call,
                call: call_arg,
                non_expanded_kind: CalltraceNonExpandedKind::default(),
                hidden_children,
                count,
                is_error: false,
            },
            depth,
        }
    }

    pub fn non_expanded(kind: CalltraceNonExpandedKind, call_arg: Call, count: usize, depth: usize) -> Self {
        CallLine {
            content: CallLineContent {
                kind: CallLineContentKind::NonExpanded,
                call: call_arg,
                non_expanded_kind: kind,
                hidden_children: false,
                count,
                is_error: false,
            },
            depth,
        }
    }

    pub fn end_of_program_call(
        kind: CalltraceNonExpandedKind,
        is_error: bool,
        text: &str,
        step_id: StepId,
    ) -> CallLine {
        let location = Location {
            rr_ticks: RRTicks(step_id.0),
            ..Default::default()
        };
        CallLine {
            content: CallLineContent {
                kind: CallLineContentKind::EndOfProgramCall,
                call: Call {
                    key: "-1".to_string(),
                    children: vec![],
                    depth: 0,
                    location,
                    parent: None,
                    raw_name: text.to_string(),
                    args: vec![],
                    return_value: Value::new(TypeKind::None, Type::new(TypeKind::None, "none")),
                    with_args_and_return: false,
                },
                non_expanded_kind: kind,
                hidden_children: false,
                count: 0,
                is_error,
            },
            depth: 0,
        }
    }

    pub fn callstack_count(kind: CalltraceNonExpandedKind, call_arg: Call, count: usize, depth: usize) -> Self {
        CallLine {
            content: CallLineContent {
                kind: CallLineContentKind::CallstackInternalCount,
                call: call_arg,
                non_expanded_kind: kind,
                hidden_children: true,
                count,
                is_error: false,
            },
            depth,
        }
    }

    pub fn start_callstack_count(kind: CalltraceNonExpandedKind, call_arg: Call, count: usize, depth: usize) -> Self {
        CallLine {
            content: CallLineContent {
                kind: CallLineContentKind::StartCallstackCount,
                call: call_arg,
                non_expanded_kind: kind,
                hidden_children: true,
                count,
                is_error: false,
            },
            depth,
        }
    }
}
#[derive(Debug, Default, Clone, Serialize, Deserialize)]
#[serde(rename_all(serialize = "camelCase", deserialize = "camelCase"))]
pub struct CallArgsUpdateResults {
    pub finished: bool,
    pub args: HashMap<String, Vec<CallArg>>,
    pub return_values: HashMap<String, Value>,
    pub start_call_line_index: GlobalCallLineIndex,
    pub start_call: Call,
    pub start_call_parent_key: String,
    pub call_lines: Vec<CallLine>,
    pub total_calls_count: usize,
    pub scroll_position: usize,
    pub max_depth: usize,
}

impl CallArgsUpdateResults {
    pub fn finished_update(
        start_call: Call,
        start_call_parent_key: String,
        total_calls_count: usize,
        max_depth: usize,
    ) -> Self {
        CallArgsUpdateResults {
            finished: true,
            args: HashMap::new(),
            return_values: HashMap::new(),
            start_call_line_index: GlobalCallLineIndex(0),
            start_call,
            start_call_parent_key,
            call_lines: vec![],
            total_calls_count,
            scroll_position: 0,
            max_depth,
        }
    }

    pub fn finished_update_call_lines(
        call_lines: Vec<CallLine>,
        index: GlobalCallLineIndex,
        total_calls_count: usize,
        position: usize,
        max_depth: usize,
    ) -> Self {
        CallArgsUpdateResults {
            finished: true,
            args: HashMap::new(),
            return_values: HashMap::new(),
            start_call_line_index: index,
            start_call: Call::default(),
            start_call_parent_key: NO_KEY.to_string(),
            call_lines,
            total_calls_count,
            scroll_position: position,
            max_depth,
        }
    }
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
#[serde(rename_all(serialize = "camelCase", deserialize = "camelCase"))]
pub struct LoadStepLinesArg {
    pub location: Location,
    pub forward_count: usize,
    pub backward_count: usize,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
#[serde(rename_all(serialize = "camelCase", deserialize = "camelCase"))]
pub struct LoadStepLinesUpdate {
    pub arg_location: Location,
    pub results: Vec<LineStep>,
    pub finish: bool,
}

#[derive(Debug, Default, Copy, Clone, FromPrimitive, Serialize_repr, Deserialize_repr, PartialEq)]
#[repr(u8)]
pub enum LineStepKind {
    #[default]
    Line,
    Call,
    Return,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
#[serde(rename_all(serialize = "camelCase", deserialize = "camelCase"))]
pub struct LineStep {
    pub kind: LineStepKind,
    pub location: Location,
    pub delta: i64,
    pub source_line: String,
    pub values: Vec<LineStepValue>,
    // pub iteration_info: Vec<StepIterationInfo>,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
#[serde(rename_all(serialize = "camelCase", deserialize = "camelCase"))]
pub struct StepIterationInfo {
    pub loop_id: LoopId,
    pub iteration: Iteration,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
#[serde(rename_all(serialize = "camelCase", deserialize = "camelCase"))]
pub struct LineStepValue {
    pub expression: String,
    pub value: Value,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
#[serde(rename_all(serialize = "camelCase", deserialize = "camelCase"))]
pub struct LocalStepJump {
    pub path: String,
    pub line: i64,
    pub step_count: i64,
    pub target_iteration: i64,
    pub first_loop_line: i64,
    pub rr_ticks: i64,
    pub reverse: bool,
    pub active_iteration: i64,
}

/// Arguments for the `ct/goto-ticks` DAP command.
///
/// Jumps the replay to a specific execution timestamp (RR ticks / step ID).
/// Used by the Python API `trace.goto_ticks(n)` and by the GUI when jumping
/// to log output events.
#[derive(Debug, Default, Clone, Serialize, Deserialize)]
#[serde(rename_all(serialize = "camelCase", deserialize = "camelCase"))]
pub struct GoToTicksArguments {
    pub thread_id: i64,
    pub ticks: i64,
}

#[derive(Debug, Default, Copy, Clone, FromPrimitive, Serialize_repr, Deserialize_repr, PartialEq)]
#[repr(u8)]
pub enum DbEventKind {
    #[default]
    Record,
    Trace,
    History,
}

#[derive(Debug, Default, Clone, Serialize, Deserialize)]
#[serde(rename_all(serialize = "camelCase", deserialize = "camelCase"))]
pub struct RegisterEventsArg {
    pub kind: DbEventKind,
    pub events: Vec<ProgramEvent>,
}

#[derive(Debug, Default, Clone, Serialize, Deserialize)]
#[serde(rename_all(serialize = "camelCase", deserialize = "camelCase"))]
pub struct TracepointResults {
    pub session_id: usize,
    pub tracepoint_id: usize,
    pub tracepoint_values: Vec<Vec<StringAndValueTuple>>,
    pub events: Vec<ProgramEvent>,
    pub last_in_session: bool,
    pub first_update: bool,
}

/// Aggregate tracepoint results emitted as a single `ct/tracepoint-results`
/// event after all tracepoints in a session have been evaluated.
///
/// The daemon's Python bridge waits for this event to build the response
/// for `ct/py-run-tracepoints`.
#[derive(Debug, Default, Clone, Serialize, Deserialize)]
#[serde(rename_all(serialize = "camelCase", deserialize = "camelCase"))]
pub struct TracepointResultsAggregate {
    /// Session that produced these results.
    pub session_id: usize,
    /// All tracepoint hits collected during the run.
    pub results: Vec<Stop>,
    /// Per-tracepoint parse/evaluation errors (tracepoint_id → message).
    pub errors: HashMap<usize, String>,
}

#[derive(Debug, Default, Clone, Serialize, Deserialize, JsonSchema)]
#[serde(rename_all(serialize = "camelCase", deserialize = "camelCase"))]
pub struct Breakpoint {
    pub id: i64,
    pub enabled: bool,
    /// 1-indexed column the breakpoint is anchored at, or `None` for
    /// the legacy line-only behaviour.  Wired through M1 of the
    /// Column-Aware Replay Navigation campaign — see
    /// `codetracer-specs/Planned-Features/Column-Aware-Navigation.status.org`
    /// §M1.  The Continue stop check compares this column against
    /// `DbStep.column` when present and falls back to line-only
    /// matching when `None`, preserving back-compat for legacy DAP
    /// clients that send only `{line: N}`.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub column: Option<i64>,
    /// Optional condition expression evaluated at the candidate stop
    /// step.  When `Some(expr)` the Continue stop check evaluates the
    /// expression against the locals recorded at the matched step and
    /// only fires the breakpoint when the expression yields a truthy
    /// value.  `None` preserves the unconditional behaviour M1
    /// shipped with.  Wired through M9 of the Column-Aware Replay
    /// Navigation campaign — see
    /// `codetracer-specs/Planned-Features/Column-Aware-Navigation.status.org`
    /// §M9.  Composes orthogonally with `column` — both axes are
    /// honoured when both are `Some`.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub condition: Option<String>,
}

#[derive(Debug, Clone, Copy, PartialEq)]
pub enum TraceKind {
    Materialized,
    Recreator,
    /// In-process MCR emulator backing the WASM browser-replay client
    /// (and the native code path when an MCR-bearing CTFS container is
    /// loaded). The Handler's `replay` field is an
    /// [`crate::emulator_session::EmulatorReplaySession`]; the
    /// `stack_trace`/`scopes`/`variables` DAP handlers delegate to it
    /// directly because there is no pre-materialised DB or
    /// recreator-subprocess channel to query. See F5c-4 wiring in
    /// `dap_server::setup_from_vfs`.
    Emulator,
}

#[derive(Debug, Default, Clone, Serialize, Deserialize, JsonSchema)]
#[serde(rename_all(serialize = "camelCase", deserialize = "camelCase"))]
pub struct Events {
    pub events: Vec<ProgramEvent>,
    pub first_events: Vec<ProgramEvent>,
    pub contents: String,
}

pub static mut TASK_ID_MAP: &mut [usize] = &mut [0; 100];
pub static mut EVENT_ID_MAP: &mut [usize] = &mut [0; 100];

fn from_camel_case_to_lisp_case(text: &str) -> String {
    let mut result = String::from("");
    for (i, c) in text.chars().enumerate() {
        if c.is_ascii_uppercase() {
            if i != 0 {
                result.push('-');
            }
            result.push(c.to_ascii_lowercase())
        } else {
            result.push(c);
        }
    }
    result
}

pub fn to_task_kind_text(task_kind: TaskKind) -> String {
    from_camel_case_to_lisp_case(&format!("{task_kind:?}"))
}

pub fn gen_task_id(task_kind: TaskKind) -> TaskId {
    let text = to_task_kind_text(task_kind);
    let index = unsafe {
        let previous = TASK_ID_MAP[task_kind as usize];
        TASK_ID_MAP[task_kind as usize] += 1;
        previous
    };
    TaskId(format!("{text}-{index}"))
}

pub fn to_task_kind(raw_task_kind: &str) -> Option<TaskKind> {
    match raw_task_kind {
        "configure" => Some(TaskKind::Configure),
        "start" => Some(TaskKind::Start),
        "runToEntry" => Some(TaskKind::RunToEntry),
        "loadLocals" => Some(TaskKind::LoadLocals),
        "loadCallstack" => Some(TaskKind::LoadCallstack),
        "collapseCalls" => Some(TaskKind::CollapseCalls),
        "expandCalls" => Some(TaskKind::ExpandCalls),
        "loadCallArgs" => Some(TaskKind::LoadCallArgs),
        "loadFlow" => Some(TaskKind::LoadFlow),
        "step" => Some(TaskKind::Step),
        "eventLoad" => Some(TaskKind::EventLoad),
        "eventJump" => Some(TaskKind::EventJump),
        "calltraceJump" => Some(TaskKind::CalltraceJump),
        "sourceLineJump" => Some(TaskKind::SourceLineJump),
        "sourceCallJump" => Some(TaskKind::SourceCallJump),
        "addBreak" => Some(TaskKind::AddBreak),
        "deleteBreak" => Some(TaskKind::DeleteBreak),
        "disable" => Some(TaskKind::Disable),
        "enable" => Some(TaskKind::Enable),
        "runTracepoints" => Some(TaskKind::RunTracepoints),
        "traceJump" => Some(TaskKind::TraceJump),
        "historyJump" => Some(TaskKind::HistoryJump),
        "loadHistory" => Some(TaskKind::LoadHistory),
        "updateTable" => Some(TaskKind::UpdateTable),
        "calltraceSearch" => Some(TaskKind::CalltraceSearch),
        "searchProgram" => Some(TaskKind::SearchProgram),
        "loadStepLines" => Some(TaskKind::LoadStepLines),
        "localStepJump" => Some(TaskKind::LocalStepJump),
        "registerEvents" => Some(TaskKind::RegisterEvents),
        "registerTracepointLogs" => Some(TaskKind::RegisterTracepointLogs),
        "setupTraceSession" => Some(TaskKind::SetupTraceSession),
        "tracepointToggle" => Some(TaskKind::TracepointToggle),
        "tracepointDelete" => Some(TaskKind::TracepointDelete),
        "loadAsmFunction" => Some(TaskKind::LoadAsmFunction),
        "loadTerminal" => Some(TaskKind::LoadTerminal),

        "run-to-entry" => Some(TaskKind::RunToEntry),
        "load-callstack" => Some(TaskKind::LoadCallstack),
        "load-locals" => Some(TaskKind::LoadLocals),
        "load-flow" => Some(TaskKind::LoadFlow),
        "event-load" => Some(TaskKind::EventLoad),
        "register-events" => Some(TaskKind::RegisterEvents),
        "register-tracepoint-logs" => Some(TaskKind::RegisterTracepointLogs),
        "update-table" => Some(TaskKind::UpdateTable),
        "setup-trace-session" => Some(TaskKind::SetupTraceSession),
        "tracepoint-toggle" => Some(TaskKind::TracepointToggle),
        "tracepoint-delete" => Some(TaskKind::TracepointDelete),
        "load-asm-function" => Some(TaskKind::LoadAsmFunction),

        _ => None,
    }
}

pub fn to_event_kind_text(event_kind: EventKind) -> String {
    from_camel_case_to_lisp_case(&format!("{event_kind:?}"))
}

pub fn gen_event_id(event_kind: EventKind) -> EventId {
    let text = to_event_kind_text(event_kind);
    let index = unsafe {
        let previous = EVENT_ID_MAP[event_kind as usize];
        EVENT_ID_MAP[event_kind as usize] += 1;
        previous
    };
    EventId(format!("{text}-{index}"))
}

pub fn to_event_kind(raw_event_kind: &str) -> Option<EventKind> {
    match raw_event_kind {
        "complete-move" => Some(EventKind::CompleteMove),
        "debugger-started" => Some(EventKind::DebuggerStarted),
        "updated-events" => Some(EventKind::UpdatedEvents),
        "updated-events-content" => Some(EventKind::UpdatedEventsContent),
        "updated-flow" => Some(EventKind::UpdatedFlow),
        // UpdatedCallArgs,
        // UpdatedTrace,
        // UpdatedShell,
        // UpdatedWatches,
        // UpdatedHistory,
        // SentFlowShape,
        // DebugOutput,
        "new-notification" => Some(EventKind::NewNotification),
        "error" => Some(EventKind::Error),
        "missing-event-kind" => Some(EventKind::MissingEventKind),
        _ => None,
    }
}
impl TaskId {
    pub fn new(raw: &str) -> TaskId {
        TaskId(raw.to_string())
    }

    pub fn as_string(&self) -> String {
        self.0.clone()
    }
}

impl EventId {
    pub fn new(raw: &str) -> EventId {
        EventId(raw.to_string())
    }

    pub fn as_string(&self) -> String {
        self.0.clone()
    }
}

#[derive(Debug, Clone)]
pub struct Task {
    pub kind: TaskKind,
    pub id: TaskId,
}

impl Task {
    pub fn new(kind: TaskKind, id: TaskId) -> Task {
        Task { kind, id }
    }
}

impl Position {
    pub fn new(position: i64) -> Position {
        Position(position)
    }
}

impl StepCount {
    pub fn as_usize(&self) -> usize {
        self.0 as usize
    }
}

impl Iteration {
    pub fn as_usize(&self) -> usize {
        self.0 as usize
    }

    pub fn not_in_a_loop(&self) -> bool {
        self.0 == -1
    }
}

impl LoopId {
    pub fn as_usize(&self) -> usize {
        self.0 as usize
    }

    pub fn is_none(&self) -> bool {
        self.0 == -1
    }
}

impl StepArg {
    pub fn new(action: Action, reverse: bool) -> StepArg {
        StepArg {
            action,
            reverse,
            repeat: 1,
            complete: true,
            skip_internal: false,
            skip_no_source: false,
        }
    }
}

#[cfg(test)]
#[allow(clippy::expect_used)]
mod tests {
    //! M-REC-4 rename verification: the wire-format JSON keys for the
    //! db-backend's recording-id and event-slot fields must flip in
    //! lockstep with the Rust-side field renames.  The pre-migration
    //! camelCase wire fields were `traceId` (overloaded) — these tests
    //! pin the post-migration form so future regressions surface
    //! immediately.
    //!
    //! Note: these tests cover only the db-backend's own struct
    //! contract.  The matching Nim consumer renames are M-REC-5 wire
    //! format work.
    use super::*;

    /// `CoreTrace.recording_id` (M-REC-4) flips both type (i64 → String)
    /// and JSON key (`traceId` → `recordingId`).  The Nim sibling
    /// `CoreTraceObject.recordingId` (M-REC-3) already sends a UUIDv7
    /// string, so this asserts the Rust receiver matches.
    #[test]
    fn core_trace_serializes_recording_id_as_camel_case_string() {
        let trace = CoreTrace {
            recording_id: "01949fcc-7d92-7e9c-aaaa-bbbbbbbbbbbb".to_string(),
            ..CoreTrace::default()
        };
        let json = serde_json::to_value(&trace).expect("CoreTrace serializes");
        assert_eq!(
            json["recordingId"],
            serde_json::Value::String("01949fcc-7d92-7e9c-aaaa-bbbbbbbbbbbb".to_string()),
            "post-M-REC-4 JSON key must be `recordingId`, not the legacy `traceId`",
        );
        assert!(
            json.get("traceId").is_none(),
            "M-REC-4 retired the `traceId` wire-format key; if it reappears the rename leaked back",
        );
    }

    /// `CoreTrace.recording_id` round-trips through serde unchanged.
    #[test]
    fn core_trace_recording_id_roundtrips_through_json() {
        let original = CoreTrace {
            recording_id: "01949fcc-7d92-7e9c-aaaa-bbbbbbbbbbbb".to_string(),
            binary: "/tmp/example".to_string(),
            ..CoreTrace::default()
        };
        let json = serde_json::to_string(&original).expect("serialize");
        let parsed: CoreTrace = serde_json::from_str(&json).expect("deserialize");
        assert_eq!(parsed.recording_id, original.recording_id);
        assert_eq!(parsed.binary, original.binary);
    }

    /// `UpdateTableArgs.event_slot` + `TableUpdate.event_slot` (M-REC-4)
    /// flip the wire-format JSON key from `traceId` (which used to
    /// overload meanings) to `eventSlot`, removing the third meaning of
    /// "trace_id" from db-backend wire format.
    #[test]
    fn update_table_args_serializes_event_slot_as_camel_case() {
        let args = UpdateTableArgs {
            is_trace: true,
            event_slot: 7,
            ..UpdateTableArgs::default()
        };
        let json = serde_json::to_value(&args).expect("UpdateTableArgs serializes");
        assert_eq!(json["eventSlot"], serde_json::Value::Number(7.into()));
        assert!(
            json.get("traceId").is_none(),
            "M-REC-4 retired the `traceId` wire-format key for event-slot args",
        );
    }

    /// `TableUpdate.event_slot` mirrors `UpdateTableArgs.event_slot` and
    /// must serialize with the same `eventSlot` JSON key.
    #[test]
    fn table_update_serializes_event_slot_as_camel_case() {
        let update = TableUpdate {
            is_trace: false,
            event_slot: 0,
            ..TableUpdate::default()
        };
        let json = serde_json::to_value(&update).expect("TableUpdate serializes");
        assert_eq!(json["eventSlot"], serde_json::Value::Number(0.into()));
        assert!(
            json.get("traceId").is_none(),
            "M-REC-4 retired the `traceId` wire-format key on TableUpdate too",
        );
    }
}
