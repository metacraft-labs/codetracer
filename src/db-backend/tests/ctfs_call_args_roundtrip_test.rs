//! Integration test for call argument round-trip through the CTFS
//! multi-stream pipeline.
//!
//! This test asserts that arguments staged via
//! `NimTraceWriter::register_call_arg` (or implicitly via
//! `NimTraceWriter::arg`) survive a write/read round-trip through the
//! Nim multi-stream backend and reach `Db.calls[i].args` populated
//! with the correct `(varname_id, ValueRecord)` pairs.
//!
//! Without this round-trip the frontend's `[PIPELINE] syncCalltraceData`
//! log line reports `0 arg entries` and the calltrace pane renders
//! every call as `f()` instead of `f(arg=value)` — see
//! TODO 5.2(n) in `/tmp/isonim-migration.txt`.

#![cfg(feature = "nim-reader")]

use codetracer_trace_types::{Line, TypeId, TypeKind, ValueRecord};
use codetracer_trace_writer_nim::{NimTraceWriter, TraceEventsFileFormat, trace_writer::TraceWriter};
use db_backend::ctfs_trace_reader::CTFSTraceReader;
use db_backend::trace_reader::TraceReader;
use std::path::Path;

/// Drive the Nim multi-stream writer through a minimal sequence that
/// produces a `.ct` container with one call carrying a single integer
/// argument, then load it back via `CTFSTraceReader` and assert that
/// the arg lands on the resulting `DbCall.args` vec.
#[test]
fn test_ctfs_call_args_roundtrip() {
    let dir = tempfile::tempdir().unwrap();
    let trace_path = dir.path().join("call_args_roundtrip");
    // The Nim writer derives the .ct filename from the program-name
    // splitFile baseName ("call_args_test"), placing it in the events
    // path's parent directory.
    let ct_path = dir.path().join("call_args_test.ct");

    // ── Write side ─────────────────────────────────────────────────
    {
        let mut writer = NimTraceWriter::new("call_args_test", &[], TraceEventsFileFormat::Ctfs);

        // The Nim multi-stream backend is selected by the file name's
        // .ct extension.  set_workdir + begin_writing_trace_metadata is
        // the same lifecycle the recorders go through.
        writer.set_workdir(dir.path());
        writer
            .begin_writing_trace_metadata(&trace_path)
            .expect("begin_writing_trace_metadata");
        writer.finish_writing_trace_metadata().unwrap();
        writer
            .begin_writing_trace_events(&trace_path)
            .expect("begin_writing_trace_events");
        writer
            .begin_writing_trace_paths(&trace_path)
            .expect("begin_writing_trace_paths");
        writer.finish_writing_trace_paths().unwrap();

        // Ensure a function id for `add` (the call we'll record).
        let path = Path::new("/tmp/test.py");
        let fid = writer.ensure_function_id("add", path, Line(1));
        writer.register_function("add", path, Line(1));

        // Initial entry step at line 1.
        writer.start(path, Line(1));
        writer.register_step(path, Line(1));

        // Stage the call's argument via `arg()`.  This both registers
        // the variable on the current step (so `ct/load-locals` finds
        // it) AND stages it on the writer's pending-args buffer so the
        // next `register_call` attaches it to the call record.
        let int_type = writer.ensure_type_id(TypeKind::Int, "int");
        let arg_value = ValueRecord::Int {
            i: 42,
            type_id: int_type,
        };
        let arg = TraceWriter::arg(&mut writer, "x", arg_value);

        // Emit the actual call event.  The pending-args buffer is
        // consumed and attached to the call record.
        TraceWriter::register_call(&mut writer, fid, vec![arg]);
        writer.register_step(path, Line(2));
        writer.register_return(ValueRecord::None { type_id: TypeId(0) });

        writer.finish_writing_trace_events().unwrap();
        writer.close().unwrap();
    }

    // ── Read side ──────────────────────────────────────────────────
    assert!(ct_path.exists(), ".ct file should be produced at {}", ct_path.display());

    let reader = CTFSTraceReader::open(&ct_path).expect("CTFSTraceReader::open");

    // We need at least one call, and that call must carry one arg.
    assert!(reader.call_count() >= 1, "expected at least 1 call record");

    let mut found_args = false;
    for k in 0..reader.call_count() {
        let key = codetracer_trace_types::CallKey(k as i64);
        if let Some(db_call) = reader.call(key) {
            if !db_call.args.is_empty() {
                found_args = true;
                // Verify the value round-tripped correctly.
                match db_call.args[0].value {
                    ValueRecord::Int { i, .. } => {
                        assert_eq!(i, 42, "expected the staged `x=42` arg to survive round-trip");
                    }
                    ref other => panic!("expected Int arg, got {:?}", other),
                }
                break;
            }
        }
    }

    assert!(
        found_args,
        "expected at least one call to carry args, but all {} calls had empty args -- \
         the writer→reader pipeline is dropping call arguments somewhere",
        reader.call_count()
    );
}
