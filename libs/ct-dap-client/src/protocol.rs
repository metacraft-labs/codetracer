use serde::{Deserialize, Serialize};
use serde_json::Value;

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
    pub arguments: Value,
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

pub fn from_json(s: &str) -> Result<DapMessage, serde_json::Error> {
    let value: Value = serde_json::from_str(s)?;
    match value.get("type").and_then(|v| v.as_str()) {
        Some("request") => Ok(DapMessage::Request(serde_json::from_value(value)?)),
        Some("response") => Ok(DapMessage::Response(serde_json::from_value(value)?)),
        Some("event") => Ok(DapMessage::Event(serde_json::from_value(value)?)),
        _ => Err(serde::de::Error::custom("Unknown DAP message type")),
    }
}

pub fn to_json(message: &DapMessage) -> Result<String, serde_json::Error> {
    serde_json::to_string(message)
}
