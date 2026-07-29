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
    SPAN_TYPE_WEB_REQUEST, SpanRecord, SpanStatus, SpanStreamReader,
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
            external_trace_path: resolve_external_container(span, &self.base_dir)
                .map(|p| p.to_string_lossy().into_owned()),
        }
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
