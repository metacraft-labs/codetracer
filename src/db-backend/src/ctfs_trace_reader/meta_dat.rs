//! Pure-Rust parser and serializer for the binary CTFS `meta.dat` format.
//!
//! `meta.dat` is the per-trace metadata file written by recorders into a
//! `.ct` CTFS container. This module provides a WASM-safe reader (and the
//! inverse writer used for tests / in-memory fixtures) so that the
//! db-backend can consume `meta.dat` without going through the Nim FFI
//! reader (`codetracer_trace_writer_nim::MetaDatReader`), which is gated
//! behind the `nim-reader` cargo feature and unavailable in browser builds.
//!
//! # Wire format
//!
//! The canonical specification lives in
//! `codetracer-specs/Trace-Files/CTFS-Binary-Format.md` §8 and is
//! implemented by the Nim writer at
//! `codetracer-trace-format-nim/src/codetracer_trace_writer/meta_dat.nim`.
//!
//! ```text
//! [4 bytes] magic "CTMD"  (0x43 0x54 0x4D 0x44)
//! [2 bytes] version u16 little-endian (6; see [`SUPPORTED_VERSIONS`])
//! [2 bytes] flags u16 little-endian
//!           bit 0       — FLAG_HAS_MCR_FIELDS
//!           bit 1       — FLAG_HAS_REPLAY_LAUNCH_FIELDS (M-RLP-1, §6A.5)
//!           bit 2       — FLAG_HAS_LAYOUT_SNAPSHOT (M-RLP-2, §6B.7)
//!           bit 3       — FLAG_HAS_TRACE_FILTER_PROVENANCE (TF-M7, §7)
//!           bit 4       — FLAG_HAS_COLUMN_AWARE_STEPS (P6.3 / P6.4)
//!           bit 5       — FLAG_HAS_ALTERNATE_SOURCE_VIEWS
//!           bit 6       — FLAG_SUPPORTS_COLUMN_BREAKPOINTS (M-capability-flags)
//!           bit 7       — FLAG_SUPPORTS_COLUMN_MOTIONS (M-capability-flags)
//!           bit 8       — FLAG_HAS_CALL_STREAM (M17a/M17b — dedicated calls.dat)
//!           bit 9       — FLAG_HAS_STEP_STREAM (M23a — dedicated steps.dat)
//!           bit 10      — FLAG_HAS_VALUE_STREAM (M23b — dedicated values.dat)
//!           bit 11      — FLAG_HAS_IO_EVENT_STREAM (M23c — dedicated events.dat)
//!           bit 12      — FLAG_HAS_INTERNING_TABLES (M23d — binary varint interning tables)
//!           bit 13      — FLAG_HAS_SPAN_STREAM (RS-M1 — spans.dat/spans.idx/spantype.ns)
//!           bit 14      — FLAG_HAS_LINE_COUNT_TABLE (paths.dat records carry line_count)
//!           bit 15      — FLAG_HAS_CORRELATION_INDEX (WTCI — corrmark.ns + markers.dat/.off)
//!           (no bit is reserved; the flag word is fully allocated)
//! [4 bytes] flags_ext u32 little-endian — always present
//!           bit 0       — FLAG_EXT_HAS_SOURCE_RELOAD (GDH-M2)
//! varint-prefixed UTF-8 string : recording_id        (M-REC-1; v3+)
//! varint-prefixed UTF-8 string : program
//! varint                       : args_count
//!   ⤷ args_count × varint-prefixed UTF-8 string : args[i]
//! varint-prefixed UTF-8 string : workdir
//! varint-prefixed UTF-8 string : recorder_id
//!
//! (No path list: a trace's source paths are the records of `paths.dat`.)
//!
//! if (flags & FLAG_HAS_MCR_FIELDS) != 0:
//!     varint                       : tick_source        (enum ord)
//!     varint                       : total_threads
//!     varint                       : atomic_mode        (enum ord)
//!     varint                       : total_events
//!     varint                       : total_checkpoints
//!     varint                       : start_time_unix_us
//!     varint-prefixed UTF-8 string : platform
//!     varint-prefixed UTF-8 string : tick_granularity
//!     varint-prefixed UTF-8 string : tick_source_str
//!     varint-prefixed UTF-8 string : atomic_mode_str
//!     varint-prefixed UTF-8 string : start_time_str
//!     varint-prefixed UTF-8 string : hook_profile
//!     varint                       : hook_strategies_count
//!       ⤷ hook_strategies_count × varint-prefixed UTF-8 string : hook_strategies[i]
//!
//! if (flags & FLAG_HAS_REPLAY_LAUNCH_FIELDS) != 0:
//!     u8 aslr_disabled
//!
//! if (flags & FLAG_HAS_LAYOUT_SNAPSHOT) != 0:
//!     u64 LE layout_hash
//!     varint fingerprint_len
//!     bytes fingerprint[fingerprint_len]
//!
//! if (flags & FLAG_HAS_TRACE_FILTER_PROVENANCE) != 0:
//!     varint trace_filter_count
//!     trace_filter_count × {
//!         varint-prefixed UTF-8 string : filter_path
//!         32 raw bytes                 : sha256 of filter source
//!     }
//! ```
//!
//! Varints are unsigned LEB128 (max 10 bytes per value). All strings are
//! UTF-8 with no nul terminator.
//!
//! ## Version history
//!
//! - **v1** — initial release.  Retired with M-REC-1.5; not readable.
//! - **v2** — added `hook_profile` and `hook_strategies` inside the
//!   MCR-fields block.  Retired with M-REC-1.5; not readable.
//! - **v3** — M-REC-1 (2026-05-18): prepended a required `recording_id`
//!   UUIDv7 string before the existing `program` field, and added flag bit
//!   3 (trace-filter provenance) to the bitmask.  Pre-1.0: no backcompat
//!   shim — v1/v2 fixtures must be regenerated.  Spec:
//!   `codetracer-specs/Refactoring-Plans/Recording-Identifier-Migration.md`
//!   M-REC-1 / M-REC-1.5.
//! - **v4** — the line-only `global_position_index` encode became
//!   `prefix_sum[file_id] + (line - 1)`, where it had been
//!   `prefix_sum[file_id] + line`.  No field of the header changed; the
//!   version moved because it is the only thing in a container that
//!   distinguishes the two encodes, and reading a v3 container under the
//!   current decode reports every step one line high without failing.
//!   See [`SUPPORTED_VERSIONS`] for why no version before it is accepted.
//!   Spec: `codetracer-trace-format-spec/internal-files.md` §"Global Line
//!   Index".
//! - **v5** — GDH-M2 (2026-09-10): a `[4] flags_ext u32 LE` word follows the
//!   u16 flags, written only when an extended flag is set.
//! - **v6** — 2026-10: the path list after `recorder_id` is gone, and
//!   `flags_ext` is always present, so there is one header length.  Every
//!   other version is refused: the bytes after `recorder_id` mean something
//!   else in v5 and below.  Spec: `codetracer-trace-format-spec/
//!   internal-files.md` §"Metadata (meta.dat)".

use std::error::Error;
use std::fmt;

// ── Constants ───────────────────────────────────────────────────────────

/// Magic bytes identifying a `meta.dat` payload: ASCII "CTMD".
pub const META_DAT_MAGIC: [u8; 4] = [0x43, 0x54, 0x4D, 0x44];

/// The `meta.dat` format version emitted by this serializer, and the only
/// one the reader accepts (see [`SUPPORTED_VERSIONS`]).
pub const META_DAT_VERSION: u16 = 6;

/// The highest schema version whose writer packed a line-only
/// `global_position_index` as `prefix_sum[file_id] + line`.
///
/// The bound is named rather than written as a literal `3` where it is
/// used, so that it and the refusal it drives move together: a later
/// version that changed the packing again would raise it, and a reader
/// comparing against a stale literal would answer such a container
/// instead of refusing it.
pub const LAST_SHIFTED_GLOBAL_INDEX_VERSION: u16 = 3;

/// All `meta.dat` versions this reader can decode: version 6 alone.
///
/// Version 6 removed the path list that versions 3 to 5 wrote after
/// `recorder_id`, and made `flags_ext` unconditional. A version 5 header read
/// under version 6's rules would decode its path count as the next
/// flag-gated block, and a version 6 header read under version 5's would
/// decode the ext word as the recording id's length, so neither is read as
/// the other: pre-1.0 there is no compatibility path, and older containers
/// are re-recorded.
///
/// Versions at or below [`LAST_SHIFTED_GLOBAL_INDEX_VERSION`] are refused
/// with their own reason as well: their writers packed a line-only step
/// position as `prefix_sum[file_id] + line`, one line above the current
/// decode, and nothing but the version tells the two apart.
pub const SUPPORTED_VERSIONS: &[u16] = &[META_DAT_VERSION];

/// Flag bit 0 — when set, the MCR (Multi-process Concurrent Recording)
/// fields follow `recorder_id`.
pub const FLAG_HAS_MCR_FIELDS: u16 = 1 << 0;

/// Flag bit 1 — replay-launch fields (M-RLP-1, spec §6A.5) follow the MCR
/// block. Currently a single `aslr_disabled` byte; layout may grow. See
/// `codetracer-trace-format-nim/src/codetracer_trace_writer/meta_dat.nim`.
pub const FLAG_HAS_REPLAY_LAUNCH_FIELDS: u16 = 1 << 1;

/// Flag bit 2 — layout-snapshot fields (M-RLP-2, spec §6B.7) follow the
/// replay-launch block: u64 LE `layout_hash` + varint-prefixed
/// `layout_fingerprint`. Recorder uses these to detect replay-time layout
/// drift; the WASM browser-replay path parses-and-ignores them.
pub const FLAG_HAS_LAYOUT_SNAPSHOT: u16 = 1 << 2;

/// Flag bit 3 — trace-filter provenance (TF-M7, spec §7).  When set, a
/// trailing block records the active trace-filter chain: a varint count
/// followed by `(varint-prefixed path, 32-byte sha256)` tuples.  The
/// reader parses-and-stores the entries; consumers that don't care about
/// filter provenance can ignore the field.
pub const FLAG_HAS_TRACE_FILTER_PROVENANCE: u16 = 1 << 3;

/// Flag bit 4 — column-aware step encoding (P6.3 / P6.4, spec
/// `trace-events.md` §"Reader Behaviour and Back-Compat").  When set the
/// step stream MAY carry tag 0x07 (`DeltaColumn`) events and
/// `global_position_index` addresses `(line, column)` pairs.  The
/// old-format reader path doesn't consume column-aware step data, but
/// it must still recognise the bit so traces that set it parse cleanly.
pub const FLAG_HAS_COLUMN_AWARE_STEPS: u16 = 1 << 4;

/// Flag bit 5 — alternate source views ("Deminification Support").
/// When set the container carries `srcviews.dat` / `srcviews.off`
/// records.  Like the column-aware bit, this path parses-and-ignores
/// the bit; the actual decoding lives in the Nim reader.
pub const FLAG_HAS_ALTERNATE_SOURCE_VIEWS: u16 = 1 << 5;

/// Flag bit 6 — `FLAG_SUPPORTS_COLUMN_BREAKPOINTS` capability
/// (M-capability-flags).  When set the recorder advertises that its
/// columns are sharp enough for per-column breakpoint placement; the
/// GUI gates the M6 Alt+click affordance on this bit (see spec
/// `codetracer-trace-format-spec/internal-files.md` §"Column-Aware
/// Capability Flags").  Implies `FLAG_HAS_COLUMN_AWARE_STEPS`.
pub const FLAG_SUPPORTS_COLUMN_BREAKPOINTS: u16 = 1 << 6;

/// Flag bit 7 — `FLAG_SUPPORTS_COLUMN_MOTIONS` capability
/// (M-capability-flags).  When set the recorder advertises that its
/// step predicate fires per-statement so the GUI can offer per-column
/// step-over / step-in / step-out.  Implies
/// `FLAG_HAS_COLUMN_AWARE_STEPS`.
pub const FLAG_SUPPORTS_COLUMN_MOTIONS: u16 = 1 << 7;

/// Flag bit 8 — `FLAG_HAS_CALL_STREAM` (M17a/M17b).  When set the container
/// ships a dedicated, SEEKABLE `calls.dat` call stream (+ its `calls.idx`
/// companion index), so the call tree can be read on demand without scanning
/// the step/value events (`trace-events.md` §"Call Stream (`calls.dat`)").
/// Stream presence is structural: the bit is a hint, and the db-backend's
/// seekable `CTFSTraceReader` serves the call tree from `calls.dat` when the
/// file is present (see `call_stream_source`).  Must match
/// `codetracer_trace_writer::meta_dat::FLAG_HAS_CALL_STREAM` and the canonical
/// Nim writer's `meta_dat.nim` bit 8.
pub const FLAG_HAS_CALL_STREAM: u16 = 1 << 8;

/// Flag bit 9 — `FLAG_HAS_STEP_STREAM` (M23a).  When set the container ships a
/// dedicated, SEEKABLE `steps.dat` compact execution stream
/// (AbsoluteStep/DeltaStep + Raise/Catch/ThreadSwitch, +  its `steps.idx`
/// companion index), so the step timeline can be read on demand
/// (`trace-events.md` §"Execution Stream (`steps.dat`)").  This parser
/// RECOGNISES the bit so the meta.dat parses cleanly (not rejected as a "newer
/// writer"); stream presence itself is structural.  Must match
/// `codetracer_trace_writer::meta_dat::FLAG_HAS_STEP_STREAM` and the canonical
/// Nim writer's `meta_dat.nim` bit 9.
pub const FLAG_HAS_STEP_STREAM: u16 = 1 << 9;

/// Flag bit 10 — `FLAG_HAS_VALUE_STREAM` (M23b).  When set the container ships a
/// dedicated, SEEKABLE `values.dat` parallel value stream (StepValues /
/// BindVariable / Cell / Assign… per step, + its `values.idx` companion index)
/// The value stream is parallel-indexed to
/// the execution stream — value record N ↔ step N, with an empty record for
/// steps that have no variable activity — so a step's variable values can be
/// read on demand (`trace-events.md` §"Value Stream").  The value stream lives in its OWN CTFS
/// file pair (NOT `steps.dat`) because value records are large (50-500B) with
/// different Zstd chunk sizing than the tiny execution records.  This parser
/// RECOGNISES the bit so the meta.dat parses cleanly (not rejected as a "newer
/// writer"); stream presence itself is structural.  Must
/// match `codetracer_trace_writer::meta_dat::FLAG_HAS_VALUE_STREAM` and the
/// canonical Nim writer's `meta_dat.nim` bit 10.
pub const FLAG_HAS_VALUE_STREAM: u16 = 1 << 10;

/// Flag bit 11 — `FLAG_HAS_IO_EVENT_STREAM` (M23c).  When set the container
/// ships a dedicated, SEEKABLE `events.dat` I/O event stream (the
/// `EventLogKind`-tagged stdout/stderr/file/network/error/log events, + its
/// `events.idx` companion index).  Each
/// record carries `kind` (u8) / `step_id` (varint cross-reference to the
/// execution stream) / `metadata` / `content`, so the event-log pane can
/// paginate it directly (`trace-events.md` §"IO Event Stream (`events.dat`)").
/// This parser RECOGNISES the bit so the meta.dat parses cleanly (not rejected
/// as a "newer writer"); stream presence itself is structural.  Must match
/// `codetracer_trace_writer::meta_dat::FLAG_HAS_IO_EVENT_STREAM` and the
/// canonical Nim writer's `meta_dat.nim` bit 11.
pub const FLAG_HAS_IO_EVENT_STREAM: u16 = 1 << 11;

/// Flag bit 12 — `FLAG_HAS_INTERNING_TABLES` (M23d).  When set the container
/// ships the binary varint interning tables (`paths.dat`+`paths.off`,
/// `funcs.dat`+`funcs.off`, `types.dat`+`types.off`, `varnames.dat`+`varnames.off`).
/// These use the
/// Variable-Size Record Table (`.dat` + `.off`) pattern — a `.dat` of serialized
/// records plus a `u64`-LE offset index for O(1) random access by id
/// (`internal-files.md` §"Interning Tables").  This parser RECOGNISES the bit
/// so the meta.dat parses cleanly (not rejected as a "newer writer").  Must match
/// `codetracer_trace_writer::meta_dat::FLAG_HAS_INTERNING_TABLES` and the
/// canonical Nim writer's `meta_dat.nim` bit 12.
pub const FLAG_HAS_INTERNING_TABLES: u16 = 1 << 12;

/// Flag bit 13 — `FLAG_HAS_SPAN_STREAM` (RS-M1).  When set the container ships
/// the request/interval **span stream**: `spans.dat` (chunked-compressed span
/// records), its companion index `spans.idx` (v2 layout — 8-byte header then
/// fixed 16-byte `[offset u64][cumulative_records u64]` entries) and the
/// `spantype.ns` namespace mapping an interned `span_type` id to the span ids
/// of that type.  A span is a bounded, labeled interval of execution named by
/// the coordinate *(process_ord, thread_id, step range)* — an HTTP request, a
/// process, a test — and the stream replaces the `session_manifest.jsonl` /
/// `codetracer_spans.jsonl` sidecars so a recording stays ONE artifact.
///
/// **This bit is deliberately NOT backwards compatible.**  Unlike bits 8..12,
/// which readers may recognise-and-ignore, a container that sets bit 13 is
/// refused outright by any reader whose [`KNOWN_FLAGS_MASK`] predates it — that
/// is the whole point of the mask.  The spec's rollout rule is therefore
/// "readers before writers" (see
/// `codetracer-specs/Trace-Files/CTFS-Request-Span-Streams.md`
/// §"`meta.dat` feature bit"), and RS-M2 is the milestone that lands the reader
/// side.  Recognising the bit here is what makes a span-bearing container
/// openable at all; the span records themselves are decoded by
/// [`crate::ctfs_trace_reader::span_stream`].
///
/// Must match `codetracer_trace_writer::meta_dat::FLAG_HAS_SPAN_STREAM`
/// (Rust writer) and the canonical Nim writer's `meta_dat.nim` bit 13.
pub const FLAG_HAS_SPAN_STREAM: u16 = 1 << 13;

/// Flag bit 14 — `FLAG_HAS_LINE_COUNT_TABLE`.  When set, every `paths.dat`
/// record carries the file's line count after the path bytes
/// (`path_len + path_bytes + line_count`) and the line-only global position
/// space is laid out from those counts rather than from the
/// `DEFAULT_LINES_PER_FILE` convention.
///
/// This is the container finally *stating* what a line-only reader previously
/// had to assume.  Spec `trace-events.md` §"Per-File Contiguous Integer Ranges"
/// sizes a line-only file at `file_size = line_count`, but no line-only
/// container carried the counts, so a reader could only apply the writer's
/// convention of 100000 addresses per file — unrecorded, and wrong above its
/// own ceiling: a file with more lines addresses positions inside the *next*
/// file's range, which is a well-formed address of a location that was never
/// recorded and which no reader can detect.
///
/// **Mutually exclusive with [`FLAG_HAS_COLUMN_AWARE_STEPS`]**: a Layout A
/// record already carries `line_count` as the length of its per-line table, and
/// that mode sizes a file in addressable columns rather than lines.  A header
/// setting both states the same field under two record layouts, and
/// [`parse_meta_dat`] rejects it.
///
/// **Like bit 13, deliberately NOT backwards compatible.**  A reader whose
/// [`KNOWN_FLAGS_MASK`] predates it refuses a count-bearing container outright,
/// which is what makes the record-layout change safe: the alternative is
/// reading the framed record as bare path bytes and answering with a path that
/// has its own length prefix glued to the front.  Rollout is therefore
/// "readers before writers", and no writer sets the bit by default.
///
/// Must match `codetracer_trace_writer::meta_dat::FLAG_HAS_LINE_COUNT_TABLE`
/// (Rust writer) and the canonical Nim writer's `meta_dat.nim` bit 14
/// (`FlagHasLineCountTable`).
pub const FLAG_HAS_LINE_COUNT_TABLE: u16 = 1 << 14;

/// Flag bit 15 — `FLAG_HAS_CORRELATION_INDEX` (WTCI).  When set the container
/// ships `corrmark.ns`, the record-time B-tree index of the distributed-trace
/// spans and boundary crossings the recording covers, together with the
/// `markers.dat` / `markers.off` interning table its boundary labels resolve
/// through.
///
/// **A hint, not a gate.**  Like bits 8..13 it says only what the container
/// carries; the root file-entry array remains the authority, and it is the
/// entry's presence — not this bit — that distinguishes "never indexed" from
/// "indexed and covering nothing" (see
/// `codetracer-specs/Testing/CTFS-Correlation-Marker-Contract.md` §9).
///
/// Recognising it here is nonetheless load-bearing: [`KNOWN_FLAGS_MASK`]
/// refuses any container carrying an unknown bit outright, so without this
/// constant a reader would reject every marker-bearing recording rather than
/// ignore an index it has no use for.
///
/// Must match `codetracer_trace_writer::meta_dat::FLAG_HAS_CORRELATION_INDEX`
/// (Rust writer) and the canonical Nim writer's `meta_dat.nim` bit 15.
///
/// Drafted against bit 14, which [`FLAG_HAS_LINE_COUNT_TABLE`] took first.
/// Both describe the container, so they could not share a bit; neither had
/// shipped, so moving this one cost no compatibility.
pub const FLAG_HAS_CORRELATION_INDEX: u16 = 1 << 15;

/// Bitmask of all flag bits this implementation understands.
///
/// Any bit outside this mask is rejected by [`parse_meta_dat`] so future
/// writers introducing new flag bits force readers to upgrade explicitly.
const KNOWN_FLAGS_MASK: u16 = FLAG_HAS_MCR_FIELDS
    | FLAG_HAS_REPLAY_LAUNCH_FIELDS
    | FLAG_HAS_LAYOUT_SNAPSHOT
    | FLAG_HAS_TRACE_FILTER_PROVENANCE
    | FLAG_HAS_COLUMN_AWARE_STEPS
    | FLAG_HAS_ALTERNATE_SOURCE_VIEWS
    | FLAG_SUPPORTS_COLUMN_BREAKPOINTS
    | FLAG_SUPPORTS_COLUMN_MOTIONS
    | FLAG_HAS_CALL_STREAM
    | FLAG_HAS_STEP_STREAM
    | FLAG_HAS_VALUE_STREAM
    | FLAG_HAS_IO_EVENT_STREAM
    | FLAG_HAS_INTERNING_TABLES
    | FLAG_HAS_SPAN_STREAM
    | FLAG_HAS_LINE_COUNT_TABLE
    | FLAG_HAS_CORRELATION_INDEX;

/// Extended flag bit 0 (global bit 16) — the execution stream may contain
/// step-event tag `0x08` (`TagSourceReload`), the source-version transition
/// marker that marks a GDScript hot reload.
///
/// Clear means the container carries no reload markers and a reader must
/// REFUSE tag 0x08 rather than skip it: the record's length is not
/// recoverable without decoding it, so a skip re-reads the payload varints
/// as further events and the step stream decodes shorter and plausibly —
/// wrong bytes instead of an error.
///
/// Must match the Nim writer's `meta_dat.nim` `FlagExtHasSourceReload` and
/// `codetracer_trace_writer::meta_dat::FLAG_EXT_HAS_SOURCE_RELOAD` (Rust).
pub const FLAG_EXT_HAS_SOURCE_RELOAD: u32 = 1 << 0;

/// Bitmask of all EXTENDED flag bits this implementation understands.
///
/// Any bit outside it is rejected by [`parse_meta_dat`], exactly as
/// [`KNOWN_FLAGS_MASK`] does for the u16.  Validating one word and not the
/// other would let a container declare a stream shape this reader cannot
/// decode.
const KNOWN_EXT_FLAGS_MASK: u32 = FLAG_EXT_HAS_SOURCE_RELOAD;

// ── Public types ────────────────────────────────────────────────────────

/// The flag bits this build understands, as a mask.
///
/// Exposed so a test in another module can derive a genuinely-unknown bit from
/// it instead of naming one by hand — a hand-written literal silently stops
/// probing anything the moment that bit is allocated.
pub fn known_flags_mask() -> u16 {
    KNOWN_FLAGS_MASK
}

/// Decoded contents of a `meta.dat` file.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct MetaDat {
    /// Format version actually present in the parsed header.
    ///
    /// The serializer always writes [`META_DAT_VERSION`]; the parser
    /// accepts any version listed in [`SUPPORTED_VERSIONS`].
    pub version: u16,
    /// Raw flag bits as parsed from the header.
    pub flags: u16,
    /// Recording identifier (UUIDv7, canonical 36-char lowercase
    /// hyphenated form, per M-REC-1 and RFC 9562).  Required in v3+.
    pub recording_id: String,
    /// Program path or identifier, exactly as recorded.
    pub program: String,
    /// Command-line arguments passed to the recorded program.
    pub args: Vec<String>,
    /// Working directory of the recorded program.
    pub workdir: String,
    /// Recorder identifier (e.g. "ruby", "python", "evm").
    pub recorder_id: String,
    /// The extended flag word (`flags_ext`). Every bit in it is one this
    /// reader knows; an unknown bit is refused at parse.
    pub ext_flags: u32,
    /// MCR metadata. `Some` iff `flags & FLAG_HAS_MCR_FIELDS != 0`.
    pub mcr: Option<McrFields>,
    /// Replay-launch fields (M-RLP-1). `Some` iff
    /// `flags & FLAG_HAS_REPLAY_LAUNCH_FIELDS != 0`.
    pub replay_launch: Option<ReplayLaunchFields>,
    /// Layout-snapshot fields (M-RLP-2). `Some` iff
    /// `flags & FLAG_HAS_LAYOUT_SNAPSHOT != 0`.
    pub layout_snapshot: Option<LayoutSnapshotFields>,
    /// Trace-filter provenance entries (TF-M7).  Empty when the flag bit
    /// is clear AND when the writer recorded a deliberately empty chain;
    /// distinguish via [`MetaDat::has_filter_provenance`].
    pub filter_provenance: Vec<FilterProvenanceEntry>,
    /// `true` iff `FLAG_HAS_TRACE_FILTER_PROVENANCE` was set on the
    /// header.  Distinguishes "no provenance recorded" (`false`) from
    /// "provenance recorded but empty" (`true` with empty
    /// `filter_provenance`).
    pub has_filter_provenance: bool,
}

/// One entry in the trace-filter provenance block (TF-M7, spec §7).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct FilterProvenanceEntry {
    /// Filter source path as recorded.
    pub path: String,
    /// SHA-256 digest of the filter source.
    pub sha256: [u8; 32],
}

/// Replay-launch metadata (M-RLP-1, spec §6A.5).
///
/// Captures launch-time configuration the replay engine needs to
/// reproduce the recorded address-space layout. Mirror of the Nim
/// writer's `ReplayLaunchFields`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ReplayLaunchFields {
    /// `true` if the recorded process was launched with ASLR disabled
    /// (e.g. via `personality(ADDR_NO_RANDOMIZE)` / `setarch -R`).
    pub aslr_disabled: bool,
}

/// Layout-snapshot metadata (M-RLP-2, spec §6B.7).
///
/// Fingerprint of the recorded address-space layout at trace-start time.
/// Used by recorder/replay coordination to detect drift. The WASM
/// browser-replay path parses-and-ignores these fields today.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct LayoutSnapshotFields {
    /// 64-bit fingerprint hash of the layout snapshot (writer-side
    /// computation; opaque to readers).
    pub layout_hash: u64,
    /// Opaque fingerprint byte string. Length is varint-prefixed on the
    /// wire; canonical content is writer-chosen.
    pub layout_fingerprint: Vec<u8>,
}

/// MCR (Multi-process Concurrent Recording) metadata block.
///
/// Enum ords (`tick_source`, `atomic_mode`) are intentionally stored as
/// raw `u64` rather than typed enums; consumers that need typed access
/// can map them via the recorder's enum definitions. The `*_str` fields
/// carry the human-readable forms emitted by the writer.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct McrFields {
    /// Ordinal of the `TickSource` enum value used during recording.
    pub tick_source: u64,
    /// Total number of threads observed in the trace.
    pub total_threads: u64,
    /// Ordinal of the `AtomicMode` enum value used during recording.
    pub atomic_mode: u64,
    /// Total event count across all threads.
    pub total_events: u64,
    /// Number of checkpoints written.
    pub total_checkpoints: u64,
    /// Recording start time in microseconds since the Unix epoch.
    pub start_time_unix_us: u64,
    /// Platform identifier string (e.g. `"linux-x86_64"`).
    pub platform: String,
    /// Human-readable tick granularity (e.g. `"instruction"`).
    pub tick_granularity: String,
    /// Stringified `TickSource` (kept verbatim for diagnostics).
    pub tick_source_str: String,
    /// Stringified `AtomicMode` (kept verbatim for diagnostics).
    pub atomic_mode_str: String,
    /// Stringified start time (e.g. ISO-8601 form emitted by the writer).
    pub start_time_str: String,
    /// Name of the active MCR hook profile (e.g. `"default"`, `"dotnet"`,
    /// `"pal_probe"`).
    pub hook_profile: String,
    /// Identifiers of the hook strategies active during recording (e.g.
    /// `"ldpreload"`, `"seccomp_unotify"`, `"callsite_patch"`).
    pub hook_strategies: Vec<String>,
}

// ── Error type ──────────────────────────────────────────────────────────

/// Errors that can occur while parsing a `meta.dat` payload.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum MetaDatError {
    /// Input is shorter than the fixed 12-byte header.
    TooShort {
        /// Number of bytes actually supplied to the parser.
        got: usize,
    },
    /// Magic bytes do not match `META_DAT_MAGIC`.
    BadMagic,
    /// Format version differs from the supported [`META_DAT_VERSION`].
    UnsupportedVersion(u16),
    /// One or more reserved flag bits were set; the writer is newer than
    /// this reader and the trace cannot be safely parsed.
    UnknownFlags {
        /// The full flags field as parsed from the header.
        flags: u16,
        /// The subset of bits this reader does not recognise.
        unknown_bits: u16,
    },
    /// GDH-M2 — one or more EXTENDED flag bits (`flags_ext`) were set that
    /// this reader does not know. Same contract as
    /// [`MetaDatError::UnknownFlags`]: the writer is newer than this reader
    /// and the container declares a stream shape it cannot decode.
    UnknownExtendedFlags {
        /// The full `flags_ext` word as parsed from the header.
        ext_flags: u32,
        /// The subset of bits this reader does not recognise.
        unknown_bits: u32,
    },
    /// Hit end-of-input while reading a varint payload.
    VarintEof,
    /// A varint required more than 10 LEB128 bytes (overflows `u64`).
    VarintTooLong,
    /// A length-prefixed string extends past the end of the buffer.
    StringEof {
        /// Byte length declared by the varint length prefix.
        declared_len: usize,
        /// Bytes still available in the buffer at the start of the string.
        remaining: usize,
    },
    /// A length-prefixed string is not valid UTF-8.
    InvalidUtf8 {
        /// Byte offset (within the full input) where the string starts.
        offset: usize,
        /// Underlying UTF-8 decoding error.
        source: std::str::Utf8Error,
    },
    /// A varint declared a string length that exceeds `usize::MAX`. Only
    /// reachable on platforms where `usize` is narrower than `u64`.
    StringTooLong(u64),
    /// The buffer contained extra bytes after a successful parse.
    TrailingBytes {
        /// Number of unconsumed bytes following the structured payload.
        extra: usize,
    },
    /// The `recording_id` field is not a canonical UUIDv7 (M-REC-1).
    /// Required in v3+: a missing or malformed id rejects the trace.
    InvalidRecordingId {
        /// The offending string value (lossy-truncated if oversized).
        value: String,
    },
    /// The header set both [`FLAG_HAS_COLUMN_AWARE_STEPS`] and
    /// [`FLAG_HAS_LINE_COUNT_TABLE`], which declare the same `paths.dat` field
    /// under two incompatible record layouts. Rejected rather than resolved by
    /// preference: picking one would decode the other layout's records as a
    /// truncated path with a fabricated count, and answer with no error.
    ConflictingPathLayouts {
        /// The full flags field as parsed from the header.
        flags: u16,
    },
}

impl fmt::Display for MetaDatError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            MetaDatError::TooShort { got } => {
                write!(f, "meta.dat too short: need at least 12 bytes, got {got}")
            }
            MetaDatError::BadMagic => write!(f, "meta.dat: bad magic bytes (expected 'CTMD')"),
            MetaDatError::ConflictingPathLayouts { flags } => write!(
                f,
                "meta.dat: flags 0x{flags:04x} set both FLAG_HAS_COLUMN_AWARE_STEPS (bit 4) and \
                 FLAG_HAS_LINE_COUNT_TABLE (bit 14). Each selects a paths.dat record layout and a \
                 record is in one or the other; a column-aware record already carries the file's \
                 line_count as the length of its per-line table. Re-record the trace with a \
                 current recorder"
            ),
            // A version at or below the correction bound is refused with its
            // reason spelled out, not with the generic mismatch, because the
            // consequence of reading one anyway is not a parse failure — it is
            // a plausible wrong answer at every step, and only naming it tells
            // a caller that the remedy is to re-record rather than to wait for
            // a newer reader.
            //
            // Phrased about the WRITER rather than about this container's
            // contents: the gate is on the schema version, so it also refuses
            // a container at that version holding no steps at all, and "its
            // steps were packed as" would be a claim about such a trace that
            // is not true.
            MetaDatError::UnsupportedVersion(v) if *v <= LAST_SHIFTED_GLOBAL_INDEX_VERSION => write!(
                f,
                "meta.dat: schema version {v} predates the global line index correction, and this \
                 trace cannot be read. Writers at that version packed a line-only step position as \
                 prefix_sum[file_id] + line; version {META_DAT_VERSION} packs \
                 prefix_sum[file_id] + (line - 1). Both land inside the trace's address space, so \
                 a step read under the current decode would come back one line high rather than \
                 fail, and the container records nothing else that tells the two apart. Re-record \
                 the trace with a current recorder. Spec: \
                 codetracer-trace-format-spec/internal-files.md \"Global Line Index\"",
            ),
            MetaDatError::UnsupportedVersion(v) => write!(
                f,
                "meta.dat: version {v} is not readable: this reader reads version {META_DAT_VERSION} only. \
                 Version 5 and below carry a path list after recorder_id that version \
                 {META_DAT_VERSION} does not, so the two cannot be read as each other. Re-record the \
                 trace with a current recorder"
            ),
            MetaDatError::UnknownFlags { flags, unknown_bits } => write!(
                f,
                "meta.dat: unknown flag bits set (flags=0x{flags:04x}, unknown=0x{unknown_bits:04x}); \
                 the writer is newer than this reader",
            ),
            MetaDatError::UnknownExtendedFlags {
                ext_flags,
                unknown_bits,
            } => write!(
                f,
                "meta.dat: unknown extended flag bits set (flags_ext=0x{ext_flags:08x}, \
                 unknown=0x{unknown_bits:08x}); the writer is newer than this reader",
            ),
            MetaDatError::VarintEof => write!(f, "meta.dat: unexpected end of input while reading varint"),
            MetaDatError::VarintTooLong => write!(f, "meta.dat: varint exceeds 10-byte LEB128 maximum"),
            MetaDatError::StringEof {
                declared_len,
                remaining,
            } => write!(
                f,
                "meta.dat: string of declared length {declared_len} extends past end of input ({remaining} bytes remain)",
            ),
            MetaDatError::InvalidUtf8 { offset, source } => {
                write!(f, "meta.dat: invalid UTF-8 string at offset {offset}: {source}")
            }
            MetaDatError::StringTooLong(n) => {
                write!(f, "meta.dat: string length {n} does not fit in usize on this platform")
            }
            MetaDatError::TrailingBytes { extra } => {
                write!(f, "meta.dat: {extra} trailing byte(s) after structured payload")
            }
            MetaDatError::InvalidRecordingId { value } => write!(
                f,
                "meta.dat: invalid recording_id {value:?} (expected canonical lowercase hyphenated UUIDv7)",
            ),
        }
    }
}

impl Error for MetaDatError {
    fn source(&self) -> Option<&(dyn Error + 'static)> {
        match self {
            MetaDatError::InvalidUtf8 { source, .. } => Some(source),
            _ => None,
        }
    }
}

// ── Varint codec (LEB128 unsigned) ──────────────────────────────────────

/// Encode `value` as unsigned LEB128 and append the bytes to `out`.
///
/// Always emits at least one byte. The maximum encoded length is 10
/// bytes (for `u64::MAX`), matching the Nim writer at
/// `codetracer_trace_writer/varint.nim`.
fn encode_varint(value: u64, out: &mut Vec<u8>) {
    let mut v = value;
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

/// Decode a single unsigned LEB128 varint starting at `*pos` in `data`.
///
/// On success advances `*pos` past the consumed bytes. On EOF or a varint
/// longer than 10 bytes (which would overflow `u64`) returns an error
/// without advancing `*pos` further than the offending byte.
fn decode_varint(data: &[u8], pos: &mut usize) -> Result<u64, MetaDatError> {
    let mut result: u64 = 0;
    let mut shift: u32 = 0;
    loop {
        if *pos >= data.len() {
            return Err(MetaDatError::VarintEof);
        }
        let byte = data[*pos];
        *pos += 1;
        result |= u64::from(byte & 0x7F) << shift;
        if byte & 0x80 == 0 {
            return Ok(result);
        }
        shift += 7;
        if shift >= 64 {
            return Err(MetaDatError::VarintTooLong);
        }
    }
}

// ── String codec ────────────────────────────────────────────────────────

/// Read a length-prefixed UTF-8 string starting at `*pos`.
///
/// Length is encoded as a single LEB128 varint. The returned `String`
/// owns its bytes; the function validates UTF-8 to surface a structured
/// error rather than panicking.
fn read_string(data: &[u8], pos: &mut usize) -> Result<String, MetaDatError> {
    let len_u64 = decode_varint(data, pos)?;
    let len = usize::try_from(len_u64).map_err(|_| MetaDatError::StringTooLong(len_u64))?;
    if data.len() - *pos < len {
        return Err(MetaDatError::StringEof {
            declared_len: len,
            remaining: data.len() - *pos,
        });
    }
    let start = *pos;
    let bytes = &data[start..start + len];
    let s = std::str::from_utf8(bytes).map_err(|source| MetaDatError::InvalidUtf8 { offset: start, source })?;
    let owned = s.to_owned();
    *pos += len;
    Ok(owned)
}

/// Append a length-prefixed UTF-8 string to `out`.
fn write_string(s: &str, out: &mut Vec<u8>) {
    encode_varint(s.len() as u64, out);
    out.extend_from_slice(s.as_bytes());
}

// ── Recording-id validation ─────────────────────────────────────────────

/// Validate a string is a canonical lowercase hyphenated UUIDv7 per
/// RFC 9562 (36 chars: 8-4-4-4-12, version nibble = 0x7, variant top
/// two bits = 10b).
///
/// Pre-1.0 the M-REC-1 spec requires that every `meta.dat` carries a
/// syntactically valid `recording_id`; readers reject metadata that
/// fails this check rather than silently accepting garbage.
pub fn is_canonical_uuid_v7(s: &str) -> bool {
    if s.len() != 36 {
        return false;
    }
    let bytes = s.as_bytes();
    // Hyphen positions follow the 8-4-4-4-12 canonical layout.
    for &i in &[8usize, 13, 18, 23] {
        if bytes[i] != b'-' {
            return false;
        }
    }
    for (idx, &b) in bytes.iter().enumerate() {
        match idx {
            8 | 13 | 18 | 23 => continue,
            _ => match b {
                b'0'..=b'9' | b'a'..=b'f' => {}
                _ => return false,
            },
        }
    }
    // Version nibble is the first character of group 3 (offset 14).
    if bytes[14] != b'7' {
        return false;
    }
    // Variant: top two bits of byte at offset 19 must be 10b → first hex
    // char in {8, 9, a, b}.
    match bytes[19] {
        b'8' | b'9' | b'a' | b'b' => {}
        _ => return false,
    }
    true
}

// ── Public API ──────────────────────────────────────────────────────────

/// Parse a binary `meta.dat` payload.
///
/// On success returns a fully populated [`MetaDat`]; on any failure
/// (truncation, magic mismatch, unsupported version, unknown flag bits,
/// invalid UTF-8, …) returns a typed [`MetaDatError`]. This function is
/// `no_std`-style in spirit: it never panics and never allocates beyond
/// what is required to materialise the returned strings/vectors.
///
/// The parser is strict about trailing bytes: if the payload contains
/// data after the structured fields, it returns
/// [`MetaDatError::TrailingBytes`]. This catches accidental
/// double-writes or tooling that appends data without bumping the
/// version field.
pub fn parse_meta_dat(input: &[u8]) -> Result<MetaDat, MetaDatError> {
    if input.len() < 6 {
        return Err(MetaDatError::TooShort { got: input.len() });
    }

    if input[0..4] != META_DAT_MAGIC {
        return Err(MetaDatError::BadMagic);
    }

    // The version is checked before the header length, so that a header from
    // another version is refused for its version and not for being short.
    let version = u16::from_le_bytes([input[4], input[5]]);
    if !SUPPORTED_VERSIONS.contains(&version) {
        return Err(MetaDatError::UnsupportedVersion(version));
    }
    if input.len() < 12 {
        return Err(MetaDatError::TooShort { got: input.len() });
    }

    let flags = u16::from_le_bytes([input[6], input[7]]);
    let unknown_bits = flags & !KNOWN_FLAGS_MASK;
    if unknown_bits != 0 {
        return Err(MetaDatError::UnknownFlags { flags, unknown_bits });
    }
    let ext_flags = u32::from_le_bytes([input[8], input[9], input[10], input[11]]);
    let unknown_ext = ext_flags & !KNOWN_EXT_FLAGS_MASK;
    if unknown_ext != 0 {
        return Err(MetaDatError::UnknownExtendedFlags {
            ext_flags,
            unknown_bits: unknown_ext,
        });
    }
    let body_start = 12usize;
    // Two known bits that cannot both be honoured: each selects a `paths.dat`
    // record layout, and a record is in one layout or the other. Refused here,
    // in front of every consumer, because the wrong choice is not a parse
    // failure downstream — it is a path string with its own framing inside it
    // and a per-file size that was never written.
    if flags & FLAG_HAS_COLUMN_AWARE_STEPS != 0 && flags & FLAG_HAS_LINE_COUNT_TABLE != 0 {
        return Err(MetaDatError::ConflictingPathLayouts { flags });
    }

    let mut pos = body_start;

    // M-REC-1 (v3+): recording_id prepends the program field.  Required
    // and validated; malformed ids reject the trace at parse time.
    let recording_id = read_string(input, &mut pos)?;
    if !is_canonical_uuid_v7(&recording_id) {
        return Err(MetaDatError::InvalidRecordingId { value: recording_id });
    }

    let program = read_string(input, &mut pos)?;

    let args_count_u64 = decode_varint(input, &mut pos)?;
    let args_count = usize::try_from(args_count_u64).map_err(|_| MetaDatError::StringTooLong(args_count_u64))?;
    let mut args = Vec::with_capacity(args_count);
    for _ in 0..args_count {
        args.push(read_string(input, &mut pos)?);
    }

    let workdir = read_string(input, &mut pos)?;
    let recorder_id = read_string(input, &mut pos)?;

    let mcr = if flags & FLAG_HAS_MCR_FIELDS != 0 {
        let tick_source = decode_varint(input, &mut pos)?;
        let total_threads = decode_varint(input, &mut pos)?;
        let atomic_mode = decode_varint(input, &mut pos)?;
        let total_events = decode_varint(input, &mut pos)?;
        let total_checkpoints = decode_varint(input, &mut pos)?;
        let start_time_unix_us = decode_varint(input, &mut pos)?;
        let platform = read_string(input, &mut pos)?;
        let tick_granularity = read_string(input, &mut pos)?;
        let tick_source_str = read_string(input, &mut pos)?;
        let atomic_mode_str = read_string(input, &mut pos)?;
        let start_time_str = read_string(input, &mut pos)?;
        let hook_profile = read_string(input, &mut pos)?;
        let hook_strategies_count_u64 = decode_varint(input, &mut pos)?;
        let hook_strategies_count = usize::try_from(hook_strategies_count_u64)
            .map_err(|_| MetaDatError::StringTooLong(hook_strategies_count_u64))?;
        let mut hook_strategies = Vec::with_capacity(hook_strategies_count);
        for _ in 0..hook_strategies_count {
            hook_strategies.push(read_string(input, &mut pos)?);
        }
        Some(McrFields {
            tick_source,
            total_threads,
            atomic_mode,
            total_events,
            total_checkpoints,
            start_time_unix_us,
            platform,
            tick_granularity,
            tick_source_str,
            atomic_mode_str,
            start_time_str,
            hook_profile,
            hook_strategies,
        })
    } else {
        None
    };

    // Replay-launch fields (M-RLP-1). Single `aslr_disabled` byte today.
    let replay_launch = if flags & FLAG_HAS_REPLAY_LAUNCH_FIELDS != 0 {
        if pos >= input.len() {
            return Err(MetaDatError::StringEof {
                declared_len: 1,
                remaining: 0,
            });
        }
        let aslr_disabled = input[pos] != 0;
        pos += 1;
        Some(ReplayLaunchFields { aslr_disabled })
    } else {
        None
    };

    // Layout-snapshot fields (M-RLP-2). u64 LE layout_hash + varint
    // fingerprint length + fingerprint bytes.
    let layout_snapshot = if flags & FLAG_HAS_LAYOUT_SNAPSHOT != 0 {
        if input.len() - pos < 8 {
            return Err(MetaDatError::StringEof {
                declared_len: 8,
                remaining: input.len() - pos,
            });
        }
        let layout_hash = u64::from_le_bytes([
            input[pos],
            input[pos + 1],
            input[pos + 2],
            input[pos + 3],
            input[pos + 4],
            input[pos + 5],
            input[pos + 6],
            input[pos + 7],
        ]);
        pos += 8;
        let fp_len_u64 = decode_varint(input, &mut pos)?;
        let fp_len = usize::try_from(fp_len_u64).map_err(|_| MetaDatError::StringTooLong(fp_len_u64))?;
        if input.len() - pos < fp_len {
            return Err(MetaDatError::StringEof {
                declared_len: fp_len,
                remaining: input.len() - pos,
            });
        }
        let layout_fingerprint = input[pos..pos + fp_len].to_vec();
        pos += fp_len;
        Some(LayoutSnapshotFields {
            layout_hash,
            layout_fingerprint,
        })
    } else {
        None
    };

    // Trace-filter provenance (TF-M7).  varint count + (path string,
    // raw 32-byte sha256) tuples.
    let mut filter_provenance: Vec<FilterProvenanceEntry> = Vec::new();
    let has_filter_provenance = flags & FLAG_HAS_TRACE_FILTER_PROVENANCE != 0;
    if has_filter_provenance {
        let count_u64 = decode_varint(input, &mut pos)?;
        let count = usize::try_from(count_u64).map_err(|_| MetaDatError::StringTooLong(count_u64))?;
        filter_provenance.reserve(count);
        for _ in 0..count {
            let path = read_string(input, &mut pos)?;
            if input.len() - pos < 32 {
                return Err(MetaDatError::StringEof {
                    declared_len: 32,
                    remaining: input.len() - pos,
                });
            }
            let mut sha = [0u8; 32];
            sha.copy_from_slice(&input[pos..pos + 32]);
            pos += 32;
            filter_provenance.push(FilterProvenanceEntry { path, sha256: sha });
        }
    }

    if pos != input.len() {
        return Err(MetaDatError::TrailingBytes {
            extra: input.len() - pos,
        });
    }

    Ok(MetaDat {
        version,
        flags,
        recording_id,
        program,
        args,
        workdir,
        recorder_id,
        ext_flags,
        mcr,
        replay_launch,
        layout_snapshot,
        filter_provenance,
        has_filter_provenance,
    })
}

/// Serialize a [`MetaDat`] into the binary `meta.dat` wire format.
///
/// Always emits the canonical encoding: the section-presence bits of
/// `flags` are **not** written verbatim — `FLAG_HAS_MCR_FIELDS` is derived
/// from `meta.mcr.is_some()`, and likewise for the other blocks — while the
/// capability and stream-presence bits of `meta.flags` are written as given. This guarantees that
/// `parse_meta_dat(serialize_meta_dat(&x))` returns a value equal to
/// `x` (after `x.flags` is normalised) and that we never produce output
/// our own parser would reject.
pub fn serialize_meta_dat(meta: &MetaDat) -> Vec<u8> {
    // Pre-allocate a reasonable starting capacity. The header is 12 bytes;
    // the rest of the payload grows with the metadata size.
    let mut out = Vec::with_capacity(64);

    // Magic + version.
    out.extend_from_slice(&META_DAT_MAGIC);
    out.extend_from_slice(&META_DAT_VERSION.to_le_bytes());

    // Section-presence bits (0..3) are derived from the blocks present, so the
    // header always says what follows `recorder_id`; every other known bit
    // (capability, stream-presence) is written as given.
    const SECTION_BITS: u16 = FLAG_HAS_MCR_FIELDS
        | FLAG_HAS_REPLAY_LAUNCH_FIELDS
        | FLAG_HAS_LAYOUT_SNAPSHOT
        | FLAG_HAS_TRACE_FILTER_PROVENANCE;
    let mut flags: u16 = meta.flags & KNOWN_FLAGS_MASK & !SECTION_BITS;
    if meta.mcr.is_some() {
        flags |= FLAG_HAS_MCR_FIELDS;
    }
    if meta.replay_launch.is_some() {
        flags |= FLAG_HAS_REPLAY_LAUNCH_FIELDS;
    }
    if meta.layout_snapshot.is_some() {
        flags |= FLAG_HAS_LAYOUT_SNAPSHOT;
    }
    let emit_filter_provenance = meta.has_filter_provenance || !meta.filter_provenance.is_empty();
    if emit_filter_provenance {
        flags |= FLAG_HAS_TRACE_FILTER_PROVENANCE;
    }
    out.extend_from_slice(&flags.to_le_bytes());
    out.extend_from_slice(&(meta.ext_flags & KNOWN_EXT_FLAGS_MASK).to_le_bytes());

    // M-REC-1: recording_id prepends the program field in v3+.
    write_string(&meta.recording_id, &mut out);

    // Program / args / workdir / recorder_id.
    write_string(&meta.program, &mut out);
    encode_varint(meta.args.len() as u64, &mut out);
    for arg in &meta.args {
        write_string(arg, &mut out);
    }
    write_string(&meta.workdir, &mut out);
    write_string(&meta.recorder_id, &mut out);

    // Optional MCR block.
    if let Some(mcr) = &meta.mcr {
        encode_varint(mcr.tick_source, &mut out);
        encode_varint(mcr.total_threads, &mut out);
        encode_varint(mcr.atomic_mode, &mut out);
        encode_varint(mcr.total_events, &mut out);
        encode_varint(mcr.total_checkpoints, &mut out);
        encode_varint(mcr.start_time_unix_us, &mut out);
        write_string(&mcr.platform, &mut out);
        write_string(&mcr.tick_granularity, &mut out);
        write_string(&mcr.tick_source_str, &mut out);
        write_string(&mcr.atomic_mode_str, &mut out);
        write_string(&mcr.start_time_str, &mut out);
        write_string(&mcr.hook_profile, &mut out);
        encode_varint(mcr.hook_strategies.len() as u64, &mut out);
        for strategy in &mcr.hook_strategies {
            write_string(strategy, &mut out);
        }
    }

    // Optional replay-launch block (M-RLP-1).
    if let Some(rl) = &meta.replay_launch {
        out.push(if rl.aslr_disabled { 1 } else { 0 });
    }

    // Optional layout-snapshot block (M-RLP-2).
    if let Some(ls) = &meta.layout_snapshot {
        out.extend_from_slice(&ls.layout_hash.to_le_bytes());
        encode_varint(ls.layout_fingerprint.len() as u64, &mut out);
        out.extend_from_slice(&ls.layout_fingerprint);
    }

    // Optional trace-filter provenance block (TF-M7).
    if emit_filter_provenance {
        encode_varint(meta.filter_provenance.len() as u64, &mut out);
        for entry in &meta.filter_provenance {
            write_string(&entry.path, &mut out);
            out.extend_from_slice(&entry.sha256);
        }
    }

    out
}

// ── Tests ───────────────────────────────────────────────────────────────

#[cfg(test)]
#[allow(clippy::unwrap_used, clippy::expect_used, clippy::panic)]
mod tests {
    use super::*;

    /// A REAL schema-version-5 `meta.dat`, produced by the Nim writer
    /// (`codetracer-trace-format-nim`) recording one file that is reloaded
    /// once, and copied out of the container byte for byte. Version 6 refuses
    /// it: its path list sits where version 6 puts the flag-gated blocks.
    ///
    ///   [0..4)  "CTMD"       [4..6)  version = 5
    ///   [6..8)  flags = 0x4f00    [8..12) flags_ext = 1 (source reload)
    ///   [12..]  body — paths has TWO entries for ONE string, the reload.
    const NIM_WRITTEN_V5_META_DAT: &[u8] = &[
        0x43, 0x54, 0x4D, 0x44, 0x05, 0x00, 0x00, 0x4F, 0x01, 0x00, 0x00, 0x00, 0x24, 0x30, 0x31, 0x38, 0x39, 0x30,
        0x30, 0x30, 0x30, 0x2D, 0x30, 0x30, 0x30, 0x30, 0x2D, 0x37, 0x30, 0x30, 0x30, 0x2D, 0x38, 0x30, 0x30, 0x30,
        0x2D, 0x30, 0x30, 0x30, 0x30, 0x30, 0x30, 0x30, 0x30, 0x39, 0x31, 0x64, 0x39, 0x0B, 0x72, 0x65, 0x76, 0x5F,
        0x70, 0x72, 0x6F, 0x64, 0x75, 0x63, 0x65, 0x00, 0x00, 0x00, 0x02, 0x12, 0x72, 0x65, 0x73, 0x3A, 0x2F, 0x2F,
        0x72, 0x65, 0x76, 0x2F, 0x70, 0x72, 0x6F, 0x62, 0x65, 0x2E, 0x67, 0x64, 0x12, 0x72, 0x65, 0x73, 0x3A, 0x2F,
        0x2F, 0x72, 0x65, 0x76, 0x2F, 0x70, 0x72, 0x6F, 0x62, 0x65, 0x2E, 0x67, 0x64,
    ];

    /// Canonical lowercase hyphenated UUIDv7 used throughout the test suite
    /// so every v3 fixture carries a syntactically valid `recording_id`.
    /// Picked by hand — embedded timestamp is fictional, but byte-stable.
    const TEST_UUID_V7: &str = "01949fcc-7d92-7e9c-aaaa-bbbbbbbbbbbb";

    /// Build a [`MetaDat`] with no optional MCR block and empty arg/path lists.
    /// Used as one of the round-trip fixtures (a) in the suite.
    fn fixture_minimal() -> MetaDat {
        MetaDat {
            version: META_DAT_VERSION,
            flags: 0,
            recording_id: TEST_UUID_V7.to_owned(),
            program: String::new(),
            args: vec![],
            workdir: String::new(),
            recorder_id: String::new(),
            ext_flags: 0,
            mcr: None,
            replay_launch: None,
            layout_snapshot: None,
            filter_provenance: vec![],
            has_filter_provenance: false,
        }
    }

    /// Build a [`MetaDat`] with populated args, but no MCR block.
    /// Round-trip fixture (b).
    fn fixture_with_args() -> MetaDat {
        MetaDat {
            version: META_DAT_VERSION,
            flags: 0,
            recording_id: TEST_UUID_V7.to_owned(),
            program: "/usr/bin/ruby".to_owned(),
            args: vec!["script.rb".to_owned(), "--flag".to_owned(), "".to_owned()],
            workdir: "/home/user/proj".to_owned(),
            recorder_id: "ruby".to_owned(),
            ext_flags: 0,
            mcr: None,
            replay_launch: None,
            layout_snapshot: None,
            filter_provenance: vec![],
            has_filter_provenance: false,
        }
    }

    /// Build a [`MetaDat`] with the full MCR block populated.
    /// Round-trip fixture (c).
    fn fixture_with_mcr() -> MetaDat {
        MetaDat {
            version: META_DAT_VERSION,
            flags: FLAG_HAS_MCR_FIELDS,
            recording_id: TEST_UUID_V7.to_owned(),
            program: "main".to_owned(),
            args: vec!["arg0".to_owned()],
            workdir: "/tmp/run".to_owned(),
            recorder_id: "evm".to_owned(),
            ext_flags: 0,
            mcr: Some(McrFields {
                tick_source: 2,
                total_threads: 4,
                atomic_mode: 1,
                total_events: 1_234_567,
                total_checkpoints: 42,
                start_time_unix_us: 1_715_000_000_000_000,
                platform: "linux-x86_64".to_owned(),
                tick_granularity: "instruction".to_owned(),
                tick_source_str: "rdtsc".to_owned(),
                atomic_mode_str: "seq_cst".to_owned(),
                start_time_str: "2024-05-06T12:00:00Z".to_owned(),
                hook_profile: "dotnet".to_owned(),
                hook_strategies: vec![
                    "ldpreload".to_owned(),
                    "seccomp_unotify".to_owned(),
                    "callsite_patch".to_owned(),
                ],
            }),
            replay_launch: None,
            layout_snapshot: None,
            filter_provenance: vec![],
            has_filter_provenance: false,
        }
    }

    #[test]
    fn varint_roundtrip_boundaries() {
        // Values chosen to exercise 1, 2, 5, and 10 byte LEB128 lengths.
        for v in [0u64, 1, 0x7F, 0x80, 0x3FFF, 0x4000, 1 << 35, u64::MAX] {
            let mut buf = Vec::new();
            encode_varint(v, &mut buf);
            let mut pos = 0;
            let decoded = decode_varint(&buf, &mut pos).expect("decode");
            assert_eq!(decoded, v, "round-trip failed for {v}");
            assert_eq!(pos, buf.len(), "decoder did not consume entire varint for {v}");
        }
    }

    #[test]
    fn varint_eof_returns_error() {
        // 0x80 with no continuation byte is a truncated varint.
        let buf = [0x80u8];
        let mut pos = 0;
        assert_eq!(decode_varint(&buf, &mut pos), Err(MetaDatError::VarintEof));
    }

    #[test]
    fn varint_too_long_returns_error() {
        // 11 bytes all with continuation bit set — exceeds the 10-byte LEB128 limit.
        let buf = [0x80u8; 11];
        let mut pos = 0;
        assert_eq!(decode_varint(&buf, &mut pos), Err(MetaDatError::VarintTooLong));
    }

    #[test]
    fn meta_dat_roundtrip_minimal() {
        let original = fixture_minimal();
        let bytes = serialize_meta_dat(&original);
        let parsed = parse_meta_dat(&bytes).expect("parse minimal");
        assert_eq!(parsed, original);
    }

    #[test]
    fn meta_dat_roundtrip_args() {
        let original = fixture_with_args();
        let bytes = serialize_meta_dat(&original);
        let parsed = parse_meta_dat(&bytes).expect("parse args");
        assert_eq!(parsed, original);
    }

    #[test]
    fn meta_dat_roundtrip_mcr() {
        let original = fixture_with_mcr();
        let bytes = serialize_meta_dat(&original);
        let parsed = parse_meta_dat(&bytes).expect("parse mcr");
        assert_eq!(parsed, original);
    }

    /// Writer-compatibility test: byte-for-byte fixture hand-derived from
    /// the format spec in this module's docs.
    ///
    /// The fixture corresponds to the `MetaDat` value:
    ///
    /// ```text
    /// MetaDat {
    ///     version: META_DAT_VERSION,
    ///     flags: 0,
    ///     recording_id: "01949fcc-7d92-7e9c-aaaa-bbbbbbbbbbbb",
    ///     program: "hi",
    ///     args: ["a"],
    ///     workdir: "/w",
    ///     recorder_id: "r",
    ///     ext_flags: 0,
    ///     mcr: None,
    /// }
    /// ```
    ///
    /// This fixture is the contract between the Nim writer at
    /// `codetracer-trace-format-nim/src/codetracer_trace_writer/meta_dat.nim`
    /// (`writeMetaDatToBuffer`) and this Rust reader. It is hand-derived
    /// from the format specification, NOT from
    /// [`serialize_meta_dat`], so it stays meaningful even if the Rust
    /// serializer drifts.
    fn writer_compat_fixture_bytes() -> Vec<u8> {
        let mut buf: Vec<u8> = Vec::new();
        buf.extend_from_slice(&META_DAT_MAGIC); // "CTMD"
        buf.extend_from_slice(&META_DAT_VERSION.to_le_bytes()); // version
        buf.extend_from_slice(&0u16.to_le_bytes()); // flags
        buf.extend_from_slice(&0u32.to_le_bytes()); // flags_ext
        encode_varint(TEST_UUID_V7.len() as u64, &mut buf);
        buf.extend_from_slice(TEST_UUID_V7.as_bytes());
        encode_varint(2, &mut buf); // program "hi"
        buf.extend_from_slice(b"hi");
        encode_varint(1, &mut buf); // args_count
        encode_varint(1, &mut buf); // args[0] "a"
        buf.extend_from_slice(b"a");
        encode_varint(2, &mut buf); // workdir "/w"
        buf.extend_from_slice(b"/w");
        encode_varint(1, &mut buf); // recorder_id "r"
        buf.extend_from_slice(b"r");
        buf
    }

    #[test]
    fn writer_compatibility_fixture() {
        let bytes = writer_compat_fixture_bytes();
        let parsed = parse_meta_dat(&bytes).expect("parse fixture");
        let expected = MetaDat {
            version: META_DAT_VERSION,
            flags: 0,
            recording_id: TEST_UUID_V7.to_owned(),
            program: "hi".to_owned(),
            args: vec!["a".to_owned()],
            workdir: "/w".to_owned(),
            recorder_id: "r".to_owned(),
            ext_flags: 0,
            mcr: None,
            replay_launch: None,
            layout_snapshot: None,
            filter_provenance: vec![],
            has_filter_provenance: false,
        };
        assert_eq!(parsed, expected);

        // Sanity check: our own serializer matches the hand-derived bytes
        // for the same input. If this fails, the serializer has drifted
        // from the canonical format.
        let serialized = serialize_meta_dat(&expected);
        assert_eq!(serialized, bytes);
    }

    /// M-REC-1.5: legacy v1/v2 payloads must be rejected because pre-1.0
    /// the spec drops backwards compatibility.
    #[test]
    fn rejects_legacy_v1_payload() {
        let mut buf: Vec<u8> = Vec::new();
        buf.extend_from_slice(&META_DAT_MAGIC);
        buf.extend_from_slice(&1u16.to_le_bytes());
        buf.extend_from_slice(&0u16.to_le_bytes());
        assert_eq!(parse_meta_dat(&buf), Err(MetaDatError::UnsupportedVersion(1)));
    }

    #[test]
    fn rejects_legacy_v2_payload() {
        let mut buf: Vec<u8> = Vec::new();
        buf.extend_from_slice(&META_DAT_MAGIC);
        buf.extend_from_slice(&2u16.to_le_bytes());
        buf.extend_from_slice(&0u16.to_le_bytes());
        assert_eq!(parse_meta_dat(&buf), Err(MetaDatError::UnsupportedVersion(2)));
    }

    /// A header at the last pre-correction schema version is refused, and the
    /// refusal says what reading it anyway would do.
    ///
    /// The fixture is the header this serializer emits with only the version
    /// field set back, because the serializer can no longer produce one — that
    /// is what the bump means. Every other byte is what a writer at that
    /// version wrote, so the container is refused for its VERSION and not for
    /// some incidental malformation.
    #[test]
    fn a_container_from_before_the_line_index_correction_is_refused_by_name() {
        let mut buf = serialize_meta_dat(&MetaDat {
            version: META_DAT_VERSION,
            flags: 0,
            recording_id: TEST_UUID_V7.to_owned(),
            program: "prog".to_owned(),
            args: vec![],
            workdir: "/w".to_owned(),
            recorder_id: "r".to_owned(),
            ext_flags: 0,
            mcr: None,
            replay_launch: None,
            layout_snapshot: None,
            filter_provenance: vec![],
            has_filter_provenance: false,
        });
        parse_meta_dat(&buf).expect("the header this serializer emits must parse before it is aged");

        buf[4..6].copy_from_slice(&LAST_SHIFTED_GLOBAL_INDEX_VERSION.to_le_bytes());
        let err = parse_meta_dat(&buf).expect_err("a pre-correction container must be refused");
        assert_eq!(err, MetaDatError::UnsupportedVersion(LAST_SHIFTED_GLOBAL_INDEX_VERSION));

        let msg = err.to_string();
        assert!(msg.contains("one line high"), "must name the consequence: {msg}");
        assert!(
            msg.contains("prefix_sum[file_id] + line"),
            "must name the superseded encode: {msg}"
        );
        assert!(msg.contains("Re-record"), "must name the remedy: {msg}");
    }

    /// The accepted set is exactly the current version. Written as a
    /// membership check rather than an equality on the slice so it states the
    /// property that matters: no version at or below the correction bound is
    /// readable, whatever else the set grows to hold later.
    #[test]
    fn no_version_at_or_below_the_correction_bound_is_accepted() {
        for v in 0..=LAST_SHIFTED_GLOBAL_INDEX_VERSION {
            assert!(
                !SUPPORTED_VERSIONS.contains(&v),
                "version {v} predates the global line index correction and must not be readable"
            );
        }
        assert!(SUPPORTED_VERSIONS.contains(&META_DAT_VERSION));
    }

    /// M-REC-1.5 end-to-end: the parser rejects a trace whose
    /// recording_id is not a canonical UUIDv7.
    #[test]
    fn rejects_invalid_recording_id() {
        let bad = "not-a-valid-uuid";
        let mut buf: Vec<u8> = Vec::new();
        buf.extend_from_slice(&META_DAT_MAGIC);
        buf.extend_from_slice(&META_DAT_VERSION.to_le_bytes());
        buf.extend_from_slice(&0u16.to_le_bytes());
        buf.extend_from_slice(&0u32.to_le_bytes());
        encode_varint(bad.len() as u64, &mut buf);
        buf.extend_from_slice(bad.as_bytes());
        match parse_meta_dat(&buf) {
            Err(MetaDatError::InvalidRecordingId { value }) => {
                assert_eq!(value, bad);
            }
            other => panic!("expected InvalidRecordingId, got {other:?}"),
        }
    }

    #[test]
    fn rejects_truncated_input() {
        let header = writer_compat_fixture_bytes();
        for len in 0..12 {
            match parse_meta_dat(&header[..len]) {
                Err(MetaDatError::TooShort { got }) => assert_eq!(got, len),
                other => panic!("expected TooShort for {len} bytes, got {other:?}"),
            }
        }
    }

    #[test]
    fn rejects_bad_magic() {
        let mut buf = writer_compat_fixture_bytes();
        buf[0] = 0xFF;
        assert_eq!(parse_meta_dat(&buf), Err(MetaDatError::BadMagic));
    }

    #[test]
    fn rejects_unsupported_version() {
        let mut buf = writer_compat_fixture_bytes();
        buf[4] = 99;
        buf[5] = 0;
        assert_eq!(parse_meta_dat(&buf), Err(MetaDatError::UnsupportedVersion(99)));
    }

    /// The refusal names the version it saw and the one this reader reads.
    #[test]
    fn unsupported_version_message_names_the_version_read() {
        assert_eq!(SUPPORTED_VERSIONS, &[META_DAT_VERSION]);
        let msg = MetaDatError::UnsupportedVersion(99).to_string();
        assert!(
            msg.contains("version 99") && msg.contains(&format!("version {META_DAT_VERSION}")),
            "the refusal must name the version it saw and the one it reads; got: {msg}"
        );
    }

    #[test]
    fn rejects_unknown_flag_bits() {
        // THE PROBE IS RETIRED, AND ITS ABSENCE IS THE ASSERTION.
        //
        // This test used to set the lowest still-reserved bit and require
        // `parse_meta_dat` to refuse it, following the reserved range down as
        // bits 8..=13 were allocated. Bit 14 went to FLAG_HAS_LINE_COUNT_TABLE
        // and bit 15 to FLAG_HAS_CORRELATION_INDEX, so KNOWN_FLAGS_MASK is now
        // the whole word and there is no flag value this reader can honestly
        // call unknown. Crafting one would mean asserting against a bit the
        // reader is supposed to know — a test of nothing.
        //
        // What stands in its place is the invariant that made the probe
        // impossible. It fails the moment a bit is freed or the flag word
        // grows, which is exactly the change that has to reinstate a probe
        // against whatever that growth defines as unknown.
        assert_eq!(
            !KNOWN_FLAGS_MASK, 0,
            "the flag word is exhausted; if this fails, a bit was freed or the \
             field grew, and the unknown-flag probe this replaced must be \
             reinstated against whatever is unknown now"
        );

        // The rejection PATH stays covered by the other half of the same
        // contract: a version this reader does not know is still refused.
        let mut buf = writer_compat_fixture_bytes();
        buf[4] = 99;
        buf[5] = 0;
        assert_eq!(parse_meta_dat(&buf), Err(MetaDatError::UnsupportedVersion(99)));
    }

    /// WTCI — the `FLAG_HAS_CORRELATION_INDEX` bit (15) parses cleanly.
    ///
    /// Same "readers before writers" guarantee bit 13 records: an unknown bit
    /// is rejecting, so before this constant existed the db-backend refused
    /// every recording that declared a correlation marker — not because it
    /// needed the index, but because it did not recognise the announcement of
    /// one.
    #[test]
    fn accepts_has_correlation_index_flag() {
        let mut buf = writer_compat_fixture_bytes();
        buf[6] = (FLAG_HAS_CORRELATION_INDEX & 0xFF) as u8;
        buf[7] = (FLAG_HAS_CORRELATION_INDEX >> 8) as u8;
        let parsed = parse_meta_dat(&buf).expect("bit 15 must parse cleanly");
        assert_eq!(parsed.flags & FLAG_HAS_CORRELATION_INDEX, FLAG_HAS_CORRELATION_INDEX);
    }

    /// Bit 14 is a REJECTING bit, so before this constant existed the
    /// db-backend refused every count-bearing container outright. Adding it to
    /// [`KNOWN_FLAGS_MASK`] is what makes such a container openable at all —
    /// the "readers before writers" rollout, same as bit 13's.
    #[test]
    fn accepts_has_line_count_table_flag() {
        let mut buf = writer_compat_fixture_bytes();
        buf[6..8].copy_from_slice(&FLAG_HAS_LINE_COUNT_TABLE.to_le_bytes());
        let meta = parse_meta_dat(&buf).expect("bit 14 must parse cleanly");
        assert_eq!(meta.flags & FLAG_HAS_LINE_COUNT_TABLE, FLAG_HAS_LINE_COUNT_TABLE);
        assert_eq!(meta.flags & FLAG_HAS_COLUMN_AWARE_STEPS, 0);
    }

    /// Bits 4 and 14 each select a `paths.dat` record layout, and a record is
    /// in one layout or the other. A header setting both is refused in front of
    /// every consumer rather than resolved by preference: the wrong choice does
    /// not fail downstream, it answers with a path that has its own length
    /// prefix inside it and a per-file size that was never written.
    #[test]
    fn rejects_both_path_layout_flags() {
        let both = FLAG_HAS_COLUMN_AWARE_STEPS | FLAG_HAS_LINE_COUNT_TABLE;
        let mut buf = writer_compat_fixture_bytes();
        buf[6..8].copy_from_slice(&both.to_le_bytes());
        match parse_meta_dat(&buf) {
            Err(MetaDatError::ConflictingPathLayouts { flags }) => assert_eq!(flags, both),
            other => panic!("expected ConflictingPathLayouts, got {other:?}"),
        }

        // The control: each bit ALONE parses, so the rejection is about the
        // combination and not about either bit being unknown.
        for one in [FLAG_HAS_COLUMN_AWARE_STEPS, FLAG_HAS_LINE_COUNT_TABLE] {
            let mut solo = writer_compat_fixture_bytes();
            solo[6..8].copy_from_slice(&one.to_le_bytes());
            parse_meta_dat(&solo).unwrap_or_else(|e| panic!("flag {one:#06x} alone must parse: {e}"));
        }
    }

    /// RS-M2 — the `has_span_stream` flag (bit 13) parses cleanly.
    ///
    /// This is the "readers before writers" guarantee in
    /// `codetracer-specs/Trace-Files/CTFS-Request-Span-Streams.md`: bit 13 is a
    /// REJECTING bit, so before this constant existed the db-backend refused
    /// every span-bearing container outright.  Adding it to
    /// [`KNOWN_FLAGS_MASK`] is what makes such a container openable at all.
    #[test]
    fn accepts_has_span_stream_flag() {
        let mut buf = writer_compat_fixture_bytes();
        buf[6] = (FLAG_HAS_SPAN_STREAM & 0xFF) as u8;
        buf[7] = ((FLAG_HAS_SPAN_STREAM >> 8) & 0xFF) as u8;
        let parsed = parse_meta_dat(&buf).unwrap_or_else(|e| panic!("expected has_span_stream to parse, got {e:?}"));
        assert_eq!(parsed.flags & FLAG_HAS_SPAN_STREAM, FLAG_HAS_SPAN_STREAM);
    }

    /// M17b — the `has_call_stream` flag (bit 8) parses cleanly (it is a KNOWN
    /// flag now, so a split bundle's meta.dat is accepted, not rejected as a
    /// "newer writer"). Regression guard for the db-backend seekable reader.
    #[test]
    fn accepts_has_call_stream_flag() {
        let mut buf = writer_compat_fixture_bytes();
        buf[6] = (FLAG_HAS_CALL_STREAM & 0xFF) as u8;
        buf[7] = ((FLAG_HAS_CALL_STREAM >> 8) & 0xFF) as u8;
        let parsed = parse_meta_dat(&buf).unwrap_or_else(|e| panic!("expected has_call_stream to parse, got {e:?}"));
        assert_eq!(parsed.flags & FLAG_HAS_CALL_STREAM, FLAG_HAS_CALL_STREAM);
    }

    /// M23a — the `has_step_stream` flag (bit 9) parses cleanly (it is a KNOWN
    /// flag now, so a step-split bundle's meta.dat is accepted, not rejected as a
    /// "newer writer"). Regression guard so the GUI/db-backend still OPEN a
    /// `has_step_stream` bundle (mirrors `accepts_has_call_stream_flag` for the
    /// M17b call-stream split).
    #[test]
    fn accepts_has_step_stream_flag() {
        // The step stream ships alongside the call stream, so test both the
        // step bit alone AND the combined call+step bits a real M23a bundle sets.
        for bits in [FLAG_HAS_STEP_STREAM, FLAG_HAS_CALL_STREAM | FLAG_HAS_STEP_STREAM] {
            let mut buf = writer_compat_fixture_bytes();
            buf[6] = (bits & 0xFF) as u8;
            buf[7] = ((bits >> 8) & 0xFF) as u8;
            let parsed =
                parse_meta_dat(&buf).unwrap_or_else(|e| panic!("expected bits 0x{bits:04x} to parse, got {e:?}"));
            assert_eq!(parsed.flags & bits, bits);
        }
    }

    /// M23b — the `has_value_stream` flag (bit 10) parses cleanly (it is a KNOWN
    /// flag now, so a value-split bundle's meta.dat is accepted, not rejected as
    /// a "newer writer"). Regression guard so the GUI/db-backend still OPEN a
    /// `has_value_stream` bundle (mirrors `accepts_has_step_stream_flag` for the
    /// M23a step-stream split and `accepts_has_call_stream_flag` for the M17b
    /// call-stream split).
    #[test]
    fn accepts_has_value_stream_flag() {
        // The value stream ships alongside the call+step streams, so test the
        // value bit alone AND the combined call+step+value bits a real M23b
        // bundle sets.
        for bits in [
            FLAG_HAS_VALUE_STREAM,
            FLAG_HAS_CALL_STREAM | FLAG_HAS_STEP_STREAM | FLAG_HAS_VALUE_STREAM,
        ] {
            let mut buf = writer_compat_fixture_bytes();
            buf[6] = (bits & 0xFF) as u8;
            buf[7] = ((bits >> 8) & 0xFF) as u8;
            let parsed =
                parse_meta_dat(&buf).unwrap_or_else(|e| panic!("expected bits 0x{bits:04x} to parse, got {e:?}"));
            assert_eq!(parsed.flags & bits, bits);
        }
    }

    /// M23c — the `has_io_event_stream` flag (bit 11) parses cleanly (it is a
    /// KNOWN flag now, so an io-event-split bundle's meta.dat is accepted, not
    /// rejected as a "newer writer"). Regression guard so the GUI/db-backend
    /// still OPEN a `has_io_event_stream` bundle (mirrors
    /// `accepts_has_value_stream_flag` for the M23b value-stream split).
    #[test]
    fn accepts_has_io_event_stream_flag() {
        // The I/O event stream ships alongside the call+step+value streams, so
        // test the io-event bit alone AND the combined all-four bits a real M23c
        // bundle sets.
        for bits in [
            FLAG_HAS_IO_EVENT_STREAM,
            FLAG_HAS_CALL_STREAM | FLAG_HAS_STEP_STREAM | FLAG_HAS_VALUE_STREAM | FLAG_HAS_IO_EVENT_STREAM,
        ] {
            let mut buf = writer_compat_fixture_bytes();
            buf[6] = (bits & 0xFF) as u8;
            buf[7] = ((bits >> 8) & 0xFF) as u8;
            let parsed =
                parse_meta_dat(&buf).unwrap_or_else(|e| panic!("expected bits 0x{bits:04x} to parse, got {e:?}"));
            assert_eq!(parsed.flags & bits, bits);
        }
    }

    /// M23d — the `has_interning_tables` flag (bit 12) parses cleanly (it is a
    /// KNOWN flag now, so an interning-tables bundle's meta.dat is accepted, not
    /// rejected as a "newer writer"). Regression guard so the GUI/db-backend
    /// still OPEN a `has_interning_tables` bundle (mirrors
    /// `accepts_has_io_event_stream_flag` for the M23c I/O-event-stream split).
    #[test]
    fn accepts_has_interning_tables_flag() {
        // The interning tables ship alongside the call+step+value+io-event
        // streams, so test the interning bit alone AND the combined all-five
        // bits a real M23d bundle sets.
        for bits in [
            FLAG_HAS_INTERNING_TABLES,
            FLAG_HAS_CALL_STREAM
                | FLAG_HAS_STEP_STREAM
                | FLAG_HAS_VALUE_STREAM
                | FLAG_HAS_IO_EVENT_STREAM
                | FLAG_HAS_INTERNING_TABLES,
        ] {
            let mut buf = writer_compat_fixture_bytes();
            buf[6] = (bits & 0xFF) as u8;
            buf[7] = ((bits >> 8) & 0xFF) as u8;
            let parsed =
                parse_meta_dat(&buf).unwrap_or_else(|e| panic!("expected bits 0x{bits:04x} to parse, got {e:?}"));
            assert_eq!(parsed.flags & bits, bits);
        }
    }

    /// Capability bits parse cleanly when paired with the wire-format
    /// column-aware bit.  Pins the M-capability-flags reader contract.
    #[test]
    fn accepts_column_capability_bits() {
        for bits in [
            FLAG_HAS_COLUMN_AWARE_STEPS,
            FLAG_HAS_COLUMN_AWARE_STEPS | FLAG_SUPPORTS_COLUMN_BREAKPOINTS,
            FLAG_HAS_COLUMN_AWARE_STEPS | FLAG_SUPPORTS_COLUMN_MOTIONS,
            FLAG_HAS_COLUMN_AWARE_STEPS | FLAG_SUPPORTS_COLUMN_BREAKPOINTS | FLAG_SUPPORTS_COLUMN_MOTIONS,
        ] {
            let mut buf = writer_compat_fixture_bytes();
            buf[6] = (bits & 0xFF) as u8;
            buf[7] = ((bits >> 8) & 0xFF) as u8;
            let parsed = parse_meta_dat(&buf)
                .unwrap_or_else(|e| panic!("expected bits 0x{bits:04x} to parse cleanly, got {e:?}"));
            assert_eq!(parsed.flags, bits);
        }
    }

    #[test]
    fn parses_replay_launch_fields() {
        // FLAG_HAS_REPLAY_LAUNCH_FIELDS (bit 1) with `aslr_disabled = true`
        // appended as a single byte after `recorder_id`.
        let mut buf = writer_compat_fixture_bytes();
        buf[6] = 0b0000_0010;
        buf[7] = 0;
        buf.push(1u8);
        let parsed = parse_meta_dat(&buf).expect("parse replay-launch");
        assert_eq!(parsed.replay_launch, Some(ReplayLaunchFields { aslr_disabled: true }));
        assert!(parsed.layout_snapshot.is_none());
    }

    #[test]
    fn parses_layout_snapshot_fields() {
        // FLAG_HAS_LAYOUT_SNAPSHOT (bit 2) with a hash + 3-byte fingerprint.
        let mut buf = writer_compat_fixture_bytes();
        buf[6] = 0b0000_0100;
        buf[7] = 0;
        buf.extend_from_slice(&0xdead_beef_1234_5678u64.to_le_bytes());
        buf.push(3); // varint length
        buf.extend_from_slice(&[0xaa, 0xbb, 0xcc]);
        let parsed = parse_meta_dat(&buf).expect("parse layout-snapshot");
        assert_eq!(
            parsed.layout_snapshot,
            Some(LayoutSnapshotFields {
                layout_hash: 0xdead_beef_1234_5678,
                layout_fingerprint: vec![0xaa, 0xbb, 0xcc],
            })
        );
        assert!(parsed.replay_launch.is_none());
    }

    #[test]
    fn parses_trace_filter_provenance() {
        // FLAG_HAS_TRACE_FILTER_PROVENANCE (bit 3) with one entry.
        let mut buf = writer_compat_fixture_bytes();
        buf[6] = 0b0000_1000;
        buf[7] = 0;
        encode_varint(1, &mut buf); // count = 1
        encode_varint(4, &mut buf); // path "abcd"
        buf.extend_from_slice(b"abcd");
        let sha = [0x42u8; 32];
        buf.extend_from_slice(&sha);
        let parsed = parse_meta_dat(&buf).expect("parse trace-filter provenance");
        assert!(parsed.has_filter_provenance);
        assert_eq!(parsed.filter_provenance.len(), 1);
        assert_eq!(parsed.filter_provenance[0].path, "abcd");
        assert_eq!(parsed.filter_provenance[0].sha256, sha);
    }

    #[test]
    fn roundtrips_all_optional_blocks() {
        // Build a fixture with all optional blocks present, serialise,
        // parse, and confirm byte-for-byte equality.
        let original = MetaDat {
            version: META_DAT_VERSION,
            flags: FLAG_HAS_REPLAY_LAUNCH_FIELDS | FLAG_HAS_LAYOUT_SNAPSHOT | FLAG_HAS_TRACE_FILTER_PROVENANCE,
            recording_id: TEST_UUID_V7.to_owned(),
            program: "p".to_owned(),
            args: vec![],
            workdir: "w".to_owned(),
            recorder_id: "r".to_owned(),
            ext_flags: 0,
            mcr: None,
            replay_launch: Some(ReplayLaunchFields { aslr_disabled: false }),
            layout_snapshot: Some(LayoutSnapshotFields {
                layout_hash: 0x0102_0304_0506_0708,
                layout_fingerprint: b"\xde\xad".to_vec(),
            }),
            filter_provenance: vec![FilterProvenanceEntry {
                path: "filters/foo.toml".to_owned(),
                sha256: [0x33; 32],
            }],
            has_filter_provenance: true,
        };
        let bytes = serialize_meta_dat(&original);
        let parsed = parse_meta_dat(&bytes).expect("parse round-trip");
        assert_eq!(parsed, original);
    }

    #[test]
    fn rejects_truncated_string() {
        // Header + recording_id + program varint(5) but only 1 byte of "h" — the
        // string extends past EOF.
        let mut buf: Vec<u8> = Vec::new();
        buf.extend_from_slice(&META_DAT_MAGIC);
        buf.extend_from_slice(&META_DAT_VERSION.to_le_bytes());
        buf.extend_from_slice(&0u16.to_le_bytes());
        buf.extend_from_slice(&0u32.to_le_bytes());
        encode_varint(TEST_UUID_V7.len() as u64, &mut buf);
        buf.extend_from_slice(TEST_UUID_V7.as_bytes());
        encode_varint(5, &mut buf); // program varint(5)
        buf.push(b'h'); // only 1 byte of declared 5
        match parse_meta_dat(&buf) {
            Err(MetaDatError::StringEof {
                declared_len,
                remaining,
            }) => {
                assert_eq!(declared_len, 5);
                assert_eq!(remaining, 1);
            }
            other => panic!("expected StringEof, got {other:?}"),
        }
    }

    #[test]
    fn rejects_invalid_utf8() {
        // Construct a payload where `program` is two bytes of invalid UTF-8.
        let mut buf: Vec<u8> = Vec::new();
        buf.extend_from_slice(&META_DAT_MAGIC);
        buf.extend_from_slice(&META_DAT_VERSION.to_le_bytes());
        buf.extend_from_slice(&0u16.to_le_bytes());
        buf.extend_from_slice(&0u32.to_le_bytes());
        encode_varint(TEST_UUID_V7.len() as u64, &mut buf);
        buf.extend_from_slice(TEST_UUID_V7.as_bytes());
        let program_start = buf.len() + 1; // past the varint(2) byte
        encode_varint(2, &mut buf); // program varint(2)
        buf.extend_from_slice(&[0xFF, 0xFE]); // invalid UTF-8
        // Remaining fields are best-effort — UTF-8 error fires first.
        match parse_meta_dat(&buf) {
            Err(MetaDatError::InvalidUtf8 { offset, .. }) => {
                assert_eq!(offset, program_start);
            }
            other => panic!("expected InvalidUtf8, got {other:?}"),
        }
    }

    #[test]
    fn rejects_trailing_bytes() {
        let mut buf = writer_compat_fixture_bytes();
        buf.extend_from_slice(&[0xAA, 0xBB]);
        match parse_meta_dat(&buf) {
            Err(MetaDatError::TrailingBytes { extra }) => assert_eq!(extra, 2),
            other => panic!("expected TrailingBytes, got {other:?}"),
        }
    }

    #[test]
    fn is_canonical_uuid_v7_validates_format() {
        // Happy paths
        assert!(is_canonical_uuid_v7(TEST_UUID_V7));
        assert!(is_canonical_uuid_v7("01949fcc-7d92-7e9c-8000-000000000000"));
        assert!(is_canonical_uuid_v7("ffffffff-ffff-7fff-bfff-ffffffffffff"));

        // Wrong length
        assert!(!is_canonical_uuid_v7(""));
        assert!(!is_canonical_uuid_v7("01949fcc-7d92-7e9c-aaaa-bbbbbbbbbbb")); // 35 chars
        assert!(!is_canonical_uuid_v7("01949fcc-7d92-7e9c-aaaa-bbbbbbbbbbbbb")); // 37 chars

        // Wrong version nibble (4 instead of 7)
        assert!(!is_canonical_uuid_v7("01949fcc-7d92-4e9c-aaaa-bbbbbbbbbbbb"));

        // Wrong variant nibble (c — only 8/9/a/b allowed)
        assert!(!is_canonical_uuid_v7("01949fcc-7d92-7e9c-caaa-bbbbbbbbbbbb"));

        // Missing a hyphen
        assert!(!is_canonical_uuid_v7("01949fcc-7d92-7e9c-aaaa.bbbbbbbbbbbb"));

        // Uppercase rejected (canonical form is lowercase)
        assert!(!is_canonical_uuid_v7("01949FCC-7D92-7E9C-AAAA-BBBBBBBBBBBB"));
    }

    #[test]
    fn error_display_messages_are_meaningful() {
        // Smoke-check that Display impl produces non-empty text for each variant.
        let cases = [
            MetaDatError::TooShort { got: 3 },
            MetaDatError::BadMagic,
            MetaDatError::UnsupportedVersion(7),
            MetaDatError::UnknownFlags {
                flags: 0xFF,
                unknown_bits: 0xFE,
            },
            MetaDatError::VarintEof,
            MetaDatError::VarintTooLong,
            MetaDatError::StringEof {
                declared_len: 10,
                remaining: 4,
            },
            MetaDatError::StringTooLong(u64::MAX),
            MetaDatError::TrailingBytes { extra: 5 },
            MetaDatError::InvalidRecordingId {
                value: "bad".to_owned(),
            },
        ];
        for case in cases {
            let s = format!("{case}");
            assert!(!s.is_empty(), "Display produced empty string for {case:?}");
        }
    }

    // ── Version 6 (internal-files.md §"Metadata (meta.dat)") ─────────────

    /// A version 6 header built from the specification, byte by byte:
    /// `flags_ext` always present, and nothing after `recorder_id` but the
    /// flag-gated blocks.
    fn v6_bytes(flags: u16, ext: u32) -> Vec<u8> {
        let mut buf: Vec<u8> = Vec::new();
        buf.extend_from_slice(b"CTMD");
        buf.extend_from_slice(&6u16.to_le_bytes());
        buf.extend_from_slice(&flags.to_le_bytes());
        buf.extend_from_slice(&ext.to_le_bytes());
        buf.push(TEST_UUID_V7.len() as u8);
        buf.extend_from_slice(TEST_UUID_V7.as_bytes());
        buf.extend_from_slice(&[2, b'h', b'i']); // program
        buf.extend_from_slice(&[1, 1, b'a']); // args = ["a"]
        buf.extend_from_slice(&[2, b'/', b'w']); // workdir
        buf.extend_from_slice(&[1, b'r']); // recorder_id
        buf
    }

    #[test]
    fn a_version_6_header_parses_with_its_ext_word_and_no_path_list() {
        let m = parse_meta_dat(&v6_bytes(0, 0)).expect("a version 6 header with flags_ext 0 must parse");
        assert_eq!(m.version, 6);
        assert_eq!(m.recording_id, TEST_UUID_V7);
        assert_eq!(m.program, "hi");
        assert_eq!(m.args, vec!["a".to_owned()]);
        assert_eq!(m.workdir, "/w");
        assert_eq!(m.recorder_id, "r");

        let reload = parse_meta_dat(&v6_bytes(0, 1)).expect("flags_ext bit 0 is known");
        assert_eq!(reload.program, "hi", "the body starts after the ext word");
    }

    /// The bytes after `recorder_id` are the next flag-gated block or nothing;
    /// a version 5 path list there is not read as one.
    #[test]
    fn a_path_list_after_recorder_id_is_not_read() {
        let mut buf = v6_bytes(0, 0);
        buf.extend_from_slice(&[1, 1, b'x']);
        assert_eq!(parse_meta_dat(&buf), Err(MetaDatError::TrailingBytes { extra: 3 }));
    }

    /// Every version but 6 is refused, naming the version it found and the
    /// one this reader reads -- including a real version 5 header from the Nim
    /// writer, whose path list would otherwise be read as an MCR block.
    #[test]
    fn every_version_but_6_is_refused_by_name() {
        for v in [1u16, 2, 3, 4, 5, 7, 99] {
            let mut buf = v6_bytes(0, 0);
            buf[4..6].copy_from_slice(&v.to_le_bytes());
            let err = parse_meta_dat(&buf).expect_err("another version must be refused");
            assert_eq!(err, MetaDatError::UnsupportedVersion(v));
            let msg = err.to_string();
            assert!(
                msg.contains(&format!("version {v}")) && msg.contains('6'),
                "the refusal names neither the version found nor the one read: {msg}"
            );
        }
        assert_eq!(
            parse_meta_dat(NIM_WRITTEN_V5_META_DAT),
            Err(MetaDatError::UnsupportedVersion(5))
        );
    }

    #[test]
    fn a_version_6_header_shorter_than_12_bytes_is_refused() {
        let buf = v6_bytes(0, 0);
        for len in 8..12 {
            assert!(parse_meta_dat(&buf[..len]).is_err(), "a {len}-byte header was accepted");
        }
    }

    #[test]
    fn an_unknown_ext_bit_is_refused_by_name() {
        let err = parse_meta_dat(&v6_bytes(0, 1 << 8)).expect_err("an unknown ext bit must be refused");
        assert_eq!(
            err,
            MetaDatError::UnknownExtendedFlags {
                ext_flags: 1 << 8,
                unknown_bits: 1 << 8
            }
        );
    }

    /// The serializer writes exactly the specified bytes: version 6, the ext
    /// word, and no path list.
    #[test]
    fn the_serializer_writes_version_6() {
        let mut m = fixture_minimal();
        m.program = "hi".to_owned();
        m.args = vec!["a".to_owned()];
        m.workdir = "/w".to_owned();
        m.recorder_id = "r".to_owned();
        assert_eq!(serialize_meta_dat(&m), v6_bytes(0, 0));
    }

    /// Capability and stream-presence bits are written as given, and the
    /// extended flag word too: a test writer that declares a split stream or a
    /// source-reload capability gets a header that says so.
    #[test]
    fn the_serializer_keeps_capability_stream_and_extended_bits() {
        let mut m = fixture_minimal();
        m.flags = FLAG_HAS_STEP_STREAM | FLAG_HAS_CALL_STREAM | FLAG_HAS_COLUMN_AWARE_STEPS;
        m.ext_flags = FLAG_EXT_HAS_SOURCE_RELOAD;
        let parsed = parse_meta_dat(&serialize_meta_dat(&m)).expect("parse");
        assert_eq!(parsed, m);
    }
}
