//! The Rust `CtfsTraceWriter`, with no opt-ins, writes the spec's multi-stream
//! split layout (calls/steps/values/events.dat + the interning tables) and
//! nothing else. These tests verify the db-backend serves such a bundle
//! correctly end-to-end.
//!
//! ## What the bundle contains, and which reader path serves it
//!
//! The trace-format spec lists the files of a materialized `.ct`
//! (`internal-files.md`, "A materialized trace `.ct` from runtime recorders")
//! and defines no combined `events.log` stream: `trace-events.md`'s
//! old-tag disposition table records the old `Event` variant as *moved to
//! `events.dat`*. The Rust writer therefore writes no `events.log`.
//!
//! With no `events.log` present, `CTFSTraceReader::open` recognises the bundle
//! as the split format (`is_new_format`: `steps.dat` present, `events.log`
//! absent) and serves it through the Nim FFI reader — the same path as a
//! Nim-written production bundle. That this works is itself asserted: the
//! execution streams the two writers produce are byte-compatible, so a Rust
//! split bundle yields its steps, calls and values through that reader. The
//! Rust-side SEEKABLE readers still attach for on-demand calls/steps/values.

#![cfg(feature = "nim-reader")]
#![allow(clippy::expect_used, clippy::unwrap_used, clippy::panic)]

use std::path::{Path, PathBuf};

use codetracer_trace_types::*;
use codetracer_trace_writer::ctfs_writer::CtfsTraceWriter;
use codetracer_trace_writer::trace_writer::TraceWriter;

use db_backend::ctfs_trace_reader::CTFSTraceReader;
use db_backend::ctfs_trace_reader::ctfs_container::CtfsReader;
use db_backend::trace_reader::TraceReader;

const SRC: &str = "/test/prog.rs";
/// Explicit user steps, each at `Line(10 + i)` with one local `vi = i*10`.
const USER_STEPS: usize = 4;

/// Write a representative trace with the DEFAULT `CtfsTraceWriter` (no opt-ins —
/// all five splits default-on as of M23e-4). Returns the `.ct` path.
fn write_default_bundle(dir: &Path) -> PathBuf {
    let path_buf = dir.join("trace");
    let mut writer = CtfsTraceWriter::new("test_program", &[]);
    TraceWriter::begin_writing_trace_events(&mut writer, &path_buf).unwrap();

    let src = Path::new(SRC);
    TraceWriter::start(&mut writer, src, Line(1));
    let int_type = TraceWriter::ensure_type_id(&mut writer, TypeKind::Int, "Int");
    let main_fn = TraceWriter::ensure_function_id(&mut writer, "main", src, Line(1));

    let arg = TraceWriter::arg(
        &mut writer,
        "x",
        ValueRecord::Int {
            i: 42,
            type_id: int_type,
        },
    );
    TraceWriter::register_call(&mut writer, main_fn, vec![arg]);

    for i in 0..USER_STEPS {
        TraceWriter::register_step(&mut writer, src, Line(10 + i as i64));
        TraceWriter::register_variable_with_full_value(
            &mut writer,
            &format!("v{i}"),
            ValueRecord::Int {
                i: (i * 10) as i64,
                type_id: int_type,
            },
        );
    }

    TraceWriter::register_special_event(&mut writer, EventLogKind::Write, "", "out\n");
    TraceWriter::register_return(&mut writer, ValueRecord::None { type_id: NONE_TYPE_ID });

    TraceWriter::finish_writing_trace_events(&mut writer).unwrap();
    path_buf.with_extension("ct")
}

fn locals_at(reader: &CTFSTraceReader, step_id: StepId) -> Vec<(String, i64)> {
    let Some(vars) = reader.variables_at(step_id) else {
        return Vec::new();
    };
    vars.iter()
        .map(|v| {
            let name = reader.variable_name(v.variable_id).unwrap_or("<unknown>").to_string();
            let i = match v.value {
                ValueRecord::Int { i, .. } => i,
                ref other => panic!("expected Int local, got {other:?}"),
            };
            (name, i)
        })
        .collect()
}

fn step_index_for_line(reader: &CTFSTraceReader, line: i64) -> Option<StepId> {
    (0..reader.step_count() as i64)
        .map(StepId)
        .find(|&sid| reader.step(sid).map(|s| s.line == Line(line)).unwrap_or(false))
}

/// The default bundle carries every split stream the spec lists, and no
/// `events.log` — a stream the spec does not define (see the header).
#[test]
fn default_bundle_carries_the_split_streams_and_no_events_log() {
    let dir = tempfile::tempdir().unwrap();
    let ct = write_default_bundle(dir.path());

    let mut ctfs = CtfsReader::open(&ct).expect("open container");
    for f in [
        "calls.dat",
        "steps.dat",
        "values.dat",
        "events.dat",
        "paths.dat",
        "meta.dat",
    ] {
        assert!(ctfs.read_file(f).is_ok(), "default bundle must carry split file `{f}`");
    }
    assert!(
        ctfs.read_file("events.log").is_err(),
        "the default bundle must not carry `events.log`: the spec defines no such stream"
    );
}

/// The db-backend serves the DEFAULT Rust-writer bundle correctly end-to-end:
/// steps, calls, and per-step variable values all surface through the
/// `TraceReader` trait, through the split-format reader path (see the header).
#[test]
fn default_bundle_is_served_correctly_end_to_end() {
    let dir = tempfile::tempdir().unwrap();
    let ct = write_default_bundle(dir.path());

    let reader = CTFSTraceReader::open(&ct).expect("open default Rust-writer bundle");

    // Steps: the explicit user steps are present.
    assert!(reader.step_count() >= USER_STEPS, "expected >= {USER_STEPS} steps");

    // Calls: the wrapping `main` call is present (call_key 0 is the implicit
    // `<toplevel>` from `start()`; `main` is a child). Locate it by name.
    assert!(reader.call_count() >= 2, "expected >= 2 calls (toplevel + main)");
    let main_present = (0..reader.call_count() as i64).map(CallKey).any(|k| {
        reader
            .call(k)
            .and_then(|c| reader.function(c.function_id))
            .map(|f| f.name == "main")
            .unwrap_or(false)
    });
    assert!(main_present, "the wrapping `main` call must be served");

    // Values: each user step's inline full value surfaces via variables_at.
    for i in 0..USER_STEPS {
        let line = 10 + i as i64;
        let sid = step_index_for_line(&reader, line).unwrap_or_else(|| panic!("no step at line {line}"));
        assert_eq!(
            locals_at(&reader, sid),
            vec![(format!("v{i}"), (i * 10) as i64)],
            "step at line {line} must serve v{i} = {}",
            i * 10
        );
    }
}

/// The Rust-side SEEKABLE call stream still attaches for the default bundle —
/// the on-demand `calls.dat` reader (written by and matched to the Rust crate)
/// serves the call tree, and agrees with the materialized tree.
#[test]
fn default_bundle_seekable_call_stream_attaches_and_agrees() {
    let dir = tempfile::tempdir().unwrap();
    let ct = write_default_bundle(dir.path());

    let reader = CTFSTraceReader::open(&ct).expect("open default bundle");

    let n = reader
        .seekable_call_count()
        .expect("default bundle exposes a seekable calls.dat stream");
    assert_eq!(n, reader.call_count(), "seekable and materialized call counts agree");

    for i in 0..n {
        let key = CallKey(i as i64);
        let seek = reader.seekable_call(key).expect("seekable call");
        let materialized = reader.call(key).expect("materialized call").clone();
        assert_eq!(seek.key, materialized.key, "call {i}: key");
        assert_eq!(seek.function_id, materialized.function_id, "call {i}: function_id");
        assert_eq!(seek.parent_key, materialized.parent_key, "call {i}: parent_key");
        assert_eq!(seek.depth, materialized.depth, "call {i}: depth");
    }
}
