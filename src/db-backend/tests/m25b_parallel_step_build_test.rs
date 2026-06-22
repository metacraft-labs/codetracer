//! M25b — VERIFY the LOCAL parallel disjoint-range whole-table step build.
//!
//! For a LOCAL (filesystem) trace the on-first-demand whole-table build splits
//! `[0, count)` into DISJOINT contiguous ranges, replays each on its own thread
//! over an INDEPENDENT per-thread reader (its own one-chunk decompression cache),
//! and MERGES the per-thread partials in range order. This milestone parallelizes
//! ONLY the whole-table build (which is already on-demand) — opening the trace and
//! per-step point lookups stay single-chunk lazy (M24c).
//!
//! The build still drives the SAME M25a per-step processing engine
//! (`replay_steps_into_sinks` / `WholeStepTableSink`); the access strategy only
//! chooses WHICH ranges run on WHICH threads. So the parallel result must be
//! BYTE-IDENTICAL to the sequential single-stream build — including each line's
//! per-step ORDER, which `steps_on_line` exposes — and DETERMINISTIC across runs.
//!
//! These tests assert, against a REAL Nim production split-only bundle (the exact
//! write path every live recorder drives):
//!
//!  1. PARITY: the parallel build (`Local { threads: N>1 }`) produces a `DbStep`
//!     array and per-path line→step map BYTE-IDENTICAL to the sequential build
//!     (`Local { threads: 1 }`), including per-line step ORDER. Deterministic
//!     across repeated runs and across thread counts.
//!  2. THREADS GENUINELY USED: a multi-chunk trace splits into ≥2 disjoint ranges
//!     and the parallel build completes correctly with N>1.
//!  3. POINT LOOKUPS STILL LAZY: opening materializes no whole table and a point
//!     `step()` lookup inflates at most one `steps.dat` chunk (M24c preserved) —
//!     the parallel path is taken ONLY on the whole-table build.
//!
//! Requires the `nim-reader` feature (the production split-stream reader), in the
//! crate's default feature set.

#![cfg(feature = "nim-reader")]
#![allow(clippy::expect_used, clippy::unwrap_used, clippy::panic)]

use std::path::{Path, PathBuf};

use codetracer_trace_types::{CallKey, Line, StepId, TypeId, TypeKind, ValueRecord};

use codetracer_trace_writer_nim::{trace_writer::TraceWriter, NimTraceWriter, TraceEventsFileFormat};

use db_backend::ctfs_trace_reader::step_value_stream_source::{
    build_whole_step_table, SeekableStepStream, StepBuildStrategy,
};
use db_backend::ctfs_trace_reader::CTFSTraceReader;
use db_backend::db::DbStep;
use db_backend::trace_reader::TraceReader;

/// The single source file every step in the fixture recording lives in.
const SRC: &str = "/tmp/m25b_parallel_prog.py";

/// Number of user steps recorded — well over the 4096 `steps.dat` chunk size so
/// the trace spans MANY chunks and a multi-thread split genuinely covers several
/// chunks per range.
const USER_STEPS: usize = 12000;

/// The recorded line of user step `i` — a deterministic spread across 40 lines so
/// the line→step map is non-trivial AND many steps share a line (so per-line
/// ORDER is a meaningful parity check, not a singleton).
fn line_of_user_step(i: usize) -> i64 {
    10 + (i % 40) as i64
}

/// Produce a GENUINELY `events.log`-free split-only `.ct` bundle via the Nim
/// multi-stream writer — the production write path that routes the reader onto
/// the lazy step path + the unified engine.
fn write_production_bundle(dir: &Path) -> PathBuf {
    let trace_path = dir.join("m25b_parallel");
    let ct_path = dir.join("m25b_parallel_prog.ct");

    let mut writer = NimTraceWriter::new("m25b_parallel_prog", &[], TraceEventsFileFormat::Ctfs);
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

/// Two `DbStep`s are equal iff EVERY field matches (DbStep does not derive
/// PartialEq; the M25b parity contract is byte-for-byte field equality).
fn db_step_eq(a: &DbStep, b: &DbStep) -> bool {
    a.step_id == b.step_id
        && a.path_id == b.path_id
        && a.line == b.line
        && a.column == b.column
        && a.call_key == b.call_key
        && a.global_call_key == b.global_call_key
}

/// Assert two whole-table builds are BYTE-IDENTICAL: the `DbStep` array
/// (order + every field) and the per-path line→`[DbStep]` map (every path, every
/// line, every step in the SAME ORDER).
fn assert_whole_tables_identical(
    a: &(Vec<DbStep>, Vec<std::collections::HashMap<usize, Vec<DbStep>>>),
    b: &(Vec<DbStep>, Vec<std::collections::HashMap<usize, Vec<DbStep>>>),
) {
    let (a_steps, a_map) = a;
    let (b_steps, b_map) = b;

    assert_eq!(a_steps.len(), b_steps.len(), "DbStep array length must match");
    for (i, (sa, sb)) in a_steps.iter().zip(b_steps.iter()).enumerate() {
        assert!(
            db_step_eq(sa, sb),
            "DbStep[{i}] differs: {sa:?} vs {sb:?}"
        );
        // The array MUST be index-aligned: steps[i] is step i.
        assert_eq!(sa.step_id.0, i as i64, "steps[{i}].step_id must equal {i}");
    }

    assert_eq!(a_map.len(), b_map.len(), "step_map path count must match");
    for (path_id, (by_line_a, by_line_b)) in a_map.iter().zip(b_map.iter()).enumerate() {
        assert_eq!(
            by_line_a.len(),
            by_line_b.len(),
            "path {path_id}: number of distinct lines must match"
        );
        for (line, steps_a) in by_line_a {
            let steps_b = by_line_b
                .get(line)
                .unwrap_or_else(|| panic!("path {path_id} line {line} missing in second build"));
            assert_eq!(
                steps_a.len(),
                steps_b.len(),
                "path {path_id} line {line}: per-line step count must match"
            );
            // ORDER-SENSITIVE: per-line step lists must be identical element by
            // element, proving the parallel merge preserves ascending step order.
            for (k, (sa, sb)) in steps_a.iter().zip(steps_b.iter()).enumerate() {
                assert!(
                    db_step_eq(sa, sb),
                    "path {path_id} line {line} step[{k}] differs: {sa:?} vs {sb:?}"
                );
            }
        }
    }
}

/// Open a seekable `steps.dat` source for the bundle and build the whole-table
/// view under `strategy`, using NEUTRAL call keys of the right length (the
/// `(path_id, line)` reconstruction — and thus the line→step map and the step
/// array's path/line — does not depend on the call-key arrays; identical neutral
/// keys in both builds keep the comparison about the parallel-vs-sequential
/// MERGE, the thing M25b changes).
fn build_with_strategy(
    ct: &Path,
    strategy: StepBuildStrategy,
) -> (Vec<DbStep>, Vec<std::collections::HashMap<usize, Vec<DbStep>>>) {
    let stream = SeekableStepStream::open(ct)
        .expect("open steps.dat")
        .expect("production bundle has a seekable steps.dat");
    let count = stream.step_count();
    assert_eq!(count, expected_step_count(), "seekable stream exposes every step");
    let call_keys = vec![CallKey(-1); count];
    // One path interned (SRC) plus the writer's implicit slot(s); size the map to
    // a generous path count so neither build has to grow it.
    let path_count = 4;
    build_whole_step_table(&stream, &call_keys, &call_keys, path_count, strategy)
}

/// DELIVERABLE 1+4 — PARITY: the parallel build equals the sequential build,
/// byte-for-byte, including per-line step ORDER, and is DETERMINISTIC across
/// repeated runs and across thread counts.
#[test]
fn parallel_build_is_byte_identical_to_sequential() {
    let dir = tempfile::tempdir().unwrap();
    let ct = write_production_bundle(dir.path());

    // The sequential reference: a single stream, no parallelism.
    let sequential = build_with_strategy(&ct, StepBuildStrategy::Local { threads: 1 });

    // The parallel build at several thread counts (≥2). Each must match the
    // sequential reference exactly. A multi-chunk trace (12002 steps, chunk 4096 →
    // 3+ chunks) genuinely splits into ≥2 disjoint ranges spanning several chunks.
    for threads in [2usize, 3, 4, 8] {
        let parallel = build_with_strategy(&ct, StepBuildStrategy::Local { threads });
        assert_whole_tables_identical(&parallel, &sequential);
    }

    // DETERMINISM: re-running the parallel build yields an identical result.
    let again = build_with_strategy(&ct, StepBuildStrategy::Local { threads: 4 });
    assert_whole_tables_identical(&again, &sequential);
}

/// DELIVERABLE 2 — THREADS GENUINELY USED: with N>1 on a multi-chunk trace the
/// build splits into ≥2 disjoint ranges. We can't observe the shard count
/// directly (it's internal), but a trace whose step count exceeds the chunk size
/// guarantees a multi-range split, and the parallel build completing with a
/// result IDENTICAL to a fresh sequential reference proves the disjoint ranges
/// were each replayed and merged correctly (a single-thread path could not
/// exercise the merge).
#[test]
fn parallel_build_covers_multiple_chunks_correctly() {
    let dir = tempfile::tempdir().unwrap();
    let ct = write_production_bundle(dir.path());

    let stream = SeekableStepStream::open(&ct).unwrap().unwrap();
    let count = stream.step_count();
    let chunk = stream.chunk_size();
    assert!(
        count > 2 * chunk,
        "trace must span several chunks for a meaningful multi-range split \
         (steps={count}, chunk={chunk})"
    );

    let sequential = build_with_strategy(&ct, StepBuildStrategy::Local { threads: 1 });
    let parallel = build_with_strategy(&ct, StepBuildStrategy::Local { threads: 4 });
    assert_whole_tables_identical(&parallel, &sequential);

    // The default strategy (machine parallelism, bounded) must also match.
    let default_built = build_with_strategy(&ct, StepBuildStrategy::default());
    assert_whole_tables_identical(&default_built, &sequential);
}

/// NetworkForward is an M25c placeholder: it must use the sequential path today
/// and still produce the identical whole table.
#[test]
fn network_forward_placeholder_matches_sequential() {
    let dir = tempfile::tempdir().unwrap();
    let ct = write_production_bundle(dir.path());

    let sequential = build_with_strategy(&ct, StepBuildStrategy::Local { threads: 1 });
    let network = build_with_strategy(&ct, StepBuildStrategy::NetworkForward);
    assert_whole_tables_identical(&network, &sequential);
}

/// DELIVERABLE 3 — POINT LOOKUPS STILL LAZY: opening materializes no whole table,
/// and a point `step()` lookup inflates at most one `steps.dat` chunk. The
/// parallel build is taken ONLY on the whole-table build (first slice / line-map
/// demand), so pure point-lookup navigation never triggers it.
#[test]
fn point_lookups_stay_lazy_under_m25b() {
    let dir = tempfile::tempdir().unwrap();
    let ct = write_production_bundle(dir.path());
    let reader = CTFSTraceReader::open(&ct).expect("open production");

    // Right after open: NOTHING materialized — neither the per-slot cache nor the
    // whole-table view.
    assert_eq!(
        reader.lazy_steps_populated(),
        Some(0),
        "open must not materialize the step table"
    );
    assert_eq!(
        reader.lazy_full_steps_materialized(),
        Some(false),
        "open must not trigger the whole-table (parallel) build"
    );
    assert_eq!(
        reader.lazy_steps_chunk_decompressions(),
        Some(0),
        "open inflates no steps.dat chunk"
    );

    // A single point lookup fills only ONE chunk's worth of slots and inflates at
    // most one chunk — and STILL does not trigger the whole-table parallel build.
    let mid = expected_step_count() / 2;
    let step = reader.step(StepId(mid as i64)).expect("point lookup");
    assert_eq!(step.step_id.0, mid as i64);

    let populated = reader.lazy_steps_populated().expect("lazy path");
    let chunk = SeekableStepStream::open(&ct).unwrap().unwrap().chunk_size();
    assert!(
        populated <= chunk,
        "a point lookup must fill at most one chunk's slots (populated={populated}, chunk={chunk})"
    );
    assert!(
        reader.lazy_steps_chunk_decompressions().expect("lazy path") <= 1,
        "a point lookup inflates at most one steps.dat chunk"
    );
    assert_eq!(
        reader.lazy_full_steps_materialized(),
        Some(false),
        "a point lookup must NOT trigger the whole-table parallel build"
    );

    // Now demand the whole table (a line-map accessor). This DOES run the parallel
    // build. Afterwards the whole table is materialized and `steps_on_line` order
    // matches a fresh sequential reference.
    let path_id = reader.path_id_for(SRC).expect("interned SRC");
    let _ = reader.steps_on_line(path_id, 10);
    assert_eq!(
        reader.lazy_full_steps_materialized(),
        Some(true),
        "a line-map accessor triggers the whole-table build"
    );

    // The reader's parallel-built per-line order must equal the sequential
    // reference's order for the same path/line.
    let sequential = build_with_strategy(&ct, StepBuildStrategy::Local { threads: 1 });
    let seq_path = path_id.0;
    for line_off in 0..40usize {
        let line = 10 + line_off;
        let reader_steps: Vec<i64> = reader
            .steps_on_line(path_id, line)
            .map(|v| v.iter().map(|s| s.step_id.0).collect())
            .unwrap_or_default();
        let ref_steps: Vec<i64> = sequential
            .1
            .get(seq_path)
            .and_then(|by_line| by_line.get(&line))
            .map(|v| v.iter().map(|s| s.step_id.0).collect())
            .unwrap_or_default();
        assert_eq!(
            reader_steps, ref_steps,
            "reader's parallel-built steps_on_line({line}) order must equal sequential reference"
        );
    }
}
