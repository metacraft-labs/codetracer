//! F2 (streaming-correctness) — the seekable + live-refresh `steps.dat` /
//! `values.dat` / `calls.dat` sources must open and serve records for a
//! STILL-RECORDING trace, i.e. a container whose stream files are present but
//! whose `meta.dat` is NOT yet written (the Nim `MultiStreamTraceWriter` writes
//! `meta.dat` only at close).
//!
//! Per the trace-format spec amendment "stream presence is structural, not
//! flag-gated" (`codetracer-trace-format-spec/internal-files.md` +
//! `ctfs-container.md` §6), existence must be decided by the STRUCTURAL PRESENCE
//! of `<stream>.dat`, never by `meta.dat` (its presence, or its hint bits).
//! Previously each `open_from_ctfs` / live-refresh helper read `meta.dat` as a
//! precondition and returned `Ok(None)` when it was absent — so a mid-run trace
//! was unreadable.
//!
//! This test builds a real fixture with all three streams, then REBUILDS the
//! container WITHOUT `meta.dat` (the mid-run image) and asserts the seekable and
//! live-refresh sources still open and serve records BYTE-IDENTICAL to the
//! baseline container that still has `meta.dat`.
//!
//! No mocks: the fixture is a real `CtfsTraceWriter` bundle; the mid-run image
//! is the same bundle's files re-packed through the real CTFS container writer.

#![allow(clippy::expect_used, clippy::unwrap_used, clippy::panic)]

use std::path::{Path, PathBuf};

use codetracer_trace_types::*;
use codetracer_trace_writer::ctfs_writer::CtfsTraceWriter;
use codetracer_trace_writer::trace_writer::TraceWriter;

use db_backend::ctfs_trace_reader::call_stream_source::SeekableCallStream;
use db_backend::ctfs_trace_reader::ctfs_container::{self, CtfsReader};
use db_backend::ctfs_trace_reader::step_value_stream_source::{SeekableStepStream, SeekableValueStream};

/// Write a fixture that exercises all three seekable streams (calls + steps +
/// values), with small chunk sizes so each stream spans multiple chunks.
fn write_trace(dir: &tempfile::TempDir) -> PathBuf {
    let path_buf = dir.path().join("trace");
    let mut writer = CtfsTraceWriter::new("test_program", &[])
        .with_call_stream(true)
        .with_calls_chunk_size(2)
        .with_step_stream(true)
        .with_steps_chunk_size(2)
        .with_value_stream(true)
        .with_values_chunk_size(2);
    TraceWriter::begin_writing_trace_events(&mut writer, &path_buf).unwrap();

    let src = Path::new("/test/prog.rs");
    TraceWriter::start(&mut writer, src, Line(1));

    let int_type = TraceWriter::ensure_type_id(&mut writer, TypeKind::Int, "Int");
    let main_fn = TraceWriter::ensure_function_id(&mut writer, "main", src, Line(1));
    let used_a = TraceWriter::ensure_function_id(&mut writer, "used_a", src, Line(10));

    // main()
    TraceWriter::register_call(&mut writer, main_fn, vec![]);
    TraceWriter::register_step(&mut writer, src, Line(2));
    TraceWriter::register_variable_with_full_value(
        &mut writer,
        "counter",
        ValueRecord::Int {
            i: 42,
            type_id: int_type,
        },
    );

    // used_a(x=5) -> 1
    let arg_a = TraceWriter::arg(
        &mut writer,
        "x",
        ValueRecord::Int {
            i: 5,
            type_id: int_type,
        },
    );
    TraceWriter::register_call(&mut writer, used_a, vec![arg_a]);
    TraceWriter::register_step(&mut writer, src, Line(11));
    TraceWriter::register_variable_with_full_value(
        &mut writer,
        "y",
        ValueRecord::Int {
            i: 7,
            type_id: int_type,
        },
    );
    TraceWriter::register_return(
        &mut writer,
        ValueRecord::Int {
            i: 1,
            type_id: int_type,
        },
    );

    // main returns
    TraceWriter::register_return(&mut writer, ValueRecord::None { type_id: NONE_TYPE_ID });

    TraceWriter::finish_writing_trace_events(&mut writer).unwrap();
    path_buf.with_extension("ct")
}

/// Re-pack every file of `src_ct` into a new CTFS container at `dst_ct`, OMITTING
/// `meta.dat` — the on-disk shape of a still-recording trace whose meta has not
/// been flushed yet. Returns the set of file names carried over (for the sanity
/// assertions).
fn repack_without_meta_dat(src_ct: &Path, dst_ct: &Path) -> Vec<String> {
    let mut reader = CtfsReader::open(src_ct).expect("open source .ct");
    // `file_names` borrows the reader immutably; collect owned names first so we
    // can then read each file (which needs `&mut`).
    let names: Vec<String> = reader.file_names().into_iter().map(str::to_string).collect();

    let mut carried: Vec<String> = Vec::new();
    let mut owned: Vec<(String, Vec<u8>)> = Vec::new();
    for name in names {
        if name == "meta.dat" {
            continue;
        }
        let bytes = reader.read_file(&name).expect("read source file");
        carried.push(name.clone());
        owned.push((name, bytes));
    }

    let files: Vec<(&str, &[u8])> = owned.iter().map(|(n, b)| (n.as_str(), b.as_slice())).collect();
    ctfs_container::write_minimal_ctfs(dst_ct, &files).expect("write mid-run container");
    carried
}

/// The core F2 assertion: a mid-run container (stream files present, NO
/// `meta.dat`) opens the seekable step/value/call sources AND the live-refresh
/// sources, and serves records byte-identical to the baseline container that
/// still carries `meta.dat`.
#[test]
fn mid_run_container_without_meta_dat_serves_all_streams() {
    let dir = tempfile::tempdir().unwrap();
    let ct = write_trace(&dir);
    let ct_nometa = dir.path().join("midrun.ct");
    let carried = repack_without_meta_dat(&ct, &ct_nometa);

    // Sanity: the mid-run image really lacks meta.dat but keeps every stream.
    {
        let mut r = CtfsReader::open(&ct_nometa).expect("open mid-run .ct");
        assert!(
            r.read_file("meta.dat").is_err(),
            "the mid-run fixture must NOT carry meta.dat"
        );
        for f in [
            "steps.dat",
            "steps.idx",
            "values.dat",
            "values.idx",
            "calls.dat",
            "calls.idx",
        ] {
            assert!(r.read_file(f).is_ok(), "mid-run fixture must carry {f}");
        }
    }
    assert!(
        carried.iter().any(|n| n == "steps.dat"),
        "the source trace must have produced the stream files"
    );

    // ── Baseline (WITH meta.dat) vs candidate (mid-run, NO meta.dat) ──────────
    let mut base = CtfsReader::open(&ct).expect("open baseline .ct");
    let mut cand = CtfsReader::open(&ct_nometa).expect("open mid-run .ct");

    // Step stream: opens without meta.dat, and every step line matches baseline.
    let base_steps = SeekableStepStream::open_from_ctfs(&mut base)
        .expect("baseline step open ok")
        .expect("baseline has a step stream");
    let cand_steps = SeekableStepStream::open_from_ctfs(&mut cand)
        .expect("mid-run step open ok")
        .expect("mid-run step stream must open with NO meta.dat present");
    assert!(cand_steps.step_count() > 0, "mid-run step stream serves records");
    assert_eq!(
        cand_steps.step_count(),
        base_steps.step_count(),
        "mid-run step count equals baseline"
    );
    for i in 0..base_steps.step_count() as i64 {
        assert_eq!(
            cand_steps.step_line(StepId(i)),
            base_steps.step_line(StepId(i)),
            "mid-run step line {i} equals baseline"
        );
    }

    // Value stream: opens without meta.dat, and every step's values match.
    let base_values = SeekableValueStream::open_from_ctfs(&mut base)
        .expect("baseline value open ok")
        .expect("baseline has a value stream");
    let cand_values = SeekableValueStream::open_from_ctfs(&mut cand)
        .expect("mid-run value open ok")
        .expect("mid-run value stream must open with NO meta.dat present");
    assert_eq!(
        cand_values.value_count(),
        base_values.value_count(),
        "mid-run value count equals baseline"
    );
    // Prove at least one step actually carries a recorded variable.
    let mut saw_a_variable = false;
    for i in 0..base_values.value_count() as i64 {
        let b = base_values.variables_at(StepId(i)).expect("baseline values");
        let c = cand_values.variables_at(StepId(i)).expect("mid-run values");
        assert_eq!(c.len(), b.len(), "mid-run value count at step {i} equals baseline");
        for (x, y) in c.iter().zip(b.iter()) {
            assert_eq!(x.variable_id, y.variable_id, "value var id at step {i}");
            assert_eq!(x.value, y.value, "value at step {i}");
        }
        if !c.is_empty() {
            saw_a_variable = true;
        }
    }
    assert!(saw_a_variable, "the fixture recorded at least one variable value");

    // Call stream: opens without meta.dat, and every call matches baseline.
    let base_calls = SeekableCallStream::open_from_ctfs(&mut base)
        .expect("baseline call open ok")
        .expect("baseline has a call stream");
    let cand_calls = SeekableCallStream::open_from_ctfs(&mut cand)
        .expect("mid-run call open ok")
        .expect("mid-run call stream must open with NO meta.dat present");
    assert!(cand_calls.call_count() > 0, "mid-run call stream serves records");
    assert_eq!(
        cand_calls.call_count(),
        base_calls.call_count(),
        "mid-run call count equals baseline"
    );
    for k in 0..base_calls.call_count() as i64 {
        let b = base_calls.call(CallKey(k)).expect("baseline call");
        let c = cand_calls.call(CallKey(k)).expect("mid-run call");
        assert_eq!(c.key, b.key, "call {k} key");
        assert_eq!(c.function_id, b.function_id, "call {k} function_id");
        assert_eq!(c.parent_key, b.parent_key, "call {k} parent_key");
        assert_eq!(c.depth, b.depth, "call {k} depth");
        assert_eq!(c.step_id, b.step_id, "call {k} step_id");
        assert_eq!(c.children_keys, b.children_keys, "call {k} children");
    }
}

/// The LIVE refresh path (`refresh_from_ctfs`, which drives the private
/// `open_step_reader_from_ctfs` / `open_value_reader_from_ctfs` /
/// `open_call_reader_from_ctfs` helpers) must also work with NO `meta.dat`:
/// refreshing a stream from a mid-run container keeps it serving records rather
/// than silently becoming empty.
#[test]
fn live_refresh_without_meta_dat_keeps_streams_populated() {
    let dir = tempfile::tempdir().unwrap();
    let ct = write_trace(&dir);
    let ct_nometa = dir.path().join("midrun.ct");
    repack_without_meta_dat(&ct, &ct_nometa);

    // Open the sources from the mid-run image, capture their counts, then refresh
    // them from a freshly-opened mid-run reader (the live-follow motion) and
    // assert the counts and records survive — a broken meta gate would zero them.
    let mut opener = CtfsReader::open(&ct_nometa).expect("open mid-run .ct");
    let steps = SeekableStepStream::open_from_ctfs(&mut opener).unwrap().unwrap();
    let values = SeekableValueStream::open_from_ctfs(&mut opener).unwrap().unwrap();
    let calls = SeekableCallStream::open_from_ctfs(&mut opener).unwrap().unwrap();

    let step_count = steps.step_count();
    let value_count = values.value_count();
    let call_count = calls.call_count();
    assert!(step_count > 0 && value_count > 0 && call_count > 0);

    let mut refresher = CtfsReader::open(&ct_nometa).expect("re-open mid-run .ct");
    steps.refresh_from_ctfs(&mut refresher).expect("live step refresh");
    values.refresh_from_ctfs(&mut refresher).expect("live value refresh");
    calls.refresh_from_ctfs(&mut refresher).expect("live call refresh");

    assert_eq!(steps.step_count(), step_count, "step count survives live refresh");
    assert_eq!(values.value_count(), value_count, "value count survives live refresh");
    assert_eq!(calls.call_count(), call_count, "call count survives live refresh");

    // And the refreshed sources still serve real records.
    assert!(
        steps.step_line(StepId(0)).is_some(),
        "refreshed step stream serves records"
    );
    assert!(calls.call(CallKey(0)).is_some(), "refreshed call stream serves records");
}
