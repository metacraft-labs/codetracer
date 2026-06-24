//! M1b — MCR streaming-flow scenario driving the UNIFIED follow reader path.
//!
//! This is the `e2e_mcr_streaming_flow_via_unified_reader` verification the M1
//! milestone calls for: a real `ct-mcr`-recorded split-stream `.ct` is read
//! through the SAME unified follow path the live/streaming case uses — the
//! db-backend [`FollowReader`] over a `FollowFileSource`, driving the production
//! Rust seekable decode across the steps / values / calls split streams — rather
//! than a separate streaming reader used only in synthetic-fixture tests.
//!
//! ## Gating (honest skip — see the sibling `*_mcr_streaming_flow_test.rs`)
//!
//! Like every other MCR-flow test, this needs the native recorder sibling
//! (`ct-mcr` + `ct-native-replay`). When those are not built in the current
//! environment the test SKIPS (prints `SKIPPED: …` and returns) exactly as the
//! sibling C/Rust/Go/… MCR flow tests do — it does not fake a pass. The M1
//! milestone records this verification as `pending` until it is observed green
//! in a recorder-capable CI lane.
//!
//! ## Scope vs. the synthetic follow tests
//!
//! `follow_stream_flow_test.rs` proves the follow reader observes growth on a
//! container a test writer is STILL appending to. This test proves the SAME
//! unified reader reads a real RECORDER-produced split-stream container
//! end-to-end (an MCR `.ct` is committed/finalized by the time `record` returns,
//! so the reader sees a sealed container and drains every chunk on its first
//! refresh). Together they cover the follow path against both a growing
//! synthetic container and a real recorder's split-stream output.

#![allow(clippy::expect_used, clippy::unwrap_used, clippy::panic)]

use std::path::PathBuf;

use db_backend::ctfs_trace_reader::follow_stream_source::FollowReader;

mod test_harness;
use test_harness::{Language, TestRecording};

#[test]
fn e2e_mcr_streaming_flow_via_unified_reader() {
    // ── pre-flight: the MCR recorder sibling must be available ──
    let ct_rr_support = match test_harness::find_ct_rr_support() {
        Some(p) => p,
        None => {
            eprintln!("SKIPPED: ct-native-replay not found");
            return;
        }
    };
    if !test_harness::is_mcr_available() {
        eprintln!("SKIPPED: MCR backend not available (ct-mcr not found)");
        return;
    }

    // ── record a C program under MCR, producing a split-stream `.ct` ──
    let source_path = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("test-programs/c/c_flow_test.c");
    assert!(
        source_path.exists(),
        "C test program not found at {}",
        source_path.display()
    );

    let recording =
        TestRecording::create_mcr(&source_path, Language::C, "mcr", &ct_rr_support).expect("MCR recording failed");
    let ct_path = &recording.trace_dir; // create_mcr stores the `.ct` path here.

    // ── drive the recorded `.ct` through the UNIFIED follow reader ──
    let mut reader = FollowReader::open(ct_path).expect("FollowReader failed to open the MCR .ct");
    // A finalized container drains every committed chunk on the first refresh.
    reader.refresh().expect("unified follow refresh failed");

    assert!(
        reader.is_finalized(),
        "a recorder-produced .ct is sealed (meta.dat committed) by the time record returns"
    );

    // The execution stream must be present and non-empty: a real recording has
    // steps. (The follow reader's step gate keys off `steps.idx`; a split-stream
    // MCR `.ct` carries it.)
    let step_count = reader.steps().step_count();
    assert!(
        step_count > 0,
        "the unified follow reader must surface the recorded execution steps (got {step_count})"
    );

    // Every surfaced step must carry a real source location decoded through the
    // production seekable path (the same decode the final-file reader uses).
    for i in 0..step_count {
        let step = reader.steps().step(i).expect("decoded step");
        assert!(step.line.0 >= 0, "step {i} has a valid source line");
    }

    // Values/calls are advertised by their own capability flags. When present,
    // the unified reader surfaces them through the same follow path; assert the
    // counts are coherent with the step stream rather than requiring a specific
    // schema the recorder may evolve.
    let value_count = reader.values().value_count();
    let call_count = reader.calls().call_count();
    eprintln!("unified follow over MCR .ct: {step_count} steps, {value_count} values, {call_count} calls");
    if value_count > 0 {
        assert_eq!(
            value_count, step_count,
            "value records are parallel-indexed to steps (record N ↔ step N)"
        );
    }
}
