use serde::{Deserialize, Serialize};
use serde_repr::{Deserialize_repr, Serialize_repr};

/// Language enum matching db-backend's Lang (repr(u8)).
#[derive(Debug, Default, Copy, Clone, PartialEq, Serialize_repr, Deserialize_repr)]
#[repr(u8)]
pub enum Lang {
    #[default]
    C = 0,
    Cpp,
    Rust,
    Nim,
    Go,
    Pascal,
    Python,
    Ruby,
    RubyDb,
    Javascript,
    Bash,
    Zsh,
    Lua,
    Asm,
    Noir,
    RustWasm,
    CppWasm,
    Small,
    PythonDb,
    Unknown,
}

/// Kinds of I/O or log events (repr(u8), matching codetracer_trace_types).
#[derive(Debug, Default, Copy, Clone, PartialEq, Serialize_repr, Deserialize_repr)]
#[repr(u8)]
pub enum EventLogKind {
    #[default]
    Write,
    WriteFile,
    WriteOther,
    Read,
    ReadFile,
    ReadOther,
    ReadDir,
    OpenDir,
    CloseDir,
    Socket,
    Open,
    Error,
    Trace,
    History,
}

#[derive(Debug, Default, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
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

#[derive(Debug, Default, Copy, Clone, PartialEq, Serialize_repr, Deserialize_repr)]
#[repr(u8)]
pub enum NotificationKind {
    #[default]
    Info,
    Warning,
    Error,
    Success,
}

#[derive(Debug, Default, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
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

#[derive(Debug, Default, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Breakpoint {
    pub id: i64,
    pub enabled: bool,
}
