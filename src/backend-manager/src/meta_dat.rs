//! Pure-Rust reader for CTFS `meta.dat` payloads, vendored for the
//! backend-manager so it can extract per-trace metadata without depending
//! on the heavier `codetracer_trace_types`/`replay-server` crates.
//!
//! The wire format is the layout introduced in M-REC-1 and pinned by
//! M-REC-1.5: pre-1.0, no backcompat for superseded versions.  The canonical
//! reference parser is in
//! `codetracer/src/db-backend/src/ctfs_trace_reader/meta_dat.rs`; the two
//! implementations stay byte-compatible by construction (they both
//! follow the spec in `codetracer-trace-format-spec/internal-files.md`).
//!
//! Only a subset of the full meta.dat surface that backend-manager needs
//! is decoded:
//! - `recording_id`
//! - `program`, `args`, `workdir`
//! - `MCR.total_events` (when present)
//!
//! The CTFS container reader here is also a minimal subset: enough to
//! read an internal file (`meta.dat`, and the `paths.dat` / `paths.off`
//! interning table that is a trace's only list of source paths) out of a
//! version 5 `.ct` archive.  The full
//! CTFS reader lives in `db-backend`; we don't want to drag it in just to
//! pull one file out of one container.

use std::error::Error;
use std::fmt;
// std::path::Path is only referenced by the #[cfg(test)] helpers
// (`write_minimal_ctfs` etc. at the bottom of this file); gating the
// import the same way keeps non-test clippy clean.
#[cfg(test)]
use std::path::Path;

// ── meta.dat constants ───────────────────────────────────────────────────

/// Magic bytes identifying a `meta.dat` payload: ASCII "CTMD".
pub const META_DAT_MAGIC: [u8; 4] = [0x43, 0x54, 0x4D, 0x44];

/// Canonical meta.dat format version: v6 (no path list after
/// `recorder_id`; `flags_ext` always present).
///
/// Pre-1.0, CodeTracer enforces a strict no-backcompat policy on the
/// trace format: every recorder is required to track the current
/// `meta.dat` version, and old fixtures must be regenerated whenever
/// the version is bumped.  See
/// `codetracer-specs/Refactoring-Plans/Recording-Identifier-Migration.md`
/// § 3 and the M-REC-1 / M-REC-1.5 milestones for the rationale.
///
/// Concretely this means [`SUPPORTED_META_DAT_VERSIONS`] holds no version
/// before [`META_DAT_VERSION`]; any older payload encountered in the wild is a
/// stale build artefact (e.g. an out-of-date
/// `libcodetracer_trace_writer.a` static library) and must be
/// rebuilt rather than worked around at the reader.
///
/// This number must equal the db-backend's
/// `ctfs_trace_reader::meta_dat::META_DAT_VERSION` and the Nim writer's
/// `MetaDatVersion`.  The three read the same containers, so a number
/// that moves in one place and not the others turns "this recording is
/// too old" into "this tool is too old" for exactly the recordings the
/// others open — a v4 recording would open in the debugger and be
/// refused by `ct trace info` on the same file.
pub const META_DAT_VERSION: u16 = 6;

/// The set of `meta.dat` versions this parser accepts on read: version 6
/// alone.
///
/// Versions 5 and below wrote a path list after `recorder_id`, where
/// version 6 has the flag-gated blocks, so neither can be read as the other;
/// pre-1.0 there is no compatibility path, and older recordings are
/// re-recorded (`codetracer-trace-format-spec/internal-files.md`
/// §"Metadata (meta.dat)", "Version History").
pub const SUPPORTED_META_DAT_VERSIONS: &[u16] = &[META_DAT_VERSION];

/// Extended flag bit 0 (global bit 16) — the execution stream may contain
/// step-event tag `0x08` (`TagSourceReload`), the source-version transition
/// marker of a GDScript hot reload.
pub const FLAG_EXT_HAS_SOURCE_RELOAD: u32 = 1 << 0;

/// Bitmask of all EXTENDED flag bits this implementation understands.  Any
/// bit outside it is rejected, exactly as `KNOWN_FLAGS_MASK` does for the
/// u16: validating one word and not the other would let a container declare
/// a stream shape this reader cannot decode.
const KNOWN_EXT_FLAGS_MASK: u32 = FLAG_EXT_HAS_SOURCE_RELOAD;

// The canonical flag list lives in
// `src/db-backend/src/ctfs_trace_reader/meta_dat.rs` (and mirrors the Nim
// writer's `meta_dat.nim`).  This module is a second, smaller reader for
// the fields backend-manager needs, and its mask MUST cover the same bits:
// a bit outside `KNOWN_FLAGS_MASK` makes `parse_meta_dat` reject the whole
// container, which takes down every backend-manager trace surface
// (`ct trace info` / `query` / `origin`, and all the MCP tools) for a
// recording the db-backend opens perfectly well.  Bits 4..13 were added to
// the canonical reader without being mirrored here, so every trace from a
// current recorder failed with "unknown flag bits set".
//
// Blocks gated by bits 4..13 live in CTFS files or in the step stream, not
// in the `meta.dat` tail this parser walks, so recognising them costs
// nothing beyond letting the container open.
const FLAG_HAS_MCR_FIELDS: u16 = 1 << 0;
const FLAG_HAS_REPLAY_LAUNCH_FIELDS: u16 = 1 << 1;
const FLAG_HAS_LAYOUT_SNAPSHOT: u16 = 1 << 2;
const FLAG_HAS_TRACE_FILTER_PROVENANCE: u16 = 1 << 3;
/// Bit 4 — column-aware step encoding (P6.3 / P6.4).
const FLAG_HAS_COLUMN_AWARE_STEPS: u16 = 1 << 4;
/// Bit 5 — alternate source views (`srcviews.dat` / `srcviews.off`).
const FLAG_HAS_ALTERNATE_SOURCE_VIEWS: u16 = 1 << 5;
/// Bit 6 — recorder advertises per-column breakpoint placement.
const FLAG_SUPPORTS_COLUMN_BREAKPOINTS: u16 = 1 << 6;
/// Bit 7 — recorder advertises per-column step motions.
const FLAG_SUPPORTS_COLUMN_MOTIONS: u16 = 1 << 7;
/// Bit 8 — dedicated `calls.dat` call stream (M17a/M17b).
const FLAG_HAS_CALL_STREAM: u16 = 1 << 8;
/// Bit 9 — dedicated `steps.dat` execution stream (M23a).
const FLAG_HAS_STEP_STREAM: u16 = 1 << 9;
/// Bit 10 — dedicated `values.dat` value stream (M23b).
const FLAG_HAS_VALUE_STREAM: u16 = 1 << 10;
/// Bit 11 — dedicated `events.dat` I/O event stream (M23c).
const FLAG_HAS_IO_EVENT_STREAM: u16 = 1 << 11;
/// Bit 12 — binary varint interning tables (M23d).
const FLAG_HAS_INTERNING_TABLES: u16 = 1 << 12;
/// Bit 13 — `spans.dat` / `spans.idx` / `spantype.ns` span stream (RS-M1).
const FLAG_HAS_SPAN_STREAM: u16 = 1 << 13;
/// Bit 14 — every `paths.dat` record carries its file's line count, and the
/// line-only global position space is laid out from those counts rather than
/// from the 100000-addresses-per-file convention.
///
/// This crate reads `meta.dat` for the metadata fields it surfaces
/// (`recording_id`, `program`, `workdir`), none of which the bit changes;
/// it selects the `paths.dat` record layout [`read_source_paths_from_ctfs`]
/// decodes. It is in the mask because the mask REJECTS what it does not know:
/// without the constant, every count-bearing container would be refused here
/// and the trace would look unopenable rather than merely unfamiliar.
const FLAG_HAS_LINE_COUNT_TABLE: u16 = 1 << 14;

/// Bit 15 — `corrmark.ns` correlation index + `markers.dat`/`.off` (WTCI).
///
/// backend-manager has no use for the index, but a bit outside
/// `KNOWN_FLAGS_MASK` makes `parse_meta_dat` reject the whole container — so
/// without this constant every recording that declares a correlation marker
/// would fail to open here, rather than opening with an index this component
/// ignores.
const FLAG_HAS_CORRELATION_INDEX: u16 = 1 << 15;
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

// ── Public types ─────────────────────────────────────────────────────────

/// Decoded subset of `meta.dat`.  Only the fields backend-manager
/// consumes are populated; the rest of the payload is skipped without
/// allocation (varint/string codecs still walk past the bytes so we can
/// validate trailing-bytes correctness).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct MetaDat {
    pub version: u16,
    pub flags: u16,
    pub recording_id: String,
    pub program: String,
    pub args: Vec<String>,
    pub workdir: String,
    pub recorder_id: String,
    /// The extended flag word (`flags_ext`); every bit in it is one this
    /// reader knows.
    pub ext_flags: u32,
    pub mcr: Option<McrFields>,
    pub replay_launch: Option<ReplayLaunchFields>,
    pub layout_snapshot: Option<LayoutSnapshotFields>,
    pub filter_provenance: Vec<FilterProvenanceEntry>,
    pub has_filter_provenance: bool,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct McrFields {
    pub tick_source: u64,
    pub total_threads: u64,
    pub atomic_mode: u64,
    pub total_events: u64,
    pub total_checkpoints: u64,
    pub start_time_unix_us: u64,
    pub platform: String,
    pub tick_granularity: String,
    pub tick_source_str: String,
    pub atomic_mode_str: String,
    pub start_time_str: String,
    pub hook_profile: String,
    pub hook_strategies: Vec<String>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ReplayLaunchFields {
    pub aslr_disabled: bool,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct LayoutSnapshotFields {
    pub layout_hash: u64,
    pub layout_fingerprint: Vec<u8>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct FilterProvenanceEntry {
    pub path: String,
    pub sha256: [u8; 32],
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum MetaDatError {
    TooShort {
        got: usize,
    },
    BadMagic,
    UnsupportedVersion(u16),
    UnknownFlags {
        flags: u16,
        unknown_bits: u16,
    },
    /// GDH-M2 — one or more EXTENDED flag bits (`flags_ext`) were set that
    /// this reader does not know.  Same contract as `UnknownFlags`: the
    /// writer is newer than this reader.
    UnknownExtendedFlags {
        ext_flags: u32,
        unknown_bits: u32,
    },
    VarintEof,
    VarintTooLong,
    StringEof {
        declared_len: usize,
        remaining: usize,
    },
    InvalidUtf8 {
        offset: usize,
    },
    InvalidRecordingId {
        value: String,
    },
    TrailingBytes {
        extra: usize,
    },
}

impl fmt::Display for MetaDatError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            MetaDatError::TooShort { got } => {
                write!(f, "meta.dat too short: need at least 12 bytes, got {got}")
            }
            MetaDatError::BadMagic => write!(f, "meta.dat: bad magic bytes (expected 'CTMD')"),
            MetaDatError::UnsupportedVersion(v) => write!(
                f,
                "meta.dat: version {v} is not readable: this reader reads version {META_DAT_VERSION} \
                 only. Re-record the trace with a current recorder"
            ),
            MetaDatError::UnknownFlags {
                flags,
                unknown_bits,
            } => write!(
                f,
                "meta.dat: unknown flag bits set (flags=0x{flags:04x}, unknown=0x{unknown_bits:04x})",
            ),
            MetaDatError::UnknownExtendedFlags {
                ext_flags,
                unknown_bits,
            } => write!(
                f,
                "meta.dat: unknown extended flag bits set (flags_ext=0x{ext_flags:08x}, unknown=0x{unknown_bits:08x})",
            ),
            MetaDatError::VarintEof => {
                write!(f, "meta.dat: unexpected end of input while reading varint")
            }
            MetaDatError::VarintTooLong => write!(f, "meta.dat: varint exceeds 10-byte LEB128"),
            MetaDatError::StringEof {
                declared_len,
                remaining,
            } => write!(
                f,
                "meta.dat: string of declared length {declared_len} extends past end ({remaining} bytes remain)",
            ),
            MetaDatError::InvalidUtf8 { offset } => {
                write!(f, "meta.dat: invalid UTF-8 string at offset {offset}")
            }
            MetaDatError::InvalidRecordingId { value } => write!(
                f,
                "meta.dat: invalid recording_id {value:?} (expected canonical UUIDv7)",
            ),
            MetaDatError::TrailingBytes { extra } => {
                write!(
                    f,
                    "meta.dat: {extra} trailing byte(s) after structured payload"
                )
            }
        }
    }
}

impl Error for MetaDatError {}

// ── Varint / string codecs ──────────────────────────────────────────────

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

fn read_string(data: &[u8], pos: &mut usize) -> Result<String, MetaDatError> {
    let len_u64 = decode_varint(data, pos)?;
    let len = usize::try_from(len_u64).map_err(|_| MetaDatError::TooShort { got: data.len() })?;
    if data.len() - *pos < len {
        return Err(MetaDatError::StringEof {
            declared_len: len,
            remaining: data.len() - *pos,
        });
    }
    let start = *pos;
    let slice = &data[start..start + len];
    let s = std::str::from_utf8(slice).map_err(|_| MetaDatError::InvalidUtf8 { offset: start })?;
    let owned = s.to_owned();
    *pos += len;
    Ok(owned)
}

// ── Recording-id validation ─────────────────────────────────────────────

/// Validate the canonical lowercase hyphenated UUIDv7 form per RFC 9562.
pub fn is_canonical_uuid_v7(s: &str) -> bool {
    if s.len() != 36 {
        return false;
    }
    let bytes = s.as_bytes();
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
    if bytes[14] != b'7' {
        return false;
    }
    match bytes[19] {
        b'8' | b'9' | b'a' | b'b' => {}
        _ => return false,
    }
    true
}

// ── meta.dat parser ─────────────────────────────────────────────────────

pub fn parse_meta_dat(input: &[u8]) -> Result<MetaDat, MetaDatError> {
    if input.len() < 6 {
        return Err(MetaDatError::TooShort { got: input.len() });
    }
    if input[0..4] != META_DAT_MAGIC {
        return Err(MetaDatError::BadMagic);
    }
    // The version is checked before the header length, so a header from
    // another version is refused for its version and not for being short.
    let version = u16::from_le_bytes([input[4], input[5]]);
    if !SUPPORTED_META_DAT_VERSIONS.contains(&version) {
        return Err(MetaDatError::UnsupportedVersion(version));
    }
    if input.len() < 12 {
        return Err(MetaDatError::TooShort { got: input.len() });
    }
    let flags = u16::from_le_bytes([input[6], input[7]]);
    let unknown_bits = flags & !KNOWN_FLAGS_MASK;
    if unknown_bits != 0 {
        return Err(MetaDatError::UnknownFlags {
            flags,
            unknown_bits,
        });
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

    let mut pos = body_start;
    // `recording_id` (M-REC-1, v3+) is a canonical UUIDv7 directly after
    // the flag words.  Every version the parser accepts carries it, so
    // this read is unconditional — there is no v2-shaped layout to
    // fall back to.
    let recording_id = read_string(input, &mut pos)?;
    if !is_canonical_uuid_v7(&recording_id) {
        return Err(MetaDatError::InvalidRecordingId {
            value: recording_id,
        });
    }

    let program = read_string(input, &mut pos)?;
    let args_count_u64 = decode_varint(input, &mut pos)?;
    let args_count =
        usize::try_from(args_count_u64).map_err(|_| MetaDatError::TooShort { got: input.len() })?;
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
            .map_err(|_| MetaDatError::TooShort { got: input.len() })?;
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
        let fp_len =
            usize::try_from(fp_len_u64).map_err(|_| MetaDatError::TooShort { got: input.len() })?;
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

    let mut filter_provenance: Vec<FilterProvenanceEntry> = Vec::new();
    let has_filter_provenance = flags & FLAG_HAS_TRACE_FILTER_PROVENANCE != 0;
    if has_filter_provenance {
        let count_u64 = decode_varint(input, &mut pos)?;
        let count =
            usize::try_from(count_u64).map_err(|_| MetaDatError::TooShort { got: input.len() })?;
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

// ── meta.dat serializer (test-only convenience) ────────────────────────
//
// The serializer mirrors `parse_meta_dat` byte-for-byte so test fixtures
// can synthesise a `meta.dat` payload from a `MetaDat` literal without
// shelling out to the recorder.  Production code only ever READS
// `meta.dat`; writing back is a recorder responsibility.  Gate the
// whole block behind `#[cfg(test)]` so the unused-function clippy
// lint doesn't trip in non-test builds.

#[cfg(test)]
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

#[cfg(test)]
fn write_string(s: &str, out: &mut Vec<u8>) {
    encode_varint(s.len() as u64, out);
    out.extend_from_slice(s.as_bytes());
}

#[cfg(test)]
pub fn serialize_meta_dat(meta: &MetaDat) -> Vec<u8> {
    let mut out: Vec<u8> = Vec::with_capacity(64);
    out.extend_from_slice(&META_DAT_MAGIC);
    out.extend_from_slice(&META_DAT_VERSION.to_le_bytes());

    // Section bits come from the blocks present; capability and
    // stream-presence bits are written as given.
    let section_bits = FLAG_HAS_MCR_FIELDS
        | FLAG_HAS_REPLAY_LAUNCH_FIELDS
        | FLAG_HAS_LAYOUT_SNAPSHOT
        | FLAG_HAS_TRACE_FILTER_PROVENANCE;
    let mut flags: u16 = meta.flags & KNOWN_FLAGS_MASK & !section_bits;
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

    write_string(&meta.recording_id, &mut out);
    write_string(&meta.program, &mut out);
    encode_varint(meta.args.len() as u64, &mut out);
    for arg in &meta.args {
        write_string(arg, &mut out);
    }
    write_string(&meta.workdir, &mut out);
    write_string(&meta.recorder_id, &mut out);

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

    if let Some(rl) = &meta.replay_launch {
        out.push(if rl.aslr_disabled { 1 } else { 0 });
    }

    if let Some(ls) = &meta.layout_snapshot {
        out.extend_from_slice(&ls.layout_hash.to_le_bytes());
        encode_varint(ls.layout_fingerprint.len() as u64, &mut out);
        out.extend_from_slice(&ls.layout_fingerprint);
    }

    if emit_filter_provenance {
        encode_varint(meta.filter_provenance.len() as u64, &mut out);
        for entry in &meta.filter_provenance {
            write_string(&entry.path, &mut out);
            out.extend_from_slice(&entry.sha256);
        }
    }

    out
}

// ── CTFS reader (minimal subset used by backend-manager) ───────────────

/// CTFS magic bytes — first 5 bytes of every CTFS container.
const CTFS_MAGIC: [u8; 5] = [0xC0, 0xDE, 0x72, 0xAC, 0xE2];

/// Base40 alphabet — used to encode short internal-file names.
const BASE40_ALPHABET: &[u8] = b"\x000123456789abcdefghijklmnopqrstuvwxyz./-";

fn base40_encode(name: &str) -> u64 {
    let mut value: u64 = 0;
    let mut mult: u64 = 1;
    for c in name.bytes() {
        let idx = BASE40_ALPHABET
            .iter()
            .position(|&b| b == c)
            .expect("character outside CTFS base40 alphabet");
        value += idx as u64 * mult;
        mult *= 40;
    }
    value
}

fn read_u32_le(data: &[u8], offset: usize) -> Option<u32> {
    let bytes = data.get(offset..offset + 4)?;
    Some(u32::from_le_bytes([bytes[0], bytes[1], bytes[2], bytes[3]]))
}

fn read_u64_le(data: &[u8], offset: usize) -> Option<u64> {
    let bytes = data.get(offset..offset + 8)?;
    Some(u64::from_le_bytes([
        bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
    ]))
}

/// The one container version this reader reads (`ctfs-container.md` §1).
const CTFS_VERSION: u8 = 5;

/// Bit 63 of `FileEntry.MapBlock`: the rest of the word is the member's only
/// data block (`ctfs-container.md` §2).
const CTFS_DIRECT: u64 = 1 << 63;

/// One root directory entry.
struct CtfsEntry {
    size: u64,
    map_block: u64,
}

/// Validate a container header and return `(block_size, root entry count)`.
fn ctfs_header(data: &[u8]) -> Result<(u64, usize), String> {
    if data.len() < 16 {
        return Err(format!("CTFS file too short ({} bytes)", data.len()));
    }
    if data[0..5] != CTFS_MAGIC {
        return Err("not a valid CTFS file (bad magic)".to_string());
    }
    let version = data[5];
    if version != CTFS_VERSION {
        return Err(format!(
            "CTFS container version {version} is not readable: this reader reads version \
             {CTFS_VERSION} only. Re-record the trace"
        ));
    }
    let block_size = read_u32_le(data, 8).ok_or("CTFS header truncated at block_size")?;
    if !matches!(block_size, 1024 | 2048 | 4096) {
        return Err(format!("invalid CTFS block size {block_size}"));
    }
    let max_entries = read_u32_le(data, 12).ok_or("CTFS header truncated at max_entries")? as usize;
    // `0` fills the rest of block 0 with entries (§1, "Auto-fill").
    let count = if max_entries == 0 {
        (block_size as usize - 16) / 24
    } else {
        max_entries
    };
    Ok((u64::from(block_size), count))
}

/// The root directory entry named `file_name`, if the container has one.
fn ctfs_entry(data: &[u8], file_name: &str) -> Result<Option<CtfsEntry>, String> {
    let (_, count) = ctfs_header(data)?;
    let encoded_name = base40_encode(file_name);
    for i in 0..count {
        let entry_off = 16 + i * 24;
        let Some(entry_name) = read_u64_le(data, entry_off + 16) else {
            break;
        };
        if entry_name == encoded_name {
            let size = read_u64_le(data, entry_off).ok_or("truncated CTFS entry size")?;
            let map_block =
                read_u64_le(data, entry_off + 8).ok_or("truncated CTFS entry mapBlock")?;
            return Ok(Some(CtfsEntry { size, map_block }));
        }
    }
    Ok(None)
}

/// Probe the size of an internal file in a CTFS container without
/// resolving its data blocks.  Returns `Ok(Some(size))` when the
/// entry table carries a non-zero matching entry, `Ok(None)` if the
/// file is not present or empty, and `Err` when the container header is
/// malformed.
///
/// Used by `trace_metadata::read_trace_metadata` to derive a
/// `total_events` proxy from the size of the materialized `steps.dat`
/// stream when `meta.dat::mcr::total_events` is unavailable
/// (currently the case for the Nim multi-stream writer, which only
/// fills the MCR block for native MCR recordings).
pub fn ctfs_internal_file_size(data: &[u8], file_name: &str) -> Result<Option<u64>, String> {
    Ok(ctfs_entry(data, file_name)?
        .map(|e| e.size)
        .filter(|&size| size > 0))
}

/// Read the internal file `file_name` out of a version 5 CTFS container:
/// `Ok(None)` when the container has no such member.
pub fn read_ctfs_internal_file(data: &[u8], file_name: &str) -> Result<Option<Vec<u8>>, String> {
    let (block_size, _) = ctfs_header(data)?;
    let Some(entry) = ctfs_entry(data, file_name)? else {
        return Ok(None);
    };
    resolve_ctfs_file(data, file_name, entry.size, entry.map_block, block_size).map(Some)
}

/// Locate the bytes of `meta.dat` inside a CTFS container.
///
/// Returns the file content on success.  Errors carry a string with
/// enough context for the caller to surface to users.
pub fn read_meta_dat_from_ctfs(data: &[u8]) -> Result<Vec<u8>, String> {
    read_ctfs_internal_file(data, "meta.dat")?
        .ok_or_else(|| "internal file not found in CTFS container: meta.dat".to_string())
}

/// The trace's source paths: the records of `paths.dat` (offsets in
/// `paths.off`), in id order.  `paths.dat` is the only list of source paths a
/// container carries (`internal-files.md` §"`meta.dat` carries no path
/// list"); a container without it names none.
///
/// `meta_flags` selects the record layout: with bit 4 (column-aware) or
/// bit 14 (line-count table) set, a record is `path_len: varint` + path
/// bytes + a tail this reader does not need; otherwise it is the path bytes.
pub fn read_source_paths_from_ctfs(data: &[u8], meta_flags: u16) -> Result<Vec<String>, String> {
    let Some(dat) = read_ctfs_internal_file(data, "paths.dat")? else {
        return Ok(Vec::new());
    };
    let off = read_ctfs_internal_file(data, "paths.off")?
        .ok_or("paths.off missing from a container that carries paths.dat")?;
    if off.is_empty() || off.len() % 8 != 0 {
        return Err(format!(
            "paths.off: length {} is not a non-zero multiple of 8",
            off.len()
        ));
    }
    let offsets: Vec<u64> = off
        .chunks_exact(8)
        .map(|c| u64::from_le_bytes([c[0], c[1], c[2], c[3], c[4], c[5], c[6], c[7]]))
        .collect();
    let framed = meta_flags & (FLAG_HAS_COLUMN_AWARE_STEPS | FLAG_HAS_LINE_COUNT_TABLE) != 0;
    let mut paths = Vec::with_capacity(offsets.len() - 1);
    for (id, w) in offsets.windows(2).enumerate() {
        let (start, end) = (w[0] as usize, w[1] as usize);
        let record = dat
            .get(start..end)
            .filter(|_| start <= end)
            .ok_or_else(|| format!("paths.dat: record {id} [{start}, {end}) is out of range"))?;
        let path = if framed {
            let mut pos = 0usize;
            let len = decode_varint(record, &mut pos)
                .map_err(|e| format!("paths.dat: record {id}: {e}"))?
                as usize;
            record
                .get(pos..pos + len)
                .ok_or_else(|| format!("paths.dat: record {id} path extends past the record"))?
        } else {
            record
        };
        paths.push(String::from_utf8_lossy(path).into_owned());
    }
    Ok(paths)
}

fn ctfs_block(
    data: &[u8],
    name: &str,
    block: u64,
    block_size: u64,
    what: &str,
) -> Result<usize, String> {
    if block == 0 {
        return Err(format!(
            "{name}: its {what} is a null block pointer (block 0 is the container header); the \
             container is damaged"
        ));
    }
    block
        .checked_mul(block_size)
        .and_then(|o| usize::try_from(o).ok())
        .filter(|&o| o < data.len())
        .ok_or_else(|| {
            format!("{name}: its {what} is block {block}, past the end of the container")
        })
}

fn resolve_ctfs_file(
    data: &[u8],
    name: &str,
    size: u64,
    map_block: u64,
    block_size: u64,
) -> Result<Vec<u8>, String> {
    if size == 0 {
        return Ok(Vec::new());
    }
    if map_block == 0 {
        return Err(format!(
            "{name} (size {size}): its MapBlock is a null block pointer; the container is damaged"
        ));
    }
    let block_size_usize = block_size as usize;
    if map_block & CTFS_DIRECT != 0 {
        if size > block_size {
            return Err(format!(
                "{name}: MapBlock names a single direct data block, but the declared size {size} is \
                 more than one block ({block_size} bytes) can hold"
            ));
        }
        let off = ctfs_block(
            data,
            name,
            map_block & !CTFS_DIRECT,
            block_size,
            "direct data block",
        )?;
        return data
            .get(off..off + size as usize)
            .map(<[u8]>::to_vec)
            .ok_or_else(|| format!("{name}: its data block is out of bounds"));
    }

    let usable = block_size / 8 - 1;
    let mut remaining = size as usize;
    let mut out: Vec<u8> = Vec::with_capacity(remaining);
    let mut block_idx: u64 = 0;
    let read_ptr = |block: u64, slot: u64, what: &str| -> Result<u64, String> {
        let off = ctfs_block(data, name, block, block_size, what)?;
        read_u64_le(data, off + (slot as usize) * 8)
            .ok_or_else(|| format!("{name}: truncated {what}"))
    };

    while remaining > 0 {
        let mut idx = block_idx;
        let mut current_level_block = map_block;
        let mut level: u32 = 1;

        loop {
            let cap = usable.saturating_pow(level);
            if idx < cap {
                break;
            }
            idx -= cap;
            level += 1;
            if level > 5 {
                return Err(format!("{name}: block index exceeds mapping depth"));
            }
            current_level_block = read_ptr(current_level_block, usable, "mapping block")?;
        }

        // Walk down `level - 1` indirections to the data-block pointer.
        let mut nav_block = current_level_block;
        let mut nav_level = level;
        let mut nav_idx = idx;
        while nav_level > 1 {
            let sub_cap = usable.saturating_pow(nav_level - 1);
            nav_block = read_ptr(nav_block, nav_idx / sub_cap, "mapping block")?;
            nav_idx %= sub_cap;
            nav_level -= 1;
        }

        let data_block = read_ptr(nav_block, nav_idx, "mapping block")?;
        let block_off = ctfs_block(
            data,
            name,
            data_block,
            block_size,
            &format!("data block {block_idx}"),
        )?;
        let copy_len = remaining.min(block_size_usize);
        let slice = data
            .get(block_off..block_off + copy_len)
            .ok_or_else(|| format!("{name}: data block {block_idx} is out of bounds"))?;
        out.extend_from_slice(slice);
        remaining -= copy_len;
        block_idx += 1;
    }

    Ok(out)
}

// ── Minimal CTFS writer (test-only) ────────────────────────────────────

/// Write a minimal version 5 CTFS container containing the given internal
/// files.
///
/// This is a test helper that mirrors the db-backend
/// `ctfs_trace_reader::ctfs_container::write_minimal_ctfs` writer, with
/// 1024-byte blocks: an empty file owns no block, a file of at most one block
/// is that block with `MapBlock` tagged (`ctfs-container.md` §2), and a larger
/// one has a level-1 mapping block claimed before its data blocks.
#[cfg(test)]
pub fn write_minimal_ctfs(path: &Path, files: &[(&str, &[u8])]) -> std::io::Result<()> {
    const BLOCK_SIZE: usize = 1024;
    const MAX_ENTRIES: usize = 8;
    assert!(
        files.len() <= MAX_ENTRIES,
        "test container holds at most {MAX_ENTRIES} files"
    );

    let mut out = vec![0u8; BLOCK_SIZE];
    out[0..5].copy_from_slice(&CTFS_MAGIC);
    out[5] = CTFS_VERSION;
    out[8..12].copy_from_slice(&(BLOCK_SIZE as u32).to_le_bytes());
    out[12..16].copy_from_slice(&(MAX_ENTRIES as u32).to_le_bytes());

    let alloc = |out: &mut Vec<u8>| -> u64 {
        let block = (out.len() / BLOCK_SIZE) as u64;
        out.resize(out.len() + BLOCK_SIZE, 0);
        block
    };
    for (i, (name, bytes)) in files.iter().enumerate() {
        let map_block = if bytes.is_empty() {
            0
        } else if bytes.len() <= BLOCK_SIZE {
            let block = alloc(&mut out);
            let off = block as usize * BLOCK_SIZE;
            out[off..off + bytes.len()].copy_from_slice(bytes);
            CTFS_DIRECT | block
        } else {
            let mapping = alloc(&mut out);
            assert!(
                bytes.len() <= (BLOCK_SIZE / 8 - 1) * BLOCK_SIZE,
                "test file too large"
            );
            for (slot, chunk) in bytes.chunks(BLOCK_SIZE).enumerate() {
                let block = alloc(&mut out);
                let off = block as usize * BLOCK_SIZE;
                out[off..off + chunk.len()].copy_from_slice(chunk);
                let ptr = mapping as usize * BLOCK_SIZE + slot * 8;
                out[ptr..ptr + 8].copy_from_slice(&block.to_le_bytes());
            }
            mapping
        };
        let entry = 16 + i * 24;
        out[entry..entry + 8].copy_from_slice(&(bytes.len() as u64).to_le_bytes());
        out[entry + 8..entry + 16].copy_from_slice(&map_block.to_le_bytes());
        out[entry + 16..entry + 24].copy_from_slice(&base40_encode(name).to_le_bytes());
    }

    std::fs::write(path, out)
}

// ── Tests ──────────────────────────────────────────────────────────────

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
        0x43, 0x54, 0x4D, 0x44, 0x05, 0x00, 0x00, 0x4F, 0x01, 0x00, 0x00, 0x00, 0x24, 0x30, 0x31,
        0x38, 0x39, 0x30, 0x30, 0x30, 0x30, 0x2D, 0x30, 0x30, 0x30, 0x30, 0x2D, 0x37, 0x30, 0x30,
        0x30, 0x2D, 0x38, 0x30, 0x30, 0x30, 0x2D, 0x30, 0x30, 0x30, 0x30, 0x30, 0x30, 0x30, 0x30,
        0x39, 0x31, 0x64, 0x39, 0x0B, 0x72, 0x65, 0x76, 0x5F, 0x70, 0x72, 0x6F, 0x64, 0x75, 0x63,
        0x65, 0x00, 0x00, 0x00, 0x02, 0x12, 0x72, 0x65, 0x73, 0x3A, 0x2F, 0x2F, 0x72, 0x65, 0x76,
        0x2F, 0x70, 0x72, 0x6F, 0x62, 0x65, 0x2E, 0x67, 0x64, 0x12, 0x72, 0x65, 0x73, 0x3A, 0x2F,
        0x2F, 0x72, 0x65, 0x76, 0x2F, 0x70, 0x72, 0x6F, 0x62, 0x65, 0x2E, 0x67, 0x64,
    ];

    #[test]
    fn an_unknown_ext_bit_is_refused() {
        let mut buf = v6_bytes();
        buf[9] = 0x01; // ext bit 8 — no constant here claims it
        assert!(matches!(
            parse_meta_dat(&buf),
            Err(MetaDatError::UnknownExtendedFlags { .. })
        ));
    }

    #[test]
    fn a_header_shorter_than_12_bytes_is_refused() {
        let buf = v6_bytes();
        for len in 6..12 {
            assert!(
                matches!(
                    parse_meta_dat(&buf[..len]),
                    Err(MetaDatError::TooShort { .. })
                ),
                "a {len}-byte header was not refused as short"
            );
        }
    }

    const TEST_RECORDING_ID: &str = "01949fcc-7d92-7e9c-aaaa-bbbbbbbbbbbb";

    fn fixture_minimal() -> MetaDat {
        MetaDat {
            version: META_DAT_VERSION,
            flags: 0,
            recording_id: TEST_RECORDING_ID.to_owned(),
            program: "/bin/test".to_owned(),
            args: vec!["a".to_owned()],
            workdir: "/tmp".to_owned(),
            recorder_id: "test".to_owned(),
            ext_flags: 0,
            mcr: None,
            replay_launch: None,
            layout_snapshot: None,
            filter_provenance: vec![],
            has_filter_provenance: false,
        }
    }

    #[test]
    fn roundtrip_minimal() {
        let original = fixture_minimal();
        let bytes = serialize_meta_dat(&original);
        let parsed = parse_meta_dat(&bytes).expect("parse");
        assert_eq!(parsed, original);
    }

    /// Pre-1.0, the parser must reject every non-v3 payload — including
    /// v2, which is the most recent retired version (M-REC-1.5 took it
    /// out of circulation).  Any stale v2 payload encountered in the
    /// wild signals an out-of-date build artefact (typically a stale
    /// `libcodetracer_trace_writer.a`) and rebuilding the recorder is
    /// the only correct fix.
    #[test]
    fn rejects_v2_payload() {
        // Minimal v2 body: program, args=0, workdir, recorder_id, paths=0.
        let mut buf: Vec<u8> = Vec::new();
        buf.extend_from_slice(&META_DAT_MAGIC);
        buf.extend_from_slice(&2u16.to_le_bytes());
        buf.extend_from_slice(&0u16.to_le_bytes());
        // program
        let program = "/bin/v2";
        encode_varint(program.len() as u64, &mut buf);
        buf.extend_from_slice(program.as_bytes());
        // args count 0
        encode_varint(0, &mut buf);
        // workdir
        let workdir = "/tmp";
        encode_varint(workdir.len() as u64, &mut buf);
        buf.extend_from_slice(workdir.as_bytes());
        // recorder_id
        let recorder_id = "ct-test/v2";
        encode_varint(recorder_id.len() as u64, &mut buf);
        buf.extend_from_slice(recorder_id.as_bytes());
        // paths count 0
        encode_varint(0, &mut buf);

        assert_eq!(
            parse_meta_dat(&buf),
            Err(MetaDatError::UnsupportedVersion(2))
        );
    }

    #[test]
    fn rejects_unsupported_versions() {
        let mut buf: Vec<u8> = Vec::new();
        buf.extend_from_slice(&META_DAT_MAGIC);
        buf.extend_from_slice(&1u16.to_le_bytes());
        buf.extend_from_slice(&0u16.to_le_bytes());
        assert_eq!(
            parse_meta_dat(&buf),
            Err(MetaDatError::UnsupportedVersion(1))
        );

        let mut buf: Vec<u8> = Vec::new();
        buf.extend_from_slice(&META_DAT_MAGIC);
        buf.extend_from_slice(&99u16.to_le_bytes());
        buf.extend_from_slice(&0u16.to_le_bytes());
        assert_eq!(
            parse_meta_dat(&buf),
            Err(MetaDatError::UnsupportedVersion(99))
        );
    }

    /// The refusal names the version it saw and the one this parser reads.
    #[test]
    fn unsupported_version_message_names_the_version_read() {
        assert_eq!(SUPPORTED_META_DAT_VERSIONS, &[META_DAT_VERSION]);
        let msg = MetaDatError::UnsupportedVersion(99).to_string();
        assert!(
            msg.contains("version 99") && msg.contains(&format!("version {META_DAT_VERSION}")),
            "the refusal must name both versions; got: {msg}"
        );
    }

    #[test]
    fn rejects_invalid_recording_id() {
        let mut buf: Vec<u8> = Vec::new();
        buf.extend_from_slice(&META_DAT_MAGIC);
        // Stamped from the constant, not written out: pinned to a superseded
        // number this payload would be refused for its VERSION and the
        // recording-id rule it exists to check would go untested behind a
        // passing assertion.
        buf.extend_from_slice(&META_DAT_VERSION.to_le_bytes());
        buf.extend_from_slice(&0u16.to_le_bytes());
        buf.extend_from_slice(&0u32.to_le_bytes());
        let bad = "not-a-uuid";
        encode_varint(bad.len() as u64, &mut buf);
        buf.extend_from_slice(bad.as_bytes());
        assert!(matches!(
            parse_meta_dat(&buf),
            Err(MetaDatError::InvalidRecordingId { .. })
        ));
    }

    #[test]
    fn ctfs_read_meta_dat_roundtrip() {
        let original = fixture_minimal();
        let meta_dat_bytes = serialize_meta_dat(&original);

        let dir = std::env::temp_dir().join(format!("ct-meta-dat-mod-test-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        let ct_path = dir.join("trace.ct");
        write_minimal_ctfs(&ct_path, &[("meta.dat", &meta_dat_bytes)]).unwrap();

        let bytes = std::fs::read(&ct_path).unwrap();
        let extracted = read_meta_dat_from_ctfs(&bytes).expect("locate meta.dat");
        // The CTFS data block is padded to BLOCK_SIZE; the file size is
        // recorded in the entry so the extracted slice is trimmed to
        // exactly meta_dat_bytes.
        assert_eq!(extracted, meta_dat_bytes);

        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn is_canonical_uuid_v7_validates_format() {
        assert!(is_canonical_uuid_v7(TEST_RECORDING_ID));
        assert!(!is_canonical_uuid_v7(
            "01949FCC-7D92-7E9C-AAAA-BBBBBBBBBBBB"
        ));
        assert!(!is_canonical_uuid_v7(
            "01949fcc-7d92-4e9c-aaaa-bbbbbbbbbbbb"
        )); // version 4
        assert!(!is_canonical_uuid_v7(
            "01949fcc-7d92-7e9c-caaa-bbbbbbbbbbbb"
        )); // bad variant
        assert!(!is_canonical_uuid_v7(""));
    }

    // ── meta.dat version 6, container version 5 ────────────────────────

    /// A version 6 header from the specification (internal-files.md
    /// §"Metadata (meta.dat)"): `flags_ext` always present, and nothing after
    /// `recorder_id` but the flag-gated blocks.
    fn v6_bytes() -> Vec<u8> {
        let mut buf: Vec<u8> = Vec::new();
        buf.extend_from_slice(b"CTMD");
        buf.extend_from_slice(&6u16.to_le_bytes());
        buf.extend_from_slice(&0u16.to_le_bytes());
        buf.extend_from_slice(&0u32.to_le_bytes());
        buf.push(TEST_RECORDING_ID.len() as u8);
        buf.extend_from_slice(TEST_RECORDING_ID.as_bytes());
        buf.extend_from_slice(&[2, b'h', b'i']);
        buf.extend_from_slice(&[0]);
        buf.extend_from_slice(&[2, b'/', b'w']);
        buf.extend_from_slice(&[1, b'r']);
        buf
    }

    #[test]
    fn a_version_6_header_parses() {
        let m = parse_meta_dat(&v6_bytes()).expect("a version 6 header must parse");
        assert_eq!(m.version, 6);
        assert_eq!(m.program, "hi");
        assert_eq!(m.workdir, "/w");
        assert_eq!(m.recorder_id, "r");
    }

    #[test]
    fn a_path_list_after_recorder_id_is_not_read() {
        let mut buf = v6_bytes();
        buf.extend_from_slice(&[1, 1, b'x']);
        assert!(
            matches!(
                parse_meta_dat(&buf),
                Err(MetaDatError::TrailingBytes { extra: 3 })
            ),
            "a version 5 path list after recorder_id must not be read"
        );
    }

    #[test]
    fn every_meta_dat_version_but_6_is_refused_by_name() {
        for v in [3u16, 4, 5, 7] {
            let mut buf = v6_bytes();
            buf[4..6].copy_from_slice(&v.to_le_bytes());
            let err = parse_meta_dat(&buf).expect_err("another version must be refused");
            assert_eq!(err, MetaDatError::UnsupportedVersion(v));
            let msg = err.to_string();
            assert!(
                msg.contains(&format!("version {v}")) && msg.contains('6'),
                "the refusal names neither version: {msg}"
            );
        }
        assert_eq!(
            parse_meta_dat(NIM_WRITTEN_V5_META_DAT),
            Err(MetaDatError::UnsupportedVersion(5))
        );
    }

    const BIT63: u64 = 1 << 63;

    /// A raw version 5 container of `blocks` 1024-byte blocks with the given
    /// `(slot, name, size, map_block)` entries.
    fn raw_v5(blocks: usize, entries: &[(usize, &str, u64, u64)]) -> Vec<u8> {
        let mut buf = vec![0u8; blocks * 1024];
        buf[0..5].copy_from_slice(&CTFS_MAGIC);
        buf[5] = 5;
        buf[8..12].copy_from_slice(&1024u32.to_le_bytes());
        buf[12..16].copy_from_slice(&8u32.to_le_bytes());
        for &(slot, name, size, map_block) in entries {
            let off = 16 + slot * 24;
            buf[off..off + 8].copy_from_slice(&size.to_le_bytes());
            buf[off + 8..off + 16].copy_from_slice(&map_block.to_le_bytes());
            buf[off + 16..off + 24].copy_from_slice(&base40_encode(name).to_le_bytes());
        }
        buf
    }

    #[test]
    fn a_container_of_another_version_is_refused_by_name() {
        for v in [3u8, 4, 6] {
            let mut raw = raw_v5(2, &[(0, "meta.dat", 2, BIT63 | 1)]);
            raw[5] = v;
            let err = read_meta_dat_from_ctfs(&raw)
                .expect_err("another container version must be refused");
            assert!(
                err.contains(&format!("version {v}")) && err.contains('5'),
                "the refusal names neither version: {err}"
            );
        }
    }

    /// `ctfs-container.md` §2: a tagged `MapBlock` is the member's only data
    /// block; an untagged one is a mapping whatever `Size` says.
    #[test]
    fn version_5_members_are_read_in_each_form() {
        let mut raw = raw_v5(4, &[(0, "meta.dat", 3, BIT63 | 1), (1, "paths.dat", 2, 2)]);
        raw[1024..1027].copy_from_slice(b"abc");
        raw[2 * 1024..2 * 1024 + 8].copy_from_slice(&3u64.to_le_bytes());
        raw[3 * 1024..3 * 1024 + 2].copy_from_slice(b"xy");
        assert_eq!(read_meta_dat_from_ctfs(&raw).unwrap(), b"abc");
        assert_eq!(ctfs_internal_file_size(&raw, "paths.dat").unwrap(), Some(2));
    }

    /// `ctfs-container.md` §4, "Null block pointers on the read path".
    #[test]
    fn a_null_or_oversized_direct_member_is_refused() {
        for (size, map_block, what) in [
            (3u64, 0u64, "MapBlock 0 with a size"),
            (3, BIT63, "a tagged block 0"),
            (2000, BIT63 | 1, "a direct member past one block"),
        ] {
            let raw = raw_v5(3, &[(0, "meta.dat", size, map_block)]);
            let err = read_meta_dat_from_ctfs(&raw).expect_err(what);
            assert!(
                err.contains("meta.dat") && !err.contains("truncat"),
                "{what}: {err}"
            );
        }
    }

    /// The source paths are `paths.dat`'s records, in either record layout.
    #[test]
    fn source_paths_are_read_from_paths_dat() {
        let dir = std::env::temp_dir().join(format!("ct-meta-dat-paths-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        let ct = dir.join("trace.ct");

        let (dat, off) = (
            b"/a.rs/bb.rs".to_vec(),
            [0u64, 5, 11].map(u64::to_le_bytes).concat(),
        );
        write_minimal_ctfs(&ct, &[("paths.dat", &dat), ("paths.off", &off)]).unwrap();
        let raw = std::fs::read(&ct).unwrap();
        assert_eq!(
            read_source_paths_from_ctfs(&raw, 0).unwrap(),
            vec!["/a.rs", "/bb.rs"]
        );

        // Layout A / line-count records: `path_len` + path + a tail.
        let mut framed = vec![5u8];
        framed.extend_from_slice(b"/a.rs");
        framed.push(40);
        let off = [0u64, framed.len() as u64].map(u64::to_le_bytes).concat();
        write_minimal_ctfs(&ct, &[("paths.dat", &framed), ("paths.off", &off)]).unwrap();
        let raw = std::fs::read(&ct).unwrap();
        assert_eq!(
            read_source_paths_from_ctfs(&raw, FLAG_HAS_LINE_COUNT_TABLE).unwrap(),
            vec!["/a.rs"]
        );

        write_minimal_ctfs(&ct, &[("meta.dat", b"m")]).unwrap();
        let raw = std::fs::read(&ct).unwrap();
        assert!(read_source_paths_from_ctfs(&raw, 0).unwrap().is_empty());
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// The test writer lays members out as version 5 requires, and a member
    /// past one block is read back through its mapping.
    #[test]
    fn the_test_writer_writes_version_5_layouts() {
        let dir = std::env::temp_dir().join(format!("ct-meta-dat-layout-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        let ct = dir.join("trace.ct");
        let big: Vec<u8> = (0..3000u32).map(|i| (i % 251) as u8).collect();
        write_minimal_ctfs(&ct, &[("empty", &[]), ("small", b"abc"), ("big", &big)]).unwrap();
        let raw = std::fs::read(&ct).unwrap();
        assert_eq!(raw[5], 5);
        let entry = |slot: usize| read_u64_le(&raw, 16 + slot * 24 + 8).unwrap();
        assert_eq!(entry(0), 0, "an empty member owns no block");
        assert_ne!(entry(1) & BIT63, 0, "a one-block member is direct");
        assert_eq!(entry(2) & BIT63, 0, "a larger member is mapped");
        assert_eq!(raw.len(), 1024 * (1 + 1 + 1 + 3));
        assert_eq!(
            read_ctfs_internal_file(&raw, "empty").unwrap(),
            Some(Vec::new())
        );
        assert_eq!(
            read_ctfs_internal_file(&raw, "small").unwrap(),
            Some(b"abc".to_vec())
        );
        assert_eq!(read_ctfs_internal_file(&raw, "big").unwrap(), Some(big));
        assert_eq!(read_ctfs_internal_file(&raw, "absent").unwrap(), None);
        let _ = std::fs::remove_dir_all(&dir);
    }
}
