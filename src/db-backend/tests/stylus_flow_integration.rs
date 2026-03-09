//! Integration test for Stylus (Arbitrum WASM) flow/omniscience support
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
//! Prerequisites:
//! - Arbitrum devnode running on localhost:8547
//! - `cargo-stylus` on PATH
//! - `cast` (Foundry) on PATH
//! - `wazero` on PATH or set via CODETRACER_WASM_VM_PATH
//! - `wasm32-unknown-unknown` Rust target installed

mod test_harness;

use std::path::{Path, PathBuf};
use std::process::Command;
use test_harness::find_wazero;

const DEVNODE_RPC: &str = "http://localhost:8547";
// Standard test private key for Arbitrum devnodes
const TEST_PRIVATE_KEY: &str = "0xb6b15c8cb491557369f3c7d2c287b053eb229daa9c22138887752191c9520659";

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

    // Parse the contract address from the deploy output
    let stdout = String::from_utf8_lossy(&output.stdout);
    for line in stdout.lines() {
        if line.contains("deployed code at address") || line.contains("contract address") {
            // Extract hex address
            if let Some(addr) = line.split_whitespace().find(|w| w.starts_with("0x") && w.len() >= 42) {
                return Ok(addr.to_string());
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

    // Parse tx hash from output
    let stdout = String::from_utf8_lossy(&output.stdout);
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
        .args(["stylus", "trace", &format!("--endpoint={}", DEVNODE_RPC), tx_hash])
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

/// Record WASM execution with Stylus EVM trace using wazero.
fn record_stylus_wasm_trace(wasm_path: &Path, trace_dir: &std::path::Path, evm_trace: &str) -> Result<(), String> {
    let wazero = find_wazero().ok_or("wazero not found")?;
    std::fs::create_dir_all(trace_dir).map_err(|e| format!("failed to create trace dir: {}", e))?;

    let output = Command::new(&wazero)
        .args([
            "run",
            "-stylus",
            evm_trace,
            "--trace-dir",
            trace_dir.to_str().unwrap(),
            wasm_path.to_str().unwrap(),
        ])
        .output()
        .map_err(|e| format!("failed to run wazero with Stylus trace: {}", e))?;

    if !output.status.success() {
        return Err(format!(
            "Stylus WASM recording failed:\nstdout: {}\nstderr: {}",
            String::from_utf8_lossy(&output.stdout),
            String::from_utf8_lossy(&output.stderr)
        ));
    }

    Ok(())
}

#[test]
#[ignore]
fn test_stylus_flow_integration() {
    let project_path = get_stylus_project_path();
    assert!(
        project_path.join("Cargo.toml").exists(),
        "Stylus test project not found at {}",
        project_path.display()
    );

    // Check all prerequisites
    if !is_devnode_available() {
        eprintln!("SKIPPED: Arbitrum devnode not reachable at {}", DEVNODE_RPC);
        return;
    }
    if !is_cargo_stylus_available() {
        eprintln!("SKIPPED: cargo-stylus not found on PATH");
        return;
    }
    if !is_cast_available() {
        eprintln!("SKIPPED: cast (Foundry) not found on PATH");
        return;
    }
    if find_wazero().is_none() {
        eprintln!("SKIPPED: wazero not found");
        return;
    }

    println!("Building Stylus contract WASM...");
    let wasm_path = match build_stylus_wasm(&project_path) {
        Ok(p) => p,
        Err(e) => {
            panic!("Failed to build Stylus WASM: {}", e);
        }
    };
    println!("WASM binary: {}", wasm_path.display());

    println!("Deploying Stylus contract to devnode...");
    let contract_address = match deploy_stylus_contract(&project_path) {
        Ok(addr) => addr,
        Err(e) => {
            panic!("Failed to deploy contract: {}", e);
        }
    };
    println!("Contract deployed at: {}", contract_address);

    println!("Sending fund(2) transaction...");
    let tx_hash = match send_fund_transaction(&contract_address) {
        Ok(hash) => hash,
        Err(e) => {
            panic!("Failed to send transaction: {}", e);
        }
    };
    println!("Transaction hash: {}", tx_hash);

    println!("Getting EVM trace...");
    let evm_trace = match get_stylus_trace(&project_path, &tx_hash) {
        Ok(trace) => trace,
        Err(e) => {
            panic!("Failed to get Stylus trace: {}", e);
        }
    };
    println!("Got EVM trace ({} bytes)", evm_trace.len());

    // Record WASM execution
    let temp_dir = std::env::temp_dir().join(format!("stylus_flow_test_{}", std::process::id()));
    if temp_dir.exists() {
        std::fs::remove_dir_all(&temp_dir).ok();
    }
    std::fs::create_dir_all(&temp_dir).unwrap();
    let trace_dir = temp_dir.join("trace");

    println!("Recording Stylus WASM trace...");
    match record_stylus_wasm_trace(&wasm_path, &trace_dir, &evm_trace) {
        Ok(()) => println!("Stylus recording created at: {}", trace_dir.display()),
        Err(e) => {
            std::fs::remove_dir_all(&temp_dir).ok();
            panic!("Failed to record Stylus trace: {}", e);
        }
    }

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
