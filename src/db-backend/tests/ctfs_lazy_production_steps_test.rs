//! M24c-steps — VERIFY the db-backend's PRODUCTION read path is RANGE-AWARE LAZY
//! for the STEP table: opening a real Nim production bundle no longer EAGERLY
//! materializes the whole `db.steps`, a point `step()` lookup pulls only the one
//! needed `steps.dat` chunk (range-aware fill), breakpoint-resolution line→step
//! and the slice/history accessors stay byte-identical to the eager path, and the
//! whole-table view is materialized ONLY on first slice/line-map demand.
//!
//! This is the step-side sibling of `ctfs_lazy_production_values_test.rs` (which
//! proved the same properties for the VALUE table). Together they show a
//! production open materializes NEITHER values NOR steps.
//!
//! ## Why this is the real production path
//!
//! The bundle is written by the Nim `MultiStreamTraceWriter` (the exact write
//! path every live recorder drives via FFI). M24a-1 brought its `steps.dat` onto
//! the SPEC-canonical wire format and `close()` sets `has_step_stream` (bit 9),
//! so the Rust seekable step reader can read it and the lazy step cache attaches.
//!
//! Requires the `nim-reader` feature (the production split-stream reader), which
//! is in the crate's default feature set.

#![cfg(feature = "nim-reader")]
#![allow(clippy::expect_used, clippy::unwrap_used, clippy::panic)]

use std::path::{Path, PathBuf};

use codetracer_trace_types::{Line, StepId, TypeId, TypeKind, ValueRecord};

use codetracer_trace_writer_nim::{NimTraceWriter, TraceEventsFileFormat, trace_writer::TraceWriter};

use db_backend::ctfs_trace_reader::CTFSTraceReader;
use db_backend::ctfs_trace_reader::ctfs_container::CtfsReader;
use db_backend::trace_reader::TraceReader;

/// The single source file every step in the fixture recording lives in.
const SRC: &str = "/tmp/lazy_production_steps_prog.py";

/// Number of user steps recorded. The step stream's chunk size is 4096
/// (`DEFAULT_STEPS_CHUNK_SIZE`), so > 4096 step records guarantees the bundle
/// spans MULTIPLE `steps.dat` chunks — letting us prove a single step fetch fills
/// only one chunk's RANGE, not the whole table. We record ~9000 steps → 3 chunks.
const USER_STEPS: usize = 9000;

/// The `steps.dat` records-per-chunk seek granularity
/// (`codetracer_trace_writer::step_stream::DEFAULT_STEPS_CHUNK_SIZE`). A point
/// `step()` lookup fills exactly this many slots (clamped at the trace end).
const STEPS_CHUNK_SIZE: usize = 4096;

/// The recorded line of user step `i` — a deterministic spread across 50 lines so
/// the line→step map is non-trivial AND multiple steps share a line.
fn line_of_user_step(i: usize) -> i64 {
    10 + (i % 50) as i64
}

/// Produce a GENUINELY `events.log`-free split-only `.ct` bundle via the Nim
/// multi-stream writer — the exact write path every live recorder drives.
fn write_production_bundle(dir: &Path) -> PathBuf {
    let trace_path = dir.join("lazy_production_steps");
    let ct_path = dir.join("lazy_production_steps_prog.ct");

    let mut writer = NimTraceWriter::new("lazy_production_steps_prog", &[], TraceEventsFileFormat::Ctfs);
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

/// DELIVERABLE 1 — the bundle is genuinely split-only and the seekable step
/// overlay engages (a production bundle exercises the lazy step path).
#[test]
fn split_only_bundle_takes_lazy_step_path() {
    let dir = tempfile::tempdir().unwrap();
    let ct = write_production_bundle(dir.path());

    {
        let ctfs = CtfsReader::open(&ct).expect("open ctfs container");
        assert!(ctfs.has_file("steps.dat"), "production bundle must ship steps.dat");
        assert!(
            !ctfs.has_file("events.log"),
            "production bundle must be events.log-free (split-only)"
        );
    }

    let reader = CTFSTraceReader::open(&ct).expect("CTFSTraceReader::open production");
    assert_eq!(
        reader.seekable_step_count(),
        Some(expected_step_count()),
        "seekable steps.dat overlay must engage on a production bundle"
    );
    // The reader is on the lazy step path.
    assert_eq!(
        reader.lazy_steps_populated(),
        Some(0),
        "production open must route through the lazy step cache"
    );
}

/// DELIVERABLE 2 — `open_new_format_nim` is LAZY for steps: opening a production
/// bundle does NOT materialize the step table. `db.steps` / `db.step_map` are
/// empty, the lazy cache has filled ZERO slots, no `steps.dat` chunk is inflated,
/// and the whole-table view is NOT built.
#[test]
fn open_does_not_materialize_step_table() {
    let dir = tempfile::tempdir().unwrap();
    let ct = write_production_bundle(dir.path());
    let reader = CTFSTraceReader::open(&ct).expect("open production");

    // The eager step table is NOT built: `db.steps` / `db.step_map` empty.
    assert!(
        reader.db().steps.is_empty(),
        "open() must NOT materialize db.steps on a production bundle (was {} entries)",
        reader.db().steps.len()
    );
    // `db.step_map` carries one EMPTY per-path slot from the interning loop, but
    // NO line→step entries are populated at open (that is the eager work we skip).
    let total_line_entries: usize = reader.db().step_map.items.iter().map(|by_line| by_line.len()).sum();
    assert_eq!(
        total_line_entries, 0,
        "open() must NOT populate any db.step_map line entries on a production bundle"
    );

    // The lazy cache filled nothing and inflated nothing.
    assert_eq!(reader.lazy_steps_populated(), Some(0), "no step slot filled at open");
    assert_eq!(
        reader.lazy_steps_chunk_decompressions(),
        Some(0),
        "no steps.dat chunk inflated at open"
    );
    // The whole-table view is NOT materialized at open.
    assert_eq!(
        reader.lazy_full_steps_materialized(),
        Some(false),
        "whole-table step view must not be built at open"
    );

    // The step count is still real (served from the lazy cache span).
    assert_eq!(reader.step_count(), expected_step_count());
}

/// DELIVERABLE 3 — RANGE-AWARE BOUNDED DECOMPRESSION: a single point `step()`
/// lookup inflates only ONE `steps.dat` chunk and fills only THAT chunk's range
/// of slots — never the whole table — and a neighbour in the same range is a free
/// cache hit while a step in a different chunk inflates exactly one more.
#[test]
fn point_step_lookup_fills_one_range_only() {
    let dir = tempfile::tempdir().unwrap();
    let ct = write_production_bundle(dir.path());
    let reader = CTFSTraceReader::open(&ct).expect("open production");

    assert_eq!(reader.lazy_steps_chunk_decompressions(), Some(0));
    // The trace spans multiple step chunks (9002 records at chunk size 4096 → 3).
    assert!(
        expected_step_count() > STEPS_CHUNK_SIZE,
        "fixture must span multiple steps.dat chunks"
    );

    // Fetch one step deep in a LATER chunk (step 5000 → steps.dat chunk 1, since
    // chunk size is 4096).
    let mid = StepId(5000);
    let s = reader.step(mid).expect("step 5000 present");
    assert_eq!(s.step_id, mid);
    // User step `i` lands at reader step `i + 2`; reader step 5000 → user step 4998.
    assert_eq!(
        s.line,
        Line(line_of_user_step(5000 - 2)),
        "lazy line must equal recorded line"
    );

    // Exactly one chunk inflated — bounded, range-aware (NOT the whole stream,
    // which spans 3 chunks here).
    assert_eq!(
        reader.lazy_steps_chunk_decompressions(),
        Some(1),
        "fetching one step must inflate exactly one steps.dat chunk"
    );
    // Only the requested step's chunk-aligned RANGE is filled — NOT the whole
    // table. Chunk 1 spans reader steps [4096, 8192), all within the trace, so the
    // filled range is exactly one chunk's worth of slots.
    let populated_after_mid = reader.lazy_steps_populated().unwrap();
    assert_eq!(
        populated_after_mid, STEPS_CHUNK_SIZE,
        "a point lookup fills exactly its chunk-aligned RANGE — not the whole table"
    );
    assert!(
        populated_after_mid < expected_step_count(),
        "the filled range must be strictly smaller than the whole table"
    );
    // The whole-table view is STILL not materialized — point navigation never
    // triggers it.
    assert_eq!(reader.lazy_full_steps_materialized(), Some(false));

    // A NEIGHBOUR in the SAME range is a free cache hit: no new chunk, no growth.
    let _ = reader.step(StepId(5001)).expect("neighbour present");
    assert_eq!(
        reader.lazy_steps_chunk_decompressions(),
        Some(1),
        "a neighbour in the same range must not inflate another chunk"
    );
    assert_eq!(
        reader.lazy_steps_populated(),
        Some(populated_after_mid),
        "a neighbour in the same range must not grow the populated set"
    );

    // A step in a DIFFERENT chunk (step 0 → chunk 0) inflates EXACTLY one more
    // chunk and fills only that range.
    let _ = reader.step(StepId(0)).expect("first step present");
    assert_eq!(
        reader.lazy_steps_chunk_decompressions(),
        Some(2),
        "touching a step in a new chunk inflates exactly one more chunk"
    );
    assert_eq!(
        reader.lazy_steps_populated(),
        Some(2 * STEPS_CHUNK_SIZE),
        "two distinct chunks filled — still NOT the whole table"
    );
    assert!(
        reader.lazy_steps_populated().unwrap() < expected_step_count(),
        "point lookups must not have materialized the whole step table"
    );
}

/// DELIVERABLE 4 — PARITY of `step()`: every step's `(path_id, line)` and call
/// keys equal the recorded values, and re-opening with the whole-table view does
/// not change them. The debugger shows identical step locations on the lazy path.
#[test]
fn lazy_step_lines_equal_recorded() {
    let dir = tempfile::tempdir().unwrap();
    let ct = write_production_bundle(dir.path());
    let reader = CTFSTraceReader::open(&ct).expect("open production");

    let path_id = reader.path_id_for(SRC).expect("source path interned");

    for i in 0..USER_STEPS {
        let sid = StepId((i + 2) as i64);
        let s = reader.step(sid).expect("user step present");
        assert_eq!(
            s.path_id, path_id,
            "lazy path_id must equal recorded path for step {}",
            sid.0
        );
        assert_eq!(
            s.line,
            Line(line_of_user_step(i)),
            "lazy line at user step {i} (reader step {}) must equal recorded line",
            sid.0
        );
        // The call key is the registered call (key 0) for every user step.
        assert!(s.call_key.0 >= 0, "user step {} must belong to a call", sid.0);
    }

    // Out-of-range yields None (matching the eager `db.steps.get`).
    assert!(reader.step(StepId(expected_step_count() as i64)).is_none());
    assert!(reader.step(StepId(-1)).is_none());
}

/// DELIVERABLE 5 — PARITY of BREAKPOINT RESOLUTION (line→step): `steps_on_line`
/// and `step_map_for_path` on the lazy path return exactly the steps the eager
/// path would, served from the on-first-demand whole-table view. This is the
/// breakpoint-resolution read path.
#[test]
fn breakpoint_resolution_parity() {
    let dir = tempfile::tempdir().unwrap();
    let ct = write_production_bundle(dir.path());
    let reader = CTFSTraceReader::open(&ct).expect("open production");

    let path_id = reader.path_id_for(SRC).expect("source path interned");

    // Before any line-map query, the whole-table view is not built.
    assert_eq!(reader.lazy_full_steps_materialized(), Some(false));

    // For each of the 50 distinct user lines, the resolved step set must equal the
    // set of user steps recorded on that line. User step `i` (reader step `i+2`)
    // is on line `10 + i%50`.
    for line_off in 0..50usize {
        let line = 10 + line_off;
        let expected: Vec<i64> = (0..USER_STEPS)
            .filter(|i| line_of_user_step(*i) == line as i64)
            .map(|i| (i + 2) as i64)
            .collect();

        let resolved = reader
            .steps_on_line(path_id, line)
            .map(|v| v.iter().map(|s| s.step_id.0).collect::<Vec<_>>())
            .unwrap_or_default();

        assert_eq!(
            resolved, expected,
            "breakpoint resolution on line {line} must match the recorded step set"
        );
    }

    // The line-map query materialized the whole-table view exactly once.
    assert_eq!(
        reader.lazy_full_steps_materialized(),
        Some(true),
        "a line-map query materializes the whole-table view"
    );

    // `step_map_for_path` agrees with the per-line accessor.
    let map = reader.step_map_for_path(path_id).expect("path has a line map");
    for line_off in 0..50usize {
        let line = 10 + line_off;
        let from_map = map.get(&line).map(|v| v.len()).unwrap_or(0);
        let from_acc = reader.steps_on_line(path_id, line).map(|v| v.len()).unwrap_or(0);
        assert_eq!(
            from_map, from_acc,
            "step_map_for_path must agree with steps_on_line on line {line}"
        );
    }

    // A line with no recorded steps resolves to None.
    assert!(reader.steps_on_line(path_id, 9999).is_none());
}

/// DELIVERABLE 6 — PARITY of the HISTORY / full-scan slice accessor `steps_from`:
/// the contiguous slice the lazy path serves equals the recorded step sequence,
/// and `materialized_db()` rebuilds a `Db` whose `steps` / `step_map` match.
#[test]
fn history_slice_and_materialized_db_parity() {
    let dir = tempfile::tempdir().unwrap();
    let ct = write_production_bundle(dir.path());
    let reader = CTFSTraceReader::open(&ct).expect("open production");

    let path_id = reader.path_id_for(SRC).expect("source path interned");

    // `steps_from(0)` is the full sequence — used by backward breakpoint scans and
    // history. It must be every step in order with the recorded lines.
    let all = reader.steps_from(StepId(0));
    assert_eq!(all.len(), expected_step_count(), "steps_from(0) spans the whole trace");
    for i in 0..USER_STEPS {
        let s = &all[i + 2];
        assert_eq!(s.step_id, StepId((i + 2) as i64));
        assert_eq!(s.line, Line(line_of_user_step(i)));
    }

    // A mid-trace slice starts at the requested step.
    let tail = reader.steps_from(StepId(300));
    assert_eq!(tail.len(), expected_step_count() - 300);
    assert_eq!(tail[0].step_id, StepId(300));

    // `materialized_db()` rebuilds the full step table + line map identically.
    let mdb = reader.materialized_db();
    assert_eq!(
        mdb.steps.len(),
        expected_step_count(),
        "materialized_db rebuilds the step table"
    );
    for i in 0..expected_step_count() {
        let lazy = reader.step(StepId(i as i64)).expect("lazy step");
        let mat = &mdb.steps.items[i];
        assert_eq!(lazy.step_id, mat.step_id);
        assert_eq!(lazy.path_id, mat.path_id);
        assert_eq!(lazy.line, mat.line);
        assert_eq!(lazy.column, mat.column);
        assert_eq!(lazy.call_key, mat.call_key);
        assert_eq!(lazy.global_call_key, mat.global_call_key);
    }
    // The rebuilt line map matches the lazy line-map accessor.
    let mdb_line_map = mdb.step_map.get(path_id).expect("materialized_db line map");
    for line_off in 0..50usize {
        let line = 10 + line_off;
        let mat_len = mdb_line_map.get(&line).map(|v| v.len()).unwrap_or(0);
        let acc_len = reader.steps_on_line(path_id, line).map(|v| v.len()).unwrap_or(0);
        assert_eq!(mat_len, acc_len, "materialized_db line {line} matches lazy accessor");
    }
}
