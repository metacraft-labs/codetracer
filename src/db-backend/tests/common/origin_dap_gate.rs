//! Required-mode policy shared by the materialized Python origin-DAP suite.
//!
//! Normal developer runs intentionally preserve the recorder-optional skip
//! behaviour. CI opts into a strict contract with
//! `CT_ORIGIN_DAP_REQUIRED=1`; unavailable prerequisites and query-level
//! `QueryOutcome::Skipped` results then panic instead of returning success.

use std::env;

pub const REQUIRED_MODE_ENV: &str = "CT_ORIGIN_DAP_REQUIRED";

/// Parse required mode without reading process-global state, so the accepted
/// values can be tested safely even when Rust tests execute concurrently.
pub fn required_mode_from_value(value: Option<&str>) -> Result<bool, String> {
    match value {
        None | Some("0") => Ok(false),
        Some("1") => Ok(true),
        Some(other) => Err(format!("{REQUIRED_MODE_ENV} must be unset, '0', or '1'; got {other:?}")),
    }
}

/// Return whether the current run requires every Python origin-DAP scenario.
/// Invalid explicit values fail closed rather than silently selecting the
/// developer-optional policy.
#[track_caller]
pub fn required_mode() -> bool {
    let value = env::var(REQUIRED_MODE_ENV).ok();
    required_mode_from_value(value.as_deref()).unwrap_or_else(|reason| panic!("{reason}"))
}

/// Handle an unavailable prerequisite or a query that asked to skip.
///
/// Required mode panics so `cargo test` records a real failure. Optional mode
/// keeps the established `SKIPPED:` sentinel and returns `None` to its caller.
#[track_caller]
pub fn unavailable<T>(required: bool, context: &str, reason: &str) -> Option<T> {
    if required {
        panic!("required origin-DAP gate cannot skip {context}: {reason}");
    }
    eprintln!("SKIPPED: {context}: {reason}");
    None
}
