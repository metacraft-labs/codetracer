// use std::path::PathBuf;
use core::fmt;
use num_derive::FromPrimitive;
use serde::{Deserialize, Serialize};
use serde_repr::*;
use std::collections::HashMap;
use std::time::{SystemTime, UNIX_EPOCH};

use crate::lang::*;
use crate::value::Value;

#[derive(Debug, Default, Serialize, Deserialize)]
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

#[derive(Debug, Default, Serialize, Deserialize)]
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
    pub skip_internal: bool
}

#[derive(Debug, Default, Serialize, Deserialize)]
pub struct EmptyArg {}

pub const EMPTY_ARG: EmptyArg = EmptyArg {};
pub const NO_PATH: &str = "<unknown>";
pub const NO_POSITION: i64 = -1;
pub const NO_EVENT: i64 = -1;
pub const NO_OFFSET: i64 = -1;
pub const NO_INDEX: i64 = -1;
pub const NO_KEY: &str = "-1";

#[derive(Debug, Default, Clone, Serialize, Deserialize)]
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

#[derive(
    Debug, Default, Copy, Clone, FromPrimitive, Serialize_repr, Deserialize_repr, PartialEq,
)]
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

#[derive(
    Debug, Default, Copy, Clone, FromPrimitive, Serialize_repr, Deserialize_repr, PartialEq,
)]
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
#[serde(rename_all(deserialize = "camelCase"))]
pub struct FrameInfo {
    offset: usize,
    has_selected: bool,
}

#[derive(Debug, Default, Clone, PartialEq, Eq, Hash, Serialize, Deserialize, PartialOrd, Ord)]
pub struct Position(i64);

#[derive(Debug, Default, Clone, Serialize, Deserialize, PartialEq, Eq, PartialOrd, Ord)]
pub struct StepCount(i64);

#[derive(Debug, Default, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct LoopId(i64);

#[derive(Debug, Default, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct Iteration(i64);

#[derive(Debug, Default, Clone, Serialize, Deserialize, PartialEq, Eq, PartialOrd, Ord)]
pub struct RRTicks(pub i64);

pub const NO_LOOP_ID: LoopId = LoopId(-1);

pub const NOT_IN_A_LOOP: Iteration = Iteration(-1);

#[derive(Debug, Default, Clone, Serialize, Deserialize)]
pub struct FlowUpdateState {
    pub kind: FlowUpdateStateKind,
    #[serde(default)]
    pub steps: u64,
}

#[derive(
    Debug, Default, Copy, Clone, FromPrimitive, Serialize_repr, Deserialize_repr, PartialEq,
)]
#[repr(u8)]
pub enum FlowUpdateStateKind {
    #[default]
    FlowNotLoading,
    FlowWaitingForStart,
    FlowLoading,
    FlowFinished,
}

#[derive(Debug, Default, Clone, Serialize, Deserialize)]
#[serde(rename_all(serialize = "camelCase", deserialize = "camelCase"))]
pub struct Loop {
    pub base: LoopId,
    pub base_iteration: Iteration,
    pub internal: Vec<LoopId>,
    pub first: Position,
    pub last: Position,
    pub iteration: Iteration,
    pub step_counts: Vec<StepCount>,
    pub rr_ticks_for_iterations: Vec<RRTicks>,
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
}

#[derive(Debug, Default, Clone, Serialize, Deserialize)]
#[serde(rename_all(serialize = "camelCase", deserialize = "camelCase"))]
pub struct FlowViewUpdate {
    pub location: Location,
    pub position_step_counts: HashMap<Position, Vec<StepCount>>,
    pub steps: Vec<FlowStep>,
    pub loops: Vec<Loop>,
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

#[derive(
    Debug, Default, Copy, Clone, FromPrimitive, Serialize_repr, Deserialize_repr, PartialEq,
)]
#[repr(u8)]
pub enum EventLogKind {
    #[default]
    Write,
    WriteFile,
    Read,
    ReadFile,
    // not used for now
    ReadDir,
    OpenDir,
    CloseDir,
    Socket,
    Open,
    // used for trace log events
    TraceLogEvent,
}

#[derive(Debug, Default, Clone, Serialize, Deserialize)]
#[serde(rename_all(serialize = "camelCase", deserialize = "camelCase"))]
pub struct ProgramEvent {
    pub kind: EventLogKind,
    pub content: String,
    pub rr_event_id: usize,
    pub high_level_path: String,
    pub high_level_line: i64,
    pub filename_metadata: String,
    pub bytes: usize,
    pub stdout: bool,
    #[serde(rename = "directLocationRRTicks")]
    pub direct_location_rr_ticks: i64,
    pub tracepoint_result_index: i64,
    pub event_index: usize,
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

impl fmt::Display for SourceCallJumpTarget {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{}:{}:{}", self.token, self.path, self.line)
    }
}

#[derive(
    Debug, Default, Copy, Clone, FromPrimitive, Serialize_repr, Deserialize_repr, PartialEq,
)]
#[repr(u8)]
pub enum TracepointMode {
    #[default]
    TracInlineCode,
    TracExpandable,
    TracVisual,
}

#[derive(
    Debug, Default, Copy, Clone, FromPrimitive, Serialize_repr, Deserialize_repr, PartialEq,
)]
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
pub struct TraceUpdate {
    #[serde(rename = "updateID")]
    pub update_id: usize,
    pub results: Vec<Stop>,
    pub id_table: HashMap<usize, TraceResult>,
    pub finish: bool,
    #[serde(rename = "sessionID")]
    pub session_id: usize,
    pub tracepoint_errors: HashMap<String, String>,
}

impl TraceUpdate {
    pub fn new(
        session_id: usize,
        results: Vec<Stop>,
        id_table: HashMap<usize, TraceResult>,
    ) -> TraceUpdate {
        TraceUpdate {
            session_id,
            update_id: 0,
            results,
            finish: false,
            tracepoint_errors: HashMap::new(),
            id_table,
        }
    }
}

#[derive(Debug, Default, Clone, Serialize, Deserialize)]
#[serde(rename_all(serialize = "PascalCase", deserialize = "PascalCase"))]
pub struct NamedTuple {
    pub field0: String,
    pub field1: Value,
}

#[derive(Debug, Default, Clone, Serialize, Deserialize)]
#[serde(rename_all(serialize = "camelCase", deserialize = "camelCase"))]
pub struct Stop {
    pub tracepoint_id: usize,
    pub time: u64,
    pub line: usize,
    pub path: String,
    pub offset: usize,
    pub address: String,
    pub iteration: usize,
    pub result_index: usize,
    pub event: usize,
    pub mode: TracepointMode,
    pub locals: Vec<NamedTuple>,
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
    pub fn new(
        path: String,
        line: usize,
        locals: Vec<NamedTuple>,
        step_id: usize,
        trace_id: usize,
        result_index: usize,
        stop_type: StopType,
    ) -> Stop {
        let now = SystemTime::now();
        let time = now.duration_since(UNIX_EPOCH).unwrap();
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

#[derive(
    Debug, Default, Copy, Clone, FromPrimitive, Serialize_repr, Deserialize_repr, PartialEq,
)]
#[repr(u8)]
pub enum NotificationKind {
    #[default]
    Info,
    Warning,
    Error,
    Success,
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
}

impl Notification {
    pub fn new(kind: NotificationKind, msg: &str, is_operation_status: bool) -> Notification {
        let now = SystemTime::now();
        let time = now.duration_since(UNIX_EPOCH).unwrap();
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
    MissingTaskKind,
}

#[derive(Debug, Default, Clone)]
pub struct TaskId(String);

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
    SentFlowShape,
    DebugOutput,
    NewNotification,
    Error,
    MissingEventKind,
}

#[derive(Debug, Default, Clone)]
pub struct EventId(String);

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
        "step" => Some(TaskKind::Step),
        "eventLoad" => Some(TaskKind::EventLoad),
        "eventJump" => Some(TaskKind::EventJump),
        "calltraceJump" => Some(TaskKind::CalltraceJump),
        "sourceLineJump" => Some(TaskKind::SourceLineJump),
        "sourceCallJump" => Some(TaskKind::SourceCallJump),
        "run-to-entry" => Some(TaskKind::RunToEntry),
        "addBreak" => Some(TaskKind::AddBreak),
        "deleteBreak" => Some(TaskKind::DeleteBreak),
        "disable" => Some(TaskKind::Disable),
        "enable" => Some(TaskKind::Enable),
        "runTracepoints" => Some(TaskKind::RunTracepoints),
        "traceJump" => Some(TaskKind::TraceJump),
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
    pub fn new(action: Action) -> StepArg {
        StepArg {
            action,
            reverse: false,
            repeat: 1,
            complete: true,
            skip_internal: false,
            skip_no_source: false
        }
    }
}
