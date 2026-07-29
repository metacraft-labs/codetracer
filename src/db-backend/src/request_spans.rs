//! RS-M2 — `ct/load-request-spans`: request spans, paged and filtered, shaped
//! for the frontend's `RequestRecord`.
//!
//! Spec: `codetracer-specs/Trace-Files/CTFS-Request-Span-Streams.md`
//! §"Reader and Frontend Surface"; milestone RS-M2 in
//! `codetracer-specs/Planned-Features/Request-Panel-Live-Sessions.milestones.org`.
//!
//! This module sits between the raw span decoder
//! ([`crate::ctfs_trace_reader::span_stream`]) and the DAP surface. It answers
//! one question — *what requests does this recording contain?* — from either of
//! two sources, in this order:
//!
//! 1. **The container's span stream** (`spans.dat`, gated by `meta.dat` bit 13).
//!    This is the format going forward: a recording is ONE artifact.
//! 2. **A legacy sidecar JSONL** (`session_manifest.jsonl` from the PHP
//!    recorder, `codetracer_spans.jsonl` from the Ruby/Python middlewares),
//!    read through the compatibility shim below.
//!
//! The stream always wins when present. The shim exists purely so that
//! recordings made *before* the cutover keep opening — it is READ-ONLY and
//! nothing ever writes a sidecar through this module.
//!
//! ## Why the shim cannot produce everything the stream can
//!
//! The sidecar carries HTTP metadata and, for PHP, a `trace_dir` — and nothing
//! else. In particular it has **no step binding**: there is no
//! `(process_ord, thread_id, start_step..end_step)` coordinate in a JSONL line,
//! because the sidecar was written by a recorder that put each request in its
//! own separate trace. So a shim-sourced [`RequestRecord`] has `startGeid == 0`
//! and `responseSize == 0`, and the panel's "jump to handler" affordance has
//! nothing to seek to; it must fall back to opening the child container named by
//! `trace_dir`. That gap is not a shim defect — it is precisely the deficiency
//! the span stream exists to remove, and the tests assert it explicitly rather
//! than papering over it.

use std::path::{Path, PathBuf};

use log::warn;
use serde::{Deserialize, Serialize};
use serde_json::Value;

use crate::ctfs_trace_reader::ctfs_container::CtfsReader;
use crate::ctfs_trace_reader::span_stream::{
    SPAN_TYPE_WEB_REQUEST, SpanRecord, SpanStatus, SpanStreamReader, resolve_spans,
};

/// Legacy sidecar written by the PHP recorder
/// (`codetracer-php-recorder/src/web_bootstrap.php`), one line per request,
/// carrying HTTP metadata plus a `trace_dir` pointing at that request's own
/// trace.
pub const PHP_SESSION_MANIFEST_FILE: &str = "session_manifest.jsonl";
/// Legacy sidecar written by the Ruby Rack middleware and the Python WSGI/ASGI
/// middlewares, one line per request, HTTP metadata only.
pub const RUBY_PYTHON_SPANS_FILE: &str = "codetracer_spans.jsonl";

// ── Well-known metadata keys (spec §"Well-known metadata keys") ─────────

const KEY_HTTP_METHOD: &str = "http.method";
const KEY_HTTP_URL: &str = "http.url";
const KEY_HTTP_STATUS_CODE: &str = "http.status_code";
const KEY_HTTP_DURATION_MS: &str = "http.duration_ms";
const KEY_HTTP_RESPONSE_SIZE: &str = "http.response_size";

// ── Frontend-facing record ──────────────────────────────────────────────

/// One row of the HTTP Request Panel.
///
/// The first seven fields are exactly the frontend's `RequestRecord`
/// (`src/frontend/viewmodel/store/types.nim`), which the spec notes needs no new
/// state for this feature. The remaining fields are strictly additive
/// diagnostics the ViewModel may ignore: they carry the parts of the span model
/// that have no `RequestRecord` column yet (in-flight state, the external
/// binding) and that RS-M3's live panel needs.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct RequestRecord {
    /// The span's `span_id` — 1-based and monotonic within the container, which
    /// is exactly the "sequential number assigned at capture time" the panel's
    /// `#` column renders. It is also the paging cursor.
    pub id: u64,
    /// Request verb (`"GET"`, `"POST"`, …), from `http.method`.
    pub http_method: String,
    /// Request URL, from `http.url`.
    pub url: String,
    /// HTTP response status code, from `http.status_code`. `0` when the request
    /// is still in flight (an open record carries no status yet).
    pub status_code: i64,
    /// Wall-clock milliseconds spent serving the request, from
    /// `http.duration_ms`.
    pub duration_ms: i64,
    /// Response body size in bytes, from the optional `http.response_size`.
    /// `0` when the recorder did not report one.
    pub response_size: i64,
    /// Global Event ID at the handler entry point — the span's `start_step`.
    /// `0` for a span with no binding in this container (an external span, or
    /// any record that came through the legacy JSONL shim).
    pub start_geid: u64,
    /// `true` while the request is in flight: an open record with no completion
    /// yet. The panel renders these greyed.
    pub is_open: bool,
    /// `"unknown"` | `"ok"` | `"error"` — the span's own status byte, which is
    /// not always derivable from `status_code` (an aborted request has neither).
    pub status: String,
    /// Absolute path of the container this request's execution lives in, when
    /// the span carries an external binding AND that container is present on
    /// disk. `None` for an inline span (the normal case — the execution is in
    /// *this* container) and for an external binding whose target is missing.
    pub external_trace_path: Option<String>,
}

/// Status-class buckets the panel filters on, matching `statusBucket` in
/// `src/frontend/viewmodel/viewmodels/request_panel_vm.nim`.
fn status_class_of(code: i64) -> &'static str {
    match code {
        200..=299 => "2xx",
        300..=399 => "3xx",
        400..=499 => "4xx",
        500..=599 => "5xx",
        _ => "",
    }
}

fn status_name(status: SpanStatus) -> &'static str {
    match status {
        SpanStatus::Unknown => "unknown",
        SpanStatus::Ok => "ok",
        SpanStatus::Error => "error",
    }
}

/// Parse a metadata value that the format defines as a decimal string.
///
/// Values are strings on the wire — the spec says so explicitly ("Values are
/// strings, matching the current JSONL contract") — so every numeric column has
/// to come back through a parse. A malformed value yields `0` rather than
/// failing the whole page: a recorder that wrote `"http.status_code": "n/a"`
/// should cost the user one bad cell, not the entire request list. Genuinely
/// malformed *records* are still rejected fail-closed by the decoder upstream.
fn parse_numeric_metadata(span: &SpanRecord, key: &str) -> i64 {
    span.metadata_value(key)
        .and_then(|v| v.trim().parse::<i64>().ok())
        .unwrap_or(0)
}

// ── Filters and paging ──────────────────────────────────────────────────

/// Filters accepted by `ct/load-request-spans`, mirroring the three the
/// `RequestPanelVM` exposes (`filterMethod`, `filterStatus`, `searchText`).
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct RequestSpanFilters {
    /// Exact HTTP method, compared case-insensitively. `None` or `""` matches
    /// every method.
    #[serde(default)]
    pub method: Option<String>,
    /// Status class: `"2xx"` / `"3xx"` / `"4xx"` / `"5xx"`. `None` or `""`
    /// matches every status.
    #[serde(default)]
    pub status_class: Option<String>,
    /// Case-insensitive substring of the URL. `None` or `""` matches every URL.
    #[serde(default)]
    pub url_contains: Option<String>,
}

impl RequestSpanFilters {
    /// Whether `record` survives every configured filter.
    ///
    /// An unset (or empty) filter matches everything, so the three are
    /// independent and compose by AND — the same semantics the ViewModel's
    /// `filteredRequests` memo applies.
    pub fn matches(&self, record: &RequestRecord) -> bool {
        if let Some(method) = self.method.as_deref().filter(|m| !m.is_empty())
            && !record.http_method.eq_ignore_ascii_case(method)
        {
            return false;
        }
        if let Some(class) = self.status_class.as_deref().filter(|c| !c.is_empty())
            && !status_class_of(record.status_code).eq_ignore_ascii_case(class)
        {
            return false;
        }
        if let Some(needle) = self.url_contains.as_deref().filter(|n| !n.is_empty())
            && !record.url.to_lowercase().contains(&needle.to_lowercase())
        {
            return false;
        }
        true
    }
}

/// Arguments of the `ct/load-request-spans` DAP request.
#[derive(Debug, Clone, Default, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct LoadRequestSpansArguments {
    /// Lowest `span_id` to return, inclusive. Omitted means "from the start".
    #[serde(default)]
    pub from_span_id: Option<u64>,
    /// Maximum number of records to return. Omitted or `0` means "no limit".
    #[serde(default)]
    pub limit: Option<usize>,
    /// Optional method / status-class / URL-substring filters.
    #[serde(default)]
    pub filters: Option<RequestSpanFilters>,
}

/// Where a request list came from — surfaced so the frontend (and the tests)
/// can tell a first-class stream from the compatibility shim.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RequestSpanSource {
    /// The container's own `spans.dat` (`meta.dat` bit 13).
    SpanStream,
    /// A legacy `session_manifest.jsonl` / `codetracer_spans.jsonl` sidecar.
    LegacyJsonl,
}

impl RequestSpanSource {
    /// Wire string sent to the frontend.
    pub fn as_str(self) -> &'static str {
        match self {
            RequestSpanSource::SpanStream => "span-stream",
            RequestSpanSource::LegacyJsonl => "legacy-jsonl",
        }
    }
}

/// Response body of `ct/load-request-spans`.
#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct LoadRequestSpansResponse {
    /// The requested page, ascending by `id`.
    pub requests: Vec<RequestRecord>,
    /// How many records match the filters in total, *before* paging. Lets the
    /// panel render "showing N of M" without walking every page.
    pub total: usize,
    /// `fromSpanId` for the next page, or `None` when this page reached the end.
    pub next_span_id: Option<u64>,
    /// `"span-stream"` or `"legacy-jsonl"`.
    pub source: String,
    /// Number of sidecar lines the shim could not parse and skipped. Always `0`
    /// for the stream path, which is fail-closed and never skips anything.
    pub skipped_lines: usize,
}

/// The settled span list for a recording, plus its provenance.
#[derive(Debug, Clone)]
pub struct RequestSpans {
    /// Settled spans (last-record-wins applied), ascending by `span_id`. This
    /// includes NON-request spans (`span_type: "process"`, `"test"`, …) —
    /// filtering to web requests is the caller's decision, and RS-M3's process
    /// selector needs the others.
    pub spans: Vec<SpanRecord>,
    /// Which of the two sources produced `spans`.
    pub source: RequestSpanSource,
    /// Sidecar lines the shim skipped as unparseable (always 0 for the stream).
    pub skipped_lines: usize,
    /// Directory external bindings resolve relative to.
    pub base_dir: PathBuf,
}

impl RequestSpans {
    /// Project the settled spans to the panel's `RequestRecord` shape, keeping
    /// only `span_type: "web-request"` records and preserving `span_id` order.
    pub fn request_records(&self) -> Vec<RequestRecord> {
        self.spans
            .iter()
            .filter(|s| s.span_type == SPAN_TYPE_WEB_REQUEST)
            .map(|s| self.to_request_record(s))
            .collect()
    }

    /// Convert one span into a `RequestRecord`, resolving its external binding.
    pub fn to_request_record(&self, span: &SpanRecord) -> RequestRecord {
        to_request_record(span, &self.base_dir)
    }

    /// Apply the filters, then page — in that order.
    ///
    /// The order is load-bearing: filtering *after* paging would make page `k`
    /// of a filtered query depend on how many non-matching records happened to
    /// precede it, so paging through a filtered list would not reproduce the
    /// full-scan result. Filtering first means a filtered page sequence is
    /// exactly the full-scan filtered list, cut into `limit`-sized pieces —
    /// which is the property `load_request_spans_pagination_and_filters` pins.
    pub fn page(&self, args: &LoadRequestSpansArguments) -> LoadRequestSpansResponse {
        let filters = args.filters.clone().unwrap_or_default();
        let matching: Vec<RequestRecord> = self
            .request_records()
            .into_iter()
            .filter(|r| filters.matches(r))
            .collect();
        let total = matching.len();

        let from = args.from_span_id.unwrap_or(0);
        let limit = args.limit.unwrap_or(0);
        let mut page: Vec<RequestRecord> = Vec::new();
        let mut next_span_id: Option<u64> = None;
        for record in matching.into_iter().filter(|r| r.id >= from) {
            if limit > 0 && page.len() >= limit {
                // The first record we did NOT return is where the next page
                // starts, so a caller that follows the cursor never skips or
                // repeats a row.
                next_span_id = Some(record.id);
                break;
            }
            page.push(record);
        }

        LoadRequestSpansResponse {
            requests: page,
            total,
            next_span_id,
            source: self.source.as_str().to_string(),
            skipped_lines: self.skipped_lines,
        }
    }
}

/// Convert one span into a `RequestRecord`, resolving its external binding
/// relative to `base_dir`.
///
/// Free function rather than a method so the RS-M3 tail
/// ([`RequestSpanTail`]) — which owns a reader and not a [`RequestSpans`] —
/// projects records through EXACTLY the same code path as the RS-M2 one-shot
/// query. A delta row and a full-query row for the same span must be
/// indistinguishable on the wire, otherwise a client that merges the two ends
/// up with two different renderings of one request.
pub fn to_request_record(span: &SpanRecord, base_dir: &Path) -> RequestRecord {
    RequestRecord {
        id: span.span_id,
        http_method: span.metadata_value(KEY_HTTP_METHOD).unwrap_or_default().to_string(),
        url: span.metadata_value(KEY_HTTP_URL).unwrap_or_default().to_string(),
        status_code: parse_numeric_metadata(span, KEY_HTTP_STATUS_CODE),
        duration_ms: parse_numeric_metadata(span, KEY_HTTP_DURATION_MS),
        response_size: parse_numeric_metadata(span, KEY_HTTP_RESPONSE_SIZE),
        start_geid: span.start_step,
        is_open: span.is_open,
        status: status_name(span.status).to_string(),
        external_trace_path: resolve_external_container(span, base_dir).map(|p| p.to_string_lossy().into_owned()),
    }
}

// ── External (child-trace) binding resolution ───────────────────────────

/// Resolve a span's external binding to an **openable container path**.
///
/// `external_path` is documented as "path relative to this container's
/// directory". It may name either the `.ct` file itself or the directory that
/// holds it (the PHP sidecar's `trace_dir` is a directory), so both are probed.
/// Returns `None` when the span is not external or when the target is not
/// actually on disk — a dangling binding must not be reported to the frontend
/// as something it can open.
pub fn resolve_external_container(span: &SpanRecord, base_dir: &Path) -> Option<PathBuf> {
    if !span.is_external || span.external_path.is_empty() {
        return None;
    }
    let candidate = base_dir.join(&span.external_path);
    if candidate.is_file() {
        return Some(candidate);
    }
    if candidate.is_dir() {
        let canonical = candidate.join("trace.ct");
        if canonical.is_file() {
            return Some(canonical);
        }
        // Several recorders name the container after the recording id; accept
        // any single `.ct` inside the directory, matching how the trace-open
        // path probes for a container.
        if let Ok(entries) = std::fs::read_dir(&candidate) {
            for entry in entries.flatten() {
                let path = entry.path();
                if path.extension().and_then(|e| e.to_str()) == Some("ct") && path.is_file() {
                    return Some(path);
                }
            }
        }
    }
    None
}

// ── Source selection ────────────────────────────────────────────────────

/// Find the `.ct` container for a trace path.
///
/// Accepts either the container itself or the directory holding it, mirroring
/// the probes the trace-open path performs.
fn find_ct_container(trace_path: &Path) -> Option<PathBuf> {
    if trace_path.is_file() {
        return Some(trace_path.to_path_buf());
    }
    if !trace_path.is_dir() {
        return None;
    }
    let canonical = trace_path.join("trace.ct");
    if canonical.is_file() {
        return Some(canonical);
    }
    let mut candidates: Vec<PathBuf> = std::fs::read_dir(trace_path)
        .ok()?
        .flatten()
        .map(|e| e.path())
        .filter(|p| p.extension().and_then(|s| s.to_str()) == Some("ct") && p.is_file())
        .collect();
    // Sort so the choice is deterministic when a directory holds several
    // containers; `read_dir` order is filesystem-dependent.
    candidates.sort();
    candidates.into_iter().next()
}

/// Load the request spans for a recording, preferring the container's span
/// stream over the legacy sidecar.
///
/// `trace_path` may be a `.ct` container or the directory that holds one.
/// Returns `Ok(None)` when the recording carries neither a span stream nor a
/// sidecar — the ordinary case for every recording that is not a server session.
///
/// **Opening is index-only.** Building the [`SpanStreamReader`] parses
/// `spans.idx` and decompresses nothing; the records are decoded here because
/// this function's job is to answer a query. RS-M3's live tail will instead hold
/// the reader across polls and call `read_spans_since`.
pub fn load_request_spans(trace_path: &Path) -> Result<Option<RequestSpans>, String> {
    let base_dir = if trace_path.is_dir() {
        trace_path.to_path_buf()
    } else {
        trace_path.parent().unwrap_or(Path::new(".")).to_path_buf()
    };

    if let Some(ct_path) = find_ct_container(trace_path) {
        let mut ctfs =
            CtfsReader::open(&ct_path).map_err(|e| format!("failed to open {}: {e}", ct_path.display()))?;
        if let Some(mut reader) = SpanStreamReader::open_from_ctfs(&mut ctfs)? {
            let spans = reader.settled_spans()?;
            return Ok(Some(RequestSpans {
                spans,
                source: RequestSpanSource::SpanStream,
                skipped_lines: 0,
                // External bindings are "relative to this container's
                // directory", which is the container's own parent — not
                // necessarily `trace_path` when the caller passed the file.
                base_dir: ct_path.parent().unwrap_or(Path::new(".")).to_path_buf(),
            }));
        }
    }

    // No stream: fall back to the read-only sidecar shim so pre-cutover
    // sessions keep opening.
    load_legacy_jsonl_spans(&base_dir)
}

// ── RS-M3 part A — the held tail cursor ─────────────────────────────────
//
// `load_request_spans` above re-opens the container and decodes the WHOLE
// stream on every call. That is right for a one-shot query and wrong for a
// live panel: a poll loop over a growing container would re-decompress every
// chunk it has already seen, so the cost of the Nth poll is O(total chunks)
// and the cost of a session is O(polls x chunks). The `spans.idx` cumulative
// column and [`SpanStreamReader::read_spans_since`] exist to make the poll
// cost O(new chunks); what was missing is somewhere to keep the cursor.
//
// [`RequestSpanTail`] is that place. It holds the reader across polls and
// decodes only the chunks sealed since the caller last looked.
//
// ## What invalidates the cursor
//
// | Trigger                                    | Effect                        |
// | ------------------------------------------ | ----------------------------- |
// | The session's trace folder changed         | owner drops the whole tail    |
// | The source file changed (grew / rewritten) | reader rebuilt, cursor kept   |
// | The source file SHRANK                     | reader rebuilt, `reset`       |
// | The source file was swapped (sidecar -> stream, or a different container) | reader rebuilt, `reset` |
// | The client's cursor is past the head       | full snapshot, `reset`        |
// | Any read/decode error                      | reader dropped, error raised, next poll rebuilds from scratch |
//
// "Reader rebuilt, cursor kept" is safe because a sealed chunk is IMMUTABLE:
// the writer appends the chunk body, syncs it, then appends the index entry
// and syncs that (`span_stream.nim`'s `flushChunk`), so a reader that has seen
// N index entries has seen N final chunks. Chunk k means the same records in
// every later observation of the same container, which is exactly what makes a
// chunk count usable as a cursor.
//
// ## Last-record-wins across deltas: the CLIENT resolves
//
// Within one delta the backend applies [`resolve_spans`], so a delta that
// carries both an open record and its completion yields ONE settled row.
// Across deltas the CLIENT resolves, by merging each payload into its list
// keyed on `RequestRecord::id` (last wins).
//
// Why not resolve on the backend: doing so would require the backend to
// remember every span it ever sent to every client, i.e. state proportional to
// the whole stream — which is precisely the cost the tail exists to avoid —
// and it still could not be authoritative, because a client may replay an
// older cursor, reconnect, or run two panels over one session.
//
// The wire contract makes client-side resolution correct rather than merely
// possible:
//
// * `id` is the span's `span_id`: 1-based, stable, and the same key the
//   backend's own last-record-wins uses. A record is never re-keyed.
// * `isOpen` tells the client whether a row is in flight, so it can render the
//   greyed state and know a completion is still coming.
// * A delta always ends at the CURRENT head, so the records it carries are the
//   settled state as of now for every span in its range. Replaying an older
//   cursor therefore yields a SUPERSET of the newer delta whose overlapping
//   rows are identical or newer — never staler. Merging an overlapping delta
//   can only re-apply what the client already has; it can never resurrect a
//   superseded open record. That is what makes deltas overlap-safe.

/// The sidecar this session would be tailed from, if any.
///
/// Deliberately different from the probe inside [`load_legacy_jsonl_spans`],
/// which SKIPS an empty sidecar so a created-but-never-appended PHP manifest
/// does not mask a populated Ruby/Python one. A live session starts with an
/// empty manifest and grows it, so for the tail an empty file is the right
/// thing to bind to, not a reason to look elsewhere.
fn legacy_sidecar_path(session_dir: &Path) -> Option<PathBuf> {
    [PHP_SESSION_MANIFEST_FILE, RUBY_PYTHON_SPANS_FILE]
        .into_iter()
        .map(|name| session_dir.join(name))
        .find(|path| path.is_file())
}

/// Filesystem identity of the bytes a held reader was built from.
///
/// Length AND mtime, because neither alone is sufficient. A `.ct` container is
/// block-padded, so appending a chunk very often leaves its file LENGTH
/// unchanged — mtime is what actually moves. Conversely a filesystem with a
/// coarse mtime clock can report the same mtime for two appends inside one
/// tick, and there the length usually differs.
///
/// A missed change costs LATENCY, not correctness: the poll returns an empty
/// delta and the next one — by which time the clock has moved — returns
/// everything from the same cursor. Nothing is skipped, because the cursor only
/// advances over chunks that were actually read.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
struct SourceStamp {
    len: u64,
    modified_ns: u128,
}

/// Stamp `path`, or `None` when the filesystem cannot tell us enough to detect
/// a change.
///
/// `None` is the FAIL-SAFE answer: the caller treats an unstampable source as
/// "changed", so the tail rebuilds its reader every poll rather than serving
/// records from a stale image. It costs performance, never correctness.
fn stamp_of(path: &Path) -> Option<SourceStamp> {
    let meta = std::fs::metadata(path).ok()?;
    let modified_ns = meta
        .modified()
        .ok()?
        .duration_since(std::time::UNIX_EPOCH)
        .ok()?
        .as_nanos();
    Some(SourceStamp {
        len: meta.len(),
        modified_ns,
    })
}

/// What a [`RequestSpanTail`] is currently reading.
#[derive(Debug)]
enum TailBody {
    /// The container's `spans.dat`, held open across polls. This is the case
    /// the whole design is for.
    Stream {
        container: PathBuf,
        /// `meta.dat`'s UUIDv7 recording id. Held so that a container REPLACED
        /// in place — the user re-records to the same path — is recognised as a
        /// different recording rather than tailed as if it were a continuation
        /// of the old one. The path is identical in that case and the file
        /// length often is too (containers are block-padded), so the recording
        /// id is the only reliable identity available without decoding.
        recording_id: String,
        reader: SpanStreamReader,
    },
    /// A pre-cutover sidecar. There are no chunks to skip, so the cursor counts
    /// RECORDS already delivered and the file is re-parsed whenever it changes.
    /// Cheap by comparison — parsing text costs no zstd frames — and it keeps
    /// the live panel working for the PHP/Ruby/Python sessions that exist today.
    Legacy { path: PathBuf, spans: Vec<SpanRecord> },
    /// The recording carries neither. Polls answer empty rather than failing:
    /// "this program served no HTTP requests" is the ordinary case.
    Absent,
}

impl TailBody {
    /// The file whose changes this body must track, or `None` when absent.
    fn source_path(&self) -> Option<&Path> {
        match self {
            TailBody::Stream { container, .. } => Some(container.as_path()),
            TailBody::Legacy { path, .. } => Some(path.as_path()),
            TailBody::Absent => None,
        }
    }

    /// What a cursor issued against this body is counting. Two bodies with
    /// different identities do not share a cursor space, so a change here
    /// forces a `reset`.
    fn identity(&self) -> (Option<PathBuf>, String) {
        let recording = match self {
            TailBody::Stream { recording_id, .. } => recording_id.clone(),
            _ => String::new(),
        };
        (self.source_path().map(Path::to_path_buf), recording)
    }

    /// Wire string for the delta's `source` field.
    fn source_name(&self) -> &'static str {
        match self {
            TailBody::Stream { .. } => RequestSpanSource::SpanStream.as_str(),
            TailBody::Legacy { .. } => RequestSpanSource::LegacyJsonl.as_str(),
            TailBody::Absent => "none",
        }
    }
}

/// Arguments of the `ct/load-request-spans-since` DAP request.
#[derive(Debug, Clone, Default, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct LoadRequestSpansSinceArguments {
    /// The `cursor` from the client's previous delta. Omitted (or `0`) asks for
    /// a full snapshot.
    ///
    /// OPAQUE to the client: it is a chunk count for a span stream and a record
    /// count for a legacy sidecar. Clients echo it back and never interpret it.
    #[serde(default)]
    pub cursor: Option<u64>,
}

/// Response body of `ct/load-request-spans-since`, and the body of the
/// `ct/updated-http-requests` event.
#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct RequestSpanDelta {
    /// The web-request rows in this delta, settled WITHIN the delta and
    /// ascending by `id`. Merge into the client list keyed on `id`, last wins.
    pub spans: Vec<RequestRecord>,
    /// The cursor to send with the next poll.
    pub cursor: u64,
    /// `true` when `spans` is the COMPLETE settled set rather than a delta, so
    /// the client must replace its list instead of merging. Set on the first
    /// poll and after any invalidation.
    pub reset: bool,
    /// `"span-stream"` | `"legacy-jsonl"` | `"none"`.
    pub source: String,
}

/// A live tail over one recording's request spans.
///
/// Owned by the DAP handler for the duration of a session and re-created when
/// the session's trace folder changes. See the section comment above for the
/// invalidation rules and the last-record-wins contract.
#[derive(Debug)]
pub struct RequestSpanTail {
    /// The recording this tail is bound to — a `.ct` container or the directory
    /// holding one.
    trace_path: PathBuf,
    /// Directory external bindings resolve relative to.
    base_dir: PathBuf,
    body: TailBody,
    /// Identity of the bytes `body` was built from; `None` means "unknown, so
    /// rebuild".
    stamp: Option<SourceStamp>,
    /// Chunk decompressions charged to readers this tail has already retired.
    /// The live reader's own counter is added on read — see
    /// [`Self::chunk_decompressions`].
    retired_decompressions: u64,
    /// The next delta must be a full snapshot.
    reset_pending: bool,
}

impl RequestSpanTail {
    /// Bind a tail to a recording WITHOUT touching it.
    ///
    /// Nothing is opened, stat-ed or decoded here, for the same reason
    /// `Handler::set_trace_folder` stores a bare path: the overwhelming
    /// majority of recordings carry no spans at all, and a session that never
    /// opens the Request panel must not pay for one.
    pub fn new(trace_path: &Path) -> RequestSpanTail {
        let base_dir = if trace_path.is_dir() {
            trace_path.to_path_buf()
        } else {
            trace_path.parent().unwrap_or(Path::new(".")).to_path_buf()
        };
        RequestSpanTail {
            trace_path: trace_path.to_path_buf(),
            base_dir,
            body: TailBody::Absent,
            stamp: None,
            retired_decompressions: 0,
            // The first delta a client ever receives is by definition the whole
            // settled set, so it is flagged as a snapshot.
            reset_pending: true,
        }
    }

    /// The recording this tail is bound to. The owner compares it against the
    /// session's current trace folder to decide whether the tail still applies.
    pub fn trace_path(&self) -> &Path {
        &self.trace_path
    }

    /// TEST SEAM. Total zstd frames decompressed by this tail, across every
    /// reader generation it has held.
    ///
    /// The tail's entire reason to exist is that this number grows with the
    /// chunks a session ADDS, not with the chunks it has. That is a performance
    /// property with no functional shadow — polling the RS-M2 one-shot query in
    /// a loop returns identical records — so the only way to pin it is to count.
    /// Nothing in this module reads the counter, so no production path can
    /// branch on it.
    pub fn chunk_decompressions(&self) -> u64 {
        let live = match &self.body {
            TailBody::Stream { reader, .. } => reader.chunk_decompressions(),
            _ => 0,
        };
        self.retired_decompressions + live
    }

    /// Charge the live reader's decompressions to the retired total, so the
    /// counter survives the reader it was accumulated on.
    fn retire_body(&mut self) {
        if let TailBody::Stream { reader, .. } = &self.body {
            self.retired_decompressions += reader.chunk_decompressions();
        }
        self.body = TailBody::Absent;
        self.stamp = None;
    }

    /// Open a fresh body for `trace_path`, preferring the stream over the shim.
    fn open_body(trace_path: &Path) -> Result<(TailBody, PathBuf), String> {
        let base_dir = if trace_path.is_dir() {
            trace_path.to_path_buf()
        } else {
            trace_path.parent().unwrap_or(Path::new(".")).to_path_buf()
        };

        if let Some(ct_path) = find_ct_container(trace_path) {
            let mut ctfs =
                CtfsReader::open(&ct_path).map_err(|e| format!("failed to open {}: {e}", ct_path.display()))?;
            // Read before the reader is built: a container with no readable
            // `meta.dat` also has no span stream, so an empty id here is only
            // ever paired with `TailBody::Absent` or a legacy body.
            let recording_id = ctfs
                .read_file("meta.dat")
                .ok()
                .and_then(|meta| crate::ctfs_trace_reader::meta_dat::parse_meta_dat(&meta).ok())
                .map(|meta| meta.recording_id)
                .unwrap_or_default();
            if let Some(reader) = SpanStreamReader::open_from_ctfs(&mut ctfs)? {
                // External bindings are relative to the CONTAINER's directory,
                // which is not necessarily `trace_path`.
                let dir = ct_path.parent().unwrap_or(Path::new(".")).to_path_buf();
                return Ok((
                    TailBody::Stream {
                        container: ct_path,
                        recording_id,
                        reader,
                    },
                    dir,
                ));
            }
        }

        if let Some(path) = legacy_sidecar_path(&base_dir) {
            let text = std::fs::read_to_string(&path).map_err(|e| format!("failed to read {}: {e}", path.display()))?;
            let (spans, _skipped) = parse_legacy_jsonl(&text, &path);
            return Ok((TailBody::Legacy { path, spans }, base_dir));
        }

        Ok((TailBody::Absent, base_dir))
    }

    /// Bring the held body up to date with what is on disk.
    ///
    /// The fast path is the point: when the source file is byte-identical to
    /// what the held reader was built from, this performs ONE `stat` and
    /// returns — no container open, no index parse, no decompression. That is
    /// the state a poll loop is in most of the time.
    fn refresh(&mut self) -> Result<(), String> {
        let bound = self.body.identity();
        // A tail with no source yet (`TailBody::Absent`) has nothing to stamp,
        // so it re-probes on every poll. That is deliberate rather than
        // wasteful: a live session's container declares its span stream the
        // first time the recorder registers a span, so "no spans here" is a
        // state a poll loop must be able to leave.
        if let (Some(path), Some(seen)) = (bound.0.as_deref(), self.stamp) {
            match stamp_of(path) {
                Some(now) if now == seen => return Ok(()),
                Some(now) if now.len < seen.len => {
                    // The source lost bytes: it was truncated, rotated or
                    // replaced. Whatever the client's cursor names, it no
                    // longer names the same records. (Block padding can hide a
                    // shrink; the authoritative guard is the cursor-past-head
                    // check in `poll`, and the recording-id check below.)
                    self.reset_pending = true;
                }
                _ => {}
            }
        }

        self.retire_body();
        let (body, base_dir) = self.rebuild()?;
        // A source SWAP — a container appeared next to the sidecar we were
        // tailing, a different container was selected, or the same path now
        // holds a DIFFERENT recording — changes what a cursor counts, so the
        // client must start over.
        if body.identity() != bound {
            self.reset_pending = true;
        }
        self.stamp = body.source_path().and_then(stamp_of);
        self.body = body;
        self.base_dir = base_dir;
        Ok(())
    }

    /// Re-open the source, leaving the tail in a clean "rebuild me" state if
    /// that fails so a later poll is not served off a half-initialised reader.
    fn rebuild(&mut self) -> Result<(TailBody, PathBuf), String> {
        match RequestSpanTail::open_body(&self.trace_path) {
            Ok(v) => Ok(v),
            Err(e) => {
                self.reset_pending = true;
                Err(e)
            }
        }
    }

    /// Return everything appended since `client_cursor`.
    ///
    /// `client_cursor` is the client's own cursor, NOT the tail's: a client
    /// that replays an older one gets a superset ending at the same head, which
    /// merges to the same set (see the section comment). A cursor past the head
    /// is not an error — it is a client whose recording was replaced — and
    /// yields a `reset` snapshot.
    pub fn poll(&mut self, client_cursor: u64) -> Result<RequestSpanDelta, String> {
        self.refresh()?;

        let force_reset = self.reset_pending;
        let source = self.body.source_name().to_string();
        let outcome = match &mut self.body {
            TailBody::Stream { reader, .. } => {
                let head = reader.chunk_count() as u64;
                let effective = if force_reset || client_cursor > head {
                    0
                } else {
                    client_cursor
                };
                usize::try_from(effective)
                    .map_err(|_| format!("request-span cursor {effective} does not fit in usize"))
                    .and_then(|from| reader.read_spans_since(from))
                    // Last-record-wins WITHIN the delta: an open record and its
                    // completion that land in the same batch must arrive as one
                    // settled row, not as two rows the client has to untangle.
                    .map(|raw| (resolve_spans(raw), head, effective == 0))
            }
            TailBody::Legacy { spans, .. } => {
                let head = spans.len() as u64;
                let effective = if force_reset || client_cursor > head {
                    0
                } else {
                    client_cursor
                };
                let from = usize::try_from(effective).unwrap_or(0).min(spans.len());
                Ok((spans[from..].to_vec(), head, effective == 0))
            }
            TailBody::Absent => Ok((Vec::new(), 0, force_reset)),
        };

        let (spans, cursor, reset) = match outcome {
            Ok(v) => v,
            Err(e) => {
                // A decode failure poisons the cursor: we do not know how much
                // of the stream we actually consumed. Drop the reader so the
                // next poll rebuilds and re-snapshots.
                self.retire_body();
                self.reset_pending = true;
                return Err(e);
            }
        };
        self.reset_pending = false;

        Ok(RequestSpanDelta {
            spans: spans
                .iter()
                .filter(|s| s.span_type == SPAN_TYPE_WEB_REQUEST)
                .map(|s| to_request_record(s, &self.base_dir))
                .collect(),
            cursor,
            reset,
            source,
        })
    }
}

// ── Legacy JSONL shim (read-only) ───────────────────────────────────────

/// Read a pre-cutover sidecar session directory into the same span records the
/// stream path produces.
///
/// Probes `session_manifest.jsonl` (PHP) then `codetracer_spans.jsonl`
/// (Ruby/Python), matching the order and the field mapping of the reference
/// loader at
/// `codetracer-native-recorder/ct_server_record/src/ct_server_record/span_manifest.nim`.
/// Returns `Ok(None)` when neither file is present.
pub fn load_legacy_jsonl_spans(session_dir: &Path) -> Result<Option<RequestSpans>, String> {
    for name in [PHP_SESSION_MANIFEST_FILE, RUBY_PYTHON_SPANS_FILE] {
        let path = session_dir.join(name);
        if !path.is_file() {
            continue;
        }
        let text = std::fs::read_to_string(&path).map_err(|e| format!("failed to read {}: {e}", path.display()))?;
        let (spans, skipped) = parse_legacy_jsonl(&text, &path);
        if spans.is_empty() && skipped == 0 {
            // An empty (or whitespace-only) sidecar carries no session; keep
            // probing so a PHP manifest that was created but never appended to
            // does not mask a populated Ruby/Python one next to it.
            continue;
        }
        return Ok(Some(RequestSpans {
            spans,
            source: RequestSpanSource::LegacyJsonl,
            skipped_lines: skipped,
            base_dir: session_dir.to_path_buf(),
        }));
    }
    Ok(None)
}

/// Parse sidecar JSONL text into span records, returning `(spans, skipped)`.
///
/// Malformed lines are SKIPPED rather than failing the load, which is the one
/// place this module deliberately departs from the stream's fail-closed
/// discipline. The reason is that the sidecar is append-only text written by a
/// `register_shutdown_function` in a process that may have been killed
/// mid-write, so a truncated final line is an expected state of a real session
/// — refusing the whole file would make exactly the recordings this shim exists
/// to rescue unopenable. The skip count is returned (and logged) so the
/// degradation is visible rather than silent.
fn parse_legacy_jsonl(text: &str, source_path: &Path) -> (Vec<SpanRecord>, usize) {
    let mut spans: Vec<SpanRecord> = Vec::new();
    let mut skipped = 0usize;

    for line in text.lines() {
        let trimmed = line.trim();
        if trimmed.is_empty() {
            continue;
        }
        let json: Value = match serde_json::from_str(trimmed) {
            Ok(v) => v,
            Err(_) => {
                skipped += 1;
                continue;
            }
        };
        let Some(metadata) = json.get("metadata").and_then(|m| m.as_object()) else {
            // The reference loader treats a line with no `metadata` object as
            // carrying no request at all.
            skipped += 1;
            continue;
        };

        let str_field = |key: &str| -> String {
            metadata
                .get(key)
                .and_then(|v| match v {
                    // Recorders emit these as strings, but accept a number
                    // rather than dropping a request over a JSON type.
                    Value::String(s) => Some(s.clone()),
                    Value::Number(n) => Some(n.to_string()),
                    _ => None,
                })
                .unwrap_or_default()
        };

        // `span_id` is the 1-based position in the file. The sidecar has no id
        // column of its own (the reference loader synthesises `span_<n>` the
        // same way), and position is stable for an append-only file, so it is
        // the only cursor available — and it makes the shim's ids line up with
        // the stream's `span_id` for a session recorded both ways.
        let span_id = spans.len() as u64 + 1;

        let status_code_text = str_field(KEY_HTTP_STATUS_CODE);
        let status = match json.get("status").and_then(|v| v.as_str()) {
            Some("error") => SpanStatus::Error,
            Some("ok") => SpanStatus::Ok,
            // No explicit status column (the Ruby/Python sidecar has none):
            // derive it from the response code, which is what the PHP recorder
            // does when it writes the column in the first place.
            _ => match status_code_text.trim().parse::<i64>() {
                Ok(code) if code >= 400 => SpanStatus::Error,
                Ok(_) => SpanStatus::Ok,
                Err(_) => SpanStatus::Unknown,
            },
        };

        let trace_dir = json.get("trace_dir").and_then(|v| v.as_str()).unwrap_or("").to_string();
        let http_method = str_field(KEY_HTTP_METHOD);
        let url = str_field(KEY_HTTP_URL);

        let mut metadata_pairs = vec![
            (KEY_HTTP_METHOD.to_string(), http_method.clone()),
            (KEY_HTTP_URL.to_string(), url.clone()),
            (KEY_HTTP_STATUS_CODE.to_string(), status_code_text),
            (KEY_HTTP_DURATION_MS.to_string(), str_field(KEY_HTTP_DURATION_MS)),
        ];
        // Carry through any other `http.*` / `framework` keys a middleware
        // emitted, after the four canonical ones, so the shim does not silently
        // discard metadata the panel could render.
        for (key, value) in metadata {
            if metadata_pairs.iter().any(|(k, _)| k == key) {
                continue;
            }
            if let Value::String(s) = value {
                metadata_pairs.push((key.clone(), s.clone()));
            }
        }

        spans.push(SpanRecord {
            span_id,
            parent_span_id: 0,
            is_open: false,
            // A sidecar entry always names a SEPARATE trace directory — that is
            // exactly what `flags.external` models, and the spec says so:
            // "The external binding … replaces exactly what
            // `session_manifest.jsonl`'s `trace_dir` does today."
            is_external: !trace_dir.is_empty(),
            status,
            // The sidecar carries no wall-clock timestamps in nanoseconds and
            // no step binding at all. Leaving these zero is honest: it is the
            // information the pre-cutover format never recorded.
            start_wall_ns: 0,
            end_wall_ns: 0,
            process_ord: 0,
            thread_id: 0,
            start_step: 0,
            end_step: 0,
            external_recording: String::new(),
            external_path: trace_dir,
            span_type: json
                .get("span_type")
                .and_then(|v| v.as_str())
                .unwrap_or(SPAN_TYPE_WEB_REQUEST)
                .to_string(),
            label: if http_method.is_empty() && url.is_empty() {
                String::new()
            } else {
                format!("{http_method} {url}")
            },
            contiguous_on_one_thread: false,
            shares_timeline: false,
            concurrent_with_siblings: false,
            metadata: metadata_pairs,
        });
    }

    if skipped > 0 {
        warn!(
            "request spans: skipped {skipped} unparseable line(s) in {}",
            source_path.display()
        );
    }
    (spans, skipped)
}

// ── Tests ───────────────────────────────────────────────────────────────

#[cfg(test)]
#[allow(clippy::unwrap_used, clippy::expect_used, clippy::panic)]
mod tests {
    use super::*;

    fn span(span_id: u64, http_method: &str, url: &str, status: i64, duration: i64) -> SpanRecord {
        SpanRecord {
            span_id,
            span_type: SPAN_TYPE_WEB_REQUEST.to_string(),
            status: if status >= 400 { SpanStatus::Error } else { SpanStatus::Ok },
            start_step: span_id * 10,
            end_step: span_id * 10 + 9,
            metadata: vec![
                (KEY_HTTP_METHOD.to_string(), http_method.to_string()),
                (KEY_HTTP_URL.to_string(), url.to_string()),
                (KEY_HTTP_STATUS_CODE.to_string(), status.to_string()),
                (KEY_HTTP_DURATION_MS.to_string(), duration.to_string()),
            ],
            ..SpanRecord::default()
        }
    }

    fn fixture() -> RequestSpans {
        RequestSpans {
            spans: vec![
                span(1, "GET", "/api/users", 200, 12),
                span(2, "POST", "/api/users", 201, 31),
                span(3, "GET", "/static/app.css", 304, 1),
                span(4, "DELETE", "/api/users/42", 404, 5),
                span(5, "PUT", "/api/orders/7", 500, 220),
            ],
            source: RequestSpanSource::SpanStream,
            skipped_lines: 0,
            base_dir: PathBuf::from("."),
        }
    }

    #[test]
    fn projects_every_request_record_column() {
        let spans = fixture();
        let records = spans.request_records();
        assert_eq!(records.len(), 5);
        assert_eq!(records[0].id, 1);
        assert_eq!(records[0].http_method, "GET");
        assert_eq!(records[0].url, "/api/users");
        assert_eq!(records[0].status_code, 200);
        assert_eq!(records[0].duration_ms, 12);
        assert_eq!(records[0].start_geid, 10);
        assert_eq!(records[0].status, "ok");
        assert!(!records[0].is_open);
    }

    #[test]
    fn non_request_spans_are_not_rows() {
        let mut spans = fixture();
        let mut process = span(6, "", "", 0, 0);
        process.span_type = "process".to_string();
        spans.spans.push(process);
        let records = spans.request_records();
        assert_eq!(records.len(), 5, "a process span must not become a request row");
        assert!(records.iter().all(|r| r.id != 6));
    }

    #[test]
    fn filters_compose_by_and() {
        let spans = fixture();
        let args = LoadRequestSpansArguments {
            filters: Some(RequestSpanFilters {
                method: Some("get".to_string()),
                status_class: Some("2xx".to_string()),
                url_contains: Some("USERS".to_string()),
            }),
            ..Default::default()
        };
        let resp = spans.page(&args);
        assert_eq!(resp.requests.len(), 1);
        assert_eq!(resp.requests[0].id, 1);
        assert_eq!(resp.total, 1);
    }

    #[test]
    fn empty_filters_match_everything() {
        let spans = fixture();
        let args = LoadRequestSpansArguments {
            filters: Some(RequestSpanFilters {
                method: Some(String::new()),
                status_class: Some(String::new()),
                url_contains: Some(String::new()),
            }),
            ..Default::default()
        };
        assert_eq!(spans.page(&args).requests.len(), 5);
    }

    #[test]
    fn paging_cursor_walks_the_filtered_list_without_gaps_or_repeats() {
        let spans = fixture();
        let filters = RequestSpanFilters {
            method: Some("GET".to_string()),
            ..Default::default()
        };
        let full = spans.page(&LoadRequestSpansArguments {
            filters: Some(filters.clone()),
            ..Default::default()
        });

        let mut walked: Vec<u64> = Vec::new();
        let mut cursor = Some(0u64);
        while let Some(from) = cursor {
            let page = spans.page(&LoadRequestSpansArguments {
                from_span_id: Some(from),
                limit: Some(1),
                filters: Some(filters.clone()),
            });
            walked.extend(page.requests.iter().map(|r| r.id));
            cursor = page.next_span_id;
        }
        assert_eq!(walked, full.requests.iter().map(|r| r.id).collect::<Vec<_>>());
    }

    #[test]
    fn legacy_jsonl_maps_the_php_sidecar_shape() {
        let text = concat!(
            r#"{"trace_dir":"requests/req-0001","span_type":"web-request","status":"ok","#,
            r#""metadata":{"http.method":"GET","http.url":"/a","http.status_code":"200","http.duration_ms":"12"}}"#,
            "\n",
            r#"{"trace_dir":"requests/req-0002","span_type":"web-request","status":"error","#,
            r#""metadata":{"http.method":"POST","http.url":"/b","http.status_code":"500","http.duration_ms":"3"}}"#,
            "\n",
        );
        let (spans, skipped) = parse_legacy_jsonl(text, Path::new("session_manifest.jsonl"));
        assert_eq!(skipped, 0);
        assert_eq!(spans.len(), 2);
        assert_eq!(spans[0].span_id, 1);
        assert_eq!(spans[1].span_id, 2);
        assert_eq!(spans[0].metadata_value(KEY_HTTP_URL), Some("/a"));
        assert_eq!(spans[1].status, SpanStatus::Error);
        assert!(spans[1].is_external, "a trace_dir is an external binding");
        assert_eq!(spans[1].external_path, "requests/req-0002");
        // The sidecar never carried a step binding — asserting the zero is the
        // point, not an oversight.
        assert_eq!(spans[0].start_step, 0);
    }

    #[test]
    fn legacy_jsonl_derives_status_when_the_column_is_absent() {
        // The Ruby/Python sidecar has no `status` column at all.
        let text = concat!(
            r#"{"metadata":{"http.method":"GET","http.url":"/ok","http.status_code":"204","http.duration_ms":"1"}}"#,
            "\n",
            r#"{"metadata":{"http.method":"GET","http.url":"/bad","http.status_code":"503","http.duration_ms":"1"}}"#,
            "\n",
        );
        let (spans, skipped) = parse_legacy_jsonl(text, Path::new("codetracer_spans.jsonl"));
        assert_eq!(skipped, 0);
        assert_eq!(spans[0].status, SpanStatus::Ok);
        assert_eq!(spans[1].status, SpanStatus::Error);
        assert!(!spans[0].is_external, "no trace_dir means no external binding");
    }

    #[test]
    fn legacy_jsonl_skips_and_counts_a_truncated_final_line() {
        let text = concat!(
            r#"{"metadata":{"http.method":"GET","http.url":"/a","http.status_code":"200","http.duration_ms":"1"}}"#,
            "\n",
            r#"{"metadata":{"http.method":"GET","http.url":"#,
        );
        let (spans, skipped) = parse_legacy_jsonl(text, Path::new("session_manifest.jsonl"));
        assert_eq!(spans.len(), 1, "the good line must still load");
        assert_eq!(skipped, 1, "the truncated line must be counted, not hidden");
    }

    #[test]
    fn external_binding_resolves_only_to_a_container_that_exists() {
        let dir = tempfile::tempdir().expect("tempdir");
        let mut external = span(1, "GET", "/a", 200, 1);
        external.is_external = true;
        external.external_path = "requests/req-0001.ct".to_string();
        assert_eq!(
            resolve_external_container(&external, dir.path()),
            None,
            "a dangling binding must not be reported as openable"
        );

        std::fs::create_dir_all(dir.path().join("requests")).expect("mkdir");
        std::fs::write(dir.path().join("requests/req-0001.ct"), b"not really a container").expect("write");
        assert_eq!(
            resolve_external_container(&external, dir.path()),
            Some(dir.path().join("requests/req-0001.ct"))
        );

        // A directory-shaped binding (what the PHP sidecar's `trace_dir` is)
        // resolves through to the container inside it.
        let mut as_dir = external.clone();
        as_dir.external_path = "requests".to_string();
        assert_eq!(
            resolve_external_container(&as_dir, dir.path()),
            Some(dir.path().join("requests/req-0001.ct"))
        );

        // A non-external span never resolves, whatever the path says.
        let mut inline = external.clone();
        inline.is_external = false;
        assert_eq!(resolve_external_container(&inline, dir.path()), None);
    }
}
