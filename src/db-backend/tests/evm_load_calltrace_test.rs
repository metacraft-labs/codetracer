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
fn evm_load_calltrace_returns_the_transactions_call_tree() {
    if find_evm_recorder().is_none() {
        test_harness::skip_or_fail_missing_prerequisite(
            "evm_load_calltrace_test",
            "EVM recorder not found.  Set CODETRACER_EVM_RECORDER_PATH or build codetracer-evm-recorder.",
            "check out the recorder sibling and build it (`just build-recorder-siblings`)",
        );
        return;
    }

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
            // FlowTest.sol's transaction enters through the contract's
            // dispatcher, which the recorder reports as the top-level frame,
            // and makes exactly one internal call: `add(10, 20)`, declared on
            // lines 20-22 and entered at step 17. `compute` is the external
            // entry point, inlined into that top-level frame; it is not a
            // call of its own.
            let body_str = resp.body.to_string();
            let calls: Vec<(i64, String, i64, Vec<(String, String)>)> = resp.body["callLines"]
                .as_array()
                .expect("callLines is an array")
                .iter()
                .filter(|line| line["content"]["kind"] == 0)
                .map(|line| {
                    let call = &line["content"]["call"];
                    let loc = &call["location"];
                    let args = call["args"]
                        .as_array()
                        .map(|args| {
                            args.iter()
                                .map(|a| {
                                    (
                                        a["name"].as_str().unwrap_or_default().to_string(),
                                        a["value"]["r"].as_str().unwrap_or_default().to_string(),
                                    )
                                })
                                .collect()
                        })
                        .unwrap_or_default();
                    (
                        line["depth"].as_i64().unwrap_or(-1),
                        call["rawName"].as_str().unwrap_or_default().to_string(),
                        loc["rrTicks"].as_i64().unwrap_or(-1),
                        args,
                    )
                })
                .collect();
            let expected = vec![
                (0, "<toplevel>".to_string(), 0, vec![]),
                (
                    1,
                    "add".to_string(),
                    17,
                    vec![
                        ("x".to_string(), "0xa".to_string()),
                        ("y".to_string(), "0x14".to_string()),
                    ],
                ),
            ];
            assert_eq!(
                calls, expected,
                "the calltrace is not <toplevel> -> add(10, 20); got body: {body_str}"
            );
            assert_eq!(resp.body["totalCallsCount"], 2, "got body: {body_str}");
            let add = &resp.body["callLines"][1]["content"]["call"]["location"];
            assert_eq!(
                (add["functionFirst"].as_i64(), add["functionLast"].as_i64()),
                (Some(20), Some(22)),
                "add is declared on lines 20-22; got body: {body_str}"
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
