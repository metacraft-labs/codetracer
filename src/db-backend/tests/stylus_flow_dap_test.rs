//! Headless DAP flow test for Stylus (Arbitrum WASM) traces.
//!
//! Uses the pre-recorded CTFS fixture at
//! `tests/fixtures/stylus-fund-trace/<program>.ct` to verify that the DAP
//! server correctly handles Stylus traces containing both DWARF-based
//! Step/Call/Function entries and EVM host function Event entries.
//!
//! This test does NOT require a devnode — it works offline with the fixture.
//!
//! Materialized traces are CTFS-only: db-backend has dropped support for the
//! legacy `trace.json` + `trace_metadata.json` + `trace_paths.json` 3-file
//! bundle, so the fixture must be a `.ct` container. To regenerate it, run
//! `tests/fixtures/regenerate-stylus-fixture.sh` (requires an Arbitrum
//! devnode, cargo-stylus, cast, and wazero — see the script header).

use std::fs;
use std::path::{Path, PathBuf};

use ct_dap_client::test_support::FlowTestRunner;

mod test_harness;

fn find_db_backend() -> PathBuf {
    PathBuf::from(env!("CARGO_BIN_EXE_replay-server"))
}

/// Returns the path to the Stylus trace fixture directory.
fn get_stylus_fixture_dir() -> PathBuf {
    let manifest_dir = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    manifest_dir.join("tests/fixtures/stylus-fund-trace")
}

/// Locate the CTFS `.ct` file inside the fixture directory.
///
/// Returns a clear regeneration instruction if the fixture is missing — the
/// directive forbids `#[ignore]` and silent skips when the only blocker is
/// off-machine resources.
fn find_fixture_ct_file(fixture_dir: &Path) -> Result<PathBuf, String> {
    if !fixture_dir.is_dir() {
        return Err(format!(
            "Stylus CTFS fixture directory missing at {}.\n\
             Regenerate it by running:\n  \
             src/db-backend/tests/fixtures/regenerate-stylus-fixture.sh\n\
             (requires an Arbitrum devnode, cargo-stylus, cast, and wazero — \
             see the script header for details).",
            fixture_dir.display()
        ));
    }

    let entries = fs::read_dir(fixture_dir).map_err(|e| format!("read_dir {}: {}", fixture_dir.display(), e))?;
    for entry in entries {
        let entry = entry.map_err(|e| format!("dir entry: {}", e))?;
        let path = entry.path();
        if path.is_file() && path.extension().is_some_and(|ext| ext == "ct") {
            return Ok(path);
        }
    }

    Err(format!(
        "Stylus CTFS fixture at {} contains no *.ct container. \
         Regenerate it via src/db-backend/tests/fixtures/regenerate-stylus-fixture.sh.",
        fixture_dir.display()
    ))
}

/// Tier 2 (DAP flow): Verify the DAP server can load the Stylus CTFS fixture
/// and start a flow session without panicking.
///
/// The original 3-file fixture stored hardcoded recording-time absolute
/// source paths and rewrote them at test time so breakpoints resolved
/// against the current checkout. Once we move to a CTFS fixture, the
/// container-internal metadata cannot be rewritten in place; callers must
/// regenerate the fixture against the current checkout (see the regen
/// script). The DAP-side test therefore just verifies that the trace loads,
/// initializes, and reaches `run-to-entry` cleanly — the breakpoint flow
/// path lives in `test_stylus_flow_integration` and runs against a freshly
/// recorded trace.
//
// ROOT CAUSE (2026-05-20): The committed `tests/fixtures/stylus-fund-trace/`
// directory does not exist in the repository.  When the test was originally
// authored the directory held a legacy 3-file bundle that was retired in the
// 2026-05 convention compliance pass (see codetracer-specs CTFS-Migration-
// Guide §3e).  The CTFS replacement was never produced because the
// regeneration script (`tests/fixtures/regenerate-stylus-fixture.sh`)
// requires off-machine prerequisites: a running Arbitrum devnode at
// `http://localhost:8547` (e.g. nitro-testnode), `cargo-stylus`, and `cast`
// (Foundry) on PATH.  None of those are available in the dev-shell / CI
// sandbox this session runs in.
//
// The test correctly panics with a clear regeneration instruction.
// Until an Arbitrum-capable host runs the regen script and commits the
// resulting `<program>.ct` into the fixture directory, this test will
// keep bailing.  Per repo policy (no #[ignore], no silent skips, no
// weakened assertions), the failure stays visible and the test stays
// authoritative.  Resolution: run regen on an Arbitrum-capable host
// and commit the produced fixture.
#[test]
fn stylus_flow_dap_loads_ctfs_fixture() {
    let db_backend = find_db_backend();
    let fixture_dir = get_stylus_fixture_dir();

    let ct_path = find_fixture_ct_file(&fixture_dir).unwrap_or_else(|msg| panic!("{msg}"));
    println!("Stylus CTFS fixture: {}", ct_path.display());

    let runner = FlowTestRunner::new_db_trace(&db_backend, &fixture_dir)
        .unwrap_or_else(|e| panic!("DAP init failed for Stylus CTFS fixture {}: {e}", ct_path.display()));
    runner.finish().expect("disconnect failed");
    println!("Stylus DAP CTFS fixture loaded successfully");
}
