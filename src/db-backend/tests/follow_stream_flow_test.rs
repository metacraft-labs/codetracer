//! M1 — follow-mode split-stream reader over a *growing* `.ct`.
//!
//! These tests drive the REAL-PRODUCT db-backend follow path
//! (`FollowFileSource` + `FollowStepStreamSource`, reading the SAME `steps.dat`
//! / `steps.idx` split streams the seekable final-file reader uses) against a
//! container that a writer is still appending to — the write-during-read case
//! the `Seek-Based-CTFS-Reader.md` §5.6 design unifies onto one reader. They
//! replace the legacy `events.log`-tailing `StreamingCtfsReader` test as the
//! live/streaming coverage: streaming tests now exercise the split-stream decode
//! pipeline that ships, not a parallel reader.
//!
//! The fixture is produced by an in-test INCREMENTAL CTFS streaming writer
//! ([`stream_writer::IncrementalCtfsStreamWriter`]) that mirrors the production
//! Nim streaming protocol: it writes Block 0 first, then flushes `steps.dat` /
//! `steps.idx` ONE CHUNK AT A TIME — growing each file's `FileEntry.Size` in
//! Block 0 as the chunk lands — and commits `meta.dat` (the finalization signal)
//! LAST. The step records themselves are encoded with the PRODUCTION
//! `encode_step_stream` encoder, so the bytes the follow reader decodes are the
//! exact wire format a real recorder emits.

#![allow(clippy::expect_used, clippy::unwrap_used, clippy::panic)]

use codetracer_trace_types::{CallKey, FunctionId, Line, PathId, StepId, TypeId, ValueRecord};

use codetracer_trace_writer::call_stream::CallStreamRecord;

use db_backend::ctfs_trace_reader::CTFSTraceReader;
use db_backend::ctfs_trace_reader::follow_stream_source::{
    FollowCallStreamSource, FollowReader, FollowStepStreamSource, FollowValueStreamSource,
};
use db_backend::trace_reader::TraceReader;

mod stream_writer;
use stream_writer::IncrementalCtfsStreamWriter;

/// The single source path id every fixture step lives in.
const PATH_ID: usize = 3;

/// Build the fixture's expected `(path_id, line)` sequence: `total` steps at
/// lines `100, 101, 102, …`. Used to drive BOTH the writer and the assertions.
fn expected_steps(total: usize) -> Vec<(PathId, Line)> {
    (0..total).map(|i| (PathId(PATH_ID), Line(100 + i as i64))).collect()
}

/// M1 — a growing split-stream `.ct` is live-tailed through the db-backend
/// follow reader and yields split-stream STEPS BEFORE finalization, and the
/// COMPLETE set after.
///
/// Strong assertions, both directions:
///  - While the recording is still in progress (meta NOT committed), once two
///    or more chunks have been flushed the follow reader, on `refresh()`, must
///    surface the EARLY (bounded) chunks' steps — proving it observes appended
///    blocks via the grown `FileEntry.Size`, NOT a whole-file load at open. The
///    follow protocol mirrors the writer's "index-offset-before-chunk-data"
///    rule (CTFS-Binary-Format.md §7): the LAST indexed chunk is deferred until
///    a successor offset bounds it or the trace is finalized, so the count of
///    decodable chunks trails the count of flushed chunks by one mid-recording.
///  - The reader must NOT be finalized while chunks are still landing.
///  - Once every chunk plus `meta.dat` is committed, the reader must be
///    finalized AND surface EVERY step, byte-exact in `(path_id, line)`.
#[test]
fn e2e_streaming_reader_real_product() {
    let dir = tempfile::tempdir().unwrap();
    let ct_path = dir.path().join("growing.ct");

    // 5 chunks × 4 steps = 20 steps, small chunk size so growth is observable
    // chunk-by-chunk.
    const CHUNK_SIZE: usize = 4;
    const NUM_CHUNKS: usize = 5;
    let total = CHUNK_SIZE * NUM_CHUNKS;
    let steps = expected_steps(total);

    // Writer: lay down Block 0 + the empty (size-0) steps.dat/steps.idx/meta.dat
    // file entries, so the follow reader can open the container before any chunk
    // exists — exactly as a live recorder creates the directory up front.
    let mut writer = IncrementalCtfsStreamWriter::create(&ct_path, CHUNK_SIZE).unwrap();

    // Open the follow reader against the still-empty (but valid) container.
    let mut reader = FollowStepStreamSource::open(&ct_path).unwrap();
    assert_eq!(reader.step_count(), 0, "no chunks flushed yet ⇒ no steps visible");
    assert!(!reader.is_finalized(), "meta.dat not committed ⇒ not finalized");

    // ── Flush the FIRST chunk. It is the last indexed chunk, so it is deferred
    //    until a successor offset bounds it; a refresh now sees nothing yet.
    writer.flush_chunk(&steps[0..CHUNK_SIZE]).unwrap();
    assert_eq!(
        reader.step_count(),
        0,
        "follow reader must not surface appended steps until refresh()"
    );
    let new = reader.refresh().unwrap();
    assert_eq!(new, 0, "the sole flushed chunk is the trailing chunk ⇒ deferred");
    assert!(!reader.is_finalized());

    // ── Flush the remaining chunks one at a time. Each new chunk's index offset
    //    bounds the PREVIOUS chunk, which then becomes decodable — so the reader
    //    surfaces steps BEFORE finalization.
    for c in 1..NUM_CHUNKS {
        let lo = c * CHUNK_SIZE;
        let hi = lo + CHUNK_SIZE;
        writer.flush_chunk(&steps[lo..hi]).unwrap();
        let new = reader.refresh().unwrap();
        assert_eq!(
            new,
            CHUNK_SIZE,
            "chunk {c}: flushing it bounds chunk {} which becomes decodable",
            c - 1
        );
        // Decodable steps = all chunks except the still-trailing last one.
        assert_eq!(reader.step_count(), c * CHUNK_SIZE);
        assert!(!reader.is_finalized(), "chunk {c}: not finalized until meta.dat lands");
        // The newly-visible early steps must be byte-exact.
        let visible = c * CHUNK_SIZE;
        for (i, (pid, line)) in steps[..visible].iter().enumerate() {
            let got = reader.step(i).expect("early step visible before finalization");
            assert_eq!(got.path_id, *pid, "early step {i} path_id");
            assert_eq!(got.line, *line, "early step {i} line");
        }
    }

    // Mid-recording, the trailing chunk is still deferred: we have seen all but
    // the last chunk, all BEFORE finalization.
    assert_eq!(reader.step_count(), (NUM_CHUNKS - 1) * CHUNK_SIZE);
    assert!(!reader.is_finalized());

    // ── Finalize: commit meta.dat. The reader must now report finalized and,
    //    after a final refresh, drain the trailing chunk and surface ALL steps.
    writer.finalize().unwrap();
    reader.refresh().unwrap();
    assert!(reader.is_finalized(), "meta.dat committed ⇒ reader finalized");
    assert_eq!(reader.step_count(), total, "must see ALL steps after finalization");
    for (i, (pid, line)) in steps.iter().enumerate() {
        let got = reader
            .step(i)
            .unwrap_or_else(|| panic!("step {i} missing after finalization"));
        assert_eq!(got.path_id, *pid, "step {i} path_id mismatch");
        assert_eq!(got.line, *line, "step {i} line mismatch");
    }
}

/// M1 — finalization that arrives WITHOUT a trailing-chunk-bounding offset.
///
/// On an in-progress recording the LAST indexed chunk's end is unbounded (no
/// successor offset yet), so the follow reader defers decoding it. This test
/// proves that when the writer finalizes (commits `meta.dat`) WITHOUT first
/// flushing another chunk, a final `refresh()` still drains that trailing chunk
/// — because finalization makes the last chunk's end equal the committed
/// `steps.dat` size.
#[test]
fn e2e_streaming_reader_drains_trailing_chunk_on_finalize() {
    let dir = tempfile::tempdir().unwrap();
    let ct_path = dir.path().join("trailing.ct");

    const CHUNK_SIZE: usize = 3;
    let steps = expected_steps(2 * CHUNK_SIZE);
    let mut writer = IncrementalCtfsStreamWriter::create(&ct_path, CHUNK_SIZE).unwrap();
    let mut reader = FollowStepStreamSource::open(&ct_path).unwrap();

    // Flush both chunks. After refresh, only the FIRST chunk is decodable: the
    // second (last indexed) chunk is unbounded until finalization.
    writer.flush_chunk(&steps[0..CHUNK_SIZE]).unwrap();
    writer.flush_chunk(&steps[CHUNK_SIZE..2 * CHUNK_SIZE]).unwrap();
    reader.refresh().unwrap();
    assert_eq!(
        reader.step_count(),
        CHUNK_SIZE,
        "trailing (last indexed) chunk is deferred until bounded or finalized"
    );

    // Finalize WITHOUT flushing another chunk; the final refresh must drain the
    // trailing chunk.
    writer.finalize().unwrap();
    reader.refresh().unwrap();
    assert!(reader.is_finalized());
    assert_eq!(
        reader.step_count(),
        2 * CHUNK_SIZE,
        "trailing chunk drained on finalize"
    );
}

/// Build a `values.dat` per-step value record carrying a single `Int(name=i)`
/// variable, for the value-stream growth fixtures.
fn value_record_for(step: usize) -> codetracer_trace_writer::value_stream::ValueRecordEntry {
    // name_id = step, value = Int(step * 10) — distinct per step so the
    // reconstruction can be asserted byte-exact.
    let cbor = cbor4ii::serde::to_vec(
        Vec::new(),
        &ValueRecord::Int {
            i: (step as i64) * 10,
            type_id: TypeId(0),
        },
    )
    .unwrap();
    IncrementalCtfsStreamWriter::step_values_record(vec![(step as u64, cbor)])
}

/// Build a `calls.dat` record for `call_key`, parented at the root, with a
/// distinct function id so the decoded structure can be asserted.
fn call_record_for(call_key: u64) -> CallStreamRecord {
    CallStreamRecord {
        call_key,
        function_id: 100 + call_key,
        parent_key: -1,
        first_step_id: call_key * 2,
        last_step_id: call_key * 2 + 1,
        depth: 0,
        args: Vec::new(),
        return_value: Vec::new(),
        raised_exception: Vec::new(),
        children: Vec::new(),
    }
}

/// M1b — the VALUE follow source observes `values.dat` records appended after
/// open, and ONLY after a `refresh()`.
///
/// Mirrors the step growth test: while the recording is in progress, flushing a
/// new value chunk bounds the PREVIOUS chunk, which then becomes decodable on the
/// next `refresh()`. Before `refresh()`, no appended records are visible. After
/// finalization the trailing chunk drains and every step's reconstructed values
/// are byte-exact.
#[test]
fn test_followvaluesource_observes_growth() {
    let dir = tempfile::tempdir().unwrap();
    let ct_path = dir.path().join("values.ct");

    const CHUNK_SIZE: usize = 3;
    const NUM_CHUNKS: usize = 4;
    let total = CHUNK_SIZE * NUM_CHUNKS;

    let mut writer = IncrementalCtfsStreamWriter::create(&ct_path, CHUNK_SIZE).unwrap();
    let mut reader = FollowValueStreamSource::open(&ct_path).unwrap();
    assert_eq!(reader.value_count(), 0, "no chunks flushed ⇒ no value records visible");
    assert!(!reader.is_finalized());

    let all: Vec<_> = (0..total).map(value_record_for).collect();

    // First chunk: the trailing (last indexed) chunk, deferred until bounded.
    writer.flush_value_chunk(&all[0..CHUNK_SIZE]).unwrap();
    assert_eq!(
        reader.value_count(),
        0,
        "appended value records must NOT be visible before refresh()"
    );
    let new = reader.refresh().unwrap();
    assert_eq!(new, 0, "the sole flushed value chunk is the trailing chunk ⇒ deferred");

    // Subsequent chunks: each bounds the previous chunk, which becomes decodable.
    for c in 1..NUM_CHUNKS {
        let lo = c * CHUNK_SIZE;
        writer.flush_value_chunk(&all[lo..lo + CHUNK_SIZE]).unwrap();
        let new = reader.refresh().unwrap();
        assert_eq!(new, CHUNK_SIZE, "value chunk {c}: flushing it bounds chunk {}", c - 1);
        assert_eq!(reader.value_count(), c * CHUNK_SIZE);
        assert!(!reader.is_finalized());
        // The newly-visible early records reconstruct byte-exact.
        for step in 0..(c * CHUNK_SIZE) {
            let vars = reader.variables_at(step).expect("early value record visible");
            assert_eq!(vars.len(), 1, "step {step} has one variable");
            assert_eq!(vars[0].variable_id.0, step, "step {step} variable id");
            assert!(matches!(vars[0].value, ValueRecord::Int { i, .. } if i == (step as i64) * 10));
        }
    }

    // Finalize and drain the trailing chunk.
    writer.finalize_all_streams().unwrap();
    reader.refresh().unwrap();
    assert!(reader.is_finalized());
    assert_eq!(
        reader.value_count(),
        total,
        "all value records visible after finalization"
    );
    for step in 0..total {
        let vars = reader.variables_at(step).unwrap();
        assert_eq!(vars[0].variable_id.0, step);
        assert!(matches!(vars[0].value, ValueRecord::Int { i, .. } if i == (step as i64) * 10));
    }
}

/// M1b — the CALL follow source observes `calls.dat` records appended after
/// open, and ONLY after a `refresh()`. The decoded `DbCall`'s structural fields
/// (key, function id, parent) are byte-exact, and the `call_key` is correctly
/// reconstructed from the chunk position.
#[test]
fn test_followcallsource_observes_growth() {
    let dir = tempfile::tempdir().unwrap();
    let ct_path = dir.path().join("calls.ct");

    const CHUNK_SIZE: usize = 2;
    const NUM_CHUNKS: usize = 4;
    let total = (CHUNK_SIZE * NUM_CHUNKS) as u64;

    let mut writer = IncrementalCtfsStreamWriter::create(&ct_path, CHUNK_SIZE).unwrap();
    let mut reader = FollowCallStreamSource::open(&ct_path).unwrap();
    assert_eq!(reader.call_count(), 0, "no chunks flushed ⇒ no call records visible");

    let all: Vec<_> = (0..total).map(call_record_for).collect();

    // First chunk: trailing, deferred.
    writer.flush_call_chunk(&all[0..CHUNK_SIZE]).unwrap();
    assert_eq!(
        reader.call_count(),
        0,
        "appended calls must NOT be visible before refresh()"
    );
    let new = reader.refresh().unwrap();
    assert_eq!(new, 0, "the sole flushed call chunk is the trailing chunk ⇒ deferred");

    for c in 1..NUM_CHUNKS {
        let lo = c * CHUNK_SIZE;
        writer.flush_call_chunk(&all[lo..lo + CHUNK_SIZE]).unwrap();
        let new = reader.refresh().unwrap();
        assert_eq!(new, CHUNK_SIZE, "call chunk {c}: flushing it bounds chunk {}", c - 1);
        assert_eq!(reader.call_count(), c * CHUNK_SIZE);
        assert!(!reader.is_finalized());
        // Verify each visible call's key + structural fields.
        for key in 0..(c * CHUNK_SIZE) {
            let call = reader.call(key).expect("early call visible before finalization");
            assert_eq!(call.key, CallKey(key as i64), "call {key} key");
            assert_eq!(call.function_id, FunctionId(100 + key), "call {key} function id");
            assert_eq!(call.parent_key, CallKey(-1), "call {key} root parent");
            assert_eq!(call.step_id, StepId((key as i64) * 2), "call {key} entry step");
        }
    }

    writer.finalize_all_streams().unwrap();
    reader.refresh().unwrap();
    assert!(reader.is_finalized());
    assert_eq!(
        reader.call_count() as u64,
        total,
        "all calls visible after finalization"
    );
    for key in 0..(total as usize) {
        let call = reader.call(key).unwrap();
        assert_eq!(call.key, CallKey(key as i64));
        assert_eq!(call.function_id, FunctionId(100 + key));
    }
}

/// M1b — a growing split-stream `.ct` is live-tailed across STEPS + VALUES +
/// CALLS through the UNIFIED follow reader ([`FollowReader`]), yielding each
/// stream's records BEFORE finalization and the COMPLETE byte-exact set after.
///
/// This is the §5.6 unified follow path the design calls for: one reader over a
/// `FollowFileSource` driving the same Rust seekable decode the final-file path
/// uses, for every split stream the Rust reader owns. The three streams are
/// flushed interleaved (steps, then values, then calls) chunk-by-chunk, and a
/// single `FollowReader::refresh()` picks them all up.
#[test]
fn e2e_streaming_reader_real_product_all_streams() {
    let dir = tempfile::tempdir().unwrap();
    let ct_path = dir.path().join("all-streams.ct");

    const CHUNK_SIZE: usize = 3;
    const NUM_CHUNKS: usize = 4;
    let total = CHUNK_SIZE * NUM_CHUNKS;
    let steps = expected_steps(total);
    let values: Vec<_> = (0..total).map(value_record_for).collect();
    let calls: Vec<_> = (0..total as u64).map(call_record_for).collect();

    let mut writer = IncrementalCtfsStreamWriter::create(&ct_path, CHUNK_SIZE).unwrap();
    let mut reader = FollowReader::open(&ct_path).unwrap();
    assert_eq!(reader.steps().step_count(), 0);
    assert_eq!(reader.values().value_count(), 0);
    assert_eq!(reader.calls().call_count(), 0);
    assert!(!reader.is_finalized());

    // Flush chunk 0 of every stream. All three are trailing chunks ⇒ deferred.
    writer.flush_chunk(&steps[0..CHUNK_SIZE]).unwrap();
    writer.flush_value_chunk(&values[0..CHUNK_SIZE]).unwrap();
    writer.flush_call_chunk(&calls[0..CHUNK_SIZE]).unwrap();
    let (s, v, c) = reader.refresh().unwrap();
    assert_eq!((s, v, c), (0, 0, 0), "all stream chunk-0s are trailing ⇒ deferred");

    // Flush the remaining chunks; each bounds the previous chunk of its stream.
    for chunk in 1..NUM_CHUNKS {
        let lo = chunk * CHUNK_SIZE;
        let hi = lo + CHUNK_SIZE;
        writer.flush_chunk(&steps[lo..hi]).unwrap();
        writer.flush_value_chunk(&values[lo..hi]).unwrap();
        writer.flush_call_chunk(&calls[lo..hi]).unwrap();
        let (s, v, c) = reader.refresh().unwrap();
        assert_eq!(
            (s, v, c),
            (CHUNK_SIZE, CHUNK_SIZE, CHUNK_SIZE),
            "chunk {chunk}: each stream advances"
        );
        assert!(!reader.is_finalized());
        let visible = chunk * CHUNK_SIZE;
        assert_eq!(reader.steps().step_count(), visible);
        assert_eq!(reader.values().value_count(), visible);
        assert_eq!(reader.calls().call_count(), visible);
        // Cross-stream byte-exact spot check at the latest visible step.
        let last = visible - 1;
        let step = reader.steps().step(last).expect("step visible");
        assert_eq!(step.line, Line(100 + last as i64));
        let vars = reader.values().variables_at(last).expect("values visible");
        assert!(matches!(vars[0].value, ValueRecord::Int { i, .. } if i == (last as i64) * 10));
        let call = reader.calls().call(last).expect("call visible");
        assert_eq!(call.function_id, FunctionId(100 + last));
    }

    // Mid-recording: every stream has surfaced all but its trailing chunk.
    assert_eq!(reader.steps().step_count(), (NUM_CHUNKS - 1) * CHUNK_SIZE);
    assert_eq!(reader.values().value_count(), (NUM_CHUNKS - 1) * CHUNK_SIZE);
    assert_eq!(reader.calls().call_count(), (NUM_CHUNKS - 1) * CHUNK_SIZE);

    // Finalize: all three trailing chunks drain and every record is visible.
    writer.finalize_all_streams().unwrap();
    reader.refresh().unwrap();
    assert!(reader.is_finalized());
    assert_eq!(reader.steps().step_count(), total, "all steps after finalization");
    assert_eq!(reader.values().value_count(), total, "all values after finalization");
    assert_eq!(reader.calls().call_count(), total, "all calls after finalization");

    for i in 0..total {
        let step = reader.steps().step(i).unwrap();
        assert_eq!(step.path_id, PathId(PATH_ID));
        assert_eq!(step.line, Line(100 + i as i64));
        let vars = reader.values().variables_at(i).unwrap();
        assert_eq!(vars[0].variable_id.0, i);
        assert!(matches!(vars[0].value, ValueRecord::Int { i: n, .. } if n == (i as i64) * 10));
        let call = reader.calls().call(i).unwrap();
        assert_eq!(call.key, CallKey(i as i64));
        assert_eq!(call.function_id, FunctionId(100 + i));
    }
}

/// M8 — the production `CTFSTraceReader::open_follow` path observes appended
/// split-stream chunks in place after `refresh()`.
///
/// This is deliberately NOT the parallel `FollowReader` path above. The reader
/// goes through the shipped new-format open path (`open_new_format_nim`), keeps
/// the Nim FFI handle alive for refresh, and serves steps/values/calls through
/// the M22/M24c Rust seekable caches opened from the same follow-backed CTFS
/// source. Appended chunks are invisible before refresh and visible after it.
#[test]
fn e2e_production_ctfs_reader_follow_refreshes_seekable_caches() {
    let dir = tempfile::tempdir().unwrap();
    let ct_path = dir.path().join("production-follow.ct");

    const CHUNK_SIZE: usize = 2;
    let steps = expected_steps(CHUNK_SIZE * 2);
    let values: Vec<_> = (0..CHUNK_SIZE * 2).map(value_record_for).collect();
    let calls: Vec<_> = (0..(CHUNK_SIZE * 2) as u64).map(call_record_for).collect();

    let mut writer = IncrementalCtfsStreamWriter::create(&ct_path, CHUNK_SIZE).unwrap();
    writer.flush_chunk(&steps[0..CHUNK_SIZE]).unwrap();
    writer.flush_value_chunk(&values[0..CHUNK_SIZE]).unwrap();
    writer.flush_call_chunk(&calls[0..CHUNK_SIZE]).unwrap();
    writer.finalize_all_streams().unwrap();

    let mut reader = CTFSTraceReader::open_follow(&ct_path).expect("production follow open");
    assert_eq!(reader.step_count(), CHUNK_SIZE, "initial production step count");
    assert_eq!(reader.call_count(), CHUNK_SIZE, "initial materialized call count");
    assert_eq!(reader.seekable_step_count(), Some(CHUNK_SIZE), "initial seekable steps");
    assert_eq!(
        reader.seekable_value_count(),
        Some(CHUNK_SIZE),
        "initial seekable values"
    );
    assert_eq!(reader.seekable_call_count(), Some(CHUNK_SIZE), "initial seekable calls");
    assert!(
        reader.step(StepId(CHUNK_SIZE as i64)).is_none(),
        "appended step not present yet"
    );
    assert!(
        reader.seekable_variables_at(StepId(CHUNK_SIZE as i64)).is_none(),
        "appended value not present yet"
    );
    assert!(
        reader.seekable_call(CallKey(CHUNK_SIZE as i64)).is_none(),
        "appended call not present yet"
    );
    assert!(
        reader.call(CallKey(CHUNK_SIZE as i64)).is_none(),
        "appended materialized call not present yet"
    );

    writer.flush_chunk(&steps[CHUNK_SIZE..CHUNK_SIZE * 2]).unwrap();
    writer.flush_value_chunk(&values[CHUNK_SIZE..CHUNK_SIZE * 2]).unwrap();
    writer.flush_call_chunk(&calls[CHUNK_SIZE..CHUNK_SIZE * 2]).unwrap();

    assert_eq!(
        reader.step_count(),
        CHUNK_SIZE,
        "appended production steps remain invisible before refresh"
    );
    assert_eq!(
        reader.seekable_value_count(),
        Some(CHUNK_SIZE),
        "appended production values remain invisible before refresh"
    );
    assert_eq!(
        reader.seekable_call_count(),
        Some(CHUNK_SIZE),
        "appended production calls remain invisible before refresh"
    );
    assert_eq!(
        reader.call_count(),
        CHUNK_SIZE,
        "appended materialized calls remain invisible before refresh"
    );

    reader.refresh().expect("production follow refresh");

    assert_eq!(
        reader.step_count(),
        CHUNK_SIZE * 2,
        "refresh grows lazy production steps"
    );
    assert_eq!(reader.seekable_step_count(), Some(CHUNK_SIZE * 2));
    assert_eq!(reader.seekable_value_count(), Some(CHUNK_SIZE * 2));
    assert_eq!(reader.seekable_call_count(), Some(CHUNK_SIZE * 2));
    assert_eq!(
        reader.call_count(),
        CHUNK_SIZE * 2,
        "refresh grows materialized production calls"
    );

    let appended = CHUNK_SIZE;
    let step = reader
        .step(StepId(appended as i64))
        .expect("appended production step visible");
    assert_eq!(step.path_id, PathId(PATH_ID));
    assert_eq!(step.line, Line(100 + appended as i64));

    let vars = reader
        .variables_at(StepId(appended as i64))
        .expect("appended production values visible");
    assert_eq!(vars.len(), 1);
    assert_eq!(vars[0].variable_id.0, appended);
    assert!(matches!(vars[0].value, ValueRecord::Int { i, .. } if i == (appended as i64) * 10));

    let call = reader
        .seekable_call(CallKey(appended as i64))
        .expect("appended production call visible");
    assert_eq!(call.key, CallKey(appended as i64));
    assert_eq!(call.function_id, FunctionId(100 + appended));

    let materialized_call = reader
        .call(CallKey(appended as i64))
        .expect("appended materialized call visible");
    assert_eq!(materialized_call.key, CallKey(appended as i64));
    assert_eq!(materialized_call.function_id, FunctionId(100 + appended));
    assert!(
        reader.instructions_at(StepId(appended as i64)).is_some(),
        "refresh extends per-step scaffolding for appended steps"
    );
    assert!(
        reader.compound_at(StepId(appended as i64)).is_some(),
        "refresh extends compound scaffolding for appended steps"
    );

    let db = reader.materialized_db();
    assert_eq!(db.steps.len(), CHUNK_SIZE * 2, "materialized Db sees refreshed steps");
    assert_eq!(
        db.variables.len(),
        CHUNK_SIZE * 2,
        "materialized Db sees refreshed values"
    );
    assert_eq!(db.calls.len(), CHUNK_SIZE * 2, "materialized Db sees refreshed calls");
}
