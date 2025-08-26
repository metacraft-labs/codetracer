use crate::dap_types;
use crate::task::{self};
use log::{error, info};
use serde::{de::DeserializeOwned, de::Error as SerdeError, Deserialize, Serialize};
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
    pub arguments: Value, //RequestArguments,
}

// using this custom definition, not autogenerating one, because we have custom fields for
// ct launch request (and to handle manually the rename = "__restart" case)
#[derive(Serialize, Deserialize, Debug, PartialEq, Clone)]
#[serde(deny_unknown_fields)]
pub struct LaunchRequestArguments {
    #[serde(skip_serializing_if = "Option::is_none")]
    pub program: Option<String>,
    #[serde(rename = "traceFolder", skip_serializing_if = "Option::is_none")]
    pub trace_folder: Option<PathBuf>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub trace_file: Option<PathBuf>,
    #[serde(rename = "rawDiffIndex", skip_serializing_if = "Option::is_none")]
    pub raw_diff_index: Option<String>,
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

// TODO: for now easier to initialize those, but when we start processing client capabilities or in
// other case, use dap_types::Capabilities
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

pub fn new_dap_variable(name: &str, value: &str, variables_reference: i64) -> dap_types::Variable {
    dap_types::Variable {
        name: name.to_string(),
        value: value.to_string(),
        variables_reference,
        r#type: None,
        presentation_hint: None,
        evaluate_name: None,
        named_variables: None,
        indexed_variables: None,
        memory_reference: None,
        declaration_location_reference: None,
        value_location_reference: None,
    }
}

#[derive(Serialize, Deserialize, Debug, PartialEq, Default, Clone)]
pub struct DisconnectResponseBody {}

impl Request {
    pub fn load_args<T: DeserializeOwned>(&self) -> Result<T, Box<dyn std::error::Error>> {
        Ok(serde_json::from_value::<T>(self.arguments.clone())?)
    }
}

#[derive(Serialize, Deserialize, Clone, Debug, PartialEq)]
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

#[derive(Serialize, Deserialize, Clone, Debug, PartialEq)]
pub struct Event {
    #[serde(flatten)]
    pub base: ProtocolMessage,
    pub event: String,
    #[serde(default)]
    pub body: Value,
}

#[derive(Serialize, Deserialize, Clone, Debug, PartialEq)]
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
    pub fn request(&mut self, command: &str, arguments: Value) -> DapMessage {
        DapMessage::Request(Request {
            base: ProtocolMessage {
                seq: self.next_seq(),
                type_: "request".to_string(),
            },
            command: command.to_string(),
            arguments,
        })
    }

    pub fn launch(&mut self, args: LaunchRequestArguments) -> Result<DapMessage, Box<dyn std::error::Error>> {
        Ok(self.request("launch", serde_json::to_value(args)?))
    }

    pub fn set_breakpoints(
        &mut self,
        args: dap_types::SetBreakpointsArguments,
    ) -> Result<DapMessage, Box<dyn std::error::Error>> {
        Ok(self.request("setBreakpoints", serde_json::to_value(args)?))
    }

    pub fn updated_trace_event(&mut self, args: task::TraceUpdate) -> Result<DapMessage, Box<dyn std::error::Error>> {
        Ok(DapMessage::Event(Event {
            base: ProtocolMessage {
                seq: self.next_seq(),
                type_: "event".to_string(),
            },
            event: "ct/updated-trace".to_string(),
            body: serde_json::to_value(args)?,
        }))
    }

    pub fn stopped_event(&mut self, reason: &str) -> Result<DapMessage, serde_json::Error> {
        let body = dap_types::StoppedEventBody {
            reason: reason.to_string(),
            thread_id: Some(1),
            all_threads_stopped: Some(true),
            hit_breakpoint_ids: Some(vec![]),
            description: None,
            preserve_focus_hint: None,
            text: None,
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

    pub fn updated_flow_event(&mut self, flow_update: task::FlowUpdate) -> Result<DapMessage, serde_json::Error> {
        Ok(DapMessage::Event(Event {
            base: ProtocolMessage {
                seq: self.next_seq(),
                type_: "event".to_string(),
            },
            event: "ct/updated-flow".to_string(),
            body: serde_json::to_value(flow_update)?,
        }))
    }

    pub fn updated_history_event(
        &mut self,
        history_update: task::HistoryUpdate,
    ) -> Result<DapMessage, serde_json::Error> {
        Ok(DapMessage::Event(Event {
            base: ProtocolMessage {
                seq: self.next_seq(),
                type_: "event".to_string(),
            },
            event: "ct/updated-history".to_string(),
            body: serde_json::to_value(history_update)?,
        }))
    }

    pub fn calltrace_search_event(&mut self, search_res: Vec<task::Call>) -> Result<DapMessage, serde_json::Error> {
        Ok(DapMessage::Event(Event {
            base: ProtocolMessage {
                seq: self.next_seq(),
                type_: "event".to_string(),
            },
            event: "ct/calltrace-search-res".to_string(),
            body: serde_json::to_value(search_res)?,
        }))
    }

    pub fn updated_events(&mut self, first_events: Vec<task::ProgramEvent>) -> Result<DapMessage, serde_json::Error> {
        Ok(DapMessage::Event(Event {
            base: ProtocolMessage {
                seq: self.next_seq(),
                type_: "event".to_string(),
            },
            event: "ct/updated-events".to_string(),
            body: serde_json::to_value(first_events)?,
        }))
    }

    pub fn updated_events_content(&mut self, contents: String) -> Result<DapMessage, serde_json::Error> {
        Ok(DapMessage::Event(Event {
            base: ProtocolMessage {
                seq: self.next_seq(),
                type_: "event".to_string(),
            },
            event: "ct/updated-events-content".to_string(),
            body: serde_json::to_value(contents)?,
        }))
    }

    pub fn updated_calltrace_event(
        &mut self,
        update: &task::CallArgsUpdateResults,
    ) -> Result<DapMessage, serde_json::Error> {
        Ok(DapMessage::Event(Event {
            base: ProtocolMessage {
                seq: self.next_seq(),
                type_: "event".to_string(),
            },
            event: "ct/updated-calltrace".to_string(),
            body: serde_json::to_value(update)?,
        }))
    }

    pub fn updated_table_event(
        &mut self,
        update: &task::CtUpdatedTableResponseBody,
    ) -> Result<DapMessage, serde_json::Error> {
        Ok(DapMessage::Event(Event {
            base: ProtocolMessage {
                seq: self.next_seq(),
                type_: "event".to_string(),
            },
            event: "ct/updated-table".to_string(),
            body: serde_json::to_value(update)?,
        }))
    }

    pub fn complete_move_event(&mut self, state: &task::MoveState) -> Result<DapMessage, serde_json::Error> {
        Ok(DapMessage::Event(Event {
            base: ProtocolMessage {
                seq: self.next_seq(),
                type_: "event".to_string(),
            },
            event: "ct/complete-move".to_string(),
            body: serde_json::to_value(state)?,
        }))
    }

    pub fn loaded_terminal_event(&mut self, events: Vec<task::ProgramEvent>) -> Result<DapMessage, serde_json::Error> {
        Ok(DapMessage::Event(Event {
            base: ProtocolMessage {
                seq: self.next_seq(),
                type_: "event".to_string(),
            },
            event: "ct/loaded-terminal".to_string(),
            body: serde_json::to_value(events)?,
        }))
    }

    pub fn notification_event(&mut self, notification: task::Notification) -> Result<DapMessage, serde_json::Error> {
        Ok(DapMessage::Event(Event {
            base: ProtocolMessage {
                seq: self.next_seq(),
                type_: "event".to_string(),
            },
            event: "ct/notification".to_string(),
            body: serde_json::to_value(notification)?,
        }))
    }

    pub fn output_event(
        &mut self,
        category: &str,
        path: &str,
        line: usize,
        output: &str,
    ) -> Result<DapMessage, serde_json::Error> {
        let body = dap_types::OutputEventBody {
            category: Some(category.to_string()),
            output: output.to_string(),
            group: None,
            variables_reference: None,
            source: Some(dap_types::Source {
                name: Some("".to_string()),
                path: Some(path.to_string()),
                source_reference: None,
                adapter_data: None,
                checksums: None,
                origin: None,
                presentation_hint: None,
                sources: None,
            }),
            line: Some(line as i64),
            column: Some(1),
            data: None,
            location_reference: None,
        };
        Ok(DapMessage::Event(Event {
            base: ProtocolMessage {
                seq: self.next_seq(),
                type_: "event".to_string(),
            },
            event: "output".to_string(),
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
    info!("from_reader");
    let mut header = String::new();
    reader.read_line(&mut header).map_err(|e| {
        error!("Read Line: {:?}", e);
        serde_json::Error::custom(e.to_string())
    })?;
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
