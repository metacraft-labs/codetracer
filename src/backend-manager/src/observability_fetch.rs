//! Observability dive-in URL → local trace directory bridge.
//!
//! When `backend-manager` is asked to operate on a trace identified by an
//! observability "dive-in URL" (instead of a local `.ct` path), this
//! module fetches the recording bytes from the CodeTracer-CI gateway and
//! materialises them into a local trace directory under
//! `$XDG_CACHE_HOME/codetracer/traces/<trace-id>/`.  After the fetch
//! completes, the rest of the backend-manager pipeline (daemon, DAP,
//! Python bridge) operates on the cached directory unchanged.
//!
//! # Dive-in URL shape
//!
//! Dive-in URLs are produced by `ct-observe` and embedded in observability
//! tooling.  Example:
//!
//!   http://127.0.0.1:36767/observability/v0/debug-session?trace_id=<TID>&span_id=<SID>
//!
//! The host part is the CodeTracer-CI base URL; the gateway range API
//! lives under the same origin at:
//!
//!   GET <base>/api/v1/observability/gateway/manifests/<traceId>      -> JSON
//!   GET <base>/api/v1/observability/gateway/ranges/<traceId>/<key>   -> bytes
//!
//! The manifest response carries `recordingManifest.mcrSlices[].sliceKey`
//! and/or `shardedMcrSegments[].shards[].replicas[].objectKey`.  These
//! are the object keys we then fetch via the range endpoint.  This
//! matches the contract enforced by the M14 constellation fixture
//! (`codetracer-observability-e2e/scripts/m14_constellation.py`,
//! [`handle_gateway_range`] and [`handle_gateway_manifest`]) and the
//! production client used by browser-replay
//! (`codetracer/browser-replay/app/worker.js`, `listManifestObjectKeys`).
//!
//! # Authentication
//!
//! The gateway requires `Authorization: Bearer <token>`.  The token can
//! be supplied via:
//!  1. URL query parameter `authToken` or `auth_token` on the dive-in
//!     URL (the same encoding used by the browser-replay client URL).
//!  2. Environment variable `CODETRACER_GATEWAY_TOKEN`.
//!  3. No token (some fixtures accept an empty token — best effort).
//!
//! # Cache key
//!
//! The trace ID (extracted from the dive-in URL) is used as the cache
//! key.  Multiple span_ids referencing the same recording therefore
//! share one cached directory.  Trace IDs are sanitised so they are
//! safe to use as a directory name.
//!
//! # Streaming
//!
//! Each range response is streamed to disk through a buffered writer in
//! 64 KiB chunks; we never hold a full recording in RAM.

use std::io::Write;
use std::path::{Path, PathBuf};
use std::time::Duration;

use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::TcpStream;

// ---------------------------------------------------------------------------
// Public surface
// ---------------------------------------------------------------------------

/// Result of fetching a recording from a dive-in URL.
#[derive(Debug, Clone)]
pub struct FetchedRecording {
    /// On-disk directory containing the materialised `.ct` payloads.
    /// Suitable for passing into `ct/open-trace` directly.
    pub local_path: PathBuf,
    /// The trace id extracted from the dive-in URL.
    pub trace_id: String,
    /// The span id extracted from the dive-in URL (may be empty).
    pub span_id: String,
    /// Object keys fetched from the gateway (kept for diagnostics).
    pub object_keys: Vec<String>,
    /// Whether the directory was reused from cache (no network).
    pub from_cache: bool,
}

/// Parsed components of a dive-in URL.
///
/// Public mostly so unit tests (and the CLI flag detection in `main.rs`)
/// can share the same parser instead of doing ad-hoc string matching.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DiveInUrl {
    /// HTTP scheme + host[:port], e.g. `http://127.0.0.1:36767`.
    pub base_url: String,
    /// `trace_id` query parameter (required).
    pub trace_id: String,
    /// `span_id` query parameter (may be empty).
    pub span_id: String,
    /// Optional bearer token harvested from the URL query string.
    pub auth_token: Option<String>,
}

/// Returns `true` if the given string looks like an HTTP(S) URL.
///
/// Used by tool handlers to decide whether to treat `trace_path` as a
/// local path or as a dive-in URL.
pub fn looks_like_url(s: &str) -> bool {
    s.starts_with("http://") || s.starts_with("https://")
}

/// Parse a dive-in URL into its components.
///
/// Accepts both forms emitted by `ct-observe`:
///  - Pure dive-in: `http://host:port/observability/v0/debug-session?...`
///  - Browser-replay client URL: `http://host:port/replay-client/...?gatewayBaseUrl=...&traceId=...`
///
/// Returns an `Err` if the URL is malformed or missing `trace_id`.
pub fn parse_dive_in_url(url: &str) -> Result<DiveInUrl, String> {
    if !looks_like_url(url) {
        return Err(format!("not an http(s) URL: {url}"));
    }

    // Locate the query string.
    let (origin_and_path, query) = match url.find('?') {
        Some(i) => (&url[..i], &url[i + 1..]),
        None => (url, ""),
    };

    // Strip scheme to find the host segment.
    let (scheme, rest) = if let Some(r) = origin_and_path.strip_prefix("http://") {
        ("http", r)
    } else if let Some(r) = origin_and_path.strip_prefix("https://") {
        ("https", r)
    } else {
        return Err(format!("unsupported scheme in URL: {url}"));
    };

    // Host is everything up to the first `/`.
    let host = match rest.find('/') {
        Some(i) => &rest[..i],
        None => rest,
    };

    if host.is_empty() {
        return Err(format!("URL has empty host: {url}"));
    }

    let base_url = format!("{scheme}://{host}");

    // Decode query parameters.
    let mut trace_id = String::new();
    let mut span_id = String::new();
    let mut auth_token: Option<String> = None;
    let mut gateway_base_url_override: Option<String> = None;
    for pair in query.split('&') {
        if pair.is_empty() {
            continue;
        }
        let (raw_k, raw_v) = match pair.find('=') {
            Some(i) => (&pair[..i], &pair[i + 1..]),
            None => (pair, ""),
        };
        let k = url_decode(raw_k);
        let v = url_decode(raw_v);
        match k.as_str() {
            "trace_id" | "traceId" => trace_id = v,
            "span_id" | "spanId" => span_id = v,
            "authToken" | "auth_token" if !v.is_empty() => auth_token = Some(v),
            "gatewayBaseUrl" | "gateway_base_url" if !v.is_empty() => {
                gateway_base_url_override = Some(v)
            }
            _ => {}
        }
    }

    if trace_id.is_empty() {
        return Err(format!(
            "dive-in URL is missing required `trace_id` query parameter: {url}"
        ));
    }

    Ok(DiveInUrl {
        base_url: gateway_base_url_override.unwrap_or(base_url),
        trace_id,
        span_id,
        auth_token,
    })
}

/// Fetch the recording for a dive-in URL into the local cache.
///
/// On cache hit the function returns immediately without touching the
/// network.  Cache layout:
///
/// ```text
///   $XDG_CACHE_HOME/codetracer/traces/<trace-id>/
///       trace.ct                  # primary CTFS container (always at this name)
///       <object-key>.bin          # additional payloads, if any
///       .complete                 # sentinel written after a successful fetch
/// ```
///
/// The `.complete` sentinel is what distinguishes a finished cache entry
/// from a partial / interrupted one — partials are torn down and re-fetched.
pub async fn fetch_recording_from_dive_in_url(url: &str) -> Result<FetchedRecording, String> {
    let parsed = parse_dive_in_url(url)?;
    let cache_dir = cache_root().join(sanitize_for_path(&parsed.trace_id));

    if has_complete_marker(&cache_dir).await {
        let object_keys = read_object_keys_metadata(&cache_dir)
            .await
            .unwrap_or_default();
        return Ok(FetchedRecording {
            local_path: cache_dir,
            trace_id: parsed.trace_id,
            span_id: parsed.span_id,
            object_keys,
            from_cache: true,
        });
    }

    // Wipe any partial state.
    if cache_dir.exists() {
        tokio::fs::remove_dir_all(&cache_dir)
            .await
            .map_err(|e| format!("failed to clear partial cache {}: {e}", cache_dir.display()))?;
    }
    tokio::fs::create_dir_all(&cache_dir).await.map_err(|e| {
        format!(
            "failed to create cache directory {}: {e}",
            cache_dir.display()
        )
    })?;

    let auth_token = parsed
        .auth_token
        .clone()
        .or_else(|| std::env::var("CODETRACER_GATEWAY_TOKEN").ok())
        .unwrap_or_default();

    let object_keys =
        fetch_recording_into_dir(&parsed.base_url, &parsed.trace_id, &auth_token, &cache_dir)
            .await?;

    // Persist the object keys for diagnostics on cache hits.
    write_object_keys_metadata(&cache_dir, &object_keys).await?;

    // Mark the cache entry complete only after every write succeeded.
    tokio::fs::write(cache_dir.join(".complete"), b"ok")
        .await
        .map_err(|e| format!("failed to write .complete sentinel: {e}"))?;

    Ok(FetchedRecording {
        local_path: cache_dir,
        trace_id: parsed.trace_id,
        span_id: parsed.span_id,
        object_keys,
        from_cache: false,
    })
}

/// Low-level entry point used by tests: fetch the recording into an
/// explicit directory rather than the user's cache.  Bypasses the
/// `.complete` sentinel — the caller is responsible for atomicity.
pub async fn fetch_recording_into_dir(
    base_url: &str,
    trace_id: &str,
    auth_token: &str,
    dest_dir: &Path,
) -> Result<Vec<String>, String> {
    // 1. Fetch the manifest.
    let manifest_path = format!(
        "/api/v1/observability/gateway/manifests/{}",
        url_encode_component(trace_id)
    );
    let (status, manifest_bytes) = http_get(base_url, &manifest_path, auth_token, None).await?;
    if !(200..300).contains(&status) {
        let body = String::from_utf8_lossy(&manifest_bytes);
        return Err(format!(
            "gateway manifest fetch failed: HTTP {status} {body}"
        ));
    }
    let manifest_str = std::str::from_utf8(&manifest_bytes)
        .map_err(|e| format!("manifest is not valid UTF-8: {e}"))?;
    let manifest_json: serde_json::Value = serde_json::from_str(manifest_str)
        .map_err(|e| format!("manifest is not valid JSON: {e}"))?;
    let recording_manifest = manifest_json
        .get("recordingManifest")
        .ok_or_else(|| "manifest response is missing `recordingManifest` field".to_string())?;
    let object_keys = list_manifest_object_keys(recording_manifest);
    if object_keys.is_empty() {
        return Err(
            "recording manifest contains no fetchable mcrSlices or shardedMcrSegments".to_string(),
        );
    }

    // 2. Fetch each object key via the range endpoint, streaming into
    //    the destination directory.  The first payload is always pinned
    //    at `<dest>/trace.ct` so the existing CTFS loader picks it up
    //    by canonical name.  Subsequent payloads are stored under a
    //    sanitised version of their object key (.bin extension preserved).
    let mut canonical_assigned = false;
    for object_key in &object_keys {
        let range_path = format!(
            "/api/v1/observability/gateway/ranges/{}/{}",
            url_encode_component(trace_id),
            object_key
                .split('/')
                .map(url_encode_component)
                .collect::<Vec<_>>()
                .join("/"),
        );
        let file_name = if !canonical_assigned {
            canonical_assigned = true;
            "trace.ct".to_string()
        } else {
            format!("{}.bin", vfs_safe_name(object_key))
        };
        let dest_file = dest_dir.join(&file_name);

        let mut stream = open_http_connection(base_url).await?;
        let bytes = http_get_streaming(
            &mut stream,
            base_url,
            &range_path,
            auth_token,
            Some("bytes=0-"),
            &dest_file,
        )
        .await?;
        if bytes == 0 {
            return Err(format!(
                "gateway range fetch for object_key={object_key} returned 0 bytes"
            ));
        }
    }

    Ok(object_keys)
}

// ---------------------------------------------------------------------------
// Cache helpers
// ---------------------------------------------------------------------------

/// Returns `$XDG_CACHE_HOME/codetracer/traces` (or `~/.cache/...` if XDG
/// is unset; falls back to the system temp dir if neither is available).
pub fn cache_root() -> PathBuf {
    if let Ok(override_path) = std::env::var("CODETRACER_TRACE_CACHE_DIR") {
        return PathBuf::from(override_path);
    }
    let base = if let Ok(xdg) = std::env::var("XDG_CACHE_HOME") {
        PathBuf::from(xdg)
    } else if let Ok(home) = std::env::var("HOME") {
        PathBuf::from(home).join(".cache")
    } else {
        std::env::temp_dir()
    };
    base.join("codetracer").join("traces")
}

async fn has_complete_marker(dir: &Path) -> bool {
    tokio::fs::metadata(dir.join(".complete")).await.is_ok()
}

async fn read_object_keys_metadata(dir: &Path) -> Result<Vec<String>, String> {
    let path = dir.join("object-keys.json");
    let bytes = tokio::fs::read(&path)
        .await
        .map_err(|e| format!("read {}: {e}", path.display()))?;
    let v: serde_json::Value =
        serde_json::from_slice(&bytes).map_err(|e| format!("parse {}: {e}", path.display()))?;
    Ok(v.as_array()
        .map(|arr| {
            arr.iter()
                .filter_map(|s| s.as_str().map(String::from))
                .collect()
        })
        .unwrap_or_default())
}

async fn write_object_keys_metadata(dir: &Path, keys: &[String]) -> Result<(), String> {
    let path = dir.join("object-keys.json");
    let json = serde_json::to_vec(&keys).map_err(|e| format!("serialise object keys: {e}"))?;
    tokio::fs::write(&path, json)
        .await
        .map_err(|e| format!("write {}: {e}", path.display()))
}

// ---------------------------------------------------------------------------
// Manifest parsing (mirrors browser-replay/app/worker.js:listManifestObjectKeys)
// ---------------------------------------------------------------------------

fn list_manifest_object_keys(manifest: &serde_json::Value) -> Vec<String> {
    let mut keys = Vec::new();
    if let Some(slices) = manifest.get("mcrSlices").and_then(|v| v.as_array()) {
        for slice in slices {
            if let Some(k) = slice.get("sliceKey").and_then(|v| v.as_str())
                && !k.is_empty()
            {
                keys.push(k.to_string());
            }
        }
    }
    if let Some(segs) = manifest
        .get("shardedMcrSegments")
        .and_then(|v| v.as_array())
    {
        for seg in segs {
            let shards = match seg.get("shards").and_then(|v| v.as_array()) {
                Some(s) => s,
                None => continue,
            };
            for shard in shards {
                let replicas = match shard.get("replicas").and_then(|v| v.as_array()) {
                    Some(r) if !r.is_empty() => r,
                    _ => continue,
                };
                if let Some(k) = replicas[0].get("objectKey").and_then(|v| v.as_str())
                    && !k.is_empty()
                {
                    keys.push(k.to_string());
                }
            }
        }
    }
    keys
}

// ---------------------------------------------------------------------------
// Minimal async HTTP/1.1 client
// ---------------------------------------------------------------------------
//
// We hand-roll a small HTTP client to avoid introducing reqwest/hyper as
// dependencies (neither was already in this crate's tree).  Scope is
// limited to: GET requests over plain HTTP, `Authorization: Bearer`,
// `Range: bytes=...`, response status, response body via Content-Length.
// HTTPS is not supported — fetching from `https://` URLs returns an
// explicit error so callers can fall back to other tooling.

async fn open_http_connection(base_url: &str) -> Result<TcpStream, String> {
    if base_url.starts_with("https://") {
        return Err(
            "HTTPS dive-in URLs are not yet supported by backend-manager's gateway fetcher; \
             use ct-observe (which can call out to HTTPS gateways via system curl) or \
             set CODETRACER_GATEWAY_TOKEN and target an HTTP endpoint"
                .to_string(),
        );
    }
    let rest = base_url
        .strip_prefix("http://")
        .ok_or_else(|| format!("unsupported scheme in base URL: {base_url}"))?;
    let host_port = if rest.contains(':') {
        rest.to_string()
    } else {
        format!("{rest}:80")
    };
    let connect = tokio::time::timeout(Duration::from_secs(10), TcpStream::connect(&host_port))
        .await
        .map_err(|_| format!("timeout connecting to {host_port}"))?;
    connect.map_err(|e| format!("connect {host_port}: {e}"))
}

fn host_from_base_url(base_url: &str) -> String {
    base_url
        .strip_prefix("http://")
        .or_else(|| base_url.strip_prefix("https://"))
        .unwrap_or(base_url)
        .to_string()
}

/// Issue a buffered GET that returns the full response body in memory.
/// Suitable for small JSON payloads (manifests etc.); do not use for
/// the .ct payload itself — call `http_get_streaming` instead.
async fn http_get(
    base_url: &str,
    path: &str,
    auth_token: &str,
    range: Option<&str>,
) -> Result<(u16, Vec<u8>), String> {
    let mut stream = open_http_connection(base_url).await?;
    let request = build_get_request(base_url, path, auth_token, range);
    stream
        .write_all(request.as_bytes())
        .await
        .map_err(|e| format!("write request: {e}"))?;
    let (status, headers, mut buf) = read_response_headers(&mut stream).await?;
    let content_length = parse_content_length(&headers);

    // We may have already buffered some body bytes while scanning for
    // the end-of-headers sentinel.  Continue reading until we hit the
    // declared Content-Length (or EOF if the server didn't send one,
    // which is the case for HTTP/1.0 connection-close responses).
    let mut body = std::mem::take(&mut buf);
    let target = content_length.unwrap_or(usize::MAX);
    let mut tmp = [0u8; 16 * 1024];
    while body.len() < target {
        let n = match stream.read(&mut tmp).await {
            Ok(0) => break,
            Ok(n) => n,
            Err(e) => return Err(format!("read body: {e}")),
        };
        body.extend_from_slice(&tmp[..n]);
        if content_length.is_none() && n == 0 {
            break;
        }
    }
    if body.len() > target {
        body.truncate(target);
    }
    Ok((status, body))
}

/// Issue a GET and stream the response body to disk in 64 KiB chunks.
/// Returns the total number of bytes written.
async fn http_get_streaming(
    stream: &mut TcpStream,
    base_url: &str,
    path: &str,
    auth_token: &str,
    range: Option<&str>,
    dest_path: &Path,
) -> Result<u64, String> {
    let request = build_get_request(base_url, path, auth_token, range);
    stream
        .write_all(request.as_bytes())
        .await
        .map_err(|e| format!("write request: {e}"))?;

    let (status, headers, leftover) = read_response_headers(stream).await?;
    if !(200..300).contains(&status) {
        return Err(format!("gateway range fetch {path} returned HTTP {status}"));
    }
    let content_length = parse_content_length(&headers);

    // Open the destination file with a buffered writer to amortise
    // syscalls.  We use the blocking std::fs API inside spawn_blocking
    // pattern would be overkill for this code path — instead we keep
    // the writes synchronous and yield via tokio::task::yield_now to
    // play nice with the runtime.
    let file = std::fs::File::create(dest_path)
        .map_err(|e| format!("create {}: {e}", dest_path.display()))?;
    let mut writer = std::io::BufWriter::new(file);

    let mut total_written: u64 = 0;
    if !leftover.is_empty() {
        let to_write = match content_length {
            Some(cl) => leftover.len().min(cl),
            None => leftover.len(),
        };
        writer
            .write_all(&leftover[..to_write])
            .map_err(|e| format!("write {}: {e}", dest_path.display()))?;
        total_written += to_write as u64;
    }

    let target = content_length.unwrap_or(usize::MAX);
    let mut buf = vec![0u8; 64 * 1024];
    while (total_written as usize) < target {
        let want = (target - total_written as usize).min(buf.len());
        let n = match stream.read(&mut buf[..want]).await {
            Ok(0) => break,
            Ok(n) => n,
            Err(e) => return Err(format!("read body: {e}")),
        };
        writer
            .write_all(&buf[..n])
            .map_err(|e| format!("write {}: {e}", dest_path.display()))?;
        total_written += n as u64;
        if content_length.is_none() {
            // No Content-Length — read until EOF.  The condition above
            // is satisfied with target=usize::MAX, but we already break
            // on `Ok(0)` so this comment just documents intent.
        }
        // Cooperative yield every ~16 reads so long downloads don't
        // starve other tokio tasks.
        if total_written.is_multiple_of(buf.len() as u64 * 16) {
            tokio::task::yield_now().await;
        }
    }

    writer
        .flush()
        .map_err(|e| format!("flush {}: {e}", dest_path.display()))?;

    Ok(total_written)
}

fn build_get_request(base_url: &str, path: &str, auth_token: &str, range: Option<&str>) -> String {
    let host = host_from_base_url(base_url);
    let mut req = format!(
        "GET {path} HTTP/1.1\r\n\
         Host: {host}\r\n\
         User-Agent: codetracer-backend-manager/0.1\r\n\
         Accept: */*\r\n\
         Connection: close\r\n"
    );
    if !auth_token.is_empty() {
        req.push_str(&format!("Authorization: Bearer {auth_token}\r\n"));
    }
    if let Some(r) = range {
        req.push_str(&format!("Range: {r}\r\n"));
    }
    req.push_str("\r\n");
    req
}

/// Read response headers from `stream`.  Returns `(status, header_block,
/// leftover_body_bytes)` — `leftover_body_bytes` are any bytes that
/// followed the `\r\n\r\n` separator in the same buffer.
async fn read_response_headers(stream: &mut TcpStream) -> Result<(u16, String, Vec<u8>), String> {
    let mut buf: Vec<u8> = Vec::with_capacity(1024);
    let mut tmp = [0u8; 1024];
    loop {
        let n = stream
            .read(&mut tmp)
            .await
            .map_err(|e| format!("read headers: {e}"))?;
        if n == 0 {
            return Err("EOF while reading HTTP headers".to_string());
        }
        buf.extend_from_slice(&tmp[..n]);
        if let Some(sep) = find_subsequence(&buf, b"\r\n\r\n") {
            let header_bytes = buf[..sep].to_vec();
            let leftover = buf[sep + 4..].to_vec();
            let headers =
                String::from_utf8(header_bytes).map_err(|e| format!("non-utf8 headers: {e}"))?;
            let status = parse_status_line(&headers)?;
            return Ok((status, headers, leftover));
        }
        if buf.len() > 64 * 1024 {
            return Err("HTTP headers exceeded 64 KiB".to_string());
        }
    }
}

fn find_subsequence(haystack: &[u8], needle: &[u8]) -> Option<usize> {
    haystack.windows(needle.len()).position(|w| w == needle)
}

fn parse_status_line(headers: &str) -> Result<u16, String> {
    let first = headers.lines().next().ok_or("empty response")?;
    // HTTP/1.1 200 OK
    let mut parts = first.split_whitespace();
    let _version = parts.next();
    let code = parts.next().ok_or("missing status code")?;
    code.parse::<u16>()
        .map_err(|e| format!("bad status code '{code}': {e}"))
}

fn parse_content_length(headers: &str) -> Option<usize> {
    for line in headers.lines().skip(1) {
        let (k, v) = line.split_once(':')?;
        if k.eq_ignore_ascii_case("content-length") {
            return v.trim().parse::<usize>().ok();
        }
    }
    None
}

// ---------------------------------------------------------------------------
// URL helpers
// ---------------------------------------------------------------------------

fn url_decode(s: &str) -> String {
    let bytes = s.as_bytes();
    let mut out = Vec::with_capacity(bytes.len());
    let mut i = 0;
    while i < bytes.len() {
        match bytes[i] {
            b'+' => {
                out.push(b' ');
                i += 1;
            }
            b'%' if i + 2 < bytes.len() => {
                let hi = hex_val(bytes[i + 1]);
                let lo = hex_val(bytes[i + 2]);
                if let (Some(hi), Some(lo)) = (hi, lo) {
                    out.push((hi << 4) | lo);
                    i += 3;
                } else {
                    out.push(bytes[i]);
                    i += 1;
                }
            }
            b => {
                out.push(b);
                i += 1;
            }
        }
    }
    String::from_utf8_lossy(&out).into_owned()
}

fn hex_val(b: u8) -> Option<u8> {
    match b {
        b'0'..=b'9' => Some(b - b'0'),
        b'a'..=b'f' => Some(b - b'a' + 10),
        b'A'..=b'F' => Some(b - b'A' + 10),
        _ => None,
    }
}

fn url_encode_component(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    for b in s.bytes() {
        match b {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'_' | b'.' | b'~' => {
                out.push(b as char);
            }
            _ => out.push_str(&format!("%{b:02X}")),
        }
    }
    out
}

/// Map an arbitrary object key (e.g. `traces/foo/segments/seg_0.ct`) to a
/// filesystem-safe single path component.
fn vfs_safe_name(object_key: &str) -> String {
    object_key
        .chars()
        .map(|c| match c {
            'a'..='z' | 'A'..='Z' | '0'..='9' | '.' | '-' | '_' => c,
            _ => '_',
        })
        .collect()
}

/// Sanitise a trace id so it is safe to use as a single path component.
/// Trace ids are typically hex but we accept anything from the URL.
fn sanitize_for_path(trace_id: &str) -> String {
    let mut out = String::with_capacity(trace_id.len());
    for c in trace_id.chars() {
        match c {
            'a'..='z' | 'A'..='Z' | '0'..='9' | '-' | '_' => out.push(c),
            _ => out.push('_'),
        }
    }
    if out.is_empty() {
        out.push('_');
    }
    out
}

// ---------------------------------------------------------------------------
// Unit tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;
    use tokio::io::AsyncWriteExt;
    use tokio::net::TcpListener;

    #[test]
    fn looks_like_url_basic() {
        assert!(looks_like_url("http://example.com/foo"));
        assert!(looks_like_url("https://example.com/foo"));
        assert!(!looks_like_url("/tmp/trace"));
        assert!(!looks_like_url("file:///tmp/trace"));
        assert!(!looks_like_url(""));
    }

    #[test]
    fn parse_dive_in_url_extracts_trace_and_span() {
        let url =
            "http://127.0.0.1:36767/observability/v0/debug-session?trace_id=abc123&span_id=def456";
        let parsed = parse_dive_in_url(url).unwrap();
        assert_eq!(parsed.base_url, "http://127.0.0.1:36767");
        assert_eq!(parsed.trace_id, "abc123");
        assert_eq!(parsed.span_id, "def456");
        assert!(parsed.auth_token.is_none());
    }

    #[test]
    fn parse_dive_in_url_picks_up_auth_token() {
        let url =
            "http://host/observability/v0/debug-session?trace_id=t&span_id=s&authToken=secret%21";
        let parsed = parse_dive_in_url(url).unwrap();
        assert_eq!(parsed.auth_token.as_deref(), Some("secret!"));
    }

    #[test]
    fn parse_dive_in_url_rejects_missing_trace_id() {
        let err =
            parse_dive_in_url("http://host/observability/v0/debug-session?span_id=s").unwrap_err();
        assert!(err.contains("trace_id"), "err = {err}");
    }

    #[test]
    fn parse_dive_in_url_rejects_non_http() {
        assert!(parse_dive_in_url("/tmp/foo").is_err());
        assert!(parse_dive_in_url("file:///tmp/foo").is_err());
    }

    #[test]
    fn parse_dive_in_url_honours_gateway_base_url_override() {
        let url = "http://shell/?trace_id=t&gatewayBaseUrl=http%3A%2F%2Felsewhere%3A9999";
        let parsed = parse_dive_in_url(url).unwrap();
        assert_eq!(parsed.base_url, "http://elsewhere:9999");
    }

    #[test]
    fn url_decode_handles_percent_and_plus() {
        assert_eq!(url_decode("hello%20world"), "hello world");
        assert_eq!(url_decode("a+b"), "a b");
        assert_eq!(url_decode("100%25"), "100%");
    }

    #[test]
    fn list_manifest_object_keys_handles_both_layouts() {
        // Legacy mcrSlices.
        let m1 = json!({
            "mcrSlices": [
                {"sliceKey": "s1"},
                {"sliceKey": "s2"},
                {"sliceKey": ""},
            ]
        });
        assert_eq!(list_manifest_object_keys(&m1), vec!["s1", "s2"]);

        // Sharded segments.
        let m2 = json!({
            "shardedMcrSegments": [
                {"shards": [
                    {"replicas": [{"objectKey": "alpha"}, {"objectKey": "alpha-mirror"}]},
                    {"replicas": [{"objectKey": "beta"}]},
                    {"replicas": []},
                ]}
            ]
        });
        assert_eq!(list_manifest_object_keys(&m2), vec!["alpha", "beta"]);

        // Empty manifest returns no keys.
        assert!(list_manifest_object_keys(&json!({})).is_empty());
    }

    #[test]
    fn sanitize_for_path_strips_path_separators() {
        assert_eq!(sanitize_for_path("abc123"), "abc123");
        // Each `.` and `/` becomes `_`, then "etc" survives, then `/` -> `_`, then "passwd".
        assert_eq!(sanitize_for_path("../../etc/passwd"), "______etc_passwd");
        assert_eq!(sanitize_for_path(""), "_");
    }

    // -----------------------------------------------------------------
    // Integration-style tests: stand up a tiny HTTP/1.1 server backed
    // by a TcpListener and assert that fetch_recording_into_dir
    // produces byte-identical .ct content on disk.
    // -----------------------------------------------------------------

    /// Mock gateway state shared between the listener task and the test.
    struct MockGateway {
        trace_id: String,
        object_keys: Vec<String>,
        payloads: std::collections::HashMap<String, Vec<u8>>,
        expected_token: Option<String>,
    }

    async fn spawn_mock_gateway(
        trace_id: &str,
        object_keys: Vec<String>,
        payloads: std::collections::HashMap<String, Vec<u8>>,
        expected_token: Option<String>,
    ) -> std::net::SocketAddr {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = listener.local_addr().unwrap();
        let state = std::sync::Arc::new(MockGateway {
            trace_id: trace_id.to_string(),
            object_keys,
            payloads,
            expected_token,
        });

        tokio::spawn(async move {
            loop {
                let (mut socket, _) = match listener.accept().await {
                    Ok(s) => s,
                    Err(_) => break,
                };
                let state = std::sync::Arc::clone(&state);
                tokio::spawn(async move {
                    serve_one_connection(&mut socket, &state).await;
                });
            }
        });

        addr
    }

    async fn serve_one_connection(socket: &mut TcpStream, state: &MockGateway) {
        let mut buf = Vec::with_capacity(2048);
        let mut tmp = [0u8; 1024];
        loop {
            let n = match socket.read(&mut tmp).await {
                Ok(0) => return,
                Ok(n) => n,
                Err(_) => return,
            };
            buf.extend_from_slice(&tmp[..n]);
            if find_subsequence(&buf, b"\r\n\r\n").is_some() {
                break;
            }
            if buf.len() > 32 * 1024 {
                return;
            }
        }
        let request = String::from_utf8_lossy(&buf).to_string();
        let first_line = request.lines().next().unwrap_or("").to_string();
        let mut parts = first_line.split_whitespace();
        let _method = parts.next();
        let target = parts.next().unwrap_or("").to_string();

        // Auth check.
        if let Some(expected) = &state.expected_token {
            let want = format!("Authorization: Bearer {expected}");
            if !request
                .lines()
                .any(|l| l.eq_ignore_ascii_case(&want) || l.trim_end().eq_ignore_ascii_case(&want))
            {
                let body = b"missing token";
                write_response(socket, 401, "application/octet-stream", body).await;
                return;
            }
        }

        let manifest_prefix = format!("/api/v1/observability/gateway/manifests/{}", state.trace_id);
        let ranges_prefix = format!("/api/v1/observability/gateway/ranges/{}/", state.trace_id);
        if target == manifest_prefix {
            let manifest = json!({
                "recordingId": "rec-1",
                "recordingManifest": {
                    "mcrSlices": state.object_keys.iter().map(|k| json!({"sliceKey": k})).collect::<Vec<_>>(),
                },
            });
            let body = serde_json::to_vec(&manifest).unwrap();
            write_response(socket, 200, "application/json", &body).await;
        } else if let Some(rest) = target.strip_prefix(&ranges_prefix) {
            let object_key = url_decode(rest);
            match state.payloads.get(&object_key) {
                Some(bytes) => {
                    let total = bytes.len();
                    let range = parse_request_range(&request, total);
                    match range {
                        Some((start, end)) => {
                            let slice = &bytes[start..=end];
                            let content_range = format!("bytes {start}-{end}/{total}");
                            write_partial_response(socket, slice, &content_range).await;
                        }
                        None => {
                            write_response(socket, 200, "application/octet-stream", bytes).await;
                        }
                    }
                }
                None => {
                    write_response(socket, 404, "text/plain", b"not found").await;
                }
            }
        } else {
            write_response(socket, 404, "text/plain", b"not found").await;
        }
    }

    fn parse_request_range(request: &str, total: usize) -> Option<(usize, usize)> {
        for line in request.lines().skip(1) {
            let (k, v) = line.split_once(':')?;
            if k.eq_ignore_ascii_case("range") {
                let v = v.trim().strip_prefix("bytes=")?;
                let (start_s, end_s) = v.split_once('-')?;
                let start: usize = start_s.parse().ok()?;
                let end: usize = if end_s.is_empty() {
                    total.saturating_sub(1)
                } else {
                    end_s.parse().ok()?
                };
                return Some((start, end.min(total.saturating_sub(1))));
            }
        }
        None
    }

    async fn write_response(socket: &mut TcpStream, status: u16, mime: &str, body: &[u8]) {
        let reason = match status {
            200 => "OK",
            206 => "Partial Content",
            401 => "Unauthorized",
            404 => "Not Found",
            _ => "Generic",
        };
        let head = format!(
            "HTTP/1.1 {status} {reason}\r\n\
             Content-Type: {mime}\r\n\
             Content-Length: {}\r\n\
             Connection: close\r\n\r\n",
            body.len()
        );
        let _ = socket.write_all(head.as_bytes()).await;
        let _ = socket.write_all(body).await;
        let _ = socket.shutdown().await;
    }

    async fn write_partial_response(socket: &mut TcpStream, body: &[u8], content_range: &str) {
        let head = format!(
            "HTTP/1.1 206 Partial Content\r\n\
             Content-Type: application/octet-stream\r\n\
             Content-Length: {}\r\n\
             Content-Range: {content_range}\r\n\
             Accept-Ranges: bytes\r\n\
             Connection: close\r\n\r\n",
            body.len()
        );
        let _ = socket.write_all(head.as_bytes()).await;
        let _ = socket.write_all(body).await;
        let _ = socket.shutdown().await;
    }

    #[tokio::test]
    async fn fetch_recording_into_dir_writes_byte_identical_files() {
        let trace_id = "abcdef0123";
        let payload_a = (0u8..=255).cycle().take(150_000).collect::<Vec<u8>>();
        let payload_b = b"second slice payload".to_vec();
        let mut payloads = std::collections::HashMap::new();
        payloads.insert("traces/a/trace.ct".to_string(), payload_a.clone());
        payloads.insert("traces/a/secondary.bin".to_string(), payload_b.clone());

        let addr = spawn_mock_gateway(
            trace_id,
            vec![
                "traces/a/trace.ct".to_string(),
                "traces/a/secondary.bin".to_string(),
            ],
            payloads,
            None,
        )
        .await;

        let dest = std::env::temp_dir().join(format!("ct-fetch-test-{}", std::process::id()));
        let _ = tokio::fs::remove_dir_all(&dest).await;
        tokio::fs::create_dir_all(&dest).await.unwrap();

        let base = format!("http://{addr}");
        let keys = fetch_recording_into_dir(&base, trace_id, "", &dest)
            .await
            .unwrap();
        assert_eq!(keys.len(), 2);

        // First key always lands at the canonical `trace.ct` name.
        let canonical = std::fs::read(dest.join("trace.ct")).unwrap();
        assert_eq!(canonical, payload_a);

        // Second key uses a sanitized variant.
        let secondary_name = format!("{}.bin", vfs_safe_name("traces/a/secondary.bin"));
        let secondary = std::fs::read(dest.join(&secondary_name)).unwrap();
        assert_eq!(secondary, payload_b);

        let _ = tokio::fs::remove_dir_all(&dest).await;
    }

    #[tokio::test]
    async fn fetch_recording_from_dive_in_url_caches_and_short_circuits() {
        let trace_id = "cache-test-trace";
        let payload = b"hello-codetracer".to_vec();
        let mut payloads = std::collections::HashMap::new();
        payloads.insert("only.ct".to_string(), payload.clone());

        let addr = spawn_mock_gateway(
            trace_id,
            vec!["only.ct".to_string()],
            payloads,
            Some("tok-42".to_string()),
        )
        .await;

        // Redirect the cache to a temp dir for this test only.
        let tmp = std::env::temp_dir().join(format!("ct-fetch-cache-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&tmp);
        // SAFETY: tests in the same module run serially because they
        // both set the same env var.  We isolate per-test by including
        // pid in the dir.
        unsafe {
            std::env::set_var("CODETRACER_TRACE_CACHE_DIR", &tmp);
        }

        let url = format!(
            "http://{addr}/observability/v0/debug-session?trace_id={trace_id}&span_id=sp&authToken=tok-42",
        );

        let r1 = fetch_recording_from_dive_in_url(&url).await.unwrap();
        assert!(!r1.from_cache);
        assert_eq!(r1.trace_id, trace_id);
        assert_eq!(r1.span_id, "sp");
        assert_eq!(
            std::fs::read(r1.local_path.join("trace.ct")).unwrap(),
            payload
        );

        // Drop the mock listener by clearing the env var: the next call
        // must come purely from the cache.
        let r2 = fetch_recording_from_dive_in_url(&url).await.unwrap();
        assert!(r2.from_cache);
        assert_eq!(r2.local_path, r1.local_path);

        let _ = std::fs::remove_dir_all(&tmp);
        unsafe {
            std::env::remove_var("CODETRACER_TRACE_CACHE_DIR");
        }
    }

    #[tokio::test]
    async fn fetch_recording_propagates_auth_failure() {
        let trace_id = "auth-test";
        let payloads = std::collections::HashMap::new();
        let addr = spawn_mock_gateway(
            trace_id,
            vec!["only.ct".to_string()],
            payloads,
            Some("good-token".to_string()),
        )
        .await;

        let dest = std::env::temp_dir().join(format!("ct-fetch-auth-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dest);
        std::fs::create_dir_all(&dest).unwrap();

        let base = format!("http://{addr}");
        let err = fetch_recording_into_dir(&base, trace_id, "wrong-token", &dest)
            .await
            .unwrap_err();
        assert!(
            err.contains("401") || err.contains("missing token"),
            "err={err}"
        );

        let _ = std::fs::remove_dir_all(&dest);
    }
}
