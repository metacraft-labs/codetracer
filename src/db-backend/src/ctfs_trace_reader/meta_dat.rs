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
//! [2 bytes] version u16 little-endian (must be 3 — current)
//! [2 bytes] flags u16 little-endian
//!           bit 0       — FLAG_HAS_MCR_FIELDS
//!           bit 1       — FLAG_HAS_REPLAY_LAUNCH_FIELDS (M-RLP-1, §6A.5)
//!           bit 2       — FLAG_HAS_LAYOUT_SNAPSHOT (M-RLP-2, §6B.7)
//!           bit 3       — FLAG_HAS_TRACE_FILTER_PROVENANCE (TF-M7, §7)
//!           bits 4..=15 — reserved (must be 0; readers reject if set)
//! varint-prefixed UTF-8 string : recording_id        (M-REC-1; v3+)
//! varint-prefixed UTF-8 string : program
//! varint                       : args_count
//!   ⤷ args_count × varint-prefixed UTF-8 string : args[i]
//! varint-prefixed UTF-8 string : workdir
//! varint-prefixed UTF-8 string : recorder_id
//! varint                       : paths_count
//!   ⤷ paths_count × varint-prefixed UTF-8 string : paths[i]
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

use std::error::Error;
use std::fmt;

// ── Constants ───────────────────────────────────────────────────────────

/// Magic bytes identifying a `meta.dat` payload: ASCII "CTMD".
pub const META_DAT_MAGIC: [u8; 4] = [0x43, 0x54, 0x4D, 0x44];

/// The `meta.dat` format version emitted by this serializer and the
/// current Nim writer.
///
/// M-REC-1.5 retired v1 and v2 (pre-1.0, no backcompat).  The reader
/// rejects any version not listed in [`SUPPORTED_VERSIONS`].
pub const META_DAT_VERSION: u16 = 3;

/// All `meta.dat` versions this reader can decode.
///
/// v1 and v2 were retired by M-REC-1.5 (pre-1.0; no backwards
/// compatibility).  v3 (M-REC-1) added the required `recording_id`
/// UUIDv7 string and trace-filter provenance flag bit.
pub const SUPPORTED_VERSIONS: &[u16] = &[3];

/// Flag bit 0 — when set, the MCR (Multi-process Concurrent Recording)
/// fields are appended after the paths block.
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

/// Bitmask of all flag bits this implementation understands.
///
/// Any bit outside this mask is rejected by [`parse_meta_dat`] so future
/// writers introducing new flag bits force readers to upgrade explicitly.
const KNOWN_FLAGS_MASK: u16 =
    FLAG_HAS_MCR_FIELDS | FLAG_HAS_REPLAY_LAUNCH_FIELDS | FLAG_HAS_LAYOUT_SNAPSHOT | FLAG_HAS_TRACE_FILTER_PROVENANCE;

// ── Public types ────────────────────────────────────────────────────────

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
    /// Source file paths referenced by the trace.
    pub paths: Vec<String>,
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
    /// Input is shorter than the fixed 8-byte header.
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
}

impl fmt::Display for MetaDatError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            MetaDatError::TooShort { got } => {
                write!(f, "meta.dat too short: need at least 8 bytes, got {got}")
            }
            MetaDatError::BadMagic => write!(f, "meta.dat: bad magic bytes (expected 'CTMD')"),
            MetaDatError::UnsupportedVersion(v) => {
                write!(f, "meta.dat: unsupported version {v}, expected {META_DAT_VERSION}")
            }
            MetaDatError::UnknownFlags { flags, unknown_bits } => write!(
                f,
                "meta.dat: unknown flag bits set (flags=0x{flags:04x}, unknown=0x{unknown_bits:04x}); \
                 the writer is newer than this reader",
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
    if input.len() < 8 {
        return Err(MetaDatError::TooShort { got: input.len() });
    }

    if input[0..4] != META_DAT_MAGIC {
        return Err(MetaDatError::BadMagic);
    }

    let version = u16::from_le_bytes([input[4], input[5]]);
    if !SUPPORTED_VERSIONS.contains(&version) {
        return Err(MetaDatError::UnsupportedVersion(version));
    }

    let flags = u16::from_le_bytes([input[6], input[7]]);
    let unknown_bits = flags & !KNOWN_FLAGS_MASK;
    if unknown_bits != 0 {
        return Err(MetaDatError::UnknownFlags { flags, unknown_bits });
    }

    let mut pos = 8usize;

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

    let paths_count_u64 = decode_varint(input, &mut pos)?;
    let paths_count = usize::try_from(paths_count_u64).map_err(|_| MetaDatError::StringTooLong(paths_count_u64))?;
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
        paths,
        mcr,
        replay_launch,
        layout_snapshot,
        filter_provenance,
        has_filter_provenance,
    })
}

/// Parse a legacy JSON `meta.json` payload into a [`MetaDat`].
///
/// Older MCR `.ct` containers — produced before the recorder switched to
/// the binary `meta.dat` format — store their metadata as a UTF-8 JSON
/// `meta.json` internal file. The recorder's own loader keeps a
/// `meta.json` fallback for backward compatibility
/// (`ct_trace_store/src/ct_trace_store/trace_reader.nim::readMetadata`);
/// this function is the db-backend's equivalent so the WASM browser
/// replay path can open those traces too.
///
/// The JSON schema is the one written by
/// `ct_trace_store/src/ct_trace_store/metadata.nim::toJson`:
///
/// ```json
/// {
///   "recording_id": "…",      // optional in legacy traces
///   "version": "2",
///   "platform": "native",
///   "tickSource": "none",
///   "tickGranularity": "edge",
///   "atomicMode": "",
///   "totalEvents": 0,
///   "totalCheckpoints": 0,
///   "totalThreads": 0,
///   "program": "…",
///   "args": [],
///   "startTime": "",
///   "recordingBackend": "mcr",   // OR "recordingMode": "mcr-interpose"
/// }
/// ```
///
/// A `meta.json` always describes an MCR trace (the materialised DB
/// layout never used a JSON metadata sidecar), so the returned
/// [`MetaDat`] always carries `mcr: Some(..)` with `FLAG_HAS_MCR_FIELDS`
/// set. Missing fields fall back to empty/zero — legacy traces predate
/// several of them.
pub fn parse_meta_json(input: &[u8]) -> Result<MetaDat, Box<dyn Error>> {
    let json: serde_json::Value = serde_json::from_slice(input)?;
    let obj = json
        .as_object()
        .ok_or_else(|| -> Box<dyn Error> { "meta.json: top-level value is not a JSON object".into() })?;

    let str_field = |key: &str| -> String {
        obj.get(key)
            .and_then(|v| v.as_str())
            .unwrap_or_default()
            .to_string()
    };
    let u64_field = |key: &str| -> u64 { obj.get(key).and_then(|v| v.as_u64()).unwrap_or(0) };

    let recording_id = {
        // Accept either the canonical snake_case key or the legacy
        // camelCase Nim-object form (mirrors `metadata.nim::fromJson`).
        let raw = obj
            .get("recording_id")
            .or_else(|| obj.get("recordingId"))
            .and_then(|v| v.as_str())
            .unwrap_or_default()
            .to_string();
        // Legacy `meta.json` traces predate M-REC-1 and carry no
        // recording_id at all. `MetaDat` parsing elsewhere validates the
        // UUIDv7 shape; here we substitute the canonical nil UUIDv7 when
        // the field is absent or malformed so downstream code that only
        // needs the MCR fields still works.
        if is_canonical_uuid_v7(&raw) {
            raw
        } else {
            "00000000-0000-7000-8000-000000000000".to_string()
        }
    };

    let args = obj
        .get("args")
        .and_then(|v| v.as_array())
        .map(|arr| {
            arr.iter()
                .filter_map(|v| v.as_str().map(|s| s.to_string()))
                .collect()
        })
        .unwrap_or_default();

    // `recordingBackend` is the newer field; older traces only carry
    // `recordingMode` (e.g. "mcr-interpose"). Either identifies the
    // recorder; keep whichever is present for diagnostics.
    let recorder_id = {
        let backend = str_field("recordingBackend");
        if backend.is_empty() {
            str_field("recordingMode")
        } else {
            backend
        }
    };

    let mcr = McrFields {
        tick_source: 0,
        total_threads: u64_field("totalThreads"),
        atomic_mode: 0,
        total_events: u64_field("totalEvents"),
        total_checkpoints: u64_field("totalCheckpoints"),
        start_time_unix_us: 0,
        platform: str_field("platform"),
        tick_granularity: str_field("tickGranularity"),
        tick_source_str: str_field("tickSource"),
        atomic_mode_str: str_field("atomicMode"),
        start_time_str: str_field("startTime"),
        hook_profile: String::new(),
        hook_strategies: Vec::new(),
    };

    Ok(MetaDat {
        version: META_DAT_VERSION,
        flags: FLAG_HAS_MCR_FIELDS,
        recording_id,
        program: str_field("program"),
        args,
        workdir: String::new(),
        recorder_id,
        paths: Vec::new(),
        mcr: Some(mcr),
        replay_launch: None,
        layout_snapshot: None,
        filter_provenance: Vec::new(),
        has_filter_provenance: false,
    })
}

/// Serialize a [`MetaDat`] into the binary `meta.dat` wire format.
///
/// Always emits the canonical encoding: the `flags` field of `meta` is
/// **not** written verbatim — instead the `FLAG_HAS_MCR_FIELDS` bit is
/// derived from `meta.mcr.is_some()` and any reserved bits in
/// `meta.flags` are ignored. This guarantees that
/// `parse_meta_dat(serialize_meta_dat(&x))` returns a value equal to
/// `x` (after `x.flags` is normalised) and that we never produce output
/// our own parser would reject.
pub fn serialize_meta_dat(meta: &MetaDat) -> Vec<u8> {
    // Pre-allocate a reasonable starting capacity. The header is 8 bytes;
    // the rest of the payload grows with the metadata size.
    let mut out = Vec::with_capacity(64);

    // Magic + version.
    out.extend_from_slice(&META_DAT_MAGIC);
    out.extend_from_slice(&META_DAT_VERSION.to_le_bytes());

    // Canonicalise flags — only emit bits we know how to read back.
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

    // M-REC-1: recording_id prepends the program field in v3+.
    write_string(&meta.recording_id, &mut out);

    // Program / args / workdir / recorder_id / paths.
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
            paths: vec![],
            mcr: None,
            replay_launch: None,
            layout_snapshot: None,
            filter_provenance: vec![],
            has_filter_provenance: false,
        }
    }

    /// Build a [`MetaDat`] with populated args + paths, but no MCR block.
    /// Round-trip fixture (b).
    fn fixture_with_args_and_paths() -> MetaDat {
        MetaDat {
            version: META_DAT_VERSION,
            flags: 0,
            recording_id: TEST_UUID_V7.to_owned(),
            program: "/usr/bin/ruby".to_owned(),
            args: vec!["script.rb".to_owned(), "--flag".to_owned(), "".to_owned()],
            workdir: "/home/user/proj".to_owned(),
            recorder_id: "ruby".to_owned(),
            paths: vec![
                "/home/user/proj/script.rb".to_owned(),
                "/home/user/proj/lib/util.rb".to_owned(),
            ],
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
            paths: vec!["src/main.sol".to_owned()],
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
    fn meta_dat_roundtrip_args_and_paths() {
        let original = fixture_with_args_and_paths();
        let bytes = serialize_meta_dat(&original);
        let parsed = parse_meta_dat(&bytes).expect("parse args+paths");
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
    ///     version: 3,
    ///     flags: 0,
    ///     recording_id: "01949fcc-7d92-7e9c-aaaa-bbbbbbbbbbbb",
    ///     program: "hi",
    ///     args: ["a"],
    ///     workdir: "/w",
    ///     recorder_id: "r",
    ///     paths: ["x"],
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
        buf.extend_from_slice(&3u16.to_le_bytes()); // version
        buf.extend_from_slice(&0u16.to_le_bytes()); // flags
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
        encode_varint(1, &mut buf); // paths_count
        encode_varint(1, &mut buf); // paths[0] "x"
        buf.push(b'x');
        buf
    }

    #[test]
    fn writer_compatibility_fixture() {
        let bytes = writer_compat_fixture_bytes();
        let parsed = parse_meta_dat(&bytes).expect("parse fixture");
        let expected = MetaDat {
            version: 3,
            flags: 0,
            recording_id: TEST_UUID_V7.to_owned(),
            program: "hi".to_owned(),
            args: vec!["a".to_owned()],
            workdir: "/w".to_owned(),
            recorder_id: "r".to_owned(),
            paths: vec!["x".to_owned()],
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

    /// M-REC-1.5 end-to-end: the parser rejects a v3 trace whose
    /// recording_id is not a canonical UUIDv7.
    #[test]
    fn rejects_invalid_recording_id() {
        let bad = "not-a-valid-uuid";
        let mut buf: Vec<u8> = Vec::new();
        buf.extend_from_slice(&META_DAT_MAGIC);
        buf.extend_from_slice(&3u16.to_le_bytes());
        buf.extend_from_slice(&0u16.to_le_bytes());
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
        for len in 0..8 {
            let buf = vec![0u8; len];
            match parse_meta_dat(&buf) {
                Err(MetaDatError::TooShort { got }) => assert_eq!(got, len),
                other => panic!("expected TooShort, got {other:?}"),
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

    #[test]
    fn rejects_unknown_flag_bits() {
        // Bit 4 is the lowest still-reserved flag (bits 0..=3 are now
        // FLAG_HAS_MCR_FIELDS / FLAG_HAS_REPLAY_LAUNCH_FIELDS /
        // FLAG_HAS_LAYOUT_SNAPSHOT / FLAG_HAS_TRACE_FILTER_PROVENANCE).
        let mut buf = writer_compat_fixture_bytes();
        buf[6] = 0b0001_0000;
        buf[7] = 0;
        match parse_meta_dat(&buf) {
            Err(MetaDatError::UnknownFlags { flags, unknown_bits }) => {
                assert_eq!(flags, 0b0001_0000);
                assert_eq!(unknown_bits, 0b0001_0000);
            }
            other => panic!("expected UnknownFlags, got {other:?}"),
        }
    }

    #[test]
    fn parses_replay_launch_fields() {
        // FLAG_HAS_REPLAY_LAUNCH_FIELDS (bit 1) with `aslr_disabled = true`
        // appended as a single byte after the paths block.
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
            paths: vec![],
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
        buf.extend_from_slice(&3u16.to_le_bytes());
        buf.extend_from_slice(&0u16.to_le_bytes());
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
        buf.extend_from_slice(&3u16.to_le_bytes());
        buf.extend_from_slice(&0u16.to_le_bytes());
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
}
