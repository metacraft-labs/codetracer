//! M26 — BREAKPOINT line→step resolution PREFERS the prepopulated `step-map.ns`
//! breakpoint index when a `.ct` carries one, WITHOUT materializing the whole
//! step table; and falls back to the M24c lazy / M25b parallel whole-table build
//! when the index is absent.
//!
//! ## What this proves
//!
//! 1. PARITY — for a bundle carrying `step-map.ns`, breakpoint resolution
//!    (`step_ids_on_line`) returns IDENTICAL step sets to the whole-table build,
//!    for every recorded line.
//! 2. NO whole-table build — when a breakpoint resolves via the prepopulated
//!    index, the lazy whole-step-table is NOT materialized
//!    (`lazy_full_steps_materialized() == false`).
//! 3. FALLBACK — a bundle WITHOUT the index resolves correctly via the
//!    whole-table build (unchanged M24c/M25b behaviour).
//!
//! ## Why the index here is REAL, not faked
//!
//! No production writer emits `step-map.ns` yet (the Nim `MultiStreamTraceWriter`
//! has only an opt-in, tests-only, never-serialized `LinehitsBuilder`; the
//! spec's `STMP` namespace has no emitter). So this test DERIVES the index from
//! the SAME recorded steps the whole-table build reconstructs — by replaying the
//! production bundle's whole-table line→step map and serializing it through the
//! production `serialize_step_map` into the spec's §4.1 `STMP` layout, dropped as
//! a `<ct>.step-map.ns` sidecar. The index therefore contains exactly the data a
//! recording-time emitter would compute; M26 wires the CONSUMER, and production
//! emission is a separate writer-side toggle (documented in the module + the
//! milestone).
//!
//! Requires the `nim-reader` feature (the production split-stream reader).

#![cfg(feature = "nim-reader")]
#![allow(clippy::expect_used, clippy::unwrap_used, clippy::panic)]

use std::path::{Path, PathBuf};

use codetracer_trace_types::{Line, PathId, StepId, TypeId, TypeKind, ValueRecord};

use codetracer_trace_writer_nim::{trace_writer::TraceWriter, NimTraceWriter, TraceEventsFileFormat};

use db_backend::ctfs_trace_reader::step_map_namespace::{serialize_step_map, StepMapNamespace, STEP_MAP_FILE};
use db_backend::ctfs_trace_reader::CTFSTraceReader;
use db_backend::trace_reader::TraceReader;

/// The single source file every step in the fixture recording lives in.
const SRC: &str = "/tmp/m26_step_map_prog.py";

/// Number of user steps recorded — enough to span multiple `steps.dat` chunks
/// (chunk size 4096) so the no-whole-table-build proof is meaningful.
const USER_STEPS: usize = 9000;

/// Distinct user lines the steps spread across.
const DISTINCT_LINES: usize = 50;

/// The recorded line of user step `i` — a deterministic spread so the line→step
/// map is non-trivial AND multiple steps share a line.
fn line_of_user_step(i: usize) -> i64 {
    10 + (i % DISTINCT_LINES) as i64
}

/// Produce a GENUINELY `events.log`-free split-only `.ct` bundle via the Nim
/// multi-stream writer — the exact write path every live recorder drives.
fn write_production_bundle(dir: &Path) -> PathBuf {
    let trace_path = dir.join("m26_step_map");
    let ct_path = dir.join("m26_step_map_prog.ct");

    let mut writer = NimTraceWriter::new("m26_step_map_prog", &[], TraceEventsFileFormat::Ctfs);
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

/// Build the `step-map.ns` SIDECAR for a bundle by REPLAYING its whole-table
/// line→step map (the exact data the whole-table build produces) and
/// serializing it into the spec's §4.1 `STMP` layout. This is the data a
/// recording-time emitter would write — derived from the trace, never faked.
fn write_step_map_sidecar(ct_path: &Path) {
    // Open WITHOUT a sidecar present, then drive the whole-table line→step map
    // through `step_map_for_path` (the M24c/M25b build) to get the ground-truth
    // (path, line) -> [step_id] data.
    let reader = CTFSTraceReader::open(ct_path).expect("open production for sidecar build");
    let path_id = reader.path_id_for(SRC).expect("source path interned");
    let line_map = reader
        .step_map_for_path(path_id)
        .expect("path has a whole-table line map")
        .clone();

    let mut entries: Vec<(PathId, usize, Vec<StepId>)> = Vec::new();
    for (line, steps) in line_map.iter() {
        let ids: Vec<StepId> = steps.iter().map(|s| s.step_id).collect();
        entries.push((path_id, *line, ids));
    }

    let blob = serialize_step_map(&entries);
    let mut name = ct_path.file_name().unwrap().to_os_string();
    name.push(".");
    name.push(STEP_MAP_FILE);
    let sidecar = ct_path.parent().unwrap().join(name);
    std::fs::write(&sidecar, &blob).expect("write step-map.ns sidecar");
}

/// The ground-truth `(line -> ascending step ids)` set the whole-table build
/// produces, computed analytically from the fixture's line spread. Used as the
/// independent oracle both the index and the whole-table build must match.
fn expected_line_steps(line: usize) -> Vec<StepId> {
    (0..USER_STEPS)
        .filter(|i| line_of_user_step(*i) == line as i64)
        .map(|i| StepId((i + 2) as i64))
        .collect()
}

/// DELIVERABLE — when the `.ct` carries `step-map.ns`, the reader attaches it
/// and breakpoint resolution is served from the index.
#[test]
fn bundle_with_step_map_attaches_index() {
    let dir = tempfile::tempdir().unwrap();
    let ct = write_production_bundle(dir.path());
    write_step_map_sidecar(&ct);

    let reader = CTFSTraceReader::open(&ct).expect("open with step-map.ns");
    assert!(
        reader.has_prepopulated_step_map(),
        "a bundle carrying step-map.ns must attach the prepopulated index"
    );

    let ns: &StepMapNamespace = reader.step_map().expect("index attached");
    // The recording spreads user steps across `DISTINCT_LINES` lines (10..59) and
    // ALSO records the leading step(s) at the function line (line 1), so the index
    // carries one entry per distinct line WITH steps: the 50 user lines + line 1.
    assert_eq!(
        ns.entry_count(),
        DISTINCT_LINES + 1,
        "the index must carry one entry per distinct recorded line (50 user lines + line 1)"
    );
}

/// DELIVERABLE — PARITY: the index returns IDENTICAL step sets to the
/// independent oracle (== the whole-table build) for every recorded line.
#[test]
fn index_resolution_matches_whole_table() {
    let dir = tempfile::tempdir().unwrap();
    let ct = write_production_bundle(dir.path());
    write_step_map_sidecar(&ct);

    let reader = CTFSTraceReader::open(&ct).expect("open with step-map.ns");
    let path_id = reader.path_id_for(SRC).expect("source path interned");

    for line_off in 0..DISTINCT_LINES {
        let line = 10 + line_off;
        let expected = expected_line_steps(line);

        let from_index = reader
            .step_ids_on_line(path_id, line)
            .expect("index resolves a recorded line");
        assert_eq!(
            from_index, expected,
            "index breakpoint resolution on line {line} must equal the recorded step set"
        );
    }

    // A line with no steps resolves to None through the index too.
    assert!(reader.step_ids_on_line(path_id, 9999).is_none());
}

/// DELIVERABLE — NO whole-table build: resolving breakpoints via the index does
/// NOT materialize the lazy whole-step-table.
#[test]
fn index_resolution_does_not_build_whole_table() {
    let dir = tempfile::tempdir().unwrap();
    let ct = write_production_bundle(dir.path());
    write_step_map_sidecar(&ct);

    let reader = CTFSTraceReader::open(&ct).expect("open with step-map.ns");
    let path_id = reader.path_id_for(SRC).expect("source path interned");

    // At open the whole-table view is not built.
    assert_eq!(reader.lazy_full_steps_materialized(), Some(false));

    // Resolve EVERY recorded line's breakpoint through the index.
    for line_off in 0..DISTINCT_LINES {
        let line = 10 + line_off;
        let _ = reader.step_ids_on_line(path_id, line);
    }

    // The whole-table view is STILL not built — breakpoint resolution went
    // entirely through the O(unique-lines) index.
    assert_eq!(
        reader.lazy_full_steps_materialized(),
        Some(false),
        "resolving breakpoints via step-map.ns must NOT materialize the whole step table"
    );
    // And the lazy step cache inflated nothing (no steps.dat access).
    assert_eq!(
        reader.lazy_steps_chunk_decompressions(),
        Some(0),
        "index breakpoint resolution must not inflate any steps.dat chunk"
    );
    assert_eq!(reader.lazy_steps_populated(), Some(0));
}

/// DELIVERABLE — FALLBACK: a bundle WITHOUT step-map.ns resolves breakpoints
/// correctly via the whole-table build (unchanged), and that build IS triggered
/// (proving the two paths are genuinely distinct).
#[test]
fn bundle_without_step_map_falls_back_to_whole_table() {
    let dir = tempfile::tempdir().unwrap();
    let ct = write_production_bundle(dir.path());
    // NO sidecar written.

    let reader = CTFSTraceReader::open(&ct).expect("open without step-map.ns");
    assert!(
        !reader.has_prepopulated_step_map(),
        "a bundle without step-map.ns must not attach an index"
    );

    let path_id = reader.path_id_for(SRC).expect("source path interned");
    assert_eq!(reader.lazy_full_steps_materialized(), Some(false));

    // Resolution still correct — served from the whole-table build.
    for line_off in 0..DISTINCT_LINES {
        let line = 10 + line_off;
        let expected = expected_line_steps(line);
        let resolved = reader
            .step_ids_on_line(path_id, line)
            .expect("fallback resolves a recorded line");
        assert_eq!(
            resolved, expected,
            "fallback breakpoint resolution on line {line} must equal the recorded step set"
        );
    }

    // The whole-table build WAS triggered by the fallback path — the distinguishing
    // counter-proof that this bundle did not use an index.
    assert_eq!(
        reader.lazy_full_steps_materialized(),
        Some(true),
        "fallback breakpoint resolution must materialize the whole-table view"
    );
}

/// DELIVERABLE — the two paths agree end-to-end: index and fallback produce the
/// SAME breakpoint resolution for the SAME trace, line by line.
#[test]
fn index_and_fallback_agree() {
    let dir = tempfile::tempdir().unwrap();
    let ct = write_production_bundle(dir.path());

    // Fallback reader (no sidecar).
    let fallback = CTFSTraceReader::open(&ct).expect("open fallback");
    let fpath = fallback.path_id_for(SRC).expect("path");

    // Index reader (with sidecar).
    write_step_map_sidecar(&ct);
    let indexed = CTFSTraceReader::open(&ct).expect("open indexed");
    let ipath = indexed.path_id_for(SRC).expect("path");
    assert!(indexed.has_prepopulated_step_map());

    for line_off in 0..DISTINCT_LINES {
        let line = 10 + line_off;
        let from_fallback = fallback.step_ids_on_line(fpath, line);
        let from_index = indexed.step_ids_on_line(ipath, line);
        assert_eq!(
            from_fallback, from_index,
            "index and whole-table fallback must resolve line {line} identically"
        );
    }

    // Sanity: the full trace really did span the chunked step stream.
    assert!(expected_step_count() > 4096, "fixture must span multiple steps.dat chunks");
}

/// DELIVERABLE — a MALFORMED step-map.ns is ignored (clean fallback), never a
/// hard open failure and never wrong breakpoints.
#[test]
fn malformed_step_map_is_ignored() {
    let dir = tempfile::tempdir().unwrap();
    let ct = write_production_bundle(dir.path());

    // Write a corrupt sidecar (bad magic).
    let mut name = ct.file_name().unwrap().to_os_string();
    name.push(".");
    name.push(STEP_MAP_FILE);
    let sidecar = ct.parent().unwrap().join(name);
    std::fs::write(&sidecar, b"not a step map at all").expect("write corrupt sidecar");

    let reader = CTFSTraceReader::open(&ct).expect("open must succeed despite corrupt sidecar");
    assert!(
        !reader.has_prepopulated_step_map(),
        "a malformed step-map.ns must be ignored, not attached"
    );

    // Breakpoint resolution still correct via the fallback build.
    let path_id = reader.path_id_for(SRC).expect("path");
    let line = 10;
    assert_eq!(
        reader.step_ids_on_line(path_id, line),
        Some(expected_line_steps(line))
    );
}
