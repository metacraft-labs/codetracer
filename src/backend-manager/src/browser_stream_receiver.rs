//! M26 — browser-recorder JSON stream receiver.
//!
//! Canonical spec:
//! [`codetracer-specs/GUI/Debugging-Features/Value-Origin-Tracking.md`]
//! §14.4 (browser-side JavaScript recorder).  Milestone:
//! [`codetracer-specs/Planned-Features/Value-Origin-Tracking.milestones.org`]
//! M26.
//!
//! # What this module owns
//!
//! - The JSON event vocabulary the browser runtime ships over WebSocket.
//!   The variants mirror `TraceLowLevelEvent`
//!   (`Step`, `Call`, `Return`, `Assignment`, `Value`, …) as documented
//!   in [`codetracer-specs/Trace-Files/Trace-Event-Types.md`].
//! - The line-by-line JSON parser ([`parse_event_line`]).
//! - The CTFS writer wiring ([`CtfsWriter`] trait + [`StreamReceiver`]).
//!
//! The receiver is intentionally split from the daemon binary so it can
//! be hosted either inside `codetracer-ci` (the canonical streaming
//! daemon for Android / iOS) or under a sibling `backend-manager` binary.
//! M26 ships the receiver entry point + parser + writer wiring; the
//! host-process choice is a follow-on (see milestone note 2026-06).
//!
//! # What this module does NOT own
//!
//! - The CTFS split-binary container itself — written by the existing
//!   trace-format crates.  The receiver consumes the abstract
//!   [`CtfsWriter`] trait so the test suite can pin in-memory captures
//!   without touching disk.
//! - The browser runtime side (`@codetracer/runtime-browser`).  The wire
//!   format is the contract between the two.
//! - The M25 correlation-marker pairing logic, which lives in
//!   [`codetracer::db_backend::correlation_index`]; the receiver
//!   surfaces correlation markers verbatim as
//!   [`BrowserEvent::CorrelationMarker`] for downstream pairing.

#![allow(dead_code)]

use std::io;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};

use serde::{Deserialize, Serialize};

/// Direction tag on a [`BrowserEvent::CorrelationMarker`].  Mirrors
/// [`crate::correlation_markers::MarkerDirection`] in the db-backend; we
/// duplicate the type here so backend-manager does not have to take a
/// hard dependency on the db-backend crate just for the M26 receiver
/// surface.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum MarkerDirection {
    Send,
    Recv,
}

/// One value carried on a `Call.args`, `Return.returnValue`, or
/// `Value.value` field.
///
/// The shape mirrors the `EncodedValue` produced by
/// `@codetracer/runtime-browser`.  We do not try to faithfully reproduce
/// every nested encoding tag — the daemon's job at this layer is to keep
/// the JSON envelope and forward it to the CTFS writer, which performs
/// the canonical re-encoding.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct EncodedValue {
    /// The encoded primitive / compound payload.  Carried as
    /// `serde_json::Value` so we round-trip arbitrary nested shapes.
    pub value: serde_json::Value,
    /// Type tag matching the `TypeKind` enum in the trace-format spec.
    #[serde(rename = "typeKind")]
    pub type_kind: String,
}

/// One JSON event from the browser runtime.  The `kind` discriminator
/// matches the names in `packages/runtime-browser/src/index.ts`.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "kind")]
pub enum BrowserEvent {
    /// Session lifecycle: emitted as the very first line.
    SessionStart {
        program: String,
        #[serde(default)]
        args: Vec<String>,
    },
    /// Trace manifest, shipped right after `SessionStart` when the
    /// recorder has one bundled.
    Manifest { manifest: serde_json::Value },
    /// Source path interning.  M26 V1 does not require the daemon to
    /// emit these (the manifest carries the paths) but the event is
    /// kept in the vocabulary for forwards compatibility.
    Path {
        #[serde(rename = "pathId")]
        path_id: u32,
        path: String,
    },
    /// Execution reached the site with the given id.
    Step {
        #[serde(rename = "siteId")]
        site_id: u32,
    },
    /// Function entry with the given arg values.
    Call { fn_id: u32, args: Vec<EncodedValue> },
    /// Function return.
    Return {
        fn_id: u32,
        #[serde(rename = "returnValue")]
        return_value: EncodedValue,
    },
    /// Synthetic M16a assignment site.
    Assignment {
        #[serde(rename = "siteId")]
        site_id: u32,
    },
    /// Full value snapshot for a named binding.
    Value { name: String, value: EncodedValue },
    /// I/O capture.
    Write { channel: String, content: String },
    /// M25 user-placed correlation marker.  No protocol shim runs in
    /// the browser; the page's own code calls `__ct.markCorrelation(...)`.
    CorrelationMarker {
        direction: MarkerDirection,
        boundary: String,
        key: serde_json::Value,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        payload: Option<serde_json::Value>,
    },
    /// Session lifecycle teardown: emitted on `pagehide` / explicit
    /// `__ct.stop()`.
    SessionEnd {},
}

/// Errors surfaced by [`parse_event_line`].
#[derive(Debug)]
pub enum ParseError {
    /// The line was empty after trimming.  Callers MAY ignore this
    /// rather than treating it as a fatal error — browsers occasionally
    /// emit stray newlines mid-batch.
    EmptyLine,
    /// `serde_json` failed to parse the line.
    Json(serde_json::Error),
}

impl std::fmt::Display for ParseError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::EmptyLine => f.write_str("empty line"),
            Self::Json(e) => write!(f, "json parse error: {e}"),
        }
    }
}

impl std::error::Error for ParseError {}

/// Parse one newline-delimited JSON line into a [`BrowserEvent`].
///
/// Returns [`ParseError::EmptyLine`] for blank lines so callers can
/// distinguish "no event" from "malformed event".
pub fn parse_event_line(line: &str) -> Result<BrowserEvent, ParseError> {
    let trimmed = line.trim();
    if trimmed.is_empty() {
        return Err(ParseError::EmptyLine);
    }
    serde_json::from_str(trimmed).map_err(ParseError::Json)
}

/// Trait abstracting the CTFS writer surface so the receiver can be
/// unit-tested without touching disk.
///
/// In production this is implemented by the CTFS multi-stream container
/// writer (see `codetracer-trace-format-nim` for the canonical
/// implementation).  In tests we use [`InMemoryCtfsWriter`].
pub trait CtfsWriter: Send + Sync {
    /// Called once at session start with the manifest and program info.
    fn session_start(&mut self, program: &str, args: &[String]) -> io::Result<()>;
    /// Called when a `Manifest` event arrives (may be a no-op if the
    /// writer already has its manifest from elsewhere).
    fn manifest(&mut self, manifest: &serde_json::Value) -> io::Result<()>;
    /// Called for every event other than session-lifecycle events.
    fn event(&mut self, event: &BrowserEvent) -> io::Result<()>;
    /// Called once at session end.  After return, the writer MUST have
    /// flushed its output to the destination `.ct` file.
    fn session_end(&mut self) -> io::Result<PathBuf>;
}

/// In-memory `CtfsWriter` used by the M26 verification tests.  Captures
/// the event sequence verbatim so tests can pin the first N events.
#[derive(Debug, Default, Clone)]
pub struct InMemoryCtfsWriter {
    pub program: String,
    pub args: Vec<String>,
    pub manifest: Option<serde_json::Value>,
    pub events: Vec<BrowserEvent>,
    pub session_ended: bool,
}

impl InMemoryCtfsWriter {
    pub fn new() -> Self {
        Self::default()
    }
}

impl CtfsWriter for InMemoryCtfsWriter {
    fn session_start(&mut self, program: &str, args: &[String]) -> io::Result<()> {
        self.program = program.to_string();
        self.args = args.to_vec();
        Ok(())
    }
    fn manifest(&mut self, manifest: &serde_json::Value) -> io::Result<()> {
        self.manifest = Some(manifest.clone());
        Ok(())
    }
    fn event(&mut self, event: &BrowserEvent) -> io::Result<()> {
        self.events.push(event.clone());
        Ok(())
    }
    fn session_end(&mut self) -> io::Result<PathBuf> {
        self.session_ended = true;
        // Tests use the synthetic path "/tmp/in-memory.ct" so the
        // session_end contract returns *something*.
        Ok(PathBuf::from("/tmp/in-memory.ct"))
    }
}

/// Shared handle to a [`CtfsWriter`] — wrapped in `Arc<Mutex<_>>` so
/// multiple receiver tasks (one per WebSocket connection) can hand off
/// events without racing on the writer state.
pub type SharedCtfsWriter = Arc<Mutex<dyn CtfsWriter>>;

/// Build a shared writer from any `CtfsWriter` implementation.
pub fn shared_writer<W: CtfsWriter + 'static>(writer: W) -> SharedCtfsWriter {
    Arc::new(Mutex::new(writer))
}

/// One receiver instance — consumes a stream of newline-delimited JSON
/// lines and forwards them to the CTFS writer.
///
/// The receiver is stateless apart from the writer reference; one
/// instance per connection lets us run many recordings concurrently.
pub struct StreamReceiver {
    writer: SharedCtfsWriter,
    session_started: bool,
}

impl StreamReceiver {
    pub fn new(writer: SharedCtfsWriter) -> Self {
        Self {
            writer,
            session_started: false,
        }
    }

    /// Feed one line (typically read from a WebSocket frame).  Returns
    /// `Ok(true)` when the session has ended and the connection can be
    /// closed.
    pub fn feed_line(&mut self, line: &str) -> Result<bool, ReceiveError> {
        let event = match parse_event_line(line) {
            Ok(e) => e,
            Err(ParseError::EmptyLine) => return Ok(false),
            Err(e) => return Err(ReceiveError::Parse(e)),
        };
        self.feed_event(event)
    }

    /// Apply an already-parsed event to the writer.
    pub fn feed_event(&mut self, event: BrowserEvent) -> Result<bool, ReceiveError> {
        let mut writer = self
            .writer
            .lock()
            .map_err(|_| ReceiveError::WriterLockPoisoned)?;
        match &event {
            BrowserEvent::SessionStart { program, args } => {
                if self.session_started {
                    return Err(ReceiveError::DuplicateSessionStart);
                }
                writer
                    .session_start(program, args)
                    .map_err(ReceiveError::Io)?;
                self.session_started = true;
                Ok(false)
            }
            BrowserEvent::Manifest { manifest } => {
                writer.manifest(manifest).map_err(ReceiveError::Io)?;
                Ok(false)
            }
            BrowserEvent::SessionEnd {} => {
                writer.session_end().map_err(ReceiveError::Io)?;
                Ok(true)
            }
            _ => {
                writer.event(&event).map_err(ReceiveError::Io)?;
                Ok(false)
            }
        }
    }

    /// Convenience: feed an entire buffer of newline-delimited JSON.
    ///
    /// Returns the number of events successfully forwarded to the
    /// writer.  Bails on the first parse / IO error.
    pub fn feed_buffer(&mut self, buffer: &str) -> Result<usize, ReceiveError> {
        let mut count = 0;
        for line in buffer.split('\n') {
            if line.trim().is_empty() {
                continue;
            }
            let ended = self.feed_line(line)?;
            count += 1;
            if ended {
                break;
            }
        }
        Ok(count)
    }
}

/// Errors surfaced by [`StreamReceiver`].
#[derive(Debug)]
pub enum ReceiveError {
    Parse(ParseError),
    Io(io::Error),
    /// Two `SessionStart` events for the same connection.
    DuplicateSessionStart,
    /// The shared writer's mutex was poisoned by a panic in another
    /// task.  Unrecoverable for the current session.
    WriterLockPoisoned,
}

impl std::fmt::Display for ReceiveError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Parse(e) => write!(f, "parse: {e}"),
            Self::Io(e) => write!(f, "io: {e}"),
            Self::DuplicateSessionStart => f.write_str("duplicate SessionStart"),
            Self::WriterLockPoisoned => f.write_str("writer mutex poisoned"),
        }
    }
}

impl std::error::Error for ReceiveError {}

/// Convenience entry point: take a buffer of newline-delimited JSON
/// (e.g. as captured by an integration test harness from a WebSocket
/// session) and write it through the receiver into the given path.
///
/// Returns the path the writer chose to persist the trace at.  In V1
/// the path is determined by the host process (`codetracer-ci` writes
/// under its session directory); the trait surface keeps the receiver
/// agnostic to the directory layout.
pub fn translate_buffer_to_writer(
    buffer: &str,
    writer: SharedCtfsWriter,
) -> Result<usize, ReceiveError> {
    let mut receiver = StreamReceiver::new(writer);
    receiver.feed_buffer(buffer)
}

/// Helper: build the canonical output file path inside `out_dir` for a
/// given program identifier.  The recorded `.ct` file is named after
/// the program so multi-recording sessions land side-by-side.
pub fn default_output_path(out_dir: &Path, program: &str) -> PathBuf {
    // Sanitize the program name — keep alphanumerics, dash, dot, and
    // underscore; replace everything else with `_` so untrusted page
    // titles can't traverse the directory layout.
    let safe: String = program
        .chars()
        .map(|c| {
            if c.is_ascii_alphanumeric() || c == '-' || c == '_' || c == '.' {
                c
            } else {
                '_'
            }
        })
        .collect();
    let trimmed = if safe.is_empty() {
        String::from("browser")
    } else {
        safe
    };
    out_dir.join(format!("{trimmed}.ct"))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_session_start_event() {
        let line = r#"{"kind":"SessionStart","program":"my-app","args":[]}"#;
        let event = parse_event_line(line).expect("valid JSON");
        match event {
            BrowserEvent::SessionStart { program, args } => {
                assert_eq!(program, "my-app");
                assert!(args.is_empty());
            }
            other => panic!("unexpected variant: {other:?}"),
        }
    }

    #[test]
    fn parses_step_event() {
        let line = r#"{"kind":"Step","siteId":7}"#;
        let event = parse_event_line(line).expect("valid JSON");
        match event {
            BrowserEvent::Step { site_id } => assert_eq!(site_id, 7),
            other => panic!("unexpected variant: {other:?}"),
        }
    }

    #[test]
    fn parses_assignment_event() {
        let line = r#"{"kind":"Assignment","siteId":42}"#;
        let event = parse_event_line(line).expect("valid JSON");
        match event {
            BrowserEvent::Assignment { site_id } => assert_eq!(site_id, 42),
            other => panic!("unexpected variant: {other:?}"),
        }
    }

    #[test]
    fn parses_correlation_marker_send() {
        let line = r#"{"kind":"CorrelationMarker","direction":"send","boundary":"outbound","key":"user-42"}"#;
        let event = parse_event_line(line).expect("valid JSON");
        match event {
            BrowserEvent::CorrelationMarker {
                direction,
                boundary,
                key,
                payload,
            } => {
                assert_eq!(direction, MarkerDirection::Send);
                assert_eq!(boundary, "outbound");
                assert_eq!(key, serde_json::json!("user-42"));
                assert!(payload.is_none());
            }
            other => panic!("unexpected variant: {other:?}"),
        }
    }

    #[test]
    fn empty_lines_round_trip_as_no_op() {
        let writer: Arc<Mutex<InMemoryCtfsWriter>> =
            Arc::new(Mutex::new(InMemoryCtfsWriter::new()));
        let dyn_writer: SharedCtfsWriter = writer.clone();
        let mut receiver = StreamReceiver::new(dyn_writer);
        // Empty lines + blank lines should not bump the count.
        let buffer = "\n\n\n";
        let n = receiver.feed_buffer(buffer).expect("ok");
        assert_eq!(n, 0);
    }

    #[test]
    fn full_session_round_trips_to_in_memory_writer() {
        let writer: Arc<Mutex<InMemoryCtfsWriter>> =
            Arc::new(Mutex::new(InMemoryCtfsWriter::new()));
        let dyn_writer: SharedCtfsWriter = writer.clone();
        let mut receiver = StreamReceiver::new(dyn_writer);
        let buffer = concat!(
            r#"{"kind":"SessionStart","program":"frontend","args":[]}"#,
            "\n",
            r#"{"kind":"Manifest","manifest":{"formatVersion":1}}"#,
            "\n",
            r#"{"kind":"Step","siteId":0}"#,
            "\n",
            r#"{"kind":"Step","siteId":1}"#,
            "\n",
            r#"{"kind":"Value","name":"x","value":{"value":42,"typeKind":"Int"}}"#,
            "\n",
            r#"{"kind":"SessionEnd"}"#,
            "\n",
        );
        let n = receiver.feed_buffer(buffer).expect("ok");
        // 6 events (incl. SessionStart + Manifest + 2 Steps + 1 Value + SessionEnd).
        assert_eq!(n, 6);
        let w = writer.lock().expect("lock");
        assert_eq!(w.program, "frontend");
        assert!(w.session_ended);
        // SessionStart + Manifest are not forwarded as "events" in the
        // in-memory writer; only Step / Value land in `events`.
        assert_eq!(w.events.len(), 3);
    }

    #[test]
    fn default_output_path_sanitizes_program_name() {
        let p = default_output_path(Path::new("/tmp"), "../bad/name");
        assert_eq!(p, Path::new("/tmp/.._bad_name.ct"));
    }
}
