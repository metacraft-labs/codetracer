
use num_derive::FromPrimitive;
use serde::{Deserialize, Serialize};
use serde_repr::*;

// use std::collections::HashMap;
// use crate::lang::*;
// use crate::value::{Type, Value};

#[derive(Debug, Default, Clone, Serialize, Deserialize)]
#[serde(rename_all(serialize = "camelCase", deserialize = "camelCase"))]
pub struct ErrorResponsebody {
    pub error: Option<Message>,
}

#[derive(Debug, Default, Clone, Serialize, Deserialize)]
#[serde(rename_all(serialize = "camelCase", deserialize = "camelCase"))]
pub struct CancelArguments {
    pub requestId: Option<i64>,
    pub progressId: Option<String>,
}

#[derive(Debug, Default, Clone, Serialize, Deserialize)]
#[serde(rename_all(serialize = "camelCase", deserialize = "camelCase"))]
pub struct StoppedEventbody {
    pub reason: String,
    pub description: Option<String>,
    pub threadId: Option<i64>,
    pub preserveFocusHint: Option<bool>,
    pub text: Option<String>,
    pub allThreadsStopped: Option<bool>,
    pub hitBreakpointIds: Option<array>,
}

#[derive(Debug, Default, Clone, Serialize, Deserialize)]
#[serde(rename_all(serialize = "camelCase", deserialize = "camelCase"))]
pub struct ContinuedEventbody {
    pub threadId: i64,
    pub allThreadsContinued: Option<bool>,
}

#[derive(Debug, Default, Clone, Serialize, Deserialize)]
#[serde(rename_all(serialize = "camelCase", deserialize = "camelCase"))]
pub struct ExitedEventbody {
    pub exitCode: i64,
}

#[derive(Debug, Default, Clone, Serialize, Deserialize)]
#[serde(rename_all(serialize = "camelCase", deserialize = "camelCase"))]
pub struct TerminatedEventbody {
    pub restart: Option<serde_json::Value>,
}

#[derive(Debug, Default, Clone, Serialize, Deserialize)]
#[serde(rename_all(serialize = "camelCase", deserialize = "camelCase"))]
pub struct ThreadEventbody {
    pub reason: String,
    pub threadId: i64,
}

#[derive(Debug, Default, Clone, Serialize, Deserialize)]
#[serde(rename_all(serialize = "camelCase", deserialize = "camelCase"))]
pub struct OutputEventbody {
    pub category: Option<String>,
    pub output: String,
    pub group: Option<String>,
    pub variablesReference: Option<i64>,
    pub source: Option<Source>,
    pub line: Option<i64>,
    pub column: Option<i64>,
    pub data: Option<serde_json::Value>,
    pub locationReference: Option<i64>,
}

#[derive(Debug, Default, Clone, Serialize, Deserialize)]
#[serde(rename_all(serialize = "camelCase", deserialize = "camelCase"))]
pub struct BreakpointEventbody {
    pub reason: String,
    pub breakpoint: Breakpoint,
}

#[derive(Debug, Default, Clone, Serialize, Deserialize)]
#[serde(rename_all(serialize = "camelCase", deserialize = "camelCase"))]
pub struct ModuleEventbody {
    pub reason: String,
    pub module: Module,
}

#[derive(Debug, Default, Clone, Serialize, Deserialize)]
#[serde(rename_all(serialize = "camelCase", deserialize = "camelCase"))]
pub struct LoadedSourceEventbody {
    pub reason: String,
    pub source: Source,
}

#[derive(Debug, Default, Clone, Serialize, Deserialize)]
#[serde(rename_all(serialize = "camelCase", deserialize = "camelCase"))]
pub struct ProcessEventbody {
    pub name: String,
    pub systemProcessId: Option<i64>,
    pub isLocalProcess: Option<bool>,
    pub startMethod: Option<String>,
    pub pointerSize: Option<i64>,
}

#[derive(Debug, Default, Clone, Serialize, Deserialize)]
#[serde(rename_all(serialize = "camelCase", deserialize = "camelCase"))]
pub struct CapabilitiesEventbody {
    pub capabilities: Capabilities,
}

#[derive(Debug, Default, Clone, Serialize, Deserialize)]
#[serde(rename_all(serialize = "camelCase", deserialize = "camelCase"))]
pub struct ProgressStartEventbody {
    pub progressId: String,
    pub title: String,
    pub requestId: Option<i64>,
    pub cancellable: Option<bool>,
    pub message: Option<String>,
    pub percentage: Option<i64>,
}

#[derive(Debug, Default, Clone, Serialize, Deserialize)]
#[serde(rename_all(serialize = "camelCase", deserialize = "camelCase"))]
pub struct ProgressUpdateEventbody {
    pub progressId: String,
    pub message: Option<String>,
    pub percentage: Option<i64>,
}

#[derive(Debug, Default, Clone, Serialize, Deserialize)]
#[serde(rename_all(serialize = "camelCase", deserialize = "camelCase"))]
pub struct ProgressEndEventbody {
    pub progressId: String,
    pub message: Option<String>,
}

#[derive(Debug, Default, Clone, Serialize, Deserialize)]
#[serde(rename_all(serialize = "camelCase", deserialize = "camelCase"))]
pub struct InvalidatedEventbody {
    pub areas: Option<array>,
    pub threadId: Option<i64>,
    pub stackFrameId: Option<i64>,
}

#[derive(Debug, Default, Clone, Serialize, Deserialize)]
#[serde(rename_all(serialize = "camelCase", deserialize = "camelCase"))]
pub struct MemoryEventbody {
    pub memoryReference: String,
    pub offset: i64,
    pub count: i64,
}

#[derive(Debug, Default, Clone, Serialize, Deserialize)]
#[serde(rename_all(serialize = "camelCase", deserialize = "camelCase"))]
pub struct RunInTerminalRequestArgumentsenv {

}

#[derive(Debug, Default, Clone, Serialize, Deserialize)]
#[serde(rename_all(serialize = "camelCase", deserialize = "camelCase"))]
pub struct RunInTerminalRequestArguments {
    pub kind: Option<String>,
    pub title: Option<String>,
    pub cwd: String,
    pub args: array,
    pub env: Option<RunInTerminalRequestArgumentsenv>,
    pub argsCanBeInterpretedByShell: Option<bool>,
}

#[derive(Debug, Default, Clone, Serialize, Deserialize)]
#[serde(rename_all(serialize = "camelCase", deserialize = "camelCase"))]
pub struct RunInTerminalResponsebody {
    pub processId: Option<i64>,
    pub shellProcessId: Option<i64>,
}

#[derive(Debug, Default, Clone, Serialize, Deserialize)]
#[serde(rename_all(serialize = "camelCase", deserialize = "camelCase"))]
pub struct StartDebuggingRequestArgumentsconfiguration {

}

#[derive(Debug, Default, Clone, Serialize, Deserialize)]
#[serde(rename_all(serialize = "camelCase", deserialize = "camelCase"))]
pub struct StartDebuggingRequestArguments {
    pub configuration: StartDebuggingRequestArgumentsconfiguration,
    pub request: String,
}

#[derive(Debug, Default, Clone, Serialize, Deserialize)]
#[serde(rename_all(serialize = "camelCase", deserialize = "camelCase"))]
pub struct InitializeRequestArguments {
    pub clientID: Option<String>,
    pub clientName: Option<String>,
    pub adapterID: String,
    pub locale: Option<String>,
    pub linesStartAt1: Option<bool>,
    pub columnsStartAt1: Option<bool>,
    pub pathFormat: Option<String>,
    pub supportsVariableType: Option<bool>,
    pub supportsVariablePaging: Option<bool>,
    pub supportsRunInTerminalRequest: Option<bool>,
    pub supportsMemoryReferences: Option<bool>,
    pub supportsProgressReporting: Option<bool>,
    pub supportsInvalidatedEvent: Option<bool>,
    pub supportsMemoryEvent: Option<bool>,
    pub supportsArgsCanBeInterpretedByShell: Option<bool>,
    pub supportsStartDebuggingRequest: Option<bool>,
    pub supportsANSIStyling: Option<bool>,
}

#[derive(Debug, Default, Clone, Serialize, Deserialize)]
#[serde(rename_all(serialize = "camelCase", deserialize = "camelCase"))]
pub struct ConfigurationDoneArguments {

}

#[derive(Debug, Default, Clone, Serialize, Deserialize)]
#[serde(rename_all(serialize = "camelCase", deserialize = "camelCase"))]
pub struct LaunchRequestArguments {
    pub noDebug: Option<bool>,
    pub __restart: Option<serde_json::Value>,
}

#[derive(Debug, Default, Clone, Serialize, Deserialize)]
#[serde(rename_all(serialize = "camelCase", deserialize = "camelCase"))]
pub struct AttachRequestArguments {
    pub __restart: Option<serde_json::Value>,
}

#[derive(Debug, Default, Clone, Serialize, Deserialize)]
#[serde(rename_all(serialize = "camelCase", deserialize = "camelCase"))]
pub struct RestartArguments {

}

#[derive(Debug, Default, Clone, Serialize, Deserialize)]
#[serde(rename_all(serialize = "camelCase", deserialize = "camelCase"))]
pub struct DisconnectArguments {
    pub restart: Option<bool>,
    pub terminateDebuggee: Option<bool>,
    pub suspendDebuggee: Option<bool>,
}

#[derive(Debug, Default, Clone, Serialize, Deserialize)]
#[serde(rename_all(serialize = "camelCase", deserialize = "camelCase"))]
pub struct TerminateArguments {
    pub restart: Option<bool>,
}

#[derive(Debug, Default, Clone, Serialize, Deserialize)]
#[serde(rename_all(serialize = "camelCase", deserialize = "camelCase"))]
pub struct BreakpointLocationsArguments {
    pub source: Source,
    pub line: i64,
    pub column: Option<i64>,
    pub endLine: Option<i64>,
    pub endColumn: Option<i64>,
}

#[derive(Debug, Default, Clone, Serialize, Deserialize)]
#[serde(rename_all(serialize = "camelCase", deserialize = "camelCase"))]
pub struct BreakpointLocationsResponsebody {
    pub breakpoints: array,
}

#[derive(Debug, Default, Clone, Serialize, Deserialize)]
#[serde(rename_all(serialize = "camelCase", deserialize = "camelCase"))]
pub struct SetBreakpointsArguments {
    pub source: Source,
    pub breakpoints: Option<array>,
    pub lines: Option<array>,
    pub sourceModified: Option<bool>,
}

#[derive(Debug, Default, Clone, Serialize, Deserialize)]
#[serde(rename_all(serialize = "camelCase", deserialize = "camelCase"))]
pub struct SetBreakpointsResponsebody {
    pub breakpoints: array,
}

#[derive(Debug, Default, Clone, Serialize, Deserialize)]
#[serde(rename_all(serialize = "camelCase", deserialize = "camelCase"))]
pub struct SetFunctionBreakpointsArguments {
    pub breakpoints: array,
}

#[derive(Debug, Default, Clone, Serialize, Deserialize)]
#[serde(rename_all(serialize = "camelCase", deserialize = "camelCase"))]
pub struct SetFunctionBreakpointsResponsebody {
    pub breakpoints: array,
}

#[derive(Debug, Default, Clone, Serialize, Deserialize)]
#[serde(rename_all(serialize = "camelCase", deserialize = "camelCase"))]
pub struct SetExceptionBreakpointsArguments {
    pub filters: array,
    pub filterOptions: Option<array>,
    pub exceptionOptions: Option<array>,
}

#[derive(Debug, Default, Clone, Serialize, Deserialize)]
#[serde(rename_all(serialize = "camelCase", deserialize = "camelCase"))]
pub struct SetExceptionBreakpointsResponsebody {
    pub breakpoints: Option<array>,
}

#[derive(Debug, Default, Clone, Serialize, Deserialize)]
#[serde(rename_all(serialize = "camelCase", deserialize = "camelCase"))]
pub struct DataBreakpointInfoArguments {
    pub variablesReference: Option<i64>,
    pub name: String,
    pub frameId: Option<i64>,
    pub bytes: Option<i64>,
    pub asAddress: Option<bool>,
    pub mode: Option<String>,
}

#[derive(Debug, Default, Clone, Serialize, Deserialize)]
#[serde(rename_all(serialize = "camelCase", deserialize = "camelCase"))]
pub struct DataBreakpointInfoResponsebody {
    pub dataId: serde_json::Value,
    pub description: String,
    pub accessTypes: Option<array>,
    pub canPersist: Option<bool>,
}

#[derive(Debug, Default, Clone, Serialize, Deserialize)]
#[serde(rename_all(serialize = "camelCase", deserialize = "camelCase"))]
pub struct SetDataBreakpointsArguments {
    pub breakpoints: array,
}

#[derive(Debug, Default, Clone, Serialize, Deserialize)]
#[serde(rename_all(serialize = "camelCase", deserialize = "camelCase"))]
pub struct SetDataBreakpointsResponsebody {
    pub breakpoints: array,
}

#[derive(Debug, Default, Clone, Serialize, Deserialize)]
#[serde(rename_all(serialize = "camelCase", deserialize = "camelCase"))]
pub struct SetInstructionBreakpointsArguments {
    pub breakpoints: array,
}

#[derive(Debug, Default, Clone, Serialize, Deserialize)]
#[serde(rename_all(serialize = "camelCase", deserialize = "camelCase"))]
pub struct SetInstructionBreakpointsResponsebody {
    pub breakpoints: array,
}

#[derive(Debug, Default, Clone, Serialize, Deserialize)]
#[serde(rename_all(serialize = "camelCase", deserialize = "camelCase"))]
pub struct ContinueArguments {
    pub threadId: i64,
    pub singleThread: Option<bool>,
}

#[derive(Debug, Default, Clone, Serialize, Deserialize)]
#[serde(rename_all(serialize = "camelCase", deserialize = "camelCase"))]
pub struct ContinueResponsebody {
    pub allThreadsContinued: Option<bool>,
}

#[derive(Debug, Default, Clone, Serialize, Deserialize)]
#[serde(rename_all(serialize = "camelCase", deserialize = "camelCase"))]
pub struct NextArguments {
    pub threadId: i64,
    pub singleThread: Option<bool>,
    pub granularity: Option<SteppingGranularity>,
}

#[derive(Debug, Default, Clone, Serialize, Deserialize)]
#[serde(rename_all(serialize = "camelCase", deserialize = "camelCase"))]
pub struct StepInArguments {
    pub threadId: i64,
    pub singleThread: Option<bool>,
    pub targetId: Option<i64>,
    pub granularity: Option<SteppingGranularity>,
}

#[derive(Debug, Default, Clone, Serialize, Deserialize)]
#[serde(rename_all(serialize = "camelCase", deserialize = "camelCase"))]
pub struct StepOutArguments {
    pub threadId: i64,
    pub singleThread: Option<bool>,
    pub granularity: Option<SteppingGranularity>,
}

#[derive(Debug, Default, Clone, Serialize, Deserialize)]
#[serde(rename_all(serialize = "camelCase", deserialize = "camelCase"))]
pub struct StepBackArguments {
    pub threadId: i64,
    pub singleThread: Option<bool>,
    pub granularity: Option<SteppingGranularity>,
}

#[derive(Debug, Default, Clone, Serialize, Deserialize)]
#[serde(rename_all(serialize = "camelCase", deserialize = "camelCase"))]
pub struct ReverseContinueArguments {
    pub threadId: i64,
    pub singleThread: Option<bool>,
}

#[derive(Debug, Default, Clone, Serialize, Deserialize)]
#[serde(rename_all(serialize = "camelCase", deserialize = "camelCase"))]
pub struct RestartFrameArguments {
    pub frameId: i64,
}

#[derive(Debug, Default, Clone, Serialize, Deserialize)]
#[serde(rename_all(serialize = "camelCase", deserialize = "camelCase"))]
pub struct GotoArguments {
    pub threadId: i64,
    pub targetId: i64,
}

#[derive(Debug, Default, Clone, Serialize, Deserialize)]
#[serde(rename_all(serialize = "camelCase", deserialize = "camelCase"))]
pub struct PauseArguments {
    pub threadId: i64,
}

#[derive(Debug, Default, Clone, Serialize, Deserialize)]
#[serde(rename_all(serialize = "camelCase", deserialize = "camelCase"))]
pub struct StackTraceArguments {
    pub threadId: i64,
    pub startFrame: Option<i64>,
    pub levels: Option<i64>,
    pub format: Option<StackFrameFormat>,
}

#[derive(Debug, Default, Clone, Serialize, Deserialize)]
#[serde(rename_all(serialize = "camelCase", deserialize = "camelCase"))]
pub struct StackTraceResponsebody {
    pub stackFrames: array,
    pub totalFrames: Option<i64>,
}

#[derive(Debug, Default, Clone, Serialize, Deserialize)]
#[serde(rename_all(serialize = "camelCase", deserialize = "camelCase"))]
pub struct ScopesArguments {
    pub frameId: i64,
}

#[derive(Debug, Default, Clone, Serialize, Deserialize)]
#[serde(rename_all(serialize = "camelCase", deserialize = "camelCase"))]
pub struct ScopesResponsebody {
    pub scopes: array,
}

#[derive(Debug, Default, Clone, Serialize, Deserialize)]
#[serde(rename_all(serialize = "camelCase", deserialize = "camelCase"))]
pub struct VariablesArguments {
    pub variablesReference: i64,
    pub filter: Option<String>,
    pub start: Option<i64>,
    pub count: Option<i64>,
    pub format: Option<ValueFormat>,
}

#[derive(Debug, Default, Clone, Serialize, Deserialize)]
#[serde(rename_all(serialize = "camelCase", deserialize = "camelCase"))]
pub struct VariablesResponsebody {
    pub variables: array,
}

#[derive(Debug, Default, Clone, Serialize, Deserialize)]
#[serde(rename_all(serialize = "camelCase", deserialize = "camelCase"))]
pub struct SetVariableArguments {
    pub variablesReference: i64,
    pub name: String,
    pub value: String,
    pub format: Option<ValueFormat>,
}

#[derive(Debug, Default, Clone, Serialize, Deserialize)]
#[serde(rename_all(serialize = "camelCase", deserialize = "camelCase"))]
pub struct SetVariableResponsebody {
    pub value: String,
    pub r#type: Option<String>,
    pub variablesReference: Option<i64>,
    pub namedVariables: Option<i64>,
    pub indexedVariables: Option<i64>,
    pub memoryReference: Option<String>,
    pub valueLocationReference: Option<i64>,
}

#[derive(Debug, Default, Clone, Serialize, Deserialize)]
#[serde(rename_all(serialize = "camelCase", deserialize = "camelCase"))]
pub struct SourceArguments {
    pub source: Option<Source>,
    pub sourceReference: i64,
}

#[derive(Debug, Default, Clone, Serialize, Deserialize)]
#[serde(rename_all(serialize = "camelCase", deserialize = "camelCase"))]
pub struct SourceResponsebody {
    pub content: String,
    pub mimeType: Option<String>,
}

#[derive(Debug, Default, Clone, Serialize, Deserialize)]
#[serde(rename_all(serialize = "camelCase", deserialize = "camelCase"))]
pub struct ThreadsResponsebody {
    pub threads: array,
}

#[derive(Debug, Default, Clone, Serialize, Deserialize)]
#[serde(rename_all(serialize = "camelCase", deserialize = "camelCase"))]
pub struct TerminateThreadsArguments {
    pub threadIds: Option<array>,
}

#[derive(Debug, Default, Clone, Serialize, Deserialize)]
#[serde(rename_all(serialize = "camelCase", deserialize = "camelCase"))]
pub struct ModulesArguments {
    pub startModule: Option<i64>,
    pub moduleCount: Option<i64>,
}

#[derive(Debug, Default, Clone, Serialize, Deserialize)]
#[serde(rename_all(serialize = "camelCase", deserialize = "camelCase"))]
pub struct ModulesResponsebody {
    pub modules: array,
    pub totalModules: Option<i64>,
}

#[derive(Debug, Default, Clone, Serialize, Deserialize)]
#[serde(rename_all(serialize = "camelCase", deserialize = "camelCase"))]
pub struct LoadedSourcesArguments {

}

#[derive(Debug, Default, Clone, Serialize, Deserialize)]
#[serde(rename_all(serialize = "camelCase", deserialize = "camelCase"))]
pub struct LoadedSourcesResponsebody {
    pub sources: array,
}

#[derive(Debug, Default, Clone, Serialize, Deserialize)]
#[serde(rename_all(serialize = "camelCase", deserialize = "camelCase"))]
pub struct EvaluateArguments {
    pub expression: String,
    pub frameId: Option<i64>,
    pub line: Option<i64>,
    pub column: Option<i64>,
    pub source: Option<Source>,
    pub context: Option<String>,
    pub format: Option<ValueFormat>,
}

#[derive(Debug, Default, Clone, Serialize, Deserialize)]
#[serde(rename_all(serialize = "camelCase", deserialize = "camelCase"))]
pub struct EvaluateResponsebody {
    pub result: String,
    pub r#type: Option<String>,
    pub presentationHint: Option<VariablePresentationHint>,
    pub variablesReference: i64,
    pub namedVariables: Option<i64>,
    pub indexedVariables: Option<i64>,
    pub memoryReference: Option<String>,
    pub valueLocationReference: Option<i64>,
}

#[derive(Debug, Default, Clone, Serialize, Deserialize)]
#[serde(rename_all(serialize = "camelCase", deserialize = "camelCase"))]
pub struct SetExpressionArguments {
    pub expression: String,
    pub value: String,
    pub frameId: Option<i64>,
    pub format: Option<ValueFormat>,
}

#[derive(Debug, Default, Clone, Serialize, Deserialize)]
#[serde(rename_all(serialize = "camelCase", deserialize = "camelCase"))]
pub struct SetExpressionResponsebody {
    pub value: String,
    pub r#type: Option<String>,
    pub presentationHint: Option<VariablePresentationHint>,
    pub variablesReference: Option<i64>,
    pub namedVariables: Option<i64>,
    pub indexedVariables: Option<i64>,
    pub memoryReference: Option<String>,
    pub valueLocationReference: Option<i64>,
}

#[derive(Debug, Default, Clone, Serialize, Deserialize)]
#[serde(rename_all(serialize = "camelCase", deserialize = "camelCase"))]
pub struct StepInTargetsArguments {
    pub frameId: i64,
}

#[derive(Debug, Default, Clone, Serialize, Deserialize)]
#[serde(rename_all(serialize = "camelCase", deserialize = "camelCase"))]
pub struct StepInTargetsResponsebody {
    pub targets: array,
}

#[derive(Debug, Default, Clone, Serialize, Deserialize)]
#[serde(rename_all(serialize = "camelCase", deserialize = "camelCase"))]
pub struct GotoTargetsArguments {
    pub source: Source,
    pub line: i64,
    pub column: Option<i64>,
}

#[derive(Debug, Default, Clone, Serialize, Deserialize)]
#[serde(rename_all(serialize = "camelCase", deserialize = "camelCase"))]
pub struct GotoTargetsResponsebody {
    pub targets: array,
}

#[derive(Debug, Default, Clone, Serialize, Deserialize)]
#[serde(rename_all(serialize = "camelCase", deserialize = "camelCase"))]
pub struct CompletionsArguments {
    pub frameId: Option<i64>,
    pub text: String,
    pub column: i64,
    pub line: Option<i64>,
}

#[derive(Debug, Default, Clone, Serialize, Deserialize)]
#[serde(rename_all(serialize = "camelCase", deserialize = "camelCase"))]
pub struct CompletionsResponsebody {
    pub targets: array,
}

#[derive(Debug, Default, Clone, Serialize, Deserialize)]
#[serde(rename_all(serialize = "camelCase", deserialize = "camelCase"))]
pub struct ExceptionInfoArguments {
    pub threadId: i64,
}

#[derive(Debug, Default, Clone, Serialize, Deserialize)]
#[serde(rename_all(serialize = "camelCase", deserialize = "camelCase"))]
pub struct ExceptionInfoResponsebody {
    pub exceptionId: String,
    pub description: Option<String>,
    pub breakMode: ExceptionBreakMode,
    pub details: Option<ExceptionDetails>,
}

#[derive(Debug, Default, Clone, Serialize, Deserialize)]
#[serde(rename_all(serialize = "camelCase", deserialize = "camelCase"))]
pub struct ReadMemoryArguments {
    pub memoryReference: String,
    pub offset: Option<i64>,
    pub count: i64,
}

#[derive(Debug, Default, Clone, Serialize, Deserialize)]
#[serde(rename_all(serialize = "camelCase", deserialize = "camelCase"))]
pub struct ReadMemoryResponsebody {
    pub address: String,
    pub unreadableBytes: Option<i64>,
    pub data: Option<String>,
}

#[derive(Debug, Default, Clone, Serialize, Deserialize)]
#[serde(rename_all(serialize = "camelCase", deserialize = "camelCase"))]
pub struct WriteMemoryArguments {
    pub memoryReference: String,
    pub offset: Option<i64>,
    pub allowPartial: Option<bool>,
    pub data: String,
}

#[derive(Debug, Default, Clone, Serialize, Deserialize)]
#[serde(rename_all(serialize = "camelCase", deserialize = "camelCase"))]
pub struct WriteMemoryResponsebody {
    pub offset: Option<i64>,
    pub bytesWritten: Option<i64>,
}

#[derive(Debug, Default, Clone, Serialize, Deserialize)]
#[serde(rename_all(serialize = "camelCase", deserialize = "camelCase"))]
pub struct DisassembleArguments {
    pub memoryReference: String,
    pub offset: Option<i64>,
    pub instructionOffset: Option<i64>,
    pub instructionCount: i64,
    pub resolveSymbols: Option<bool>,
}

#[derive(Debug, Default, Clone, Serialize, Deserialize)]
#[serde(rename_all(serialize = "camelCase", deserialize = "camelCase"))]
pub struct DisassembleResponsebody {
    pub instructions: array,
}

#[derive(Debug, Default, Clone, Serialize, Deserialize)]
#[serde(rename_all(serialize = "camelCase", deserialize = "camelCase"))]
pub struct LocationsArguments {
    pub locationReference: i64,
}

#[derive(Debug, Default, Clone, Serialize, Deserialize)]
#[serde(rename_all(serialize = "camelCase", deserialize = "camelCase"))]
pub struct LocationsResponsebody {
    pub source: Source,
    pub line: i64,
    pub column: Option<i64>,
    pub endLine: Option<i64>,
    pub endColumn: Option<i64>,
}

#[derive(Debug, Default, Clone, Serialize, Deserialize)]
#[serde(rename_all(serialize = "camelCase", deserialize = "camelCase"))]
pub struct Capabilities {
    pub supportsConfigurationDoneRequest: Option<bool>,
    pub supportsFunctionBreakpoints: Option<bool>,
    pub supportsConditionalBreakpoints: Option<bool>,
    pub supportsHitConditionalBreakpoints: Option<bool>,
    pub supportsEvaluateForHovers: Option<bool>,
    pub exceptionBreakpointFilters: Option<array>,
    pub supportsStepBack: Option<bool>,
    pub supportsSetVariable: Option<bool>,
    pub supportsRestartFrame: Option<bool>,
    pub supportsGotoTargetsRequest: Option<bool>,
    pub supportsStepInTargetsRequest: Option<bool>,
    pub supportsCompletionsRequest: Option<bool>,
    pub completionTriggerCharacters: Option<array>,
    pub supportsModulesRequest: Option<bool>,
    pub additionalModuleColumns: Option<array>,
    pub supportedChecksumAlgorithms: Option<array>,
    pub supportsRestartRequest: Option<bool>,
    pub supportsExceptionOptions: Option<bool>,
    pub supportsValueFormattingOptions: Option<bool>,
    pub supportsExceptionInfoRequest: Option<bool>,
    pub supportTerminateDebuggee: Option<bool>,
    pub supportSuspendDebuggee: Option<bool>,
    pub supportsDelayedStackTraceLoading: Option<bool>,
    pub supportsLoadedSourcesRequest: Option<bool>,
    pub supportsLogPoints: Option<bool>,
    pub supportsTerminateThreadsRequest: Option<bool>,
    pub supportsSetExpression: Option<bool>,
    pub supportsTerminateRequest: Option<bool>,
    pub supportsDataBreakpoints: Option<bool>,
    pub supportsReadMemoryRequest: Option<bool>,
    pub supportsWriteMemoryRequest: Option<bool>,
    pub supportsDisassembleRequest: Option<bool>,
    pub supportsCancelRequest: Option<bool>,
    pub supportsBreakpointLocationsRequest: Option<bool>,
    pub supportsClipboardContext: Option<bool>,
    pub supportsSteppingGranularity: Option<bool>,
    pub supportsInstructionBreakpoints: Option<bool>,
    pub supportsExceptionFilterOptions: Option<bool>,
    pub supportsSingleThreadExecutionRequests: Option<bool>,
    pub supportsDataBreakpointBytes: Option<bool>,
    pub breakpointModes: Option<array>,
    pub supportsANSIStyling: Option<bool>,
}

#[derive(Debug, Default, Clone, Serialize, Deserialize)]
#[serde(rename_all(serialize = "camelCase", deserialize = "camelCase"))]
pub struct ExceptionBreakpointsFilter {
    pub filter: String,
    pub label: String,
    pub description: Option<String>,
    pub default: Option<bool>,
    pub supportsCondition: Option<bool>,
    pub conditionDescription: Option<String>,
}

#[derive(Debug, Default, Clone, Serialize, Deserialize)]
#[serde(rename_all(serialize = "camelCase", deserialize = "camelCase"))]
pub struct Messagevariables {

}

#[derive(Debug, Default, Clone, Serialize, Deserialize)]
#[serde(rename_all(serialize = "camelCase", deserialize = "camelCase"))]
pub struct Message {
    pub id: i64,
    pub format: String,
    pub variables: Option<Messagevariables>,
    pub sendTelemetry: Option<bool>,
    pub showUser: Option<bool>,
    pub url: Option<String>,
    pub urlLabel: Option<String>,
}

#[derive(Debug, Default, Clone, Serialize, Deserialize)]
#[serde(rename_all(serialize = "camelCase", deserialize = "camelCase"))]
pub struct Module {
    pub id: serde_json::Value,
    pub name: String,
    pub path: Option<String>,
    pub isOptimized: Option<bool>,
    pub isUserCode: Option<bool>,
    pub version: Option<String>,
    pub symbolStatus: Option<String>,
    pub symbolFilePath: Option<String>,
    pub dateTimeStamp: Option<String>,
    pub addressRange: Option<String>,
}

#[derive(Debug, Default, Clone, Serialize, Deserialize)]
#[serde(rename_all(serialize = "camelCase", deserialize = "camelCase"))]
pub struct ColumnDescriptor {
    pub attributeName: String,
    pub label: String,
    pub format: Option<String>,
    pub r#type: Option<String>,
    pub width: Option<i64>,
}

#[derive(Debug, Default, Clone, Serialize, Deserialize)]
#[serde(rename_all(serialize = "camelCase", deserialize = "camelCase"))]
pub struct Thread {
    pub id: i64,
    pub name: String,
}

#[derive(Debug, Default, Clone, Serialize, Deserialize)]
#[serde(rename_all(serialize = "camelCase", deserialize = "camelCase"))]
pub struct Source {
    pub name: Option<String>,
    pub path: Option<String>,
    pub sourceReference: Option<i64>,
    pub presentationHint: Option<String>,
    pub origin: Option<String>,
    pub sources: Option<array>,
    pub adapterData: Option<serde_json::Value>,
    pub checksums: Option<array>,
}

#[derive(Debug, Default, Clone, Serialize, Deserialize)]
#[serde(rename_all(serialize = "camelCase", deserialize = "camelCase"))]
pub struct StackFrame {
    pub id: i64,
    pub name: String,
    pub source: Option<Source>,
    pub line: i64,
    pub column: i64,
    pub endLine: Option<i64>,
    pub endColumn: Option<i64>,
    pub canRestart: Option<bool>,
    pub instructionPointerReference: Option<String>,
    pub moduleId: Option<serde_json::Value>,
    pub presentationHint: Option<String>,
}

#[derive(Debug, Default, Clone, Serialize, Deserialize)]
#[serde(rename_all(serialize = "camelCase", deserialize = "camelCase"))]
pub struct Scope {
    pub name: String,
    pub presentationHint: Option<String>,
    pub variablesReference: i64,
    pub namedVariables: Option<i64>,
    pub indexedVariables: Option<i64>,
    pub expensive: bool,
    pub source: Option<Source>,
    pub line: Option<i64>,
    pub column: Option<i64>,
    pub endLine: Option<i64>,
    pub endColumn: Option<i64>,
}

#[derive(Debug, Default, Clone, Serialize, Deserialize)]
#[serde(rename_all(serialize = "camelCase", deserialize = "camelCase"))]
pub struct Variable {
    pub name: String,
    pub value: String,
    pub r#type: Option<String>,
    pub presentationHint: Option<VariablePresentationHint>,
    pub evaluateName: Option<String>,
    pub variablesReference: i64,
    pub namedVariables: Option<i64>,
    pub indexedVariables: Option<i64>,
    pub memoryReference: Option<String>,
    pub declarationLocationReference: Option<i64>,
    pub valueLocationReference: Option<i64>,
}

#[derive(Debug, Default, Clone, Serialize, Deserialize)]
#[serde(rename_all(serialize = "camelCase", deserialize = "camelCase"))]
pub struct VariablePresentationHint {
    pub kind: Option<String>,
    pub attributes: Option<array>,
    pub visibility: Option<String>,
    pub lazy: Option<bool>,
}

#[derive(Debug, Default, Clone, Serialize, Deserialize)]
#[serde(rename_all(serialize = "camelCase", deserialize = "camelCase"))]
pub struct BreakpointLocation {
    pub line: i64,
    pub column: Option<i64>,
    pub endLine: Option<i64>,
    pub endColumn: Option<i64>,
}

#[derive(Debug, Default, Clone, Serialize, Deserialize)]
#[serde(rename_all(serialize = "camelCase", deserialize = "camelCase"))]
pub struct SourceBreakpoint {
    pub line: i64,
    pub column: Option<i64>,
    pub condition: Option<String>,
    pub hitCondition: Option<String>,
    pub logMessage: Option<String>,
    pub mode: Option<String>,
}

#[derive(Debug, Default, Clone, Serialize, Deserialize)]
#[serde(rename_all(serialize = "camelCase", deserialize = "camelCase"))]
pub struct FunctionBreakpoint {
    pub name: String,
    pub condition: Option<String>,
    pub hitCondition: Option<String>,
}

#[derive(Debug, Default, Clone, Serialize, Deserialize)]
#[serde(rename_all(serialize = "camelCase", deserialize = "camelCase"))]
pub struct DataBreakpoint {
    pub dataId: String,
    pub accessType: Option<DataBreakpointAccessType>,
    pub condition: Option<String>,
    pub hitCondition: Option<String>,
}

#[derive(Debug, Default, Clone, Serialize, Deserialize)]
#[serde(rename_all(serialize = "camelCase", deserialize = "camelCase"))]
pub struct InstructionBreakpoint {
    pub instructionReference: String,
    pub offset: Option<i64>,
    pub condition: Option<String>,
    pub hitCondition: Option<String>,
    pub mode: Option<String>,
}

#[derive(Debug, Default, Clone, Serialize, Deserialize)]
#[serde(rename_all(serialize = "camelCase", deserialize = "camelCase"))]
pub struct Breakpoint {
    pub id: Option<i64>,
    pub verified: bool,
    pub message: Option<String>,
    pub source: Option<Source>,
    pub line: Option<i64>,
    pub column: Option<i64>,
    pub endLine: Option<i64>,
    pub endColumn: Option<i64>,
    pub instructionReference: Option<String>,
    pub offset: Option<i64>,
    pub reason: Option<String>,
}

#[derive(Debug, Default, Clone, Serialize, Deserialize)]
#[serde(rename_all(serialize = "camelCase", deserialize = "camelCase"))]
pub struct StepInTarget {
    pub id: i64,
    pub label: String,
    pub line: Option<i64>,
    pub column: Option<i64>,
    pub endLine: Option<i64>,
    pub endColumn: Option<i64>,
}

#[derive(Debug, Default, Clone, Serialize, Deserialize)]
#[serde(rename_all(serialize = "camelCase", deserialize = "camelCase"))]
pub struct GotoTarget {
    pub id: i64,
    pub label: String,
    pub line: i64,
    pub column: Option<i64>,
    pub endLine: Option<i64>,
    pub endColumn: Option<i64>,
    pub instructionPointerReference: Option<String>,
}

#[derive(Debug, Default, Clone, Serialize, Deserialize)]
#[serde(rename_all(serialize = "camelCase", deserialize = "camelCase"))]
pub struct CompletionItem {
    pub label: String,
    pub text: Option<String>,
    pub sortText: Option<String>,
    pub detail: Option<String>,
    pub r#type: Option<CompletionItemType>,
    pub start: Option<i64>,
    pub length: Option<i64>,
    pub selectionStart: Option<i64>,
    pub selectionLength: Option<i64>,
}

#[derive(Debug, Default, Clone, Serialize, Deserialize)]
#[serde(rename_all(serialize = "camelCase", deserialize = "camelCase"))]
pub struct Checksum {
    pub algorithm: ChecksumAlgorithm,
    pub checksum: String,
}

#[derive(Debug, Default, Clone, Serialize, Deserialize)]
#[serde(rename_all(serialize = "camelCase", deserialize = "camelCase"))]
pub struct ValueFormat {
    pub hex: Option<bool>,
}

#[derive(Debug, Default, Clone, Serialize, Deserialize)]
#[serde(rename_all(serialize = "camelCase", deserialize = "camelCase"))]
pub struct StackFrameFormat {
    pub parameters: Option<bool>,
    pub parameterTypes: Option<bool>,
    pub parameterNames: Option<bool>,
    pub parameterValues: Option<bool>,
    pub line: Option<bool>,
    pub module: Option<bool>,
    pub includeAll: Option<bool>,
}

#[derive(Debug, Default, Clone, Serialize, Deserialize)]
#[serde(rename_all(serialize = "camelCase", deserialize = "camelCase"))]
pub struct ExceptionFilterOptions {
    pub filterId: String,
    pub condition: Option<String>,
    pub mode: Option<String>,
}

#[derive(Debug, Default, Clone, Serialize, Deserialize)]
#[serde(rename_all(serialize = "camelCase", deserialize = "camelCase"))]
pub struct ExceptionOptions {
    pub path: Option<array>,
    pub breakMode: ExceptionBreakMode,
}

#[derive(Debug, Default, Clone, Serialize, Deserialize)]
#[serde(rename_all(serialize = "camelCase", deserialize = "camelCase"))]
pub struct ExceptionPathSegment {
    pub negate: Option<bool>,
    pub names: array,
}

#[derive(Debug, Default, Clone, Serialize, Deserialize)]
#[serde(rename_all(serialize = "camelCase", deserialize = "camelCase"))]
pub struct ExceptionDetails {
    pub message: Option<String>,
    pub typeName: Option<String>,
    pub fullTypeName: Option<String>,
    pub evaluateName: Option<String>,
    pub stackTrace: Option<String>,
    pub innerException: Option<array>,
}

#[derive(Debug, Default, Clone, Serialize, Deserialize)]
#[serde(rename_all(serialize = "camelCase", deserialize = "camelCase"))]
pub struct DisassembledInstruction {
    pub address: String,
    pub instructionBytes: Option<String>,
    pub instruction: String,
    pub symbol: Option<String>,
    pub location: Option<Source>,
    pub line: Option<i64>,
    pub column: Option<i64>,
    pub endLine: Option<i64>,
    pub endColumn: Option<i64>,
    pub presentationHint: Option<String>,
}

#[derive(Debug, Default, Clone, Serialize, Deserialize)]
#[serde(rename_all(serialize = "camelCase", deserialize = "camelCase"))]
pub struct BreakpointMode {
    pub mode: String,
    pub label: String,
    pub description: Option<String>,
    pub appliesTo: array,
}

