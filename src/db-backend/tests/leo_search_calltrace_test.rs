//! Reproduces the WDIO ``can search the calltrace for "compute"`` failure
//! from codetracer-leo-recorder cross-repo-tests against a local leo trace.
//!
//! The cross-repo WDIO test sends ``ct/search-calltrace {value:"compute"}``
//! and times out with ``DAP request timeout`` after 10 s.  This test
//! exercises the same DAP request directly against a freshly-recorded leo
//! flow_test trace so the round-trip can be debugged with ``RUST_LOG``.
//!
//! Run with::
//!
//!   CODETRACER_LEO_RECORDER_PATH=… cargo nextest run leo_search_calltrace
//!
//! The test is gated on a ``CODETRACER_LEO_RECORDER_PATH`` /
//! ``codetracer-leo-recorder`` sibling — without those it is silently
//! skipped (same convention as ``leo_flow_dap_test``).

use std::path::PathBuf;
use std::time::Duration;

use ct_dap_client::test_support::FlowTestRunner;
use serde_json::json;

mod test_harness;
use test_harness::{Language, TestRecording, find_leo_flow_test, find_leo_recorder};

fn find_db_backend() -> PathBuf {
    PathBuf::from(env!("CARGO_BIN_EXE_replay-server"))
}

#[test]
#[ignore = "requires leo-recorder; run via: just test-leo-search-calltrace"]
fn leo_search_calltrace_returns_compute_call() {
    assert!(
        find_leo_recorder().is_some(),
        "Leo recorder not found.  Set CODETRACER_LEO_RECORDER_PATH or build codetracer-leo-recorder.",
    );

    let db_backend = find_db_backend();
    let source_path = find_leo_flow_test().expect("flow_test.leo not found");

    let recording =
        TestRecording::create_db_trace(&source_path, Language::Leo, "leo-1.0").expect("Leo recording failed");

    let mut runner =
        FlowTestRunner::new_db_trace(&db_backend, &recording.trace_dir).expect("DAP init failed for Leo trace");

    // Mirror the WDIO leo-deep ordering: set a breakpoint at line 5,
    // continue to it, load flow, *then* search the calltrace.  The
    // session state matters because each preceding ``ct/load-flow``
    // or breakpoint-stop event leaves the server in a different
    // worker state, and the WDIO failure only surfaces after those
    // preceding requests.
    let client = runner.client();
    client
        .set_breakpoints(source_path.to_str().unwrap(), &[5])
        .expect("set_breakpoints failed");
    eprintln!("Set breakpoint at line 5");
    let move_state = client.dap_continue().expect("continue failed");
    eprintln!("Continued to {:?}", move_state.location);
    let load_flow_seq = client
        .send_request("ct/load-flow", json!({ "flowMode": 0 }))
        .expect("send_request load-flow failed");
    let _ = client
        .recv_response(Duration::from_secs(10))
        .expect("ct/load-flow response timed out");
    eprintln!("ct/load-flow seq={load_flow_seq} responded");

    let seq = client
        .send_request("ct/search-calltrace", json!({ "value": "compute" }))
        .expect("send_request failed");
    eprintln!("Sent ct/search-calltrace seq={seq}");

    // The cross-repo WDIO timeout is 10 s; replicate it.  With the smoke
    // test confirming the leo calltrace contains ``compute``, this
    // response should arrive in well under a second on a healthy build.
    let response = client.recv_response(Duration::from_secs(10));
    match response {
        Ok(resp) => {
            eprintln!(
                "Received response request_seq={} success={} command={} body={}",
                resp.request_seq, resp.success, resp.command, resp.body,
            );
            assert!(resp.success, "DAP responded with success=false: {resp:?}");
            assert_eq!(resp.command, "ct/search-calltrace");
            let calls = resp.body.as_array().expect("response body must be a Call array");
            assert!(
                !calls.is_empty(),
                "expected at least one matching call in body; got {calls:?}",
            );
        }
        Err(e) => {
            panic!(
                "ct/search-calltrace timed out / errored: {e}\n\
                 This reproduces the WDIO ``can search the calltrace for compute`` \
                 failure from codetracer-leo-recorder cross-repo-tests.",
            );
        }
    }

    runner.finish().expect("disconnect failed");
}
