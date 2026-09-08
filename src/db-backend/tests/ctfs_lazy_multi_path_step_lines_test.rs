//! The lazy step path must report the `(path_id, line)` a step was recorded at
//! on a trace with MORE THAN ONE source file.
//!
//! `ctfs_lazy_production_steps_test` proves the lazy path's laziness, its
//! bounded decompression and its line parity — over a bundle with a single
//! source file. Path 0 is where every apportionment of the line-only
//! `global_line_index` agrees: whatever the writer's rule, path 0's base is 0
//! and the address is the line. So a single-path fixture cannot see how the
//! address was apportioned, and the disagreement between the two writers of
//! this container format hid behind exactly that.
//!
//! The Nim `MultiStreamTraceWriter` — the write path every live recorder drives
//! through the FFI, and the one this fixture uses — packs
//! `prefix_sum[path_id] + line` with 100_000 addresses per file. The lazy Rust
//! path used to invert every record with the OTHER writer's rule,
//! `(path_id << 32) | line`, and so reported a step recorded at
//! (path 1, line 12) as path 0, line 100_012: a file that exists, a line number
//! that is arithmetic, and no error anywhere. Because the Nim writer always
//! stamps `has_step_stream`, the lazy path is the one a production open takes,
//! so that was the location the debugger showed and the key breakpoint
//! resolution missed.
//!
//! Requires the `nim-reader` feature (the production split-stream reader), which
//! is in the crate's default feature set.

#![cfg(feature = "nim-reader")]
#![allow(clippy::expect_used, clippy::unwrap_used, clippy::panic)]

use std::path::{Path, PathBuf};

use codetracer_trace_types::{Line, StepId, TypeId, TypeKind, ValueRecord};

use codetracer_trace_writer_nim::{NimTraceWriter, TraceEventsFileFormat, trace_writer::TraceWriter};

use db_backend::ctfs_trace_reader::CTFSTraceReader;
use db_backend::ctfs_trace_reader::line_only_position::LineOnlyPositionSpace;
use db_backend::trace_reader::TraceReader;

/// The first registered source file. Its steps are the ones that look right
/// under every apportionment.
const MAIN_SRC: &str = "/tmp/lazy_multi_path_main.py";
/// The second registered source file. Its steps are the ones that do not.
const LIB_SRC: &str = "/tmp/lazy_multi_path_lib.py";

/// The line every step in `LIB_SRC` is recorded at, per index.
fn lib_line(i: usize) -> i64 {
    12 + (i % 4) as i64
}

/// The line every step in `MAIN_SRC` is recorded at, per index.
fn main_line(i: usize) -> i64 {
    3 + (i % 5) as i64
}

const STEPS_PER_FILE: usize = 12;

/// Produce a split-only `.ct` through the Nim multi-stream writer, alternating
/// between two source files so both path ids carry steps.
fn write_two_path_bundle(dir: &Path) -> PathBuf {
    let trace_path = dir.join("lazy_multi_path");
    let ct_path = dir.join("lazy_multi_path_main.ct");

    let mut writer = NimTraceWriter::new("lazy_multi_path_main", &[], TraceEventsFileFormat::Ctfs);
    writer.set_workdir(dir);
    writer.begin_writing_trace_metadata(&trace_path).unwrap();
    writer.finish_writing_trace_metadata().unwrap();
    writer.begin_writing_trace_events(&trace_path).unwrap();
    writer.begin_writing_trace_paths(&trace_path).unwrap();
    writer.finish_writing_trace_paths().unwrap();

    let main_path = Path::new(MAIN_SRC);
    let lib_path = Path::new(LIB_SRC);
    let fid = writer.ensure_function_id("main", main_path, Line(1));
    writer.register_function("main", main_path, Line(1));

    writer.start(main_path, Line(1));
    writer.register_step(main_path, Line(1));
    let int_type = writer.ensure_type_id(TypeKind::Int, "int");
    TraceWriter::register_call(&mut writer, fid, vec![]);

    for i in 0..STEPS_PER_FILE {
        writer.register_step(main_path, Line(main_line(i)));
        writer.register_variable_with_full_value(
            "var",
            ValueRecord::Int {
                i: i as i64,
                type_id: int_type,
            },
        );
        writer.register_step(lib_path, Line(lib_line(i)));
        writer.register_variable_with_full_value(
            "var",
            ValueRecord::Int {
                i: i as i64,
                type_id: int_type,
            },
        );
    }

    writer.register_return(ValueRecord::None { type_id: TypeId(0) });
    writer.finish_writing_trace_events().unwrap();
    writer.close().unwrap();

    assert!(ct_path.exists(), ".ct should be produced at {}", ct_path.display());
    ct_path
}

/// The reader step index of the `i`-th step recorded in `MAIN_SRC` inside the
/// loop. Two leading steps precede the loop (`start` + `register_step`), and the
/// loop emits two steps per iteration.
fn main_step_id(i: usize) -> StepId {
    StepId((2 + i * 2) as i64)
}

/// The reader step index of the `i`-th step recorded in `LIB_SRC`.
fn lib_step_id(i: usize) -> StepId {
    StepId((3 + i * 2) as i64)
}

/// The fixture really does take the lazy path — otherwise the assertions below
/// would be about the eager decoder and prove nothing about the live one.
#[test]
fn two_path_bundle_takes_the_lazy_step_path() {
    let dir = tempfile::tempdir().unwrap();
    let ct = write_two_path_bundle(dir.path());
    let reader = CTFSTraceReader::open(&ct).expect("open two-path bundle");

    assert_eq!(
        reader.lazy_steps_populated(),
        Some(0),
        "a production open must route through the lazy step cache; \
         these assertions are about that path"
    );
    assert!(
        reader.db().paths.len() >= 2,
        "the fixture must register two source files, got {:?}",
        reader.db().paths
    );
}

/// THE REPRODUCER. Every step comes back at the file and line it was recorded
/// at, including the ones in the second file.
#[test]
fn lazy_step_locations_equal_recorded_across_two_paths() {
    let dir = tempfile::tempdir().unwrap();
    let ct = write_two_path_bundle(dir.path());
    let reader = CTFSTraceReader::open(&ct).expect("open two-path bundle");

    let main_id = reader.path_id_for(MAIN_SRC).expect("main source interned");
    let lib_id = reader.path_id_for(LIB_SRC).expect("lib source interned");
    assert_ne!(main_id, lib_id, "the two sources must intern to different ids");

    for i in 0..STEPS_PER_FILE {
        let sid = main_step_id(i);
        let s = reader.step(sid).expect("main step present");
        assert_eq!(s.path_id, main_id, "step {} path (main file)", sid.0);
        assert_eq!(s.line, Line(main_line(i)), "step {} line (main file)", sid.0);

        let sid = lib_step_id(i);
        let s = reader.step(sid).expect("lib step present");
        assert_eq!(
            s.path_id,
            lib_id,
            "step {} was recorded in {LIB_SRC}; the reader says {:?} ({:?})",
            sid.0,
            s.path_id,
            reader.db().paths[s.path_id]
        );
        assert_eq!(
            s.line,
            Line(lib_line(i)),
            "step {} was recorded at line {}; the reader says {:?}",
            sid.0,
            lib_line(i),
            s.line
        );
    }
}

/// BREAKPOINT RESOLUTION on the second file, through the whole-table line map
/// the lazy path materializes on first demand — the same decode, reached the
/// way a breakpoint reaches it. A breakpoint request arrives as (source path,
/// line) and is interned to `(path_id, line)`; if the steps were filed under a
/// different pair, the request resolves to nothing.
///
/// `step_ids_on_line` is deliberately NOT used here. It prefers the
/// prepopulated `step-map.ns` index when the container carries one, and that
/// index is built by the WRITER — its keying is the writer's contract, asserted
/// in `codetracer-trace-format-nim`, and answering from it would say nothing
/// about the decode this test is about.
#[test]
fn breakpoint_resolution_finds_steps_in_the_second_path() {
    let dir = tempfile::tempdir().unwrap();
    let ct = write_two_path_bundle(dir.path());
    let reader = CTFSTraceReader::open(&ct).expect("open two-path bundle");

    let lib_id = reader.path_id_for(LIB_SRC).expect("lib source interned");
    let line = lib_line(0) as usize;

    let steps = reader
        .steps_on_line(lib_id, line)
        .unwrap_or_else(|| panic!("no steps on {LIB_SRC}:{line}; the file's steps were filed elsewhere"));
    assert!(
        !steps.is_empty(),
        "a breakpoint on {LIB_SRC}:{line} must resolve to the steps recorded there"
    );
    for s in steps {
        assert_eq!(s.path_id, lib_id);
        assert_eq!(s.line, Line(line as i64));
    }
}

/// The arithmetic, stated against the writer this fixture uses, so the
/// reproducer above cannot pass for an unrelated reason. The address the Nim
/// writer gives (path 1, line 12) in a two-path trace inverts to (1, 12) here
/// and to (0, 100012) under the rival packing.
#[test]
fn the_two_packings_differ_exactly_where_this_test_looks() {
    let space = LineOnlyPositionSpace::uniform(2);
    assert_eq!(space.resolve(100_012), Ok((1, 12)));
    assert_eq!(
        codetracer_trace_writer::step_stream::unpack_global_line_index(100_012),
        (0, 100_012),
        "the reading the lazy path used to apply to a Nim-written address"
    );
}
