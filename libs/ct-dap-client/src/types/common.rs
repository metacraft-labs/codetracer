use serde::{Deserialize, Serialize};
use serde_repr::{Deserialize_repr, Serialize_repr};

/// A `repr(u8)` language tag for the test DAP client.
///
/// This is NOT db-backend's `Lang`, despite what this comment used to claim:
/// it has 21 variants against that enum's 40 and diverges from ordinal 6
/// (`Fortran` there, `Python` here).  It is not live-reachable — this crate is
/// a `[dev-dependencies]` entry used only by `src/db-backend/tests/*`, and the
/// only value any of them constructs is `Lang::C`, which is 0 on both sides.
/// Left as-is rather than widened: the tests do not exercise any other value,
/// and a second 40-variant copy would be one more thing to keep in step.
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
    PythonDb,
    Unknown,
    Elixir,
    Erlang,
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
