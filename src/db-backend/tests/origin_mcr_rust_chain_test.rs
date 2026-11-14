//! Value origin on an MCR recording of a Rust program, through the DAP
//! server: the chain of `c` in `origin/rust/simple_trivial_chain`
//! (`let a = 10; let b = a; let c = b;`) is `c = b`, `b = a`, `a = 10`
//! (ANSWERS.md), drawn by the rr-driver algorithm (`run_rr_origin_chain`)
//! over `ct-native-replay`'s MCR loop and `ct-mcr debugserver`, within the
//! default request budget (`DEFAULT_ORIGIN_WALL_CLOCK_MS`).
//!
//! The stop is reached through a line BREAKPOINT, as a user reaches it. The
//! MCR loop used to let LLDB resume into the reverse continue's queued stop
//! with that breakpoint enabled; LLDB stepped over the breakpoint site, the
//! step consumed the queued write stop and the continue ran on to the
//! breakpoint again, so every hop re-issued until the per-hop cap
//! (`mcr_report_historical_stop_to_lldb` in codetracer-native-backend).
//!
//! After the walk the replay is back at the stop (Value-Origin-Tracking §6.3,
//! "The replay after a walk"): the top frame is the `println!` line again,
//! and a second query there answers like the first. Without the return, the
//! replay stood at the first write (`a`'s), where `c` has no write before it.
//!
//! No mocks: the fixture is compiled and recorded with `ct-mcr` (through
//! `ct-native-replay record --backend mcr`), and replayed by the real worker
//! and debugserver. Missing `ct-native-replay` or `ct-mcr` fails with the
//! remedy.

mod test_harness;

use std::path::PathBuf;
use std::time::{Duration, Instant};

use db_backend::dap::DapMessage;
use db_backend::task::{CtOriginChainArguments, DEFAULT_ORIGIN_MAX_HOPS, OriginChain, OriginKind};
use serde_json::json;

fn fixture() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures/origin/rust/simple_trivial_chain/main.rs")
}

fn origin_chain_of(client: &mut test_harness::DapStdioTestClient, variable: &str) -> (OriginChain, Duration) {
    let args = CtOriginChainArguments {
        variable_name: variable.to_string(),
        variable_path: Vec::new(),
        frame_id: -1,
        // The current stop, as the desktop asks.
        step_id: -1,
        thread_id: 0,
        max_hops: DEFAULT_ORIGIN_MAX_HOPS,
        lazy: false,
        continuation_token: None,
        session_id: String::new(),
        classify_source: true,
    };
    let started = Instant::now();
    let req = client
        .dap_client_mut()
        .request("ct/originChain", serde_json::to_value(args).expect("args"));
    client.send_message(&req).expect("send ct/originChain");
    let response = client
        .read_until_response_msg("ct/originChain", Duration::from_secs(60))
        .expect("ct/originChain response");
    let elapsed = started.elapsed();
    match response {
        DapMessage::Response(r) => {
            assert!(r.success, "ct/originChain failed: {:?} {}", r.message, r.body);
            (serde_json::from_value(r.body).expect("OriginChain"), elapsed)
        }
        other => panic!("expected a response, got {other:?}"),
    }
}

fn hops(chain: &OriginChain) -> Vec<String> {
    chain
        .hops
        .iter()
        .map(|h| format!("{} = {}", h.target_expr, h.source_expr))
        .collect()
}

fn top_frame_line(client: &mut test_harness::DapStdioTestClient) -> i64 {
    let req = client
        .dap_client_mut()
        .request("stackTrace", json!({ "threadId": 1, "startFrame": 0, "levels": 1 }));
    client.send_message(&req).expect("send stackTrace");
    match client
        .read_until_response_msg("stackTrace", Duration::from_secs(30))
        .expect("stackTrace response")
    {
        DapMessage::Response(r) => {
            assert!(r.success, "stackTrace failed: {:?} {}", r.message, r.body);
            r.body["stackFrames"][0]["line"]
                .as_i64()
                .unwrap_or_else(|| panic!("no top frame line in {}", r.body))
        }
        other => panic!("expected a response, got {other:?}"),
    }
}

#[test]
fn origin_mcr_rust_simple_trivial_chain_within_budget_and_back_at_the_stop() {
    let ct_native_replay = test_harness::find_ct_native_replay()
        .expect("ct-native-replay was not found: build it, or set CT_NATIVE_REPLAY_PATH");
    assert!(
        test_harness::is_mcr_available(),
        "ct-mcr was not found: `just build-ct-mcr` in codetracer-native-recorder, or set CODETRACER_CT_MCR_CMD"
    );
    let source = fixture();
    let recording =
        test_harness::TestRecording::create_mcr(&source, test_harness::Language::Rust, "mcr", &ct_native_replay)
            .expect("MCR recording failed");
    let line = test_harness::find_line_containing(&source, "println!(\"{}\", c)") as u32;

    let mut client = test_harness::DapStdioTestClient::start().expect("DAP stdio client should start");
    client
        .initialize_and_launch_rr(&recording, &ct_native_replay)
        .expect("launch of the MCR recording");
    client.set_breakpoint(&recording.source_path, line).expect("breakpoint");
    let location = client.continue_to_breakpoint().expect("continue to the println! line");
    assert_eq!(location.line, line as i64, "stopped at {location:?}");

    let (first, elapsed) = origin_chain_of(&mut client, "c");
    eprintln!(
        "origin chain of c on MCR: {:?}, terminator {:?} `{}`, {} ms",
        hops(&first),
        first.terminator.kind,
        first.terminator.expression,
        elapsed.as_millis()
    );
    assert_eq!(
        hops(&first),
        vec!["c = b", "b = a", "a = 10"],
        "the chain ANSWERS.md names: {first:?}"
    );
    assert!(first.hops[..2].iter().all(|h| h.kind == OriginKind::TrivialCopy));

    assert_eq!(
        top_frame_line(&mut client),
        line as i64,
        "after the walk the replay must be back at the println! line"
    );
    let (second, _) = origin_chain_of(&mut client, "c");
    assert_eq!(
        hops(&second),
        hops(&first),
        "a second query at the stop must answer like the first"
    );
}
