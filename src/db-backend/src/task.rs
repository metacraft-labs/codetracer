// use std::path::PathBuf;
use core::fmt;
use std::cmp::min;
use std::collections::HashMap;
use std::ops;
use std::time::{SystemTime, UNIX_EPOCH};

use num_derive::FromPrimitive;
use runtime_tracing::{CallKey, EventLogKind, StepId, TypeKind};
use serde::{Deserialize, Serialize};
use serde_repr::*;

use crate::lang::*;
use crate::value::{Type, Value};
use schemars::JsonSchema;

// IMPORTANT: must keep in sync with `EventLogKind` definition in common_types.nim!
pub const EVENT_KINDS_COUNT: usize = 14;

/// documentation
#[derive(Debug, Default, Clone, Serialize, Deserialize, JsonSchema)]
#[serde(rename_all = "camelCase")]
pub struct CoreTrace {
    pub replay: bool,
    pub binary: String,
    pub program: Vec<String>,
    pub paths: Vec<String>,
    pub trace_id: i64,
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

#[derive(Debug, Default, Clone, Serialize, Deserialize)]
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

#[derive(Debug, Default, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all(serialize = "camelCase", deserialize = "camelCase"))]
pub struct Variable {
    pub expression: String,
    pub value: Value,
}

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

#[derive(Debug, Default, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all(serialize = "camelCase", deserialize = "camelCase"))]
pub struct Location {
    pub path: String,
    pub line: i64,
    pub function_name: String,
    pub high_level_path: String,
    pub high_level_line: i64,
    pub high_level_function_name: String,
    pub low_level_path: String,
    pub low_level_line: i64,
    pub rr_ticks: RRTicks,
    pub function_first: i64,
    pub function_last: i64,
    pub event: i64,
    pub expression: String,
    pub offset: i64,
    pub error: bool,
    pub callstack_depth: usize,
    pub originating_instruction_address: i64,
    pub key: String,
    pub global_call_key: String,

    // for now not including most expansion-related fields
    // including this to make sure we don't pass undefined/null
    // for strings/seq-s
    pub expansion_parents: Vec<usize>,

    pub missing_path: bool,
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
            event: NO_EVENT,
            expression: "".to_string(),
            offset: NO_OFFSET,
            error: false,
            originating_instruction_address: -1,
            expansion_parents: vec![],
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

#[derive(Debug, Default, Copy, Clone, FromPrimitive, Serialize_repr, Deserialize_repr, PartialEq)]
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

#[derive(Debug, Default, Clone, Serialize, Deserialize, PartialEq, Eq, PartialOrd, Ord)]
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

#[derive(Debug, Default, Clone, Serialize, Deserialize)]
#[serde(rename_all(serialize = "camelCase", deserialize = "camelCase"))]
pub struct ProgramEvent {
    pub kind: EventLogKind,
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
}

impl fmt::Display for SourceLocation {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{}:{}", self.path, self.line)
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

#[derive(Debug, Default, Clone, Serialize, Deserialize)]
#[serde(rename_all(serialize = "camelCase", deserialize = "camelCase"))]
pub struct SearchValue {
    pub value: String,
    pub regex: bool,
}

#[derive(Debug, Default, Clone, Serialize, Deserialize)]
#[serde(rename_all(serialize = "camelCase", deserialize = "camelCase"))]
pub struct OrdValue {
    pub column: usize,
    pub dir: String,
}

#[derive(Debug, Default, Clone, Serialize, Deserialize, PartialEq)]
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
    pub content: String,
    pub metadata: String,
    pub stdout: bool,
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
            content: event.content.to_string(),
            base64_encoded: event.base64_encoded,
            metadata: event.metadata.clone(),
            stdout: event.stdout,
        }
    }
}

#[derive(Debug, Default, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all(serialize = "camelCase", deserialize = "camelCase"))]
pub struct TableData {
    pub draw: usize,
    pub records_total: usize,
    pub records_filtered: usize,
    pub data: Vec<TableRow>,
}

#[derive(Debug, Default, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all(serialize = "camelCase", deserialize = "camelCase"))]
pub struct TableUpdate {
    pub data: TableData,
    pub is_trace: bool,
    pub trace_id: usize,
}

#[derive(Debug, Default, Clone, Serialize, Deserialize)]
#[serde(rename_all(serialize = "camelCase", deserialize = "camelCase"))]
pub struct TraceValues {
    pub id: usize,
    pub locals: Vec<Vec<StringAndValueTuple>>,
}

#[derive(Debug, Default, Clone, Serialize, Deserialize)]
#[serde(rename_all(serialize = "camelCase", deserialize = "camelCase"))]
pub struct UpdateColumns {
    pub data: String,
    pub name: String,
    pub orderable: bool,
    pub search: SearchValue,
    pub searchable: bool,
}

#[derive(Debug, Default, Clone, Serialize, Deserialize)]
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
pub struct UpdateTableArgs {
    pub table_args: TableArgs,
    pub selected_kinds: [bool; EVENT_KINDS_COUNT],
    pub is_trace: bool,
    pub trace_id: usize,
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
        trace_id: usize,
        result_index: usize,
        stop_type: StopType,
    ) -> Stop {
        let now = SystemTime::now();
        let time = now
            .duration_since(UNIX_EPOCH)
            .expect("expected now is always >= UNIX_EPOCH");
        let address = format!("{}:{}", path, line);
        Stop {
            tracepoint_id: trace_id,
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

#[derive(Debug, Default, Clone, Serialize, Deserialize)]
#[serde(rename_all(serialize = "camelCase", deserialize = "camelCase"))]
pub struct HistoryResult {
    pub location: Location,
    pub value: Value,
    pub time: u64,
    pub description: String,
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
        }
    }
}

#[derive(Debug, Default, Clone, Serialize, Deserialize)]
#[serde(rename_all(serialize = "camelCase", deserialize = "camelCase"))]
pub struct HistoryUpdate {
    pub expression: String,
    pub results: Vec<HistoryResult>,
    pub finish: bool,
}

impl HistoryUpdate {
    pub fn new(expression: String, results: &[HistoryResult]) -> HistoryUpdate {
        HistoryUpdate {
            expression,
            results: results.to_vec(),
            finish: true,
        }
    }
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
#[serde(rename_all(serialize = "camelCase", deserialize = "camelCase"))]
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
    pub iteration: i64,
    pub first_loop_line: i64,
    pub rr_ticks: i64,
    pub reverse: bool,
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


#[derive(Serialize, Deserialize, Debug, PartialEq, Default, Clone)]
#[serde(rename_all = "camelCase")]
pub struct CtUpdatedTableResponseBody {
    pub table_update: TableUpdate,
}

#[derive(Serialize, Deserialize, Debug, PartialEq, Default, Clone)]
#[serde(rename_all = "camelCase")]
pub struct CtLoadLocalsResponseBody {
    pub locals: Vec<Variable>,
}

#[derive(Serialize, Deserialize, Debug, PartialEq, Default, Clone)]
#[serde(rename_all = "camelCase")]
pub struct CtLoadLocalsArguments {
    pub rr_ticks: i64,
    pub count_budget: i64,
    pub min_count_limit: i64,
}
