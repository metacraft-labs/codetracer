use serde::{Deserialize, Serialize};
use serde_repr::{Deserialize_repr, Serialize_repr};

/// The `repr(u8)` language tag, re-exported from the canonical definition in
/// `libs/ct-lang`.
///
/// This crate used to hand-write its own 21-variant copy, which diverged from
/// db-backend's list at ordinal 6 (`Fortran` there, `Python` here).  The
/// divergence was never observed because the only value any test constructs is
/// `Lang::C`, which is 0 on both sides — but the ordinal is not private to this
/// crate: `types::tracepoint`'s requests carry it over DAP to db-backend, which
/// reads it back with `serde_repr`.  Any other value would have decoded as a
/// different language there.
///
/// `ct-lang` is a leaf crate (no build script, no path dependencies), so taking
/// the canonical definition costs this crate nothing.  Depending on db-backend
/// instead was not an option: db-backend has *this* crate as a
/// `[dev-dependencies]` entry, and its build script compiles the Nim MCR
/// emulator.
pub use ct_lang::Lang;

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
