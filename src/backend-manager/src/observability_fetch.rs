//! Observability dive-in URL → local trace directory bridge.
//!
//! When `backend-manager` is asked to operate on a trace identified by an
//! observability "dive-in URL" (instead of a local `.ct` path), this
//! module fetches the recording bytes from the CodeTracer-CI gateway and
//! materialises them into a local trace directory under
//! `$XDG_CACHE_HOME/codetracer/traces/<recording-id>/`.  After the fetch
//! completes, the rest of the backend-manager pipeline (daemon, DAP,
//! Python bridge) operates on the cached directory unchanged.
//!
//! # Dive-in URL shape
//!
//! Dive-in URLs are produced by `ct-observe` and embedded in observability
//! tooling.  Example:
//!
//!   http://127.0.0.1:36767/observability/v0/debug-session?recording_id=<RID>&trace_id=<TID>&span_id=<SID>
//!
//! The host part is the CodeTracer-CI base URL; the gateway range API
//! lives under the same origin at:
//!
//!   GET <base>/api/v1/observability/gateway/manifests/<id>      -> JSON
//!   GET <base>/api/v1/observability/gateway/ranges/<id>/<key>   -> bytes
//!
//! `<id>` is the URL's `recording_id` when it carries one, else (the v0
//! link shape, `docs/attribute-url-contract-v0.md`) its `trace_id`.  The
//! gateway addresses a recording by codetracer-ci's own recording id.
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
//! # Which host is fetched from
//!
//! A dive-in URL usually comes from span data, and span data is written by
//! whoever can send spans, so the URL is not trusted to name the gateway.
//! The gateway is configured instead: `CODETRACER_CI_BASE_URL` names the
//! codetracer-ci origin (`scheme://host[:port]`), the same variable that
//! names it to the OpenTelemetry adapter emitting the links.  A dive-in URL
//! is fetched only when its own origin, and its `gatewayBaseUrl` parameter
//! when present, are that origin: scheme, host and port compared after
//! lower-casing the scheme and host and filling in the scheme's default
//! port, with no DNS resolution (an alias of the host is another origin).
//! Any other URL is refused before a connection is opened, and with the
//! variable unset every dive-in URL is refused.  The client follows no
//! redirects, so the configured origin is the only host that is contacted
//! (RFC 6454 §4 defines the origin of a URI).
//!
//! # Authentication
//!
//! The gateway requires an authenticated caller, `Authorization: Bearer
//! <token>`, and reads a recording for a caller that may read it.  A
//! codetracer-ci share link for the recording (a Trace link with download
//! permission) grants that through `X-Share-Token`.  The bearer token comes
//! from the URL's `authToken` or `auth_token` parameter, else
//! `CODETRACER_GATEWAY_TOKEN`, else none; the share token from the URL's
//! `shareToken` or `share_token` parameter (codetracer-ci's own name for
//! it), else `CODETRACER_GATEWAY_SHARE_TOKEN`, else none.  Both must be RFC
//! 6750 §2.1 `b64token`s, checked before any connection, so neither can
//! add a header line; both are sent only to the configured gateway origin,
//! and no error echoes them ([`redact_url`]).
//!
//! # Response size
//!
//! The manifest response may be at most [`MAX_MANIFEST_BYTES`] and the
//! payloads of one recording together at most [`MAX_RECORDING_BYTES`],
//! counted in decoded bytes (a chunked body is decoded, RFC 9112 §7.1).  A
//! declared `Content-Length` or chunk size above what is left is refused
//! before its data is read, a body that runs past it is cut off with an
//! error, and a fetch that fails removes its partial cache directory.
//!
//! # Cache key
//!
//! The recording id (a canonical UUID) is the cache key, so two
//! recordings of one OpenTelemetry trace get two directories and every
//! span of one recording shares one.  A link without a recording id (the
//! v0 shape) is cached under `otel-trace-<trace id>`, sanitised to one path
//! component; no recording id has that prefix.
//!
//! # Streaming
//!
//! Each range response is streamed to disk through a buffered writer in
//! 64 KiB chunks; we never hold a full recording in RAM.

use std::fmt;
use std::io::Write;
use std::path::{Path, PathBuf};
use std::time::Duration;

use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::TcpStream;

// ---------------------------------------------------------------------------
// Public surface
// ---------------------------------------------------------------------------

/// Environment variable naming the codetracer-ci origin that dive-in URLs
/// may be fetched from (and the gateway token sent to).
pub const GATEWAY_BASE_URL_ENV: &str = "CODETRACER_CI_BASE_URL";

/// Environment variable holding the gateway bearer token, used when the
/// dive-in URL carries none.
pub const GATEWAY_TOKEN_ENV: &str = "CODETRACER_GATEWAY_TOKEN";

/// Environment variable holding a codetracer-ci share token, used when the
/// dive-in URL carries none.
pub const GATEWAY_SHARE_TOKEN_ENV: &str = "CODETRACER_GATEWAY_SHARE_TOKEN";

/// The header codetracer-ci reads a share token from (its `ShareToken`).
const SHARE_TOKEN_HEADER: &str = "X-Share-Token";

/// Query parameters of a dive-in URL that carry a credential.  Their values
/// are never echoed in an error (see [`redact_url`]).  `token` is the
/// codetracer-ci share link's legacy parameter name.
const CREDENTIAL_PARAMETERS: [&str; 5] = [
    "authToken",
    "auth_token",
    "shareToken",
    "share_token",
    "token",
];

/// The credentials a fetch sends to the configured gateway: the bearer
/// token, which authenticates the caller, and optionally a codetracer-ci
/// share token, which authorizes reading the one recording its share link
/// names.  Both are checked against the RFC 6750 §2.1 `b64token` syntax
/// when built, so neither can add a header line or split the request.
#[derive(Clone, PartialEq, Eq)]
pub struct GatewayCredentials {
    bearer: String,
    share_token: Option<String>,
}

impl fmt::Debug for GatewayCredentials {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        // Never print a credential.
        f.debug_struct("GatewayCredentials")
            .field("bearer", &(!self.bearer.is_empty()))
            .field("share_token", &self.share_token.is_some())
            .finish()
    }
}

impl GatewayCredentials {
    /// `bearer` may be empty (no `Authorization` header is sent).
    pub fn new(bearer: &str, share_token: Option<&str>) -> Result<GatewayCredentials, String> {
        if !bearer.is_empty() {
            check_b64token("the gateway token", bearer)?;
        }
        if let Some(share) = share_token {
            check_b64token("the share token", share)?;
        }
        Ok(GatewayCredentials {
            bearer: bearer.to_string(),
            share_token: share_token.map(str::to_string),
        })
    }
}

/// RFC 6750 §2.1: `b64token = 1*( ALPHA / DIGIT / "-" / "." / "_" / "~" /
/// "+" / "/" ) *"="`.  The error names the credential, never its value.
fn check_b64token(what: &str, value: &str) -> Result<(), String> {
    let body = value.trim_end_matches('=');
    let valid = !body.is_empty()
        && body.bytes().all(|b| {
            b.is_ascii_alphanumeric() || matches!(b, b'-' | b'.' | b'_' | b'~' | b'+' | b'/')
        });
    if valid {
        Ok(())
    } else {
        Err(format!(
            "refusing {what}: it is not an RFC 6750 b64token (letters, digits, \"-._~+/\" and \
             trailing \"=\" only)"
        ))
    }
}

/// Largest manifest response accepted from the gateway (16 MiB).  A
/// recording manifest lists object keys; it is kilobytes in practice.
pub const MAX_MANIFEST_BYTES: u64 = 16 * 1024 * 1024;

/// Largest total size of the payloads fetched for one recording (16 GiB),
/// so a gateway answer cannot fill the disk the cache lives on.
pub const MAX_RECORDING_BYTES: u64 = 16 * 1024 * 1024 * 1024;

/// How long a read from the gateway may wait for its next bytes.  A gateway
/// that accepts the connection and then goes silent fails the fetch instead
/// of holding the tool call forever.
/// (Two seconds in unit tests, so the silent-gateway test is quick.)
const READ_IDLE_TIMEOUT: Duration = if cfg!(test) {
    Duration::from_secs(2)
} else {
    Duration::from_secs(60)
};

/// How many bytes of a refused gateway response body an error quotes.
const ERROR_BODY_QUOTE_BYTES: usize = 512;

/// The origin of a URL (RFC 6454 §4): scheme, host and port.
///
/// The scheme and host are lower-cased and the port is always explicit
/// (the scheme's default when the URL names none), so two spellings of the
/// same origin compare equal.  No DNS resolution is involved: a different
/// name for the same address is a different origin.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Origin {
    scheme: String,
    host: String,
    port: u16,
}

impl Origin {
    /// Parse a base URL that consists of an origin only:
    /// `scheme://host[:port]`, optionally followed by a single `/`.
    ///
    /// A path, query or fragment is refused, because codetracer-ci serves
    /// its routes at the root of its host
    /// (`docs/attribute-url-contract-v0.md`).
    pub fn parse_base_url(value: &str) -> Result<Origin, String> {
        let (origin, rest) = split_origin(value)?;
        if !(rest.is_empty() || rest == "/") {
            return Err(format!(
                "{value:?} is not an origin (scheme://host[:port]): it carries a path, query or fragment"
            ));
        }
        Ok(origin)
    }

    /// `host[:port]`, with the port left out when it is the scheme's
    /// default: the value of an HTTP `Host` header.
    fn authority(&self) -> String {
        if self.port == default_port(&self.scheme) {
            self.host.clone()
        } else {
            format!("{}:{}", self.host, self.port)
        }
    }

    /// `host:port`, always with the port: what `TcpStream::connect` takes.
    fn socket_address(&self) -> String {
        format!("{}:{}", self.host, self.port)
    }
}

impl fmt::Display for Origin {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{}://{}", self.scheme, self.authority())
    }
}

/// The gateway origin configured through [`GATEWAY_BASE_URL_ENV`].
///
/// Unset or empty is an error: with no configured gateway no dive-in URL
/// is fetched, since the URL itself cannot be trusted to name one.
pub fn configured_gateway() -> Result<Origin, String> {
    match std::env::var(GATEWAY_BASE_URL_ENV) {
        Ok(value) if !value.trim().is_empty() => {
            Origin::parse_base_url(value.trim()).map_err(|e| format!("{GATEWAY_BASE_URL_ENV}: {e}"))
        }
        _ => Err(format!(
            "no gateway is configured: set {GATEWAY_BASE_URL_ENV} to the codetracer-ci origin \
             (scheme://host[:port]) that dive-in URLs may be fetched from"
        )),
    }
}

/// Refuse a dive-in URL that names any origin other than `gateway`, either
/// as its own origin or through its `gatewayBaseUrl` parameter.
///
/// This is what keeps the bearer token on the configured gateway: the
/// fetch connects only after this check passes.
pub fn check_gateway_origin(parsed: &DiveInUrl, gateway: &Origin) -> Result<(), String> {
    if parsed.origin != *gateway {
        return Err(format!(
            "refusing the dive-in URL: its origin {} is not the configured gateway {gateway} \
             ({GATEWAY_BASE_URL_ENV}); the gateway token is sent to that origin only",
            parsed.origin
        ));
    }
    if let Some(named) = &parsed.gateway_base_url
        && named != gateway
    {
        return Err(format!(
            "refusing the dive-in URL: its gatewayBaseUrl {named} is not the configured gateway \
             {gateway} ({GATEWAY_BASE_URL_ENV}); the gateway token is sent to that origin only"
        ));
    }
    Ok(())
}

/// Result of fetching a recording from a dive-in URL.
#[derive(Debug, Clone)]
pub struct FetchedRecording {
    /// On-disk directory containing the materialised `.ct` payloads.
    /// Suitable for passing into `ct/open-trace` directly.
    pub local_path: PathBuf,
    /// The recording id extracted from the dive-in URL, when it carries one.
    pub recording_id: Option<String>,
    /// The trace id extracted from the dive-in URL (may be empty when the
    /// URL names a recording id).
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
    /// The URL's own origin, e.g. `http://127.0.0.1:36767`.
    pub origin: Origin,
    /// The origin named by the `gatewayBaseUrl` (or `gateway_base_url`)
    /// query parameter, when the URL carries one.
    pub gateway_base_url: Option<Origin>,
    /// `recording_id` query parameter: the recording to fetch, a canonical
    /// (lower-case, hyphenated) UUID.
    pub recording_id: Option<String>,
    /// `trace_id` query parameter (may be empty when `recording_id` is set).
    pub trace_id: String,
    /// `span_id` query parameter (may be empty).
    pub span_id: String,
    /// Optional bearer token harvested from the URL query string.
    pub auth_token: Option<String>,
    /// Optional codetracer-ci share token (`shareToken` or `share_token`).
    pub share_token: Option<String>,
}

impl DiveInUrl {
    /// The id the gateway is asked for: the recording id when the URL
    /// carries one, else (the v0 link shape) the trace id.
    pub fn gateway_id(&self) -> &str {
        self.recording_id.as_deref().unwrap_or(&self.trace_id)
    }

    /// The cache directory name: the recording id, or for a link without
    /// one `otel-trace-<trace id>`, so the two never share a directory
    /// (a recording id is a UUID, which never starts with `otel-`).
    fn cache_key(&self) -> String {
        match &self.recording_id {
            Some(recording_id) => recording_id.clone(),
            None => format!("otel-trace-{}", sanitize_for_path(&self.trace_id)),
        }
    }
}

/// `url` with the values of its credential parameters, any user
/// information and any fragment replaced, for error messages.
pub fn redact_url(url: &str) -> String {
    let (before_fragment, had_fragment) = match url.split_once('#') {
        Some((before, _)) => (before, true),
        None => (url, false),
    };
    let (head, query) = match before_fragment.split_once('?') {
        Some((head, query)) => (head, Some(query)),
        None => (before_fragment, None),
    };
    // User information: everything between `://` and the last `@` before
    // the path.
    let head = match head.split_once("://") {
        Some((scheme, rest)) => {
            let authority_end = rest.find('/').unwrap_or(rest.len());
            match rest[..authority_end].rfind('@') {
                Some(at) => format!("{scheme}://<redacted>@{}", &rest[at + 1..]),
                None => head.to_string(),
            }
        }
        None => head.to_string(),
    };
    let mut out = head;
    if let Some(query) = query {
        let pairs: Vec<String> = query
            .split('&')
            .map(|pair| {
                let key = pair.split_once('=').map_or(pair, |(k, _)| k);
                if CREDENTIAL_PARAMETERS
                    .iter()
                    .any(|c| url_decode(key).eq_ignore_ascii_case(c))
                {
                    format!("{key}=<redacted>")
                } else {
                    pair.to_string()
                }
            })
            .collect();
        out.push('?');
        out.push_str(&pairs.join("&"));
    }
    if had_fragment {
        out.push_str("#<redacted>");
    }
    out
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
/// Returns an `Err` if the URL is malformed or missing `trace_id`.  The
/// authority must be a host name, IPv4 address or bracketed IPv6 literal
/// and an optional port: user information (`user@host`) and
/// percent-encoded hosts are refused, so the origin compared against the
/// configured gateway is the host a connection would reach.
///
/// Parsing decides nothing about trust; [`check_gateway_origin`] does.
pub fn parse_dive_in_url(url: &str) -> Result<DiveInUrl, String> {
    if !looks_like_url(url) {
        return Err(format!("not an http(s) URL: {}", redact_url(url)));
    }

    let (origin, after_authority) = split_origin(url)?;
    // A fragment is never sent to a server; drop it before the query.
    let without_fragment = after_authority
        .split_once('#')
        .map_or(after_authority, |(before, _)| before);
    let query = without_fragment
        .split_once('?')
        .map_or("", |(_, query)| query);

    // Decode query parameters.
    let mut recording_id: Option<String> = None;
    let mut trace_id = String::new();
    let mut span_id = String::new();
    let mut auth_token: Option<String> = None;
    let mut share_token: Option<String> = None;
    let mut gateway_base_url: Option<Origin> = None;
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
            "recording_id" | "recordingId" if !v.is_empty() => {
                recording_id = Some(canonical_uuid(&v).ok_or_else(|| {
                    format!(
                        "dive-in URL's recording_id is not a hyphenated UUID: {}",
                        redact_url(url)
                    )
                })?);
            }
            "trace_id" | "traceId" => trace_id = v,
            "span_id" | "spanId" => span_id = v,
            "authToken" | "auth_token" if !v.is_empty() => auth_token = Some(v),
            "shareToken" | "share_token" if !v.is_empty() => share_token = Some(v),
            "gatewayBaseUrl" | "gateway_base_url" if !v.is_empty() => {
                gateway_base_url = Some(
                    Origin::parse_base_url(&v)
                        .map_err(|e| format!("dive-in URL has a malformed gatewayBaseUrl: {e}"))?,
                );
            }
            _ => {}
        }
    }

    if trace_id.is_empty() && recording_id.is_none() {
        return Err(format!(
            "dive-in URL names neither a `recording_id` nor a `trace_id`: {}",
            redact_url(url)
        ));
    }

    Ok(DiveInUrl {
        origin,
        gateway_base_url,
        recording_id,
        trace_id,
        span_id,
        auth_token,
        share_token,
    })
}

/// Fetch the recording for a dive-in URL into the local cache.
///
/// On cache hit the function returns immediately without touching the
/// network.  Cache layout:
///
/// ```text
///   $XDG_CACHE_HOME/codetracer/traces/<recording-id or otel-trace-<trace-id>>/
///       trace.ct                  # primary CTFS container (always at this name)
///       <object-key>.bin          # additional payloads, if any
///       .complete                 # sentinel written after a successful fetch
/// ```
///
/// The `.complete` sentinel is what distinguishes a finished cache entry
/// from a partial / interrupted one — partials are torn down and re-fetched.
///
/// The gateway is the origin [`configured_gateway`] names; a URL naming any
/// other origin is refused before the cache or the network is touched.
pub async fn fetch_recording_from_dive_in_url(url: &str) -> Result<FetchedRecording, String> {
    let gateway = configured_gateway()?;
    fetch_recording_from_dive_in_url_via(url, &gateway).await
}

/// [`fetch_recording_from_dive_in_url`] with the gateway origin given
/// explicitly instead of read from the environment.
pub async fn fetch_recording_from_dive_in_url_via(
    url: &str,
    gateway: &Origin,
) -> Result<FetchedRecording, String> {
    let parsed = parse_dive_in_url(url)?;
    // Before the cache too: a refused URL must not reach a recording that
    // an earlier, accepted URL fetched.
    check_gateway_origin(&parsed, gateway)?;
    // The credentials too, so a malformed one is refused the same way
    // whether or not the recording is cached.
    let bearer = parsed
        .auth_token
        .clone()
        .or_else(|| std::env::var(GATEWAY_TOKEN_ENV).ok())
        .unwrap_or_default();
    let share_token = parsed.share_token.clone().or_else(|| {
        std::env::var(GATEWAY_SHARE_TOKEN_ENV)
            .ok()
            .filter(|v| !v.is_empty())
    });
    let credentials = GatewayCredentials::new(&bearer, share_token.as_deref())?;
    let cache_dir = cache_root().join(parsed.cache_key());

    if has_complete_marker(&cache_dir).await {
        let object_keys = read_object_keys_metadata(&cache_dir)
            .await
            .unwrap_or_default();
        return Ok(FetchedRecording {
            local_path: cache_dir,
            recording_id: parsed.recording_id,
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

    let object_keys = match fetch_recording_into_dir(
        gateway,
        parsed.gateway_id(),
        &credentials,
        &cache_dir,
    )
    .await
    {
        Ok(keys) => keys,
        Err(e) => {
            // Do not leave a partial (possibly large) download behind.
            let _ = tokio::fs::remove_dir_all(&cache_dir).await;
            return Err(e);
        }
    };

    // Persist the object keys for diagnostics on cache hits.
    write_object_keys_metadata(&cache_dir, &object_keys).await?;

    // Mark the cache entry complete only after every write succeeded.
    tokio::fs::write(cache_dir.join(".complete"), b"ok")
        .await
        .map_err(|e| format!("failed to write .complete sentinel: {e}"))?;

    Ok(FetchedRecording {
        local_path: cache_dir,
        recording_id: parsed.recording_id,
        trace_id: parsed.trace_id,
        span_id: parsed.span_id,
        object_keys,
        from_cache: false,
    })
}

/// Low-level entry point used by tests: fetch the recording into an
/// explicit directory rather than the user's cache.  Bypasses the
/// `.complete` sentinel — the caller is responsible for atomicity.
///
/// `gateway` is trusted as given: callers holding a URL check it with
/// [`check_gateway_origin`] first.
pub async fn fetch_recording_into_dir(
    gateway: &Origin,
    trace_id: &str,
    credentials: &GatewayCredentials,
    dest_dir: &Path,
) -> Result<Vec<String>, String> {
    fetch_recording_into_dir_limited(
        gateway,
        trace_id,
        credentials,
        dest_dir,
        FetchLimits::DEFAULT,
    )
    .await
}

/// Size limits of one recording fetch (see "Response size" above).
#[derive(Debug, Clone, Copy)]
struct FetchLimits {
    manifest_bytes: u64,
    recording_bytes: u64,
}

impl FetchLimits {
    const DEFAULT: FetchLimits = FetchLimits {
        manifest_bytes: MAX_MANIFEST_BYTES,
        recording_bytes: MAX_RECORDING_BYTES,
    };
}

async fn fetch_recording_into_dir_limited(
    gateway: &Origin,
    trace_id: &str,
    credentials: &GatewayCredentials,
    dest_dir: &Path,
    limits: FetchLimits,
) -> Result<Vec<String>, String> {
    // 1. Fetch the manifest.
    let manifest_path = format!(
        "/api/v1/observability/gateway/manifests/{}",
        url_encode_component(trace_id)
    );
    let (status, manifest_bytes) = http_get(
        gateway,
        &manifest_path,
        credentials,
        None,
        limits.manifest_bytes,
    )
    .await?;
    if !(200..300).contains(&status) {
        let quoted = &manifest_bytes[..manifest_bytes.len().min(ERROR_BODY_QUOTE_BYTES)];
        let body = String::from_utf8_lossy(quoted);
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
    let mut budget = limits.recording_bytes;
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

        let mut stream = open_http_connection(gateway).await?;
        let bytes = http_get_streaming(
            &mut stream,
            gateway,
            &range_path,
            credentials,
            Some("bytes=0-"),
            &dest_file,
            &mut budget,
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
    // `$CODETRACER_HOME/cache/traces` relocates it with every other per-user
    // location (`ct_home`).
    if let Some(cache) = ct_home::area(ct_home::Area::Cache) {
        return cache.join("traces");
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
// `Range: bytes=...`, response status, and a response body delimited by
// `Content-Length`, `Transfer-Encoding: chunked` (decoded, RFC 9112 §7.1,
// with `httparse` parsing the chunk-size line) or the end of the connection.
// Redirects are not followed.  HTTPS is not supported: fetching from an
// `https://` gateway returns an explicit error so callers can fall back to
// other tooling.

async fn open_http_connection(gateway: &Origin) -> Result<TcpStream, String> {
    if gateway.scheme != "http" {
        return Err(format!(
            "HTTPS dive-in URLs are not yet supported by backend-manager's gateway fetcher \
             (gateway {gateway}); use ct-observe (which can call out to HTTPS gateways via \
             system curl) or configure an HTTP gateway origin in {GATEWAY_BASE_URL_ENV}"
        ));
    }
    let host_port = gateway.socket_address();
    let connect = tokio::time::timeout(Duration::from_secs(10), TcpStream::connect(&host_port))
        .await
        .map_err(|_| format!("timeout connecting to {host_port}"))?;
    connect.map_err(|e| format!("connect {host_port}: {e}"))
}

/// Issue a buffered GET that returns the full (decoded) response body in
/// memory, refusing a body over `limit` bytes.  Suitable for small JSON
/// payloads (manifests etc.); do not use for the .ct payload itself; call
/// `http_get_streaming` instead.
async fn http_get(
    gateway: &Origin,
    path: &str,
    credentials: &GatewayCredentials,
    range: Option<&str>,
    limit: u64,
) -> Result<(u16, Vec<u8>), String> {
    let mut stream = open_http_connection(gateway).await?;
    let request = build_get_request(gateway, path, credentials, range);
    stream
        .write_all(request.as_bytes())
        .await
        .map_err(|e| format!("write request: {e}"))?;
    let (status, headers, leftover) = read_response_headers(&mut stream).await?;
    let framing = body_framing(&headers)?;
    let mut body = Vec::new();
    read_body(
        &mut stream,
        leftover,
        framing,
        limit,
        path,
        &mut |bytes: &[u8]| {
            body.extend_from_slice(bytes);
            Ok(())
        },
    )
    .await?;
    Ok((status, body))
}

/// Issue a GET and stream the (decoded) response body to disk.  Returns the
/// number of bytes written, which is also taken from `budget`; a body larger
/// than what is left of `budget` is refused (before reading when its
/// `Content-Length` or a chunk size says so, otherwise when it runs past).
async fn http_get_streaming(
    stream: &mut TcpStream,
    gateway: &Origin,
    path: &str,
    credentials: &GatewayCredentials,
    range: Option<&str>,
    dest_path: &Path,
    budget: &mut u64,
) -> Result<u64, String> {
    let request = build_get_request(gateway, path, credentials, range);
    stream
        .write_all(request.as_bytes())
        .await
        .map_err(|e| format!("write request: {e}"))?;

    let (status, headers, leftover) = read_response_headers(stream).await?;
    if !(200..300).contains(&status) {
        return Err(format!("gateway range fetch {path} returned HTTP {status}"));
    }
    let framing = body_framing(&headers)?;
    if let BodyFraming::Length(declared) = framing
        && declared > *budget
    {
        return Err(over_limit(path, declared, *budget));
    }

    // The writes are synchronous through a buffered writer; `read_body`
    // yields to the runtime between socket reads.
    let file = std::fs::File::create(dest_path)
        .map_err(|e| format!("create {}: {e}", dest_path.display()))?;
    let mut writer = std::io::BufWriter::new(file);
    let total_written = read_body(
        stream,
        leftover,
        framing,
        *budget,
        path,
        &mut |bytes: &[u8]| {
            writer
                .write_all(bytes)
                .map_err(|e| format!("write {}: {e}", dest_path.display()))
        },
    )
    .await?;
    writer
        .flush()
        .map_err(|e| format!("flush {}: {e}", dest_path.display()))?;

    *budget -= total_written;
    Ok(total_written)
}

/// How a response body is delimited (RFC 9112 §6.3).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum BodyFraming {
    /// `Content-Length` bytes.
    Length(u64),
    /// `Transfer-Encoding: chunked` (RFC 9112 §7.1).
    Chunked,
    /// Neither header: the body ends when the server closes the connection.
    UntilClose,
}

/// The longest chunk-size line accepted (the size, extensions and CRLF).
/// RFC 9112 sets no limit; a size line has no business being long, and an
/// unbounded one would be read into memory.
const MAX_CHUNK_SIZE_LINE: usize = 1024;

/// The most trailer-section bytes accepted after the last chunk.
const MAX_CHUNK_TRAILER_BYTES: usize = 16 * 1024;

/// Decide the body's framing from the response headers (RFC 9112 §6.3):
/// `Transfer-Encoding` wins over `Content-Length`; its only coding this
/// client decodes is a lone `chunked`, and any other is refused rather than
/// passed through as if it were the body.  A malformed or contradictory
/// `Content-Length` is refused too.
fn body_framing(headers: &str) -> Result<BodyFraming, String> {
    let codings: Vec<String> = header_values(headers, "transfer-encoding")
        .iter()
        .flat_map(|v| v.split(','))
        .map(|c| c.trim().to_ascii_lowercase())
        .filter(|c| !c.is_empty())
        .collect();
    if !codings.is_empty() {
        return if codings == ["chunked"] {
            Ok(BodyFraming::Chunked)
        } else {
            Err(format!(
                "unsupported Transfer-Encoding {:?}: only chunked is decoded",
                codings.join(", ")
            ))
        };
    }
    let lengths = header_values(headers, "content-length");
    let Some(first) = lengths.first() else {
        return Ok(BodyFraming::UntilClose);
    };
    let parse = |v: &str| {
        let v = v.trim();
        if v.is_empty() || !v.bytes().all(|b| b.is_ascii_digit()) {
            return Err(format!("malformed Content-Length {v:?}"));
        }
        v.parse::<u64>()
            .map_err(|_| format!("malformed Content-Length {v:?}"))
    };
    let length = parse(first)?;
    for other in &lengths[1..] {
        if parse(other)? != length {
            return Err("conflicting Content-Length headers".to_string());
        }
    }
    Ok(BodyFraming::Length(length))
}

/// The values of every header field named `name` (case-insensitive).
fn header_values<'a>(headers: &'a str, name: &str) -> Vec<&'a str> {
    headers
        .lines()
        .skip(1)
        .filter_map(|line| line.split_once(':'))
        .filter(|(k, _)| k.trim().eq_ignore_ascii_case(name))
        .map(|(_, v)| v.trim())
        .collect()
}

/// Bytes read from the connection and not yet consumed.
struct RawBody<'r, R> {
    src: &'r mut R,
    buf: Vec<u8>,
    pos: usize,
    reads: u32,
}

impl<R: tokio::io::AsyncRead + Unpin> RawBody<'_, R> {
    fn available(&self) -> &[u8] {
        &self.buf[self.pos..]
    }

    fn consume(&mut self, n: usize) {
        self.pos += n;
    }

    /// Read more bytes from the connection; `false` at end of stream.
    async fn fill(&mut self) -> Result<bool, String> {
        if self.pos > 0 {
            self.buf.drain(..self.pos);
            self.pos = 0;
        }
        let mut tmp = [0u8; 64 * 1024];
        let n = tokio::time::timeout(READ_IDLE_TIMEOUT, self.src.read(&mut tmp))
            .await
            .map_err(|_| format!("the gateway's body stalled for {READ_IDLE_TIMEOUT:?}"))?
            .map_err(|e| format!("read body: {e}"))?;
        self.buf.extend_from_slice(&tmp[..n]);
        // Cooperative yield so a long download does not starve other tasks.
        self.reads = self.reads.wrapping_add(1);
        if self.reads.is_multiple_of(16) {
            tokio::task::yield_now().await;
        }
        Ok(n > 0)
    }

    /// Hand at most `want` available bytes to `sink`; the number handed.
    fn drain_into(
        &mut self,
        want: u64,
        sink: &mut impl FnMut(&[u8]) -> Result<(), String>,
    ) -> Result<u64, String> {
        let take = (self.available().len() as u64).min(want) as usize;
        if take > 0 {
            sink(&self.buf[self.pos..self.pos + take])?;
            self.consume(take);
        }
        Ok(take as u64)
    }

    /// The next CRLF-terminated line (without the CRLF), at most `max`
    /// bytes long including the CRLF.
    async fn line(&mut self, max: usize, what: &str) -> Result<Vec<u8>, String> {
        loop {
            if let Some(end) = find_subsequence(self.available(), b"\r\n") {
                if end + 2 > max {
                    return Err(format!(
                        "malformed chunked body: {what} longer than {max} bytes"
                    ));
                }
                let line = self.available()[..end].to_vec();
                self.consume(end + 2);
                return Ok(line);
            }
            if self.available().len() >= max {
                return Err(format!(
                    "malformed chunked body: {what} longer than {max} bytes"
                ));
            }
            if !self.fill().await? {
                return Err(format!(
                    "malformed chunked body: the connection closed in {what}"
                ));
            }
        }
    }
}

/// Read a response body delimited by `framing` from `leftover` (the bytes
/// that came with the headers) and then `src`, handing the decoded bytes to
/// `sink`.  More than `limit` decoded bytes is refused: before reading when
/// the `Content-Length` or a chunk size declares it, otherwise as soon as
/// the body runs past it.  A body that ends early, and chunked framing that
/// breaks RFC 9112 §7.1, are errors, never a silently shorter body.
/// Returns the number of decoded bytes.
async fn read_body<R: tokio::io::AsyncRead + Unpin>(
    src: &mut R,
    leftover: Vec<u8>,
    framing: BodyFraming,
    limit: u64,
    path: &str,
    sink: &mut impl FnMut(&[u8]) -> Result<(), String>,
) -> Result<u64, String> {
    let mut raw = RawBody {
        src,
        buf: leftover,
        pos: 0,
        reads: 0,
    };
    let mut total: u64 = 0;
    match framing {
        BodyFraming::Length(length) => {
            if length > limit {
                return Err(over_limit(path, length, limit));
            }
            while total < length {
                total += raw.drain_into(length - total, sink)?;
                if total < length && !raw.fill().await? {
                    return Err(format!(
                        "gateway response for {path} ended after {total} of its {length} bytes"
                    ));
                }
            }
        }
        BodyFraming::UntilClose => loop {
            let pending = raw.available().len() as u64;
            if total + pending > limit {
                return Err(over_limit(path, total + pending, limit));
            }
            total += raw.drain_into(pending, sink)?;
            if !raw.fill().await? {
                break;
            }
        },
        BodyFraming::Chunked => loop {
            // chunk = chunk-size [ chunk-ext ] CRLF chunk-data CRLF
            let size_line = raw.line(MAX_CHUNK_SIZE_LINE, "a chunk-size line").await?;
            let mut with_crlf = size_line.clone();
            with_crlf.extend_from_slice(b"\r\n");
            let size = match httparse::parse_chunk_size(&with_crlf) {
                Ok(httparse::Status::Complete((consumed, size))) if consumed == with_crlf.len() => {
                    size
                }
                _ => {
                    return Err(format!(
                        "malformed chunked body: bad chunk-size line {:?}",
                        String::from_utf8_lossy(&size_line)
                    ));
                }
            };
            if size == 0 {
                // last-chunk, then the trailer section up to an empty line.
                // Trailer fields are not used, so they are checked for shape
                // and dropped (RFC 9112 §7.1.2).
                let mut trailer_bytes = 0usize;
                loop {
                    let field = raw
                        .line(MAX_CHUNK_TRAILER_BYTES, "the trailer section")
                        .await?;
                    if field.is_empty() {
                        break;
                    }
                    trailer_bytes += field.len() + 2;
                    if trailer_bytes > MAX_CHUNK_TRAILER_BYTES {
                        return Err(format!(
                            "malformed chunked body: trailer section longer than {MAX_CHUNK_TRAILER_BYTES} bytes"
                        ));
                    }
                    if !field.contains(&b':') {
                        return Err(format!(
                            "malformed chunked body: bad trailer field {:?}",
                            String::from_utf8_lossy(&field)
                        ));
                    }
                }
                break;
            }
            if total.saturating_add(size) > limit {
                return Err(over_limit(path, total.saturating_add(size), limit));
            }
            let mut left = size;
            while left > 0 {
                let got = raw.drain_into(left, sink)?;
                left -= got;
                total += got;
                if left > 0 && !raw.fill().await? {
                    return Err(format!(
                        "malformed chunked body: the connection closed {left} bytes before the end of a chunk"
                    ));
                }
            }
            while raw.available().len() < 2 {
                if !raw.fill().await? {
                    return Err(
                        "malformed chunked body: the connection closed after chunk data"
                            .to_string(),
                    );
                }
            }
            if &raw.available()[..2] != b"\r\n" {
                return Err("malformed chunked body: chunk data not followed by CRLF".to_string());
            }
            raw.consume(2);
        },
    }
    Ok(total)
}

fn over_limit(path: &str, size: u64, limit: u64) -> String {
    format!(
        "gateway response for {path} is at least {size} bytes, over the {limit}-byte limit \
         of a dive-in fetch"
    )
}

fn build_get_request(
    gateway: &Origin,
    path: &str,
    credentials: &GatewayCredentials,
    range: Option<&str>,
) -> String {
    let host = gateway.authority();
    let mut req = format!(
        "GET {path} HTTP/1.1\r\n\
         Host: {host}\r\n\
         User-Agent: codetracer-backend-manager/0.1\r\n\
         Accept: */*\r\n\
         Connection: close\r\n"
    );
    // Both values are b64tokens (GatewayCredentials::new), so neither can
    // end the header line.
    if !credentials.bearer.is_empty() {
        req.push_str(&format!("Authorization: Bearer {}\r\n", credentials.bearer));
    }
    if let Some(share) = &credentials.share_token {
        req.push_str(&format!("{SHARE_TOKEN_HEADER}: {share}\r\n"));
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
        let n = tokio::time::timeout(READ_IDLE_TIMEOUT, stream.read(&mut tmp))
            .await
            .map_err(|_| format!("the gateway sent no response within {READ_IDLE_TIMEOUT:?}"))?
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

// ---------------------------------------------------------------------------
// URL helpers
// ---------------------------------------------------------------------------

fn default_port(scheme: &str) -> u16 {
    if scheme == "https" { 443 } else { 80 }
}

/// Split an absolute `http(s)` URL into its [`Origin`] and what follows the
/// authority (the path, query and fragment, possibly empty).
///
/// The authority ends at the first `/`, `?` or `#` (RFC 3986 §3.2).
fn split_origin(url: &str) -> Result<(Origin, &str), String> {
    let (scheme, rest) = url
        .split_once("://")
        .ok_or_else(|| format!("not an absolute http(s) URL: {:?}", redact_url(url)))?;
    let scheme = scheme.to_ascii_lowercase();
    if scheme != "http" && scheme != "https" {
        return Err(format!("unsupported scheme in URL: {:?}", redact_url(url)));
    }
    let end = rest.find(['/', '?', '#']).unwrap_or(rest.len());
    let (authority, after) = rest.split_at(end);
    let (host, port) =
        parse_authority(authority, &scheme).map_err(|e| format!("{e} in {:?}", redact_url(url)))?;
    Ok((Origin { scheme, host, port }, after))
}

/// Parse `host[:port]` strictly: a host name or IPv4 address made of
/// letters, digits, `-`, `.`, `_` and `~`, or a bracketed IPv6 literal, then
/// an optional port of one to five digits (1 to 65535).  Anything else,
/// user information (`user@host`) and percent-encoding included, is
/// refused, so the host compared is the host a connection would reach.
/// The host is returned lower-cased; a missing port becomes the scheme's
/// default.
fn parse_authority(authority: &str, scheme: &str) -> Result<(String, u16), String> {
    if authority.is_empty() {
        return Err("empty host".to_string());
    }
    if authority.contains('@') {
        // `http://gateway@other/` reaches `other`; refuse rather than
        // compare a host the connection would not use.
        return Err("user information in the authority is refused".to_string());
    }
    let (host, port) = if let Some(after_bracket) = authority.strip_prefix('[') {
        let (literal, rest) = after_bracket
            .split_once(']')
            .ok_or_else(|| "unterminated IPv6 literal".to_string())?;
        if literal.is_empty()
            || !literal
                .chars()
                .all(|c| c.is_ascii_hexdigit() || c == ':' || c == '.')
        {
            return Err(format!("malformed IPv6 literal [{literal}]"));
        }
        let port = if rest.is_empty() {
            None
        } else {
            Some(
                rest.strip_prefix(':')
                    .ok_or_else(|| format!("unexpected {rest:?} after an IPv6 literal"))?,
            )
        };
        (format!("[{}]", literal.to_ascii_lowercase()), port)
    } else {
        let (host, port) = match authority.split_once(':') {
            Some((host, port)) => (host, Some(port)),
            None => (authority, None),
        };
        if host.is_empty()
            || !host
                .chars()
                .all(|c| c.is_ascii_alphanumeric() || matches!(c, '-' | '.' | '_' | '~'))
        {
            return Err(format!(
                "host {host:?} is not a host name or IPv4 address (user information, \
                 percent-encoding and other characters are refused)"
            ));
        }
        (host.to_ascii_lowercase(), port)
    };
    let port = match port {
        None => default_port(scheme),
        Some(digits) => {
            let valid = !digits.is_empty()
                && digits.len() <= 5
                && digits.bytes().all(|b| b.is_ascii_digit());
            match digits.parse::<u16>() {
                Ok(port) if valid && port != 0 => port,
                _ => return Err(format!("malformed port {digits:?}")),
            }
        }
    };
    Ok((host, port))
}

/// `value` as a canonical (lower-case, 8-4-4-4-12 hyphenated) UUID, or
/// `None` when it is not a UUID in that form (letter case aside).
fn canonical_uuid(value: &str) -> Option<String> {
    let bytes = value.as_bytes();
    let well_formed = bytes.len() == 36
        && bytes.iter().enumerate().all(|(i, b)| {
            if matches!(i, 8 | 13 | 18 | 23) {
                *b == b'-'
            } else {
                b.is_ascii_hexdigit()
            }
        });
    well_formed.then(|| value.to_ascii_lowercase())
}

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
        assert_eq!(parsed.origin.to_string(), "http://127.0.0.1:36767");
        assert!(parsed.gateway_base_url.is_none());
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
    fn parse_dive_in_url_reads_gateway_base_url() {
        let url = "http://shell/?trace_id=t&gatewayBaseUrl=http%3A%2F%2Felsewhere%3A9999";
        let parsed = parse_dive_in_url(url).unwrap();
        assert_eq!(parsed.origin.to_string(), "http://shell");
        assert_eq!(
            parsed.gateway_base_url.map(|o| o.to_string()).as_deref(),
            Some("http://elsewhere:9999")
        );
        // A gatewayBaseUrl that is not an origin is a malformed URL.
        let err = parse_dive_in_url("http://gw/?trace_id=t&gatewayBaseUrl=http%3A%2F%2Fgw%2Fx")
            .unwrap_err();
        assert!(err.contains("gatewayBaseUrl"), "err = {err}");
    }

    fn origin(base: &str) -> Origin {
        Origin::parse_base_url(base).unwrap()
    }

    #[test]
    fn origins_compare_after_normalisation() {
        // Each pair names one origin.
        for (a, b) in [
            ("HTTP://LocalHost", "http://localhost:80/"),
            ("https://gw.example", "https://gw.example:443"),
            ("http://[::1]:8080", "http://[::1]:8080/"),
            ("http://[FE80::1]", "http://[fe80::1]:80"),
        ] {
            assert_eq!(origin(a), origin(b), "{a} and {b}");
        }
        // Each pair names two.
        for (a, b) in [
            ("http://gw", "https://gw"),
            ("http://gw:443", "https://gw"),
            ("http://gw:8080", "http://gw:8081"),
            ("http://gw", "http://gw."),
            ("http://127.0.0.1", "http://localhost"),
        ] {
            assert_ne!(origin(a), origin(b), "{a} and {b}");
        }
    }

    #[test]
    fn malformed_authorities_are_refused() {
        for bad in [
            "http://gw:8080@evil.example/x?trace_id=t",
            "http://user@gw/x?trace_id=t",
            "http:///x?trace_id=t",
            "http://gw:/x?trace_id=t",
            "http://gw:0/x?trace_id=t",
            "http://gw:65536/x?trace_id=t",
            "http://gw:123456/x?trace_id=t",
            "http://gw:8o/x?trace_id=t",
            "http://g%77/x?trace_id=t",
            "http://gw\\evil/x?trace_id=t",
            "http://[::1/x?trace_id=t",
            "http://[::g]/x?trace_id=t",
            "http://[::1]x/x?trace_id=t",
            "ftp://gw/x?trace_id=t",
        ] {
            assert!(parse_dive_in_url(bad).is_err(), "accepted {bad}");
        }
        for bad_base in ["http://gw/path", "http://gw?x=1", "http://gw/#f", "gw:80"] {
            assert!(
                Origin::parse_base_url(bad_base).is_err(),
                "accepted {bad_base}"
            );
        }
    }

    #[test]
    fn the_authority_ends_at_query_or_fragment() {
        // `?` and `#` end the authority, so what follows cannot pose as the host.
        let parsed = parse_dive_in_url("http://evil.example?trace_id=t&x=@gw/").unwrap();
        assert_eq!(parsed.origin, origin("http://evil.example"));
        let parsed = parse_dive_in_url("http://evil.example#@gw/?trace_id=t");
        assert!(parsed.is_err(), "the fragment's trace_id must not count");
    }

    #[test]
    fn check_gateway_origin_refuses_every_other_origin() {
        let gateway = origin("http://127.0.0.1:5000");
        let ok = |url: &str| check_gateway_origin(&parse_dive_in_url(url).unwrap(), &gateway);
        ok("http://127.0.0.1:5000/observability/v0/debug-session?trace_id=t").unwrap();
        ok("http://127.0.0.1:5000/x?trace_id=t&gatewayBaseUrl=HTTP%3A%2F%2F127.0.0.1%3A5000%2F")
            .unwrap();
        for refused in [
            "http://127.0.0.1:5001/observability/v0/debug-session?trace_id=t",
            "http://localhost:5000/observability/v0/debug-session?trace_id=t",
            "http://127.0.0.1:5000/x?trace_id=t&gatewayBaseUrl=http%3A%2F%2Fevil.example",
            "http://evil.example/x?trace_id=t&gatewayBaseUrl=http%3A%2F%2F127.0.0.1%3A5000",
        ] {
            let err = ok(refused).unwrap_err();
            assert!(err.contains("refusing the dive-in URL"), "{refused}: {err}");
        }
    }

    #[tokio::test]
    async fn a_refused_url_never_connects_and_never_reads_the_cache() {
        // The URL names a live listener; the configured gateway is another.
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = listener.local_addr().unwrap();
        let gateway = origin("http://127.0.0.1:1");
        let url = format!(
            "http://{addr}/observability/v0/debug-session?trace_id=never-fetched&authToken=tok"
        );
        let err = fetch_recording_from_dive_in_url_via(&url, &gateway)
            .await
            .unwrap_err();
        assert!(err.contains("refusing the dive-in URL"), "err = {err}");
        let accepted = tokio::time::timeout(Duration::from_millis(200), listener.accept()).await;
        assert!(accepted.is_err(), "the refused URL's host was connected to");
    }

    /// A one-shot listener answering every connection with `response`.
    async fn spawn_canned_server(response: Vec<u8>) -> Origin {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = listener.local_addr().unwrap();
        tokio::spawn(async move {
            while let Ok((mut socket, _)) = listener.accept().await {
                let response = response.clone();
                tokio::spawn(async move {
                    let mut buf = [0u8; 4096];
                    let _ = socket.read(&mut buf).await;
                    let _ = socket.write_all(&response).await;
                    let _ = socket.shutdown().await;
                });
            }
        });
        origin(&format!("http://{addr}"))
    }

    /// An `AsyncRead` that hands out one byte per read, so every line,
    /// chunk size and CRLF arrives split across reads.
    struct OneByteAtATime(Vec<u8>, usize);

    impl tokio::io::AsyncRead for OneByteAtATime {
        fn poll_read(
            mut self: std::pin::Pin<&mut Self>,
            _cx: &mut std::task::Context<'_>,
            buf: &mut tokio::io::ReadBuf<'_>,
        ) -> std::task::Poll<std::io::Result<()>> {
            if self.1 < self.0.len() && buf.remaining() > 0 {
                let byte = self.0[self.1];
                buf.put_slice(&[byte]);
                self.1 += 1;
            }
            std::task::Poll::Ready(Ok(()))
        }
    }

    /// Decode `wire` (the bytes after the response headers) with `framing`,
    /// both from a single buffer and one byte at a time; the two must agree.
    async fn decode(wire: &[u8], framing: BodyFraming, limit: u64) -> Result<Vec<u8>, String> {
        let mut whole = Vec::new();
        let mut src: &[u8] = wire;
        let whole_result = read_body(
            &mut src,
            Vec::new(),
            framing,
            limit,
            "/p",
            &mut |b: &[u8]| {
                whole.extend_from_slice(b);
                Ok(())
            },
        )
        .await;
        let mut split = Vec::new();
        let mut slow = OneByteAtATime(wire.to_vec(), 0);
        let split_result = read_body(
            &mut slow,
            Vec::new(),
            framing,
            limit,
            "/p",
            &mut |b: &[u8]| {
                split.extend_from_slice(b);
                Ok(())
            },
        )
        .await;
        match (whole_result, split_result) {
            (Ok(n), Ok(m)) => {
                assert_eq!((n, &whole), (m, &split), "split reads decoded differently");
                assert_eq!(n, whole.len() as u64);
                Ok(whole)
            }
            (Err(a), Err(b)) => {
                assert_eq!(a, b, "split reads failed differently");
                Err(a)
            }
            (a, b) => panic!("whole and split reads disagree: {a:?} vs {b:?}"),
        }
    }

    #[tokio::test]
    async fn a_chunked_body_is_decoded() {
        // RFC 9112 §7.1, with upper- and lower-case hex and leading zeros.
        let wire = b"5\r\nhello\r\n006\r\n world\r\nA\r\n, chunked!\r\n0\r\n\r\n";
        let body = decode(wire, BodyFraming::Chunked, 1024).await.unwrap();
        assert_eq!(body, b"hello world, chunked!");
        // Leftover bytes that came with the headers are part of the body.
        let mut rest: &[u8] = b"llo\r\n0\r\n\r\n";
        let mut out = Vec::new();
        read_body(
            &mut rest,
            b"5\r\nhe".to_vec(),
            BodyFraming::Chunked,
            64,
            "/p",
            &mut |b: &[u8]| {
                out.extend_from_slice(b);
                Ok(())
            },
        )
        .await
        .unwrap();
        assert_eq!(out, b"hello");
    }

    #[tokio::test]
    async fn chunk_extensions_and_trailers_are_accepted_and_dropped() {
        let wire = b"4;name=value\r\nWiki\r\n5 ; quoted=\"x\"\r\npedia\r\n0\r\nExpires: never\r\nX-Checksum: abc\r\n\r\n";
        let body = decode(wire, BodyFraming::Chunked, 1024).await.unwrap();
        assert_eq!(body, b"Wikipedia");
    }

    #[tokio::test]
    async fn malformed_chunked_framing_is_an_error() {
        let long_ext = format!(
            "1;{}\r\nx\r\n0\r\n\r\n",
            "e".repeat(2 * MAX_CHUNK_SIZE_LINE)
        );
        let cases: Vec<(&str, Vec<u8>)> = vec![
            ("not hex", b"zz\r\nab\r\n0\r\n\r\n".to_vec()),
            ("negative", b"-1\r\nab\r\n0\r\n\r\n".to_vec()),
            ("empty size", b"\r\nab\r\n0\r\n\r\n".to_vec()),
            (
                "over 64 bits",
                b"10000000000000000\r\nab\r\n0\r\n\r\n".to_vec(),
            ),
            ("size line too long", long_ext.into_bytes()),
            (
                "data not followed by CRLF",
                b"3\r\nabcX\r\n0\r\n\r\n".to_vec(),
            ),
            ("closed inside a chunk", b"5\r\nab".to_vec()),
            ("closed before the last chunk", b"3\r\nabc\r\n".to_vec()),
            ("closed in a size line", b"3".to_vec()),
            ("closed in the trailers", b"0\r\nX: y\r\n".to_vec()),
            (
                "trailer without a colon",
                b"0\r\nnot a field\r\n\r\n".to_vec(),
            ),
        ];
        for (case, wire) in cases {
            let err = decode(&wire, BodyFraming::Chunked, 1 << 20)
                .await
                .unwrap_err();
            assert!(err.contains("malformed chunked body"), "{case}: {err}");
        }
    }

    #[tokio::test]
    async fn a_chunked_body_over_the_limit_is_refused() {
        // Exactly at the limit is fine ...
        let wire = b"5\r\nhello\r\n5\r\nworld\r\n0\r\n\r\n";
        assert_eq!(
            decode(wire, BodyFraming::Chunked, 10).await.unwrap(),
            b"helloworld"
        );
        // ... one byte over is not, refused at the chunk that crosses it.
        let err = decode(wire, BodyFraming::Chunked, 9).await.unwrap_err();
        assert!(
            err.contains("at least 10 bytes, over the 9-byte limit"),
            "{err}"
        );
        // A declared chunk size over the limit is refused before its data:
        // no data follows here, so reading it would fail differently.
        let err = decode(b"ffffffff\r\n", BodyFraming::Chunked, 1024)
            .await
            .unwrap_err();
        assert!(err.contains("over the 1024-byte limit"), "{err}");
        let err = decode(b"ffffffffffffffff\r\n", BodyFraming::Chunked, 1024)
            .await
            .unwrap_err();
        assert!(err.contains("over the 1024-byte limit"), "{err}");
    }

    #[tokio::test]
    async fn length_and_close_delimited_bodies() {
        assert_eq!(
            decode(b"abcdef", BodyFraming::Length(3), 10).await.unwrap(),
            b"abc"
        );
        let err = decode(b"ab", BodyFraming::Length(3), 10).await.unwrap_err();
        assert!(err.contains("ended after 2 of its 3 bytes"), "{err}");
        let err = decode(b"abc", BodyFraming::Length(11), 10)
            .await
            .unwrap_err();
        assert!(err.contains("over the 10-byte limit"), "{err}");
        assert_eq!(
            decode(b"abc", BodyFraming::UntilClose, 3).await.unwrap(),
            b"abc"
        );
        let err = decode(b"abcd", BodyFraming::UntilClose, 3)
            .await
            .unwrap_err();
        assert!(err.contains("over the 3-byte limit"), "{err}");
    }

    #[test]
    fn body_framing_follows_rfc_9112_section_6_3() {
        let h = |fields: &str| format!("HTTP/1.1 200 OK\r\n{fields}");
        assert_eq!(
            body_framing(&h("Content-Length: 12")),
            Ok(BodyFraming::Length(12))
        );
        assert_eq!(body_framing(&h("X: y")), Ok(BodyFraming::UntilClose));
        assert_eq!(
            body_framing(&h("Transfer-Encoding: Chunked")),
            Ok(BodyFraming::Chunked)
        );
        // Transfer-Encoding wins over Content-Length.
        assert_eq!(
            body_framing(&h("Content-Length: 3\r\ntransfer-encoding: chunked")),
            Ok(BodyFraming::Chunked)
        );
        for refused in [
            "Transfer-Encoding: gzip, chunked",
            "Transfer-Encoding: gzip",
            "Transfer-Encoding: chunked\r\nTransfer-Encoding: chunked",
            "Content-Length: 1x",
            "Content-Length: -1",
            "Content-Length: 3\r\nContent-Length: 4",
        ] {
            assert!(body_framing(&h(refused)).is_err(), "accepted {refused:?}");
        }
        assert_eq!(
            body_framing(&h("Content-Length: 3\r\nContent-Length: 3")),
            Ok(BodyFraming::Length(3))
        );
    }

    #[tokio::test]
    async fn a_chunked_manifest_is_fetched_and_parsed() {
        // The gateway answers its manifest chunked, the way codetracer-ci does.
        let json = br#"{"recordingManifest":{"mcrSlices":[{"sliceKey":"k"}]}}"#;
        let mut response = b"HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nTransfer-Encoding: chunked\r\n\r\n".to_vec();
        for piece in json.chunks(7) {
            response.extend_from_slice(format!("{:x}\r\n", piece.len()).as_bytes());
            response.extend_from_slice(piece);
            response.extend_from_slice(b"\r\n");
        }
        response.extend_from_slice(b"0\r\n\r\n");
        let gateway = spawn_canned_server(response).await;
        let (status, body) = http_get(&gateway, "/m", &no_credentials(), None, 1024)
            .await
            .unwrap();
        assert_eq!(status, 200);
        assert_eq!(body, json);
        let parsed: serde_json::Value = serde_json::from_slice(&body).unwrap();
        assert_eq!(parsed["recordingManifest"]["mcrSlices"][0]["sliceKey"], "k");
    }

    fn no_credentials() -> GatewayCredentials {
        GatewayCredentials::new("", None).unwrap()
    }

    #[test]
    fn credentials_must_be_b64tokens() {
        // RFC 6750 §2.1 b64token: accepted.
        for good in ["ct_ci_abc-DEF.123~+/", "abc==", "a", "dGVzdA", "x_y-z"] {
            GatewayCredentials::new(good, Some(good)).unwrap();
        }
        // Anything that could end or extend a header line, or is not a
        // b64token at all: refused, for both the bearer and the share token,
        // without the value in the error.
        for bad in [
            "tok\r\nX-Injected: 1",
            "tok\nX-Injected: 1",
            "tok\r",
            "tok en",
            "tok\tX",
            "tok\u{0}",
            "tok\u{7f}",
            "=abc",
            "===",
            "tök",
            "tok;x",
            "tok:x",
            "a=b",
        ] {
            let err = GatewayCredentials::new(bad, None).unwrap_err();
            assert!(err.contains("not an RFC 6750 b64token"), "{bad:?}: {err}");
            assert!(!err.contains(bad), "the error quotes the value: {err}");
            let err = GatewayCredentials::new("ok", Some(bad)).unwrap_err();
            assert!(err.contains("the share token"), "{bad:?}: {err}");
        }
        // Debug never prints a credential.
        let shown = format!(
            "{:?}",
            GatewayCredentials::new("sekrit", Some("shh")).unwrap()
        );
        assert!(
            !shown.contains("sekrit") && !shown.contains("shh"),
            "{shown}"
        );
    }

    #[tokio::test]
    async fn an_injected_token_is_refused_before_connecting() {
        // The URL names the gateway itself, so only the token check stands
        // between the request and the listener.
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = listener.local_addr().unwrap();
        let gateway = origin(&format!("http://{addr}"));
        for (param, value) in [
            ("authToken", "tok%0D%0AX-Injected%3A%201"),
            ("shareToken", "tok%0AX-Injected%3A%201"),
            ("authToken", "tok%20x"),
        ] {
            let url = format!(
                "http://{addr}/observability/v0/debug-session?trace_id=t-inject&{param}={value}"
            );
            // Bounded: a request that was sent would wait for an answer the
            // listener never gives.
            let err = tokio::time::timeout(
                Duration::from_secs(10),
                fetch_recording_from_dive_in_url_via(&url, &gateway),
            )
            .await
            .unwrap_or_else(|_| {
                panic!("{param}: the request was sent (the fetch awaited an answer)")
            })
            .unwrap_err();
            assert!(err.contains("not an RFC 6750 b64token"), "{param}: {err}");
            assert!(!err.contains("X-Injected"), "{param}: {err}");
        }
        let accepted = tokio::time::timeout(Duration::from_millis(200), listener.accept()).await;
        assert!(accepted.is_err(), "a refused token's request was sent");
    }

    #[tokio::test]
    async fn no_error_quotes_a_credential() {
        let gateway = origin("http://127.0.0.1:1");
        let secret = "S3cretTokenValue";
        // Each URL fails somewhere: scheme, authority, recording id, missing
        // ids, origin, gatewayBaseUrl, token syntax, or the connection.
        let urls = [
            format!("ftp://gw/x?authToken={secret}"),
            format!("http://{secret}@gw/x?trace_id=t"),
            format!("http://gw:99999/x?trace_id=t&authToken={secret}"),
            format!("http://127.0.0.1:1/x?recording_id=nope&shareToken={secret}"),
            format!("http://127.0.0.1:1/x?span_id=s&authToken={secret}&shareToken={secret}"),
            format!("http://evil.example/x?trace_id=t&authToken={secret}"),
            format!(
                "http://127.0.0.1:1/x?trace_id=t&gatewayBaseUrl=http%3A%2F%2Fevil&share_token={secret}"
            ),
            format!("http://127.0.0.1:1/x?trace_id=t&auth_token={secret}%0A"),
            format!(
                "http://127.0.0.1:1/x?trace_id=t-no-listener&authToken={secret}&shareToken={secret}"
            ),
            format!("http://127.0.0.1:1/x?trace_id=t&token={secret}#frag{secret}"),
        ];
        for url in &urls {
            if let Err(err) = fetch_recording_from_dive_in_url_via(url, &gateway).await {
                assert!(!err.contains(secret), "{err}");
            } else {
                panic!("{url} was fetched");
            }
        }
        // redact_url itself.
        let redacted = redact_url(&format!(
            "http://u:{secret}@gw/p?trace_id=t&authToken={secret}&Share_Token={secret}&token={secret}#{secret}"
        ));
        assert!(!redacted.contains(secret), "{redacted}");
        assert!(redacted.contains("trace_id=t"), "{redacted}");
    }

    #[test]
    fn recording_id_addresses_the_gateway_and_keys_the_cache() {
        let rid = "01A155B2-C265-74AF-BDED-9A97C782CF31";
        let parsed = parse_dive_in_url(&format!(
            "http://gw/observability/v0/debug-session?recording_id={rid}&trace_id=4bf92f3577b34da6a3ce929d0e0e4736&span_id=00f067aa0ba902b7"
        ))
        .unwrap();
        assert_eq!(
            parsed.recording_id.as_deref(),
            Some("01a155b2-c265-74af-bded-9a97c782cf31")
        );
        assert_eq!(parsed.gateway_id(), "01a155b2-c265-74af-bded-9a97c782cf31");
        assert_eq!(parsed.cache_key(), "01a155b2-c265-74af-bded-9a97c782cf31");
        // Two recordings of one OpenTelemetry trace get two cache entries.
        let other = parse_dive_in_url(
            "http://gw/x?recording_id=01a155b2-c265-74af-bded-000000000000&trace_id=4bf92f3577b34da6a3ce929d0e0e4736",
        )
        .unwrap();
        assert_ne!(parsed.cache_key(), other.cache_key());
        // The v0 shape keeps the trace id, under a prefix no recording id has.
        let v0 =
            parse_dive_in_url("http://gw/x?trace_id=4bf92f3577b34da6a3ce929d0e0e4736").unwrap();
        assert_eq!(v0.gateway_id(), "4bf92f3577b34da6a3ce929d0e0e4736");
        assert_eq!(
            v0.cache_key(),
            "otel-trace-4bf92f3577b34da6a3ce929d0e0e4736"
        );
        // A recording id alone is enough; a malformed one is refused.
        parse_dive_in_url(&format!("http://gw/x?recording_id={rid}")).unwrap();
        for bad in [
            "not-a-uuid",
            "01a155b2c26574afbded9a97c782cf31",
            "01a155b2-c265-74af-bded-9a97c782cf3g",
        ] {
            assert!(
                parse_dive_in_url(&format!("http://gw/x?recording_id={bad}")).is_err(),
                "{bad}"
            );
        }
    }

    #[tokio::test]
    async fn the_share_token_is_sent_as_x_share_token() {
        // A gateway that records each request head and answers 404.
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = listener.local_addr().unwrap();
        let seen = std::sync::Arc::new(tokio::sync::Mutex::new(Vec::<String>::new()));
        let sink = std::sync::Arc::clone(&seen);
        tokio::spawn(async move {
            while let Ok((mut socket, _)) = listener.accept().await {
                let mut buf = vec![0u8; 8192];
                let n = socket.read(&mut buf).await.unwrap_or(0);
                sink.lock()
                    .await
                    .push(String::from_utf8_lossy(&buf[..n]).into_owned());
                let _ = socket
                    .write_all(b"HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\n\r\n")
                    .await;
            }
        });
        let gateway = origin(&format!("http://{addr}"));
        let url = format!(
            "http://{addr}/observability/v0/debug-session?recording_id=01a155b2-c265-74af-bded-9a97c782cf31&authToken=ct_ci_bearer&shareToken=ShAre-tok_en"
        );
        let err = fetch_recording_from_dive_in_url_via(&url, &gateway)
            .await
            .unwrap_err();
        assert!(err.contains("HTTP 404"), "{err}");
        let requests = seen.lock().await.clone();
        assert_eq!(requests.len(), 1, "{requests:?}");
        let head = &requests[0];
        assert!(
            head.starts_with(
                "GET /api/v1/observability/gateway/manifests/01a155b2-c265-74af-bded-9a97c782cf31 "
            ),
            "{head}"
        );
        assert!(
            head.contains("\r\nAuthorization: Bearer ct_ci_bearer\r\n"),
            "{head}"
        );
        assert!(
            head.contains("\r\nX-Share-Token: ShAre-tok_en\r\n"),
            "{head}"
        );
    }

    #[tokio::test]
    async fn a_silent_gateway_fails_the_fetch() {
        // Accepts, reads the request, then never answers (or answers headers
        // only and stalls the body).
        for answer in [
            &b""[..],
            &b"HTTP/1.1 200 OK\r\nContent-Length: 10\r\n\r\nabc"[..],
        ] {
            let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
            let addr = listener.local_addr().unwrap();
            tokio::spawn(async move {
                let (mut socket, _) = listener.accept().await.unwrap();
                let mut buf = [0u8; 4096];
                let _ = socket.read(&mut buf).await;
                let _ = socket.write_all(answer).await;
                tokio::time::sleep(Duration::from_secs(30)).await;
            });
            let gateway = origin(&format!("http://{addr}"));
            let started = std::time::Instant::now();
            let err = http_get(&gateway, "/m", &no_credentials(), None, 1024)
                .await
                .unwrap_err();
            assert!(
                err.contains("sent no response within") || err.contains("body stalled for"),
                "{err}"
            );
            assert!(
                started.elapsed() < Duration::from_secs(10),
                "{:?}",
                started.elapsed()
            );
        }
    }

    #[tokio::test]
    async fn an_oversized_manifest_is_refused() {
        let limits = FetchLimits {
            manifest_bytes: 64,
            recording_bytes: 1024,
        };
        let dest = tempfile::tempdir().unwrap();
        // Declared too large: refused before the body is read.
        let declared =
            spawn_canned_server(b"HTTP/1.1 200 OK\r\nContent-Length: 17000000\r\n\r\n{}".to_vec())
                .await;
        let err = fetch_recording_into_dir_limited(
            &declared,
            "t",
            &no_credentials(),
            dest.path(),
            limits,
        )
        .await
        .unwrap_err();
        assert!(err.contains("over the 64-byte limit"), "err = {err}");
        // Undeclared, running past the limit: cut off.
        let mut body = b"HTTP/1.1 200 OK\r\n\r\n".to_vec();
        body.extend(std::iter::repeat_n(b' ', 100_000));
        let streamed = spawn_canned_server(body).await;
        let err = fetch_recording_into_dir_limited(
            &streamed,
            "t",
            &no_credentials(),
            dest.path(),
            limits,
        )
        .await
        .unwrap_err();
        assert!(err.contains("over the 64-byte limit"), "err = {err}");
    }

    #[tokio::test]
    async fn a_recording_over_its_budget_is_refused() {
        let trace_id = "budget-trace";
        let mut payloads = std::collections::HashMap::new();
        payloads.insert("a.ct".to_string(), vec![1u8; 600]);
        payloads.insert("b.bin".to_string(), vec![2u8; 600]);
        let addr = spawn_mock_gateway(
            trace_id,
            vec!["a.ct".to_string(), "b.bin".to_string()],
            payloads,
            None,
        )
        .await;
        let gateway = origin(&format!("http://{addr}"));
        let dest = tempfile::tempdir().unwrap();
        // 1200 bytes fit in 1200, so the limit is not off by one ...
        let fits = FetchLimits {
            manifest_bytes: MAX_MANIFEST_BYTES,
            recording_bytes: 1200,
        };
        fetch_recording_into_dir_limited(&gateway, trace_id, &no_credentials(), dest.path(), fits)
            .await
            .unwrap();
        // ... and not in 1199: the second object is refused by its declared size.
        let short = FetchLimits {
            recording_bytes: 1199,
            ..fits
        };
        let err = fetch_recording_into_dir_limited(
            &gateway,
            trace_id,
            &no_credentials(),
            dest.path(),
            short,
        )
        .await
        .unwrap_err();
        assert!(err.contains("over the 599-byte limit"), "err = {err}");
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

        let base = origin(&format!("http://{addr}"));
        let keys = fetch_recording_into_dir(&base, trace_id, &no_credentials(), &dest)
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

        let gateway = origin(&format!("http://{addr}"));
        let r1 = fetch_recording_from_dive_in_url_via(&url, &gateway)
            .await
            .unwrap();
        assert!(!r1.from_cache);
        assert_eq!(r1.trace_id, trace_id);
        assert_eq!(r1.span_id, "sp");
        assert_eq!(
            std::fs::read(r1.local_path.join("trace.ct")).unwrap(),
            payload
        );

        // Drop the mock listener by clearing the env var: the next call
        // must come purely from the cache.
        let r2 = fetch_recording_from_dive_in_url_via(&url, &gateway)
            .await
            .unwrap();
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

        let base = origin(&format!("http://{addr}"));
        let err = fetch_recording_into_dir(
            &base,
            trace_id,
            &GatewayCredentials::new("wrong-token", None).unwrap(),
            &dest,
        )
        .await
        .unwrap_err();
        assert!(
            err.contains("401") || err.contains("missing token"),
            "err={err}"
        );

        let _ = std::fs::remove_dir_all(&dest);
    }
}
