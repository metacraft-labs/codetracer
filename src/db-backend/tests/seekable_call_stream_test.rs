//! M17b — db-backend SEEKABLE `calls.dat` reader tests.
//!
//! These tests exercise the db-backend's on-demand call-tree path (the
//! `SeekableCallStream` wired into `CTFSTraceReader`), proving the spec
//! properties from `Trace-Files-Overview.md` §"Random-access seeking" and
//! `trace-events.md` §"Call Stream (`calls.dat`)":
//!
//!  1. A call record is fetched by `call_key` from a `has_call_stream` `.ct`
//!     through the seekable path WITHOUT materializing the whole trace — and the
//!     decompression is BOUNDED (only the needed chunk is inflated), proven by
//!     the `SeekableCallStream` chunk-decompression counter.
//!  2. Multiple concurrent readers can read the same `.ct` independently.
//!  3. Backward compat: a legacy (flag-off) `.ct` exposes NO seekable stream and
//!     still reads through the existing fully-materialized path, unchanged.
//!
//! The fixtures are written in-test with the M17a writer
//! (`CtfsTraceWriter::with_call_stream(true)` / a flag-off twin), so the tests
//! are self-contained and do not depend on an external bundle.

#![allow(clippy::expect_used, clippy::unwrap_used, clippy::panic)]

use std::path::{Path, PathBuf};
use std::sync::Arc;

use codetracer_trace_types::*;
use codetracer_trace_writer::ctfs_writer::CtfsTraceWriter;
use codetracer_trace_writer::trace_writer::TraceWriter;

use db_backend::ctfs_trace_reader::call_stream_source::SeekableCallStream;
use db_backend::ctfs_trace_reader::CTFSTraceReader;
use db_backend::trace_reader::TraceReader;

/// Write a small trace exercising nested calls, mirroring the M17a round-trip
/// fixture. `start()` emits an implicit `<toplevel>` call (function_id 0); the
/// user calls nest beneath it. Call records, by call_key:
///   <toplevel>()                 -> 0 (root, depth 0)
///     main()                     -> 1 (child of 0, depth 1)
///       used_a() returns 1       -> 2 (child of 1, depth 2)
///       used_b() calls leaf()    -> 3 (child of 1, depth 2)
///         leaf()  returns        -> 4 (child of 3, depth 3)
///
/// A small `calls.dat` chunk size (2) means the 5 records span 3 chunks, so
/// seeking to a single call must inflate only that one chunk.
fn write_trace(dir: &tempfile::TempDir, with_call_stream: bool) -> PathBuf {
    let path_buf = dir.path().join("trace");
    let mut writer = CtfsTraceWriter::new("test_program", &[]).with_call_stream(with_call_stream);
    writer = writer.with_calls_chunk_size(2);
    TraceWriter::begin_writing_trace_events(&mut writer, &path_buf).unwrap();

    let src = Path::new("/test/prog.rs");
    TraceWriter::start(&mut writer, src, Line(1));

    let int_type = TraceWriter::ensure_type_id(&mut writer, TypeKind::Int, "Int");
    let main_fn = TraceWriter::ensure_function_id(&mut writer, "main", src, Line(1));
    let used_a = TraceWriter::ensure_function_id(&mut writer, "used_a", src, Line(10));
    let used_b = TraceWriter::ensure_function_id(&mut writer, "used_b", src, Line(20));
    let leaf = TraceWriter::ensure_function_id(&mut writer, "leaf", src, Line(30));
    let _unused_c = TraceWriter::ensure_function_id(&mut writer, "unused_c", src, Line(40));

    // main()
    TraceWriter::register_call(&mut writer, main_fn, vec![]);
    TraceWriter::register_step(&mut writer, src, Line(2));

    // used_a(x=5) -> 1
    let arg_a = TraceWriter::arg(&mut writer, "x", ValueRecord::Int { i: 5, type_id: int_type });
    TraceWriter::register_call(&mut writer, used_a, vec![arg_a]);
    TraceWriter::register_step(&mut writer, src, Line(11));
    TraceWriter::register_return(&mut writer, ValueRecord::Int { i: 1, type_id: int_type });

    // used_b() -> calls leaf()
    TraceWriter::register_call(&mut writer, used_b, vec![]);
    TraceWriter::register_step(&mut writer, src, Line(21));
    TraceWriter::register_call(&mut writer, leaf, vec![]);
    TraceWriter::register_step(&mut writer, src, Line(31));
    TraceWriter::register_return(&mut writer, ValueRecord::None { type_id: NONE_TYPE_ID });
    TraceWriter::register_return(&mut writer, ValueRecord::Int { i: 2, type_id: int_type });

    // main returns
    TraceWriter::register_return(&mut writer, ValueRecord::None { type_id: NONE_TYPE_ID });

    TraceWriter::finish_writing_trace_events(&mut writer).unwrap();
    path_buf.with_extension("ct")
}

/// Deliverable test #1 (bounded decompression): fetching ONE call by key from a
/// multi-chunk `calls.dat` decompresses ONLY that call's chunk — not the whole
/// stream. Proven by the `SeekableCallStream` chunk-decompression counter, which
/// is observable and exact (it samples the M17a reader's one-chunk cache).
#[test]
fn fetch_call_by_key_decompresses_only_its_chunk() {
    let dir = tempfile::tempdir().unwrap();
    let ct = write_trace(&dir, true);

    let stream = SeekableCallStream::open(&ct)
        .expect("open seekable call stream")
        .expect("trace has has_call_stream flag set");

    // 5 records over chunk_size 2 ⇒ 3 chunks; nothing inflated yet.
    assert_eq!(stream.call_count(), 5, "expected 5 call records (1 toplevel + 4 user calls)");
    assert_eq!(stream.chunk_size(), 2);
    assert_eq!(stream.chunk_decompressions(), 0, "no chunk inflated before the first read");

    // Fetch call_key 4 (leaf), which lives in the LAST (3rd) chunk. A
    // whole-trace materialization would touch every chunk; the seekable path
    // must inflate exactly ONE.
    let leaf = stream.call(CallKey(4)).expect("call_key 4 present");
    assert_eq!(leaf.key, CallKey(4));
    assert_eq!(leaf.depth, 3, "leaf is at depth 3");
    assert_eq!(leaf.parent_key, CallKey(3), "leaf's parent is used_b (call_key 3)");
    assert_eq!(
        stream.chunk_decompressions(),
        1,
        "fetching one call inflated exactly one chunk, not the whole stream"
    );

    // A second read WITHIN the same chunk (call_key 5 would be out of range; 4
    // is the only record in chunk 2 here) — re-reading key 4 must NOT inflate
    // again (the reader caches the chunk).
    let _again = stream.call(CallKey(4)).expect("re-read call_key 4");
    assert_eq!(stream.chunk_decompressions(), 1, "re-reading the cached chunk inflates nothing new");

    // Reading a call in a DIFFERENT chunk (call_key 0, chunk 0) inflates one
    // more — still bounded, one chunk per distinct chunk touched.
    let root = stream.call(CallKey(0)).expect("call_key 0 present");
    assert_eq!(root.parent_key, CallKey(-1), "toplevel root has parent -1");
    assert_eq!(stream.chunk_decompressions(), 2, "touching a new chunk inflated exactly one more");

    // Out-of-range key yields None, never a panic, and inflates nothing.
    assert!(stream.call(CallKey(99)).is_none());
    assert!(stream.call(CallKey(-1)).is_none());
    assert_eq!(stream.chunk_decompressions(), 2);
}

/// Deliverable test #1 (call tree from calls.dat, not a materialized Db): the
/// `CTFSTraceReader` over a `has_call_stream` `.ct` serves the call tree through
/// the SEEKABLE hooks (`seekable_call_count`/`seekable_call`), and the records
/// match the structure the call stream encodes.
#[test]
fn ctfs_reader_serves_call_tree_from_calls_dat() {
    let dir = tempfile::tempdir().unwrap();
    let ct = write_trace(&dir, true);

    let reader = CTFSTraceReader::open(&ct).expect("open CTFS reader over split bundle");

    // The seekable hooks are active (call tree comes from calls.dat).
    let seekable_count = reader.seekable_call_count().expect("reader exposes a seekable call stream");
    assert_eq!(seekable_count, 5, "5 calls served from calls.dat");

    // Spot-check the tree structure read through the seekable path.
    let root = reader.seekable_call(CallKey(0)).expect("seekable call_key 0");
    assert_eq!(root.parent_key, CallKey(-1));
    assert_eq!(root.depth, 0);

    let main_call = reader.seekable_call(CallKey(1)).expect("seekable call_key 1");
    assert_eq!(main_call.parent_key, CallKey(0));
    assert_eq!(main_call.depth, 1);
    assert!(
        main_call.children_keys.contains(&CallKey(2)) && main_call.children_keys.contains(&CallKey(3)),
        "main's children are used_a (2) and used_b (3): {:?}",
        main_call.children_keys
    );

    let used_a = reader.seekable_call(CallKey(2)).expect("seekable call_key 2");
    assert_eq!(used_a.parent_key, CallKey(1));
    assert_eq!(used_a.depth, 2);
}

/// Deliverable test #2 (concurrent readers): multiple readers over the SAME
/// `.ct` can fetch calls independently and agree, per the spec's
/// "multiple concurrent readers" property. Each thread opens its own seekable
/// stream (CTFS is opened read-only), so they never contend.
#[test]
fn concurrent_readers_over_same_ct() {
    let dir = tempfile::tempdir().unwrap();
    let ct = write_trace(&dir, true);
    let ct = Arc::new(ct);

    let mut handles = Vec::new();
    for t in 0..8usize {
        let ct = Arc::clone(&ct);
        handles.push(std::thread::spawn(move || {
            // Each thread opens its OWN seekable stream over the same file.
            let stream = SeekableCallStream::open(&ct)
                .expect("open in thread")
                .expect("flag set");
            assert_eq!(stream.call_count(), 5);
            // Read every call key in an order that varies per thread, asserting
            // a stable, reader-independent result.
            for i in 0..5usize {
                let key = CallKey(((i + t) % 5) as i64);
                let call = stream.call(key).expect("call present");
                assert_eq!(call.key, key);
            }
            // Bounded decompression: each of the 5 reads inflates AT MOST one
            // chunk (the reader caches the last chunk; a cache miss inflates
            // exactly one). So the total is at most one-per-read (5), never the
            // whole stream materialized N times. The exact per-fetch bound is
            // proven in `fetch_call_by_key_decompresses_only_its_chunk`.
            assert!(
                stream.chunk_decompressions() <= 5,
                "bounded per-reader decompression: {} > 5",
                stream.chunk_decompressions()
            );
            t
        }));
    }
    let mut seen: Vec<usize> = handles.into_iter().map(|h| h.join().expect("thread joined")).collect();
    seen.sort_unstable();
    assert_eq!(seen, (0..8).collect::<Vec<_>>(), "all readers completed");
}

/// Deliverable test #3a (backward compat, seekable layer): a flag-off `.ct`
/// exposes NO seekable call stream — `SeekableCallStream::open` returns `None`,
/// so the caller transparently falls back to the materialized call tree.
#[test]
fn flag_off_trace_exposes_no_seekable_stream() {
    let dir = tempfile::tempdir().unwrap();
    let ct = write_trace(&dir, false);

    assert!(
        SeekableCallStream::open(&ct).expect("open ok").is_none(),
        "flag-off trace exposes no seekable calls.dat (no has_call_stream flag)"
    );
}

/// Deliverable test #3b (backward compat, full reader): a REAL legacy `.ct`
/// recorded WITHOUT the call-stream split (the reprobuild `ruby.ct` fixture —
/// a complete flag-off bundle with a full `meta.dat`) still opens through the
/// existing path, exposes NO seekable stream, and serves its call tree from the
/// fully-materialized `Db` exactly as before.
///
/// The fixture is the flag-OFF twin of `ruby_split.ct` used by the M17a engine
/// tests. It is skipped (not failed) if the reprobuild checkout is absent, so
/// the db-backend suite stays self-contained on a bare checkout while genuinely
/// exercising a real legacy bundle when the workspace has it.
#[test]
fn real_legacy_ct_reads_unchanged_with_no_seekable_stream() {
    let fixture = Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../../../reprobuild/libs/repro_ct_incremental/tests/fixtures/m12_ctfs/ruby.ct");
    if !fixture.exists() {
        eprintln!("skipping real_legacy_ct_reads_unchanged: fixture absent at {}", fixture.display());
        return;
    }

    let reader = CTFSTraceReader::open(&fixture).expect("open real legacy ruby.ct");
    assert!(
        reader.seekable_call_count().is_none(),
        "legacy ruby.ct (flag off) exposes no seekable stream"
    );
    // The materialized path still serves a non-trivial call tree.
    assert!(reader.call_count() >= 1, "legacy call tree materialized");
    assert!(reader.call(CallKey(0)).is_some(), "legacy call_key 0 present on the materialized path");
}

/// Deliverable test #1 over a REAL recorded bundle: the reprobuild
/// `ruby_split.ct` fixture (a genuine flag-ON Ruby recording) is served through
/// the seekable path, fetching a call by key with bounded decompression.
///
/// M20 (RESOLVED): `ruby_split.ct` is now produced by the Nim
/// `multi_stream_writer` WITH the Rust-compatible chunked-Zstd `calls.dat` plus
/// its companion `calls.idx` seek index (the M20 fix to `call_stream.nim`). The
/// M17a `CallStreamReader` can therefore index a Nim-written split bundle, and
/// this test asserts — no longer skips — that the real recorded bundle is served
/// through the seekable path with bounded decompression. (Pre-M20 the Nim writer
/// shipped a `calls.dat`+`calls.off` VariableRecordTable with no `calls.idx`, so
/// this test had to skip; that gap is closed.) The only remaining tolerated skip
/// is a genuinely-absent fixture (e.g. a sparse checkout).
#[test]
fn real_split_ct_serves_calls_seekably_with_bounded_decompression() {
    let fixture = Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../../../reprobuild/libs/repro_ct_incremental/tests/fixtures/m12_ctfs/ruby_split.ct");
    if !fixture.exists() {
        eprintln!("skipping real_split_ct_serves_calls_seekably: fixture absent at {}", fixture.display());
        return;
    }

    // M20: a Nim-written split bundle MUST now be seekable — open must succeed
    // and expose a stream (the fixture carries has_call_stream + calls.idx).
    let stream = SeekableCallStream::open(&fixture)
        .expect("M20: Nim-written ruby_split.ct must open seekably (calls.idx present)")
        .expect("M20: ruby_split.ct must expose a seekable call stream (has_call_stream set)");

    let n = stream.call_count();
    assert!(n >= 1, "real bundle has at least one call");
    assert_eq!(stream.chunk_decompressions(), 0, "nothing inflated before the first read");

    // Fetch the LAST call by key — a whole-trace load would touch every chunk;
    // the seekable path inflates at most one.
    let last = stream.call(CallKey((n - 1) as i64)).expect("last call present");
    assert_eq!(last.key, CallKey((n - 1) as i64));
    assert!(
        stream.chunk_decompressions() <= 1,
        "fetching one call inflated at most one chunk over a real recorded bundle, got {}",
        stream.chunk_decompressions()
    );
}

/// Cross-check: the seekable call tree (from `calls.dat`) and the fully
/// materialized call tree (postprocessed from `events.log`) agree on the tree
/// STRUCTURE for the same split bundle — proving the seekable path is not a
/// divergent re-derivation but the same tree, loaded on demand.
#[test]
fn seekable_and_materialized_call_trees_agree() {
    let dir = tempfile::tempdir().unwrap();
    let ct = write_trace(&dir, true);
    let reader = CTFSTraceReader::open(&ct).expect("open split bundle");

    let n = reader.seekable_call_count().expect("seekable stream present");
    assert_eq!(n, reader.call_count(), "same number of calls on both paths");

    for i in 0..n {
        let key = CallKey(i as i64);
        let seek = reader.seekable_call(key).expect("seekable call");
        let materialized = reader.call(key).expect("materialized call").clone();
        assert_eq!(seek.key, materialized.key, "call {i}: key");
        assert_eq!(seek.function_id, materialized.function_id, "call {i}: function_id");
        assert_eq!(seek.parent_key, materialized.parent_key, "call {i}: parent_key");
        assert_eq!(seek.depth, materialized.depth, "call {i}: depth");
        assert_eq!(seek.children_keys, materialized.children_keys, "call {i}: children");
    }
}
