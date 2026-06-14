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

    // Mirror the WDIO leo-deep ordering exhaustively: prior to the
    // ``ct/search-calltrace`` request the test does
    //   load-calltrace-section → event-load → load-locals →
    //   4×stepOver → stepIn → stepOut →
    //   removeAllBreakpoints → addBreakpoint(5) →
    //   continue → load-flow → search.
    // Each of these requests mutates the db-backend's session state
    // (current step_id, breakpoint list, expr_loader caches,
    // tracepoint workers) -- the WDIO failure only surfaces in this
    // settled-after-many-commands state, so reproduce the full
    // ordering rather than the minimal init+search the previous
    // version of this test had.
    let client = runner.client();

    let calltrace_seq = client
        .send_request(
            "ct/load-calltrace-section",
            json!({
                "location": {
                    "path": "", "line": 0, "functionName": "",
                    "highLevelPath": "", "highLevelLine": 0,
                    "highLevelFunctionName": "",
                    "lowLevelPath": "", "lowLevelLine": 0,
                    "rrTicks": 0, "functionFirst": 0,
                    "functionLast": 0, "event": 0, "expression": "",
                    "offset": 0, "error": false,
                    "callstackDepth": 0,
                    "originatingInstructionAddress": 0,
                    "key": "", "globalCallKey": "",
                },
                "startCallLineIndex": 0,
                "depth": 50, "height": 200,
                "rawIgnorePatterns": "",
                "autoCollapsing": false,
                "optimizeCollapse": false,
                "renderCallLineIndex": 0,
            }),
        )
        .expect("send load-calltrace-section");
    let _ = client
        .recv_response(Duration::from_secs(10))
        .expect("load-calltrace-section response timed out");
    eprintln!("load-calltrace-section seq={calltrace_seq} responded");

    let event_load_seq = client
        .send_request("ct/event-load", json!({}))
        .expect("send event-load");
    let _ = client
        .recv_response(Duration::from_secs(15))
        .expect("event-load response timed out");
    eprintln!("event-load seq={event_load_seq} responded");

    let load_locals_seq = client
        .send_request(
            "ct/load-locals",
            json!({
                "rrTicks": 0, "countBudget": 100, "minCountLimit": 10,
                "lang": 33, "watchExpressions": [], "depthLimit": 3,
            }),
        )
        .expect("send load-locals");
    let _ = client
        .recv_response(Duration::from_secs(10))
        .expect("load-locals response timed out");
    eprintln!("load-locals seq={load_locals_seq} responded");

    // WDIO uses DAP standard ``next``/``stepIn``/``stepOut`` requests
    // (not the ct/step custom protocol), so mirror that exactly --
    // they take a different code path inside the db-backend and the
    // step_id state transitions differ subtly.
    for i in 0..4 {
        let next_seq = client.send_request("next", json!({"threadId": 1})).expect("send next");
        let _ = client
            .recv_response(Duration::from_secs(10))
            .unwrap_or_else(|e| panic!("next #{i} response timed out: {e}"));
        eprintln!("DAP next #{i} seq={next_seq} responded");
    }
    let step_in_seq = client
        .send_request("stepIn", json!({"threadId": 1}))
        .expect("send stepIn");
    let _ = client
        .recv_response(Duration::from_secs(10))
        .expect("DAP stepIn response timed out");
    eprintln!("DAP stepIn seq={step_in_seq} responded");
    let step_out_seq = client
        .send_request("stepOut", json!({"threadId": 1}))
        .expect("send stepOut");
    let _ = client
        .recv_response(Duration::from_secs(10))
        .expect("DAP stepOut response timed out");
    eprintln!("DAP stepOut seq={step_out_seq} responded");

    // removeAllBreakpoints + addBreakpoint(5) + continue: mirror
    // WDIO's breakpoint exercise.
    client
        .set_breakpoints(source_path.to_str().unwrap(), &[])
        .expect("clear breakpoints failed");
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
