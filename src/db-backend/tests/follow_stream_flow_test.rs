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

use codetracer_trace_types::{Line, PathId};

use db_backend::ctfs_trace_reader::follow_stream_source::FollowStepStreamSource;

mod stream_writer;
use stream_writer::IncrementalCtfsStreamWriter;

/// The single source path id every fixture step lives in.
const PATH_ID: usize = 3;

/// Build the fixture's expected `(path_id, line)` sequence: `total` steps at
/// lines `100, 101, 102, …`. Used to drive BOTH the writer and the assertions.
fn expected_steps(total: usize) -> Vec<(PathId, Line)> {
    (0..total)
        .map(|i| (PathId(PATH_ID), Line(100 + i as i64)))
        .collect()
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
            new, CHUNK_SIZE,
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
        let got = reader.step(i).unwrap_or_else(|| panic!("step {i} missing after finalization"));
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
    assert_eq!(reader.step_count(), 2 * CHUNK_SIZE, "trailing chunk drained on finalize");
}
