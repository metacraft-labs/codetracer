use serde::{de::Error as SerdeError, Deserialize, Serialize};
use serde_json::Value;
use std::io::{BufRead, Write};
use std::path::PathBuf;

#[derive(Serialize, Deserialize, Debug, PartialEq)]
pub struct ProtocolMessage {
    pub seq: i64,
    #[serde(rename = "type")]
    pub type_: String,
}

#[derive(Serialize, Deserialize, Debug, PartialEq)]
pub struct Request {
    #[serde(flatten)]
    pub base: ProtocolMessage,
    pub command: String,
    #[serde(default)]
    pub arguments: RequestArguments,
}

#[derive(Serialize, Deserialize, Debug, PartialEq)]
// #[serde(deny_unknown_fields)]
pub struct LaunchRequestArguments {
    #[serde(skip_serializing_if = "Option::is_none")]
    pub program: Option<String>,
    #[serde(rename = "traceFolder", skip_serializing_if = "Option::is_none")]
    pub trace_folder: Option<PathBuf>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub trace_file: Option<PathBuf>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub pid: Option<u64>,
    #[serde(rename = "noDebug", skip_serializing_if = "Option::is_none")]
    pub no_debug: Option<bool>,
    #[serde(rename = "__restart", skip_serializing_if = "Option::is_none")]
    pub restart: Option<Value>,
}

#[derive(Serialize, Deserialize, Debug, PartialEq, Clone)]
#[serde(deny_unknown_fields)]
pub struct Source {
    #[serde(skip_serializing_if = "Option::is_none")]
    pub name: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub path: Option<String>,
    #[serde(rename = "sourceReference", skip_serializing_if = "Option::is_none")]
    pub source_reference: Option<i64>,
}

#[derive(Serialize, Deserialize, Debug, PartialEq)]
#[serde(deny_unknown_fields)]
pub struct SourceBreakpoint {
    pub line: i64,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub column: Option<i64>,
}

#[derive(Serialize, Deserialize, Debug, PartialEq)]
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

#[derive(Serialize, Deserialize, Debug, PartialEq)]
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

#[derive(Serialize, Deserialize, Debug, PartialEq)]
pub struct SetBreakpointsResponseBody {
    pub breakpoints: Vec<Breakpoint>,
}

#[derive(Serialize, Deserialize, Debug, PartialEq, Default)]
#[serde(deny_unknown_fields)]
pub struct Capabilities {
    #[serde(
        rename = "supportsLoadedSourcesRequest",
        skip_serializing_if = "Option::is_none"
    )]
    pub supports_loaded_sources_request: Option<bool>,
    #[serde(rename = "supportsStepBack", skip_serializing_if = "Option::is_none")]
    pub supports_step_back: Option<bool>,
    #[serde(
        rename = "supportsConfigurationDoneRequest",
        skip_serializing_if = "Option::is_none"
    )]
    pub supports_configuration_done_request: Option<bool>,
    #[serde(
        rename = "supportsDisassembleRequest",
        skip_serializing_if = "Option::is_none"
    )]
    pub supports_disassemble_request: Option<bool>,
    #[serde(rename = "supportsLogPoints", skip_serializing_if = "Option::is_none")]
    pub supports_log_points: Option<bool>,
    #[serde(
        rename = "supportsRestartRequest",
        skip_serializing_if = "Option::is_none"
    )]
    pub supports_restart_request: Option<bool>,
}

#[derive(Serialize, Deserialize, Debug, PartialEq)]
#[serde(untagged)]
pub enum RequestArguments {
    Launch(LaunchRequestArguments),
    SetBreakpoints(SetBreakpointsArguments),
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
#[serde(untagged)]
pub enum DapMessage {
    Request(Request),
    Response(Response),
    Event(Event),
}

pub struct DapClient {
    seq: i64,
}

impl Default for DapClient {
    fn default() -> Self {
        DapClient { seq: 1 }
    }
}

impl DapClient {
    pub fn request(&mut self, command: &str, arguments: RequestArguments) -> DapMessage {
        let message = DapMessage::Request(Request {
            base: ProtocolMessage {
                seq: self.seq,
                type_: "request".to_string(),
            },
            command: command.to_string(),
            arguments,
        });
        self.seq += 1;
        message
    }

    pub fn launch(&mut self, args: LaunchRequestArguments) -> DapMessage {
        self.request("launch", RequestArguments::Launch(args))
    }

    pub fn set_breakpoints(&mut self, args: SetBreakpointsArguments) -> DapMessage {
        self.request("setBreakpoints", RequestArguments::SetBreakpoints(args))
    }
}

pub fn from_json(s: &str) -> Result<DapMessage, serde_json::Error> {
    let value: Value = serde_json::from_str(s)?;
    match value.get("type").and_then(|v| v.as_str()) {
        Some("request") => Ok(DapMessage::Request(serde_json::from_value(value)?)),
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
        println!("no content-length!");
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
    Ok(())
}
