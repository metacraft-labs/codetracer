//! Reproduces the WDIO ``finds "compute" in the calltrace`` failure
//! from codetracer-evm-recorder cross-repo-tests against a locally
//! recorded EVM trace.
//!
//! The cross-repo WDIO test sends ``ct/load-calltrace-section`` (via
//! ``session.loadCalltrace({depth:50,height:200})``) and times out
//! with ``DAP request timeout`` after 10 s.  This test exercises the
//! same DAP request directly against a freshly-recorded
//! ``FlowTest.sol`` trace so the round-trip can be debugged with
//! ``RUST_LOG``.
//!
//! Run with::
//!
//!   CODETRACER_EVM_RECORDER_PATH=… cargo nextest run evm_load_calltrace
//!
//! Gated on ``CODETRACER_EVM_RECORDER_PATH`` + a sibling
//! ``codetracer-evm-recorder`` checkout + ``solc`` and ``anvil`` on
//! PATH -- silently skipped without all of them (same convention as
//! ``solidity_flow_dap_test``).

use std::path::PathBuf;
use std::time::Duration;

use ct_dap_client::test_support::FlowTestRunner;
use serde_json::json;

mod test_harness;
use test_harness::{Language, TestRecording, find_evm_recorder};

fn find_db_backend() -> PathBuf {
    PathBuf::from(env!("CARGO_BIN_EXE_replay-server"))
}

#[test]
#[ignore = "requires evm-recorder + solc + anvil; run via: just test-evm-load-calltrace"]
fn evm_load_calltrace_returns_compute_call() {
    assert!(
        find_evm_recorder().is_some(),
        "EVM recorder not found.  Set CODETRACER_EVM_RECORDER_PATH or build codetracer-evm-recorder.",
    );

    let db_backend = find_db_backend();

    // Use the recorder's canonical FlowTest.sol contract.  Sibling
    // resolution mirrors ``solidity_flow_dap_test``.
    let recorder_repo = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../../codetracer-evm-recorder");
    let source_path = recorder_repo.join("contracts/FlowTest.sol");
    assert!(
        source_path.exists(),
        "FlowTest.sol not found at {}",
        source_path.display(),
    );

    let recording = TestRecording::create_db_trace(&source_path, Language::Solidity, "evm-1.0")
        .expect("EVM recording failed -- check that solc/anvil are on PATH");

    let mut runner =
        FlowTestRunner::new_db_trace(&db_backend, &recording.trace_dir).expect("DAP init failed for EVM trace");

    let client = runner.client();
    let seq = client
        .send_request("ct/load-calltrace-section", json!({ "depth": 50, "height": 200 }))
        .expect("send_request failed");
    eprintln!("Sent ct/load-calltrace-section seq={seq}");

    // The WDIO client's default timeout is 10 s; replicate it.  A
    // healthy load-calltrace returns near-instantly for a trace this
    // small (a few hundred steps + 4 calls per my local recorder
    // run).
    let response = client.recv_response(Duration::from_secs(10));
    match response {
        Ok(resp) => {
            eprintln!(
                "Received response request_seq={} success={} command={} body_chars={}",
                resp.request_seq,
                resp.success,
                resp.command,
                resp.body.to_string().chars().count(),
            );
            assert!(resp.success, "DAP responded with success=false: {resp:?}");
            assert_eq!(resp.command, "ct/load-calltrace-section");
            let body_str = resp.body.to_string();
            assert!(
                body_str.contains("compute"),
                "expected the loaded calltrace to reference ``compute``; \
                 got body: {body_str}",
            );
        }
        Err(e) => {
            panic!(
                "ct/load-calltrace-section timed out / errored: {e}\n\
                 This reproduces the WDIO ``finds \"compute\" in the calltrace`` \
                 failure from codetracer-evm-recorder cross-repo-tests.",
            );
        }
    }

    runner.finish().expect("disconnect failed");
}
