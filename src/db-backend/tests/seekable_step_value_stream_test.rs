//! M22 — db-backend SEEKABLE `steps.dat` + `values.dat` reader tests.
//!
//! These complete the M17b spec-violation fix. M17b made the CALL tree seekable;
//! M22 makes the per-step source LINE (`steps.dat`, M23a) and the per-step
//! VARIABLE VALUES (`values.dat`, M23b) seekable too, so a `has_step_stream` +
//! `has_value_stream` `.ct` never materializes the whole step/value stream to
//! serve a step lookup. The tests prove the spec properties from
//! `Trace-Files-Overview.md` §"Random-access seeking":
//!
//!  1. A step's line and a step's values are fetched by `step_id` from a
//!     `has_step_stream`/`has_value_stream` `.ct` through the seekable path
//!     WITHOUT materializing the whole trace — and the decompression is BOUNDED
//!     (only the needed chunk is inflated), proven by the chunk-decompression
//!     counters (exactly as M17b/M23a/M23b proved it for calls/steps/values).
//!  2. PARITY: the seekable values for step N EQUAL what the materialized path
//!     (`CTFSTraceReader::variables_at`) returns for the same step, and the
//!     seekable line equals the materialized `step(id).{path_id,line}` — so the
//!     debugger shows identical data.
//!  3. Multiple concurrent readers can read the same `.ct` independently.
//!  4. Backward compat: a legacy (flag-off) `.ct` exposes NO seekable stream and
//!     still reads through the existing fully-materialized path, unchanged.
//!
//! The fixtures are written in-test with the M23a/M23b writer
//! (`CtfsTraceWriter::with_step_stream(true).with_value_stream(true)` / a flag-off
//! twin), so the tests are self-contained and do not depend on an external bundle.

#![allow(clippy::expect_used, clippy::unwrap_used, clippy::panic)]

use std::path::{Path, PathBuf};
use std::sync::Arc;

use codetracer_trace_types::*;
use codetracer_trace_writer::ctfs_writer::CtfsTraceWriter;
use codetracer_trace_writer::trace_writer::TraceWriter;

use db_backend::ctfs_trace_reader::step_value_stream_source::{SeekableStepStream, SeekableValueStream};
use db_backend::ctfs_trace_reader::CTFSTraceReader;
use db_backend::trace_reader::TraceReader;

/// Compare two `FullValueRecord` lists by `(variable_id, value)` — `ValueRecord`
/// is `PartialEq` but `FullValueRecord` itself is not, so we project the fields.
fn records_eq(a: &[FullValueRecord], b: &[FullValueRecord]) -> bool {
    a.len() == b.len()
        && a.iter()
            .zip(b.iter())
            .all(|(x, y)| x.variable_id == y.variable_id && x.value == y.value)
}

/// Number of EXPLICIT user steps in the fixture (each with one variable).
const MY_STEPS: usize = 6;

/// Total steps the trace actually records. `register_call(main_fn)` emits an
/// implicit leading `Step` at `main`'s definition line (`Line(1)`) BEFORE the
/// call event (see `AbstractTraceWriter::register_call`), so the total is one
/// more than the explicit user steps. The leading step (index 0) carries NO
/// variable values; explicit user step `i` (0-based) lives at total index
/// `i + 1`.
const TOTAL_STEPS: usize = MY_STEPS + 1;

/// The total-stream index of explicit user step `i`.
fn user_step_index(i: usize) -> i64 {
    (i + 1) as i64
}

/// The single source path every step in the fixture lives in.
const SRC: &str = "/test/prog.rs";

/// Build the exact event sequence the fixture records. Used to drive BOTH the
/// seekable `.ct` writer AND the materialized `TraceProcessor` baseline, so the
/// parity test compares the two read paths over identical input.
///
/// User step `i` is at `Line(10 + i)` and carries one variable `var_i = i*100`,
/// emitted via a `Value` event — so the value-stream `StepValues` projection and
/// the materialized `db.variables[step]` are the same single-element list (the
/// implicit `<toplevel>` / `main` calls have NO args, so there is no call-arg
/// divergence between the two paths).
fn fixture_events() -> Vec<TraceLowLevelEvent> {
    let mut events: Vec<TraceLowLevelEvent> = Vec::new();
    // Interning: path, the None + Int types, the toplevel + main functions.
    events.push(TraceLowLevelEvent::Path(PathBuf::from(SRC)));
    events.push(TraceLowLevelEvent::Type(TypeRecord {
        kind: TypeKind::None,
        lang_type: "None".to_string(),
        specific_info: TypeSpecificInfo::None,
    }));
    events.push(TraceLowLevelEvent::Type(TypeRecord {
        kind: TypeKind::Int,
        lang_type: "Int".to_string(),
        specific_info: TypeSpecificInfo::None,
    }));
    let int_type = TypeId(1);
    events.push(TraceLowLevelEvent::Function(FunctionRecord {
        path_id: PathId(0),
        line: Line(1),
        name: "<toplevel>".to_string(),
    }));
    events.push(TraceLowLevelEvent::Call(CallRecord {
        function_id: FunctionId(0),
        args: vec![],
    }));
    events.push(TraceLowLevelEvent::Function(FunctionRecord {
        path_id: PathId(0),
        line: Line(1),
        name: "main".to_string(),
    }));
    // register_call(main) emits the implicit leading Step at main's line BEFORE
    // the Call event (mirrors AbstractTraceWriter::register_call).
    events.push(TraceLowLevelEvent::Step(StepRecord {
        path_id: PathId(0),
        line: Line(1),
    }));
    events.push(TraceLowLevelEvent::Call(CallRecord {
        function_id: FunctionId(1),
        args: vec![],
    }));

    for i in 0..MY_STEPS {
        events.push(TraceLowLevelEvent::Step(StepRecord {
            path_id: PathId(0),
            line: Line(10 + i as i64),
        }));
        events.push(TraceLowLevelEvent::VariableName(format!("var_{i}")));
        events.push(TraceLowLevelEvent::Value(FullValueRecord {
            variable_id: VariableId(i),
            value: ValueRecord::Int {
                i: (i * 100) as i64,
                type_id: int_type,
            },
        }));
    }

    events.push(TraceLowLevelEvent::Return(ReturnRecord {
        return_value: ValueRecord::None { type_id: TypeId(0) },
    }));
    events
}

/// Write the fixture trace to a `.ct`. With `with_streams` on, the writer emits
/// the seekable `steps.dat`/`values.dat` (chunk size 2 ⇒ the {TOTAL_STEPS}-record
/// streams span multiple chunks, so a single lookup must inflate only one
/// chunk). With it off, the legacy flag-off twin is written (no streams), used
/// for the backward-compatibility test.
fn write_trace(dir: &tempfile::TempDir, with_streams: bool) -> PathBuf {
    let path_buf = dir.path().join("trace");
    let mut writer = CtfsTraceWriter::new("test_program", &[])
        .with_step_stream(with_streams)
        .with_value_stream(with_streams)
        .with_steps_chunk_size(2)
        .with_values_chunk_size(2);
    TraceWriter::begin_writing_trace_events(&mut writer, &path_buf).unwrap();

    let mut events = fixture_events();
    TraceWriter::append_events(&mut writer, &mut events);

    TraceWriter::finish_writing_trace_events(&mut writer).unwrap();
    path_buf.with_extension("ct")
}

/// Deliverable test #1a (bounded step decompression): fetching ONE step's line
/// by id from a multi-chunk `steps.dat` decompresses ONLY that step's chunk —
/// not the whole stream. Proven by the `SeekableStepStream` chunk counter.
#[test]
fn fetch_step_line_decompresses_only_its_chunk() {
    let dir = tempfile::tempdir().unwrap();
    let ct = write_trace(&dir, true);

    let stream = SeekableStepStream::open(&ct)
        .expect("open seekable step stream")
        .expect("trace has has_step_stream flag set");

    assert_eq!(stream.step_count(), TOTAL_STEPS, "expected {TOTAL_STEPS} step records");
    assert_eq!(stream.chunk_size(), 2);
    assert_eq!(stream.chunk_decompressions(), 0, "no chunk inflated before the first read");

    // The LAST user step lives in the last chunk (total index 6 over chunk_size
    // 2 ⇒ chunk 3). A whole-trace materialization would touch every chunk; the
    // seekable path must inflate exactly ONE.
    let last = user_step_index(MY_STEPS - 1);
    let (path_id, line) = stream.step_line(StepId(last)).expect("last user step present");
    assert_eq!(line, Line(10 + (MY_STEPS - 1) as i64), "last user step line");
    assert_eq!(
        stream.chunk_decompressions(),
        1,
        "fetching one step inflated exactly one chunk, not the whole stream"
    );

    // Re-reading the same step (same chunk) must NOT inflate again.
    let _again = stream.step_line(StepId(last)).expect("re-read last user step");
    assert_eq!(stream.chunk_decompressions(), 1, "re-reading the cached chunk inflates nothing new");

    // The FIRST user step is in a different chunk (total index 1, chunk 0).
    let first = user_step_index(0);
    let (_p0, l0) = stream.step_line(StepId(first)).expect("first user step present");
    assert_eq!(l0, Line(10));
    assert_eq!(stream.chunk_decompressions(), 2, "touching a new chunk inflated exactly one more");

    // The path id is consistent (single source file).
    assert_eq!(path_id, _p0, "all steps share the single source path");

    // Out-of-range / negative ids yield None, never a panic, and inflate nothing.
    assert!(stream.step_line(StepId(99)).is_none());
    assert!(stream.step_line(StepId(-1)).is_none());
    assert_eq!(stream.chunk_decompressions(), 2, "rejected lookups inflate nothing");
}

/// Deliverable test #1b (bounded value decompression): fetching ONE step's
/// values by id from a multi-chunk `values.dat` decompresses ONLY that step's
/// chunk. Proven by the `SeekableValueStream` chunk counter.
#[test]
fn fetch_step_values_decompresses_only_its_chunk() {
    let dir = tempfile::tempdir().unwrap();
    let ct = write_trace(&dir, true);

    let stream = SeekableValueStream::open(&ct)
        .expect("open seekable value stream")
        .expect("trace has has_value_stream flag set");

    assert_eq!(stream.value_count(), TOTAL_STEPS, "value record N ↔ step N");
    assert_eq!(stream.chunk_size(), 2);
    assert_eq!(stream.chunk_decompressions(), 0);

    // The last user step's values live in the last chunk.
    let last = user_step_index(MY_STEPS - 1);
    let vals_last = stream.variables_at(StepId(last)).expect("last step values present");
    assert_eq!(vals_last.len(), 1, "last user step has one variable");
    match &vals_last[0].value {
        ValueRecord::Int { i, .. } => assert_eq!(*i, ((MY_STEPS - 1) * 100) as i64, "var_(n-1) = (n-1)*100"),
        other => panic!("expected Int, got {other:?}"),
    }
    assert_eq!(stream.chunk_decompressions(), 1, "one value lookup inflated exactly one chunk");

    let _again = stream.variables_at(StepId(last)).expect("re-read last step values");
    assert_eq!(stream.chunk_decompressions(), 1, "cached chunk inflates nothing new");

    let first = user_step_index(0);
    let vals_first = stream.variables_at(StepId(first)).expect("first step values present");
    assert_eq!(vals_first.len(), 1);
    match &vals_first[0].value {
        ValueRecord::Int { i, .. } => assert_eq!(*i, 0, "var_0 = 0"),
        other => panic!("expected Int, got {other:?}"),
    }
    assert_eq!(stream.chunk_decompressions(), 2, "a new chunk inflated exactly one more");

    // The leading implicit step (index 0) carries NO variable values.
    let vals_leading = stream.variables_at(StepId(0)).expect("leading step record present");
    assert!(vals_leading.is_empty(), "the implicit leading step has no variables");

    assert!(stream.variables_at(StepId(99)).is_none());
    assert!(stream.variables_at(StepId(-1)).is_none());
}

/// Deliverable test #2 (PARITY): the SEEKABLE per-step line and per-step values
/// EQUAL the MATERIALIZED `step()` / `variables_at()` for every step — so the
/// debugger shows identical data whichever path it uses.
///
/// The materialized baseline is built by postprocessing the SAME event sequence
/// the seekable `.ct` was written from (`CTFSTraceReader::from_events` runs the
/// production `TraceProcessor` over those events — no Nim reader, no `steps.dat`
/// new-format parse — so this is a genuine A/B over identical input). The
/// seekable side reads the `.ct`'s `steps.dat`/`values.dat` on demand.
#[test]
fn seekable_and_materialized_steps_values_agree() {
    let dir = tempfile::tempdir().unwrap();
    let ct = write_trace(&dir, true);

    // Seekable side: the on-demand streams over the written `.ct`.
    let step_stream = SeekableStepStream::open(&ct).unwrap().expect("step stream present");
    let value_stream = SeekableValueStream::open(&ct).unwrap().expect("value stream present");
    assert_eq!(step_stream.step_count(), TOTAL_STEPS);
    assert_eq!(value_stream.value_count(), TOTAL_STEPS);

    // Materialized baseline: postprocess the identical events into a Db-backed
    // reader (the production materialized read path) and wrap it in the trait.
    let materialized = CTFSTraceReader::from_events(fixture_events(), Path::new("/test")).expect("postprocess events");
    assert_eq!(materialized.step_count(), TOTAL_STEPS, "materialized step table agrees on count");

    for i in 0..TOTAL_STEPS as i64 {
        let step_id = StepId(i);

        // ── Step line parity ──────────────────────────────────────────
        let mat_step = materialized.step(step_id).expect("materialized step present");
        let (seek_path, seek_line) = step_stream.step_line(step_id).expect("seekable step line present");
        assert_eq!(seek_line, mat_step.line, "seekable line must equal materialized line for step {i}");
        assert_eq!(
            seek_path, mat_step.path_id,
            "seekable path_id must equal materialized path_id for step {i}"
        );

        // ── Step values parity ────────────────────────────────────────
        let mat_vals = materialized
            .variables_at(step_id)
            .expect("materialized variables present")
            .to_vec();
        let seek_vals = value_stream.variables_at(step_id).expect("seekable variables present");
        assert!(
            records_eq(&seek_vals, &mat_vals),
            "seekable values must equal materialized values for step {i}: \
             seekable={seek_vals:?} materialized={mat_vals:?}"
        );
    }

    // The trait's `variables_at_owned` convenience: a reader exposing the
    // seekable value stream serves owned values from it (the production DAP path
    // that `load_locals` / `load_value` now call). We verify it directly on a
    // `CTFSTraceReader::from_events` reader — which has NO seekable stream — so
    // it must fall back to the materialized table, equalling `variables_at`.
    for i in 0..TOTAL_STEPS as i64 {
        let owned = materialized.variables_at_owned(StepId(i)).expect("owned variables present");
        let mat_vals = materialized.variables_at(StepId(i)).map(|v| v.to_vec()).unwrap_or_default();
        assert!(records_eq(&owned, &mat_vals), "variables_at_owned fallback equals materialized for step {i}");
    }
}

/// Deliverable test #3 (concurrency): many threads read step lines and step
/// values from the SAME `.ct` over independent seekable sources without
/// contention or data races, and every read returns the expected value.
#[test]
fn concurrent_readers_over_same_ct() {
    let dir = tempfile::tempdir().unwrap();
    let ct = write_trace(&dir, true);

    let step_stream = Arc::new(SeekableStepStream::open(&ct).unwrap().unwrap());
    let value_stream = Arc::new(SeekableValueStream::open(&ct).unwrap().unwrap());

    let mut handles = Vec::new();
    for t in 0..8 {
        let ss = Arc::clone(&step_stream);
        let vs = Arc::clone(&value_stream);
        handles.push(std::thread::spawn(move || {
            for _ in 0..50 {
                for i in 0..MY_STEPS {
                    let idx = user_step_index(i);
                    let (_p, line) = ss.step_line(StepId(idx)).expect("step line");
                    assert_eq!(line, Line(10 + i as i64), "thread {t}: user step {i} line");
                    let vals = vs.variables_at(StepId(idx)).expect("step values");
                    assert_eq!(vals.len(), 1, "thread {t}: user step {i} has one var");
                    match &vals[0].value {
                        ValueRecord::Int { i: v, .. } => {
                            assert_eq!(*v, (i * 100) as i64, "thread {t}: user step {i} value")
                        }
                        other => panic!("expected Int, got {other:?}"),
                    }
                }
            }
        }));
    }
    for h in handles {
        h.join().expect("thread panicked");
    }
}

/// Deliverable test #4 (backward compat): a legacy (flag-off) `.ct` exposes NO
/// seekable step/value stream, so the reader falls back to the materialized
/// path exactly as before. `SeekableStepStream::open` / `SeekableValueStream::open`
/// return `Ok(None)`, and `CTFSTraceReader`'s seekable hooks return `None`.
#[test]
fn flag_off_trace_exposes_no_seekable_streams() {
    let dir = tempfile::tempdir().unwrap();
    let ct = write_trace(&dir, false);

    assert!(
        SeekableStepStream::open(&ct).expect("open ok").is_none(),
        "flag-off trace must expose no seekable step stream"
    );
    assert!(
        SeekableValueStream::open(&ct).expect("open ok").is_none(),
        "flag-off trace must expose no seekable value stream"
    );

    // Opened through the full reader (old-format path, since no steps.dat), the
    // seekable hooks are None and the materialized path still serves the trace.
    let reader = CTFSTraceReader::open(&ct).expect("open flag-off ct");
    assert_eq!(reader.seekable_step_count(), None);
    assert_eq!(reader.seekable_value_count(), None);
    assert_eq!(reader.seekable_step_line(StepId(0)), None);
    assert!(reader.seekable_variables_at(StepId(0)).is_none());
    assert_eq!(reader.step_count(), TOTAL_STEPS, "materialized path reads the legacy trace unchanged");

    // `variables_at_owned` falls back to the materialized table for legacy
    // traces. The first user step (total index 1) has its one variable.
    let owned = reader
        .variables_at_owned(StepId(user_step_index(0)))
        .expect("materialized fallback");
    assert_eq!(owned.len(), 1, "first user step has one variable from the materialized table");
}
