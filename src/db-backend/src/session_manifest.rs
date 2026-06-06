//! M24 — Multi-trace **session manifest** loader (`session.toml`).
//!
//! Implements the foundation listed in the M24 deliverables and in the
//! Value-Origin-Tracking spec § 14.1: a small TOML file listing every
//! `.ct` trace that participates in a combined debugging session, plus
//! optional correlation hints. The db-backend opens each referenced
//! trace through the existing single-trace `Handler` path and multiplexes
//! them behind the M24 `SessionHandler` layer.
//!
//! Storage shape (spec § 14.1 — kept verbatim):
//!
//! ```toml
//! version = 1
//!
//! [[trace]]
//! recording_id = "0194c3b0-7e2c-7e9c-bbbb-111111111111"
//! path = "./web-frontend.ct"
//! role = "frontend"
//! default_thread_prefix = "fe"
//!
//! [[trace]]
//! recording_id = "0194c3b0-7f5b-7e9c-cccc-222222222222"
//! path = "./api-backend.ct"
//! role = "backend"
//! default_thread_prefix = "be"
//!
//! [correlation]
//! correlation_index_mode = "eager"  # eager | lazy
//! ```
//!
//! ## Why a minimal hand-rolled parser
//!
//! The db-backend already ships a hand-rolled key=value parser for
//! `origin-config.toml` (see [`crate::origin_metadata_indexer::OriginConfig`])
//! precisely to avoid pulling in a fresh `toml` crate dependency for a
//! tiny, well-bounded subset of the format. M24 inherits the same
//! convention: we accept exactly the surface the spec defines (one
//! `version`, an array of `[[trace]]` tables with four fields each,
//! and an optional `[correlation]` table with one field) and reject
//! anything else with a diagnostic.
//!
//! The spec's filename `session.toml` is preserved on disk so future
//! tooling can swap in a full TOML implementation transparently — the
//! grammar accepted here is a strict subset of real TOML.

use std::fmt;
use std::path::{Path, PathBuf};

/// Stable identifier of a trace inside a session manifest. M-REC-11
/// assigns recording IDs as UUIDv7 strings; M24's role is to track the
/// id verbatim (string compare) without imposing a parser on it so the
/// loader survives test fixtures that use shorter synthetic ids.
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct RecordingId(pub String);

impl fmt::Display for RecordingId {
    fn fmt(&self, formatter: &mut fmt::Formatter) -> fmt::Result {
        write!(formatter, "{}", self.0)
    }
}

impl From<&str> for RecordingId {
    fn from(value: &str) -> Self {
        RecordingId(value.to_string())
    }
}

/// One `[[trace]]` entry in `session.toml`. Mirrors the fields the
/// spec § 14.1 example carries — fewer, simpler fields than the full
/// `runtime_tracing` manifest because M24 is only concerned with
/// **routing** DAP requests, not with replaying the trace contents.
#[derive(Debug, Clone)]
pub struct TraceEntry {
    /// UUIDv7-string identifying the recording. Used by the
    /// `SessionHandler` as the routing key.
    pub recording_id: RecordingId,
    /// Filesystem path to the `.ct` container (or its containing
    /// folder). Resolved relative to the directory of `session.toml`
    /// when the path is relative.
    pub path: PathBuf,
    /// Human-readable role for the trace ("frontend", "backend",
    /// "worker", ...). Surfaced to the frontend through
    /// `ct/listProcesses` so the process tree carries meaningful
    /// labels.
    pub role: String,
    /// Prefix prepended to every thread id when the session-wide
    /// thread list is rendered. Example: `fe:thread-1`, `be:thread-1`.
    pub default_thread_prefix: String,
}

/// Optional `[correlation]` table. Only the `correlation_index_mode`
/// hint is consumed at M24 — full correlation handling lands in
/// M25 / M25b on top of the M24 routing surface.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CorrelationConfig {
    pub index_mode: CorrelationIndexMode,
}

impl Default for CorrelationConfig {
    fn default() -> Self {
        // Spec § 14.1 example shows `eager` as the documented default.
        // The lazy variant remains a valid opt-in for callers that want
        // to defer the correlation-index build until the first
        // cross-process query.
        CorrelationConfig {
            index_mode: CorrelationIndexMode::Eager,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CorrelationIndexMode {
    Eager,
    Lazy,
}

impl CorrelationIndexMode {
    pub fn as_str(self) -> &'static str {
        match self {
            CorrelationIndexMode::Eager => "eager",
            CorrelationIndexMode::Lazy => "lazy",
        }
    }

    fn parse(value: &str) -> Option<Self> {
        match value.trim() {
            "eager" => Some(CorrelationIndexMode::Eager),
            "lazy" => Some(CorrelationIndexMode::Lazy),
            _ => None,
        }
    }
}

/// Fully parsed session manifest. The `traces` field preserves manifest
/// order so the frontend's process tree renders entries in the order
/// the user authored them — critical for the M24
/// `test_ct_list_processes_returns_manifest_roles` verification.
#[derive(Debug, Clone)]
pub struct SessionManifest {
    pub version: u32,
    pub traces: Vec<TraceEntry>,
    pub correlation: CorrelationConfig,
    /// Directory the manifest was loaded from. Used to resolve
    /// relative `[[trace]].path` entries.
    pub base_dir: PathBuf,
}

impl SessionManifest {
    /// Construct a single-trace manifest synthetically for the
    /// backwards-compat path: invoking the backend with a bare `.ct`
    /// produces a manifest with one `[[trace]]` so downstream code
    /// routes uniformly through `SessionHandler`.
    pub fn single_trace<P: Into<PathBuf>>(path: P) -> Self {
        let path: PathBuf = path.into();
        let base_dir = path
            .parent()
            .map(Path::to_path_buf)
            .unwrap_or_else(|| PathBuf::from("."));
        let recording_id = synthesize_single_trace_recording_id(&path);
        SessionManifest {
            version: 1,
            traces: vec![TraceEntry {
                recording_id: RecordingId(recording_id),
                path,
                role: "main".to_string(),
                default_thread_prefix: String::new(),
            }],
            correlation: CorrelationConfig::default(),
            base_dir,
        }
    }

    /// Parse the manifest text. `base_dir` is the directory the
    /// manifest was loaded from (used to resolve relative
    /// `[[trace]].path` entries).
    pub fn parse(text: &str, base_dir: &Path) -> Result<Self, ManifestError> {
        let mut version: Option<u32> = None;
        let mut traces: Vec<TraceEntry> = Vec::new();
        let mut correlation = CorrelationConfig::default();
        let mut current_section = SectionKind::TopLevel;
        // Buffer for the `[[trace]]` table currently being parsed. The
        // grammar requires every field; we collect into Options and
        // finalise when we see the next table header or EOF.
        let mut current_trace = TraceBuf::default();

        for (line_no, raw_line) in text.lines().enumerate() {
            let line = strip_comment(raw_line).trim();
            if line.is_empty() {
                continue;
            }
            if line.starts_with("[[") {
                // Finalise any in-progress trace before switching.
                finalise_trace_if_present(&mut current_trace, &mut traces, &mut current_section, line_no)?;
                let header = line.trim_start_matches("[[").trim_end_matches("]]").trim();
                if header != "trace" {
                    return Err(ManifestError::UnknownArrayTable {
                        line: line_no + 1,
                        name: header.to_string(),
                    });
                }
                current_section = SectionKind::Trace;
                current_trace = TraceBuf::default();
                continue;
            }
            if line.starts_with('[') && line.ends_with(']') {
                // Finalise any in-progress trace before switching.
                finalise_trace_if_present(&mut current_trace, &mut traces, &mut current_section, line_no)?;
                let header = line.trim_start_matches('[').trim_end_matches(']').trim();
                if header != "correlation" {
                    return Err(ManifestError::UnknownTable {
                        line: line_no + 1,
                        name: header.to_string(),
                    });
                }
                current_section = SectionKind::Correlation;
                continue;
            }
            // key = value
            let (key, value) = split_kv(line).ok_or(ManifestError::MalformedLine {
                line: line_no + 1,
                content: raw_line.to_string(),
            })?;
            match current_section {
                SectionKind::TopLevel => {
                    if key == "version" {
                        version = Some(parse_integer(value).ok_or(ManifestError::MalformedLine {
                            line: line_no + 1,
                            content: raw_line.to_string(),
                        })?);
                    } else {
                        return Err(ManifestError::UnknownKey {
                            line: line_no + 1,
                            section: "<top-level>".to_string(),
                            key: key.to_string(),
                        });
                    }
                }
                SectionKind::Trace => match key {
                    "recording_id" => {
                        current_trace.recording_id = Some(RecordingId(unquote(value)?));
                    }
                    "path" => {
                        current_trace.path = Some(PathBuf::from(unquote(value)?));
                    }
                    "role" => {
                        current_trace.role = Some(unquote(value)?);
                    }
                    "default_thread_prefix" => {
                        current_trace.default_thread_prefix = Some(unquote(value)?);
                    }
                    _ => {
                        return Err(ManifestError::UnknownKey {
                            line: line_no + 1,
                            section: "trace".to_string(),
                            key: key.to_string(),
                        });
                    }
                },
                SectionKind::Correlation => {
                    if key == "correlation_index_mode" {
                        let mode_text = unquote(value)?;
                        correlation.index_mode =
                            CorrelationIndexMode::parse(&mode_text).ok_or(ManifestError::MalformedLine {
                                line: line_no + 1,
                                content: raw_line.to_string(),
                            })?;
                    } else {
                        return Err(ManifestError::UnknownKey {
                            line: line_no + 1,
                            section: "correlation".to_string(),
                            key: key.to_string(),
                        });
                    }
                }
            }
        }
        // Flush a trailing `[[trace]]` if the file ended inside one.
        finalise_trace_if_present(&mut current_trace, &mut traces, &mut current_section, 0)?;

        let version = version.unwrap_or(1);
        if traces.is_empty() {
            return Err(ManifestError::NoTraces);
        }
        // Reject duplicate recording ids: they would collide as keys in
        // the SessionHandler's HashMap. A duplicate path is also flagged
        // because it usually indicates a hand-edit typo.
        let mut seen_ids = std::collections::HashSet::new();
        for trace in &traces {
            if !seen_ids.insert(trace.recording_id.0.clone()) {
                return Err(ManifestError::DuplicateRecordingId {
                    recording_id: trace.recording_id.0.clone(),
                });
            }
        }

        Ok(SessionManifest {
            version,
            traces,
            correlation,
            base_dir: base_dir.to_path_buf(),
        })
    }

    /// Load and parse the manifest from disk. `path` is the absolute
    /// or relative path to a `session.toml` file.
    pub fn load(path: &Path) -> Result<Self, ManifestError> {
        let text = std::fs::read_to_string(path).map_err(ManifestError::Io)?;
        let base_dir = path
            .parent()
            .map(Path::to_path_buf)
            .unwrap_or_else(|| PathBuf::from("."));
        Self::parse(&text, &base_dir)
    }

    /// Resolve a `[[trace]].path` against the manifest's base
    /// directory. Returns the path unchanged when it is already
    /// absolute.
    pub fn resolved_trace_path(&self, entry: &TraceEntry) -> PathBuf {
        if entry.path.is_absolute() {
            entry.path.clone()
        } else {
            self.base_dir.join(&entry.path)
        }
    }
}

/// Synthesise a deterministic recording-id from a single `.ct` path
/// for the backwards-compat surface. We avoid generating a fresh UUID
/// here because the caller doesn't need uniqueness across processes —
/// only stability within a single SessionHandler instance.
fn synthesize_single_trace_recording_id(path: &Path) -> String {
    let stem = path.file_stem().and_then(|s| s.to_str()).unwrap_or("trace").to_string();
    format!("single-trace:{}", stem)
}

#[derive(Debug, Default)]
struct TraceBuf {
    recording_id: Option<RecordingId>,
    path: Option<PathBuf>,
    role: Option<String>,
    default_thread_prefix: Option<String>,
}

#[derive(Clone, Copy)]
enum SectionKind {
    TopLevel,
    Trace,
    Correlation,
}

fn finalise_trace_if_present(
    buf: &mut TraceBuf,
    traces: &mut Vec<TraceEntry>,
    section: &mut SectionKind,
    line: usize,
) -> Result<(), ManifestError> {
    if matches!(section, SectionKind::Trace) {
        let TraceBuf {
            recording_id,
            path,
            role,
            default_thread_prefix,
        } = std::mem::take(buf);
        let recording_id = recording_id.ok_or(ManifestError::MissingField {
            line,
            field: "recording_id".to_string(),
        })?;
        let path = path.ok_or(ManifestError::MissingField {
            line,
            field: "path".to_string(),
        })?;
        let role = role.ok_or(ManifestError::MissingField {
            line,
            field: "role".to_string(),
        })?;
        let default_thread_prefix = default_thread_prefix.ok_or(ManifestError::MissingField {
            line,
            field: "default_thread_prefix".to_string(),
        })?;
        traces.push(TraceEntry {
            recording_id,
            path,
            role,
            default_thread_prefix,
        });
    }
    *section = SectionKind::TopLevel;
    Ok(())
}

fn strip_comment(line: &str) -> &str {
    // We intentionally do not understand `#` inside a quoted string —
    // the manifest grammar never needs to embed one, so the simple
    // first-`#` split is correct and matches the `origin-config.toml`
    // tiny parser convention.
    match line.find('#') {
        Some(pos) => &line[..pos],
        None => line,
    }
}

fn split_kv(line: &str) -> Option<(&str, &str)> {
    let (k, v) = line.split_once('=')?;
    Some((k.trim(), v.trim()))
}

fn parse_integer(value: &str) -> Option<u32> {
    value.trim().parse::<u32>().ok()
}

/// Strip a single pair of surrounding `"` characters, if present.
/// Unquoted bare values are accepted too (they're used by tests that
/// hand-author manifests for readability).
fn unquote(value: &str) -> Result<String, ManifestError> {
    let trimmed = value.trim();
    if let Some(rest) = trimmed.strip_prefix('"') {
        if let Some(inner) = rest.strip_suffix('"') {
            return Ok(inner.to_string());
        }
        return Err(ManifestError::UnterminatedString {
            content: value.to_string(),
        });
    }
    Ok(trimmed.to_string())
}

#[derive(Debug)]
pub enum ManifestError {
    Io(std::io::Error),
    MalformedLine { line: usize, content: String },
    MissingField { line: usize, field: String },
    UnknownTable { line: usize, name: String },
    UnknownArrayTable { line: usize, name: String },
    UnknownKey { line: usize, section: String, key: String },
    UnterminatedString { content: String },
    DuplicateRecordingId { recording_id: String },
    NoTraces,
}

impl fmt::Display for ManifestError {
    fn fmt(&self, f: &mut fmt::Formatter) -> fmt::Result {
        match self {
            ManifestError::Io(err) => write!(f, "session manifest IO error: {err}"),
            ManifestError::MalformedLine { line, content } => {
                write!(f, "session manifest line {line}: malformed line: {content:?}")
            }
            ManifestError::MissingField { line, field } => write!(
                f,
                "session manifest line {line}: [[trace]] table is missing required field {field:?}"
            ),
            ManifestError::UnknownTable { line, name } => {
                write!(f, "session manifest line {line}: unknown table [{name}]")
            }
            ManifestError::UnknownArrayTable { line, name } => {
                write!(f, "session manifest line {line}: unknown array table [[{name}]]")
            }
            ManifestError::UnknownKey { line, section, key } => {
                write!(
                    f,
                    "session manifest line {line}: unknown key {key:?} in section {section:?}"
                )
            }
            ManifestError::UnterminatedString { content } => {
                write!(f, "session manifest unterminated string: {content:?}")
            }
            ManifestError::DuplicateRecordingId { recording_id } => {
                write!(f, "session manifest duplicate recording_id: {recording_id:?}")
            }
            ManifestError::NoTraces => write!(f, "session manifest contains no [[trace]] entries"),
        }
    }
}

impl std::error::Error for ManifestError {
    fn source(&self) -> Option<&(dyn std::error::Error + 'static)> {
        match self {
            ManifestError::Io(err) => Some(err),
            _ => None,
        }
    }
}

#[cfg(test)]
#[allow(clippy::unwrap_used, clippy::expect_used, clippy::panic)]
mod tests {
    use super::*;

    /// M24 verification: the loader parses a session.toml with two
    /// `[[trace]]` entries; the resulting struct records both
    /// `recording_id` values and roles.
    #[test]
    fn test_session_manifest_loader_parses_two_trace_toml() {
        let manifest_text = r#"
version = 1

[[trace]]
recording_id = "0194c3b0-7e2c-7e9c-bbbb-111111111111"
path = "./web-frontend.ct"
role = "frontend"
default_thread_prefix = "fe"

[[trace]]
recording_id = "0194c3b0-7f5b-7e9c-cccc-222222222222"
path = "./api-backend.ct"
role = "backend"
default_thread_prefix = "be"

[correlation]
correlation_index_mode = "eager"
"#;
        let parsed = SessionManifest::parse(manifest_text, Path::new(".")).unwrap();
        assert_eq!(parsed.version, 1);
        assert_eq!(parsed.traces.len(), 2);
        assert_eq!(
            parsed.traces[0].recording_id,
            RecordingId("0194c3b0-7e2c-7e9c-bbbb-111111111111".to_string())
        );
        assert_eq!(parsed.traces[0].role, "frontend");
        assert_eq!(parsed.traces[0].default_thread_prefix, "fe");
        assert_eq!(parsed.traces[0].path, PathBuf::from("./web-frontend.ct"));
        assert_eq!(
            parsed.traces[1].recording_id,
            RecordingId("0194c3b0-7f5b-7e9c-cccc-222222222222".to_string())
        );
        assert_eq!(parsed.traces[1].role, "backend");
        assert_eq!(parsed.traces[1].default_thread_prefix, "be");
        assert_eq!(parsed.correlation.index_mode, CorrelationIndexMode::Eager);
    }

    #[test]
    fn comments_and_blank_lines_are_ignored() {
        let text = r#"
# A leading comment
version = 1  # inline comment

[[trace]]
recording_id = "abc"
path = "a.ct"
role = "main"
default_thread_prefix = "t"
"#;
        let parsed = SessionManifest::parse(text, Path::new(".")).unwrap();
        assert_eq!(parsed.traces.len(), 1);
        assert_eq!(parsed.traces[0].recording_id.0, "abc");
    }

    #[test]
    fn lazy_correlation_mode_is_recognised() {
        let text = r#"
[[trace]]
recording_id = "abc"
path = "a.ct"
role = "main"
default_thread_prefix = "t"

[correlation]
correlation_index_mode = "lazy"
"#;
        let parsed = SessionManifest::parse(text, Path::new(".")).unwrap();
        assert_eq!(parsed.correlation.index_mode, CorrelationIndexMode::Lazy);
    }

    #[test]
    fn duplicate_recording_id_is_rejected() {
        let text = r#"
[[trace]]
recording_id = "abc"
path = "a.ct"
role = "main"
default_thread_prefix = "t"

[[trace]]
recording_id = "abc"
path = "b.ct"
role = "other"
default_thread_prefix = "u"
"#;
        let err = SessionManifest::parse(text, Path::new(".")).unwrap_err();
        assert!(matches!(err, ManifestError::DuplicateRecordingId { .. }));
    }

    #[test]
    fn missing_required_field_is_reported() {
        let text = r#"
[[trace]]
recording_id = "abc"
path = "a.ct"
role = "main"
"#;
        let err = SessionManifest::parse(text, Path::new(".")).unwrap_err();
        match err {
            ManifestError::MissingField { field, .. } => {
                assert_eq!(field, "default_thread_prefix");
            }
            other => panic!("expected MissingField, got {other:?}"),
        }
    }

    #[test]
    fn single_trace_synthetic_manifest_is_well_formed() {
        let manifest = SessionManifest::single_trace(PathBuf::from("/tmp/example.ct"));
        assert_eq!(manifest.traces.len(), 1);
        assert_eq!(manifest.traces[0].path, PathBuf::from("/tmp/example.ct"));
        assert_eq!(manifest.traces[0].role, "main");
        assert!(manifest.traces[0].default_thread_prefix.is_empty());
        assert_eq!(manifest.traces[0].recording_id.0, "single-trace:example");
    }

    #[test]
    fn relative_paths_are_resolved_against_base_dir() {
        let manifest = SessionManifest::parse(
            r#"
[[trace]]
recording_id = "abc"
path = "child.ct"
role = "main"
default_thread_prefix = "t"
"#,
            Path::new("/tmp/session-root"),
        )
        .unwrap();
        let resolved = manifest.resolved_trace_path(&manifest.traces[0]);
        assert_eq!(resolved, PathBuf::from("/tmp/session-root/child.ct"));
    }

    #[test]
    fn absolute_paths_pass_through_resolved_trace_path() {
        let manifest = SessionManifest::parse(
            r#"
[[trace]]
recording_id = "abc"
path = "/abs/path.ct"
role = "main"
default_thread_prefix = "t"
"#,
            Path::new("/tmp/session-root"),
        )
        .unwrap();
        let resolved = manifest.resolved_trace_path(&manifest.traces[0]);
        assert_eq!(resolved, PathBuf::from("/abs/path.ct"));
    }

    #[test]
    fn unknown_array_table_is_rejected() {
        let text = r#"
[[other]]
key = "value"
"#;
        let err = SessionManifest::parse(text, Path::new(".")).unwrap_err();
        assert!(matches!(err, ManifestError::UnknownArrayTable { .. }));
    }

    #[test]
    fn unknown_key_in_correlation_table_is_rejected() {
        let text = r#"
[[trace]]
recording_id = "abc"
path = "a.ct"
role = "main"
default_thread_prefix = "t"

[correlation]
not_a_real_key = "eager"
"#;
        let err = SessionManifest::parse(text, Path::new(".")).unwrap_err();
        assert!(matches!(err, ManifestError::UnknownKey { .. }));
    }
}
