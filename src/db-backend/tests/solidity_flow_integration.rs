//! Integration test for Solidity/EVM flow/omniscience support.
//!
//! This test verifies the full recording-to-DAP pipeline for Solidity contracts:
//! 1. Compile the test contract with `solc`
//! 2. Deploy to a local Anvil node
//! 3. Record a transaction trace with `codetracer-evm-recorder`
//! 4. Load the trace in the DAP server
//! 5. Verify expected local variables and values are present in flow data
//!
//! ## Prerequisites
//!
//! - `codetracer-evm-recorder` binary (set `CODETRACER_EVM_RECORDER_PATH` or
//!   build it in the sibling repo `codetracer-evm-recorder/`)
//! - `solc` (Solidity compiler) on PATH or set `SOLC_PATH`
//! - `anvil` (Foundry) on PATH for a local EVM node
//!
//! The test is `#[ignore]` by default — run with:
//!   `cargo nextest run --run-ignored all test_solidity_flow`
//! or:
//!   `just test-solidity-flow`

mod test_harness;

use std::collections::HashMap;
use std::path::PathBuf;
use test_harness::{FlowTestConfig, Language, find_evm_recorder, run_db_flow_test};

fn get_solidity_source_path() -> PathBuf {
    let manifest_dir = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    manifest_dir.join("test-programs/solidity/solidity_flow_test.sol")
}

/// Check if `solc` (Solidity compiler) is available on PATH or via `SOLC_PATH`.
fn create_solidity_flow_config() -> FlowTestConfig {
    let mut expected_values = HashMap::new();
    // Canonical flow-test values: a=10, b=32, sum_val=42, doubled=84, final_result=94
    expected_values.insert("a".to_string(), 10);
    expected_values.insert("b".to_string(), 32);
    expected_values.insert("sum_val".to_string(), 42);
    expected_values.insert("doubled".to_string(), 84);
    expected_values.insert("final_result".to_string(), 94);

    FlowTestConfig {
        source_path: get_solidity_source_path(),
        language: Language::Solidity,
        // Line 39: `uint256 final_result = doubled + 10;` — all 5 locals are in scope here.
        breakpoint_line: 39,
        expected_variables: vec![
            "a".to_string(),
            "b".to_string(),
            "sum_val".to_string(),
            "doubled".to_string(),
            "final_result".to_string(),
        ],
        // `storedResult` and `emit` should not appear as local variables
        excluded_identifiers: vec!["storedResult".to_string(), "Computed".to_string()],
        expected_values,
    }
}

/// Integration test for the Solidity flow/omniscience pipeline.
///
/// Records a transaction that calls `FlowTest.run()` and verifies that flow
/// data contains the expected local variable values at the breakpoint inside
/// `run()`.
///
/// Prerequisites: `codetracer-evm-recorder`, `solc`, and `anvil`.
/// These are provided by the Nix dev shell (`nix develop`).
#[test]
#[ignore = "requires evm-recorder dev shell (solc, anvil); run via: just test-solidity-flow"]
fn test_solidity_flow_integration() {
    // --- Prerequisite checks ---
    assert!(
        find_evm_recorder().is_some(),
        "EVM recorder not found. \
         Set CODETRACER_EVM_RECORDER_PATH or build codetracer-evm-recorder \
         (run `cargo build` inside the codetracer-evm-recorder repo)."
    );

    // solc and anvil are provided by the EVM recorder's dev shell.
    // The record_solidity_trace function uses direnv exec to access them,
    // so we don't need to check for them on the current PATH.

    let source_path = get_solidity_source_path();
    assert!(
        source_path.exists(),
        "Solidity test program not found at {}",
        source_path.display()
    );

    let config = create_solidity_flow_config();

    match run_db_flow_test(&config, "solidity-0.8") {
        Ok(()) => println!("Solidity flow integration test passed!"),
        Err(e) => panic!("Solidity flow integration test failed: {}", e),
    }
}
