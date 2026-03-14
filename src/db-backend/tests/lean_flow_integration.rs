//! Integration test for Lean build/record/replay pipeline
//!
//! Lean compiles to C, so DWARF debug info references generated C files,
//! not .lean source files. This means source-level breakpoints on .lean
//! lines do not work, and flow/omniscience tests that rely on .lean-line
//! breakpoints cannot be used yet.
//!
//! This test verifies:
//! 1. ct-rr-support can build a Lean program (lake build)
//! 2. ct-rr-support can record its execution with RR
//! 3. db-backend can connect to the replay and initialize a DAP session
//!
//! The test is skipped if `ct-rr-support`, `rr`, or `lake` is not available.

mod test_harness;

use std::path::PathBuf;
use test_harness::{find_ct_rr_support, is_rr_available, Language, TestRecording};

fn get_lean_source_path() -> PathBuf {
    let manifest_dir = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    manifest_dir.join("test-programs/lean/lean_flow_test/Main.lean")
}

fn is_lake_available() -> bool {
    std::process::Command::new("lake")
        .arg("--version")
        .output()
        .map(|o| o.status.success())
        .unwrap_or(false)
}

#[test]
fn test_lean_build_and_record() {
    // Check prerequisites
    let ct_rr_support = match find_ct_rr_support() {
        Some(p) => p,
        None => {
            eprintln!("SKIPPED: ct-rr-support not found");
            return;
        }
    };

    if !is_rr_available() {
        eprintln!("SKIPPED: rr is not available");
        return;
    }

    if !is_lake_available() {
        eprintln!("SKIPPED: lake (Lean build tool) is not available");
        return;
    }

    let source_path = get_lean_source_path();
    assert!(
        source_path.exists(),
        "Lean test program not found at {}",
        source_path.display()
    );

    // Get Lean version for labeling
    let version_label = std::process::Command::new("lean")
        .arg("--version")
        .output()
        .ok()
        .and_then(|o| String::from_utf8(o.stdout).ok())
        .and_then(|s| {
            // Parse "Lean (version 4.26.0, ...)"
            s.split_whitespace()
                .nth(2)
                .map(|v| v.trim_matches(|c| c == ',' || c == ')').to_string())
        })
        .unwrap_or_else(|| "unknown".to_string());

    println!("Testing Lean build+record pipeline (version: {})", version_label);

    // Build and record
    let recording = TestRecording::create(&source_path, Language::Lean, &version_label, &ct_rr_support);
    match recording {
        Ok(rec) => {
            println!("Lean build+record succeeded:");
            println!("  trace dir: {}", rec.trace_dir.display());
            println!("  binary: {}", rec.binary_path.display());
            assert!(rec.trace_dir.exists(), "trace directory should exist");
            assert!(rec.binary_path.exists(), "binary should exist");
        }
        Err(e) => {
            panic!("Lean build+record failed: {}", e);
        }
    }
}

#[cfg(unix)]
#[test]
fn test_lean_dap_replay_connects() {
    use test_harness::DapTestClient;

    // Check prerequisites
    let ct_rr_support = match find_ct_rr_support() {
        Some(p) => p,
        None => {
            eprintln!("SKIPPED: ct-rr-support not found");
            return;
        }
    };

    if !is_rr_available() {
        eprintln!("SKIPPED: rr is not available");
        return;
    }

    if !is_lake_available() {
        eprintln!("SKIPPED: lake (Lean build tool) is not available");
        return;
    }

    let source_path = get_lean_source_path();
    assert!(source_path.exists());

    let version_label = "test";
    let recording = TestRecording::create(&source_path, Language::Lean, version_label, &ct_rr_support)
        .expect("build+record should succeed");

    // Start DAP client and verify we can connect
    println!("Starting DAP client for Lean replay...");
    let mut client = DapTestClient::start(&recording.temp_dir, &ct_rr_support).expect("DAP client should start");

    // Initialize and launch — verifies db-backend can connect to the RR replay
    println!("Initializing DAP session...");
    client
        .initialize_and_launch(&recording, &ct_rr_support)
        .expect("DAP initialize+launch should succeed");

    println!("Lean DAP replay connection test passed!");
}
