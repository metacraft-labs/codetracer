//! Value-Origin Tracking query engine — M2 surface.
//!
//! Sits between the DAP dispatch (`dap_handler::Handler::origin_chain`)
//! and the per-backend implementations. The trait is implemented by:
//!
//! - [`crate::db::MaterializedReplaySession`] — the materialized Path B
//!   algorithm (spec §6.1).
//! - [`crate::emulator_session::EmulatorReplaySession`] — placeholder
//!   that returns `OriginError::UnsupportedBackend` until the omniscient
//!   DB lands in M18.
//! - [`crate::recreator_session::RecreatorReplaySession`] — placeholder
//!   that returns `OriginError::UnsupportedBackend` until M11.
//!
//! Errors map to the DAP error codes 6101–6106 documented in spec §5.3.
//! Conversion is handled in `dap_handler.rs` so the trait surface stays
//! transport-agnostic.

use std::fmt;
use std::time::SystemTime;

use base64::Engine as _;
use base64::engine::general_purpose::URL_SAFE_NO_PAD as BASE64_URL;
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};

use crate::task::{CtOriginChainArguments, OriginBudget, OriginChain, OriginSummary, TerminatorKindWire};

// ---------------------------------------------------------------------------
// Error codes (spec §5.3, table at lines 686-697)
// ---------------------------------------------------------------------------

/// DAP error codes for `ct/originChain` and `ct/originSummary` (spec §5.3).
/// Carried through to the DAP response body as `body.originErrorCode`
/// so the frontend can branch deterministically without parsing the
/// human-readable `message` field.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum OriginErrorCode {
    /// 6101 — variable / dotted path could not be resolved in scope.
    InvalidVariablePath = 6101,
    /// 6102 — frame_id / step_id out of range for the trace.
    InvalidFrameOrStep = 6102,
    /// 6103 — backend does not yet implement origin queries for this
    /// trace kind.
    UnsupportedBackend = 6103,
    /// 6104 — the recording lacks source files (and the classifier
    /// cannot resolve the source line for the value's defining
    /// expression). Per spec §5.3 this is distinct from the global
    /// budget code below.
    RecordingLacksSourceFiles = 6104,
    /// 6105 — per-call / global budget exhausted (wall-clock,
    /// instructions scanned, or max-hops) and the chain cannot be
    /// continued.
    QueryExceededGlobalBudget = 6105,
    /// 6106 — continuation-token fingerprint OR source-digest mismatch.
    ContinuationTokenInvalid = 6106,
}

impl OriginErrorCode {
    pub const fn as_u32(self) -> u32 {
        self as u32
    }
}

impl fmt::Display for OriginErrorCode {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{}", self.as_u32())
    }
}

/// Structured origin error. Carries the DAP error code, a human-readable
/// message, and (optionally) a structured detail blob the dispatch layer
/// will serialise into the response body — frontends consume it to
/// disambiguate 6106 fingerprint mismatch vs. source-digest mismatch.
#[derive(Debug, Clone)]
pub struct OriginError {
    pub code: OriginErrorCode,
    pub message: String,
    pub detail: Option<serde_json::Value>,
}

impl OriginError {
    pub fn new(code: OriginErrorCode, message: impl Into<String>) -> Self {
        OriginError {
            code,
            message: message.into(),
            detail: None,
        }
    }

    pub fn with_detail(mut self, detail: serde_json::Value) -> Self {
        self.detail = Some(detail);
        self
    }

    /// Constructor for the most common case: "this backend isn't wired
    /// up yet". The frontend renders this with a "coming soon" affordance.
    pub fn unsupported_backend(backend_name: &str) -> Self {
        OriginError::new(
            OriginErrorCode::UnsupportedBackend,
            format!("origin queries are not yet supported for `{backend_name}` traces"),
        )
    }
}

impl fmt::Display for OriginError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "origin error {}: {}", self.code, self.message)
    }
}

impl std::error::Error for OriginError {}

// ---------------------------------------------------------------------------
// Trait
// ---------------------------------------------------------------------------

/// Backend-agnostic origin-query surface invoked by `dap_handler::Handler`.
///
/// Every replay backend (materialized / emulator / recreator) implements
/// the same trait so the handler can dispatch unconditionally on
/// `TraceKind`.
pub trait OriginQueryEngine {
    /// Compute (or extend, via continuation token) a value-origin chain.
    fn origin_chain(
        &mut self,
        args: &CtOriginChainArguments,
        budget: &OriginBudget,
    ) -> Result<OriginChain, OriginError>;

    /// Resolve a batch of placeholder tokens into filled summaries
    /// (spec §5.3.2). Per-token errors yield `UnknownVariable` /
    /// `UnknownSource` summaries rather than request-level failures.
    fn origin_summary(&mut self, tokens: &[String]) -> Result<Vec<OriginSummary>, OriginError>;
}

// ---------------------------------------------------------------------------
// Default impls — `UnsupportedBackend` for non-materialized sessions until
// M11 (recreator) / M18 (emulator) land.
// ---------------------------------------------------------------------------

/// Helper a backend uses when it has not yet wired the algorithm:
/// returns the 6103 error directly so call sites stay one-liners.
pub fn unsupported_backend(name: &str) -> OriginError {
    OriginError::unsupported_backend(name)
}

// ---------------------------------------------------------------------------
// Continuation tokens (spec §5.3.1)
// ---------------------------------------------------------------------------

/// Per-source-file digest used by the continuation-token integrity check
/// (spec §5.3.1 step 3).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct SourceDigest {
    pub path: String,
    /// Bundled = digest of the `meta_dat/sources/` copy; FileSystem = digest
    /// of the live on-disk file at chain-start time. The kind matters for
    /// the 6106 self-contained-trace exemption.
    pub origin: SourceOriginKind,
    /// Hex-encoded SHA-256.
    pub sha256_hex: String,
}

/// Where the source line came from. Mirrors `expr_loader::SourceOrigin` so
/// the wire shape carries the bundled-vs-disk distinction the spec calls
/// out (the bundled variant is immune to disk edits).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum SourceOriginKind {
    BundledMetaData,
    Filesystem,
    Unavailable,
}

/// Serialised continuation cursor (spec §5.3.1). Encoded as base64url JSON
/// — the actual `String` carried over the wire is the b64url
/// representation of this struct.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct OriginContinuationToken {
    /// Token format version. Incremented when the payload schema changes.
    pub v: u32,
    pub query_variable: String,
    pub query_step_id: i64,
    pub current_step: i64,
    pub current_frame: i64,
    pub current_var_name: String,
    pub hops_emitted: u32,
    pub max_hops: u32,
    /// Hex fingerprint of the loaded `PatternSet` (spec §5.3.1 step 2).
    pub patterns_fingerprint: String,
    pub source_digests: Vec<SourceDigest>,
    /// Issue time (UNIX seconds) — purely informational.
    pub issued_at: u64,
}

impl OriginContinuationToken {
    pub const CURRENT_VERSION: u32 = 1;

    pub fn encode(&self) -> Result<String, OriginError> {
        let json = serde_json::to_vec(self).map_err(|e| {
            OriginError::new(
                OriginErrorCode::QueryExceededGlobalBudget,
                format!("failed to serialise continuation token: {e}"),
            )
        })?;
        Ok(BASE64_URL.encode(json))
    }

    pub fn decode(raw: &str) -> Result<Self, OriginError> {
        let bytes = BASE64_URL.decode(raw).map_err(|e| {
            OriginError::new(
                OriginErrorCode::ContinuationTokenInvalid,
                format!("continuation token is not valid base64url: {e}"),
            )
        })?;
        let token: OriginContinuationToken = serde_json::from_slice(&bytes).map_err(|e| {
            OriginError::new(
                OriginErrorCode::ContinuationTokenInvalid,
                format!("continuation token JSON is malformed: {e}"),
            )
        })?;
        if token.v != Self::CURRENT_VERSION {
            return Err(OriginError::new(
                OriginErrorCode::ContinuationTokenInvalid,
                format!(
                    "continuation token version {} not supported (current = {})",
                    token.v,
                    Self::CURRENT_VERSION
                ),
            ));
        }
        Ok(token)
    }
}

/// Compute SHA-256 over the bytes of a single source-file, returning the
/// hex digest used by the integrity check.
pub fn sha256_hex(bytes: &[u8]) -> String {
    let mut hasher = Sha256::new();
    hasher.update(bytes);
    let digest = hasher.finalize();
    let mut out = String::with_capacity(digest.len() * 2);
    for byte in digest {
        out.push(char::from_digit((byte >> 4) as u32, 16).unwrap_or('0'));
        out.push(char::from_digit((byte & 0x0F) as u32, 16).unwrap_or('0'));
    }
    out
}

/// Wall-clock cancellation helper used by the materialized scan loop.
#[derive(Debug, Clone, Copy)]
pub struct WallClockDeadline {
    pub started_at: SystemTime,
    pub budget_ms: u32,
}

impl WallClockDeadline {
    pub fn new(budget_ms: u32) -> Self {
        WallClockDeadline {
            started_at: SystemTime::now(),
            budget_ms,
        }
    }

    pub fn elapsed_ms(&self) -> u64 {
        SystemTime::now()
            .duration_since(self.started_at)
            .map(|d| d.as_millis() as u64)
            .unwrap_or(0)
    }

    pub fn exceeded(&self) -> bool {
        if self.budget_ms == 0 {
            return false;
        }
        self.elapsed_ms() >= self.budget_ms as u64
    }
}

/// Helper used by the dispatch layer to build a placeholder summary when
/// the backend wants the frontend to call back via `ct/originSummary`.
pub fn placeholder_summary(token: OriginContinuationToken) -> OriginSummary {
    // If encoding fails, we still mark the entry placeholder; the
    // frontend will receive an empty token and skip the lazy fetch.
    let placeholder_token = token.encode().ok();
    OriginSummary {
        terminator_kind: TerminatorKindWire::UnknownSource,
        is_placeholder: true,
        placeholder_token,
        ..OriginSummary::default()
    }
}

#[cfg(test)]
#[allow(clippy::unwrap_used)]
mod tests {
    use super::*;

    #[test]
    fn continuation_token_roundtrip() {
        let token = OriginContinuationToken {
            v: OriginContinuationToken::CURRENT_VERSION,
            query_variable: "c".to_string(),
            query_step_id: 7,
            current_step: 3,
            current_frame: 1,
            current_var_name: "a".to_string(),
            hops_emitted: 2,
            max_hops: 16,
            patterns_fingerprint: "deadbeef".to_string(),
            source_digests: vec![SourceDigest {
                path: "main.py".to_string(),
                origin: SourceOriginKind::Filesystem,
                sha256_hex: "cafebabe".to_string(),
            }],
            issued_at: 0,
        };
        let encoded = token.encode().unwrap();
        let decoded = OriginContinuationToken::decode(&encoded).unwrap();
        assert_eq!(decoded.query_variable, "c");
        assert_eq!(decoded.patterns_fingerprint, "deadbeef");
        assert_eq!(decoded.source_digests.len(), 1);
    }

    #[test]
    fn continuation_token_rejects_bad_version() {
        let mut token = OriginContinuationToken {
            v: 999,
            query_variable: String::new(),
            query_step_id: 0,
            current_step: 0,
            current_frame: -1,
            current_var_name: String::new(),
            hops_emitted: 0,
            max_hops: 16,
            patterns_fingerprint: String::new(),
            source_digests: Vec::new(),
            issued_at: 0,
        };
        let encoded = token.encode().unwrap();
        let err = OriginContinuationToken::decode(&encoded).unwrap_err();
        assert_eq!(err.code, OriginErrorCode::ContinuationTokenInvalid);
        token.v = OriginContinuationToken::CURRENT_VERSION;
    }

    #[test]
    fn sha256_hex_is_lowercase() {
        let hex = sha256_hex(b"hello");
        assert_eq!(hex.len(), 64);
        assert!(hex.chars().all(|c| c.is_ascii_hexdigit() && !c.is_ascii_uppercase()));
    }
}
