//! The missing-prerequisite gate for unit tests inside this crate.
//!
//! Integration tests use `tests/test_harness::skip_or_fail_missing_prerequisite`,
//! which a unit test under `src/` cannot reach. This is the same gate with the
//! same contract, so a unit test that needs an external tool is held to the
//! same rule: never a silent pass.
//!
//! - `CODETRACER_ALLOW_GRACEFUL_TEST_SKIPPING=false` (or `0`/`no`): the
//!   prerequisite is mandatory and the test fails.
//! - Otherwise: a banner says the test asserted nothing, and the skip is
//!   appended to `CODETRACER_TEST_SKIP_REPORT` when a lane set it, so the lane
//!   prints it instead of counting it as a pass.
//!
//! Keep this alike with `tests/test_harness::skip_or_fail_missing_prerequisite`
//! and `tests/common/origin_dap_gate.rs`.

// Test-only module (declared `#[cfg(test)]`): failing the test IS the job of
// the strict branch, so panicking is the correct behaviour here.
#![allow(clippy::panic)]

use std::io::Write as _;

/// Report a missing prerequisite. Returns only when skipping is allowed, so a
/// caller writes `if missing { skip_or_fail_missing_prerequisite(..); return; }`.
pub(crate) fn skip_or_fail_missing_prerequisite(test_name: &str, what: &str, remedy: &str) {
    let graceful = std::env::var("CODETRACER_ALLOW_GRACEFUL_TEST_SKIPPING")
        .map(|v| {
            let v = v.trim().to_ascii_lowercase();
            !(v == "false" || v == "0" || v == "no")
        })
        .unwrap_or(true);
    if !graceful {
        panic!(
            "{test_name}: MISSING PREREQUISITE: {what}. {remedy}. CODETRACER_ALLOW_GRACEFUL_TEST_SKIPPING \
             is set to a false value, so this prerequisite is mandatory and the test fails rather than \
             silently passing."
        );
    }
    eprintln!(
        "\n*** SKIPPED (NOT VERIFIED) *** {test_name}: {what}.\n*** Remedy: {remedy}.\n\
         *** This test asserted NOTHING. Set CODETRACER_ALLOW_GRACEFUL_TEST_SKIPPING=false to make a \
         missing prerequisite fail instead.\n"
    );
    if let Some(report) = std::env::var_os("CODETRACER_TEST_SKIP_REPORT") {
        let line = format!("{test_name}: {}\n", what.replace('\n', " "));
        std::fs::OpenOptions::new()
            .create(true)
            .append(true)
            .open(&report)
            .and_then(|mut file| file.write_all(line.as_bytes()))
            .unwrap_or_else(|e| panic!("cannot append to the skip report {}: {e}", report.to_string_lossy()));
    }
}
