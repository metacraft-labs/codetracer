//! A container that STATES how large each of its files is, read end to end.
//!
//! A line-only `.ct` used to record nothing about how its address space was
//! apportioned between files, so every reader here re-applied the writer's
//! convention of `DEFAULT_LINES_PER_FILE` addresses each. That convention is
//! unrecorded, and above its own ceiling it is wrong: a file with more lines
//! has them addressed inside the NEXT file's range. Such an address is inside
//! the trace's space, so nothing downstream can refuse it — the debugger shows
//! a file that exists at a line number that is arithmetic.
//!
//! `meta.dat` bit 14 (`FLAG_HAS_LINE_COUNT_TABLE`) makes every `paths.dat`
//! record carry its file's line count, and this reader lays the space out from
//! those counts.
//!
//! What is asserted here, and how each one fails:
//!
//!   1. Every step reads back at the `(path_id, line)` it was recorded at, over
//!      a TWO-file trace. Path 0 is where every apportionment agrees, so a
//!      single-file fixture could not see the sizing at all; path 1's steps are
//!      the ones a mis-sized space misplaces.
//!   2. The space really is the sum of the recorded counts and not the
//!      convention — otherwise assertion 1 would hold for the wrong reason
//!      (a stride space also resolves its own addresses consistently).
//!   3. The MUTATION CONTROL: the identical program recorded WITHOUT the table
//!      produces a strictly larger space, so the two arms differ in the thing
//!      under test and not only in a flag byte.
//!   4. A step past a file's recorded count is refused at the WRITER, which is
//!      the only place it can be caught — its address is well-formed and
//!      in-space, so no assertion this file could make on the read side would
//!      fire.
//!
//! No mock: the fixtures are written by the production Nim
//! `MultiStreamTraceWriter` through its FFI, which is the write path every live
//! recorder drives, and read through `CTFSTraceReader::open`, which is the path
//! a debugger session takes.
//!
//! Requires the `nim-reader` feature (the production split-stream reader), which
//! is in the crate's default feature set.

#![cfg(feature = "nim-reader")]
#![allow(clippy::expect_used, clippy::unwrap_used, clippy::panic)]

use std::path::{Path, PathBuf};

use codetracer_trace_types::{Line, StepId};
use codetracer_trace_writer::line_position::DEFAULT_LINES_PER_FILE;
use codetracer_trace_writer_nim::{NimTraceWriter, TraceEventsFileFormat, trace_writer::TraceWriter};

use db_backend::ctfs_trace_reader::CTFSTraceReader;
use db_backend::ctfs_trace_reader::ctfs_container::CtfsReader;
use db_backend::ctfs_trace_reader::interning_tables::InterningTables;
use db_backend::ctfs_trace_reader::line_position_space::container_line_space;
use db_backend::trace_reader::TraceReader;

const MAIN_SRC: &str = "/tmp/line_count_main.py";
const LIB_SRC: &str = "/tmp/line_count_lib.py";

/// Real line counts, small enough that the space they define is nowhere near
/// the convention's — which is what makes assertion 2 falsifiable.
const MAIN_LINES: u64 = 40;
const LIB_LINES: u64 = 25;

/// The `(path, line)` pairs the fixture records, in order. Both files' last
/// lines are included: the last line of a non-final file is the address that
/// spills into the next file when the sizing is wrong.
fn recorded() -> Vec<(&'static str, i64)> {
    vec![
        (MAIN_SRC, 1),
        (MAIN_SRC, 7),
        (LIB_SRC, 1),
        (LIB_SRC, 13),
        (MAIN_SRC, MAIN_LINES as i64),
        (LIB_SRC, LIB_LINES as i64),
    ]
}

/// Write a two-file bundle, with or without the line-count table. The two arms
/// record the identical program, so they differ in the sizing and nothing else.
fn write_bundle(dir: &Path, name: &str, with_table: bool) -> PathBuf {
    let trace_path = dir.join(name);
    let ct_path = dir.join(format!("{name}.ct"));

    let mut writer = NimTraceWriter::new(name, &[], TraceEventsFileFormat::Ctfs);
    writer.set_workdir(dir);
    writer.begin_writing_trace_metadata(&trace_path).unwrap();
    writer.finish_writing_trace_metadata().unwrap();
    writer.begin_writing_trace_events(&trace_path).unwrap();
    writer.begin_writing_trace_paths(&trace_path).unwrap();
    writer.finish_writing_trace_paths().unwrap();

    if with_table {
        writer.enable_line_count_table().expect("enable the line-count table");
        writer
            .register_path_with_line_count(Path::new(MAIN_SRC), MAIN_LINES)
            .expect("register main with its line count");
        writer
            .register_path_with_line_count(Path::new(LIB_SRC), LIB_LINES)
            .expect("register lib with its line count");
    }

    let first = recorded()[0];
    writer.start(Path::new(first.0), Line(first.1));
    for (path, line) in recorded().into_iter().skip(1) {
        writer.register_step(Path::new(path), Line(line));
    }
    writer.finish_writing_trace_events().unwrap();
    writer.close().unwrap();

    assert!(ct_path.exists(), ".ct should be produced at {}", ct_path.display());
    ct_path
}

#[test]
fn every_step_reads_back_where_it_was_recorded() {
    let dir = tempfile::tempdir().unwrap();
    let ct = write_bundle(dir.path(), "counted", true);

    let reader = CTFSTraceReader::open(&ct).expect("open the counted bundle");
    let main_id = reader.path_id_for(MAIN_SRC).expect("main source interned");
    let lib_id = reader.path_id_for(LIB_SRC).expect("lib source interned");
    assert_ne!(main_id, lib_id, "the two sources must intern to different ids");

    for (i, (path, line)) in recorded().into_iter().enumerate() {
        let want_id = if path == MAIN_SRC { main_id } else { lib_id };
        let s = reader.step(StepId(i as i64)).expect("step present");
        assert_eq!(
            s.path_id,
            want_id,
            "step {i} was recorded in {path}; the reader says {:?} ({:?}) — the file's slot in \
             the position space is not the size the container states",
            s.path_id,
            reader.db().paths[s.path_id]
        );
        assert_eq!(
            s.line,
            Line(line),
            "step {i} was recorded at {path}:{line}; the reader says {:?}",
            s.line
        );
    }
}

/// The space is the sum of the RECORDED counts. Without this the test above
/// would hold for the wrong reason: a stride space also resolves its own
/// addresses consistently, and would pass every assertion there.
#[test]
fn the_space_is_the_sum_of_the_recorded_counts() {
    let dir = tempfile::tempdir().unwrap();
    let ct = write_bundle(dir.path(), "sized", true);

    let mut ctfs = CtfsReader::open(&ct).expect("open the container");
    let tables = InterningTables::open_from_ctfs(&mut ctfs)
        .expect("interning tables decode")
        .expect("paths.dat present");
    assert_eq!(
        tables.line_counts,
        vec![MAIN_LINES, LIB_LINES],
        "the container must STATE each file's line count"
    );

    let space = container_line_space(&mut ctfs).expect("the container registers paths");
    assert_eq!(
        space.total_lines(),
        MAIN_LINES + LIB_LINES,
        "the space must be the sum of the recorded counts, not the convention's {}",
        2 * DEFAULT_LINES_PER_FILE
    );
    // The boundary the sizing exists to get right: file 0's last line is the
    // last address of file 0's slot, and file 1's first line is file 1's base.
    assert_eq!(space.resolve(MAIN_LINES - 1), Ok((0, MAIN_LINES as i64)));
    assert_eq!(space.resolve(MAIN_LINES), Ok((1, 1)));
    assert!(
        space.resolve(MAIN_LINES + LIB_LINES).is_err(),
        "one past the top of the space must be refused"
    );
}

/// MUTATION CONTROL. The identical program without the table is sized by the
/// convention instead. If both arms produced the same space the table would be
/// doing nothing and the test above would be an assertion about a constant.
#[test]
fn without_the_table_the_same_program_uses_the_convention() {
    let dir = tempfile::tempdir().unwrap();
    let ct = write_bundle(dir.path(), "uncounted", false);

    let mut ctfs = CtfsReader::open(&ct).expect("open the container");
    let tables = InterningTables::open_from_ctfs(&mut ctfs)
        .expect("interning tables decode")
        .expect("paths.dat present");
    assert!(
        tables.line_counts.is_empty(),
        "a container without bit 14 states NO per-file size; got {:?}",
        tables.line_counts
    );

    let space = container_line_space(&mut ctfs).expect("the container registers paths");
    assert_eq!(
        space.total_lines(),
        2 * DEFAULT_LINES_PER_FILE,
        "without the table the space is the convention's"
    );
    assert_ne!(
        space.total_lines(),
        MAIN_LINES + LIB_LINES,
        "the two arms must differ in the sizing, or neither test proves anything"
    );

    // And the steps still read back correctly under the convention — the table
    // is an improvement, not a prerequisite.
    let reader = CTFSTraceReader::open(&ct).expect("open the uncounted bundle");
    let main_id = reader.path_id_for(MAIN_SRC).expect("main source interned");
    let lib_id = reader.path_id_for(LIB_SRC).expect("lib source interned");
    for (i, (path, line)) in recorded().into_iter().enumerate() {
        let want_id = if path == MAIN_SRC { main_id } else { lib_id };
        let s = reader.step(StepId(i as i64)).expect("step present");
        assert_eq!(s.path_id, want_id, "step {i} path, uncounted arm");
        assert_eq!(s.line, Line(line), "step {i} line, uncounted arm");
    }
}

/// The spill refusal, at the only place it can happen. A step one line past a
/// file's recorded count addresses the FIRST line of the next file: a
/// well-formed address of a location that was never recorded, which no reader
/// can detect. The writer, which was given the count, refuses it.
#[test]
fn a_step_past_the_recorded_count_is_refused_at_the_writer() {
    let dir = tempfile::tempdir().unwrap();
    let trace_path = dir.path().join("overflow");

    let mut writer = NimTraceWriter::new("overflow", &[], TraceEventsFileFormat::Ctfs);
    writer.set_workdir(dir.path());
    writer.begin_writing_trace_metadata(&trace_path).unwrap();
    writer.finish_writing_trace_metadata().unwrap();
    writer.begin_writing_trace_events(&trace_path).unwrap();
    writer.begin_writing_trace_paths(&trace_path).unwrap();
    writer.finish_writing_trace_paths().unwrap();
    writer.enable_line_count_table().expect("enable the line-count table");
    writer
        .register_path_with_line_count(Path::new(MAIN_SRC), MAIN_LINES)
        .expect("register main with its line count");
    writer
        .register_path_with_line_count(Path::new(LIB_SRC), LIB_LINES)
        .expect("register lib with its line count");

    // The file's own last line is inside its slot, so the writer is not simply
    // refusing everything. `last_error` is sticky, so this also establishes the
    // known-empty state the assertion below reads against — without it the
    // assertion could be echoing a message from an earlier call.
    writer.start(Path::new(MAIN_SRC), Line(MAIN_LINES as i64));
    assert_eq!(
        codetracer_trace_writer_nim::last_error(),
        "",
        "the file's own last line must be accepted"
    );

    // One past it is not. The refusal surfaces when the buffered step flushes.
    writer.register_step(Path::new(MAIN_SRC), Line(MAIN_LINES as i64 + 1));
    writer.register_step(Path::new(LIB_SRC), Line(1));
    let err = codetracer_trace_writer_nim::last_error();
    assert!(
        err.contains(MAIN_SRC) && err.contains(&MAIN_LINES.to_string()),
        "a step at line {} of a file recorded as having {MAIN_LINES} lines must be refused by \
         name; last_error was: {err:?}",
        MAIN_LINES + 1
    );

    // Registering a path with no count at all is refused too, so a caller
    // cannot half-state the table by forgetting a call.
    assert!(
        writer
            .register_path_with_line_count(Path::new("/tmp/zero.py"), 0)
            .is_err(),
        "a recorded count of 0 must be refused: a file sized 0 shares its base with the next one"
    );
}
