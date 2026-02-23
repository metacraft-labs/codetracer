use serde::{Deserialize, Serialize};

use crate::lang::Lang;
use crate::task::{Action, Breakpoint, CtLoadLocalsArguments, LoadHistoryArg, Location, ProgramEvent};
use crate::value::ValueRecordWithType;

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "kind")]
pub enum CtRRQuery {
    RunToEntry,
    LoadLocation,
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

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
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
