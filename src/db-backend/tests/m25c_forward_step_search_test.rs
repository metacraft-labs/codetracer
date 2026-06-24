//! M25c — VERIFY the NETWORK forward-from-search lazy-population primitive.
//!
//! Owner guidance (M25c): "When the file is being loaded from the internet, it
//! makes sense to process the events only from the STARTING POINT of the search
//! going forward (when looking for the next breakpoint or tracepoint hit)."
//!
//! Where M25b's LOCAL strategy splits `[0, count)` into disjoint ranges and
//! builds the WHOLE table (random access is cheap locally), the NETWORK strategy
//! must NOT touch the whole file: a "find the next hit of line L from position P"
//! query fetches/decompresses ONLY the `steps.dat` chunks from `P` forward up to
//! the FIRST matching step, and stops there.
//!
//! `replay_forward_until` / `find_next_line_hit` are that forward primitive,
//! built on the SAME M25a engine (`reconstruct_db_step`) so the RESULT is
//! identical to the whole-table `steps_on_line` lookup — the strategy only
//! changes WHICH chunks get fetched, never the answer.
//!
//! HONEST SCOPE: no live network `.ct` LOADER exists in the db-backend yet (only
//! an HTTP omniscient-PREP trigger), so this is validated in ISOLATION over a
//! local seekable stream — the chunk-fetch pattern is identical regardless of
//! where the bytes come from — and wired behind the existing
//! `StepBuildStrategy::NetworkForward` seam, ready for when network loading lands.
//!
//! These tests assert, against a REAL Nim production split-only bundle:
//!
//!  1. FORWARD HIT + BOUNDED FETCH: a forward scan from a mid-trace start finds
//!     the next matching step, decompresses ONLY the chunks from start→hit
//!     (strictly fewer than the whole trace when the hit is early), and stops at
//!     the hit (does NOT scan to end).
//!  2. PARITY: `find_next_line_hit(path,line,from)` under `NetworkForward`
//!     returns the SAME step the `Local` whole-table `steps_on_line` lookup
//!     resolves — for several (line, from) cases, including no-further-hit (None).
//!  3. BOUNDED-FETCH PROOF: searching for an early hit fetches far fewer chunks
//!     than the whole-table build inflates.
//!
//! Requires the `nim-reader` feature (the production split-stream reader), in the
//! crate's default feature set.

#![cfg(feature = "nim-reader")]
#![allow(clippy::expect_used, clippy::unwrap_used, clippy::panic)]

use std::collections::HashMap;
use std::path::{Path, PathBuf};

use codetracer_trace_types::{CallKey, Line, PathId, StepId, TypeId, TypeKind, ValueRecord};

use codetracer_trace_writer_nim::{NimTraceWriter, TraceEventsFileFormat, trace_writer::TraceWriter};

use db_backend::ctfs_trace_reader::step_value_stream_source::{
    DiscardStepSink, SeekableStepStream, StepBuildStrategy, WholeStepTableSink, build_whole_step_table,
    find_next_line_hit, replay_forward_until,
};
use db_backend::db::DbStep;

/// The single source file every step in the fixture recording lives in.
const SRC: &str = "/tmp/m25c_forward_prog.py";

/// Number of user steps recorded — well over the 4096 `steps.dat` chunk size so
/// the trace spans MANY chunks and a forward scan from a mid-trace start can
/// genuinely touch FEWER chunks than the whole table.
const USER_STEPS: usize = 12000;

/// The recorded line of user step `i` — a deterministic spread across 40 lines so
/// the line→step map is non-trivial AND many steps share a line (so "next hit"
/// is a meaningful query, not a singleton).
fn line_of_user_step(i: usize) -> i64 {
    10 + (i % 40) as i64
}

/// Produce a GENUINELY `events.log`-free split-only `.ct` bundle via the Nim
/// multi-stream writer — the production write path that routes the reader onto
/// the lazy step path + the unified engine.
fn write_production_bundle(dir: &Path) -> PathBuf {
    let trace_path = dir.join("m25c_forward");
    let ct_path = dir.join("m25c_forward_prog.ct");

    let mut writer = NimTraceWriter::new("m25c_forward_prog", &[], TraceEventsFileFormat::Ctfs);
    writer.set_workdir(dir);
    writer.begin_writing_trace_metadata(&trace_path).unwrap();
    writer.finish_writing_trace_metadata().unwrap();
    writer.begin_writing_trace_events(&trace_path).unwrap();
    writer.begin_writing_trace_paths(&trace_path).unwrap();
    writer.finish_writing_trace_paths().unwrap();

    let path = Path::new(SRC);
    let fid = writer.ensure_function_id("main", path, Line(1));
    writer.register_function("main", path, Line(1));

    writer.start(path, Line(1));
    writer.register_step(path, Line(1));
    let int_type = writer.ensure_type_id(TypeKind::Int, "int");
    TraceWriter::register_call(&mut writer, fid, vec![]);

    for i in 0..USER_STEPS {
        writer.register_step(path, Line(line_of_user_step(i)));
        let value = ValueRecord::Int {
            i: i as i64,
            type_id: int_type,
        };
        writer.register_variable_with_full_value("var", value);
    }

    writer.register_return(ValueRecord::None { type_id: TypeId(0) });
    writer.finish_writing_trace_events().unwrap();
    writer.close().unwrap();

    assert!(ct_path.exists(), ".ct should be produced at {}", ct_path.display());
    ct_path
}

/// The recorded step total: a leading step at the function line + `USER_STEPS`
/// user steps. (`start`+`register_step` emit one initial step before the loop.)
fn expected_step_count() -> usize {
    USER_STEPS + 2
}

/// Open a seekable `steps.dat` source for the bundle, with neutral call keys of
/// the right length (the `(path_id, line)` reconstruction the line search uses
/// does not depend on the call-key arrays).
fn open_stream(ct: &Path) -> (SeekableStepStream, Vec<CallKey>) {
    let stream = SeekableStepStream::open(ct)
        .expect("open steps.dat")
        .expect("production bundle has a seekable steps.dat");
    let count = stream.step_count();
    assert_eq!(count, expected_step_count(), "seekable stream exposes every step");
    let call_keys = vec![CallKey(-1); count];
    (stream, call_keys)
}

/// The interned path id of SRC, derived from the whole-table map (path 0 in this
/// single-file bundle). We confirm it by checking the reconstructed steps land on
/// it.
const SRC_PATH_ID: PathId = PathId(0);

/// Build the whole-table line→step map (the M25b LOCAL reference) so parity can
/// be checked against the authoritative `steps_on_line`-equivalent lookup.
fn whole_table(ct: &Path) -> (Vec<DbStep>, Vec<HashMap<usize, Vec<DbStep>>>) {
    let (stream, call_keys) = open_stream(ct);
    build_whole_step_table(
        &stream,
        &call_keys,
        &call_keys,
        4,
        StepBuildStrategy::Local { threads: 1 },
    )
}

/// The LOCAL whole-table answer to "next step at-or-after `from` on `(path,
/// line)`": scan the per-line step list (ascending step order) for the first id
/// >= `from`. This is exactly what a `steps_on_line` breakpoint resolver does.
fn local_next_line_hit(
    map: &[HashMap<usize, Vec<DbStep>>],
    path_id: PathId,
    line: usize,
    from: usize,
) -> Option<StepId> {
    map.get(path_id.0)
        .and_then(|by_line| by_line.get(&line))
        .and_then(|steps| steps.iter().find(|s| s.step_id.0 as usize >= from))
        .map(|s| s.step_id)
}

/// DELIVERABLE 1 — FORWARD HIT + BOUNDED FETCH: a forward scan from a mid-trace
/// start finds the next matching step, decompresses ONLY the chunks from
/// start→hit (strictly fewer than the whole trace when the hit is early), and
/// stops at the hit (does not scan to end).
#[test]
fn forward_scan_finds_next_hit_with_bounded_fetch() {
    let dir = tempfile::tempdir().unwrap();
    let ct = write_production_bundle(dir.path());
    let (stream, call_keys) = open_stream(&ct);
    let chunk = stream.chunk_size();
    let count = stream.step_count();

    // Start mid-trace, search for the NEXT step on a line that recurs every 40
    // steps — so the hit is within ~40 steps (well under one chunk) of the start.
    let from = count / 2;
    // Pick a target line that appears AFTER `from` soon. The first user step is at
    // reader index 1 (after the leading function-line step at index 0); user step
    // `i` lands at reader index `i + 1`. Find the recorded line of the first user
    // step at-or-after `from`.
    let first_user_after = from.saturating_sub(1); // user index ~ reader index - 1
    let target_line = line_of_user_step(first_user_after) as usize;

    let mut sink = WholeStepTableSink::new(4, count);
    let hit = replay_forward_until(
        &stream,
        &call_keys,
        &call_keys,
        from,
        |step| step.path_id == SRC_PATH_ID && step.line.0 as usize == target_line,
        &mut sink,
    );

    let hit = hit.expect("a forward scan from mid-trace must find the recurring line");
    assert!(hit.0 as usize >= from, "the hit must be at-or-after the start point");

    // The hit must be EARLY (within a couple of chunks of `from`), proving the
    // scan stopped at the hit rather than running to the end.
    assert!(
        (hit.0 as usize) < from + chunk,
        "a recurring line must be hit within one chunk of the start (hit={}, from={}, chunk={})",
        hit.0,
        from,
        chunk
    );

    // BOUNDED FETCH: the forward scan inflated only the chunks spanning
    // [from, hit] — STRICTLY FEWER than the whole trace's chunk count.
    let scanned_chunks = stream.chunk_decompressions();
    let total_chunks = count.div_ceil(chunk) as u64;
    let chunks_for_span = (hit.0 as usize / chunk - from / chunk + 1) as u64;
    assert!(
        scanned_chunks <= chunks_for_span,
        "forward scan inflated at most the chunks spanning [from, hit] (got {scanned_chunks}, span {chunks_for_span})"
    );
    assert!(
        scanned_chunks < total_chunks,
        "an early hit must inflate STRICTLY FEWER chunks than the whole trace \
         (scanned={scanned_chunks}, total={total_chunks})"
    );

    // The sink was populated INCREMENTALLY only up to the hit, never the whole
    // table: it holds exactly `hit - from + 1` steps.
    let (steps, _map) = sink.into_parts();
    assert_eq!(
        steps.len(),
        hit.0 as usize - from + 1,
        "the sink is populated forward from the start up to and including the hit, not the whole table"
    );
}

/// A forward scan with a predicate that never matches reaches end-of-trace and
/// returns None (no hit), having scanned to the end (no early stop possible).
#[test]
fn forward_scan_no_match_returns_none() {
    let dir = tempfile::tempdir().unwrap();
    let ct = write_production_bundle(dir.path());
    let (stream, call_keys) = open_stream(&ct);

    // A line that no step lands on → no hit anywhere after `from`.
    let mut sink = DiscardStepSink;
    let hit = replay_forward_until(
        &stream,
        &call_keys,
        &call_keys,
        0,
        |step| step.line.0 == 999_999,
        &mut sink,
    );
    assert_eq!(hit, None, "a predicate that never matches must yield None");
}

/// A `from_step` at or past the end yields None immediately, fetching no chunk.
#[test]
fn forward_scan_past_end_fetches_nothing() {
    let dir = tempfile::tempdir().unwrap();
    let ct = write_production_bundle(dir.path());
    let (stream, call_keys) = open_stream(&ct);
    let count = stream.step_count();

    let mut sink = DiscardStepSink;
    let hit = replay_forward_until(&stream, &call_keys, &call_keys, count, |_| true, &mut sink);
    assert_eq!(hit, None, "a start at the end yields None");
    assert_eq!(
        stream.chunk_decompressions(),
        0,
        "a start past the end fetches no chunk at all"
    );
}

/// DELIVERABLE 2 — PARITY: `find_next_line_hit(path,line,from)` under
/// `NetworkForward` returns the SAME step the `Local` whole-table `steps_on_line`
/// lookup resolves, for several (line, from) cases including no-further-hit.
#[test]
fn network_forward_next_hit_matches_local_steps_on_line() {
    let dir = tempfile::tempdir().unwrap();
    let ct = write_production_bundle(dir.path());

    // The LOCAL whole-table reference (the authoritative `steps_on_line` answer).
    let (_steps, map) = whole_table(&ct);

    let count = expected_step_count();

    // Exercise several (line, from) cases spread across the trace, plus a
    // no-further-hit case.
    let cases: &[(usize, usize)] = &[
        (10, 0),          // earliest line, from the very start
        (25, 0),          // mid line, from the start
        (49, count / 4),  // last spread line, quarter in
        (30, count / 2),  // mid-trace start
        (15, count - 50), // near the end — may or may not have a further hit
        (42, count - 1),  // last index start
    ];

    for &(line, from) in cases {
        // Re-open a FRESH stream per case so each search starts with a clean
        // chunk-decompression counter (parity is about the RESULT; the fetch
        // pattern is proven in deliverables 1/3).
        let (stream, call_keys) = open_stream(&ct);

        let network = find_next_line_hit(
            &stream,
            &call_keys,
            &call_keys,
            SRC_PATH_ID,
            Line(line as i64),
            from,
            StepBuildStrategy::NetworkForward,
        );
        let local = local_next_line_hit(&map, SRC_PATH_ID, line, from);

        assert_eq!(
            network, local,
            "NetworkForward find_next_line_hit(line={line}, from={from}) must equal the Local steps_on_line next hit"
        );
    }

    // EXPLICIT no-further-hit case: search for a line PAST every occurrence — from
    // beyond the last step on that line. Find the last step on line 10, then start
    // one past it.
    let line10 = map[SRC_PATH_ID.0].get(&10).expect("line 10 has steps");
    let last_on_10 = line10.last().unwrap().step_id.0 as usize;
    let (stream, call_keys) = open_stream(&ct);
    let network = find_next_line_hit(
        &stream,
        &call_keys,
        &call_keys,
        SRC_PATH_ID,
        Line(10),
        last_on_10 + 1,
        StepBuildStrategy::NetworkForward,
    );
    let local = local_next_line_hit(&map, SRC_PATH_ID, 10, last_on_10 + 1);
    assert_eq!(network, None, "no further hit on line 10 past its last occurrence");
    assert_eq!(
        network, local,
        "NetworkForward and Local agree on the no-further-hit (None) case"
    );
}

/// Parity must also hold under the `Local` strategy (the forward primitive is the
/// search-scoped path both strategies can use; the RESULT is strategy-independent).
#[test]
fn local_strategy_next_hit_matches_whole_table() {
    let dir = tempfile::tempdir().unwrap();
    let ct = write_production_bundle(dir.path());
    let (_steps, map) = whole_table(&ct);

    for &(line, from) in &[(10usize, 0usize), (33, expected_step_count() / 3)] {
        let (stream, call_keys) = open_stream(&ct);
        let local_fwd = find_next_line_hit(
            &stream,
            &call_keys,
            &call_keys,
            SRC_PATH_ID,
            Line(line as i64),
            from,
            StepBuildStrategy::Local { threads: 4 },
        );
        assert_eq!(
            local_fwd,
            local_next_line_hit(&map, SRC_PATH_ID, line, from),
            "Local-strategy forward search must also equal the whole-table next hit"
        );
    }
}

/// DELIVERABLE 3 — BOUNDED-FETCH PROOF: searching for an EARLY hit fetches far
/// fewer chunks than the whole-table build inflates over the same stream.
#[test]
fn early_hit_search_fetches_far_fewer_chunks_than_whole_table() {
    let dir = tempfile::tempdir().unwrap();
    let ct = write_production_bundle(dir.path());

    // Whole-table build over a FRESH stream: inflates EVERY chunk.
    let (whole_stream, whole_keys) = open_stream(&ct);
    let count = whole_stream.step_count();
    let chunk = whole_stream.chunk_size();
    let _ = build_whole_step_table(
        &whole_stream,
        &whole_keys,
        &whole_keys,
        4,
        StepBuildStrategy::Local { threads: 1 },
    );
    let whole_chunks = whole_stream.chunk_decompressions();
    let total_chunks = count.div_ceil(chunk) as u64;
    assert_eq!(
        whole_chunks, total_chunks,
        "the sequential whole-table build inflates every chunk ({total_chunks})"
    );

    // Forward search for an EARLY hit (line 10 is hit within the first 40 steps)
    // over a FRESH stream: inflates only the FIRST chunk.
    let (search_stream, search_keys) = open_stream(&ct);
    let hit = find_next_line_hit(
        &search_stream,
        &search_keys,
        &search_keys,
        SRC_PATH_ID,
        Line(10),
        0,
        StepBuildStrategy::NetworkForward,
    );
    assert!(hit.is_some(), "line 10 is hit early");
    let search_chunks = search_stream.chunk_decompressions();

    assert!(
        search_chunks < whole_chunks,
        "an early-hit forward search must fetch STRICTLY FEWER chunks than the whole-table build \
         (search={search_chunks}, whole={whole_chunks})"
    );
    // Concretely: the early hit is in the first chunk, so the search inflates just
    // ONE chunk vs the whole trace's many.
    assert_eq!(search_chunks, 1, "an early hit inflates exactly one chunk");
    assert!(
        whole_chunks >= 3,
        "the multi-chunk trace's whole-table build inflates several chunks (got {whole_chunks})"
    );
}
