//! M5 — Rust-side helper invoked by the Nim ViewModel headless test
//! `src/frontend/tests/value_origin_test.nim`.
//!
//! Acts as Option-B from the milestone brief: the Nim test shells out
//! to `cargo test --test origin_chain_dump_helper -- --nocapture` (or
//! more precisely the specific test functions below) with the
//! environment variable `ORIGIN_DUMP_OUT_DIR=<dir>` set. This binary:
//!
//! 1. Records the M0 Python fixture trace via the same harness used by
//!    `origin_python_dap_test.rs` (`TestRecording::create_db_trace`).
//! 2. Spawns the real `db-backend` (`DapStdioTestClient`).
//! 3. Sends a real `ct/originChain` DAP request.
//! 4. Writes the raw response body JSON to
//!    `<ORIGIN_DUMP_OUT_DIR>/<scenario>.json`.
//!
//! When the recorder isn't available, it writes
//! `<ORIGIN_DUMP_OUT_DIR>/<scenario>.skipped` with the skip reason so
//! the Nim test can render the SKIPPED outcome (matching the harness
//! discipline documented in `origin_python_dap_test.rs`).
//!
//! No mocks. The chain that lands in the dump file is the same chain
//! the Nim `parseOriginChain` would receive from the real db-backend
//! over DAP — exactly what the M5 ViewModel headless test wants to
//! assert on.

mod test_harness;

#[path = "common/origin_dap.rs"]
mod origin_dap;

use std::fs;
use std::path::PathBuf;

use origin_dap::{OriginQueryConfig, QueryOutcome, fixture_source, load_fixture_and_query_or_skip};
use test_harness::Language;

/// Output directory injected by the Nim test runner. Returning `None`
/// means "no dump requested" so the test silently no-ops when run by a
/// human via plain `cargo test`.
fn dump_out_dir() -> Option<PathBuf> {
    std::env::var_os("ORIGIN_DUMP_OUT_DIR").map(PathBuf::from)
}

/// Build the standard Python origin-query config.
fn python_config(scenario: &str, line: u32, variable: &str, version: &str) -> OriginQueryConfig {
    OriginQueryConfig {
        source_path: fixture_source("python", scenario, "main.py"),
        language: Language::Python,
        version_label: version.to_string(),
        breakpoint_line: line,
        variable_name: variable.to_string(),
        max_hops: None,
        breakpoint_source_path: None,
    }
}

/// Skip-reason sentinel mirroring `require_python_recorder` in
/// `origin_python_dap_test.rs`. Returns `Err(reason)` when the recorder
/// is unavailable so the caller can write a `.skipped` marker.
fn require_python_recorder() -> Result<String, String> {
    if test_harness::find_python_recorder().is_none() {
        return Err("Python recorder not found (install codetracer-python-recorder or set \
             CODETRACER_PYTHON_RECORDER_PATH)"
            .to_string());
    }
    match test_harness::find_suitable_python() {
        Some((_cmd, version)) => Ok(version),
        None => Err("no suitable python interpreter on PATH (requires Python 3.10+)".to_string()),
    }
}

/// Drive the fixture and dump either the JSON body or a `.skipped`
/// marker. Returns `Ok(())` even on environment skip — the Nim test
/// inspects the file contents to decide whether to assert or skip.
fn dump_scenario(scenario: &str, line: u32, variable: &str) -> Result<(), String> {
    let Some(out_dir) = dump_out_dir() else {
        // No dump requested — running under plain `cargo test`. Skip
        // silently so this file behaves like a normal test crate.
        return Ok(());
    };
    fs::create_dir_all(&out_dir).map_err(|e| format!("create out dir: {}", e))?;

    let version = match require_python_recorder() {
        Ok(v) => v,
        Err(reason) => {
            let path = out_dir.join(format!("{}.skipped", scenario));
            fs::write(&path, &reason).map_err(|e| format!("write skipped marker: {}", e))?;
            eprintln!("SKIPPED: python/{}: {}", scenario, reason);
            return Ok(());
        }
    };

    let config = python_config(scenario, line, variable, &version);
    match load_fixture_and_query_or_skip(&config) {
        QueryOutcome::Ok(result) => {
            let json = serde_json::to_string_pretty(&result.chain)
                .map_err(|e| format!("serialise OriginChain to JSON: {}", e))?;
            let path = out_dir.join(format!("{}.json", scenario));
            fs::write(&path, json).map_err(|e| format!("write chain dump: {}", e))?;
            eprintln!("DUMPED: python/{} -> {}", scenario, path.display());
            Ok(())
        }
        QueryOutcome::Skipped(reason) => {
            let path = out_dir.join(format!("{}.skipped", scenario));
            fs::write(&path, &reason).map_err(|e| format!("write skipped marker: {}", e))?;
            eprintln!("SKIPPED: python/{}: {}", scenario, reason);
            Ok(())
        }
    }
}

/// Dump the chain JSON for `python/simple_trivial_chain` (query: `c`
/// at line 12).
#[test]
fn dump_python_simple_trivial_chain() {
    dump_scenario("simple_trivial_chain", 12, "c").expect("dump simple_trivial_chain");
}

/// Dump the chain JSON for `python/computational_origin` (query:
/// `result` at line 10).
#[test]
fn dump_python_computational_origin() {
    dump_scenario("computational_origin", 10, "result").expect("dump computational_origin");
}

/// Dump the chain JSON for `python/parameter_pass` (query: `local`
/// inside `receive(p)` at line 9).
#[test]
fn dump_python_parameter_pass() {
    dump_scenario("parameter_pass", 9, "local").expect("dump parameter_pass");
}
