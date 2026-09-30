//! Missing-prerequisite policy shared by the materialized origin-DAP suites.
//!
//! A `#[test]` that finds its recorder missing and returns early is counted by
//! cargo and nextest as `1 passed` with nothing asserted, which is
//! indistinguishable in a summary from a run that verified something. So an
//! unavailable prerequisite, or a query that asked to skip, goes through
//! [`unavailable`], which does one of two things:
//!
//! - **fail**, when the run requires the suite: `CT_ORIGIN_DAP_REQUIRED=1`
//!   (the strict origin-DAP lanes) or
//!   `CODETRACER_ALLOW_GRACEFUL_TEST_SKIPPING=false` (the harness-wide switch
//!   that `test_harness::skip_or_fail_missing_prerequisite` honours too);
//! - **skip loudly** otherwise: a `SKIPPED:` line that says the test asserted
//!   nothing and how to make the skip a failure, so a developer box without,
//!   say, the Cairo recorder stays usable without the skip passing for a check.

use std::env;

pub const REQUIRED_MODE_ENV: &str = "CT_ORIGIN_DAP_REQUIRED";

pub const GRACEFUL_SKIPPING_ENV: &str = "CODETRACER_ALLOW_GRACEFUL_TEST_SKIPPING";

/// Parse required mode without reading process-global state, so the accepted
/// values can be tested safely even when Rust tests execute concurrently.
pub fn required_mode_from_value(value: Option<&str>) -> Result<bool, String> {
    match value {
        None | Some("0") => Ok(false),
        Some("1") => Ok(true),
        Some(other) => Err(format!("{REQUIRED_MODE_ENV} must be unset, '0', or '1'; got {other:?}")),
    }
}

/// Whether `CODETRACER_ALLOW_GRACEFUL_TEST_SKIPPING` forbids skipping. Same
/// reading as `test_harness::skip_or_fail_missing_prerequisite`: only an
/// explicit `false` / `0` / `no` does.
pub fn graceful_skipping_disabled_from_value(value: Option<&str>) -> bool {
    value.is_some_and(|v| {
        let v = v.trim().to_ascii_lowercase();
        v == "false" || v == "0" || v == "no"
    })
}

/// Return whether the current run must fail rather than skip: either the
/// origin-DAP required mode is on or graceful skipping is switched off.
/// Invalid explicit `CT_ORIGIN_DAP_REQUIRED` values fail closed rather than
/// silently selecting the developer-optional policy.
#[track_caller]
pub fn required_mode() -> bool {
    let value = env::var(REQUIRED_MODE_ENV).ok();
    let required = required_mode_from_value(value.as_deref()).unwrap_or_else(|reason| panic!("{reason}"));
    required || graceful_skipping_disabled_from_value(env::var(GRACEFUL_SKIPPING_ENV).ok().as_deref())
}

/// The message a skipped test prints. It keeps the `SKIPPED:` sentinel the
/// strict lanes grep for, and says outright that nothing was verified.
pub fn skip_banner(context: &str, reason: &str) -> String {
    format!(
        "SKIPPED: {context}: {reason}\n\
         *** SKIPPED (NOT VERIFIED): this test asserted NOTHING. Set \
         {GRACEFUL_SKIPPING_ENV}=false (or {REQUIRED_MODE_ENV}=1) to make a missing \
         prerequisite fail instead."
    )
}

/// Handle an unavailable prerequisite or a query that asked to skip.
///
/// Required mode panics so `cargo test` records a real failure. Optional mode
/// prints [`skip_banner`] and returns `None` to its caller.
#[track_caller]
pub fn unavailable<T>(required: bool, context: &str, reason: &str) -> Option<T> {
    let report = env::var_os(SKIP_REPORT_ENV).map(std::path::PathBuf::from);
    unavailable_reporting_to(required, context, reason, report.as_deref())
}

/// [`unavailable`] with the skip report named explicitly rather than read from
/// the environment, so the gate's own tests can exercise it without writing a
/// fabricated skip into the report of the lane running them.
#[track_caller]
pub fn unavailable_reporting_to<T>(
    required: bool,
    context: &str,
    reason: &str,
    report: Option<&std::path::Path>,
) -> Option<T> {
    if required {
        panic!("required origin-DAP gate cannot skip {context}: {reason}");
    }
    eprintln!("\n{}\n", skip_banner(context, reason));
    if let Some(report) = report {
        record_skip_to(report, context, reason);
    }
    None
}

/// The variable a lane sets to collect its skips (see [`record_skip_to`]).
pub const SKIP_REPORT_ENV: &str = "CODETRACER_TEST_SKIP_REPORT";

/// Append one line to a lane's skip report.
///
/// A skipped test is tallied by cargo and nextest as a PASS, and nextest does
/// not print a passing test's stderr, so a loud banner alone is invisible in a
/// CI log. `just test-rust` points `CODETRACER_TEST_SKIP_REPORT` at a file and
/// prints every line of it after the run, so each skip is reported by the lane
/// that took it. `test_harness::record_skip` is the other writer; keep them
/// alike.
pub fn record_skip_to(report: &std::path::Path, context: &str, reason: &str) {
    // A lane that asked for the report and cannot get it would be back to
    // counting this skip as a pass, so failing to write it fails the test.
    let line = format!("{context}: {}\n", reason.replace('\n', " "));
    use std::io::Write as _;
    std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(report)
        .and_then(|mut file| file.write_all(line.as_bytes()))
        .unwrap_or_else(|e| panic!("cannot append to the skip report {}: {e}", report.display()));
}
