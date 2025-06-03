// use std::path::PathBuf;
use num_derive::FromPrimitive;
use serde::{Deserialize, Serialize};
use serde_repr::*;
use std::collections::HashMap;

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
    pub callgraph: bool,
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

#[derive(Debug, Default, Serialize, Deserialize)]
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

pub const EMPTY_ARG: EmptyArg = EmptyArg {};

#[derive(Debug, Default, Clone, Serialize, Deserialize)]
#[serde(rename_all(serialize = "camelCase", deserialize = "camelCase"))]
pub struct Location {
    pub path: String,
    pub line: u64,
    pub function_name: String,
    pub high_level_path: String,
    pub high_level_line: u64,
    pub low_level_path: String,
    pub low_level_line: u64,
    pub rr_ticks: RRTicks,
    pub function_first: i64,
    pub function_last: i64,
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
pub struct RRTicks(i64);

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

#[derive(Debug, Default, Copy, Clone, Serialize, Deserialize)]
pub enum TaskKind {
    #[default]
    LoadFlow = 0,
    LoadFlowShape,
    RunTracepoints,
    LoadHistory,
    LoadHistoryWorker,
    CallgraphSearch,
    EventLoad,
    LoadCallArgs,
    ResetOperation,
    CallgraphJump,
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
    LoadTerminal,
}

#[derive(Debug, Default, Clone)]
pub struct TaskId(String);

#[derive(Debug, Default)]
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

pub static mut TASK_ID_MAP: &'static mut [usize] = &mut [0; 100];

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
            action: action,
            reverse: false,
            repeat: 1,
            complete: true,
            skip_internal: false,
            skip_no_source: false,
        }
    }
}
