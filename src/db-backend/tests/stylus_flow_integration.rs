//! Integration tests for Stylus (Arbitrum WASM) recording.
//!
//! A Stylus recording is a replay. The transaction is traced on the Nitro
//! node with `debug_traceTransaction` and the `stylusTracer`
//! (`cargo stylus trace`), which lists every hostio the contract made with
//! its arguments and results; `wazero run -stylus` then re-executes the
//! contract's debug wasm with a `vm_hooks` host module that answers each
//! hostio from that capture, and the replay is the materialized trace.
//!
//! The capture of a `fund(2)` transaction against
//! `test-programs/stylus_fund_tracker` is committed as that project's
//! `evm_trace.json`, so the default tests need no node:
//!
//! - `test_stylus_flow_integration`: replays the capture and checks that a
//!   `.ct` container was produced.
//! - `test_stylus_trace_analysis`: replays the capture and checks the
//!   trace's contents: the hostio events (`read_args`, storage reads and
//!   writes, `write_result`), the `fund(uint256)` calldata and its argument,
//!   and the metadata naming the contract's wasm.
//! - `test_stylus_dap_trace`: loads the committed CTFS fixture in the DAP
//!   server.
//!
//! `capture_stylus_fund_transaction_from_devnode` is the live path, and is
//! `#[ignore]`d: it deploys the contract to a Nitro dev node, sends
//! `fund(2)`, re-captures `evm_trace.json`, and runs the same analysis on
//! the fresh capture. Run it after changing the contract or its SDK:
//!
//! ```text
//! cargo test --test stylus_flow_integration -- --ignored --nocapture \
//!     capture_stylus_fund_transaction_from_devnode
//! ```
//!
//! It needs a dev node at `http://localhost:8547` (OffchainLabs
//! `nitro-devnode`'s `run-dev-node.sh`), `cargo-stylus` and `cast`.
//!
//! The replay needs `wazero` (on PATH in the dev shells, or
//! `CODETRACER_WASM_VM_PATH`) and a Rust toolchain with the
//! `wasm32-unknown-unknown` target.
//!
//! No mocks: the host interface is answered from a real node's capture of a
//! real transaction.

mod test_harness;

use std::path::{Path, PathBuf};
use std::process::Command;
use test_harness::{
    DapStdioTestClient, STYLUS_EVM_TRACE_FILE, find_wazero, record_stylus_project_trace,
    skip_or_fail_missing_prerequisite,
};

use codetracer_trace_types::{EventLogKind, RecordEvent, TraceLowLevelEvent};

const DEVNODE_RPC: &str = "http://localhost:8547";
// The pre-funded account of the Nitro dev node.
const TEST_PRIVATE_KEY: &str = "0xb6b15c8cb491557369f3c7d2c287b053eb229daa9c22138887752191c9520659";

/// Returns the path to the Stylus fund tracker test project.
fn get_stylus_project_path() -> PathBuf {
    let manifest_dir = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    manifest_dir.join("../../test-programs/stylus_fund_tracker")
}

/// The replay's prerequisites; reports a missing one through the loud-skip
/// gate and returns false.
fn replay_prerequisites_present(test_name: &str) -> bool {
    if find_wazero().is_none() {
        skip_or_fail_missing_prerequisite(
            test_name,
            "the wazero recorder is not available",
            "enter the dev shell, or set CODETRACER_WASM_VM_PATH",
        );
        return false;
    }
    if !test_harness::is_command_available("cargo") {
        skip_or_fail_missing_prerequisite(test_name, "cargo is not on PATH", "enter the dev shell");
        return false;
    }
    true
}

/// Replay the committed `fund(2)` capture into a fresh trace directory.
///
/// Returns `(trace_dir, temp_dir)`; the caller removes `temp_dir`.
fn record_committed_capture(project_path: &Path, label: &str) -> Result<(PathBuf, PathBuf), String> {
    let temp_dir = std::env::temp_dir().join(format!("stylus_flow_{}_{}", label, std::process::id()));
    if temp_dir.exists() {
        std::fs::remove_dir_all(&temp_dir).ok();
    }
    std::fs::create_dir_all(&temp_dir).map_err(|e| format!("failed to create temp dir: {}", e))?;
    let trace_dir = temp_dir.join("trace");
    record_stylus_project_trace(project_path, &trace_dir)?;
    Ok((trace_dir, temp_dir))
}

fn strip_ansi(text: &str) -> String {
    let ansi_re = regex::Regex::new(r"\x1b\[[0-9;]*m").unwrap();
    ansi_re.replace_all(text, "").into_owned()
}

fn run_checked(cmd: &mut Command, what: &str) -> Result<String, String> {
    let output = cmd.output().map_err(|e| format!("failed to run {}: {}", what, e))?;
    if !output.status.success() {
        return Err(format!(
            "{} failed:\nstdout: {}\nstderr: {}",
            what,
            String::from_utf8_lossy(&output.stdout),
            String::from_utf8_lossy(&output.stderr)
        ));
    }
    Ok(strip_ansi(&String::from_utf8_lossy(&output.stdout)))
}

/// Deploy the contract to the dev node from a scratch copy of the project.
///
/// cargo-stylus insists on a `rust-toolchain.toml` naming an exact version;
/// the copy names the toolchain actually in use, so a machine without rustup
/// deploys with the compiler it has, and the build output stays out of the
/// tree.
fn deploy_stylus_contract(project_dir: &Path, work_dir: &Path) -> Result<String, String> {
    let copy = work_dir.join("contract");
    let status = Command::new("cp")
        .arg("-r")
        .arg(project_dir)
        .arg(&copy)
        .status()
        .map_err(|e| format!("failed to copy the contract project: {}", e))?;
    if !status.success() {
        return Err("failed to copy the contract project".to_string());
    }
    std::fs::remove_dir_all(copy.join("target")).ok();
    let rustc_version = run_checked(Command::new("rustc").arg("--version"), "rustc --version")?;
    let version = rustc_version
        .split_whitespace()
        .nth(1)
        .ok_or_else(|| format!("unexpected rustc --version output: {}", rustc_version))?;
    std::fs::write(
        copy.join("rust-toolchain.toml"),
        format!(
            "[toolchain]\nchannel = \"{}\"\ntargets = [\"wasm32-unknown-unknown\"]\n",
            version
        ),
    )
    .map_err(|e| format!("failed to write rust-toolchain.toml: {}", e))?;

    let stdout = run_checked(
        Command::new("cargo")
            .args([
                "stylus",
                "deploy",
                &format!("--endpoint={}", DEVNODE_RPC),
                &format!("--private-key={}", TEST_PRIVATE_KEY),
                "--no-verify",
            ])
            .current_dir(&copy),
        "cargo stylus deploy",
    )?;
    for line in stdout.lines() {
        if line.contains("deployed code at address")
            && let Some(addr) = line.split_whitespace().find(|w| w.starts_with("0x") && w.len() >= 42)
        {
            return Ok(addr[..42].to_string());
        }
    }
    Err(format!(
        "could not parse contract address from deploy output:\n{}",
        stdout
    ))
}

/// Send a `fund(2)` transaction using Foundry's `cast send`.
fn send_fund_transaction(contract_address: &str) -> Result<String, String> {
    let stdout = run_checked(
        Command::new("cast").args([
            "send",
            "--json",
            "--rpc-url",
            DEVNODE_RPC,
            "--private-key",
            TEST_PRIVATE_KEY,
            contract_address,
            "fund(uint256)",
            "2",
        ]),
        "cast send",
    )?;
    let receipt: serde_json::Value = serde_json::from_str(stdout.trim())
        .map_err(|e| format!("cast send printed no JSON receipt ({}): {}", e, stdout))?;
    receipt
        .get("transactionHash")
        .and_then(|h| h.as_str())
        .map(str::to_string)
        .ok_or_else(|| format!("cast send receipt has no transactionHash: {}", stdout))
}

/// The `stylusTracer` capture of `tx_hash`, as `cargo stylus trace` prints it.
fn capture_transaction(tx_hash: &str) -> Result<String, String> {
    run_checked(
        Command::new("cargo").args([
            "stylus",
            "trace",
            &format!("--endpoint={}", DEVNODE_RPC),
            "--use-native-tracer",
            "--tx",
            tx_hash,
        ]),
        "cargo stylus trace",
    )
}

/// One hostio per line, so a re-capture diffs readably.
fn format_capture(raw: &str) -> Result<String, String> {
    let events: Vec<serde_json::Value> =
        serde_json::from_str(raw.trim()).map_err(|e| format!("capture is not a JSON array ({}): {}", e, raw))?;
    let lines: Vec<String> = events
        .iter()
        .map(|e| serde_json::to_string(e).map(|l| format!("  {}", l)))
        .collect::<Result<_, _>>()
        .map_err(|e| e.to_string())?;
    Ok(format!("[\n{}\n]\n", lines.join(",\n")))
}

/// Load the recording's metadata from the `.ct` CTFS container in `trace_dir`.
///
/// Per `Trace-Files/CTFS-Migration-Guide.md` §3e the `.ct` container is the
/// only supported materialized-trace format, and `meta.dat` is where its
/// metadata lives. The legacy `meta.json` block this used to read is retired —
/// no writer emits it — and the sidecar `trace_metadata.json` was already not
/// accepted.
fn load_stylus_trace_metadata(trace_dir: &Path) -> Result<db_backend::ctfs_trace_reader::meta_dat::MetaDat, String> {
    // Pick the first `*.ct` file in `trace_dir` (recorders may name it
    // `trace.ct` or `<program>.ct`).
    let ct_path = std::fs::read_dir(trace_dir)
        .map_err(|e| format!("read_dir {}: {}", trace_dir.display(), e))?
        .filter_map(|e| e.ok())
        .map(|e| e.path())
        .find(|p| p.extension().is_some_and(|ext| ext == "ct"))
        .ok_or_else(|| format!("no *.ct CTFS container in {}", trace_dir.display()))?;

    let mut ctfs = db_backend::ctfs_trace_reader::ctfs_container::CtfsReader::open(&ct_path)
        .map_err(|e| format!("open {}: {}", ct_path.display(), e))?;
    let meta_bytes = ctfs
        .read_file("meta.dat")
        .map_err(|e| format!("read meta.dat from {}: {}", ct_path.display(), e))?;
    db_backend::ctfs_trace_reader::meta_dat::parse_meta_dat(&meta_bytes)
        .map_err(|e| format!("parse meta.dat from {}: {:?}", ct_path.display(), e))
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

/// Replay the committed capture and verify a CTFS container was produced.
#[test]
fn test_stylus_flow_integration() {
    let project_path = get_stylus_project_path();
    assert!(
        project_path.join(STYLUS_EVM_TRACE_FILE).is_file(),
        "committed Stylus capture missing at {}",
        project_path.join(STYLUS_EVM_TRACE_FILE).display()
    );
    if !replay_prerequisites_present("test_stylus_flow_integration") {
        return;
    }

    let (trace_dir, temp_dir) = record_committed_capture(&project_path, "smoke")
        .unwrap_or_else(|e| panic!("Stylus replay of the committed capture failed: {}", e));

    // Per `Trace-Files/CTFS-Migration-Guide.md` §3e, `.ct` is the only
    // supported materialized-trace format.
    let has_ct = std::fs::read_dir(&trace_dir)
        .map(|entries| {
            entries
                .filter_map(|e| e.ok())
                .any(|e| e.path().extension().is_some_and(|ext| ext == "ct"))
        })
        .unwrap_or(false);
    assert!(has_ct, "no *.ct CTFS container produced at {}", trace_dir.display());

    std::fs::remove_dir_all(&temp_dir).ok();
}

/// Replay the committed capture and verify the trace's contents.
///
/// Stylus traces carry EVM host-function Event entries next to the
/// DWARF-derived steps; see [`verify_fund_trace`] for what is checked.
///
/// If `STYLUS_FIXTURE_OUTPUT_DIR` is set, the trace is also exported to that
/// directory for use by the VS Code extension's UI tests.
#[test]
fn test_stylus_trace_analysis() {
    let project_path = get_stylus_project_path();
    if !replay_prerequisites_present("test_stylus_trace_analysis") {
        return;
    }

    let (trace_dir, temp_dir) = record_committed_capture(&project_path, "analysis")
        .unwrap_or_else(|e| panic!("Stylus replay of the committed capture failed: {}", e));
    export_fixture_if_requested(&trace_dir);
    verify_fund_trace(&trace_dir);

    std::fs::remove_dir_all(&temp_dir).ok();
}

/// Live path: re-capture the `fund(2)` transaction from a Nitro dev node,
/// write it over the committed `evm_trace.json`, and verify a replay of the
/// fresh capture.
#[test]
#[ignore = "needs a Nitro dev node; regenerates the committed capture"]
fn capture_stylus_fund_transaction_from_devnode() {
    let project_path = get_stylus_project_path();
    let devnode_up = Command::new("cast")
        .args(["chain-id", "--rpc-url", DEVNODE_RPC])
        .output()
        .map(|o| o.status.success())
        .unwrap_or(false);
    // Asked for explicitly, so a missing prerequisite is a failure.
    assert!(
        devnode_up,
        "no Nitro dev node answers at {} (or `cast` is missing)",
        DEVNODE_RPC
    );
    assert!(
        Command::new("cargo")
            .args(["stylus", "--version"])
            .output()
            .is_ok_and(|o| o.status.success()),
        "cargo-stylus is not available"
    );

    let work_dir = std::env::temp_dir().join(format!("stylus_capture_{}", std::process::id()));
    std::fs::remove_dir_all(&work_dir).ok();
    std::fs::create_dir_all(&work_dir).expect("create the capture work dir");

    let address = deploy_stylus_contract(&project_path, &work_dir).unwrap_or_else(|e| panic!("{}", e));
    println!("Contract deployed at: {}", address);
    let tx_hash = send_fund_transaction(&address).unwrap_or_else(|e| panic!("{}", e));
    println!("fund(2) transaction: {}", tx_hash);
    let raw = capture_transaction(&tx_hash).unwrap_or_else(|e| panic!("{}", e));
    let capture = format_capture(&raw).unwrap_or_else(|e| panic!("{}", e));
    let capture_path = project_path.join(STYLUS_EVM_TRACE_FILE);
    std::fs::write(&capture_path, capture)
        .unwrap_or_else(|e| panic!("failed to write {}: {}", capture_path.display(), e));
    println!("Wrote {}", capture_path.display());

    let (trace_dir, temp_dir) = record_committed_capture(&project_path, "live")
        .unwrap_or_else(|e| panic!("Stylus replay of the fresh capture failed: {}", e));
    verify_fund_trace(&trace_dir);

    std::fs::remove_dir_all(&temp_dir).ok();
    std::fs::remove_dir_all(&work_dir).ok();
}

/// Verify a replay of a `fund(2)` transaction against the fund tracker:
/// - the events are EVM host-function events, including `read_args`,
///   `storage_load_bytes32` and `write_result`;
/// - `read_args` carries the `fund(uint256)` selector (0xca1d209d) and the
///   argument 2;
/// - storage writes are present;
/// - the trace metadata names the contract's wasm.
fn verify_fund_trace(trace_dir: &Path) {
    println!("\n=== Verifying trace contents ===");

    // Locate the .ct CTFS container produced by wazero -stylus and pull
    // recorded events out via the CTFS reader. Materialized traces are
    // CTFS-only; the legacy `trace.json` sidecar is no longer accepted.
    let ct_path = std::fs::read_dir(trace_dir)
        .unwrap_or_else(|e| panic!("read_dir {}: {}", trace_dir.display(), e))
        .filter_map(|e| e.ok())
        .map(|e| e.path())
        .find(|p| p.extension().is_some_and(|ext| ext == "ct"))
        .unwrap_or_else(|| panic!("no *.ct CTFS container produced at {}", trace_dir.display()));

    let ctfs_reader = db_backend::ctfs_trace_reader::CTFSTraceReader::open(&ct_path)
        .unwrap_or_else(|e| panic!("Failed to open CTFS container {}: {}", ct_path.display(), e));

    // Synthesize a `TraceLowLevelEvent` view from the populated Db so the
    // assertions below (which were written against the raw event stream)
    // continue to work without re-parsing the on-disk encoding.
    let db = ctfs_reader.db();
    let trace_events: Vec<TraceLowLevelEvent> = db
        .events
        .iter()
        .map(|ev| {
            TraceLowLevelEvent::Event(RecordEvent {
                kind: ev.kind,
                content: ev.content.clone(),
                metadata: ev.metadata.clone(),
            })
        })
        .collect();

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

    // Every event is a host-function event. The recorder registers them as
    // `EvmEvent`, but the multi-stream CTFS IO-event stream has no EVM kind:
    // the Nim writer stores `EvmEvent` (and `TraceLogEvent`) as `ioStderr`,
    // which the reader returns as `WriteOther`. Either kind is accepted until
    // the format carries the distinction; any other kind is a defect.
    for event in &evm_events {
        assert!(
            matches!(event.kind, EventLogKind::EvmEvent | EventLogKind::WriteOther),
            "Stylus trace events are host-function events, got {:?} for hook '{}'",
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
    assert!(
        calldata.len() >= arg_start + 64,
        "read_args calldata ends before the uint256 argument: {}",
        calldata
    );
    let arg_hex = &calldata[arg_start..arg_start + 64];
    let trimmed = arg_hex.trim_start_matches('0');
    assert_eq!(trimmed, "2", "fund() argument should be 2, got 0x{}", arg_hex);
    println!("Verified: fund() argument is 2");

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

    // Parse and verify trace metadata.  Per the CTFS migration guide
    // (Trace-Files/CTFS-Migration-Guide.md §3e) the canonical home for
    // metadata is `meta.dat` inside the `.ct` container.
    let metadata = load_stylus_trace_metadata(trace_dir)
        .unwrap_or_else(|e| panic!("Failed to load trace metadata from {}: {}", trace_dir.display(), e));

    assert!(
        metadata.program.contains("stylus_fund_tracking_demo"),
        "trace metadata program should reference the Stylus WASM binary, got: {}",
        metadata.program
    );
    println!("Verified: trace_metadata references '{}'", metadata.program);

    println!("\nStylus trace analysis passed!");
    println!(
        "  {} total entries, {} EVM events",
        trace_events.len(),
        evm_events.len()
    );
    println!("  EVM hooks: {:?}", hook_names);
}

/// Tier 2 (DAP): Verify the DAP server can load a pre-recorded Stylus trace
/// and respond to standard + custom requests.
///
/// Stylus traces contain both DWARF-based Step/Call/Function entries (from wazero
/// replaying the EVM trace through the debug WASM binary) and EVM host function
/// Event entries. This test validates that the DAP server handles this mixed
/// format correctly: initializes without panicking, returns thread info, and
/// delivers stopped + complete-move events.
///
/// Uses the CTFS trace at `STYLUS_TRACE_DIR` (env var) or the committed CTFS
/// fixture at `tests/fixtures/stylus-fund-trace/`. Does NOT require a devnode
/// — works offline once the fixture is present. Materialized traces are
/// CTFS-only; if the fixture is missing or only contains the legacy 3-file
/// JSON bundle, regenerate it via
/// `src/db-backend/tests/fixtures/regenerate-stylus-fixture.sh`.
//
// ROOT CAUSE (2026-05-20): Same blocker as `stylus_flow_dap_loads_ctfs_fixture`
// in tests/stylus_flow_dap_test.rs.  The CTFS fixture directory
// `tests/fixtures/stylus-fund-trace/` does not exist in the repository, and
// regenerating it requires an Arbitrum devnode at `http://localhost:8547`,
// `cargo-stylus`, and `cast` (Foundry) — all off-machine for this dev shell.
// The test bails at the `assert!(has_ct, ...)` check with the correct
// regeneration directive.  Resolution: produce the fixture on an Arbitrum-
// capable host (run `regenerate-stylus-fixture.sh`) and commit the resulting
// `<program>.ct` next to the regen script.  No reader-side workaround is
// acceptable because the CTFS migration removed the legacy 3-file path on
// purpose (see codetracer-specs Trace-Files/CTFS-Migration-Guide §3e).
#[test]
fn test_stylus_dap_trace() {
    // Use STYLUS_TRACE_DIR env var if set, otherwise fall back to the committed fixture.
    let trace_dir = std::env::var("STYLUS_TRACE_DIR")
        .map(PathBuf::from)
        .unwrap_or_else(|_| {
            let manifest_dir = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
            manifest_dir.join("tests/fixtures/stylus-fund-trace")
        });

    // Require a CTFS .ct container inside the fixture directory.
    let has_ct = std::fs::read_dir(&trace_dir)
        .map(|entries| {
            entries
                .filter_map(|e| e.ok())
                .any(|e| e.path().is_file() && e.path().extension().is_some_and(|ext| ext == "ct"))
        })
        .unwrap_or(false);
    assert!(
        has_ct,
        "Stylus CTFS fixture not found at {}.\n  \
         Regenerate it via \
         src/db-backend/tests/fixtures/regenerate-stylus-fixture.sh\n  \
         (requires Arbitrum devnode + cargo-stylus + cast + wazero).",
        trace_dir.display()
    );

    println!("Using Stylus CTFS trace at: {}", trace_dir.display());

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

    // Initialize and launch — this exercises the CTFS reader and
    // run_to_entry codepaths that previously panicked on event-only traces.
    // Success means:
    //   1. CTFSTraceReader::open didn't panic on empty steps
    //   2. run_to_entry() / load_location() handled empty steps (db.rs:98)
    //   3. The "stopped" and "ct/complete-move" events were received
    client
        .initialize_and_launch(&recording)
        .unwrap_or_else(|e| panic!("Failed to initialize and launch: {}", e));

    println!("\nStylus DAP trace test passed!");
    println!("  DAP server initialized, launched, and delivered stopped + complete-move events");
    // Don't clean up — we don't own the trace directory
}
