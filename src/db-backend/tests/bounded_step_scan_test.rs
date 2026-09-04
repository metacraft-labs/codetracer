//! M0 (BlockTracer "Browser Replay Gate") deliverable 3, `steps_from` half —
//! ordinary navigation walks the step stream WITHOUT building the whole step
//! table, and walks exactly the steps the slice-based code walked.
//!
//! ## The hole this closes
//!
//! `TraceReader::steps_from` returns a borrowed contiguous `&[DbStep]` running
//! to the end of the trace. A borrow of a contiguous array cannot be
//! synthesized from a chunked stream, so a reader backed by a seekable
//! `steps.dat` had to materialize the WHOLE step table — a `Vec<DbStep>` plus a
//! per-path line→steps map — to answer it.
//!
//! Every production caller was a walk that stops early:
//!
//! | caller | walk |
//! | --- | --- |
//! | `step_over_depths_step_id` (step-over / step-out, both directions) | until a step is shallow enough |
//! | `MaterializedReplaySession::step_continue` | until a breakpoint matches |
//! | `MaterializedReplaySession::first_executable_step_for_call` | until the call's first executable line |
//! | `DbHandler::get_call_target` | until the enclosing function name matches |
//!
//! So pressing F10 once on a freshly-opened trace built the entire step table.
//! The milestone names this precisely: "the lazy step cache saves memory only
//! until the first navigation command — which is BlockTracer's exact use case."
//!
//! `TraceReader::scan_steps_from` is the bounded replacement, and this suite
//! asserts both halves of the claim: the walk is bounded, AND it produces the
//! same answers.
//!
//! ## Why the equivalence half matters as much as the bound
//!
//! A "bounded" walk that visits the wrong steps is not an optimisation, it is a
//! navigation bug. `scan_visits_exactly_what_the_slice_walk_visited` compares
//! `scan_steps_from` against the verbatim `steps_from` walk it replaces, in both
//! directions, from many start points — so a divergence in ordering, in the
//! skip-the-start-step convention, or at either boundary fails here.
//!
//! ## No skip path
//!
//! The container is written at test time by the production Nim writer. Nothing
//! can be absent, and no case can pass without the engine actually navigating.

#![cfg(feature = "nim-reader")]
#![allow(clippy::expect_used, clippy::unwrap_used, clippy::panic)]

use std::path::{Path, PathBuf};
use std::sync::Arc;

use codetracer_trace_types::{Line, StepId, TypeId, TypeKind, ValueRecord};

use codetracer_trace_writer_nim::{NimTraceWriter, TraceEventsFileFormat, trace_writer::TraceWriter};

use db_backend::ctfs_trace_reader::CTFSTraceReader;
use db_backend::db::MaterializedReplaySession;
use db_backend::replay::ReplaySession;
use db_backend::task::Action;
use db_backend::trace_reader::TraceReader;

const SRC: &str = "/tmp/m0_bounded_scan_prog.py";

/// `steps.dat` uses a 4096-record chunk. The fixture spans several, so a
/// chunk-bounded walk is distinguishable from a whole-stream one — a fixture
/// that fits in one chunk cannot tell them apart.
const CALLS: usize = 600;
const STEPS_PER_CALL: usize = 90;
const DISTINCT_LINES: usize = 50;

fn line_of_user_step(i: usize) -> i64 {
    10 + (i % DISTINCT_LINES) as i64
}

fn write_production_bundle(dir: &Path) -> PathBuf {
    let trace_path = dir.join("m0_bounded_scan");
    let ct_path = dir.join("m0_bounded_scan_prog.ct");

    let mut writer = NimTraceWriter::new("m0_bounded_scan_prog", &[], TraceEventsFileFormat::Ctfs);
    writer.set_workdir(dir);
    writer.begin_writing_trace_metadata(&trace_path).unwrap();
    writer.finish_writing_trace_metadata().unwrap();
    writer.begin_writing_trace_events(&trace_path).unwrap();
    writer.begin_writing_trace_paths(&trace_path).unwrap();
    writer.finish_writing_trace_paths().unwrap();

    let path = Path::new(SRC);
    let fid = writer.ensure_function_id("main", path, Line(1));
    writer.register_function("main", path, Line(1));

    // The trace is NESTED, not flat: `main` calls `worker` a hundred times.
    //
    // That matters for what this suite measures. In a flat trace every step
    // sits at depth 0, so a step-out has nothing shallower to find and
    // legitimately walks to the end of the trace — which would make a
    // "bounded walk" assertion pass or fail for reasons that have nothing to
    // do with the change under test. With a real frame to step out of, the
    // walk is bounded by the frame, which is the case a user actually
    // produces.
    let worker_id = writer.ensure_function_id("worker", path, Line(200));
    writer.register_function("worker", path, Line(200));

    writer.start(path, Line(1));
    writer.register_step(path, Line(1));
    let int_type = writer.ensure_type_id(TypeKind::Int, "int");
    TraceWriter::register_call(&mut writer, fid, vec![]);

    let mut i = 0usize;
    for call_index in 0..CALLS {
        // The call site's line VARIES per iteration. It used to be a constant,
        // and that quietly made the fixture useless for this suite: `next`
        // steps to a DIFFERENT LINE, so a hundred depth-0 steps all reporting
        // line 5 in the same frame made one F10 walk the entire trace looking
        // for a line change. That is correct product behaviour on a degenerate
        // trace, but it measures the fixture rather than the change.
        writer.register_step(path, Line(300 + (call_index % 37) as i64));
        TraceWriter::register_call(&mut writer, worker_id, vec![]);
        for _ in 0..(STEPS_PER_CALL - 1) {
            writer.register_step(path, Line(line_of_user_step(i)));
            writer.register_variable_with_full_value(
                "var",
                ValueRecord::Int {
                    i: i as i64,
                    type_id: int_type,
                },
            );
            i += 1;
        }
        writer.register_return(ValueRecord::None { type_id: TypeId(0) });
        i += 1;
    }

    writer.register_return(ValueRecord::None { type_id: TypeId(0) });
    writer.finish_writing_trace_events().unwrap();
    writer.close().unwrap();

    assert!(ct_path.exists(), "the Nim writer must produce {}", ct_path.display());
    ct_path
}

/// The recorded step total is what the writer produced; the suite reads it from
/// the reader rather than recomputing the writer's bookkeeping by hand, which
/// is the kind of duplicated arithmetic that goes stale silently.
fn recorded_step_count(reader: &CTFSTraceReader) -> usize {
    let count = reader.step_count();
    assert!(
        count > 4096,
        "the fixture must span more than one steps.dat chunk, got {count} steps"
    );
    count
}

/// Open the bundle through the BROWSER constructor — `from_bytes`, the only one
/// a tab can reach — so the reader under test is on the lazy step path.
fn browser_reader(ct_path: &Path) -> CTFSTraceReader {
    let bytes = std::fs::read(ct_path).expect("the .ct bytes must be readable");
    let reader = CTFSTraceReader::from_bytes(bytes).expect("from_bytes must open the seekable container");
    assert_eq!(
        reader.lazy_full_steps_materialized(),
        Some(false),
        "the reader must start on the lazy step path with nothing materialized, \
         or this whole suite is measuring the eager path"
    );
    reader
}

fn fixture() -> (tempfile::TempDir, PathBuf) {
    let dir = tempfile::tempdir().unwrap();
    let ct = write_production_bundle(dir.path());
    (dir, ct)
}

/// The core M0 assertion, and the milestone's
/// `test_navigation_does_not_materialize_step_table`.
///
/// Step-over — forwards and backwards, the two motions a user produces most —
/// costs the chunk it walks through, not the trace.
#[test]
fn step_over_costs_the_chunk_it_walks_not_the_trace() {
    let (_dir, ct) = fixture();
    let reader = Arc::new(browser_reader(&ct));
    let probe = reader.clone();
    let mut session = MaterializedReplaySession::new(reader);

    for _ in 0..25 {
        session.step(Action::Next, true).expect("step-over forward");
    }
    for _ in 0..10 {
        session.step(Action::Next, false).expect("step-over backward");
    }

    let total = probe.step_count();
    let total_chunks = total.div_ceil(4096);
    let populated = probe.lazy_steps_populated().expect("on the lazy path");
    let chunks = probe.lazy_steps_chunk_decompressions().expect("on the lazy path");
    println!("  35 step-overs: populated={populated}/{total}, chunks={chunks}/{total_chunks}");

    assert_eq!(
        probe.lazy_full_steps_materialized(),
        Some(false),
        "step-over must not build the whole step table"
    );
    assert!(
        chunks <= 2,
        "35 step-overs inflated {chunks} of {total_chunks} steps.dat chunks; a local walk crosses \
         at most two"
    );
    assert!(
        populated * 4 < total,
        "35 step-overs filled {populated} of {total} step slots; a local walk must leave most of \
         the stream untouched"
    );
}

/// Stepping OUT of a real frame is bounded by that frame.
///
/// This is the case a user produces; it is separated from the degenerate one
/// below because they have genuinely different costs and conflating them hides
/// both.
#[test]
fn step_out_of_a_frame_is_bounded_by_that_frame() {
    let (_dir, ct) = fixture();
    let reader = Arc::new(browser_reader(&ct));
    let probe = reader.clone();
    let mut session = MaterializedReplaySession::new(reader);

    // Park inside the first `worker` frame. The fixture's layout is asserted
    // here rather than assumed: if the writer's call bookkeeping ever changes,
    // this fails by name instead of silently measuring a frameless step.
    session.step_id_jump(StepId(10));
    let step = probe.step(StepId(10)).expect("step 10 exists");
    let depth = probe
        .call(step.call_key)
        .map(|c| c.depth)
        .expect("step 10 must be inside a recorded call");
    assert_eq!(
        depth, 1,
        "step 10 must sit inside a `worker` frame for this case to mean anything"
    );

    session.step(Action::StepOut, true).expect("step-out forward");

    let total = probe.step_count();
    let chunks = probe.lazy_steps_chunk_decompressions().expect("on the lazy path");
    let populated = probe.lazy_steps_populated().expect("on the lazy path");
    println!("  step-out of a frame: populated={populated}/{total}, chunks={chunks}");

    assert_eq!(
        probe.lazy_full_steps_materialized(),
        Some(false),
        "step-out must not build the whole step table"
    );
    assert!(
        chunks <= 2,
        "stepping out of a ~90-step frame inflated {chunks} chunks; it crosses at most two"
    );
}

/// Stepping OUT of the OUTERMOST frame has nowhere shallower to go, so it
/// walks to the trace boundary. That is pre-existing, correct behaviour and it
/// is asserted rather than hidden — but it must still not build the whole
/// table, because the whole-table build costs a `Vec<DbStep>` AND a per-path
/// line→steps map on top of the walk.
#[test]
fn step_out_of_the_outermost_frame_walks_to_the_boundary_without_building_the_table() {
    let (_dir, ct) = fixture();
    let reader = Arc::new(browser_reader(&ct));
    let probe = reader.clone();
    let mut session = MaterializedReplaySession::new(reader);

    // Step 2 is `main`'s own first step: depth 0, nothing to step out to.
    session.step_id_jump(StepId(2));
    let step = probe.step(StepId(2)).expect("step 2 exists");
    assert_eq!(
        probe.call(step.call_key).map(|c| c.depth),
        Some(0),
        "step 2 must be at the outermost depth for this case to mean anything"
    );

    session.step(Action::StepOut, true).expect("step-out forward");

    assert_eq!(
        probe.lazy_full_steps_materialized(),
        Some(false),
        "even a walk to the boundary must not build the whole step table — that build is the \
         expensive thing M0 removes, and it is strictly more than the walk"
    );
}

/// A `continue` that hits a breakpoint early costs what it walked.
///
/// Note the contrast with a `continue` that has NOTHING to stop at: that one
/// legitimately runs to the trace boundary, and it inspects every step on the
/// way because `breakpoint_list` is a per-path `Vec` that is non-empty as soon
/// as the trace has paths (its per-path maps are what is empty). That is
/// pre-existing behaviour this change deliberately preserves — `scan_steps_from`
/// visits exactly the steps the slice walk visited — so the case worth asserting
/// is the one with a reachable stop.
#[test]
fn continue_to_an_early_breakpoint_costs_what_it_walked() {
    let (_dir, ct) = fixture();
    let reader = Arc::new(browser_reader(&ct));
    let probe = reader.clone();
    assert!(
        probe.path_id_for(SRC).is_some(),
        "the source path must be interned, or the breakpoint below cannot resolve"
    );
    let mut session = MaterializedReplaySession::new(reader);

    // A line the `worker` frames hit constantly, so the very first frame
    // contains a stop.
    let target_line = line_of_user_step(3);
    session
        .add_breakpoint(SRC, target_line, None, None)
        .expect("the breakpoint must resolve against the fixture's source path");
    session.step_id_jump(StepId(2));

    let hit = session.step(Action::Continue, true).expect("continue forward");
    assert!(hit, "the breakpoint must be reachable, or this case measures nothing");

    let total = probe.step_count();
    let chunks = probe.lazy_steps_chunk_decompressions().expect("on the lazy path");
    let populated = probe.lazy_steps_populated().expect("on the lazy path");
    println!("  continue to an early breakpoint: populated={populated}/{total}, chunks={chunks}");

    assert_eq!(
        probe.lazy_full_steps_materialized(),
        Some(false),
        "continue must not build the whole step table"
    );
    assert!(
        chunks <= 2,
        "a continue that stops in the first frame inflated {chunks} chunks; it crosses at most two"
    );
    assert!(
        populated * 4 < total,
        "a continue that stops in the first frame filled {populated} of {total} step slots"
    );
}

/// `run_to_entry` reaches `first_executable_step_for_call`, which used to
/// `.find()` over `steps_from(call.step_id)`.
#[test]
fn run_to_entry_does_not_materialize_the_step_table() {
    let (_dir, ct) = fixture();
    let reader = Arc::new(browser_reader(&ct));
    let probe = reader.clone();
    let mut session = MaterializedReplaySession::new(reader);

    session.run_to_entry().expect("run to entry");
    assert_eq!(
        probe.lazy_full_steps_materialized(),
        Some(false),
        "run-to-entry must not build the whole step table"
    );
}

/// EQUIVALENCE. `scan_steps_from` visits exactly the steps the `steps_from`
/// walk it replaces visited, in the same order, in both directions.
///
/// The reference side deliberately uses `steps_from` — the materializing
/// accessor — so this is a comparison against the verbatim old behaviour rather
/// than against a restatement of the new one. It runs LAST relative to the
/// bounded assertions above (separate reader instance), because reading the
/// reference materializes the table.
#[test]
fn scan_visits_exactly_what_the_slice_walk_visited() {
    let (_dir, ct) = fixture();
    let reader = browser_reader(&ct);
    let count = recorded_step_count(&reader);

    // Start points spanning chunk boundaries, both ends, and the interior.
    let starts = [0usize, 1, 7, 4095, 4096, 4097, 5000, count / 2, count - 2, count - 1];

    for &start in &starts {
        for forward in [true, false] {
            // The reference walk, verbatim from the pre-M0/3 code.
            let reference: Vec<i64> = if forward {
                reader
                    .steps_from(StepId(start as i64))
                    .iter()
                    .skip(1)
                    .map(|s| s.step_id.0)
                    .collect()
            } else {
                let all = reader.steps_from(StepId(0));
                let end = std::cmp::min(start, all.len());
                all[..end].iter().rev().map(|s| s.step_id.0).collect()
            };

            let mut scanned: Vec<i64> = Vec::new();
            reader.scan_steps_from(StepId(start as i64), forward, &mut |step| {
                scanned.push(step.step_id.0);
                true
            });

            assert_eq!(
                scanned.len(),
                reference.len(),
                "start {start} forward={forward}: scan visited {} steps, the slice walk visited {}",
                scanned.len(),
                reference.len()
            );
            assert_eq!(
                scanned, reference,
                "start {start} forward={forward}: scan visited a different sequence than the slice walk"
            );
        }
    }
}

/// A scan that stops immediately visits exactly one step, and a scan from a
/// negative or out-of-range start visits none — the boundary cases the slice
/// walk handled by returning an empty slice.
#[test]
fn scan_boundaries_match_the_slice_walk() {
    let (_dir, ct) = fixture();
    let reader = browser_reader(&ct);
    let count = reader.step_count();

    let mut visited = 0usize;
    reader.scan_steps_from(StepId(10), true, &mut |_| {
        visited += 1;
        false
    });
    assert_eq!(visited, 1, "a scan that stops on the first step visits exactly one");

    visited = 0;
    reader.scan_steps_from(StepId(0), false, &mut |_| {
        visited += 1;
        true
    });
    assert_eq!(visited, 0, "there is nothing before step 0");

    visited = 0;
    reader.scan_steps_from(StepId(count as i64 - 1), true, &mut |_| {
        visited += 1;
        true
    });
    assert_eq!(visited, 0, "there is nothing after the last step");

    visited = 0;
    reader.scan_steps_from(StepId(-1), true, &mut |_| {
        visited += 1;
        true
    });
    assert_eq!(visited, 0, "a negative start visits nothing rather than panicking");

    visited = 0;
    reader.scan_steps_from(StepId(count as i64 + 500), true, &mut |_| {
        visited += 1;
        true
    });
    assert_eq!(visited, 0, "a start past the end visits nothing rather than panicking");

    assert_eq!(
        reader.lazy_full_steps_materialized(),
        Some(false),
        "none of the boundary scans should have built the whole table"
    );
}

/// A LOCAL walk touches only the chunks it crosses. This is the property the
/// whole change exists for, stated as a number rather than as an absence.
#[test]
fn a_short_walk_inflates_only_the_chunks_it_crosses() {
    let (_dir, ct) = fixture();
    let reader = browser_reader(&ct);
    assert_eq!(
        reader.lazy_steps_chunk_decompressions(),
        Some(0),
        "nothing may be inflated before the walk"
    );

    let mut visited = 0usize;
    reader.scan_steps_from(StepId(0), true, &mut |_| {
        visited += 1;
        visited < 100
    });
    assert_eq!(visited, 100);

    let chunks = reader.lazy_steps_chunk_decompressions().expect("on the lazy path");
    assert!(
        chunks <= 2,
        "a 100-step walk inflated {chunks} steps.dat chunks; it crosses at most two"
    );
    assert_eq!(
        reader.lazy_full_steps_materialized(),
        Some(false),
        "a 100-step walk must not build the whole table"
    );
}
