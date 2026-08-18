//! Integration regression test for the Omniscience loop controls
//! (issues #562 / #593 / #595 / #606).
//!
//! # What is being pinned
//!
//! `FlowMode::Call` must return the flow window of the **enclosing call**, and
//! that window must be **invariant** while the user steps around inside the
//! call. Everything the Omniscience loop controls render is derived from it:
//!
//!   * `loops[k].rr_ticks_for_iterations` — one entry per loop iteration whose
//!     header the flow walker passed, i.e. the slider's tick stops;
//!   * `loops[k].iteration`               — the highest iteration index in the
//!     window, i.e. the "from N" total;
//!   * `loop_iteration_steps[k]`          — one table per iteration;
//!   * `steps[i].iteration`               — the per-step iteration index the
//!     frontend matches against the debugger location.
//!
//! Before the fix, the materialized (DB) branch of
//! `CallFlowPreloader::move_to_first_step` started the window at the *current*
//! statement instead of the enclosing call entry, while the RR branch widened.
//! Because a loop iteration is only counted when the walker passes the loop
//! **header**, the window then dropped every iteration before the cursor:
//! stepping forward one iteration made the reported total shrink
//! ("0 from 10" -> "0 from 8" -> "0 from 6", #595), pinned the active iteration
//! at 0 (#593), collapsed `loop.iteration` to 0 near the loop end so the slider
//! was suppressed (#562), and hid the flow of every line before the cursor
//! (#606).
//!
//! # No mocks
//!
//! This test records a real Python trace with the real recorder and drives the
//! real DAP server, per the workspace policy of preferring integration tests
//! that mock as little as possible. It skips loudly if the recorder or a
//! suitable Python is unavailable.

mod test_harness;

use std::path::PathBuf;
use std::time::Duration;

use db_backend::dap::DapMessage;
use db_backend::task::{CtLoadFlowArguments, FlowMode, Location};
use test_harness::{DapStdioTestClient, Language, TestRecording};

/// Line of `for i in range(n):` in `python_loop_window_test.py`.
const LOOP_HEADER_LINE: i64 = 14;

/// Line of `doubled = i * 2` — the first loop-body line, our breakpoint.
const LOOP_BODY_LINE: u32 = 15;

/// Lines inside `accumulate` that execute BEFORE the loop. They must be
/// present in the flow window at every stop (#606: full function scope).
const LINES_BEFORE_LOOP: [i64; 2] = [12, 13];

/// `range(n)` argument in the program: the body runs exactly this many times.
const TOTAL_ITERATIONS: usize = 10;

/// Number of `rr_ticks_for_iterations` entries the backend reports for that
/// loop.
///
/// It is `TOTAL_ITERATIONS + 1`, not `TOTAL_ITERATIONS`: `process_loops` starts
/// a new iteration every time the walker passes the loop HEADER line, and
/// CPython executes `for i in range(n):` one extra time — the visit that
/// exhausts the iterator and leaves the loop. So a 10-body-execution Python
/// `for` reports 11 header visits.
///
/// This is a property of the language/recorder, not of the window, and it is
/// deliberately NOT what this test is about. What matters here is that the
/// count is the same at every stop; the assertion is written against a literal
/// so a change in either direction is noticed rather than absorbed.
const EXPECTED_ITERATION_ENTRIES: usize = TOTAL_ITERATIONS + 1;

/// 1-based breakpoint hits to inspect; each maps to 0-based iteration hit - 1.
const HITS_TO_INSPECT: [u32; 3] = [1, 4, 8];

fn source_path() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("test-programs/python/python_loop_window_test.py")
}

/// A single `ct/load-flow` result, kept as raw JSON.
///
/// The shared `test_harness::FlowData` deliberately projects only variables and
/// values; the loop metadata this test is about is not part of that projection,
/// so we read the DAP event body directly rather than widening a helper that
/// every other flow test depends on.
struct RawFlow {
    view_update: serde_json::Value,
}

impl RawFlow {
    fn steps(&self) -> &Vec<serde_json::Value> {
        self.view_update["steps"].as_array().expect("flow steps array")
    }

    /// The loop entry whose header is `LOOP_HEADER_LINE`.
    ///
    /// `loops[0]` is a always-present sentinel (`FlowViewUpdate::new`), so we
    /// match on the header line instead of hardcoding an index.
    fn accumulate_loop(&self) -> (usize, &serde_json::Value) {
        self.view_update["loops"]
            .as_array()
            .expect("flow loops array")
            .iter()
            .enumerate()
            .find(|(_, l)| l["first"].as_i64() == Some(LOOP_HEADER_LINE))
            .unwrap_or_else(|| {
                panic!(
                    "no loop registered for header line {} in flow window; loops={}",
                    LOOP_HEADER_LINE, self.view_update["loops"]
                )
            })
    }

    fn lines(&self) -> Vec<i64> {
        self.steps()
            .iter()
            .filter_map(|s| s["position"].as_i64())
            .collect::<std::collections::BTreeSet<_>>()
            .into_iter()
            .collect()
    }

    /// The `iteration` recorded for the flow step at exactly `rr_ticks`.
    fn iteration_at_ticks(&self, rr_ticks: i64) -> Option<i64> {
        self.steps()
            .iter()
            .find(|s| s["rrTicks"].as_i64() == Some(rr_ticks))
            .and_then(|s| s["iteration"].as_i64())
    }
}

/// Issue `ct/load-flow` for `location` and return the raw view update.
///
/// `DapStdioTestClient::request_flow` parses into the harness' projected
/// `FlowData`; we need the untouched payload, so we build the request through
/// the public escape hatches the harness exposes for exactly this purpose.
fn request_raw_flow(client: &mut DapStdioTestClient, location: Location) -> RawFlow {
    let args = CtLoadFlowArguments {
        flow_mode: FlowMode::Call,
        location,
    };
    let request = {
        let dap = client.dap_client_mut();
        dap.request("ct/load-flow", serde_json::to_value(args).expect("flow args serialize"))
    };
    client.send_message(&request).expect("failed to send ct/load-flow");

    let event = client
        .read_until_event_msg("ct/updated-flow", Duration::from_secs(30))
        .expect("no ct/updated-flow event");
    let body = match event {
        DapMessage::Event(e) => e.body,
        _ => panic!("expected an event"),
    };
    let view_update = body["viewUpdates"]
        .as_array()
        .and_then(|v| v.first())
        .cloned()
        .expect("flow update should carry at least one view update");
    RawFlow { view_update }
}

#[test]
fn materialized_call_flow_window_is_stable_across_loop_iterations() {
    if test_harness::find_python_recorder().is_none() {
        eprintln!("SKIPPED: Python recorder not found (set CODETRACER_PYTHON_RECORDER_PATH)");
        return;
    }
    let (_python_cmd, version_label) = match test_harness::find_suitable_python() {
        Some(pair) => pair,
        None => {
            eprintln!("SKIPPED: Python 3.10+ not found (needed for the recorder)");
            return;
        }
    };

    let source = source_path();
    assert!(source.exists(), "test program missing at {}", source.display());

    let recording = TestRecording::create_db_trace_with_format(&source, Language::Python, &version_label, "ctfs")
        .expect("Python recording failed");

    // The Python recorder stores bare filenames relative to its CWD (the trace
    // dir), so breakpoints must be set on the trace-dir copy.
    let bp_source = recording.trace_dir.join(source.file_name().unwrap());

    let mut client = DapStdioTestClient::start().expect("failed to start DAP client");
    client
        .initialize_and_launch(&recording)
        .expect("failed to initialize DAP session");
    client
        .set_breakpoint(&bp_source, LOOP_BODY_LINE)
        .expect("failed to set breakpoint");

    let mut hit = 0u32;
    let mut stop: Option<Location> = None;
    let mut observed_totals = Vec::new();

    for &target_hit in HITS_TO_INSPECT.iter() {
        while hit < target_hit {
            stop = Some(
                client
                    .continue_to_breakpoint()
                    .expect("failed to continue to breakpoint"),
            );
            hit += 1;
        }

        // Re-issue the flow request with exactly the shape the frontend uses on
        // every move: an exact `rrTicks` for the current stop.
        let stop = stop.clone().expect("stopped location should be available");
        let stop_ticks = stop.rr_ticks.0;

        let flow = request_raw_flow(&mut client, stop);
        let (loop_index, loop_entry) = flow.accumulate_loop();

        let ticks_for_iterations = loop_entry["rrTicksForIterations"]
            .as_array()
            .expect("rrTicksForIterations array")
            .len();
        let reported_total = loop_entry["iteration"].as_i64().expect("loop iteration");
        let iteration_tables = flow.view_update["loopIterationSteps"][loop_index]
            .as_array()
            .expect("loopIterationSteps entry for this loop")
            .len();

        println!(
            "hit {}: stop_ticks={} rrTicksForIterations={} loop.iteration={} \
             loopIterationSteps={} lines={:?}",
            target_hit,
            stop_ticks,
            ticks_for_iterations,
            reported_total,
            iteration_tables,
            flow.lines()
        );

        // (1) #595: the total must not shrink as the cursor advances.
        assert_eq!(
            ticks_for_iterations, EXPECTED_ITERATION_ENTRIES,
            "hit {}: the flow window must contain every loop iteration of the call, \
             expected {} entries, got {} (a shrinking window is the \
             '0 from 10 -> 0 from 8 -> 0 from 6' regression)",
            target_hit, EXPECTED_ITERATION_ENTRIES, ticks_for_iterations
        );
        assert_eq!(
            reported_total,
            (EXPECTED_ITERATION_ENTRIES - 1) as i64,
            "hit {}: loop.iteration is the highest iteration index in the window",
            target_hit
        );
        assert_eq!(
            iteration_tables, EXPECTED_ITERATION_ENTRIES,
            "hit {}: one loop_iteration_steps table per iteration",
            target_hit
        );
        observed_totals.push(ticks_for_iterations);

        // (2) #593: the step the user is stopped on must carry the TRUE
        // iteration index, counting from the start of the call — not 0.
        let expected_iteration = (target_hit - 1) as i64;
        let actual_iteration = flow
            .iteration_at_ticks(stop_ticks)
            .unwrap_or_else(|| panic!("hit {}: no flow step at rrTicks={}", target_hit, stop_ticks));
        assert_eq!(
            actual_iteration, expected_iteration,
            "hit {}: flow step at the stop should report iteration {} (counting 0,1,2,... \
             from the call entry), got {}",
            target_hit, expected_iteration, actual_iteration
        );

        // (3) #606: the window covers the WHOLE call, including the lines that
        // executed before the cursor. A forward-only window loses these.
        let lines = flow.lines();
        for before in LINES_BEFORE_LOOP {
            assert!(
                lines.contains(&before),
                "hit {}: flow window must cover line {} (executed before the stop); \
                 covered lines were {:?}",
                target_hit,
                before,
                lines
            );
        }
    }

    assert!(
        observed_totals.windows(2).all(|w| w[0] == w[1]),
        "the iteration total must be identical at every stop, got {:?}",
        observed_totals
    );

    println!("flow loop-iteration window test passed");
}
