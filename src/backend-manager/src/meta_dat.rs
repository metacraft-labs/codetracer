//! Pure-Rust reader for CTFS `meta.dat` payloads, vendored for the
//! backend-manager so it can extract per-trace metadata without depending
//! on the heavier `codetracer_trace_types`/`replay-server` crates.
//!
//! The wire format is the v3 layout introduced in M-REC-1 and pinned by
//! M-REC-1.5: pre-1.0, no backcompat for v1/v2 fixtures.  The canonical
//! reference parser is in
//! `codetracer/src/db-backend/src/ctfs_trace_reader/meta_dat.rs`; the two
//! implementations stay byte-compatible by construction (they both
//! follow the spec in `codetracer-trace-format-spec/internal-files.md`).
//!
//! Only a subset of the full meta.dat surface that backend-manager needs
//! is decoded:
//! - `recording_id`
//! - `program`, `args`, `workdir`
//! - `paths`
//! - `MCR.total_events` (when present)
//!
//! The CTFS container reader here is also a minimal subset: enough to
//! locate the `meta.dat` internal file inside a `.ct` archive.  The full
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

/// Canonical meta.dat format version: v3 (M-REC-1, 2026-05-18).
///
/// Pre-1.0, CodeTracer enforces a strict no-backcompat policy on the
/// trace format: every recorder is required to track the current
/// `meta.dat` version, and old fixtures must be regenerated whenever
/// the version is bumped.  See
/// `codetracer-specs/Refactoring-Plans/Recording-Identifier-Migration.md`
/// § 3 and the M-REC-1 / M-REC-1.5 milestones for the rationale.
///
/// Concretely this means [`SUPPORTED_META_DAT_VERSIONS`] is a
/// singleton `&[3]`; any v1/v2 payload encountered in the wild is a
/// stale build artefact (e.g. an out-of-date
/// `libcodetracer_trace_writer.a` static library) and must be
/// rebuilt rather than worked around at the reader.
pub const META_DAT_VERSION: u16 = 3;

/// The set of `meta.dat` versions this parser accepts on read.  Kept
/// as a slice (rather than a single constant) so callers that surface
/// "unsupported version" errors can enumerate the accepted set in
/// diagnostics; the slice is intentionally a singleton, mirroring
/// [`META_DAT_VERSION`].
pub const SUPPORTED_META_DAT_VERSIONS: &[u16] = &[3];

const FLAG_HAS_MCR_FIELDS: u16 = 1 << 0;
const FLAG_HAS_REPLAY_LAUNCH_FIELDS: u16 = 1 << 1;
const FLAG_HAS_LAYOUT_SNAPSHOT: u16 = 1 << 2;
const FLAG_HAS_TRACE_FILTER_PROVENANCE: u16 = 1 << 3;
const KNOWN_FLAGS_MASK: u16 = FLAG_HAS_MCR_FIELDS
    | FLAG_HAS_REPLAY_LAUNCH_FIELDS
    | FLAG_HAS_LAYOUT_SNAPSHOT
    | FLAG_HAS_TRACE_FILTER_PROVENANCE;

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
    pub paths: Vec<String>,
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
                write!(f, "meta.dat too short: need at least 8 bytes, got {got}")
            }
            MetaDatError::BadMagic => write!(f, "meta.dat: bad magic bytes (expected 'CTMD')"),
            MetaDatError::UnsupportedVersion(v) => {
                write!(
                    f,
                    "meta.dat: unsupported version {v}, expected {META_DAT_VERSION}"
                )
            }
            MetaDatError::UnknownFlags {
                flags,
                unknown_bits,
            } => write!(
                f,
                "meta.dat: unknown flag bits set (flags=0x{flags:04x}, unknown=0x{unknown_bits:04x})",
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
    if input.len() < 8 {
        return Err(MetaDatError::TooShort { got: input.len() });
    }
    if input[0..4] != META_DAT_MAGIC {
        return Err(MetaDatError::BadMagic);
    }
    let version = u16::from_le_bytes([input[4], input[5]]);
    if !SUPPORTED_META_DAT_VERSIONS.contains(&version) {
        return Err(MetaDatError::UnsupportedVersion(version));
    }
    let flags = u16::from_le_bytes([input[6], input[7]]);
    let unknown_bits = flags & !KNOWN_FLAGS_MASK;
    if unknown_bits != 0 {
        return Err(MetaDatError::UnknownFlags {
            flags,
            unknown_bits,
        });
    }

    let mut pos = 8usize;
    // v3 (M-REC-1) prepends a canonical UUIDv7 `recording_id` directly
    // after the flags word.  Pre-1.0, the parser only accepts v3, so
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
    let paths_count_u64 = decode_varint(input, &mut pos)?;
    let paths_count = usize::try_from(paths_count_u64)
        .map_err(|_| MetaDatError::TooShort { got: input.len() })?;
    let mut paths = Vec::with_capacity(paths_count);
    for _ in 0..paths_count {
        paths.push(read_string(input, &mut pos)?);
    }

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
        paths,
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

    let mut flags: u16 = 0;
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

    write_string(&meta.recording_id, &mut out);
    write_string(&meta.program, &mut out);
    encode_varint(meta.args.len() as u64, &mut out);
    for arg in &meta.args {
        write_string(arg, &mut out);
    }
    write_string(&meta.workdir, &mut out);
    write_string(&meta.recorder_id, &mut out);
    encode_varint(meta.paths.len() as u64, &mut out);
    for path in &meta.paths {
        write_string(path, &mut out);
    }

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

/// Probe the size of an internal file in a CTFS container without
/// resolving its data blocks.  Returns `Ok(Some(size))` when the
/// entry table carries a non-zero matching entry, `Ok(None)` if the
/// file is not present, and `Err` when the container header is
/// malformed.
///
/// Used by `trace_metadata::read_trace_metadata` to derive a
/// `total_events` proxy from the size of the materialized `steps.dat`
/// stream when `meta.dat::mcr::total_events` is unavailable
/// (currently the case for the Nim multi-stream writer, which only
/// fills the MCR block for native MCR recordings).
pub fn ctfs_internal_file_size(data: &[u8], file_name: &str) -> Result<Option<u64>, String> {
    if data.len() < 16 {
        return Err(format!("CTFS file too short ({} bytes)", data.len()));
    }
    if data[0..5] != CTFS_MAGIC {
        return Err("not a valid CTFS file (bad magic)".to_string());
    }
    let version = data[5];
    if !matches!(version, 2..=4) {
        return Err(format!("unsupported CTFS version {version}"));
    }
    let max_entries = read_u32_le(data, 12).ok_or("CTFS header truncated at max_entries")?;
    let encoded_name = base40_encode(file_name);

    let mut entry_off = 16usize;
    for _ in 0..max_entries {
        let size = read_u64_le(data, entry_off).ok_or("truncated CTFS entry size")?;
        let _map_block = read_u64_le(data, entry_off + 8).ok_or("truncated CTFS entry mapBlock")?;
        let entry_name = read_u64_le(data, entry_off + 16).ok_or("truncated CTFS entry name")?;
        if entry_name == encoded_name && size > 0 {
            return Ok(Some(size));
        }
        entry_off += 24;
    }
    Ok(None)
}

/// Locate the bytes of an internal file inside a CTFS container.
///
/// Returns the file content on success.  Errors carry a string with
/// enough context for the caller to surface to users.
pub fn read_meta_dat_from_ctfs(data: &[u8]) -> Result<Vec<u8>, String> {
    if data.len() < 16 {
        return Err(format!("CTFS file too short ({} bytes)", data.len()));
    }
    if data[0..5] != CTFS_MAGIC {
        return Err("not a valid CTFS file (bad magic)".to_string());
    }
    let version = data[5];
    if !matches!(version, 2..=4) {
        return Err(format!("unsupported CTFS version {version}"));
    }
    let block_size = read_u32_le(data, 8).ok_or("CTFS header truncated at block_size")?;
    if !matches!(block_size, 1024 | 2048 | 4096) {
        return Err(format!("invalid CTFS block size {block_size}"));
    }
    let max_entries = read_u32_le(data, 12).ok_or("CTFS header truncated at max_entries")?;
    let encoded_name = base40_encode("meta.dat");

    // Each entry: u64 size, u64 mapBlock, u64 encodedName (= 24 bytes).
    let mut entry_off = 16usize;
    for _ in 0..max_entries {
        let size = read_u64_le(data, entry_off).ok_or("truncated CTFS entry size")?;
        let map_block = read_u64_le(data, entry_off + 8).ok_or("truncated CTFS entry mapBlock")?;
        let entry_name = read_u64_le(data, entry_off + 16).ok_or("truncated CTFS entry name")?;
        if entry_name == encoded_name {
            return resolve_ctfs_file(data, size, map_block, block_size);
        }
        entry_off += 24;
    }
    Err("internal file not found in CTFS container: meta.dat".to_string())
}

fn resolve_ctfs_file(
    data: &[u8],
    size: u64,
    map_block: u64,
    block_size: u32,
) -> Result<Vec<u8>, String> {
    let block_size_usize = block_size as usize;
    let usable = (block_size as u64) / 8 - 1;
    let mut remaining = size as usize;
    let mut out: Vec<u8> = Vec::with_capacity(remaining);
    let mut block_idx: u64 = 0;

    while remaining > 0 {
        let mut idx = block_idx;
        let mut current_level_block = map_block;
        let mut level: u32 = 1;

        loop {
            let mut cap: u64 = 1;
            for _ in 0..level {
                cap *= usable;
            }
            if idx < cap {
                break;
            }
            idx -= cap;
            level += 1;
            if level > 5 {
                return Err("CTFS block index exceeds mapping depth".to_string());
            }
            let chain_off =
                (current_level_block as usize) * block_size_usize + (usable as usize) * 8;
            let chain_ptr = read_u64_le(data, chain_off).ok_or("truncated CTFS chain pointer")?;
            if chain_ptr == 0 {
                return Err(format!("missing CTFS chain pointer at level {level}"));
            }
            current_level_block = chain_ptr;
        }

        // Walk down `level - 1` indirections to the data-block pointer.
        let mut nav_block = current_level_block;
        let mut nav_level = level;
        let mut nav_idx = idx;
        while nav_level > 1 {
            let mut sub_cap: u64 = 1;
            for _ in 0..(nav_level - 1) {
                sub_cap *= usable;
            }
            let entry_idx = nav_idx / sub_cap;
            let sub_idx = nav_idx % sub_cap;
            let child_off = (nav_block as usize) * block_size_usize + (entry_idx as usize) * 8;
            let child = read_u64_le(data, child_off).ok_or("truncated CTFS child pointer")?;
            if child == 0 {
                return Err(format!("missing CTFS child block at level {nav_level}"));
            }
            nav_block = child;
            nav_idx = sub_idx;
            nav_level -= 1;
        }

        let ptr_off = (nav_block as usize) * block_size_usize + (nav_idx as usize) * 8;
        let data_block = read_u64_le(data, ptr_off).ok_or("truncated CTFS data-block pointer")?;
        if data_block == 0 {
            return Err(format!("null CTFS data block at index {block_idx}"));
        }
        let block_off = (data_block as usize) * block_size_usize;
        let copy_len = remaining.min(block_size_usize);
        let slice = data
            .get(block_off..block_off + copy_len)
            .ok_or("CTFS data block out of bounds")?;
        out.extend_from_slice(slice);
        remaining -= copy_len;
        block_idx += 1;
    }

    Ok(out)
}

// ── Minimal CTFS writer (test-only) ────────────────────────────────────

/// Write a minimal CTFS container containing the given internal files.
///
/// This is a test helper that mirrors the db-backend
/// `ctfs_trace_reader::ctfs_container::write_minimal_ctfs` writer.  The
/// layout is intentionally simple: one mapping block + one data block per
/// internal file, all 1024 bytes.
#[cfg(test)]
pub fn write_minimal_ctfs(path: &Path, files: &[(&str, &[u8])]) -> std::io::Result<()> {
    const BLOCK_SIZE: usize = 1024;
    const MAX_ENTRIES: usize = 8;

    let mut root: Vec<u8> = Vec::new();
    root.extend_from_slice(&CTFS_MAGIC);
    root.push(3); // version
    root.push(0);
    root.push(0);
    root.extend_from_slice(&(BLOCK_SIZE as u32).to_le_bytes());
    root.extend_from_slice(&(MAX_ENTRIES as u32).to_le_bytes());

    for (i, file) in files.iter().enumerate() {
        let map_block = (1 + i * 2) as u64;
        root.extend_from_slice(&(file.1.len() as u64).to_le_bytes());
        root.extend_from_slice(&map_block.to_le_bytes());
        root.extend_from_slice(&base40_encode(file.0).to_le_bytes());
    }
    for _ in files.len()..MAX_ENTRIES {
        root.extend_from_slice(&0u64.to_le_bytes());
        root.extend_from_slice(&0u64.to_le_bytes());
        root.extend_from_slice(&0u64.to_le_bytes());
    }
    root.resize(BLOCK_SIZE, 0);

    for (i, file) in files.iter().enumerate() {
        let data_block = (2 + i * 2) as u64;
        let mut mapping: Vec<u8> = Vec::new();
        mapping.extend_from_slice(&data_block.to_le_bytes());
        mapping.resize(BLOCK_SIZE, 0);
        root.extend_from_slice(&mapping);

        let mut data_padded = file.1.to_vec();
        data_padded.resize(BLOCK_SIZE, 0);
        root.extend_from_slice(&data_padded);
    }

    std::fs::write(path, root)
}

// ── Tests ──────────────────────────────────────────────────────────────

#[cfg(test)]
#[allow(clippy::unwrap_used, clippy::expect_used, clippy::panic)]
mod tests {
    use super::*;

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
            paths: vec!["main.rs".to_owned()],
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

    #[test]
    fn rejects_invalid_recording_id() {
        let mut buf: Vec<u8> = Vec::new();
        buf.extend_from_slice(&META_DAT_MAGIC);
        buf.extend_from_slice(&3u16.to_le_bytes());
        buf.extend_from_slice(&0u16.to_le_bytes());
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
}
