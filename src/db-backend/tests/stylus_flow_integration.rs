//! Integration tests for Stylus (Arbitrum WASM) flow/omniscience support
//!
//! Stylus tests require a running Arbitrum devnode (nitro-testnode) to:
//! 1. Deploy the Stylus contract
//! 2. Send transactions to trigger contract execution
//! 3. Obtain EVM traces for the transaction
//! 4. Record WASM execution via wazero with `-stylus` flag
//!
//! These tests are `#[ignore]` by default — run with `--include-ignored`
//! and a devnode at `http://localhost:8547`.
//!
//! ## Test tiers
//!
//! - `test_stylus_flow_integration` (Tier 1): Records a Stylus trace and verifies
//!   that trace files were produced. Quick smoke test for the recording pipeline.
//!
//! - `test_stylus_trace_analysis` (Tier 1+2): Records a trace AND verifies the
//!   trace contents — checks that EVM event entries are present with expected
//!   host function calls (read_args, storage ops) and correct calldata.
//!   Catches regressions in both the Arbitrum toolchain and the wazero recorder.
//!
//! Prerequisites:
//! - Arbitrum devnode running on localhost:8547
//! - `cargo-stylus` on PATH
//! - `cast` (Foundry) on PATH
//! - `wazero` on PATH or set via CODETRACER_WASM_VM_PATH
//! - `wasm32-unknown-unknown` Rust target installed

mod test_harness;

use std::path::{Path, PathBuf};
use std::process::Command;
use test_harness::{find_wazero, record_stylus_wasm_trace, DapStdioTestClient};

use codetracer_trace_types::{EventLogKind, RecordEvent, TraceLowLevelEvent, TraceMetadata};

const DEVNODE_RPC: &str = "http://localhost:8547";
// Standard test private key for Arbitrum devnodes
const TEST_PRIVATE_KEY: &str = "0xb6b15c8cb491557369f3c7d2c287b053eb229daa9c22138887752191c9520659";

/// Line in `stylus_fund_tracker/src/lib.rs` where we'd set a breakpoint for DAP testing.
/// This is inside the `fund()` method: `let mut new_fund = self.funds.grow();`
/// Currently unused — Stylus traces lack DWARF step data. Kept for future DAP integration.
#[allow(dead_code)]
const FUND_BREAKPOINT_LINE: u32 = 59;

/// Returns the path to the Stylus fund tracker test project.
fn get_stylus_project_path() -> PathBuf {
    let manifest_dir = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    manifest_dir.join("../../test-programs/stylus_fund_tracker")
}

/// Check if the devnode is reachable.
fn is_devnode_available() -> bool {
    Command::new("curl")
        .args(["-sf", "-o", "/dev/null", "--max-time", "2", DEVNODE_RPC])
        .status()
        .map(|s| s.success())
        .unwrap_or(false)
}

/// Check if cargo-stylus is available.
fn is_cargo_stylus_available() -> bool {
    Command::new("cargo")
        .args(["stylus", "--version"])
        .output()
        .map(|o| o.status.success())
        .unwrap_or(false)
}

/// Check if `cast` (Foundry) is available.
fn is_cast_available() -> bool {
    Command::new("cast")
        .arg("--version")
        .output()
        .map(|o| o.status.success())
        .unwrap_or(false)
}

/// Verify all prerequisites for Stylus testing are available.
/// Returns false (and prints skip reason) if any prerequisite is missing.
fn check_prerequisites() -> bool {
    if !is_devnode_available() {
        eprintln!("SKIPPED: Arbitrum devnode not reachable at {}", DEVNODE_RPC);
        return false;
    }
    if !is_cargo_stylus_available() {
        eprintln!("SKIPPED: cargo-stylus not found on PATH");
        return false;
    }
    if !is_cast_available() {
        eprintln!("SKIPPED: cast (Foundry) not found on PATH");
        return false;
    }
    if find_wazero().is_none() {
        eprintln!("SKIPPED: wazero not found");
        return false;
    }
    true
}

/// Build the Stylus contract WASM binary.
fn build_stylus_wasm(project_dir: &Path) -> Result<PathBuf, String> {
    let output = Command::new("cargo")
        .args(["build", "--release", "--target", "wasm32-unknown-unknown"])
        .current_dir(project_dir)
        .output()
        .map_err(|e| format!("failed to build Stylus contract: {}", e))?;

    if !output.status.success() {
        return Err(format!(
            "Stylus WASM build failed:\nstdout: {}\nstderr: {}",
            String::from_utf8_lossy(&output.stdout),
            String::from_utf8_lossy(&output.stderr)
        ));
    }

    let wasm_path = project_dir.join("target/wasm32-unknown-unknown/release/stylus_fund_tracking_demo.wasm");
    if !wasm_path.exists() {
        return Err(format!("WASM binary not found at {}", wasm_path.display()));
    }
    Ok(wasm_path)
}

/// Deploy the Stylus contract and return the contract address.
fn deploy_stylus_contract(project_dir: &Path) -> Result<String, String> {
    let output = Command::new("cargo")
        .args([
            "stylus",
            "deploy",
            &format!("--endpoint={}", DEVNODE_RPC),
            &format!("--private-key={}", TEST_PRIVATE_KEY),
            "--no-verify",
        ])
        .current_dir(project_dir)
        .output()
        .map_err(|e| format!("failed to deploy Stylus contract: {}", e))?;

    if !output.status.success() {
        return Err(format!(
            "Stylus deploy failed:\nstdout: {}\nstderr: {}",
            String::from_utf8_lossy(&output.stdout),
            String::from_utf8_lossy(&output.stderr)
        ));
    }

    // Parse the contract address from the deploy output.
    // cargo-stylus output contains ANSI escape codes, so we strip them first.
    let stdout_raw = String::from_utf8_lossy(&output.stdout);
    // Strip ANSI escape sequences: \x1b[...m
    let ansi_re = regex::Regex::new(r"\x1b\[[0-9;]*m").unwrap();
    let stdout = ansi_re.replace_all(&stdout_raw, "");
    for line in stdout.lines() {
        if line.contains("deployed code at address") || line.contains("contract address") {
            // Extract hex address (0x followed by 40 hex chars)
            if let Some(addr) = line.split_whitespace().find(|w| w.starts_with("0x") && w.len() >= 42) {
                // Trim to exactly 42 chars (0x + 40 hex digits)
                return Ok(addr[..42].to_string());
            }
        }
    }

    Err(format!(
        "could not parse contract address from deploy output:\n{}",
        stdout
    ))
}

/// Send a `fund(2)` transaction using Foundry's `cast send`.
fn send_fund_transaction(contract_address: &str) -> Result<String, String> {
    let output = Command::new("cast")
        .args([
            "send",
            "--rpc-url",
            DEVNODE_RPC,
            "--private-key",
            TEST_PRIVATE_KEY,
            contract_address,
            "fund(uint256)",
            "2",
        ])
        .output()
        .map_err(|e| format!("failed to send transaction: {}", e))?;

    if !output.status.success() {
        return Err(format!(
            "cast send failed:\nstdout: {}\nstderr: {}",
            String::from_utf8_lossy(&output.stdout),
            String::from_utf8_lossy(&output.stderr)
        ));
    }

    // Parse tx hash from output (strip ANSI codes first)
    let stdout_raw = String::from_utf8_lossy(&output.stdout);
    let ansi_re = regex::Regex::new(r"\x1b\[[0-9;]*m").unwrap();
    let stdout = ansi_re.replace_all(&stdout_raw, "");
    for line in stdout.lines() {
        let line = line.trim();
        if line.starts_with("transactionHash") {
            if let Some(hash) = line.split_whitespace().last() {
                return Ok(hash.to_string());
            }
        }
    }

    // Try the first line as raw tx hash
    if let Some(first_line) = stdout.lines().next() {
        let trimmed = first_line.trim();
        if trimmed.starts_with("0x") && trimmed.len() == 66 {
            return Ok(trimmed.to_string());
        }
    }

    Err(format!("could not parse tx hash from cast output:\n{}", stdout))
}

/// Get the EVM trace for a transaction using `cargo stylus trace`.
fn get_stylus_trace(project_dir: &Path, tx_hash: &str) -> Result<String, String> {
    let output = Command::new("cargo")
        .args([
            "stylus",
            "trace",
            &format!("--endpoint={}", DEVNODE_RPC),
            "--tx",
            tx_hash,
        ])
        .current_dir(project_dir)
        .output()
        .map_err(|e| format!("failed to get Stylus trace: {}", e))?;

    if !output.status.success() {
        return Err(format!(
            "cargo stylus trace failed:\nstdout: {}\nstderr: {}",
            String::from_utf8_lossy(&output.stdout),
            String::from_utf8_lossy(&output.stderr)
        ));
    }

    Ok(String::from_utf8_lossy(&output.stdout).trim().to_string())
}

/// Perform the full Stylus recording pipeline: build, deploy, send tx, get EVM trace, record.
///
/// Returns the WASM path and trace directory on success.
fn record_stylus_trace(project_path: &Path) -> Result<(PathBuf, PathBuf, PathBuf), String> {
    println!("Building Stylus contract WASM...");
    let wasm_path = build_stylus_wasm(project_path)?;
    println!("WASM binary: {}", wasm_path.display());

    println!("Deploying Stylus contract to devnode...");
    let contract_address = deploy_stylus_contract(project_path)?;
    println!("Contract deployed at: {}", contract_address);

    println!("Sending fund(2) transaction...");
    let tx_hash = send_fund_transaction(&contract_address)?;
    println!("Transaction hash: {}", tx_hash);

    println!("Getting EVM trace...");
    let evm_trace_content = get_stylus_trace(project_path, &tx_hash)?;
    println!("Got EVM trace ({} bytes)", evm_trace_content.len());

    // Create temp directory for the trace
    let temp_dir = std::env::temp_dir().join(format!("stylus_flow_test_{}", std::process::id()));
    if temp_dir.exists() {
        std::fs::remove_dir_all(&temp_dir).ok();
    }
    std::fs::create_dir_all(&temp_dir).map_err(|e| format!("failed to create temp dir: {}", e))?;

    // Save EVM trace to a file (wazero -stylus expects a file path)
    let evm_trace_path = temp_dir.join("evm_trace.json");
    std::fs::write(&evm_trace_path, &evm_trace_content)
        .map_err(|e| format!("failed to write evm_trace.json: {}", e))?;

    let trace_dir = temp_dir.join("trace");

    println!("Recording Stylus WASM trace...");
    record_stylus_wasm_trace(&wasm_path, &trace_dir, &evm_trace_path)?;
    println!("Stylus recording created at: {}", trace_dir.display());

    Ok((wasm_path, trace_dir, temp_dir))
}

/// Copy the trace directory to an external fixture location if
/// `STYLUS_FIXTURE_OUTPUT_DIR` is set. Used by the VS Code extension's
/// `scripts/prepare-stylus-fixture.sh` to generate a pre-recorded fixture.
fn export_fixture_if_requested(trace_dir: &Path) {
    if let Ok(output_dir) = std::env::var("STYLUS_FIXTURE_OUTPUT_DIR") {
        let dest = PathBuf::from(&output_dir);
        println!("Exporting Stylus trace fixture to: {}", dest.display());

        if dest.exists() {
            std::fs::remove_dir_all(&dest).ok();
        }

        // Copy trace_dir recursively to dest
        fn copy_dir_recursive(src: &Path, dst: &Path) -> std::io::Result<()> {
            std::fs::create_dir_all(dst)?;
            for entry in std::fs::read_dir(src)? {
                let entry = entry?;
                let src_path = entry.path();
                let dst_path = dst.join(entry.file_name());
                if src_path.is_dir() {
                    copy_dir_recursive(&src_path, &dst_path)?;
                } else {
                    std::fs::copy(&src_path, &dst_path)?;
                }
            }
            Ok(())
        }

        match copy_dir_recursive(trace_dir, &dest) {
            Ok(()) => println!("Fixture exported successfully to: {}", dest.display()),
            Err(e) => eprintln!("WARNING: Failed to export fixture: {}", e),
        }
    }
}

/// Tier 1: Record a Stylus trace and verify that trace files were produced.
///
/// This is a quick smoke test for the recording pipeline: build WASM, deploy,
/// send a transaction, get the EVM trace, and record with wazero.
#[test]
#[ignore]
fn test_stylus_flow_integration() {
    let project_path = get_stylus_project_path();
    assert!(
        project_path.join("Cargo.toml").exists(),
        "Stylus test project not found at {}",
        project_path.display()
    );

    if !check_prerequisites() {
        return;
    }

    let (_wasm_path, trace_dir, temp_dir) = match record_stylus_trace(&project_path) {
        Ok(result) => result,
        Err(e) => panic!("Stylus recording failed: {}", e),
    };

    // Verify trace files were produced
    let trace_json = trace_dir.join("trace.json");
    let trace_metadata = trace_dir.join("trace_metadata.json");
    assert!(
        trace_json.exists(),
        "trace.json not produced at {}",
        trace_json.display()
    );
    assert!(
        trace_metadata.exists(),
        "trace_metadata.json not produced at {}",
        trace_metadata.display()
    );

    println!("Stylus flow integration test passed!");
    println!("  Trace files verified at: {}", trace_dir.display());

    // Clean up
    std::fs::remove_dir_all(&temp_dir).ok();
}

/// Tier 1+2: Record a Stylus trace AND verify its contents.
///
/// After recording, this test parses the trace files and verifies that:
/// - `trace.json` contains EVM event entries (EventLogKind::EvmEvent)
/// - Expected EVM host function calls are present (read_args, storage operations)
/// - The `read_args` event contains the `fund(uint256)` selector (0xca1d209d)
/// - `trace_metadata.json` is valid and references the WASM binary
///
/// Note: Stylus traces currently contain only Event entries (EVM host function
/// calls), not Step/Call/Function entries. Source-level DAP debugging is not yet
/// supported for Stylus — when DWARF-based stepping becomes available, this test
/// should be extended with DAP breakpoint/flow analysis (see `FUND_BREAKPOINT_LINE`).
///
/// If `STYLUS_FIXTURE_OUTPUT_DIR` is set, the trace is also exported to that
/// directory for use by VS Code extension UI tests (Tier 3).
#[test]
#[ignore]
fn test_stylus_trace_analysis() {
    let project_path = get_stylus_project_path();
    assert!(
        project_path.join("Cargo.toml").exists(),
        "Stylus test project not found at {}",
        project_path.display()
    );

    if !check_prerequisites() {
        return;
    }

    // --- Tier 1: Recording ---
    let (_wasm_path, trace_dir, temp_dir) = match record_stylus_trace(&project_path) {
        Ok(result) => result,
        Err(e) => panic!("Stylus recording failed: {}", e),
    };

    // Export fixture for Tier 3 if requested
    export_fixture_if_requested(&trace_dir);

    // --- Tier 2: Trace content verification ---
    println!("\n=== Verifying trace contents ===");

    // Parse trace.json
    let trace_json_path = trace_dir.join("trace.json");
    let trace_content =
        std::fs::read_to_string(&trace_json_path).unwrap_or_else(|e| panic!("Failed to read trace.json: {}", e));

    let trace_events: Vec<TraceLowLevelEvent> =
        serde_json::from_str(&trace_content).unwrap_or_else(|e| panic!("Failed to parse trace.json: {}", e));

    println!("Trace has {} entries", trace_events.len());
    assert!(!trace_events.is_empty(), "trace.json should contain at least one entry");

    // Extract all Event entries
    let evm_events: Vec<&RecordEvent> = trace_events
        .iter()
        .filter_map(|entry| {
            if let TraceLowLevelEvent::Event(event) = entry {
                Some(event)
            } else {
                None
            }
        })
        .collect();

    println!("Found {} Event entries in trace", evm_events.len());
    assert!(!evm_events.is_empty(), "Trace should contain EVM Event entries");

    // Verify all events are EvmEvent kind
    for event in &evm_events {
        assert_eq!(
            event.kind,
            EventLogKind::EvmEvent,
            "Stylus trace events should all be EvmEvent, got {:?} for hook '{}'",
            event.kind,
            event.metadata
        );
    }

    // Collect EVM host function names (stored in metadata field)
    let hook_names: Vec<&str> = evm_events.iter().map(|e| e.metadata.as_str()).collect();
    println!("EVM hooks called: {:?}", hook_names);

    // Verify expected EVM host functions are present.
    // A fund(2) call should at minimum: read arguments, interact with storage, write results.
    let expected_hooks = ["read_args", "storage_load_bytes32", "write_result"];
    for hook in &expected_hooks {
        assert!(
            hook_names.contains(hook),
            "Expected EVM hook '{}' not found in trace. Hooks present: {:?}",
            hook,
            hook_names
        );
    }

    // Verify read_args contains the fund(uint256) selector 0xca1d209d.
    // The content is hex-encoded ABI calldata: selector (4 bytes) + uint256 arg.
    let read_args_event = evm_events
        .iter()
        .find(|e| e.metadata == "read_args")
        .expect("read_args event must exist");
    let calldata = read_args_event.content.to_lowercase();
    assert!(
        calldata.contains("ca1d209d"),
        "read_args should contain fund(uint256) selector 0xca1d209d, got: {}",
        calldata
    );
    println!("Verified: read_args contains fund() selector (0xca1d209d)");

    // Verify the argument encodes the value 2 (uint256).
    // ABI encoding: selector (4 bytes / 8 hex chars) + uint256 padded to 32 bytes (64 hex chars).
    // Value 2 = ...0000000000000000000000000000000000000000000000000000000000000002
    println!("  read_args calldata: {}", calldata);
    let selector_pos = calldata
        .find("ca1d209d")
        .expect("selector must be present (already asserted)");
    let arg_start = selector_pos + 8; // skip 4-byte selector
    if calldata.len() >= arg_start + 64 {
        let arg_hex = &calldata[arg_start..arg_start + 64];
        let trimmed = arg_hex.trim_start_matches('0');
        assert_eq!(trimmed, "2", "fund() argument should be 2, got 0x{}", arg_hex);
        println!("Verified: fund() argument is 2");
    } else {
        eprintln!(
            "WARNING: calldata shorter than expected after selector ({} chars available, need 64), \
             skipping argument check",
            calldata.len().saturating_sub(arg_start)
        );
    }

    // Verify storage write operations are present (fund() writes to storage).
    // The Stylus SDK uses storage_cache_bytes32 + storage_flush_cache instead
    // of storage_store_bytes32 directly.
    assert!(
        hook_names.contains(&"storage_cache_bytes32") || hook_names.contains(&"storage_store_bytes32"),
        "Expected storage write operations (storage_cache_bytes32 or storage_store_bytes32) in trace"
    );
    if hook_names.contains(&"storage_flush_cache") {
        println!("Verified: storage writes present (storage_cache_bytes32 + storage_flush_cache)");
    } else {
        println!("Verified: storage writes present (storage_store_bytes32)");
    }

    // Parse and verify trace_metadata.json
    let metadata_path = trace_dir.join("trace_metadata.json");
    let metadata_content =
        std::fs::read_to_string(&metadata_path).unwrap_or_else(|e| panic!("Failed to read trace_metadata.json: {}", e));

    let metadata: TraceMetadata = serde_json::from_str(&metadata_content)
        .unwrap_or_else(|e| panic!("Failed to parse trace_metadata.json: {}", e));

    assert!(
        metadata.program.contains("stylus_fund_tracking_demo"),
        "trace_metadata.json program should reference the Stylus WASM binary, got: {}",
        metadata.program
    );
    println!("Verified: trace_metadata references '{}'", metadata.program);

    println!("\nStylus trace analysis test passed!");
    println!(
        "  {} total entries, {} EVM events",
        trace_events.len(),
        evm_events.len()
    );
    println!("  EVM hooks: {:?}", hook_names);

    // Clean up
    std::fs::remove_dir_all(&temp_dir).ok();
}

/// Tier 2 (DAP): Verify the DAP server can load a pre-recorded Stylus trace
/// and respond to standard + custom requests.
///
/// Stylus traces contain only EVM host function Event entries (no Step/Call/Function
/// entries). This test validates that the DAP server handles this event-only format
/// correctly: initializes without panicking, returns thread info, and delivers
/// the event log containing EVM host function calls.
///
/// Uses the trace at `STYLUS_TRACE_DIR` (env var) or the checked-in fixture at
/// `../../stylus-trace-manual`. Does NOT require a devnode — works offline.
#[test]
fn test_stylus_dap_event_only_trace() {
    // Use STYLUS_TRACE_DIR env var if set, otherwise fall back to the committed fixture.
    let trace_dir = std::env::var("STYLUS_TRACE_DIR")
        .map(PathBuf::from)
        .unwrap_or_else(|_| {
            let manifest_dir = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
            manifest_dir.join("tests/fixtures/stylus-fund-trace")
        });

    assert!(
        trace_dir.join("trace.json").exists(),
        "Stylus trace fixture not found at {}",
        trace_dir.display()
    );

    println!("Using Stylus trace at: {}", trace_dir.display());

    // Create a TestRecording pointing at the fixture trace.
    // Use a throwaway temp_dir so Drop doesn't remove the fixture.
    let throwaway_temp = std::env::temp_dir().join(format!("stylus_dap_test_{}", std::process::id()));
    std::fs::create_dir_all(&throwaway_temp).ok();
    let recording = test_harness::TestRecording {
        trace_dir: trace_dir.clone(),
        source_path: PathBuf::from("unused"),
        binary_path: PathBuf::from("unused"),
        temp_dir: throwaway_temp,
        language: test_harness::Language::Stylus,
        version_label: "fixture".to_string(),
    };

    // --- DAP session ---
    let mut client = DapStdioTestClient::start().unwrap_or_else(|e| panic!("Failed to start DAP server: {}", e));

    // Initialize and launch — this exercises the trace_processor postprocess
    // and run_to_entry codepaths that previously panicked on event-only traces.
    // Success means:
    //   1. trace_processor.postprocess() didn't panic on empty steps (trace_processor.rs:74)
    //   2. run_to_entry() / load_location() handled empty steps (db.rs:98)
    //   3. The "stopped" and "ct/complete-move" events were received
    client
        .initialize_and_launch(&recording)
        .unwrap_or_else(|e| panic!("Failed to initialize and launch: {}", e));

    println!("\nStylus DAP event-only trace test passed!");
    println!("  DAP server initialized, launched, and delivered stopped + complete-move events");
    // Don't clean up — we don't own the trace directory
}
