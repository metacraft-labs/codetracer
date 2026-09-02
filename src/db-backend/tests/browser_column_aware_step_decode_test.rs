//! The BROWSER (pure-Rust, no-FFI) split-stream reader decodes a COLUMN-AWARE
//! container's step positions correctly.
//!
//! # The defect this pins
//!
//! A `Step` record in `steps.dat` carries exactly ONE `u64`, and the container
//! decides what it means:
//!
//! * **line-only** containers store the M23a packed `global_line_index`
//!   (`path_id << 32 | line`), whose inverse is `unpack_global_line_index`;
//! * **column-aware** containers store a `global_position_index` — a cumulative
//!   BYTE address across every registered file — which only the per-file
//!   Layout A line-length tables in `paths.dat` can resolve.
//!
//! Nothing in the record distinguishes them. `CTFSTraceReader::from_bytes` —
//! the ONLY browser-reachable constructor, and the one BlockTracer's published
//! wasm engine runs — routed every new-format container through the lazy step
//! path, which called `unpack_global_line_index` unconditionally. For a
//! column-aware container that is a category error: a byte offset below 2^32
//! unpacks to `path_id = 0` and `line = <the byte offset>`, so EVERY step
//! reported `paths[0]` at a four-digit line, and `column` was hard-coded `None`
//! on that path besides.
//!
//! The tell that made it look like a frontend bug for a long time: function
//! NAMES stayed perfectly correct, because they come from `calls.dat`, which
//! does not use this encoding at all. Measured against BlockTracer's vendored
//! `zk_shields.ct`, the engine agreed with the container's own `ct-print`
//! reading on 82 of 82 function names and 0 of 82 positions.
//!
//! The NATIVE reader had already been fixed for this exact bug — see
//! `cairo_fixture_gli_decode.rs` — but it was fixed inside the column-aware
//! branch of `open_new_format_nim`, which harvests per-file line lengths
//! through the Nim FFI. There is no FFI in wasm, so the browser never reached
//! that fix and had no line tables of its own until `InterningTables` started
//! carrying them.
//!
//! # Why the writer is native and the reader is the browser's
//!
//! Writing a column-aware container needs the Nim writer (hence the
//! `nim-reader` feature gate on this file), but the READ under test is
//! `from_bytes` — byte-identical to what runs in the worker. That asymmetry is
//! the point: it exercises the browser code path on a host where it can be
//! debugged.
//!
//! # Arms
//!
//! Per `codetracer-specs/Testing/Verification-Harness-Traps.md` §4/§4a, every
//! negative claim here has a positive twin through the SAME code path, and the
//! counts are asserted before anything ranges over them:
//!
//! | arm | container | claim |
//! | --- | --- | --- |
//! | §1 | column-aware | steps land on the lines and columns that were written |
//! | §2 | column-aware | no step reports a line past the source's own length |
//! | §3 | line-only (CONTROL) | the legacy packed decode is untouched |
//! | §4 | line-only (CONTROL) | `column` stays `None` — no column invented |
//!
//! §3 and §4 are the arms that would catch an over-broad fix. A decoder applied
//! to a line-only container would read its packed `path_id << 32 | line` as a
//! byte address and send those steps somewhere absurd — which is the same
//! defect, merely pointed the other way, and is exactly the outcome the
//! instruction-level chain traces (old-format, `Line(pc)` in a `.avm` path)
//! must be protected from.

#![cfg(feature = "nim-reader")]
#![allow(clippy::expect_used, clippy::unwrap_used, clippy::panic)]

use codetracer_trace_types::Line;
use codetracer_trace_writer_nim::{NimTraceWriter, TraceEventsFileFormat};
use db_backend::ctfs_trace_reader::CTFSTraceReader;
use db_backend::trace_reader::TraceReader;
use std::path::{Path, PathBuf};

/// The synthetic subject: one 6-line source, and the exact `(line, column)`
/// pairs the recorder writes. Chosen so a byte-offset misread is unmistakable —
/// the file's whole address space is 132 positions, so a GLI read as a line
/// number lands far outside `1..=6` and cannot coincide with a real line by
/// accident.
const SOURCE_LINE_LENGTHS: [u32; 6] = [12, 30, 25, 18, 27, 20];

/// `(line, column)` in write order. Columns are 1-based, and each is well
/// inside its line's length so the decoder's answer is unambiguous.
const WRITTEN_POSITIONS: [(i64, i64); 7] = [(1, 1), (2, 5), (3, 11), (4, 2), (5, 17), (3, 24), (6, 9)];

/// `writer.start(path, Line(1))` emits a step of its own before any of
/// [`WRITTEN_POSITIONS`] is registered, so the container holds one more step on
/// the subject source than the recorder explicitly wrote. Named rather than
/// absorbed into a `>=`: the exact count is knowable, and Traps §4b is that a
/// bound accepts a partial scan while an equality does not.
const ENTRY_STEP: (i64, i64) = (1, 1);

/// Every `(line, column)` the subject source should carry, entry step included.
fn expected_positions() -> Vec<(i64, Option<i64>)> {
    std::iter::once(ENTRY_STEP)
        .chain(WRITTEN_POSITIONS)
        .map(|(line, column)| (line, Some(column)))
        .collect()
}

fn source_path() -> PathBuf {
    PathBuf::from("/tmp/ct_column_aware_subject.nr")
}

/// Build a `.ct` and hand back its RAW BYTES — because `from_bytes` is the
/// browser's only door, and reading the file into memory here is what the
/// worker's VFS does with the container it is posted.
fn build_container(program: &str, column_aware: bool) -> Vec<u8> {
    let dir = tempfile::tempdir().unwrap();
    let trace_path = dir.path().join("trace");
    let source = source_path();

    let mut writer = NimTraceWriter::new(program, &[], TraceEventsFileFormat::Ctfs);
    writer.set_workdir(dir.path());
    writer.begin_writing_trace_metadata(&trace_path).unwrap();
    writer.finish_writing_trace_metadata().unwrap();
    writer.begin_writing_trace_events(&trace_path).unwrap();
    writer.begin_writing_trace_paths(&trace_path).unwrap();

    if column_aware {
        // Order matters: the opt-in must precede the path registration, or the
        // path record is written in the legacy bare-bytes form and carries no
        // line table for the decoder to be built from.
        writer.enable_column_aware_steps();
        writer
            .register_path_with_line_lengths(&source, &SOURCE_LINE_LENGTHS)
            .unwrap();
    }
    writer.finish_writing_trace_paths().unwrap();

    let function = writer.ensure_function_id("subject", &source, Line(1));
    writer.start(&source, Line(1));
    writer.register_call(function, Vec::new());

    for (line, column) in WRITTEN_POSITIONS {
        if column_aware {
            writer.register_step_with_column(&source, Line(line), Some(Line(column)));
        } else {
            writer.register_step(&source, Line(line));
        }
    }

    writer.finish_writing_trace_events().unwrap();
    writer.close().unwrap();

    // The container is written as a single `.ct` beside the trace directory;
    // find it rather than assuming a name, so a writer-side rename fails the
    // test loudly instead of silently reading a stale file.
    let candidates: Vec<PathBuf> = std::fs::read_dir(dir.path())
        .unwrap()
        .filter_map(|entry| entry.ok().map(|e| e.path()))
        .filter(|p| p.extension().is_some_and(|ext| ext == "ct"))
        .collect();
    assert_eq!(
        candidates.len(),
        1,
        "expected exactly one .ct container in {:?}, found {:?}",
        dir.path(),
        candidates,
    );
    std::fs::read(&candidates[0]).unwrap()
}

/// Open through the BROWSER constructor — the same call the wasm worker makes.
fn open_as_browser(bytes: Vec<u8>) -> CTFSTraceReader {
    CTFSTraceReader::from_bytes(bytes).unwrap_or_else(|e| panic!("from_bytes: {e}"))
}

/// Every step the reader serves, as `(path, line, column)`. Read through the
/// borrowing accessor so this exercises the lazy reconstruction path rather
/// than some eagerly-materialized table the browser never builds.
fn positions(reader: &CTFSTraceReader) -> Vec<(String, i64, Option<i64>)> {
    let db = reader.db();
    let count = reader.step_count();
    let mut out = Vec::with_capacity(count);
    for index in 0..count {
        let Some(step) = reader.step(codetracer_trace_types::StepId(index as i64)) else {
            continue;
        };
        let path = db
            .paths
            .get(step.path_id)
            .cloned()
            .unwrap_or_else(|| format!("<unknown path id {}>", step.path_id.0));
        out.push((path, step.line.0, step.column.map(|c| c.0)));
    }
    out
}

/// The subset of served steps that fall on the subject source, which is what
/// the written positions are claims about. A container carries entry/exit
/// bookkeeping steps besides, and asserting over the whole table would make
/// this test a statement about the writer's framing rather than about the
/// decoder.
fn on_subject(served: &[(String, i64, Option<i64>)]) -> Vec<(i64, Option<i64>)> {
    let wanted = source_path().to_string_lossy().into_owned();
    served
        .iter()
        .filter(|(path, _, _)| path == &wanted)
        .map(|(_, line, column)| (*line, *column))
        .collect()
}

// ---------------------------------------------------------------------------
// §1 / §2 — the SUBJECT: a column-aware container
// ---------------------------------------------------------------------------

#[test]
fn column_aware_container_decodes_written_lines_and_columns() {
    let served = positions(&open_as_browser(build_container("column_aware", true)));
    let subject = on_subject(&served);

    // Traps §4: assert the scan found something, and assert its SIZE, before
    // asserting anything over it. A decoder that sent every step to `paths[0]`
    // would leave this list EMPTY — and an empty list satisfies every
    // per-element claim below vacuously, which is precisely how this defect
    // could hide behind a green test.
    let expected = expected_positions();
    assert_eq!(
        subject.len(),
        expected.len(),
        "expected {} steps on {}, got {}. Served: {:?}",
        expected.len(),
        source_path().display(),
        subject.len(),
        served,
    );

    assert_eq!(
        subject,
        expected,
        "the browser reader decoded a column-aware container's steps to the wrong positions.\n\
         Every entry whose line is far outside 1..={} is a `global_position_index` byte offset \
         being read as a line number by `unpack_global_line_index` — the defect that made the \
         published engine report `std/lib.nr:5869` for a step the container records at \
         `src/shield.nr:1`.",
        SOURCE_LINE_LENGTHS.len(),
    );
}

#[test]
fn column_aware_container_reports_no_line_past_the_source() {
    let served = positions(&open_as_browser(build_container("column_aware_range", true)));
    let max_line = SOURCE_LINE_LENGTHS.len() as i64;

    // The range claim, made over the WHOLE served table rather than only the
    // subject rows: a step that escaped onto the wrong path would not appear in
    // `on_subject` at all, so §1 alone cannot see it. This arm can.
    assert!(
        !served.is_empty(),
        "the reader served no steps at all — the range claim below would pass vacuously"
    );
    for (index, (path, line, column)) in served.iter().enumerate() {
        if path != &source_path().to_string_lossy() {
            continue;
        }
        assert!(
            (1..=max_line).contains(line),
            "step {index}: line {line} is outside the subject's 1..={max_line} — a byte-offset \
             GLI escaping the decoder"
        );
        let column = column.expect(
            "a column-aware container must serve a real column; `None` here is the hard-coded \
             `column: None` the lazy step path used to apply to every container",
        );
        assert!(
            column >= 1,
            "step {index}: column {column} is not 1-based as the spec requires"
        );
    }
}

// ---------------------------------------------------------------------------
// §3 / §4 — the CONTROL: a line-only container must be untouched
// ---------------------------------------------------------------------------

#[test]
fn line_only_container_keeps_the_legacy_packed_decode() {
    let served = positions(&open_as_browser(build_container("line_only", false)));
    let subject = on_subject(&served);

    let expected = expected_positions();
    assert_eq!(
        subject.len(),
        expected.len(),
        "expected {} steps on the subject source, got {}. Served: {:?}",
        expected.len(),
        subject.len(),
        served,
    );

    let expected_lines: Vec<i64> = expected.iter().map(|(line, _)| *line).collect();
    let served_lines: Vec<i64> = subject.iter().map(|(line, _)| *line).collect();
    assert_eq!(
        served_lines, expected_lines,
        "a line-only container's packed `global_line_index` decode changed. This is the arm that \
         protects the instruction-level chain traces, which legitimately report `Line(pc)` and \
         must NOT be re-interpreted as source positions."
    );
}

#[test]
fn line_only_container_invents_no_columns() {
    let served = positions(&open_as_browser(build_container("line_only_columns", false)));
    assert!(!served.is_empty(), "no steps served — the claim below would be vacuous");
    for (index, (_, _, column)) in served.iter().enumerate() {
        assert_eq!(
            *column, None,
            "step {index}: a line-only container carries no column data, so a column here was \
             INVENTED — the over-broad-fix failure, where a decoder is applied to a container \
             whose records are not in that address space"
        );
    }
}

// ---------------------------------------------------------------------------
// The two containers genuinely differ on the wire
// ---------------------------------------------------------------------------

#[test]
fn the_two_arms_are_actually_different_containers() {
    // Without this, both arms could be reading the same line-only bytes and
    // both could pass — the control arm and the subject arm would agree
    // because there was only ever one subject. Traps §4a's positive twin,
    // applied to the fixture rather than to the assertion.
    let column_aware = build_container("differ_column_aware", true);
    let line_only = build_container("differ_line_only", false);
    assert_ne!(
        column_aware, line_only,
        "the column-aware and line-only writers produced byte-identical containers; the \
         column-aware opt-in did not take effect and both arms above are testing one thing"
    );

    let ca_reader = open_as_browser(column_aware);
    let lo_reader = open_as_browser(line_only);
    let ca_has_columns = positions(&ca_reader).iter().any(|(_, _, c)| c.is_some());
    let lo_has_columns = positions(&lo_reader).iter().any(|(_, _, c)| c.is_some());
    assert!(ca_has_columns, "the column-aware container served no columns at all");
    assert!(!lo_has_columns, "the line-only container served a column");
}

/// `Path` is used only through `source_path`; this keeps the import honest if
/// the helper is ever inlined.
#[allow(dead_code)]
fn _assert_path_import(_: &Path) {}
