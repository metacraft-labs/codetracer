//! Seekable, on-demand `events.dat` I/O-event source for the db-backend.
//!
//! M0 deliverable 4 ("a seekable path for `events()`") in the BlockTracer
//! "Browser Replay Gate": until now the only way to get a trace's I/O events
//! into `Db::events` was to materialise them all at open — either through the
//! legacy `events.log` postprocessing, or through the Nim FFI's
//! `event_fields(i)` loop in `open_new_format_nim`. Neither is reachable from
//! the browser (`events.log` bundles are whole-file by construction, and the
//! Nim reader needs a filesystem path and is not in the wasm build), and
//! neither is bounded by anything but trace size.
//!
//! This module is the third sibling of [`super::call_stream_source`] and
//! [`super::step_value_stream_source`], for the M23c `events.dat` /
//! `events.idx` pair: reading event `i` decompresses ONLY the one Zstd chunk
//! that holds it, and a contiguous page decompresses only the chunks the page
//! spans.
//!
//! # Why the decode is borrowed from `call_stream_reader`
//!
//! `events.dat` and `calls.dat` share their container framing exactly — a
//! `[chunk_size: u32 LE][chunk_offset: u64 LE]…` index, and Zstd chunks of
//! varint-length-prefixed records — and differ only in the per-record payload.
//! The sibling `codetracer_trace_reader` crate has a reader for `events.dat`
//! ([`codetracer_trace_reader::io_event_stream_reader`]) but it is declared
//! `#[cfg(not(target_arch = "wasm32"))]` there, because its chunk decompression
//! calls `zstd::decode_all` with no pure-Rust arm. Its `calls.dat` sibling
//! *does* have that arm (`ruzstd` under `cfg(target_arch = "wasm32")`) and is
//! compiled for wasm32, so this module reuses
//! [`codetracer_trace_reader::call_stream_reader::decode_chunk_records`] for
//! the container framing and applies
//! [`codetracer_trace_writer::event_stream::IoEventRecord::decode`] to each
//! record. One decompressor, already correct on both targets — rather than a
//! second `cfg` split maintained here.
//!
//! # Concurrency
//!
//! As with the call/step/value sources, the one-chunk decompression cache means
//! reads take `&mut self`, so the reader is held behind a [`Mutex`] and the
//! source as a whole is `Send + Sync` behind an `Arc<dyn TraceReader>`.

use std::sync::Mutex;
use std::sync::atomic::{AtomicU64, Ordering};

use codetracer_trace_types::{EventLogKind, StepId};

use codetracer_trace_reader::ChunkForm;
use codetracer_trace_reader::call_stream_reader::decode_chunk_records;
use codetracer_trace_writer::event_stream::IoEventRecord;

use crate::db::DbRecordEvent;

use super::ctfs_container::CtfsReader;

/// A parsed `events.idx`: the per-chunk byte offsets into `events.dat`.
#[derive(Debug)]
struct EventsIndex {
    chunk_size: usize,
    chunk_offsets: Vec<u64>,
}

impl EventsIndex {
    fn parse(idx: &[u8]) -> Result<EventsIndex, String> {
        if idx.len() < 4 {
            return Err("events.idx: too short for chunk_size header".to_string());
        }
        let chunk_size = u32::from_le_bytes([idx[0], idx[1], idx[2], idx[3]]) as usize;
        if chunk_size == 0 {
            return Err("events.idx: chunk_size is zero".to_string());
        }
        let mut chunk_offsets = Vec::new();
        let mut pos = 4usize;
        while pos + 8 <= idx.len() {
            let mut buf = [0u8; 8];
            buf.copy_from_slice(&idx[pos..pos + 8]);
            chunk_offsets.push(u64::from_le_bytes(buf));
            pos += 8;
        }
        Ok(EventsIndex {
            chunk_size,
            chunk_offsets,
        })
    }
}

/// The records of one chunk of a compact container's `events.dat`: the
/// chunk's content as it is, each record framed by its varint length.
fn stored_chunk_records(content: &[u8]) -> Result<Vec<Vec<u8>>, String> {
    let mut records = Vec::new();
    let mut pos = 0usize;
    while pos < content.len() {
        let len = codetracer_trace_writer::column_aware::decode_varint(content, &mut pos)? as usize;
        let end = pos
            .checked_add(len)
            .filter(|&end| end <= content.len())
            .ok_or_else(|| format!("record {} extends past the end of its chunk", records.len()))?;
        records.push(content[pos..end].to_vec());
        pos = end;
    }
    Ok(records)
}

/// The bytes + index of an `events.dat` stream, plus the one-chunk cache.
struct EventsReader {
    index: EventsIndex,
    dat: Vec<u8>,
    /// Whether a chunk is a zstd frame (full container) or its content
    /// (compact container, `ctfs-container.md` §1f).
    form: ChunkForm,
    record_count: u64,
    cached_chunk: Option<(usize, Vec<IoEventRecord>)>,
}

impl EventsReader {
    /// Decompress `chunk_number` (unless it is already cached) and return
    /// whether a *new* chunk had to be inflated.
    fn ensure_chunk(&mut self, chunk_number: usize) -> Result<bool, String> {
        if matches!(&self.cached_chunk, Some((c, _)) if *c == chunk_number) {
            return Ok(false);
        }
        let start = self.index.chunk_offsets[chunk_number] as usize;
        let end = if chunk_number + 1 < self.index.chunk_offsets.len() {
            self.index.chunk_offsets[chunk_number + 1] as usize
        } else {
            self.dat.len()
        };
        if start > end || end > self.dat.len() {
            return Err(format!(
                "events.dat: chunk {chunk_number} offsets [{start}, {end}) out of range (dat len {})",
                self.dat.len()
            ));
        }
        let chunk = &self.dat[start..end];
        let raw_records = match self.form {
            ChunkForm::Framed => decode_chunk_records(chunk),
            ChunkForm::Stored => stored_chunk_records(chunk),
        }
        .map_err(|e| format!("events.dat: chunk {chunk_number}: {e}"))?;
        let mut records = Vec::with_capacity(raw_records.len());
        for (within, raw) in raw_records.iter().enumerate() {
            records.push(
                IoEventRecord::decode(raw)
                    .map_err(|e| format!("events.dat: chunk {chunk_number} record {within}: {e}"))?,
            );
        }
        self.cached_chunk = Some((chunk_number, records));
        Ok(true)
    }
}

/// A seekable, on-demand view over a container's `events.dat` I/O-event stream.
pub struct SeekableEventStream {
    reader: Mutex<EventsReader>,
    record_count: AtomicU64,
    chunk_size: usize,
    /// Number of *distinct* Zstd chunks inflated since the source was opened —
    /// the observable bounded-decompression property. Reading a single event, or
    /// a page that fits in one chunk, must move this by at most one.
    chunk_decompressions: AtomicU64,
}

impl std::fmt::Debug for SeekableEventStream {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("SeekableEventStream")
            .field("record_count", &self.record_count.load(Ordering::Relaxed))
            .field("chunk_size", &self.chunk_size)
            .field(
                "chunk_decompressions",
                &self.chunk_decompressions.load(Ordering::Relaxed),
            )
            .finish()
    }
}

impl SeekableEventStream {
    /// Open the seekable I/O-event stream through an already-open
    /// [`CtfsReader`], so the bytes come from the caller's current source
    /// (a file, an overlay, or the browser's in-memory VFS) rather than from a
    /// reopened filesystem path.
    ///
    /// Returns `Ok(None)` when the container carries no `events.dat` (decided by
    /// structural presence, not the `has_io_event_stream` hint bit) — the caller
    /// then keeps whatever materialised events it already has.
    pub fn open_from_ctfs(ctfs: &mut CtfsReader) -> Result<Option<SeekableEventStream>, String> {
        // Existence is answered by STRUCTURAL PRESENCE of `events.dat`, never by
        // `meta.dat`'s `has_io_event_stream` hint bit — a writer may stamp that
        // bit only at close, so gating on it would refuse an I/O-event stream that
        // structurally exists in a still-recording trace (trace-format spec:
        // "Stream-presence flags are a hint, not a gate").
        let dat = match ctfs.read_file("events.dat") {
            Ok(dat) => dat,
            Err(_) => return Ok(None),
        };
        let idx = ctfs
            .read_file("events.idx")
            .map_err(|e| format!("events.idx missing despite events.dat presence: {e}"))?;

        let index = EventsIndex::parse(&idx)?;
        let chunk_size = index.chunk_size;

        // The record count: every chunk but the last holds `chunk_size`
        // records; the last holds however many decode out of it. Establishing
        // the count therefore inflates exactly ONE chunk at open (the last),
        // never the whole stream.
        let mut reader = EventsReader {
            index,
            dat,
            form: ctfs.chunk_form(),
            record_count: 0,
            cached_chunk: None,
        };
        let record_count = if reader.index.chunk_offsets.is_empty() {
            0
        } else {
            let last_chunk = reader.index.chunk_offsets.len() - 1;
            reader.ensure_chunk(last_chunk)?;
            let last_records = reader.cached_chunk.as_ref().map(|(_, r)| r.len()).unwrap_or(0);
            (last_chunk * chunk_size + last_records) as u64
        };
        reader.record_count = record_count;

        Ok(Some(SeekableEventStream {
            reader: Mutex::new(reader),
            record_count: AtomicU64::new(record_count),
            chunk_size,
            chunk_decompressions: AtomicU64::new(0),
        }))
    }

    /// Total number of I/O events in the stream.
    pub fn event_count(&self) -> usize {
        self.record_count.load(Ordering::Relaxed) as usize
    }

    /// The fixed records-per-chunk seek granularity.
    pub fn chunk_size(&self) -> usize {
        self.chunk_size
    }

    /// Number of *distinct* Zstd chunks inflated so far.
    pub fn chunk_decompressions(&self) -> u64 {
        self.chunk_decompressions.load(Ordering::Relaxed)
    }

    /// Fetch one event by index, decompressing only its chunk. `None` for an
    /// out-of-range index.
    pub fn event(&self, index: usize) -> Option<DbRecordEvent> {
        if index as u64 >= self.record_count.load(Ordering::Relaxed) {
            return None;
        }
        let mut reader = self.reader.lock().ok()?;
        let chunk_number = index / self.chunk_size;
        let within = index % self.chunk_size;
        match reader.ensure_chunk(chunk_number) {
            Ok(true) => {
                self.chunk_decompressions.fetch_add(1, Ordering::Relaxed);
            }
            Ok(false) => {}
            Err(e) => {
                log::warn!("events.dat: read of event {index} failed: {e}");
                return None;
            }
        }
        let records = &reader.cached_chunk.as_ref()?.1;
        match io_event_record_to_db_event(records.get(within)?) {
            Ok(event) => Some(event),
            Err(e) => {
                log::error!("events.dat: event {index} refused: {e}");
                None
            }
        }
    }

    /// Fetch a contiguous page of events, decompressing only the chunks the
    /// page spans. `start` past the end yields an empty page; a page that runs
    /// past the end is clamped.
    pub fn page(&self, start: usize, len: usize) -> Vec<DbRecordEvent> {
        let total = self.record_count.load(Ordering::Relaxed) as usize;
        if start >= total || len == 0 {
            return Vec::new();
        }
        let end = std::cmp::min(start + len, total);
        let mut out = Vec::with_capacity(end - start);
        for index in start..end {
            match self.event(index) {
                Some(event) => out.push(event),
                None => break,
            }
        }
        out
    }

    /// Materialise every event. This is the DELIBERATELY unbounded accessor,
    /// kept for the callers that still want a whole `Db::events` vector; it is
    /// separate from [`Self::page`] so that a caller which materialises is
    /// visible at the call site rather than hidden behind an innocuous name.
    pub fn all_events(&self) -> Vec<DbRecordEvent> {
        let total = self.record_count.load(Ordering::Relaxed) as usize;
        self.page(0, total)
    }
}

/// The `EventLogKind` an `events.dat` kind byte stands for: the recorder's
/// exact `EventLogKind`, by ordinal (`trace-events.md` §"EventLogKind (u8
/// enum)"). Values 14-255 are unassigned and refused, naming the value: a
/// substitute kind would report an event as something it was not.
pub fn event_log_kind_from_ordinal(kind: u8) -> Result<EventLogKind, String> {
    Ok(match kind {
        0 => EventLogKind::Write,
        1 => EventLogKind::WriteFile,
        2 => EventLogKind::WriteOther,
        3 => EventLogKind::Read,
        4 => EventLogKind::ReadFile,
        5 => EventLogKind::ReadOther,
        6 => EventLogKind::ReadDir,
        7 => EventLogKind::OpenDir,
        8 => EventLogKind::CloseDir,
        9 => EventLogKind::Socket,
        10 => EventLogKind::Open,
        11 => EventLogKind::Error,
        12 => EventLogKind::TraceLogEvent,
        13 => EventLogKind::EvmEvent,
        other => {
            return Err(format!(
                "events.dat: event kind {other} is not an assigned EventLogKind (0-13)"
            ));
        }
    })
}

/// Map an `events.dat` [`IoEventRecord`] onto the db-backend's
/// [`DbRecordEvent`], refusing a record whose kind is unassigned.
pub fn io_event_record_to_db_event(record: &IoEventRecord) -> Result<DbRecordEvent, String> {
    Ok(DbRecordEvent {
        kind: event_log_kind_from_ordinal(record.kind)?,
        content: String::from_utf8_lossy(&record.content).into_owned(),
        step_id: StepId(record.step_id as i64),
        metadata: String::from_utf8_lossy(&record.metadata).into_owned(),
    })
}

#[cfg(test)]
// Unit tests: `unwrap` is the readable spelling of "this fixture is well
// formed, and a panic here IS the failure report". The crate denies it on
// production paths (`main.rs:4`); this is the local-allow convention that
// file documents at line 53.
#[allow(clippy::unwrap_used)]
mod tests {
    use super::*;

    /// The `EventLogKind` table of `trace-events.md` §"EventLogKind (u8
    /// enum)", by ordinal. Spelled out rather than derived from the enum, so
    /// that a reordering of the enum fails here instead of silently
    /// relabelling every recording.
    const SPEC_KINDS: [(u8, EventLogKind); 14] = [
        (0, EventLogKind::Write),
        (1, EventLogKind::WriteFile),
        (2, EventLogKind::WriteOther),
        (3, EventLogKind::Read),
        (4, EventLogKind::ReadFile),
        (5, EventLogKind::ReadOther),
        (6, EventLogKind::ReadDir),
        (7, EventLogKind::OpenDir),
        (8, EventLogKind::CloseDir),
        (9, EventLogKind::Socket),
        (10, EventLogKind::Open),
        (11, EventLogKind::Error),
        (12, EventLogKind::TraceLogEvent),
        (13, EventLogKind::EvmEvent),
    ];

    fn record(kind: u8) -> IoEventRecord {
        IoEventRecord {
            kind,
            step_id: 4,
            metadata: b"m".to_vec(),
            content: b"c".to_vec(),
        }
    }

    /// Every on-disk kind byte is reported as exactly the `EventLogKind` with
    /// that ordinal, not mapped onto a coarser set.
    #[test]
    fn every_kind_is_read_as_its_exact_ordinal() {
        for (raw, expected) in SPEC_KINDS {
            let event = io_event_record_to_db_event(&record(raw)).unwrap();
            assert_eq!(event.kind, expected, "kind byte {raw}");
            assert_eq!(event.step_id, StepId(4));
            assert_eq!(event.content, "c");
            assert_eq!(event.metadata, "m");
        }
    }

    /// Values 14-255 are unassigned, and a record carrying one is refused,
    /// naming the value, rather than given a substitute kind.
    #[test]
    fn an_unassigned_kind_is_refused_by_value() {
        for raw in [14u8, 15, 99, 255] {
            let err = io_event_record_to_db_event(&record(raw)).unwrap_err();
            assert!(
                err.contains(&raw.to_string()) && err.contains("EventLogKind"),
                "the refusal of kind {raw} does not name it: {err}"
            );
        }
    }

    /// The metadata slot carries correlation markers; dropping it silently
    /// breaks cross-process origin chains, so it is asserted explicitly.
    #[test]
    fn metadata_is_preserved_not_dropped() {
        let record = IoEventRecord {
            kind: 0,
            step_id: 0,
            metadata: b"ct-marker:abc".to_vec(),
            content: Vec::new(),
        };
        assert_eq!(io_event_record_to_db_event(&record).unwrap().metadata, "ct-marker:abc");
    }

    /// An `events.idx` shorter than its own header is rejected by name.
    #[test]
    fn truncated_index_is_rejected() {
        let err = EventsIndex::parse(&[0u8; 3]).unwrap_err();
        assert!(err.contains("events.idx"), "{err}");
    }

    /// A zero `chunk_size` would make every seek divide by zero; it is rejected
    /// at parse rather than trapping later.
    #[test]
    fn zero_chunk_size_is_rejected() {
        let mut idx = 0u32.to_le_bytes().to_vec();
        idx.extend_from_slice(&0u64.to_le_bytes());
        let err = EventsIndex::parse(&idx).unwrap_err();
        assert!(err.contains("chunk_size is zero"), "{err}");
    }

    /// The chunk offsets are parsed in order after the 4-byte header.
    #[test]
    fn index_parses_chunk_offsets_after_the_header() {
        let mut idx = 64u32.to_le_bytes().to_vec();
        for offset in [0u64, 128, 512] {
            idx.extend_from_slice(&offset.to_le_bytes());
        }
        let parsed = EventsIndex::parse(&idx).unwrap();
        assert_eq!(parsed.chunk_size, 64);
        assert_eq!(parsed.chunk_offsets, vec![0, 128, 512]);
    }
}
