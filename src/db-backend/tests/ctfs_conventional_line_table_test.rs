//! A column-aware `paths.dat` record with `line_count = 0` is the
//! conventional table: 100,000 lines of 1024 positions each.
//!
//! Spec: `codetracer-trace-format-spec/internal-files.md` §"paths.dat Layout
//! A": "`0` ... is the **only** encoding of the conventional table ... A reader
//! MUST decode `line_count = 0` as 100,000 lines of 1024 positions, and SHOULD
//! hold it as that rule rather than as an array."
//!
//! # What goes wrong when a reader misses it
//!
//! A reader that takes `0` literally sizes the file at zero positions. The
//! file's own steps then have no table to resolve against, and every file
//! interned AFTER it starts 1.024e8 positions too early, so its steps land on
//! the wrong file or out of range. The subject container therefore puts the
//! conventional file FIRST, ahead of a file with a real table, so both halves
//! of the defect are visible.
//!
//! # How the subject is built
//!
//! The Nim writer records the container with the conventional file registered
//! by its spelled-out table (100,000 × 1024), which the spec requires a writer
//! to record as `line_count = 0`. So that the subject does not depend on that
//! writer rule, the test then rewrites the conventional file's `paths.dat`
//! record to `line_count = 0` itself and re-emits every other member unchanged
//! (`the_rewrite_changes_only_the_conventional_record` pins that). The CONTROL
//! arm opens the container as the writer wrote it.
//!
//! No mocks: the writer, the container and both readers (the browser's
//! `from_bytes` and the native `open`) are the real ones.

#![cfg(feature = "nim-reader")]
#![allow(clippy::expect_used, clippy::unwrap_used, clippy::panic)]

use std::path::{Path, PathBuf};

use codetracer_trace_types::Line;
use codetracer_trace_writer_nim::{NimTraceWriter, TraceEventsFileFormat};
use db_backend::ctfs_trace_reader::CTFSTraceReader;
use db_backend::ctfs_trace_reader::ctfs_container::{CtfsReader, write_minimal_ctfs};
use db_backend::trace_reader::TraceReader;

const CONVENTIONAL_LINES: usize = 100_000;
const CONVENTIONAL_POSITIONS_PER_LINE: u32 = 1024;

/// The file with a real table, interned after the conventional one.
const REAL_LINE_LENGTHS: [u32; 4] = [12, 30, 25, 18];

/// `(line, column)` written on the conventional file. Line 99,999 column 1000
/// sits near the end of its 1.024e8 positions, so a decoder that sized the file
/// wrongly cannot place it by accident.
const CONVENTIONAL_STEPS: [(i64, i64); 3] = [(7, 3), (512, 1), (99_999, 1000)];

/// `(line, column)` written on the real file.
const REAL_STEPS: [(i64, i64); 3] = [(1, 1), (2, 29), (4, 18)];

fn conventional_path() -> PathBuf {
    PathBuf::from("/tmp/ct_conventional_table_subject.bin")
}

fn real_path() -> PathBuf {
    PathBuf::from("/tmp/ct_conventional_table_neighbour.nr")
}

/// Record the subject with the Nim writer and return the `.ct` bytes.
fn record() -> Vec<u8> {
    let dir = tempfile::tempdir().unwrap();
    let trace_path = dir.path().join("trace");
    let conventional = conventional_path();
    let real = real_path();
    let spelled_out = vec![CONVENTIONAL_POSITIONS_PER_LINE; CONVENTIONAL_LINES];

    let mut writer = NimTraceWriter::new("conventional_table", &[], TraceEventsFileFormat::Ctfs);
    writer.set_workdir(dir.path());
    writer.begin_writing_trace_metadata(&trace_path).unwrap();
    writer.finish_writing_trace_metadata().unwrap();
    writer.begin_writing_trace_events(&trace_path).unwrap();
    writer.begin_writing_trace_paths(&trace_path).unwrap();
    writer.enable_column_aware_steps();
    writer
        .register_path_with_line_lengths(&conventional, &spelled_out)
        .unwrap();
    writer
        .register_path_with_line_lengths(&real, &REAL_LINE_LENGTHS)
        .unwrap();
    writer.finish_writing_trace_paths().unwrap();

    let function = writer.ensure_function_id("subject", &real, Line(1));
    writer.start(&real, Line(1));
    writer.register_call(function, Vec::new());
    for (line, column) in CONVENTIONAL_STEPS {
        writer.register_step_with_column(&conventional, Line(line), Some(Line(column)));
    }
    for (line, column) in REAL_STEPS {
        writer.register_step_with_column(&real, Line(line), Some(Line(column)));
    }
    writer.finish_writing_trace_events().unwrap();
    writer.close().unwrap();

    let containers: Vec<PathBuf> = std::fs::read_dir(dir.path())
        .unwrap()
        .filter_map(|entry| entry.ok().map(|e| e.path()))
        .filter(|p| p.extension().is_some_and(|ext| ext == "ct"))
        .collect();
    assert_eq!(
        containers.len(),
        1,
        "expected one .ct in {:?}: {containers:?}",
        dir.path()
    );
    std::fs::read(&containers[0]).unwrap()
}

fn read_varint(bytes: &[u8], pos: &mut usize) -> u64 {
    let mut value = 0u64;
    let mut shift = 0;
    loop {
        let byte = bytes[*pos];
        *pos += 1;
        value |= u64::from(byte & 0x7f) << shift;
        if byte & 0x80 == 0 {
            return value;
        }
        shift += 7;
    }
}

/// `paths.dat` records split by `paths.off` (u64 little-endian offsets).
fn split_records(dat: &[u8], off: &[u8]) -> Vec<Vec<u8>> {
    let offsets: Vec<usize> = off
        .chunks_exact(8)
        .map(|c| u64::from_le_bytes(c.try_into().unwrap()) as usize)
        .collect();
    offsets.windows(2).map(|w| dat[w[0]..w[1]].to_vec()).collect()
}

/// A record's path and its stated `line_count`.
fn path_and_line_count(record: &[u8]) -> (String, u64) {
    let mut pos = 0;
    let len = read_varint(record, &mut pos) as usize;
    let path = String::from_utf8(record[pos..pos + len].to_vec()).unwrap();
    pos += len;
    (path, read_varint(record, &mut pos))
}

/// Rewrite the conventional file's record to `line_count = 0` and re-emit the
/// container with every other member unchanged.
fn with_conventional_record_as_zero(container: &[u8]) -> Vec<u8> {
    let mut ctfs = CtfsReader::from_bytes(container.to_vec()).unwrap();
    let mut names: Vec<String> = ctfs.file_names().into_iter().map(str::to_string).collect();
    names.sort();
    let dat = ctfs.read_file("paths.dat").unwrap();
    let off = ctfs.read_file("paths.off").unwrap();

    let wanted = conventional_path().to_string_lossy().into_owned();
    let mut rewritten = 0;
    let mut new_dat = Vec::new();
    let mut new_off = Vec::new();
    new_off.extend_from_slice(&0u64.to_le_bytes());
    for record in split_records(&dat, &off) {
        let (path, _) = path_and_line_count(&record);
        if path == wanted {
            let mut pos = 0;
            let len = read_varint(&record, &mut pos) as usize;
            new_dat.extend_from_slice(&record[..pos + len]);
            new_dat.push(0);
            rewritten += 1;
        } else {
            new_dat.extend_from_slice(&record);
        }
        new_off.extend_from_slice(&(new_dat.len() as u64).to_le_bytes());
    }
    assert_eq!(
        rewritten, 1,
        "the conventional file's record was not found in paths.dat"
    );

    let members: Vec<(String, Vec<u8>)> = names
        .iter()
        .map(|name| {
            let bytes = match name.as_str() {
                "paths.dat" => new_dat.clone(),
                "paths.off" => new_off.clone(),
                other => ctfs.read_file(other).unwrap(),
            };
            (name.clone(), bytes)
        })
        .collect();
    let borrowed: Vec<(&str, &[u8])> = members.iter().map(|(n, b)| (n.as_str(), b.as_slice())).collect();
    let dir = tempfile::tempdir().unwrap();
    let out = dir.path().join("rewritten.ct");
    write_minimal_ctfs(&out, &borrowed).unwrap();
    std::fs::read(&out).unwrap()
}

/// The line count each `paths.dat` record states, by path.
fn stated_line_counts(container: &[u8]) -> Vec<(String, u64)> {
    let mut ctfs = CtfsReader::from_bytes(container.to_vec()).unwrap();
    let dat = ctfs.read_file("paths.dat").unwrap();
    let off = ctfs.read_file("paths.off").unwrap();
    split_records(&dat, &off)
        .iter()
        .map(|r| path_and_line_count(r))
        .collect()
}

/// Every served step on `path`, as `(line, column)`.
fn steps_on(reader: &CTFSTraceReader, path: &Path) -> Vec<(i64, Option<i64>)> {
    let wanted = path.to_string_lossy().into_owned();
    let db = reader.db();
    (0..reader.step_count())
        .filter_map(|i| reader.step(codetracer_trace_types::StepId(i as i64)))
        .filter(|step| db.paths.get(step.path_id).is_some_and(|p| p == &wanted))
        .map(|step| (step.line.0, step.column.map(|c| c.0)))
        .collect()
}

fn expected(written: &[(i64, i64)]) -> Vec<(i64, Option<i64>)> {
    written.iter().map(|&(line, column)| (line, Some(column))).collect()
}

/// The real file's expected steps: the entry step `writer.start` emits, then
/// the written ones.
fn expected_on_real() -> Vec<(i64, Option<i64>)> {
    std::iter::once((1, Some(1))).chain(expected(&REAL_STEPS)).collect()
}

fn assert_decodes_every_written_position(reader: &CTFSTraceReader, which: &str) {
    assert_eq!(
        steps_on(reader, &conventional_path()),
        expected(&CONVENTIONAL_STEPS),
        "{which}: the conventional file's own steps did not decode to the positions written on it",
    );
    assert_eq!(
        steps_on(reader, &real_path()),
        expected_on_real(),
        "{which}: the file interned AFTER the conventional one decoded to the wrong positions; \
         its base moved, which is what sizing the conventional file at zero does",
    );
}

#[test]
fn the_rewrite_changes_only_the_conventional_record() {
    let written = record();
    let rewritten = with_conventional_record_as_zero(&written);
    let conventional = conventional_path().to_string_lossy().into_owned();
    let real = real_path().to_string_lossy().into_owned();

    let before = stated_line_counts(&written);
    let after = stated_line_counts(&rewritten);
    assert_eq!(before.len(), after.len());
    for ((path_before, count_before), (path_after, count_after)) in before.iter().zip(&after) {
        assert_eq!(path_before, path_after);
        if *path_before == conventional {
            assert!(
                *count_before == CONVENTIONAL_LINES as u64 || *count_before == 0,
                "the writer stated {count_before} lines for the conventional file",
            );
            assert_eq!(*count_after, 0);
        } else {
            assert_eq!(count_before, count_after, "{path_before} changed");
        }
    }
    assert!(
        after
            .iter()
            .any(|(p, c)| *p == real && *c == REAL_LINE_LENGTHS.len() as u64)
    );
}

#[test]
fn control_the_container_as_written_decodes_every_position() {
    let reader = CTFSTraceReader::from_bytes(record()).unwrap_or_else(|e| panic!("from_bytes: {e}"));
    assert_decodes_every_written_position(&reader, "control (as written), browser reader");
}

#[test]
fn browser_reader_decodes_line_count_zero_as_the_conventional_table() {
    let container = with_conventional_record_as_zero(&record());
    let reader = CTFSTraceReader::from_bytes(container).unwrap_or_else(|e| panic!("from_bytes: {e}"));
    assert_decodes_every_written_position(&reader, "line_count 0, browser reader");
}

#[test]
fn native_reader_decodes_line_count_zero_as_the_conventional_table() {
    let container = with_conventional_record_as_zero(&record());
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("conventional.ct");
    std::fs::write(&path, container).unwrap();
    let reader = CTFSTraceReader::open(&path).unwrap_or_else(|e| panic!("open: {e}"));
    assert_decodes_every_written_position(&reader, "line_count 0, native reader");
}
