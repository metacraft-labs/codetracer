//! M29 — CLI agent-tooling layer tests for `ct trace origin <session.toml>`
//! (per §5.2.3 of the Cross-Process Origin E2E Test Design doc).
//!
//! Scope:
//!
//! - The `ct trace origin --variable <name> --format text` rendering
//!   path works end-to-end on a `session.toml` carrying two `[[trace]]`
//!   entries.
//! - The rendered output identifies each hop's owning process per
//!   the M29 spec requirement.
//!
//! The CLI test is deliberately a thin smoke check rather than a
//! per-backend matrix run — the recorder-driven fixture
//! infrastructure described in the E2E design doc §3.4 is deferred
//! per the M29 ship-core directive, so the CLI's chain compute
//! currently emits the synthetic skeleton documented in
//! `run_origin_subcommand`. The smoke check is sufficient to pin the
//! CLI's argument shape + format-switch behaviour + multi-trace
//! manifest acceptance, which is what the §5.2.3 entry calls out.

#![allow(clippy::expect_used, clippy::unwrap_used, clippy::panic)]

use std::path::PathBuf;
use std::process::Command;

fn binary_path() -> PathBuf {
    PathBuf::from(env!("CARGO_BIN_EXE_replay-server"))
}

fn write_session_manifest(tmp_dir: &std::path::Path) -> PathBuf {
    let manifest = r#"
version = 1

[[trace]]
recording_id = "01956f8a-7e2c-7e9c-bbbb-fixturea-fe-trace"
path = "./frontend.ct"
role = "frontend"
default_thread_prefix = "fe"

[[trace]]
recording_id = "01956f8a-7f5b-7e9c-cccc-fixturea-be-trace"
path = "./backend.ct"
role = "backend"
default_thread_prefix = "be"

[correlation]
correlation_index_mode = "eager"
"#;
    let manifest_path = tmp_dir.join("session.toml");
    std::fs::write(&manifest_path, manifest).expect("write manifest");
    // The traces themselves don't need to exist for the M29 ship-core
    // CLI run — the command only reads the manifest + scans for
    // markers on disk; an absent .ct doesn't trip the read path.
    manifest_path
}

/// `test_cli_trace_origin_session_toml_text_format`
///
/// Exercises the `--format text` rendering path: the command must
/// emit per-trace lines tagged with the recording id + role so the
/// user can see which process owns each hop. Per M29 spec the
/// command accepts a `session.toml` in place of a single `.ct`.
#[test]
fn test_cli_trace_origin_session_toml_text_format() {
    let tmp = tempfile::tempdir().expect("tempdir");
    let manifest_path = write_session_manifest(tmp.path());

    let output = Command::new(binary_path())
        .arg("trace")
        .arg("origin")
        .arg(&manifest_path)
        .arg("--variable")
        .arg("balance")
        .arg("--thread")
        .arg("fe:thread-1")
        .arg("--format")
        .arg("text")
        .output()
        .expect("run replay-server");

    let stdout = String::from_utf8(output.stdout).expect("utf-8 stdout");
    let stderr = String::from_utf8(output.stderr).expect("utf-8 stderr");

    assert!(
        output.status.success(),
        "command failed: status={:?} stderr={}",
        output.status,
        stderr
    );

    // Header line
    assert!(
        stdout.contains("origin chain for `balance`"),
        "header missing; stdout was:\n{}",
        stdout
    );
    // Both traces surfaced (so the user knows which process owns
    // which hop).
    assert!(
        stdout.contains("recording_id=01956f8a-7e2c-7e9c-bbbb-fixturea-fe-trace"),
        "frontend trace missing; stdout was:\n{}",
        stdout
    );
    assert!(
        stdout.contains("role=frontend"),
        "frontend role missing; stdout was:\n{}",
        stdout
    );
    assert!(
        stdout.contains("recording_id=01956f8a-7f5b-7e9c-cccc-fixturea-be-trace"),
        "backend trace missing; stdout was:\n{}",
        stdout
    );
    assert!(
        stdout.contains("role=backend"),
        "backend role missing; stdout was:\n{}",
        stdout
    );
    // Thread tag echoed.
    assert!(
        stdout.contains("thread: fe:thread-1"),
        "thread tag missing; stdout was:\n{}",
        stdout
    );
    // At least one hop line with an owning-process tag. Post TCT-M1
    // the legacy `"frontend"` role is normalised to `"frontend-js"`
    // by the session-manifest parser, so the rendered tag matches the
    // canonical token.
    assert!(
        stdout.contains("hop 1:") && stdout.contains("[frontend-js]"),
        "hop line missing owning-process tag; stdout was:\n{}",
        stdout
    );
    // Terminator line.
    assert!(
        stdout.contains("terminator:"),
        "terminator line missing; stdout was:\n{}",
        stdout
    );
}
