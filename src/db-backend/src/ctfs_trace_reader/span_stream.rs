//! Reader for the CTFS request/interval **span stream** — `spans.dat` /
//! `spans.idx` / `spantype.ns` (RS-M2).
//!
//! Spec: `codetracer-specs/Trace-Files/CTFS-Request-Span-Streams.md`.
//! Canonical writer *and* reference reader:
//! `codetracer-trace-format-nim/src/codetracer_trace_writer/span_stream.nim`.
//! This module is the Rust half of that pair and is deliberately written to
//! mirror it procedure-for-procedure so the two can be diffed: same index
//! validation, same binary search, same fail-closed record decoder, same
//! last-record-wins resolution.  A container written by the Nim writer must
//! read identically here — `tests/span_stream_request_spans_test.rs` pins that
//! against real Nim-written fixtures.
//!
//! # What a span is
//!
//! A bounded, labeled interval of execution named by the coordinate
//! *(process_ord, thread_id, step range)* — an HTTP request, a process, a test.
//! The stream replaces the `session_manifest.jsonl` / `codetracer_spans.jsonl`
//! sidecars the PHP / Ruby / Python recorders write today, so a recording is
//! **one artifact**.
//!
//! # Files
//!
//! | File          | Type               | Contents                                   |
//! | ------------- | ------------------ | ------------------------------------------ |
//! | `spans.dat`   | Chunked compressed | Span records in append order               |
//! | `spans.idx`   | Companion index    | header + `[offset u64][cumulative u64]`... |
//! | `spantype.ns` | Namespace          | interned `span_type` id -> span ids        |
//!
//! All three are gated by `meta.dat` bit 13
//! [`FLAG_HAS_SPAN_STREAM`](super::meta_dat::FLAG_HAS_SPAN_STREAM).
//!
//! # `spans.dat` layout (CTFS §9c chunked compressed table)
//!
//! ```text
//! [zstd(chunk 0)][zstd(chunk 1)]...
//! ```
//!
//! Each chunk's uncompressed payload is the concatenation of LENGTH-PREFIXED
//! records (`[varint rec_len][rec_bytes]`...), exactly as `events.dat` /
//! `calls.dat` do.  Chunks are independently decompressible.
//!
//! # `spans.idx` layout (v2, CTFS §7 companion index)
//!
//! ```text
//! Header (8 bytes):
//!   [chunk_size: u32 LE][index_version: u16 LE = 2][reserved: u16 LE = 0]
//! Entries (16 bytes each, at 8 + i*16 — a FIXED STRIDE, per CTFS §7):
//!   [offset: u64 LE][cumulative_records: u64 LE]
//! ```
//!
//! `offset_i` is chunk `i`'s first byte in `spans.dat`.  `cumulative_records_i`
//! is the number of span RECORDS held by chunks `0..=i` — a running total, not
//! a per-chunk count.
//!
//! ## Why `chunk_size` cannot locate a record
//!
//! Unlike a table whose chunks are all full but the last, a span chunk may be
//! SHORT ANYWHERE in the stream: the writer's `flush` seals whatever is
//! buffered, and a live recorder calls it per request so an in-flight span
//! becomes visible immediately.  `chunk_size` is therefore only an UPPER-BOUND
//! HINT — the writer's seal-at threshold.  The CTFS §7 rule
//! "chunk = N div chunk_size" does NOT hold for this stream; the **cumulative
//! column is authoritative**, and [`SpanStreamReader::read_span`] binary-searches
//! it.
//!
//! Empty chunks repeat their predecessor's cumulative total, so the search must
//! take the first entry *strictly greater* than the target index.
//!
//! # Opening decodes nothing
//!
//! [`SpanStreamReader::from_files`] parses the index and decompresses NOTHING.
//! `count()`, `records_in_chunk()` and the chunk that owns any record all come
//! from `spans.idx` alone.  RS-M1 originally shipped the plain §7 shape and the
//! reader had to decode *every chunk at open* to recover occupancy, which cost
//! 20–210 ms on realistic streams; the cumulative column exists precisely to
//! remove that.  [`SpanStreamReader::chunk_decompressions`] is the test seam
//! that pins the property.
//!
//! # Record model (spec §"Record Model", wire format v1)
//!
//! ```text
//! span_id:          varint u64   # 1-based, monotonic within the container
//! parent_span_id:   varint u64   # 0 = none (reserved; v1 spans are flat)
//! flags:            u8           # bit 0: open record; bit 1: external binding
//! status:           u8           # 0 unknown | 1 ok | 2 error
//! start_wall_ns:    varint u64   # UNIX epoch nanoseconds at span start
//! end_wall_ns:      varint u64   # 0 when flags.open is set
//! process_ord:      varint u64   # ordinal into the process table; 0 = primary
//! thread_id:        varint u64
//! start_step:       varint u64   # first step id inside the span
//! end_step:         varint u64   # last step id (0 when open)
//! # flags.external ONLY — span lives in a different container:
//! external_recording: string     # UUIDv7 recording_id
//! external_path:      string     # path relative to this container's directory
//! span_type:        string       # "web-request" | "process" | "test" | ...
//! label:            string       # e.g. "GET /api/users", or an exe path
//! structural:       u8           # bit 0: contiguous_on_one_thread
//!                                # bit 1: shares_timeline
//!                                # bit 2: concurrent_with_siblings
//! metadata_count:   varint
//! metadata:         (key: string, value: string) * metadata_count
//! ```
//!
//! Strings are varint-length-prefixed UTF-8.  Metadata is a flat **ordered**
//! key/value list — write order is part of the contract, so it is a `Vec` of
//! pairs and never a map.
//!
//! # Append-only, last-record-wins
//!
//! A writer MAY append a record with `flags.open` when a request starts, and
//! appends a normal record with the SAME `span_id` when it completes.  Readers
//! apply **last record wins per `span_id`** ([`resolve_spans`]), so the stream
//! stays strictly append-only and a truncated or mid-upload container is always
//! a valid prefix.  [`SpanStreamReader::read_span`] exposes the raw, unresolved
//! record sequence for callers that need it.
//!
//! # Fail-closed decoding
//!
//! [`decode_span_record`] NEVER silently drops or repairs a span.  It rejects
//! truncated fields, trailing bytes inside a record, unknown `flags` bits,
//! unknown `structural` bits, a `status` outside 0..=2, a zero `span_id`, and an
//! open record whose `end_wall_ns` / `end_step` are non-zero.  Any of these fail
//! the whole read rather than yielding a partial span list.

use std::collections::HashMap;

use super::ctfs_container::{CtfsError, CtfsReader};
use super::meta_dat::FLAG_HAS_SPAN_STREAM;

// ── Constants (mirror `span_stream.nim`) ────────────────────────────────

/// Chunked-compressed span records, in append order.
pub const SPANS_DATA_FILE_NAME: &str = "spans.dat";
/// Companion index for [`SPANS_DATA_FILE_NAME`] (v2 layout).
pub const SPANS_INDEX_FILE_NAME: &str = "spans.idx";
/// Interned `span_type` id → span ids namespace.
pub const SPAN_TYPE_NAMESPACE_FILE_NAME: &str = "spantype.ns";

/// `spans.idx` layout version this reader accepts.
///
/// 1 names the never-shipped RS-M1 layout (`[chunk_size u32][offset u64]...`,
/// offsets only, no version field); 2 is the current
/// `[offset u64][cumulative_records u64]` layout.  No container carries bit 13
/// yet, so there is no migration path to write and none is offered — anything
/// but 2 is rejected.
pub const SPANS_INDEX_VERSION: u16 = 2;
/// `[chunk_size u32][index_version u16][reserved u16]` — 8 bytes rather than 4
/// so every entry field lands 8-byte aligned.
pub const SPANS_INDEX_HEADER_SIZE: usize = 8;
/// `[offset u64][cumulative_records u64]` — a FIXED stride, as CTFS §7 requires.
pub const SPANS_INDEX_ENTRY_SIZE: usize = 16;

/// `flags` bit 0 — open record, completion still to come.
const SPAN_FLAG_OPEN: u8 = 0x01;
/// `flags` bit 1 — span lives in a different container.
const SPAN_FLAG_EXTERNAL: u8 = 0x02;
const SPAN_FLAGS_KNOWN: u8 = SPAN_FLAG_OPEN | SPAN_FLAG_EXTERNAL;

/// `structural` bit 0 — the interval is an uninterrupted run on one thread.
const SPAN_STRUCTURAL_CONTIGUOUS: u8 = 0x01;
/// `structural` bit 1 — ordering is comparable with sibling intervals.
const SPAN_STRUCTURAL_SHARES_TIMELINE: u8 = 0x02;
/// `structural` bit 2 — sibling intervals may overlap in time.
const SPAN_STRUCTURAL_CONCURRENT: u8 = 0x04;
const SPAN_STRUCTURAL_KNOWN: u8 =
    SPAN_STRUCTURAL_CONTIGUOUS | SPAN_STRUCTURAL_SHARES_TIMELINE | SPAN_STRUCTURAL_CONCURRENT;

/// ASCII "SPTY" read as a little-endian u32 — the `spantype.ns` magic.
const SPAN_TYPE_NS_MAGIC: u32 = 0x5350_5459;
const SPAN_TYPE_NS_VERSION: u16 = 1;
const SPAN_TYPE_NS_HEADER_SIZE: usize = 18;
const SPAN_TYPE_NS_ENTRY_SIZE: usize = 28;

/// `span_type` of an HTTP request span — the rows the Request Panel renders.
pub const SPAN_TYPE_WEB_REQUEST: &str = "web-request";
/// `span_type` of a process descriptor span (RS-M1b), which replaced the dead
/// `meta.json` process table.
pub const SPAN_TYPE_PROCESS: &str = "process";

// ── Record model ────────────────────────────────────────────────────────

/// Spec §"Record Model" `status` byte.  The discriminants are the wire values.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum SpanStatus {
    /// Wire value 0 — no status recorded (the normal state of an open record).
    #[default]
    Unknown = 0,
    /// Wire value 1 — the interval completed successfully.
    Ok = 1,
    /// Wire value 2 — the interval completed with an error.
    Error = 2,
}

impl SpanStatus {
    /// Map a wire byte to a status, or `None` for a value outside 0..=2.
    fn from_wire(byte: u8) -> Option<SpanStatus> {
        match byte {
            0 => Some(SpanStatus::Unknown),
            1 => Some(SpanStatus::Ok),
            2 => Some(SpanStatus::Error),
            _ => None,
        }
    }
}

/// One interval record.  Field order mirrors the spec's wire layout.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct SpanRecord {
    /// 1-based, monotonic within the container.  The last-record-wins key.
    pub span_id: u64,
    /// 0 = none.  Reserved: v1 spans are flat, so nesting can land later
    /// without a version bump.
    pub parent_span_id: u64,
    /// `flags` bit 0.  The request has started but not finished; `end_wall_ns`
    /// and `end_step` are 0 and `status` is normally [`SpanStatus::Unknown`].
    pub is_open: bool,
    /// `flags` bit 1.  The span's execution lives in a DIFFERENT container,
    /// named by `external_recording` / `external_path`.  This is the fallback
    /// for recordings that genuinely stay separate — it replaces what
    /// `session_manifest.jsonl`'s `trace_dir` does today — not the primary
    /// model; an inline span names a coordinate in THIS container.
    pub is_external: bool,
    /// Completion status.
    pub status: SpanStatus,
    /// UNIX epoch nanoseconds at span start.
    pub start_wall_ns: u64,
    /// UNIX epoch nanoseconds at span end; 0 when `is_open`.
    pub end_wall_ns: u64,
    /// Ordinal into the process table; 0 = primary.
    pub process_ord: u64,
    /// Owning thread id.
    pub thread_id: u64,
    /// First step id inside the span.
    pub start_step: u64,
    /// Last step id inside the span; 0 when `is_open`.
    pub end_step: u64,
    /// UUIDv7 recording id of the container the span's execution lives in;
    /// only present when `is_external`.
    pub external_recording: String,
    /// Path relative to this container's directory; only when `is_external`.
    pub external_path: String,
    /// `"web-request"` | `"process"` | `"test"` | … (an open vocabulary).
    pub span_type: String,
    /// e.g. `"GET /api/users"`, or an executable path for a process span.
    pub label: String,
    /// `structural` bit 0.
    pub contiguous_on_one_thread: bool,
    /// `structural` bit 1.
    pub shares_timeline: bool,
    /// `structural` bit 2.
    pub concurrent_with_siblings: bool,
    /// Flat ORDERED key/value metadata.  Order is preserved on the wire and by
    /// every reader entry point — consumers render metadata in emission order,
    /// so this is a `Vec` of pairs and never a map.
    pub metadata: Vec<(String, String)>,
}

impl SpanRecord {
    /// First value recorded under `key`, or `None`.
    ///
    /// Linear over the metadata list on purpose: span metadata is a handful of
    /// pairs (the spec's well-known-key table has nine rows), so a scan beats
    /// building a map per record — and it preserves the "first wins" semantics
    /// a duplicated key would otherwise resolve arbitrarily.
    pub fn metadata_value(&self, key: &str) -> Option<&str> {
        self.metadata
            .iter()
            .find(|(k, _)| k == key)
            .map(|(_, v)| v.as_str())
    }
}

// ── Varint / string codec ───────────────────────────────────────────────

/// Decode one unsigned LEB128 varint at `*pos`, advancing it past the value.
fn decode_varint(data: &[u8], pos: &mut usize) -> Result<u64, String> {
    let mut result: u64 = 0;
    let mut shift: u32 = 0;
    loop {
        if *pos >= data.len() {
            return Err("span record: truncated varint".to_string());
        }
        let byte = data[*pos];
        *pos += 1;
        result |= u64::from(byte & 0x7F) << shift;
        if byte & 0x80 == 0 {
            return Ok(result);
        }
        shift += 7;
        if shift >= 64 {
            return Err("span record: varint exceeds 10-byte LEB128 maximum".to_string());
        }
    }
}

/// Read a varint-length-prefixed UTF-8 string at `*pos`.
///
/// `what` names the field so a malformed record says which one broke.
fn read_varint_str(data: &[u8], pos: &mut usize, what: &str) -> Result<String, String> {
    let len_u64 = decode_varint(data, pos)?;
    let len = usize::try_from(len_u64).map_err(|_| format!("span record: {what} length {len_u64} does not fit in usize"))?;
    if data.len() - *pos < len {
        return Err(format!("span record: {what} extends past end of record"));
    }
    let start = *pos;
    let s = std::str::from_utf8(&data[start..start + len])
        .map_err(|e| format!("span record: {what} is not valid UTF-8: {e}"))?
        .to_owned();
    *pos += len;
    Ok(s)
}

fn read_u16_le(data: &[u8], off: usize) -> u16 {
    u16::from_le_bytes([data[off], data[off + 1]])
}

fn read_u32_le(data: &[u8], off: usize) -> u32 {
    u32::from_le_bytes([data[off], data[off + 1], data[off + 2], data[off + 3]])
}

fn read_u64_le(data: &[u8], off: usize) -> u64 {
    let mut buf = [0u8; 8];
    buf.copy_from_slice(&data[off..off + 8]);
    u64::from_le_bytes(buf)
}

// ── Per-record decode ───────────────────────────────────────────────────

/// Decode a span from its v1 wire format (the whole record, no length prefix).
///
/// FAIL-CLOSED: every malformation is an error, never a dropped or
/// partially-populated span.  See the module header for the full list.
pub fn decode_span_record(data: &[u8]) -> Result<SpanRecord, String> {
    let mut pos = 0usize;

    let span_id = decode_varint(data, &mut pos)?;
    if span_id == 0 {
        return Err("span record: span_id must be 1-based (got 0)".to_string());
    }
    let parent_span_id = decode_varint(data, &mut pos)?;

    if pos + 2 > data.len() {
        return Err("span record: truncated before flags/status".to_string());
    }
    let flags = data[pos];
    pos += 1;
    if flags & !SPAN_FLAGS_KNOWN != 0 {
        return Err(format!("span record: unknown flags bits set: 0x{flags:02X}"));
    }
    let is_open = flags & SPAN_FLAG_OPEN != 0;
    let is_external = flags & SPAN_FLAG_EXTERNAL != 0;

    let status_byte = data[pos];
    pos += 1;
    let status =
        SpanStatus::from_wire(status_byte).ok_or_else(|| format!("span record: invalid status value {status_byte}"))?;

    let start_wall_ns = decode_varint(data, &mut pos)?;
    let end_wall_ns = decode_varint(data, &mut pos)?;

    let process_ord = decode_varint(data, &mut pos)?;
    let thread_id = decode_varint(data, &mut pos)?;
    let start_step = decode_varint(data, &mut pos)?;
    let end_step = decode_varint(data, &mut pos)?;

    if is_open && (end_wall_ns != 0 || end_step != 0) {
        return Err(format!(
            "span record: open span {span_id} must have end_wall_ns and end_step == 0"
        ));
    }

    // The two external-binding strings are present ONLY when flags.external is
    // set, per the spec's `# flags.external only` annotation.
    let (external_recording, external_path) = if is_external {
        (
            read_varint_str(data, &mut pos, "external_recording")?,
            read_varint_str(data, &mut pos, "external_path")?,
        )
    } else {
        (String::new(), String::new())
    };

    let span_type = read_varint_str(data, &mut pos, "span_type")?;
    let label = read_varint_str(data, &mut pos, "label")?;

    if pos + 1 > data.len() {
        return Err("span record: truncated before structural byte".to_string());
    }
    let structural = data[pos];
    pos += 1;
    if structural & !SPAN_STRUCTURAL_KNOWN != 0 {
        return Err(format!("span record: unknown structural bits set: 0x{structural:02X}"));
    }

    let meta_count = decode_varint(data, &mut pos)?;
    let mut metadata = Vec::new();
    for _ in 0..meta_count {
        let k = read_varint_str(data, &mut pos, "metadata key")?;
        let v = read_varint_str(data, &mut pos, "metadata value")?;
        metadata.push((k, v));
    }

    if pos != data.len() {
        return Err(format!("span record: {} trailing bytes after record", data.len() - pos));
    }
    Ok(SpanRecord {
        span_id,
        parent_span_id,
        is_open,
        is_external,
        status,
        start_wall_ns,
        end_wall_ns,
        process_ord,
        thread_id,
        start_step,
        end_step,
        external_recording,
        external_path,
        span_type,
        label,
        contiguous_on_one_thread: structural & SPAN_STRUCTURAL_CONTIGUOUS != 0,
        shares_timeline: structural & SPAN_STRUCTURAL_SHARES_TIMELINE != 0,
        concurrent_with_siblings: structural & SPAN_STRUCTURAL_CONCURRENT != 0,
        metadata,
    })
}

// ── Zstd chunk decode ───────────────────────────────────────────────────

#[cfg(not(target_arch = "wasm32"))]
fn decode_zstd_chunk(compressed: &[u8]) -> Result<Vec<u8>, String> {
    zstd::decode_all(std::io::Cursor::new(compressed)).map_err(|e| format!("spans.dat: zstd decode failed: {e}"))
}

#[cfg(target_arch = "wasm32")]
fn decode_zstd_chunk(compressed: &[u8]) -> Result<Vec<u8>, String> {
    use std::io::Read;

    let mut decoder = ruzstd::decoding::StreamingDecoder::new(std::io::Cursor::new(compressed))
        .map_err(|e| format!("spans.dat: zstd decode failed: {e}"))?;
    let mut raw = Vec::new();
    decoder
        .read_to_end(&mut raw)
        .map_err(|e| format!("spans.dat: zstd decode failed: {e}"))?;
    Ok(raw)
}

/// Compressed byte length of the FIRST zstd frame starting at `data`.
///
/// The Nim reader calls `ZSTD_findFrameCompressedSize` here and the spec
/// mandates it: while a container is being written, `spans.dat` may already
/// carry the leading bytes of the next, not-yet-sealed chunk, and the file size
/// is therefore NOT a safe end offset for the last indexed chunk.
///
/// The wasm build has no libzstd to ask, so it falls back to "the rest of the
/// slice" — the same limitation the sibling wasm stream readers carry
/// (`call_stream_source_wasm`).  That is sound for a finalized container, which
/// is the only thing the browser-replay path ever opens; live tailing (RS-M3) is
/// a native-only surface.
#[cfg(not(target_arch = "wasm32"))]
fn first_frame_compressed_size(data: &[u8]) -> Result<usize, String> {
    zstd_safe::find_frame_compressed_size(data).map_err(|code| {
        format!(
            "spans.dat: cannot determine span chunk frame size (zstd error code {code})"
        )
    })
}

#[cfg(target_arch = "wasm32")]
fn first_frame_compressed_size(data: &[u8]) -> Result<usize, String> {
    Ok(data.len())
}

// ── Reader ──────────────────────────────────────────────────────────────

/// A reader over a container's `spans.dat` / `spans.idx` pair.
///
/// Opening parses the index and decompresses NOTHING; a zstd frame is touched
/// for the first time on the path that actually wants a chunk's records.  A
/// one-chunk cache makes a sequential walk cost one decompression per chunk.
#[derive(Debug)]
pub struct SpanStreamReader {
    /// Raw (still COMPRESSED) `spans.dat` content.
    data: Vec<u8>,
    /// The index header's records-per-chunk field: the writer's seal-at
    /// threshold, and therefore only an upper-bound HINT.
    chunk_size: u32,
    /// Chunk byte offsets — column 1 of `spans.idx`.
    offsets: Vec<u64>,
    /// `cumulative[i]` = span records held by chunks `0..=i` — column 2 of
    /// `spans.idx`, read verbatim off the wire.  Nothing here is derived by
    /// decoding `spans.dat`.
    cumulative: Vec<u64>,
    /// Index of the chunk currently held in `cached_records`, if any.
    cached_chunk_idx: Option<usize>,
    /// The cached chunk's raw (still-encoded) records.
    cached_records: Vec<Vec<u8>>,
    /// TEST SEAM.  Counts zstd frame decompressions performed by this reader.
    ///
    /// The whole point of the `spans.idx` cumulative column is that opening a
    /// stream, counting its records and addressing a record all cost ZERO chunk
    /// decompressions, and that `read_span` costs exactly one.  Those are
    /// performance PROPERTIES: the functional results are identical either way,
    /// which is precisely how RS-M1's eager-decode cost went unnoticed.  Nothing
    /// in this module reads the counter, so no production path can branch on it.
    chunk_decompressions: u64,
}

/// Whether a parsed `meta.dat` payload declares the span stream (bit 13).
///
/// Callers gate on this rather than on the presence of `spans.dat`: the flag is
/// the container's own declaration, and a container that sets it but omits the
/// files is corrupt, not span-free.
pub fn meta_dat_has_span_stream(meta: &[u8]) -> bool {
    // Deliberately routed through the FULL parser rather than peeking at the
    // 8-byte header.  `parse_meta_dat` rejects any container carrying a flag
    // bit outside `KNOWN_FLAGS_MASK`, and that refusal must cover the span path
    // too: a container that sets bit 13 *and* some future bit this build does
    // not understand is a container this build has no business reading spans
    // out of.  Peeking at the header would quietly bypass exactly the
    // fail-closed guarantee the mask exists to provide.
    super::meta_dat::parse_meta_dat(meta)
        .map(|m| m.flags & FLAG_HAS_SPAN_STREAM != 0)
        .unwrap_or(false)
}

impl SpanStreamReader {
    /// Open the span stream inside an already-open container.
    ///
    /// Returns `Ok(None)` when the container declares no span stream (bit 13
    /// clear) — the caller then has no spans, which is the normal case for
    /// every recording that is not a server session.  A container that DOES
    /// declare the stream but cannot produce `spans.dat` / `spans.idx` is an
    /// error, not a silent `None`: the declaration is the container's own claim
    /// and breaking it means the file is damaged.
    pub fn open_from_ctfs(ctfs: &mut CtfsReader) -> Result<Option<SpanStreamReader>, String> {
        let meta = match ctfs.read_file("meta.dat") {
            Ok(meta) => meta,
            // A container with no meta.dat cannot declare bit 13, so it has no
            // span stream by construction.
            Err(CtfsError::FileNotFound(_)) => return Ok(None),
            Err(e) => return Err(format!("spans: failed to read meta.dat: {e}")),
        };
        if !meta_dat_has_span_stream(&meta) {
            return Ok(None);
        }
        let dat = ctfs
            .read_file(SPANS_DATA_FILE_NAME)
            .map_err(|e| format!("{SPANS_DATA_FILE_NAME} missing despite meta.dat bit 13: {e}"))?;
        let idx = ctfs
            .read_file(SPANS_INDEX_FILE_NAME)
            .map_err(|e| format!("{SPANS_INDEX_FILE_NAME} missing despite meta.dat bit 13: {e}"))?;
        Ok(Some(SpanStreamReader::from_files(dat, &idx)?))
    }

    /// Build a reader from the raw `spans.dat` and `spans.idx` bytes.
    ///
    /// Works equally on a finalized container and on one that is still being
    /// written — re-opening a growing container is exactly how a live consumer
    /// observes new chunks (RS-M3).  Cost is O(C) in the chunk count for the
    /// index parse and its validation, and independent of the number of span
    /// records: **nothing is decompressed here**.
    pub fn from_files(dat: Vec<u8>, idx: &[u8]) -> Result<SpanStreamReader, String> {
        if idx.len() < SPANS_INDEX_HEADER_SIZE {
            return Err(format!("{SPANS_INDEX_FILE_NAME} too small for its header"));
        }
        let chunk_size = read_u32_le(idx, 0);
        if chunk_size == 0 {
            return Err(format!("chunkSize in {SPANS_INDEX_FILE_NAME} is 0"));
        }
        let version = read_u16_le(idx, 4);
        if version != SPANS_INDEX_VERSION {
            return Err(format!(
                "{SPANS_INDEX_FILE_NAME}: unsupported index version {version} \
                 (this build reads version {SPANS_INDEX_VERSION})"
            ));
        }
        // `reserved` must be 0, so a later header field cannot be silently
        // ignored by this reader.
        if read_u16_le(idx, 6) != 0 {
            return Err(format!("{SPANS_INDEX_FILE_NAME}: reserved header field is not 0"));
        }

        let entry_region_bytes = idx.len() - SPANS_INDEX_HEADER_SIZE;
        if !entry_region_bytes.is_multiple_of(SPANS_INDEX_ENTRY_SIZE) {
            return Err(format!(
                "{SPANS_INDEX_FILE_NAME} has trailing bytes in the entry region"
            ));
        }
        let num_chunks = entry_region_bytes / SPANS_INDEX_ENTRY_SIZE;
        let mut offsets = Vec::with_capacity(num_chunks);
        let mut cumulative = Vec::with_capacity(num_chunks);
        for i in 0..num_chunks {
            let base = SPANS_INDEX_HEADER_SIZE + i * SPANS_INDEX_ENTRY_SIZE;
            offsets.push(read_u64_le(idx, base));
            cumulative.push(read_u64_le(idx, base + 8));
        }

        // Fail closed on an index that could mis-address a record.  The binary
        // search in `read_span` is only sound on a non-decreasing cumulative
        // column, and `chunk_byte_range` is only sound on non-decreasing,
        // in-bounds offsets — so both are checked here rather than trusted.
        // O(C) in the chunk count, and it reads no chunk bytes.
        let dat_len = dat.len() as u64;
        for i in 0..num_chunks {
            if offsets[i] > dat_len {
                return Err(format!(
                    "{SPANS_INDEX_FILE_NAME}: chunk {i} offset is past the end of {SPANS_DATA_FILE_NAME}"
                ));
            }
            if i > 0 {
                if offsets[i] < offsets[i - 1] {
                    return Err(format!(
                        "{SPANS_INDEX_FILE_NAME}: chunk offsets are not monotonic at entry {i}"
                    ));
                }
                if cumulative[i] < cumulative[i - 1] {
                    return Err(format!(
                        "{SPANS_INDEX_FILE_NAME}: cumulative record counts are not monotonic at entry {i}"
                    ));
                }
            }
        }

        Ok(SpanStreamReader {
            data: dat,
            chunk_size,
            offsets,
            cumulative,
            cached_chunk_idx: None,
            cached_records: Vec::new(),
            chunk_decompressions: 0,
        })
    }

    /// Number of span RECORDS committed to sealed chunks.
    ///
    /// An open record and its later completion are two records; use
    /// [`Self::settled_spans`] for the last-record-wins view.  O(1): the last
    /// index entry's cumulative field IS the total.
    pub fn count(&self) -> u64 {
        self.cumulative.last().copied().unwrap_or(0)
    }

    /// Number of sealed chunks — equivalently, the number of 16-byte entries in
    /// `spans.idx`.  This is the cursor a live consumer remembers between polls
    /// and hands back to [`Self::read_spans_since`].
    pub fn chunk_count(&self) -> usize {
        self.offsets.len()
    }

    /// The `spans.idx` header's records-per-chunk field.
    ///
    /// The writer's seal-at threshold, and therefore only an UPPER-BOUND HINT —
    /// a chunk sealed early by `flush` holds fewer, so this can never be used to
    /// locate a record.  It survives as a hint because it still bounds what a
    /// chunk fetch can cost.  Use [`Self::records_in_chunk`] for a chunk's
    /// actual count.
    pub fn chunk_size_records(&self) -> u32 {
        self.chunk_size
    }

    /// Append-order index of chunk `chunk_number`'s first record — the exclusive
    /// prefix total, i.e. the previous entry's cumulative field.  O(1).
    pub fn first_record_of_chunk(&self, chunk_number: usize) -> u64 {
        if chunk_number == 0 {
            0
        } else if chunk_number > self.cumulative.len() {
            self.count()
        } else {
            self.cumulative[chunk_number - 1]
        }
    }

    /// Records actually held by chunk `chunk_number`, straight out of the
    /// index — the difference of two adjacent cumulative fields.  0 for an
    /// out-of-range chunk.  O(1), and it decompresses nothing.
    pub fn records_in_chunk(&self, chunk_number: usize) -> u64 {
        if chunk_number >= self.cumulative.len() {
            return 0;
        }
        self.cumulative[chunk_number] - self.first_record_of_chunk(chunk_number)
    }

    /// Number of zstd frames this reader has decompressed since it was opened.
    ///
    /// See the note on the `chunk_decompressions` field: this exists so tests
    /// can pin the "open decodes nothing / `read_span` decodes one chunk"
    /// properties, which are otherwise invisible.
    pub fn chunk_decompressions(&self) -> u64 {
        self.chunk_decompressions
    }

    /// The `[start, end)` byte range of chunk `chunk_number` in `spans.dat`.
    ///
    /// For any chunk but the last indexed one the end is simply the next index
    /// entry.  For the LAST indexed chunk the file size is NOT a safe end:
    /// while the container is still being written, `spans.dat` may already hold
    /// the leading bytes of the next, not-yet-sealed chunk.  We ask zstd for the
    /// exact frame length instead, so a tailing read decodes the same bytes a
    /// finalized read would.
    fn chunk_byte_range(&self, chunk_number: usize) -> Result<(usize, usize), String> {
        if chunk_number >= self.offsets.len() {
            return Err(format!(
                "span chunk {chunk_number} out of range (have {} chunks)",
                self.offsets.len()
            ));
        }
        let start_off = self.offsets[chunk_number] as usize;
        if start_off > self.data.len() {
            return Err(format!("span chunk offset past end of {SPANS_DATA_FILE_NAME}"));
        }
        if chunk_number + 1 < self.offsets.len() {
            let end_off = self.offsets[chunk_number + 1] as usize;
            if end_off < start_off || end_off > self.data.len() {
                return Err("span chunk offsets out of range".to_string());
            }
            return Ok((start_off, end_off));
        }
        if start_off == self.data.len() {
            return Ok((start_off, start_off));
        }
        let frame_len = first_frame_compressed_size(&self.data[start_off..])?;
        let end_off = start_off + frame_len;
        if end_off > self.data.len() {
            return Err(format!(
                "span chunk frame extends past end of {SPANS_DATA_FILE_NAME}"
            ));
        }
        Ok((start_off, end_off))
    }

    /// Decompress one chunk and split it into its length-prefixed records.
    fn decode_chunk(&mut self, chunk_number: usize) -> Result<Vec<Vec<u8>>, String> {
        let (start_off, end_off) = self.chunk_byte_range(chunk_number)?;
        if start_off == end_off {
            return Ok(Vec::new());
        }
        self.chunk_decompressions += 1;
        let raw = decode_zstd_chunk(&self.data[start_off..end_off])?;
        let mut records = Vec::new();
        let mut pos = 0usize;
        while pos < raw.len() {
            let rec_len_u64 = decode_varint(&raw, &mut pos)?;
            let rec_len = usize::try_from(rec_len_u64)
                .map_err(|_| format!("span record length {rec_len_u64} does not fit in usize"))?;
            if raw.len() - pos < rec_len {
                return Err("span record length extends past chunk".to_string());
            }
            records.push(raw[pos..pos + rec_len].to_vec());
            pos += rec_len;
        }
        Ok(records)
    }

    /// Read the raw span record at `index` in append order, decompressing only
    /// its chunk.  Records are NOT resolved by last-record-wins here.
    ///
    /// O(log C) in the chunk count: a binary search over the index's cumulative
    /// column locates the owning chunk without touching `spans.dat`, and then
    /// exactly ONE zstd frame is decompressed (none at all when the chunk is
    /// already cached, which is the common case for a sequential walk).
    ///
    /// The owning chunk comes from that column, NOT from `index / chunk_size` —
    /// a `flush` mid-recording seals a short chunk, after which the two disagree
    /// for every later record.
    pub fn read_span(&mut self, index: u64) -> Result<SpanRecord, String> {
        let total = self.count();
        if index >= total {
            return Err(format!("span index {index} out of range (count {total})"));
        }
        // The first chunk whose cumulative total EXCEEDS `index` is the one
        // holding it.  `partition_point(<= index)` returns the number of leading
        // entries that are <= index, i.e. the index of the first entry strictly
        // greater — exactly that chunk.  An empty chunk repeats its
        // predecessor's total and is therefore skipped, as it must be.
        // `index < total` guarantees a hit.
        let chunk_number = self.cumulative.partition_point(|&c| c <= index);
        if chunk_number >= self.cumulative.len() {
            return Err(format!("span index {index} has no owning chunk"));
        }
        let within = usize::try_from(index - self.first_record_of_chunk(chunk_number))
            .map_err(|_| format!("span index {index} offset within chunk does not fit in usize"))?;

        if self.cached_chunk_idx != Some(chunk_number) {
            let recs = self.decode_chunk(chunk_number)?;
            self.cached_records = recs;
            self.cached_chunk_idx = Some(chunk_number);
        }

        let rec = self
            .cached_records
            .get(within)
            .ok_or_else(|| format!("span record {within} missing in chunk {chunk_number}"))?;
        decode_span_record(rec)
    }

    /// Decode every record in chunks `[from_chunk, to_chunk)`, in append order.
    /// Records are raw — apply [`resolve_spans`] for the settled view.
    pub fn read_spans_in_chunks(&mut self, from_chunk: usize, to_chunk: usize) -> Result<Vec<SpanRecord>, String> {
        if to_chunk > self.offsets.len() || from_chunk > to_chunk {
            return Err(format!(
                "span chunk range [{from_chunk}, {to_chunk}) out of range (have {} chunks)",
                self.offsets.len()
            ));
        }
        let mut spans = Vec::new();
        for c in from_chunk..to_chunk {
            for rec in self.decode_chunk(c)? {
                spans.push(decode_span_record(&rec)?);
            }
        }
        Ok(spans)
    }

    /// The tailing primitive (RS-M3): decode ONLY the chunks sealed since the
    /// caller last looked, identified by the companion-index length it saw then.
    /// Returns them in append order; the new cursor is [`Self::chunk_count`].
    ///
    /// Cost is proportional to the DELTA, not to the stream, and an up-to-date
    /// cursor decompresses nothing.
    pub fn read_spans_since(&mut self, known_chunk_count: usize) -> Result<Vec<SpanRecord>, String> {
        if known_chunk_count > self.offsets.len() {
            return Err(format!(
                "knownChunkCount {known_chunk_count} exceeds current chunk count {} (the index cannot shrink)",
                self.offsets.len()
            ));
        }
        self.read_spans_in_chunks(known_chunk_count, self.offsets.len())
    }

    /// Every committed span record, raw, in append order.
    pub fn read_all_span_records(&mut self) -> Result<Vec<SpanRecord>, String> {
        self.read_spans_in_chunks(0, self.offsets.len())
    }

    /// Every span in the container, last-record-wins applied, ascending by
    /// `span_id`.
    pub fn settled_spans(&mut self) -> Result<Vec<SpanRecord>, String> {
        Ok(resolve_spans(self.read_all_span_records()?))
    }
}

/// Apply **last record wins per `span_id`** to a raw record sequence and return
/// the settled spans ascending by `span_id`.
///
/// An open record followed by its completion yields exactly one span — the
/// completion.  This is what makes the append-only stream renderable: the panel
/// shows a greyed in-flight row that settles when the request finishes, and a
/// reader that sees both records must never show two.
pub fn resolve_spans(records: Vec<SpanRecord>) -> Vec<SpanRecord> {
    let mut by_span_id: HashMap<u64, SpanRecord> = HashMap::with_capacity(records.len());
    for rec in records {
        by_span_id.insert(rec.span_id, rec);
    }
    let mut settled: Vec<SpanRecord> = by_span_id.into_values().collect();
    settled.sort_by_key(|s| s.span_id);
    settled
}

// ── `spantype.ns` ───────────────────────────────────────────────────────

/// One `spantype.ns` entry: an interned span-type id, its name, and the span
/// ids of that type in ascending order.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SpanTypeEntry {
    /// Interned id, assigned in first-appearance order by the writer.
    pub type_id: u32,
    /// The `span_type` string (`"web-request"`, `"process"`, …).
    pub name: String,
    /// The DISTINCT span ids recorded under this type, ascending.
    pub span_ids: Vec<u64>,
}

/// Parse a `spantype.ns` image (`SPTY` wire format, version 1).
///
/// ```text
/// Header (18 bytes):
///   [magic u32 = "SPTY"][version u16 = 1][type_count u32][type_table_offset u64]
/// Type table (at type_table_offset), sorted by span_type_id, 28 bytes each:
///   [span_type_id u32][name_len u32][name_offset u64][span_count u32][spans_offset u64]
/// Name bytes (at name_offset): name_len UTF-8 bytes, no terminator.
/// Span-id lists (at spans_offset): span_count x u64 LE, ascending.
/// ```
///
/// The namespace exists so a reader that only wants the processes (or only the
/// tests) fetches a handful of ids instead of scanning a million request
/// records.  Fail-closed on any out-of-bounds offset.
pub fn parse_span_type_namespace(data: &[u8]) -> Result<Vec<SpanTypeEntry>, String> {
    if data.len() < SPAN_TYPE_NS_HEADER_SIZE {
        return Err(format!("spantype.ns too short: {} bytes", data.len()));
    }
    if read_u32_le(data, 0) != SPAN_TYPE_NS_MAGIC {
        return Err("spantype.ns: bad magic".to_string());
    }
    let version = read_u16_le(data, 4);
    if version != SPAN_TYPE_NS_VERSION {
        return Err(format!("spantype.ns: unsupported version {version}"));
    }
    let type_count = read_u32_le(data, 6) as usize;
    let table_off = read_u64_le(data, 10) as usize;
    if table_off < SPAN_TYPE_NS_HEADER_SIZE
        || table_off
            .checked_add(type_count.saturating_mul(SPAN_TYPE_NS_ENTRY_SIZE))
            .is_none_or(|end| end > data.len())
    {
        return Err("spantype.ns: type table out of bounds".to_string());
    }

    let mut entries = Vec::with_capacity(type_count);
    for i in 0..type_count {
        let base = table_off + i * SPAN_TYPE_NS_ENTRY_SIZE;
        let type_id = read_u32_le(data, base);
        let name_len = read_u32_le(data, base + 4) as usize;
        let name_off = read_u64_le(data, base + 8) as usize;
        let span_count = read_u32_le(data, base + 16) as usize;
        let spans_off = read_u64_le(data, base + 20) as usize;
        if name_off.checked_add(name_len).is_none_or(|end| end > data.len()) {
            return Err(format!("spantype.ns: name out of bounds for type {type_id}"));
        }
        if spans_off
            .checked_add(span_count.saturating_mul(8))
            .is_none_or(|end| end > data.len())
        {
            return Err(format!("spantype.ns: span id list out of bounds for type {type_id}"));
        }
        let name = std::str::from_utf8(&data[name_off..name_off + name_len])
            .map_err(|e| format!("spantype.ns: type {type_id} name is not valid UTF-8: {e}"))?
            .to_owned();
        let mut span_ids = Vec::with_capacity(span_count);
        for j in 0..span_count {
            span_ids.push(read_u64_le(data, spans_off + j * 8));
        }
        entries.push(SpanTypeEntry {
            type_id,
            name,
            span_ids,
        });
    }
    Ok(entries)
}

/// Read and parse `spantype.ns` out of an open container.
///
/// Returns `Ok(None)` when the container carries no span-type namespace — which
/// is every container that does not declare bit 13.
pub fn read_span_type_namespace(ctfs: &mut CtfsReader) -> Result<Option<Vec<SpanTypeEntry>>, String> {
    match ctfs.read_file(SPAN_TYPE_NAMESPACE_FILE_NAME) {
        Ok(raw) => parse_span_type_namespace(&raw).map(Some),
        Err(CtfsError::FileNotFound(_)) => Ok(None),
        Err(e) => Err(format!("failed to read {SPAN_TYPE_NAMESPACE_FILE_NAME}: {e}")),
    }
}

/// The span ids recorded under `span_type`, or an empty slice when the
/// container holds no spans of that type.
pub fn span_ids_of_type<'a>(entries: &'a [SpanTypeEntry], span_type: &str) -> &'a [u64] {
    entries
        .iter()
        .find(|e| e.name == span_type)
        .map(|e| e.span_ids.as_slice())
        .unwrap_or(&[])
}

// ── Tests ───────────────────────────────────────────────────────────────

#[cfg(test)]
#[allow(clippy::unwrap_used, clippy::expect_used, clippy::panic)]
mod tests {
    use super::*;

    /// Encode a span into the v1 wire format.
    ///
    /// Test-only mirror of the Nim writer's `encodeSpanRecord`, so the unit
    /// tests below can exercise the decoder's fail-closed paths on
    /// deliberately-malformed bytes.  The INTEGRATION proof that this agrees
    /// with the real writer lives in
    /// `tests/span_stream_request_spans_test.rs`, which reads containers the
    /// Nim writer produced — this helper is never used for that.
    fn encode_span_record(s: &SpanRecord) -> Vec<u8> {
        fn put_varint(v: u64, out: &mut Vec<u8>) {
            let mut v = v;
            loop {
                let mut byte = (v & 0x7F) as u8;
                v >>= 7;
                if v != 0 {
                    byte |= 0x80;
                }
                out.push(byte);
                if v == 0 {
                    break;
                }
            }
        }
        fn put_str(s: &str, out: &mut Vec<u8>) {
            put_varint(s.len() as u64, out);
            out.extend_from_slice(s.as_bytes());
        }

        let mut buf = Vec::new();
        put_varint(s.span_id, &mut buf);
        put_varint(s.parent_span_id, &mut buf);
        let mut flags = 0u8;
        if s.is_open {
            flags |= SPAN_FLAG_OPEN;
        }
        if s.is_external {
            flags |= SPAN_FLAG_EXTERNAL;
        }
        buf.push(flags);
        buf.push(s.status as u8);
        put_varint(s.start_wall_ns, &mut buf);
        put_varint(s.end_wall_ns, &mut buf);
        put_varint(s.process_ord, &mut buf);
        put_varint(s.thread_id, &mut buf);
        put_varint(s.start_step, &mut buf);
        put_varint(s.end_step, &mut buf);
        if s.is_external {
            put_str(&s.external_recording, &mut buf);
            put_str(&s.external_path, &mut buf);
        }
        put_str(&s.span_type, &mut buf);
        put_str(&s.label, &mut buf);
        let mut structural = 0u8;
        if s.contiguous_on_one_thread {
            structural |= SPAN_STRUCTURAL_CONTIGUOUS;
        }
        if s.shares_timeline {
            structural |= SPAN_STRUCTURAL_SHARES_TIMELINE;
        }
        if s.concurrent_with_siblings {
            structural |= SPAN_STRUCTURAL_CONCURRENT;
        }
        buf.push(structural);
        put_varint(s.metadata.len() as u64, &mut buf);
        for (k, v) in &s.metadata {
            put_str(k, &mut buf);
            put_str(v, &mut buf);
        }
        buf
    }

    fn sample_span(span_id: u64) -> SpanRecord {
        SpanRecord {
            span_id,
            parent_span_id: 0,
            is_open: false,
            is_external: false,
            status: SpanStatus::Ok,
            start_wall_ns: 1_700_000_000_000_000_000 + span_id * 1_000_000,
            end_wall_ns: 1_700_000_000_000_000_000 + span_id * 1_000_000 + 12_000_000,
            process_ord: 0,
            thread_id: 7,
            start_step: span_id * 100,
            end_step: span_id * 100 + 50,
            external_recording: String::new(),
            external_path: String::new(),
            span_type: SPAN_TYPE_WEB_REQUEST.to_string(),
            label: format!("GET /api/{span_id}"),
            contiguous_on_one_thread: true,
            shares_timeline: true,
            concurrent_with_siblings: false,
            metadata: vec![
                ("http.method".to_string(), "GET".to_string()),
                ("http.url".to_string(), format!("/api/{span_id}")),
                ("http.status_code".to_string(), "200".to_string()),
                ("http.duration_ms".to_string(), "12".to_string()),
            ],
        }
    }

    #[test]
    fn decodes_every_wire_field_including_metadata_order() {
        let mut span = sample_span(3);
        // Deliberately non-alphabetical so an order-losing decoder fails.
        span.metadata = vec![
            ("http.url".to_string(), "/z".to_string()),
            ("http.method".to_string(), "POST".to_string()),
            ("framework".to_string(), "flask".to_string()),
        ];
        let decoded = decode_span_record(&encode_span_record(&span)).expect("decode");
        assert_eq!(decoded, span);
    }

    #[test]
    fn decodes_external_binding_strings_only_when_flagged() {
        let mut span = sample_span(4);
        span.is_external = true;
        span.external_recording = "01949fcc-7d92-7e9c-cccc-dddddddddddd".to_string();
        span.external_path = "requests/req-0002.ct".to_string();
        let decoded = decode_span_record(&encode_span_record(&span)).expect("decode");
        assert_eq!(decoded.external_recording, span.external_recording);
        assert_eq!(decoded.external_path, span.external_path);

        // A non-external span's bytes carry no binding strings at all.
        let inline = sample_span(5);
        let decoded_inline = decode_span_record(&encode_span_record(&inline)).expect("decode");
        assert!(decoded_inline.external_recording.is_empty());
        assert!(decoded_inline.external_path.is_empty());
    }

    #[test]
    fn rejects_zero_span_id() {
        let mut span = sample_span(1);
        span.span_id = 0;
        let err = decode_span_record(&encode_span_record(&span)).expect_err("must reject");
        assert!(err.contains("1-based"), "unexpected error: {err}");
    }

    #[test]
    fn rejects_unknown_flag_and_structural_bits() {
        let mut bytes = encode_span_record(&sample_span(1));
        // flags byte sits after two single-byte varints (span_id=1, parent=0).
        bytes[2] = 0x04;
        let err = decode_span_record(&bytes).expect_err("must reject unknown flags");
        assert!(err.contains("unknown flags"), "unexpected error: {err}");

        // With empty metadata the record ends `...[structural u8][meta_count=0]`,
        // so the structural byte is the second-to-last one.
        let mut span = sample_span(1);
        span.metadata.clear();
        let mut bytes = encode_span_record(&span);
        let structural_pos = bytes.len() - 2;
        assert_eq!(bytes[structural_pos], 0x03, "structural byte not where expected");
        bytes[structural_pos] = 0x08;
        let err = decode_span_record(&bytes).expect_err("must reject unknown structural bits");
        assert!(err.contains("unknown structural"), "unexpected error: {err}");
    }

    #[test]
    fn rejects_open_record_with_non_zero_end_fields() {
        let mut span = sample_span(1);
        span.is_open = true;
        // end_wall_ns / end_step stay populated — the spec requires them to be 0.
        let err = decode_span_record(&encode_span_record(&span)).expect_err("must reject");
        assert!(err.contains("must have end_wall_ns"), "unexpected error: {err}");
    }

    #[test]
    fn rejects_trailing_bytes_inside_a_record() {
        let mut bytes = encode_span_record(&sample_span(1));
        bytes.push(0x00);
        let err = decode_span_record(&bytes).expect_err("must reject");
        assert!(err.contains("trailing bytes"), "unexpected error: {err}");
    }

    #[test]
    fn rejects_invalid_status_byte() {
        let mut bytes = encode_span_record(&sample_span(1));
        bytes[3] = 9;
        let err = decode_span_record(&bytes).expect_err("must reject");
        assert!(err.contains("invalid status"), "unexpected error: {err}");
    }

    /// Build a `spans.dat` / `spans.idx` pair with EXPLICIT per-chunk record
    /// counts, including short and empty chunks, so the reader's addressing is
    /// exercised against a stream `chunk_size` cannot describe.
    fn build_stream(chunk_size: u32, chunks: &[Vec<SpanRecord>]) -> (Vec<u8>, Vec<u8>) {
        let mut dat = Vec::new();
        let mut idx = Vec::new();
        idx.extend_from_slice(&chunk_size.to_le_bytes());
        idx.extend_from_slice(&SPANS_INDEX_VERSION.to_le_bytes());
        idx.extend_from_slice(&0u16.to_le_bytes());
        let mut cumulative = 0u64;
        for chunk in chunks {
            let offset = dat.len() as u64;
            let mut payload = Vec::new();
            for rec in chunk {
                let bytes = encode_span_record(rec);
                let mut len_prefix = Vec::new();
                let mut v = bytes.len() as u64;
                loop {
                    let mut byte = (v & 0x7F) as u8;
                    v >>= 7;
                    if v != 0 {
                        byte |= 0x80;
                    }
                    len_prefix.push(byte);
                    if v == 0 {
                        break;
                    }
                }
                payload.extend_from_slice(&len_prefix);
                payload.extend_from_slice(&bytes);
            }
            dat.extend_from_slice(&zstd::encode_all(std::io::Cursor::new(&payload), 3).expect("compress"));
            cumulative += chunk.len() as u64;
            idx.extend_from_slice(&offset.to_le_bytes());
            idx.extend_from_slice(&cumulative.to_le_bytes());
        }
        (dat, idx)
    }

    #[test]
    fn open_decompresses_nothing_and_count_is_index_only() {
        let chunks = vec![
            (1..=5).map(sample_span).collect::<Vec<_>>(),
            (6..=7).map(sample_span).collect::<Vec<_>>(),
            (8..=20).map(sample_span).collect::<Vec<_>>(),
        ];
        let (dat, idx) = build_stream(64, &chunks);
        let reader = SpanStreamReader::from_files(dat, &idx).expect("open");
        assert_eq!(reader.count(), 20);
        assert_eq!(reader.chunk_count(), 3);
        assert_eq!(reader.records_in_chunk(0), 5);
        assert_eq!(reader.records_in_chunk(1), 2);
        assert_eq!(reader.records_in_chunk(2), 13);
        assert_eq!(reader.first_record_of_chunk(2), 7);
        // The whole point of the v2 cumulative column.
        assert_eq!(reader.chunk_decompressions(), 0, "open must decode nothing");
    }

    /// The chunks here are deliberately SHORT relative to `chunk_size = 64`, so
    /// a reader that computed `index / chunk_size` would address chunk 0 for
    /// every record and silently return the wrong span.
    #[test]
    fn read_span_binary_searches_cumulative_not_chunk_size() {
        let chunks = vec![
            (1..=3).map(sample_span).collect::<Vec<_>>(),
            Vec::new(), // an empty chunk repeats its predecessor's total
            (4..=9).map(sample_span).collect::<Vec<_>>(),
            (10..=10).map(sample_span).collect::<Vec<_>>(),
        ];
        let (dat, idx) = build_stream(64, &chunks);
        let mut reader = SpanStreamReader::from_files(dat, &idx).expect("open");
        assert_eq!(reader.count(), 10);
        for i in 0..10u64 {
            let got = reader.read_span(i).expect("read");
            assert_eq!(got.span_id, i + 1, "record {i} came from the wrong chunk");
        }
        assert!(reader.read_span(10).is_err(), "out-of-range index must fail");
    }

    #[test]
    fn read_span_decompresses_exactly_one_chunk_and_caches_it() {
        let chunks = vec![
            (1..=4).map(sample_span).collect::<Vec<_>>(),
            (5..=8).map(sample_span).collect::<Vec<_>>(),
        ];
        let (dat, idx) = build_stream(4, &chunks);
        let mut reader = SpanStreamReader::from_files(dat, &idx).expect("open");
        reader.read_span(0).expect("read");
        assert_eq!(reader.chunk_decompressions(), 1);
        // Same chunk — served from the one-chunk cache.
        reader.read_span(3).expect("read");
        assert_eq!(reader.chunk_decompressions(), 1);
        // Different chunk — exactly one more frame.
        reader.read_span(4).expect("read");
        assert_eq!(reader.chunk_decompressions(), 2);
    }

    #[test]
    fn read_spans_since_decodes_only_the_delta() {
        let chunks = vec![
            (1..=4).map(sample_span).collect::<Vec<_>>(),
            (5..=8).map(sample_span).collect::<Vec<_>>(),
            (9..=12).map(sample_span).collect::<Vec<_>>(),
        ];
        let (dat, idx) = build_stream(4, &chunks);
        let mut reader = SpanStreamReader::from_files(dat, &idx).expect("open");
        let delta = reader.read_spans_since(2).expect("tail");
        assert_eq!(delta.len(), 4);
        assert_eq!(delta[0].span_id, 9);
        assert_eq!(reader.chunk_decompressions(), 1, "only the new chunk may be decoded");
        // An up-to-date cursor decompresses nothing at all.
        let empty = reader.read_spans_since(3).expect("tail");
        assert!(empty.is_empty());
        assert_eq!(reader.chunk_decompressions(), 1);
        assert!(reader.read_spans_since(4).is_err(), "index cannot shrink");
    }

    #[test]
    fn last_record_wins_per_span_id() {
        let mut open = sample_span(2);
        open.is_open = true;
        open.end_wall_ns = 0;
        open.end_step = 0;
        open.status = SpanStatus::Unknown;
        let completed = sample_span(2);
        let chunks = vec![vec![sample_span(1), open], vec![completed.clone(), sample_span(3)]];
        let (dat, idx) = build_stream(64, &chunks);
        let mut reader = SpanStreamReader::from_files(dat, &idx).expect("open");
        assert_eq!(reader.count(), 4, "raw records are counted separately");
        let settled = reader.settled_spans().expect("settle");
        assert_eq!(settled.len(), 3, "the open record must be superseded");
        assert_eq!(settled.iter().map(|s| s.span_id).collect::<Vec<_>>(), vec![1, 2, 3]);
        assert_eq!(settled[1], completed, "the completion must win");
    }

    #[test]
    fn rejects_index_with_bad_version_reserved_or_stride() {
        let chunks = vec![(1..=2).map(sample_span).collect::<Vec<_>>()];
        let (dat, idx) = build_stream(64, &chunks);

        let mut bad_version = idx.clone();
        bad_version[4] = 1;
        assert!(
            SpanStreamReader::from_files(dat.clone(), &bad_version)
                .expect_err("v1 must be rejected")
                .contains("unsupported index version")
        );

        let mut bad_reserved = idx.clone();
        bad_reserved[6] = 1;
        assert!(
            SpanStreamReader::from_files(dat.clone(), &bad_reserved)
                .expect_err("non-zero reserved must be rejected")
                .contains("reserved header field")
        );

        let mut bad_stride = idx.clone();
        bad_stride.push(0);
        assert!(
            SpanStreamReader::from_files(dat.clone(), &bad_stride)
                .expect_err("ragged entry region must be rejected")
                .contains("trailing bytes")
        );

        let mut zero_chunk_size = idx.clone();
        zero_chunk_size[0..4].copy_from_slice(&0u32.to_le_bytes());
        assert!(
            SpanStreamReader::from_files(dat, &zero_chunk_size)
                .expect_err("chunk_size 0 must be rejected")
                .contains("is 0")
        );
    }

    #[test]
    fn rejects_non_monotonic_index_columns() {
        let chunks = vec![
            (1..=2).map(sample_span).collect::<Vec<_>>(),
            (3..=4).map(sample_span).collect::<Vec<_>>(),
        ];
        let (dat, idx) = build_stream(64, &chunks);

        // Second entry's cumulative column walks backwards.
        let mut bad_cumulative = idx.clone();
        let second_cum = SPANS_INDEX_HEADER_SIZE + SPANS_INDEX_ENTRY_SIZE + 8;
        bad_cumulative[second_cum..second_cum + 8].copy_from_slice(&1u64.to_le_bytes());
        assert!(
            SpanStreamReader::from_files(dat.clone(), &bad_cumulative)
                .expect_err("must reject")
                .contains("cumulative record counts are not monotonic")
        );

        // Second entry's offset walks backwards.
        let mut bad_offset = idx.clone();
        let second_off = SPANS_INDEX_HEADER_SIZE + SPANS_INDEX_ENTRY_SIZE;
        bad_offset[second_off..second_off + 8].copy_from_slice(&0u64.to_le_bytes());
        // Entry 0's offset is already 0, so make entry 0 non-zero to force the
        // descent to be observable.
        bad_offset[SPANS_INDEX_HEADER_SIZE..SPANS_INDEX_HEADER_SIZE + 8].copy_from_slice(&1u64.to_le_bytes());
        assert!(
            SpanStreamReader::from_files(dat.clone(), &bad_offset)
                .expect_err("must reject")
                .contains("offsets are not monotonic")
        );

        // An offset past the end of spans.dat.
        let mut past_end = idx;
        past_end[SPANS_INDEX_HEADER_SIZE..SPANS_INDEX_HEADER_SIZE + 8]
            .copy_from_slice(&(dat.len() as u64 + 1).to_le_bytes());
        assert!(
            SpanStreamReader::from_files(dat, &past_end)
                .expect_err("must reject")
                .contains("past the end")
        );
    }

    /// Build a minimal valid v3 `meta.dat` payload with the given flags.
    fn meta_dat_bytes(flags: u16) -> Vec<u8> {
        const TEST_UUID_V7: &str = "01949fcc-7d92-7e9c-aaaa-bbbbbbbbbbbb";
        let mut buf = Vec::new();
        buf.extend_from_slice(&super::super::meta_dat::META_DAT_MAGIC);
        buf.extend_from_slice(&3u16.to_le_bytes());
        buf.extend_from_slice(&flags.to_le_bytes());
        let put_str = |s: &str, out: &mut Vec<u8>| {
            out.push(s.len() as u8);
            out.extend_from_slice(s.as_bytes());
        };
        put_str(TEST_UUID_V7, &mut buf);
        put_str("prog", &mut buf);
        buf.push(0); // args_count
        put_str("/w", &mut buf);
        put_str("php", &mut buf);
        buf.push(0); // paths_count
        buf
    }

    #[test]
    fn meta_dat_span_stream_bit_is_recognised() {
        assert!(meta_dat_has_span_stream(&meta_dat_bytes(FLAG_HAS_SPAN_STREAM)));
        assert!(!meta_dat_has_span_stream(&meta_dat_bytes(0)));
        assert!(!meta_dat_has_span_stream(b"nope"));
    }

    /// Fail-closed: a container that sets bit 13 alongside a bit this build does
    /// not know is not a container this build may read spans out of.  The check
    /// goes through `parse_meta_dat` precisely so `KNOWN_FLAGS_MASK` governs the
    /// span path too.
    #[test]
    fn meta_dat_with_an_unknown_bit_alongside_bit_13_is_refused() {
        const FUTURE_BIT: u16 = 1 << 14;
        assert!(!meta_dat_has_span_stream(&meta_dat_bytes(
            FLAG_HAS_SPAN_STREAM | FUTURE_BIT
        )));
    }
}
