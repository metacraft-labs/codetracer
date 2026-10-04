//! Produce a LEGACY `events.log` `.ct` bundle — the combined-stream layout
//! that `CTFSTraceReader::open` still serves through `open_old_format` →
//! `TraceProcessor::postprocess`.
//!
//! No writer produces this layout any more. The trace-format spec defines no
//! `events.log` stream (`internal-files.md` lists the files of a materialized
//! `.ct`; `trace-events.md`'s old-tag disposition table records `Event` as
//! *moved to `events.dat`*), and the Rust `CtfsTraceWriter` stopped emitting it
//! in codetracer-trace-format `ac413d7`. Recordings made before that still carry
//! it, and the db-backend still opens them, so the tests that pin that reader
//! path need a producer that does not depend on a writer switch that no longer
//! exists.
//!
//! The events.log bytes are exactly what the retired writer wrote for its CBOR
//! serialization: `meta.dat`, plus an `events.log` holding the 8-byte
//! `HEADERV1` magic followed by the CBOR-encoded `TraceLowLevelEvent`s in
//! `codetracer_ctfs::ChunkedWriter`'s zstd chunks (no `events.fmt` marker, which
//! is what selects CBOR over split-binary).
//!
//! This is a producer of a real on-disk format, not a mock: every byte is read
//! back by the production `CtfsReader` and `open_old_format`. The logical
//! events.log encoding remains legacy, while its container and metadata use
//! the shipping CtfsWriter and genuine current metadata API, so both current
//! readers can exercise that retained logical compatibility path.

#![allow(dead_code)]

use std::path::{Path, PathBuf};

use codetracer_ctfs::{ChunkedWriter, CompressionMethod, CtfsWriter};
use codetracer_trace_types::TraceLowLevelEvent;

use db_backend::ctfs_trace_reader::meta_dat::{META_DAT_VERSION, MetaDat, serialize_current_meta_dat};

/// `codetracer_trace_format_cbor_zstd::HEADERV1`: "C0DE72ACE2", format version 1.
const EVENTS_HEADER_V1: [u8; 8] = [0xC0, 0xDE, 0x72, 0xAC, 0xE2, 0x01, 0x00, 0x00];

/// Events per zstd chunk. Small enough that a test fixture spans several
/// chunks, as a real recording does.
const EVENTS_PER_CHUNK: usize = 4;

/// Write `events` as a legacy `events.log` bundle at `dir/<name>.ct` and return
/// its path.
pub fn write_legacy_events_log_bundle(dir: &Path, name: &str, events: &[TraceLowLevelEvent]) -> PathBuf {
    let mut raw = Vec::new();
    let mut sizes = Vec::with_capacity(events.len());
    for event in events {
        let before = raw.len();
        raw = cbor4ii::serde::to_vec(raw, event).expect("a TraceLowLevelEvent always CBOR-encodes");
        sizes.push(raw.len() - before);
    }
    let geids: Vec<u64> = (0..events.len() as u64).collect();
    let chunks = ChunkedWriter::new(CompressionMethod::Zstd, EVENTS_PER_CHUNK)
        .write_chunked(&raw, &sizes, &geids)
        .expect("chunk the legacy event stream");
    let mut events_log = EVENTS_HEADER_V1.to_vec();
    events_log.extend_from_slice(&chunks);

    let meta = serialize_current_meta_dat(&MetaDat {
        version: META_DAT_VERSION,
        flags: 0,
        recording_id: "01949fcc-7d92-7e9c-aaaa-bbbbbbbbbbbb".to_owned(),
        program: name.to_owned(),
        args: vec![],
        workdir: dir.to_string_lossy().into_owned(),
        recorder_id: "test".to_owned(),
        paths: vec![],
        mcr: None,
        replay_launch: None,
        layout_snapshot: None,
        filter_provenance: vec![],
        has_filter_provenance: false,
    });

    let ct = dir.join(format!("{name}.ct"));
    let mut writer = CtfsWriter::create(&ct, 4096, 31).expect("create shipping container for legacy logical stream");
    for (name, bytes) in [("meta.dat", meta.as_slice()), ("events.log", events_log.as_slice())] {
        let handle = writer.add_file(name).expect("add legacy logical stream member");
        writer.write(handle, bytes).expect("write legacy logical stream member");
    }
    writer
        .close()
        .expect("publish shipping container for legacy logical stream");
    ct
}
