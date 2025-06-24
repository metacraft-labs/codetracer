use log::info;
use serde::{de::Error as SerdeError, Deserialize, Serialize};
use serde_json::Value;
use std::io::{BufRead, Write};
use std::path::PathBuf;

#[derive(Serialize, Deserialize, Default, Debug, PartialEq, Clone)]
pub struct ProtocolMessage {
    pub seq: i64,
    #[serde(rename = "type")]
    pub type_: String,
}

#[derive(Serialize, Deserialize, Default, Debug, PartialEq, Clone)]
pub struct Request {
    #[serde(flatten)]
    pub base: ProtocolMessage,
    pub command: String,
    #[serde(default)]
    pub arguments: RequestArguments,
}

#[derive(Serialize, Deserialize, Debug, PartialEq, Clone)]
#[serde(deny_unknown_fields)]
pub struct LaunchRequestArguments {
    #[serde(skip_serializing_if = "Option::is_none")]
    pub program: Option<String>,
    #[serde(rename = "traceFolder", skip_serializing_if = "Option::is_none")]
    pub trace_folder: Option<PathBuf>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub trace_file: Option<PathBuf>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub pid: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub cwd: Option<String>,
    #[serde(rename = "noDebug", skip_serializing_if = "Option::is_none")]
    pub no_debug: Option<bool>,
    #[serde(rename = "__restart", skip_serializing_if = "Option::is_none")]
    pub restart: Option<Value>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub name: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub request: Option<String>,
    #[serde(rename = "type", skip_serializing_if = "Option::is_none")]
    pub typ: Option<String>,
    #[serde(rename = "__sessionId", skip_serializing_if = "Option::is_none")]
    pub session_id: Option<String>,
}

#[derive(Serialize, Deserialize, Debug, PartialEq, Clone)]
#[serde(deny_unknown_fields)]
pub struct Source {
    #[serde(skip_serializing_if = "Option::is_none")]
    pub name: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub path: Option<String>,
    #[serde(rename = "sourceReference")] // skip_serializing_if = "Option::is_none")]
    pub source_reference: Option<i64>,
}

#[derive(Serialize, Deserialize, Debug, PartialEq, Clone)]
#[serde(deny_unknown_fields)]
pub struct Thread {
    pub id: i64,
    pub name: String,
}

#[derive(Serialize, Deserialize, Debug, PartialEq, Clone)]
#[serde(deny_unknown_fields)]
pub struct SourceBreakpoint {
    pub line: i64,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub column: Option<i64>,
}

#[derive(Serialize, Deserialize, Debug, PartialEq, Clone)]
#[serde(deny_unknown_fields)]
pub struct SetBreakpointsArguments {
    pub source: Source,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub breakpoints: Option<Vec<SourceBreakpoint>>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub lines: Option<Vec<i64>>,
    #[serde(rename = "sourceModified", skip_serializing_if = "Option::is_none")]
    pub source_modified: Option<bool>,
}

#[derive(Serialize, Deserialize, Debug, PartialEq, Clone)]
#[serde(deny_unknown_fields)]
pub struct Breakpoint {
    #[serde(skip_serializing_if = "Option::is_none")]
    pub id: Option<i64>,
    pub verified: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub message: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub source: Option<Source>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub line: Option<i64>,
}

#[derive(Serialize, Deserialize, Debug, PartialEq, Clone)]
pub struct SetBreakpointsResponseBody {
    pub breakpoints: Vec<Breakpoint>,
}

#[derive(Serialize, Deserialize, Debug, PartialEq, Default, Clone)]
#[serde(deny_unknown_fields)]
pub struct Capabilities {
    #[serde(rename = "supportsLoadedSourcesRequest", skip_serializing_if = "Option::is_none")]
    pub supports_loaded_sources_request: Option<bool>,
    #[serde(rename = "supportsStepBack", skip_serializing_if = "Option::is_none")]
    pub supports_step_back: Option<bool>,
    #[serde(rename = "supportsConfigurationDoneRequest", skip_serializing_if = "Option::is_none")]
    pub supports_configuration_done_request: Option<bool>,
    #[serde(rename = "supportsDisassembleRequest", skip_serializing_if = "Option::is_none")]
    pub supports_disassemble_request: Option<bool>,
    #[serde(rename = "supportsLogPoints", skip_serializing_if = "Option::is_none")]
    pub supports_log_points: Option<bool>,
    #[serde(rename = "supportsRestartRequest", skip_serializing_if = "Option::is_none")]
    pub supports_restart_request: Option<bool>,
}

#[derive(Serialize, Deserialize, Debug, PartialEq, Default, Clone)]
pub struct ThreadsResponseBody {
    pub threads: Vec<Thread>,
}

#[derive(Serialize, Deserialize, Debug, PartialEq, Default, Clone)]
// #[serde(deny_unknown_fields)]
pub struct StackTraceArguments {
    #[serde(rename = "threadId")]
    pub thread_id: i64,
}

#[derive(Serialize, Deserialize, Debug, PartialEq, Default, Clone)]
#[serde(rename_all = "camelCase")]
pub struct StackFrame {
    pub id: i64,
    pub name: String,
    pub source: Option<Source>,
    pub line: usize,
    pub column: usize,
    pub end_line: Option<usize>,
    pub end_column: Option<usize>,
    pub instruction_pointer_reference: Option<String>,
    pub module_id: Option<Value>, // number | string;
    pub presentation_hint: Option<String>,
}

#[derive(Serialize, Deserialize, Debug, PartialEq, Default, Clone)]
#[serde(rename_all = "camelCase")]
pub struct StackTraceResponseBody {
    pub stack_frames: Vec<StackFrame>,
    pub total_frames: usize,
}

#[derive(Serialize, Deserialize, Debug, PartialEq, Default, Clone)]
#[serde(rename_all = "camelCase")]
pub struct ScopeArguments {
    pub frame_id: i64,
}

#[derive(Serialize, Deserialize, Debug, PartialEq, Default, Clone)]
#[serde(rename_all = "camelCase")]
pub struct Scope {
    pub name: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub presentation_hint: Option<String>,
    pub variables_reference: i64,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub named_variables: Option<i64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub indexed_variables: Option<i64>,
    pub expensive: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub source: Option<Source>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub line: Option<usize>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub column: Option<usize>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub end_line: Option<usize>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub end_column: Option<usize>,
}

#[derive(Serialize, Deserialize, Debug, PartialEq, Default, Clone)]
#[serde(rename_all = "camelCase")]
pub struct ScopeResponseBody {
    pub scopes: Vec<Scope>,
}

#[derive(Serialize, Deserialize, Debug, PartialEq, Default, Clone)]
#[serde(rename_all = "camelCase")]
pub struct VariablesArguments {
    pub variables_reference: i64,

    // 'indexed' or 'named' or null(None)
    #[serde(skip_serializing_if = "Option::is_none")]
    pub filter: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    start: Option<usize>,
    #[serde(skip_serializing_if = "Option::is_none")]
    count: Option<usize>,
    // TODO: eventually add ValueFormat if we need,
    // but for now we don't set
    // `supportsValueFormattingOptions` capability
    #[serde(skip_serializing_if = "Option::is_none")]
    format: Option<Value>,
}

#[derive(Serialize, Deserialize, Debug, PartialEq, Default, Clone)]
#[serde(rename_all = "camelCase")]
pub struct Variable {
    pub name: String,

    pub value: String,

    #[serde(rename = "type", skip_serializing_if = "Option::is_none")]
    pub typ: Option<String>,

    #[serde(skip_serializing_if = "Option::is_none")]
    pub presentation_hint: Option<VariablePresentationHint>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub evaluate_name: Option<String>,

    pub variables_reference: i64,

    #[serde(skip_serializing_if = "Option::is_none")]
    pub named_variables: Option<usize>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub indexed_variables: Option<usize>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub memory_reference: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub declaration_location_reference: Option<i64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub value_location_reference: Option<i64>,
}

#[derive(Serialize, Deserialize, Debug, PartialEq, Default, Clone)]
#[serde(rename_all = "camelCase")]
pub struct VariablePresentationHint {
    #[serde(skip_serializing_if = "Option::is_none")]
    pub kind: Option<String>,

    #[serde(skip_serializing_if = "Option::is_none")]
    pub attributes: Option<String>,

    #[serde(skip_serializing_if = "Option::is_none")]
    pub visibility: Option<String>,

    #[serde(skip_serializing_if = "Option::is_none")]
    pub lazy: Option<bool>,
}

impl Variable {
    pub fn new(name: &str, value: &str, variables_reference: i64) -> Variable {
        Variable {
            name: name.to_string(),
            value: value.to_string(),
            variables_reference,
            typ: None,
            presentation_hint: None,
            evaluate_name: None,
            named_variables: None,
            indexed_variables: None,
            memory_reference: None,
            declaration_location_reference: None,
            value_location_reference: None,
        }
    }
}

#[derive(Serialize, Deserialize, Debug, PartialEq, Default, Clone)]
pub struct VariablesResponseBody {
    pub variables: Vec<Variable>,
}

#[derive(Serialize, Deserialize, Debug, PartialEq, Clone)]
#[serde(untagged)]
pub enum RequestArguments {
    Launch(LaunchRequestArguments),
    SetBreakpoints(SetBreakpointsArguments),
    StackTrace(StackTraceArguments),
    Scope(ScopeArguments),
    Variables(VariablesArguments),
    Other(Value),
}

impl Default for RequestArguments {
    fn default() -> Self {
        RequestArguments::Other(Value::Null)
    }
}

#[derive(Serialize, Deserialize, Debug, PartialEq)]
pub struct Response {
    #[serde(flatten)]
    pub base: ProtocolMessage,
    pub request_seq: i64,
    pub success: bool,
    pub command: String,
    #[serde(default)]
    pub message: Option<String>,
    #[serde(default)]
    pub body: Value,
}

#[derive(Serialize, Deserialize, Debug, PartialEq)]
pub struct InitializeResponse {
    #[serde(flatten)]
    pub base: ProtocolMessage,
    pub request_seq: i64,
    pub success: bool,
    pub command: String,
    #[serde(default)]
    pub message: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub body: Option<Capabilities>,
}

#[derive(Serialize, Deserialize, Debug, PartialEq)]
pub struct Event {
    #[serde(flatten)]
    pub base: ProtocolMessage,
    pub event: String,
    #[serde(default)]
    pub body: Value,
}

#[derive(Serialize, Deserialize, Debug, PartialEq)]
#[serde(deny_unknown_fields)]
pub struct StoppedEventBody {
    pub reason: String,
    #[serde(rename = "threadId")]
    pub thread_id: i64,
    #[serde(rename = "allThreadsStopped")]
    pub all_threads_stopped: bool,
    #[serde(rename = "hitBreakpointIds", skip_serializing_if = "Option::is_none")]
    pub hit_breakpoint_ids: Option<Vec<i64>>,
}

#[derive(Serialize, Deserialize, Debug, PartialEq)]
#[serde(untagged)]
pub enum DapMessage {
    Request(Request),
    Response(Response),
    Event(Event),
}

#[derive(Debug, Clone)]
pub struct DapClient {
    pub seq: i64,
}

impl Default for DapClient {
    fn default() -> Self {
        DapClient { seq: 1 }
    }
}

impl DapClient {
    pub fn request(&mut self, command: &str, arguments: RequestArguments) -> DapMessage {
        DapMessage::Request(Request {
            base: ProtocolMessage {
                seq: self.next_seq(),
                type_: "request".to_string(),
            },
            command: command.to_string(),
            arguments,
        })
    }

    pub fn launch(&mut self, args: LaunchRequestArguments) -> DapMessage {
        self.request("launch", RequestArguments::Launch(args))
    }

    pub fn set_breakpoints(&mut self, args: SetBreakpointsArguments) -> DapMessage {
        self.request("setBreakpoints", RequestArguments::SetBreakpoints(args))
    }

    pub fn stopped(&mut self, reason: &str) -> Result<DapMessage, serde_json::Error> {
        let body = StoppedEventBody {
            reason: reason.to_string(),
            thread_id: 1,
            all_threads_stopped: true,
            hit_breakpoint_ids: Some(vec![]),
        };
        Ok(DapMessage::Event(Event {
            base: ProtocolMessage {
                seq: self.next_seq(),
                type_: "event".to_string(),
            },
            event: "stopped".to_string(),
            body: serde_json::to_value(body)?,
        }))
    }

    fn next_seq(&mut self) -> i64 {
        let current = self.seq;
        self.seq += 1;
        current
    }

    pub fn with_seq(seq: i64) -> DapClient {
        DapClient { seq }
    }
}

pub fn from_json(s: &str) -> Result<DapMessage, serde_json::Error> {
    let value: Value = serde_json::from_str(s)?;
    match value.get("type").and_then(|v| v.as_str()) {
        Some("request") => {
            // if value.get("kind").and_then(|v| v.as_str()) == Some("launch") {
            // Ok(DapMessage::Request(dap::Request::Launch(serde_json::from_value::<LaunchRequestArguments>(
            // value,
            // )?))
            // } else {
            Ok(DapMessage::Request(serde_json::from_value(value)?))
            // }
        }
        Some("response") => Ok(DapMessage::Response(serde_json::from_value(value)?)),
        Some("event") => Ok(DapMessage::Event(serde_json::from_value(value)?)),
        _ => Err(serde_json::Error::custom("Unknown DAP message type")),
    }
}

pub fn to_json(message: &DapMessage) -> Result<String, serde_json::Error> {
    serde_json::to_string(message)
}

pub fn from_reader<R: BufRead>(reader: &mut R) -> Result<DapMessage, serde_json::Error> {
    let mut header = String::new();
    reader
        .read_line(&mut header)
        .map_err(|e| serde_json::Error::custom(e.to_string()))?;
    if !header.to_ascii_lowercase().starts_with("content-length:") {
        // println!("no content-length!");
        return Err(serde_json::Error::custom("Missing Content-Length header"));
    }
    let len_part = header
        .split(':')
        .nth(1)
        .ok_or_else(|| serde_json::Error::custom("Invalid Content-Length"))?;
    let len: usize = len_part
        .trim()
        .parse::<usize>()
        .map_err(|e| serde_json::Error::custom(e.to_string()))?;
    let mut blank = String::new();
    reader
        .read_line(&mut blank)
        .map_err(|e| serde_json::Error::custom(e.to_string()))?; // consume blank line
    let mut buf = vec![0u8; len];
    reader
        .read_exact(&mut buf)
        .map_err(|e| serde_json::Error::custom(e.to_string()))?;
    let json_text = std::str::from_utf8(&buf).map_err(|e| serde_json::Error::custom(e.to_string()))?;
    info!("DAP raw <- {json_text}");
    from_json(json_text)
}

pub fn write_message<W: Write>(writer: &mut W, message: &DapMessage) -> Result<(), serde_json::Error> {
    let json = to_json(message)?;
    let header = format!("Content-Length: {}\r\n\r\n", json.len());
    writer
        .write_all(header.as_bytes())
        .map_err(|e| serde_json::Error::custom(e.to_string()))?;
    writer
        .write_all(json.as_bytes())
        .map_err(|e| serde_json::Error::custom(e.to_string()))?;
    writer.flush().map_err(|e| serde_json::Error::custom(e.to_string()))?;
    info!("DAP -> {:?}", message);
    Ok(())
}
