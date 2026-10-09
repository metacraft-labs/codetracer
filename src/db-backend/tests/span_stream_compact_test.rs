//! A compact-profile container's span stream reads exactly as the full
//! container's does.
//!
//! A compact container stores each chunk of `spans.dat` as the chunk's content
//! rather than as a zstd frame (`ctfs-container.md` §1f). The recordings here
//! are written by the Rust `CtfsTraceWriter`, once with its compact threshold
//! set so it emits the compact profile and once without, and their span
//! streams are read through the db-backend's own span reader and the request
//! span loader built on it. No mocks.

#![allow(clippy::expect_used, clippy::unwrap_used, clippy::panic)]

use std::path::{Path, PathBuf};

use codetracer_trace_types::{Line, PathId, StepRecord, TraceLowLevelEvent};
use codetracer_trace_writer::ctfs_writer::CtfsTraceWriter;
use codetracer_trace_writer::span_stream::{SPAN_STATUS_OK, SpanRecord as WrittenSpan};
use codetracer_trace_writer::trace_writer::TraceWriter;

use db_backend::ctfs_trace_reader::ctfs_container::{CtfsProfile, CtfsReader};
use db_backend::ctfs_trace_reader::span_stream::{SpanRecord, SpanStreamReader};
use db_backend::request_spans::load_request_spans;

const SRC: &str = "/tmp/spans/server.py";

/// Spans per explicitly sealed chunk; three chunks are written.
const SPANS_PER_CHUNK: u64 = 4;
const CHUNKS: u64 = 3;

fn span(id: u64, open: bool) -> WrittenSpan {
    WrittenSpan {
        span_id: id,
        is_open: open,
        status: if open { 0 } else { SPAN_STATUS_OK },
        start_wall_ns: 1000 * id,
        end_wall_ns: if open { 0 } else { 1000 * id + 500 },
        start_step: id,
        end_step: if open { 0 } else { id + 1 },
        span_type: "web-request".into(),
        label: format!("GET /item/{id}"),
        contiguous_on_one_thread: true,
        metadata: vec![("http.path".into(), format!("/item/{id}"))],
        ..WrittenSpan::default()
    }
}

/// Record a short program with spans over three sealed chunks, and return the
/// container's path. `compact_threshold` 0 writes the full profile.
fn record(dir: &Path, name: &str, compact_threshold: u64) -> PathBuf {
    let stem = dir.join(name);
    let mut writer = CtfsTraceWriter::new(name, &[]).with_compact_threshold(compact_threshold);
    TraceWriter::set_workdir(&mut writer, dir);
    TraceWriter::begin_writing_trace_events(&mut writer, &stem).expect("begin");
    let mut events = vec![TraceLowLevelEvent::Path(PathBuf::from(SRC))];
    for line in 1..=(SPANS_PER_CHUNK * CHUNKS + 2) as i64 {
        events.push(TraceLowLevelEvent::Step(StepRecord {
            path_id: PathId(0),
            line: Line(line),
        }));
    }
    TraceWriter::append_events(&mut writer, &mut events);
    let mut id = 1;
    for _ in 0..CHUNKS {
        for _ in 0..SPANS_PER_CHUNK / 2 {
            writer.register_span(&span(id, true)).expect("open span");
            writer.register_span(&span(id, false)).expect("settled span");
            id += 1;
        }
        writer.flush_spans().expect("seal the chunk");
    }
    TraceWriter::finish_writing_trace_events(&mut writer).expect("finish");
    stem.with_extension("ct")
}

fn key(s: &SpanRecord) -> (u64, bool, u64, u64, String, Vec<(String, String)>) {
    (
        s.span_id,
        s.is_open,
        s.start_wall_ns,
        s.end_step,
        s.label.clone(),
        s.metadata.clone(),
    )
}

fn all_records(ct: &Path) -> Vec<SpanRecord> {
    let mut ctfs = CtfsReader::open(ct).expect("open the container");
    let mut reader = SpanStreamReader::open_from_ctfs(&mut ctfs)
        .expect("the span stream opens")
        .expect("the container carries a span stream");
    assert_eq!(reader.chunk_count() as u64, CHUNKS, "{}: chunk count", ct.display());
    reader.read_all_span_records().expect("every span record reads")
}

#[test]
fn a_compact_containers_span_stream_reads_as_the_full_ones() {
    let dir = tempfile::tempdir().unwrap();
    let full = record(dir.path(), "full", 0);
    let compact = record(dir.path(), "compact", 1 << 20);

    assert_eq!(CtfsReader::open(&full).unwrap().profile(), CtfsProfile::Full);
    let compact_ctfs = CtfsReader::open(&compact).unwrap();
    assert_eq!(
        compact_ctfs.profile(),
        CtfsProfile::Compact,
        "the writer did not emit the compact profile, so this test proves nothing"
    );
    assert!(
        compact_ctfs.has_file("spans.dat"),
        "the compact container carries no spans.dat"
    );

    // The control: the full container's spans are the ones recorded.
    let expected = all_records(&full);
    assert_eq!(expected.len() as u64, SPANS_PER_CHUNK * CHUNKS);
    assert_eq!(expected[0].label, "GET /item/1");

    let got = all_records(&compact);
    assert_eq!(
        got.iter().map(key).collect::<Vec<_>>(),
        expected.iter().map(key).collect::<Vec<_>>(),
        "the compact container's span records differ from the full container's"
    );

    // A point read of a record in the middle chunk.
    let mut ctfs = CtfsReader::open(&compact).unwrap();
    let mut reader = SpanStreamReader::open_from_ctfs(&mut ctfs).unwrap().unwrap();
    let mid = SPANS_PER_CHUNK + 1;
    assert_eq!(
        key(&reader.read_span(mid).expect("read_span")),
        key(&expected[mid as usize])
    );

    // The request-span loader the DAP server answers from.
    let loaded = load_request_spans(&compact)
        .expect("the request spans load")
        .expect("the request spans are present");
    let settled_full = load_request_spans(&full).unwrap().unwrap();
    assert_eq!(
        loaded.spans.iter().map(key).collect::<Vec<_>>(),
        settled_full.spans.iter().map(key).collect::<Vec<_>>(),
        "the compact container's settled spans differ from the full container's"
    );
}

/// The remote tail's reader: a suffix of a compact `spans.dat`, starting at
/// its second chunk, read in the container's form.
#[test]
fn a_partial_compact_span_stream_reads_its_resident_chunks() {
    let dir = tempfile::tempdir().unwrap();
    let full = record(dir.path(), "full", 0);
    let compact = record(dir.path(), "compact", 1 << 20);
    let expected = all_records(&full);

    let mut ctfs = CtfsReader::open(&compact).unwrap();
    let form = ctfs.chunk_form();
    let idx = ctfs.read_file("spans.idx").unwrap();
    let dat = ctfs.read_file("spans.dat").unwrap();
    let base = u64::from_le_bytes(idx[8 + 16..8 + 24].try_into().unwrap());
    let mut reader = SpanStreamReader::from_partial_files(dat[base as usize..].to_vec(), base, &idx)
        .unwrap()
        .with_chunk_form(form);
    assert!(
        reader.chunk_is_resident(CHUNKS as usize - 1),
        "the last chunk is resident"
    );
    let got = reader
        .read_spans_in_chunks(1, CHUNKS as usize)
        .expect("the resident chunks read");
    assert_eq!(
        got.iter().map(key).collect::<Vec<_>>(),
        expected[SPANS_PER_CHUNK as usize..].iter().map(key).collect::<Vec<_>>()
    );
}
