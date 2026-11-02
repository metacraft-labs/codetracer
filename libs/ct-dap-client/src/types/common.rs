use serde::{Deserialize, Serialize};
use serde_repr::{Deserialize_repr, Serialize_repr};

/// The language tag, re-exported from the canonical definition in
/// `libs/ct-lang`.
///
/// This crate used to hand-write its own 21-variant copy, which diverged from
/// db-backend's list at ordinal 6 (`Fortran` there, `Python` here).  The
/// divergence was never observed because the only value any test constructed
/// was `Lang::C`, which is 0 on both sides — but at the time the ordinal was
/// not private to this crate: `types::tracepoint`'s requests carried it over
/// DAP to db-backend, which read it back with `serde_repr`.  Any other value
/// would have decoded as a different language there.
///
/// Since LRS-1 no request or event of this crate carries the ordinal at all:
/// `ct/load-locals` sends `Lang::wire_name()` and the tracepoint structs have
/// no `lang` field.  `Lang` derives no serde implementation of its own — a
/// field that needs one uses `ct_lang::lang_wire`, by name.
///
/// `ct-lang` is a leaf crate (no build script, no path dependencies), so taking
/// the canonical definition costs this crate nothing.  Depending on db-backend
/// instead was not an option: db-backend has *this* crate as a
/// `[dev-dependencies]` entry, and its build script compiles the Nim MCR
/// emulator.
pub use ct_lang::Lang;

/// Kinds of I/O or log events: `codetracer_trace_types::EventLogKind`, by
/// name and ordinal (`trace-events.md` §"EventLogKind (u8 enum)"). On the
/// wire a kind is its ordinal; an unassigned ordinal (24-255) does not decode.
#[derive(Debug, Default, Copy, Clone, PartialEq, Serialize_repr, Deserialize_repr)]
#[repr(u8)]
pub enum EventLogKind {
    /// Output to stdout, or a write with no more specific kind.
    #[default]
    Write = 0,
    WriteFile = 1,
    /// A write no other kind describes.
    WriteOther = 2,
    /// Input from stdin, or a read with no more specific kind.
    Read = 3,
    ReadFile = 4,
    /// A read no other kind describes.
    ReadOther = 5,
    ReadDir = 6,
    OpenDir = 7,
    CloseDir = 8,
    Socket = 9,
    Open = 10,
    Error = 11,
    TraceLogEvent = 12,
    EvmEvent = 13,
    /// Output to stderr.
    WriteStderr = 14,
    /// Running a program or spawning a process.
    Exec = 15,
    /// Reading an environment variable, or testing whether one is set.
    ReadEnv = 16,
    /// Setting or removing an environment variable.
    WriteEnv = 17,
    /// An existence or metadata query of a filesystem entry, or a PATH search.
    Stat = 18,
    /// Creating a directory, including copying a directory tree.
    CreateDir = 19,
    RemoveDir = 20,
    RemoveFile = 21,
    /// Renaming or moving a file or directory.
    Rename = 22,
    /// Changing the working directory.
    ChangeDir = 23,
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

#[cfg(test)]
#[allow(clippy::unwrap_used)]
mod tests {
    use super::EventLogKind;

    /// The `EventLogKind` table of `trace-events.md` §"EventLogKind (u8
    /// enum)", by ordinal, spelled out so that a reordering of the enum fails
    /// here instead of relabelling every event the client decodes.
    const SPEC_KINDS: [(u8, EventLogKind); 24] = [
        (0, EventLogKind::Write),
        (1, EventLogKind::WriteFile),
        (2, EventLogKind::WriteOther),
        (3, EventLogKind::Read),
        (4, EventLogKind::ReadFile),
        (5, EventLogKind::ReadOther),
        (6, EventLogKind::ReadDir),
        (7, EventLogKind::OpenDir),
        (8, EventLogKind::CloseDir),
        (9, EventLogKind::Socket),
        (10, EventLogKind::Open),
        (11, EventLogKind::Error),
        (12, EventLogKind::TraceLogEvent),
        (13, EventLogKind::EvmEvent),
        (14, EventLogKind::WriteStderr),
        (15, EventLogKind::Exec),
        (16, EventLogKind::ReadEnv),
        (17, EventLogKind::WriteEnv),
        (18, EventLogKind::Stat),
        (19, EventLogKind::CreateDir),
        (20, EventLogKind::RemoveDir),
        (21, EventLogKind::RemoveFile),
        (22, EventLogKind::Rename),
        (23, EventLogKind::ChangeDir),
    ];

    #[test]
    fn every_kind_decodes_from_and_encodes_to_its_ordinal() {
        for (ordinal, kind) in SPEC_KINDS {
            let decoded: EventLogKind = serde_json::from_str(&ordinal.to_string()).unwrap();
            assert_eq!(decoded, kind, "ordinal {ordinal}");
            assert_eq!(serde_json::to_string(&kind).unwrap(), ordinal.to_string());
        }
    }

    #[test]
    fn an_unassigned_kind_does_not_decode() {
        for ordinal in [24u16, 99, 255] {
            let err = serde_json::from_str::<EventLogKind>(&ordinal.to_string())
                .expect_err("an unassigned kind must not decode");
            assert!(err.to_string().contains(&ordinal.to_string()), "{err}");
        }
    }
}
