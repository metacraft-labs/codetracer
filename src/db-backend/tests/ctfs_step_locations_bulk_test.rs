//! Bulk step-locations FFI correctness + microbenchmark.
//!
//! Mission goal #1 (perf) — see `/tmp/isonim-migration.txt` §5.2(o)
//! / §1.97 for context.  The CTFS new-format `Db` population loop in
//! `ctfs_trace_reader::open_new_format_nim` used to call
//! `NimTraceReaderHandle::step_location` once per step, which:
//!
//!   1. issues a Rust→Nim FFI hop per step (~5 ms in the current
//!      build), and
//!   2. re-scans from the exec-stream chunk boundary on every call
//!      because `readEvent` decodes from position 0 each time.
//!
//! The bulk variant `step_locations(start, count, ...)` exposed by the
//! Nim-side `ct_reader_step_locations` FFI streams whole chunks at a
//! time and pays a single FFI hop per chunked call.  This test
//! exercises both paths on a synthetic 2400-step trace (matching the
//! python_sudoku_solver fixture cited in §5.2(o)) and asserts:
//!
//!   * exact equivalence between per-step and bulk results;
//!   * a meaningful speedup on the bulk path (target: ≥ 5× faster).
//!
//! The microbenchmark is light enough to live inside the regular
//! `cargo test` suite; the wall-time numbers are printed for triage.

#![cfg(feature = "nim-reader")]

use codetracer_trace_types::{Line, TypeId, TypeKind, ValueRecord};
use codetracer_trace_writer_nim::{
    trace_writer::TraceWriter, NimTraceReaderHandle, NimTraceWriter, TraceEventsFileFormat,
};
use std::path::Path;
use std::time::Instant;

/// Number of steps for the synthetic fixture.  Picked to roughly
/// match the python_sudoku_solver trace cited in the migration
/// handoff (~2400 steps).
const SYNTHETIC_STEP_COUNT: u64 = 2400;

/// Build a `.ct` container with a single function call wrapping
/// `SYNTHETIC_STEP_COUNT` register_step events.  No call args, no
/// per-step variables — we are profiling step-location resolution
/// only.  Returns the absolute path to the produced `.ct` file.
fn build_synthetic_trace(workdir: &Path, name: &str) -> std::path::PathBuf {
    let trace_path = workdir.join(name);
    let ct_path = workdir.join(format!("{name}.ct"));

    let mut writer = NimTraceWriter::new(name, TraceEventsFileFormat::Ctfs);
    writer.set_workdir(workdir);
    writer.begin_writing_trace_metadata(&trace_path).unwrap();
    writer.finish_writing_trace_metadata().unwrap();
    writer.begin_writing_trace_events(&trace_path).unwrap();
    writer.begin_writing_trace_paths(&trace_path).unwrap();
    writer.finish_writing_trace_paths().unwrap();

    let path = Path::new("/tmp/synthetic.py");
    let fid = writer.ensure_function_id("loop", path, Line(1));
    writer.register_function("loop", path, Line(1));

    writer.start(path, Line(1));
    writer.register_step(path, Line(1));

    // Wrap the run in one call so the Db has a single non-empty
    // CallRange — the steps loop in open_new_format_nim still has
    // step_to_call_key / step_to_global_call_key to populate.
    let _ty = writer.ensure_type_id(TypeKind::Int, "int");
    TraceWriter::register_call(&mut writer, fid, vec![]);

    // Linearly increasing line numbers force every step after the
    // chunk boundary to be a DeltaStep(+1), matching the realistic
    // single-file synthetic trace shape.
    for i in 1u64..SYNTHETIC_STEP_COUNT {
        writer.register_step(path, Line((1 + i) as i64));
    }
    writer.register_return(ValueRecord::None { type_id: TypeId(0) });

    writer.finish_writing_trace_events().unwrap();
    writer.close().unwrap();

    assert!(
        ct_path.exists(),
        ".ct container should have been produced at {}",
        ct_path.display()
    );
    ct_path
}

/// Drain step locations one at a time via the legacy FFI, returning
/// the resulting (path_id, line) sequence and the wall-clock time
/// spent inside the FFI calls.
fn drain_per_step(reader: &NimTraceReaderHandle, count: u64) -> (Vec<(u64, u64)>, std::time::Duration) {
    let start = Instant::now();
    let mut out = Vec::with_capacity(count as usize);
    for i in 0..count {
        let (pid, line) = reader.step_location(i).unwrap();
        out.push((pid, line));
    }
    (out, start.elapsed())
}

/// Drain step locations through the bulk FFI in `chunk`-sized batches.
fn drain_bulk(reader: &NimTraceReaderHandle, count: u64, chunk: u64) -> (Vec<(u64, u64)>, std::time::Duration) {
    let start = Instant::now();
    let mut path_ids = vec![0u64; chunk as usize];
    let mut lines = vec![0u64; chunk as usize];
    let mut out = Vec::with_capacity(count as usize);
    let mut step = 0u64;
    while step < count {
        let want = std::cmp::min(chunk, count - step);
        let written = reader
            .step_locations(step, want, &mut path_ids[..want as usize], &mut lines[..want as usize])
            .unwrap();
        assert!(
            written > 0,
            "bulk FFI returned 0 entries at step {step} — trace truncated?"
        );
        for offset in 0..written {
            out.push((path_ids[offset as usize], lines[offset as usize]));
        }
        step += written;
    }
    (out, start.elapsed())
}

#[test]
fn bulk_step_locations_matches_per_step() {
    let dir = tempfile::tempdir().unwrap();
    let ct_path = build_synthetic_trace(dir.path(), "step_locations_bulk");

    let reader = NimTraceReaderHandle::open(ct_path.to_str().unwrap()).expect("open trace");
    let step_count = reader.step_count();
    // The trace writer emits one initial step from `start()` plus one
    // per `register_step` call, so the produced trace has roughly
    // `SYNTHETIC_STEP_COUNT` steps.  Use the reader's reported count
    // as the source of truth to avoid coupling the assertion to the
    // exact write-side bookkeeping.
    assert!(
        (SYNTHETIC_STEP_COUNT - 1..=SYNTHETIC_STEP_COUNT + 4).contains(&step_count),
        "synthetic trace should have ~{} steps (got {})",
        SYNTHETIC_STEP_COUNT,
        step_count
    );

    // Per-step path establishes the ground truth.
    let (per_step, per_step_elapsed) = drain_per_step(&reader, step_count);

    // Bulk path with the same chunk size used by the db-backend hot
    // loop — keeps the benchmark numbers representative of production.
    let (bulk, bulk_elapsed) = drain_bulk(&reader, step_count, 1024);

    assert_eq!(per_step.len(), bulk.len());
    for (i, (a, b)) in per_step.iter().zip(bulk.iter()).enumerate() {
        assert_eq!(a, b, "step {i}: per-step {:?} != bulk {:?}", a, b);
    }

    // Diagnostics — the test prints the wall times so a curious
    // operator can correlate with the §1.69 numbers in the handoff.
    let speedup = per_step_elapsed.as_secs_f64() / bulk_elapsed.as_secs_f64().max(1e-9);
    println!(
        "[bulk_step_locations_matches_per_step] steps={} per_step={:.2?} bulk={:.2?} speedup={:.1}x",
        step_count, per_step_elapsed, bulk_elapsed, speedup
    );

    // Sanity: the bulk path must beat the per-step path by a
    // comfortable margin.  Without the bulk variant the §5.2(o)
    // ct host startup latency on python_sudoku_solver was ~40 s; the
    // §1.97 fix targets ≥ 5× on this microbenchmark.  The assertion
    // is intentionally conservative (3×) to absorb the noise of CI
    // shared runners while still flagging an accidental regression
    // back to the per-step path.
    assert!(
        speedup >= 3.0,
        "bulk path should be ≥ 3× faster than per-step (got {:.1}x: \
         per_step={:?}, bulk={:?})",
        speedup,
        per_step_elapsed,
        bulk_elapsed
    );
}

/// The bulk FFI must clamp `count` to the remaining step count and
/// report the truncated value back to the caller — the db-backend
/// loop relies on this to advance `step_idx` correctly.
#[test]
fn bulk_step_locations_truncates_to_total() {
    let dir = tempfile::tempdir().unwrap();
    let ct_path = build_synthetic_trace(dir.path(), "step_locations_truncate");

    let reader = NimTraceReaderHandle::open(ct_path.to_str().unwrap()).expect("open trace");
    let step_count = reader.step_count();

    // Request more than available — written must clamp to the tail.
    let mut path_ids = vec![0u64; (step_count + 16) as usize];
    let mut lines = vec![0u64; (step_count + 16) as usize];
    let written = reader
        .step_locations(step_count - 8, step_count + 16, &mut path_ids, &mut lines)
        .unwrap();
    assert_eq!(written, 8, "expected 8 entries written, got {written}");

    // start past total events → 0 entries written, no error.
    let mut p = [0u64; 1];
    let mut l = [0u64; 1];
    let oob = reader.step_locations(step_count + 100, 1, &mut p, &mut l).unwrap();
    assert_eq!(oob, 0);
}
