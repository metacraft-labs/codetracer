//! Pillar-E Option-B: DAP-level flow test for a Rust program recorded under the
//! COOPERATIVE-SYMMETRIC MCR backend (macOS arm64, SIP-off).
//!
//! Unlike `rust_mcr_streaming_flow_test` (which records via the DYLD-insert MCR
//! recorder and replays via the DYLD-insert worker — the path that diverges/
//! hangs on the layout-sensitive Rust runtime), this test drives the flow
//! pipeline through the cooperative-symmetric query server:
//!
//!   * The cooperatively-linked program + cooperatively-recorded `.ct` are
//!     built out-of-band (the cooperative link recipe is Nim-only) and passed
//!     in via CT_COOP_TRACE_CT / CT_COOP_PROGRAM / CT_COOP_SOURCE.
//!   * CT_COOP_QUERY=1 + CT_COOP_RECREATOR=<ct-mcr> make db-backend's recreator
//!     spawn `ct-mcr replay-worker --coop-query` instead of the diverging DYLD
//!     worker.  That worker brings the SAME program up symmetrically (no
//!     divergence), stops held at `calculate_sum`, and answers the JSON
//!     ReplayQuery protocol (LoadLocation / LoadValue / LoadLocals) with REAL
//!     values read from the held child's registers + memory.
//!
//! Asserts the same flow values as the streaming test:
//!   a = 10, b = 32, sum = 42, doubled = 84, final_result = 94.
//!
//! ## Why it is `#[ignore]`d
//!
//! Its inputs cannot be produced by any test lane: the cooperatively-linked
//! program and its recording are made by hand, on a SIP-disabled macOS arm64
//! host, and handed in through the environment. Run by default it could only
//! ever return early and be counted as passed, so it is ignored instead, which
//! the runner reports as not run. Run it with `--ignored` after supplying the
//! artefacts; if any of them is missing it then FAILS, naming what is missing.

use std::collections::HashMap;
use std::path::PathBuf;

use ct_dap_client::test_support::{FlowTestConfig, FlowTestRunner};

mod test_harness;
use test_harness::{Language, TestRecording};

fn find_db_backend() -> PathBuf {
    PathBuf::from(env!("CARGO_BIN_EXE_replay-server"))
}

#[test]
#[ignore = "manual: needs an out-of-band cooperative recording (CT_COOP_TRACE_CT, CT_COOP_PROGRAM, CT_COOP_SOURCE) and CT_COOP_QUERY=1; no lane produces one"]
fn rust_mcr_coop_flow_variables_and_values() {
    let recording = TestRecording::from_cooperative_env(Language::Rust).unwrap_or_else(|| {
        panic!(
            "this test was run explicitly but its cooperative recording is not supplied: set \
             CT_COOP_TRACE_CT (an existing .ct), CT_COOP_PROGRAM and CT_COOP_SOURCE"
        )
    });
    assert_eq!(
        std::env::var("CT_COOP_QUERY").as_deref(),
        Ok("1"),
        "this test was run explicitly but CT_COOP_QUERY is not 1, so db-backend would not use the \
         cooperative query server it exists to exercise"
    );

    let db_backend = find_db_backend();
    let source_path = recording.source_path.clone();

    println!("cooperative MCR trace: {}", recording.trace_dir.display());
    println!("cooperative program:   {}", recording.binary_path.display());

    let mut expected_values = HashMap::new();
    expected_values.insert("a".to_string(), 10);
    expected_values.insert("b".to_string(), 32);
    expected_values.insert("sum".to_string(), 42);
    expected_values.insert("doubled".to_string(), 84);
    expected_values.insert("final_result".to_string(), 94);

    let config = FlowTestConfig {
        source_file: source_path.to_str().unwrap().to_string(),
        breakpoint_line: 12,
        expected_variables: vec!["a", "b", "sum", "doubled", "final_result"]
            .into_iter()
            .map(String::from)
            .collect(),
        excluded_identifiers: vec!["println".to_string()],
        expected_values,
    };

    let mut runner =
        FlowTestRunner::new(&db_backend, &recording.trace_dir).expect("DAP init failed for cooperative MCR trace");
    runner
        .run_and_verify(&config)
        .expect("Rust cooperative MCR flow test failed");
    runner.finish().expect("disconnect failed");
}
