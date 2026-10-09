//! Minimal CTFS binary container reader (and test-only writer).
//!
//! Implements just enough of the CTFS container format (version 5,
//! `codetracer-trace-format-spec/ctfs-container.md`) to:
//! 1. Parse the container header and file directory
//! 2. Read named internal files by navigating the block mapping hierarchy
//!
//! See `codetracer-specs/Trace-Files/CTFS-Binary-Format.md` for the full
//! format specification. This module implements the subset needed for reading;
//! writing is provided only for test support (`write_minimal_ctfs`).
//!
//! # Format summary
//!
//! ```text
//! Block 0:
//!   Header (8 bytes): magic [C0 DE 72 AC E2], version, reserved
//!   Extended Header (8 bytes): block_size (u32), max_root_entries (u32)
//!   File Entry Array: max_root_entries × 24-byte entries
//!
//! Blocks 1..N:
//!   Data blocks and mapping blocks
//! ```
//!
//! File names are base40-encoded into a single `u64`. A file entry's
//! `MapBlock` is `0` for an empty member, the member's only data block with
//! bit 63 set for a member of at most one block, and otherwise the root of a
//! hierarchical mapping structure (up to 5 levels of indirect blocks).

use std::collections::HashMap;
use std::error::Error;
use std::fmt;
use std::fs;
use std::fs::File;
use std::io;
use std::path::Path;

// ── Constants ───────────────────────────────────────────────────────────

/// Magic bytes identifying a CTFS file: "C0DE trACE2" in hex-speak.
pub(crate) const CTFS_MAGIC: [u8; 5] = [0xC0, 0xDE, 0x72, 0xAC, 0xE2];

/// The container version this crate's writers write (`ctfs-container.md`
/// §1, "What a writer writes"): version 5, for a full-profile container with
/// no whole-file scheme.
///
/// Version 5 stores a member of at most one block without a mapping block
/// (its `MapBlock` carries [`CTFS_DIRECT`]) and an empty member as
/// `MapBlock = 0`. Earlier versions gave every member a mapping block, and
/// their bytes cannot be told apart from version 5's by anything but the
/// version byte, so they are refused by name (§2, "Older versions are
/// refused"); such containers are re-recorded.
pub(crate) const CTFS_VERSION: u8 = 5;

/// Version 6: a 24-byte header that adds `Profile` and whole-file
/// `Compression` (§1a). Its full profile is version 5's body with the
/// `FileEntry` array at 24; its compact profile is a flat directory of
/// concatenated members, read only from a memory-resident image. Any
/// whole-file scheme and a non-zero reserved byte are refused, naming the
/// value (§1c).
pub(crate) const CTFS_VERSION_V6: u8 = 6;

/// Size of the version 6 header.
pub(crate) const V6_HEADER_SIZE: usize = 24;

/// Bit 63 of `FileEntry.MapBlock`: set, the rest of the word is the member's
/// only data block (`ctfs-container.md` §2, "`MapBlock` has three forms").
pub(crate) const CTFS_DIRECT: u64 = 1 << 63;

/// Refuse every container version but the ones this reader implements (5
/// and 6), before any member is resolved.
pub(crate) fn check_container_version(version: u8) -> Result<(), CtfsError> {
    if version == CTFS_VERSION || version == CTFS_VERSION_V6 {
        Ok(())
    } else {
        Err(CtfsError::UnsupportedVersion(version))
    }
}

/// What a container's header says about where its root directory is.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) struct ContainerHeader {
    /// Block size in bytes (1024, 2048 or 4096).
    pub(crate) block_size: usize,
    /// Byte offset of the `FileEntry` array: the header's own size.
    pub(crate) entry_start: usize,
    /// Root directory entries (`MaxRootEntries`, or the auto-fill count).
    pub(crate) max_root_entries: usize,
}

/// Parse and validate a container header from its first bytes (at least 16;
/// 24 for version 6). Every value this reader does not implement is refused,
/// naming it (`ctfs-container.md` §1c).
pub(crate) fn parse_container_header(header: &[u8]) -> Result<ContainerHeader, CtfsError> {
    if header.len() < HEADER_SIZE + EXTENDED_HEADER_SIZE {
        return Err(CtfsError::Corrupt(format!(
            "file too small ({} bytes, need at least {})",
            header.len(),
            HEADER_SIZE + EXTENDED_HEADER_SIZE
        )));
    }
    if header[..5] != CTFS_MAGIC {
        return Err(CtfsError::InvalidMagic);
    }
    let version = header[5];
    check_container_version(version)?;
    let entry_start = if version == CTFS_VERSION_V6 {
        if header.len() < V6_HEADER_SIZE {
            return Err(CtfsError::Corrupt(format!(
                "a version 6 header is {V6_HEADER_SIZE} bytes, but only {} are present",
                header.len()
            )));
        }
        // The two closed-set fields are read before anything structural, so
        // an unknown value is reported as itself.
        let profile = parse_profile(header[PROFILE_OFFSET])?;
        parse_whole_file_compression(header[COMPRESSION_OFFSET])?;
        if let Some(i) = RESERVED_RANGE.clone().find(|&i| header[i] != 0) {
            return Err(CtfsError::Corrupt(format!(
                "version 6 header byte {i} is reserved and MUST be zero, but carries 0x{:02x}",
                header[i]
            )));
        }
        if profile == CtfsProfile::Compact {
            // A compact container has no block map; it is opened only through
            // `CtfsReader::from_source` on a memory-resident source, which
            // routes it before this header parser runs.
            return Err(compact_residency_refusal(
                "this door parses a full-profile header, and the container declares profile 1 (compact)",
            ));
        }
        V6_HEADER_SIZE
    } else {
        HEADER_SIZE + EXTENDED_HEADER_SIZE
    };
    // Validated after the version 6 fields, so a compact header (whose block
    // size is 0 by definition) is refused for its profile, not its block size.
    let block_size = u32::from_le_bytes([header[8], header[9], header[10], header[11]]) as usize;
    if !matches!(block_size, 1024 | 2048 | 4096) {
        return Err(CtfsError::Corrupt(format!("invalid block size: {block_size}")));
    }
    let raw_entries = u32::from_le_bytes([header[12], header[13], header[14], header[15]]) as usize;
    // `0` fills the rest of block 0 with entries (§1, "Auto-fill").
    let max_root_entries = if raw_entries == 0 {
        block_size.saturating_sub(entry_start) / FILE_ENTRY_SIZE
    } else {
        raw_entries
    };
    Ok(ContainerHeader {
        block_size,
        entry_start,
        max_root_entries,
    })
}

/// Read and parse the header through a [`BlockSource`].
fn read_container_header(source: &dyn BlockSource) -> Result<ContainerHeader, CtfsError> {
    let total = source.current_size();
    let want = V6_HEADER_SIZE.min(usize::try_from(total).unwrap_or(V6_HEADER_SIZE));
    let mut header = vec![0u8; want];
    if want > 0 {
        read_exact_at(source, 0, &mut header, "header")?;
    }
    parse_container_header(&header)
}

/// Size of the fixed header (magic + version + reserved).
pub(crate) const HEADER_SIZE: usize = 8;

/// Size of the extended header (block_size + max_root_entries).
pub(crate) const EXTENDED_HEADER_SIZE: usize = 8;

/// Size of each file entry in the root directory.
pub(crate) const FILE_ENTRY_SIZE: usize = 24;

/// Maximum number of mapping levels supported (5 levels handles files up to ~35 TB).
const MAX_MAPPING_LEVELS: usize = 5;

/// Container version 6, the only version in which a `Profile` byte exists.
pub(crate) const CTFS_PROFILED_VERSION: u8 = CTFS_VERSION_V6;

/// Size of the version-6 header.
pub(crate) const HEADER_V6_SIZE: usize = V6_HEADER_SIZE;

/// Byte offset of the version-6 `Profile` field.
const PROFILE_OFFSET: usize = 16;

/// Byte offset of the version-6 whole-file `Compression` field.
const COMPRESSION_OFFSET: usize = 17;

/// The six reserved bytes of the version-6 header, which MUST be zero.
const RESERVED_RANGE: std::ops::Range<usize> = 18..24;

/// Offset of the compact profile's `MemberCount` (u32 LE).
const COMPACT_MEMBER_COUNT_OFFSET: u64 = 24;

/// Offset at which the compact profile's directory begins.
const COMPACT_DIRECTORY_OFFSET: u64 = 28;

/// Size of one compact directory record: `(name: u64, offset: u64, length: u64)`.
const COMPACT_DIRECTORY_ENTRY_SIZE: u64 = 24;

/// The container body shape a version-6 header selects.
///
/// Version 5 has no `Profile` byte and is always [`CtfsProfile::Full`]; the
/// field is read from the header only at version 6.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CtfsProfile {
    /// Block-mapped body: block 0 carries the `FileEntry` array and every
    /// member's bytes are reached through its mapping hierarchy.
    Full,
    /// Concatenated raw members behind a flat `(name, offset, length)`
    /// directory, with no block map and no alignment.
    Compact,
}

impl fmt::Display for CtfsProfile {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            CtfsProfile::Full => write!(f, "full"),
            CtfsProfile::Compact => write!(f, "compact"),
        }
    }
}

/// Parse the `Profile` byte of a version-6 header.
///
/// An unknown value is REFUSED by name rather than defaulted: a reader that
/// treated an unrecognised profile as `full` would parse a body it has never
/// seen as the one it happens to implement, which is the whole of the refusal
/// rule the version-3/4 global-line-index incident bought.
fn parse_profile(byte: u8) -> Result<CtfsProfile, CtfsError> {
    match byte {
        0 => Ok(CtfsProfile::Full),
        1 => Ok(CtfsProfile::Compact),
        other => Err(CtfsError::Unimplemented(format!(
            "CTFS container declares profile {other}, which is not one this reader implements \
             (known profiles: 0 = full, 1 = compact)"
        ))),
    }
}

/// Parse the whole-file `Compression` byte of a version-6 header.
///
/// Same rule, same reason: an unknown scheme is not read as `none`. `none` is
/// the only scheme this reader can serve — the bytes it is handed must already
/// be the container — so a declared scheme is refused BY NAME rather than
/// ignored, which is the difference between "I cannot read this" and silently
/// parsing compressed bytes as a directory.
fn parse_whole_file_compression(byte: u8) -> Result<(), CtfsError> {
    match byte {
        0 => Ok(()),
        1 => Err(CtfsError::Unimplemented(
            "CTFS container declares whole-file compression 1 (zstd); this reader serves only \
             scheme 0 (none) and does not reconstruct a compressed container"
                .to_string(),
        )),
        other => Err(CtfsError::Unimplemented(format!(
            "CTFS container declares whole-file compression {other}, which is not one this \
             reader implements (known schemes: 0 = none, 1 = zstd)"
        ))),
    }
}

/// Whether `name` is a name the base40 encoder in this module could have
/// produced: non-empty, at most 12 characters, and every character in the
/// alphabet.
///
/// The round-trip alone is NOT sufficient and that is measured rather than
/// assumed: an out-of-alphabet character maps to the padding index, and an
/// INTERIOR one yields a word whose decoded name carries an embedded NUL —
/// which re-encodes to itself and so survives a round-trip unchanged.
fn name_is_well_formed(name: &str) -> bool {
    !name.is_empty() && name.len() <= 12 && name.bytes().all(|c| BASE40_CHARS[1..].contains(&c))
}

/// The one refusal every non-resident door gives for a compact container.
///
/// Written once, so the three doors that can be handed one — the positional
/// source, the follow source and the HTTP range source — cannot drift into
/// three different diagnoses of one condition. `because` says what is specific
/// to the caller; the remedy is the same for all of them.
fn compact_residency_refusal(because: &str) -> CtfsError {
    CtfsError::Unimplemented(format!(
        "a compact container must be loaded whole: it has no block map and no alignment, so there \
         is nothing for a ranged or positional source to seek with ({because}). Open it through \
         CtfsReader::open or CtfsReader::from_bytes, both of which read the whole image into an \
         InMemoryBlockSource"
    ))
}

// ── Base40 codec ────────────────────────────────────────────────────────

/// The base40 character set used for CTFS file names.
/// Index 0 is the null/padding character.
const BASE40_CHARS: &[u8; 40] = b"\x000123456789abcdefghijklmnopqrstuvwxyz./-";

/// Encode a file name (up to 12 characters) into a base40-packed `u64`.
///
/// Characters are encoded left-to-right with the leftmost character in the
/// lowest-order position: `c[0]*40^0 + c[1]*40^1 + ...`.
pub(crate) fn base40_encode(name: &str) -> Result<u64, Box<dyn Error>> {
    if name.len() > 12 {
        return Err(format!("CTFS filename too long ({} chars, max 12): {name}", name.len()).into());
    }

    let mut encoded: u64 = 0;
    let mut multiplier: u64 = 1;

    for (i, ch) in name.bytes().enumerate() {
        let idx = BASE40_CHARS.iter().position(|&c| c == ch).ok_or_else(|| {
            format!(
                "CTFS filename contains invalid character '{}' (0x{:02x}) at position {i}",
                ch as char, ch
            )
        })?;
        encoded += (idx as u64) * multiplier;
        multiplier *= 40;
    }

    Ok(encoded)
}

/// Decode a base40-packed `u64` into a file name string.
///
/// Trailing null-padding characters (index 0) are stripped.
pub(crate) fn base40_decode(mut encoded: u64) -> String {
    if encoded == 0 {
        return String::new();
    }

    let mut chars = Vec::with_capacity(12);
    for _ in 0..12 {
        let idx = (encoded % 40) as usize;
        encoded /= 40;
        chars.push(BASE40_CHARS[idx]);
    }

    // Strip trailing null padding
    while chars.last() == Some(&0) {
        chars.pop();
    }

    // Safety: all base40 characters are valid ASCII, so from_utf8 cannot fail.
    String::from_utf8(chars).unwrap_or_default()
}

// ── Error type ──────────────────────────────────────────────────────────

/// Errors that can occur when reading a CTFS container.
#[derive(Debug)]
pub enum CtfsError {
    /// The file does not start with the expected CTFS magic bytes.
    InvalidMagic,
    /// The format version is not supported.
    UnsupportedVersion(u8),
    /// A named file was not found in the container.
    FileNotFound(String),
    /// An I/O error occurred while reading the container.
    Io(io::Error),
    /// The container structure is corrupt or inconsistent.
    Corrupt(String),
    /// The container is WELL-FORMED but declares something this reader does not
    /// implement — a profile, a whole-file compression scheme, or a body shape
    /// a newer writer produces.
    ///
    /// Distinct from [`CtfsError::Corrupt`] on purpose. A container from a
    /// newer writer is not broken, and reporting it as corrupt sends a reader
    /// looking for a defect in the bytes instead of for the support it is
    /// missing. The same distinction was drawn in the Nim reader when its
    /// version-6 refusal stopped saying "broken".
    Unimplemented(String),
}

impl fmt::Display for CtfsError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            CtfsError::InvalidMagic => write!(f, "not a valid CTFS file (bad magic bytes)"),
            CtfsError::UnsupportedVersion(v) => write!(
                f,
                "CTFS container version {v} is not readable: this reader reads versions {CTFS_VERSION} \
                 and {CTFS_VERSION_V6}. Re-record the trace, or regenerate the fixture with its producer"
            ),
            CtfsError::FileNotFound(name) => write!(f, "internal file not found in CTFS container: {name}"),
            CtfsError::Io(e) => write!(f, "CTFS I/O error: {e}"),
            CtfsError::Corrupt(msg) => write!(f, "corrupt CTFS container: {msg}"),
            CtfsError::Unimplemented(msg) => write!(f, "unsupported CTFS container: {msg}"),
        }
    }
}

impl std::error::Error for CtfsError {
    fn source(&self) -> Option<&(dyn Error + 'static)> {
        match self {
            CtfsError::Io(e) => Some(e),
            _ => None,
        }
    }
}

impl From<io::Error> for CtfsError {
    fn from(e: io::Error) -> Self {
        CtfsError::Io(e)
    }
}

// ── File entry ──────────────────────────────────────────────────────────

/// A parsed file entry from the CTFS root directory.
#[derive(Debug, Clone)]
struct FileEntry {
    /// Decoded file name.
    name: String,
    /// Size of the file in bytes.
    size: u64,
    /// The raw `MapBlock` word: `0`, a tagged direct block, or a level-1
    /// mapping block (see [`MemberLayout`]). Always 0 for a compact member,
    /// which has no mapping block at all.
    map_block: u64,
    /// COMPACT PROFILE ONLY: the member's absolute byte offset in the
    /// container image.
    ///
    /// `None` for every full-profile entry, and that is what selects the read
    /// path: a compact member is a contiguous byte range, so it is served by
    /// one positional read and never touches block arithmetic. Keeping the
    /// discriminant on the ENTRY rather than only on the reader is deliberate —
    /// `read_range_inner` is the one place both profiles meet, and a field it
    /// must match on cannot be forgotten the way a reader-level flag can.
    compact_offset: Option<u64>,
}

/// The form a version 5 `FileEntry.MapBlock` takes (`ctfs-container.md` §2).
/// Decided from `MapBlock` alone, never from `Size`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum MemberLayout {
    /// `MapBlock = 0`: the member owns no block.
    Empty,
    /// Tagged: the member's only data block.
    Direct(u64),
    /// Untagged and non-zero: the member's level-1 mapping block.
    Mapped(u64),
}

impl FileEntry {
    fn layout(&self) -> MemberLayout {
        if self.map_block == 0 {
            MemberLayout::Empty
        } else if self.map_block & CTFS_DIRECT != 0 {
            MemberLayout::Direct(self.map_block & !CTFS_DIRECT)
        } else {
            MemberLayout::Mapped(self.map_block)
        }
    }
}

// ── Block source abstraction ──────────────────────────────────────────────

/// Abstraction over the raw byte storage backing a CTFS container.
///
/// `CtfsReader` resolves logical file blocks to physical block numbers and
/// then asks the `BlockSource` for the bytes at the corresponding container
/// offsets.  Separating *how blocks are stored* from *how blocks are located*
/// is the seam that later milestones extend without touching the reader:
///
/// - **M0 (this milestone):** [`InMemoryBlockSource`] (whole-file load, the
///   historical default) and [`LocalFileSource`] (positional `pread` over an
///   open `File`).  Both are byte-for-byte equivalent for a finalized
///   container; only the default path (`InMemoryBlockSource`) is wired in so
///   there is no behaviour change.
/// - **M1 (follow mode):** a follow source re-reads block-0 `FileEntry` sizes
///   on [`BlockSource::refresh`] to observe appended blocks while a writer is
///   still streaming, and reports finalization via [`BlockSource::is_finalized`].
/// - **M7 (HTTP):** a range-request source serves [`BlockSource::read_at`] from
///   bounded HTTP `Range:` fetches.
///
/// All reads are positional and side-effect free, so a `BlockSource` only
/// needs `&self` for reads; this keeps the read path shareable across threads
/// for sources whose underlying I/O is itself thread-safe.
pub trait BlockSource: fmt::Debug + Send + Sync {
    /// Read exactly `buf.len()` bytes starting at container byte `offset`.
    ///
    /// Returns the number of bytes read (always `buf.len()` on success).  An
    /// `offset`/length that runs past the currently-observable end of the
    /// container is a [`CtfsError::Corrupt`]; callers (e.g. `read_file`,
    /// `read_mapping_entry`) bounds-check against [`BlockSource::current_size`]
    /// before reading, mirroring the historical whole-file slice bounds checks.
    fn read_at(&self, offset: u64, buf: &mut [u8]) -> Result<usize, CtfsError>;

    /// The number of bytes currently observable through this source.
    ///
    /// For fixed sources this is the container length captured at open time.
    /// Growing/follow sources update this on [`BlockSource::refresh`].
    fn current_size(&self) -> u64;

    /// Re-observe the backing storage to pick up growth from a concurrent
    /// writer.  Fixed sources are a no-op; follow/HTTP sources override this in
    /// later milestones to re-read `FileEntry` sizes / re-probe content length.
    fn refresh(&mut self) -> Result<(), CtfsError> {
        Ok(())
    }

    /// Whether the container is finalized (the writer has committed terminal
    /// metadata such as `meta.dat`).
    ///
    /// M0 sources back finalized, fully-written containers, so the default is
    /// `true`; follow-mode (M1) overrides this to surface in-progress
    /// recordings as not-yet-finalized.
    fn is_finalized(&self) -> bool {
        true
    }

    /// Whether every byte of the container is already resident in this
    /// process's memory.
    ///
    /// `false` by default, which is the honest answer for every positional
    /// source: a local file, a follow source and an HTTP range source each
    /// fetch on demand. Only [`InMemoryBlockSource`] holds the whole image.
    ///
    /// This is the predicate the COMPACT profile is gated on, and it is a
    /// gate rather than a preference. A compact container is specified for a
    /// one-shot load: it has no block map, no alignment, and therefore nothing
    /// for a ranged reader to seek with. Serving one over a range source would
    /// be one request per member read, on a file whose whole point is that it
    /// is fetched once.
    fn is_memory_resident(&self) -> bool {
        false
    }

    /// Read the whole of block `block_num` (`block_size` bytes) into a freshly
    /// allocated `Vec`.
    ///
    /// This is the block-aligned helper the design's trait sketch defines
    /// (CTFS-Binary-Format.md §11.4 "Read Path" — `backing_store.read_block(N)`).
    /// It is deferred from M0 to M2, where the copy-on-write overlay
    /// ([`CtfsBlockOverlay`]) is its first consumer: the overlay resolves a
    /// block from its in-memory map *or* falls through to
    /// `backing_store.read_block(N)`, so the plain sources and the overlay must
    /// share one block-granular read primitive that returns identical bytes.
    ///
    /// The default implementation is layered on [`BlockSource::read_at`] via the
    /// shared [`read_exact_at`] bounds check, so every source (in-memory, local
    /// file, follow, and later HTTP range) gets a correct, bounds-checked
    /// `read_block` for free; a source with a cheaper block-granular fetch (e.g.
    /// the future HTTP range source's one-`Range`-request-per-block path) may
    /// override it.
    fn read_block(&self, block_num: u64, block_size: usize) -> Result<Vec<u8>, CtfsError> {
        let offset = block_num
            .checked_mul(block_size as u64)
            .ok_or_else(|| CtfsError::Corrupt(format!("read_block: block {block_num} offset overflow")))?;
        // Mirror `read_exact_at`'s bounds + short-read checks; we cannot call it
        // here because it takes `&dyn BlockSource` (an unsized cast from `Self`).
        let end = offset
            .checked_add(block_size as u64)
            .ok_or_else(|| CtfsError::Corrupt(format!("read_block {block_num}: read offset overflow")))?;
        if end > self.current_size() {
            return Err(CtfsError::Corrupt(format!(
                "read_block {block_num}: read extends beyond end of container"
            )));
        }
        let mut buf = vec![0u8; block_size];
        let read = self.read_at(offset, &mut buf)?;
        if read != buf.len() {
            return Err(CtfsError::Corrupt(format!(
                "read_block {block_num}: short read ({read} of {block_size} bytes)"
            )));
        }
        Ok(buf)
    }
}

/// Read exactly `buf.len()` bytes at `offset` from a `BlockSource`, mapping a
/// short read (storage smaller than requested) to a [`CtfsError::Corrupt`].
///
/// Centralises the "block extends beyond end of container" bounds check that
/// the historical whole-file path performed inline, so every reader call site
/// gets identical error reporting regardless of the backing source.
fn read_exact_at(source: &dyn BlockSource, offset: u64, buf: &mut [u8], context: &str) -> Result<(), CtfsError> {
    let end = offset
        .checked_add(buf.len() as u64)
        .ok_or_else(|| CtfsError::Corrupt(format!("{context}: read offset overflow")))?;
    if end > source.current_size() {
        return Err(CtfsError::Corrupt(format!(
            "{context}: read extends beyond end of container"
        )));
    }
    let read = source.read_at(offset, buf)?;
    if read != buf.len() {
        return Err(CtfsError::Corrupt(format!(
            "{context}: short read ({read} of {} bytes)",
            buf.len()
        )));
    }
    Ok(())
}

/// Parse Block 0's root file directory through a [`BlockSource`].
///
/// Shared by [`CtfsReader::from_source`] and [`CtfsReader::refresh`] so an open
/// and a re-observation can never disagree about how the directory is read.
///
/// **One positional read, not `max_root_entries` of them.**  The entry region is
/// a contiguous `max_root_entries * FILE_ENTRY_SIZE` byte span (744 bytes at the
/// default 31 entries), so reading it whole is free for a local source and turns
/// a remote refresh from 31 HTTP range requests into ONE — which matters a great
/// deal for the RS-M11 remote live tail, whose poll loop re-parses this
/// directory on every poll to observe `spans.idx`'s committed growth.  The
/// per-entry decode below is byte-for-byte what the previous per-entry read did,
/// including stopping at the first entry that would run past `total`.
fn parse_root_directory(
    source: &dyn BlockSource,
    total: u64,
    entry_start: usize,
    max_root_entries: usize,
) -> Result<(HashMap<String, FileEntry>, Vec<String>), CtfsError> {
    let entry_start = entry_start as u64;
    // How many whole entries are actually backed by the observable container.
    let available = total.saturating_sub(entry_start) / FILE_ENTRY_SIZE as u64;
    let entry_count = usize::try_from(available).unwrap_or(usize::MAX).min(max_root_entries);

    let mut files = HashMap::new();
    let mut order: Vec<String> = Vec::new();
    if entry_count == 0 {
        return Ok((files, order));
    }

    let mut region = vec![0u8; entry_count * FILE_ENTRY_SIZE];
    read_exact_at(source, entry_start, &mut region, "file entry")?;

    for i in 0..entry_count {
        let entry_buf = &region[i * FILE_ENTRY_SIZE..(i + 1) * FILE_ENTRY_SIZE];
        let size = u64::from_le_bytes(
            entry_buf[0..8]
                .try_into()
                .map_err(|_| CtfsError::Corrupt("file entry size slice".to_string()))?,
        );
        let map_block = u64::from_le_bytes(
            entry_buf[8..16]
                .try_into()
                .map_err(|_| CtfsError::Corrupt("file entry map_block slice".to_string()))?,
        );
        let name_encoded = u64::from_le_bytes(
            entry_buf[16..24]
                .try_into()
                .map_err(|_| CtfsError::Corrupt("file entry name slice".to_string()))?,
        );

        // Skip empty entries (size=0, map_block=0, name=0)
        if name_encoded == 0 {
            continue;
        }

        let name = base40_decode(name_encoded);
        order.push(name.clone());
        files.insert(
            name.clone(),
            FileEntry {
                name,
                size,
                map_block,
                compact_offset: None,
            },
        );
    }
    Ok((files, order))
}

/// Parse the COMPACT profile's flat directory (`ctfs-container.md` §1d).
///
/// Layout, and every offset is read rather than assumed: `MemberCount` (u32 LE)
/// at 24, then `MemberCount` 24-byte records from 28, each
/// `(Name: u64 base40, Offset: u64, Length: u64)`, then the members themselves
/// concatenated from `28 + 24*N` in directory order with no padding between
/// them and nothing after the last.
///
/// The six reader MUSTs §1d enumerates are applied HERE, before any member is
/// reachable, so there is no way to read a member out of a directory that has
/// not been checked. Each is a refusal that names the offending value.
fn parse_compact_directory(
    source: &dyn BlockSource,
    total: u64,
) -> Result<(HashMap<String, FileEntry>, Vec<String>), CtfsError> {
    if total < COMPACT_DIRECTORY_OFFSET {
        return Err(CtfsError::Corrupt(format!(
            "compact container is {total} bytes, too small to carry the 24-byte header and the \
             4-byte member count (need at least {COMPACT_DIRECTORY_OFFSET})"
        )));
    }

    let mut count_buf = [0u8; 4];
    read_exact_at(source, COMPACT_MEMBER_COUNT_OFFSET, &mut count_buf, "member count")?;
    let member_count = u32::from_le_bytes(count_buf) as u64;

    // §1d check 1: the directory fits inside the container.
    let directory_bytes = member_count
        .checked_mul(COMPACT_DIRECTORY_ENTRY_SIZE)
        .ok_or_else(|| CtfsError::Corrupt(format!("compact directory of {member_count} members overflows")))?;
    let first_member = COMPACT_DIRECTORY_OFFSET
        .checked_add(directory_bytes)
        .ok_or_else(|| CtfsError::Corrupt(format!("compact directory of {member_count} members overflows")))?;
    if first_member > total {
        return Err(CtfsError::Corrupt(format!(
            "compact directory declares {member_count} members, whose {directory_bytes} bytes of \
             directory would end at {first_member} in a {total}-byte container"
        )));
    }

    let mut files = HashMap::new();
    let mut order: Vec<String> = Vec::new();
    if member_count == 0 {
        // A container with no members is well-formed only if nothing follows
        // the (empty) directory; check 4 below would otherwise not run at all.
        if total != first_member {
            return Err(CtfsError::Corrupt(format!(
                "compact container declares 0 members but carries {} bytes after its directory",
                total - first_member
            )));
        }
        return Ok((files, order));
    }

    let mut region = vec![0u8; directory_bytes as usize];
    read_exact_at(source, COMPACT_DIRECTORY_OFFSET, &mut region, "compact directory")?;

    let mut expected_offset = first_member;
    for i in 0..member_count as usize {
        let base = i * COMPACT_DIRECTORY_ENTRY_SIZE as usize;
        let name_encoded = u64::from_le_bytes(
            region[base..base + 8]
                .try_into()
                .map_err(|_| CtfsError::Corrupt("compact directory name slice".to_string()))?,
        );
        let offset = u64::from_le_bytes(
            region[base + 8..base + 16]
                .try_into()
                .map_err(|_| CtfsError::Corrupt("compact directory offset slice".to_string()))?,
        );
        let length = u64::from_le_bytes(
            region[base + 16..base + 24]
                .try_into()
                .map_err(|_| CtfsError::Corrupt("compact directory length slice".to_string()))?,
        );

        // §1d check 5: every name is non-zero, round-trips, and is spelled in
        // the alphabet. The round-trip alone does not catch an interior
        // out-of-alphabet character, so both halves are checked.
        if name_encoded == 0 {
            return Err(CtfsError::Corrupt(format!(
                "compact directory entry {i} has a zero Name, which no member can have"
            )));
        }
        let name = base40_decode(name_encoded);
        if !name_is_well_formed(&name) {
            return Err(CtfsError::Corrupt(format!(
                "compact directory entry {i} has Name 0x{name_encoded:016x}, which decodes to \
                 {name:?} — not a name the base40 alphabet can spell"
            )));
        }
        match base40_encode(&name) {
            Ok(re_encoded) if re_encoded == name_encoded => {}
            _ => {
                return Err(CtfsError::Corrupt(format!(
                    "compact directory entry {i} has Name 0x{name_encoded:016x}, which does not \
                     round-trip through the base40 codec (decoded {name:?})"
                )));
            }
        }

        // §1d checks 2 and 3: the first member begins at `28 + 24*N` and the
        // members are contiguous. Both are the same equality, applied in
        // directory order, which is why they are one check here.
        if offset != expected_offset {
            return Err(CtfsError::Corrupt(format!(
                "compact member {name:?} (entry {i}) declares Offset {offset}, but the members \
                 are concatenated in directory order and this one must begin at {expected_offset}"
            )));
        }
        let end = offset
            .checked_add(length)
            .ok_or_else(|| CtfsError::Corrupt(format!("compact member {name:?} length overflows")))?;
        if end > total {
            return Err(CtfsError::Corrupt(format!(
                "compact member {name:?} (entry {i}) spans [{offset}, {end}) in a {total}-byte \
                 container"
            )));
        }
        expected_offset = end;

        // §1d check 6: the names are distinct.
        order.push(name.clone());
        if let Some(previous) = files.insert(
            name.clone(),
            FileEntry {
                name: name.clone(),
                size: length,
                map_block: 0,
                compact_offset: Some(offset),
            },
        ) {
            return Err(CtfsError::Corrupt(format!(
                "compact directory names member {name:?} twice (entry {i} and an earlier one at \
                 offset {})",
                previous.compact_offset.unwrap_or(0)
            )));
        }
    }

    // §1d check 4: nothing follows the last member.
    if expected_offset != total {
        return Err(CtfsError::Corrupt(format!(
            "compact container is {total} bytes but its members end at {expected_offset}, leaving \
             {} byte(s) belonging to no member — the compact profile pads nothing",
            total - expected_offset
        )));
    }

    Ok((files, order))
}

/// A `BlockSource` backed by the whole container loaded into a `Vec<u8>`.
///
/// This preserves the exact pre-M0 behaviour: `CtfsReader` historically held
/// `data: Vec<u8>` and sliced it directly.  Routing those slices through this
/// source is byte-for-byte equivalent — it is the M0 default.
#[derive(Debug)]
pub struct InMemoryBlockSource {
    data: Vec<u8>,
}

impl InMemoryBlockSource {
    /// Wrap an already-loaded container image.
    pub fn new(data: Vec<u8>) -> Self {
        InMemoryBlockSource { data }
    }
}

impl BlockSource for InMemoryBlockSource {
    fn read_at(&self, offset: u64, buf: &mut [u8]) -> Result<usize, CtfsError> {
        let start = offset as usize;
        let end = start
            .checked_add(buf.len())
            .ok_or_else(|| CtfsError::Corrupt("in-memory read offset overflow".to_string()))?;
        if end > self.data.len() {
            return Err(CtfsError::Corrupt(format!(
                "in-memory read [{start}..{end}) extends beyond end of container ({} bytes)",
                self.data.len()
            )));
        }
        buf.copy_from_slice(&self.data[start..end]);
        Ok(buf.len())
    }

    fn current_size(&self) -> u64 {
        self.data.len() as u64
    }

    /// The whole image is in `self.data`, so every stream a reader resolves
    /// through this source is already resident. This is the one source over
    /// which a compact container may be opened.
    fn is_memory_resident(&self) -> bool {
        true
    }
}

/// A `BlockSource` backed by positional reads (`pread`) over an open `File`.
///
/// Modelled on `codetracer_ctfs::concurrent_reader::ConcurrentCtfsReader`:
/// `pread` does not move a shared file cursor, so reads are thread-safe and the
/// container is never fully loaded into RAM.  M0 implements and unit-tests this
/// source but does not make it the default — that swap lands with follow mode
/// (M1) and the HTTP source (M7) which build on the same positional seam.
#[derive(Debug)]
pub struct LocalFileSource {
    file: File,
    /// Container length observed at open time (and re-observed on `refresh`).
    size: u64,
}

impl LocalFileSource {
    /// Open `path` for positional reads.
    pub fn open(path: &Path) -> Result<Self, CtfsError> {
        let file = File::open(path)?;
        let size = file.metadata()?.len();
        Ok(LocalFileSource { file, size })
    }
}

impl BlockSource for LocalFileSource {
    fn read_at(&self, offset: u64, buf: &mut [u8]) -> Result<usize, CtfsError> {
        // Cross-platform positional read; mirrors `pread_compat::pread`.
        #[cfg(unix)]
        {
            use std::os::unix::fs::FileExt;
            self.file.read_exact_at(buf, offset)?;
        }
        #[cfg(windows)]
        {
            use std::os::windows::fs::FileExt;
            let mut read = 0usize;
            while read < buf.len() {
                let n = self.file.seek_read(&mut buf[read..], offset + read as u64)?;
                if n == 0 {
                    return Err(CtfsError::Corrupt("local-file source: unexpected EOF".to_string()));
                }
                read += n;
            }
        }
        #[cfg(not(any(unix, windows)))]
        {
            use std::io::{Read, Seek, SeekFrom};
            let mut f = &self.file;
            f.seek(SeekFrom::Start(offset))?;
            f.read_exact(buf)?;
        }
        Ok(buf.len())
    }

    fn current_size(&self) -> u64 {
        self.size
    }

    fn refresh(&mut self) -> Result<(), CtfsError> {
        // Re-observe the file length so a later milestone's follow logic — and
        // even a plain reader over a growing file — can see appended bytes.
        self.size = self.file.metadata()?.len();
        Ok(())
    }
}

/// A `BlockSource` that follows a *growing* local `.ct` file during live
/// recording (M1).
///
/// Where [`LocalFileSource`] snapshots the container length at open and only
/// re-observes it on an explicit [`BlockSource::refresh`], `FollowFileSource`
/// is purpose-built for the *write-during-read* case: a recorder is still
/// appending blocks to the container, growing individual internal files
/// (`steps.dat`, `steps.idx`, `values.dat`, …) and updating their
/// `FileEntry.Size` entries in Block 0 as each chunk is flushed (the CTFS
/// streaming/reader protocol — see CTFS-Binary-Format.md §6 "Reader Protocol"
/// and §7 "Streaming and Seeking During Active Writing", and the reference
/// implementation in `codetracer_ctfs::concurrent_reader::ConcurrentCtfsReader`).
///
/// It exposes two follow-specific observations on top of the positional read
/// path:
///
/// - [`current_size`](BlockSource::current_size) reflects the *raw container
///   length* (so positional block reads that land in newly-appended blocks
///   succeed once those bytes are on disk), refreshed by
///   [`refresh`](BlockSource::refresh).
/// - [`file_size`](FollowFileSource::file_size) returns the latest committed
///   `FileEntry.Size` for a named internal file, re-read from Block 0 on
///   `refresh()`. This is the growth signal a follow reader watches: when the
///   recorder flushes a new `steps.dat` chunk, `steps.dat`'s `FileEntry.Size`
///   grows and its companion `steps.idx` gains a new offset entry, so the
///   newly-committed records become visible.
/// - [`is_finalized`](BlockSource::is_finalized) becomes `true` once the
///   container carries a non-empty `meta.dat` — the writer commits terminal
///   metadata last, so its presence means no further growth will occur and a
///   follow reader can stop polling.
///
/// `refresh()` re-reads ONLY Block 0's `FileEntry` array (a single positional
/// read per entry), never the whole container, so polling a multi-gigabyte
/// growing trace stays O(max_root_entries) per refresh regardless of trace
/// size — exactly the cheap reader-protocol re-read the concurrent reader uses.
#[derive(Debug)]
pub struct FollowFileSource {
    file: File,
    /// Raw container length observed at open / last `refresh`.
    size: u64,
    /// Block size, parsed from the extended header at open. Needed to locate the
    /// Block 0 `FileEntry` array on each `refresh`.
    block_size: usize,
    /// Byte offset of the `FileEntry` array (the header's size).
    entry_start: usize,
    /// Number of root directory entries (extended header `max_root_entries`).
    max_root_entries: usize,
    /// The latest `FileEntry.Size` per internal file name, re-read from Block 0
    /// on every `refresh`. This is the per-file growth signal — distinct from
    /// the raw container `size`, which only ever grows monotonically as bytes
    /// land on disk.
    file_sizes: HashMap<String, u64>,
    /// `true` once a non-empty `meta.dat` is observed.
    finalized: bool,
}

/// Names whose non-empty presence seals a recording: the binary metadata
/// document, committed and non-empty, means the writer has finished.
///
/// The retired `meta.json` used to be listed here too, and removing it was
/// only safe once every writer emitted `meta.dat` unconditionally — a bundle
/// with no dedicated streams used to omit it, and would then never have looked
/// finalized to a follow reader.
const FINALIZATION_META_FILES: [&str; 1] = ["meta.dat"];

impl FollowFileSource {
    /// Open `path` for follow-mode positional reads and take an initial
    /// observation of Block 0 (`FileEntry` sizes + finalization state).
    ///
    /// The container must already exist and carry a valid header (the recorder
    /// writes Block 0 before any data chunk); a not-yet-created or header-less
    /// file is a [`CtfsError`], matching the concurrent reader's open contract.
    pub fn open(path: &Path) -> Result<Self, CtfsError> {
        let file = File::open(path)?;
        let size = file.metadata()?.len();
        // Parse the header to locate the FileEntry array. We read it here
        // (not lazily) so a malformed container fails fast at open.
        let want = V6_HEADER_SIZE.min(usize::try_from(size).unwrap_or(V6_HEADER_SIZE));
        let mut header = vec![0u8; want];
        Self::pread_into(&file, 0, &mut header)?;
        let ContainerHeader {
            block_size,
            entry_start,
            max_root_entries,
        } = parse_container_header(&header)?;

        let mut source = FollowFileSource {
            file,
            size,
            block_size,
            entry_start,
            max_root_entries,
            file_sizes: HashMap::new(),
            finalized: false,
        };
        source.reobserve_block_zero()?;
        Ok(source)
    }

    /// The latest committed `FileEntry.Size` for a named internal file, or
    /// `None` if no entry for that name has been observed yet.
    ///
    /// This is the growth signal a follow reader watches between
    /// [`refresh`](BlockSource::refresh) calls: a recorder flushing a new chunk
    /// grows the target file's `FileEntry.Size`, and the next `refresh()` makes
    /// the larger size visible here.
    pub fn file_size(&self, name: &str) -> Option<u64> {
        self.file_sizes.get(name).copied()
    }

    /// Re-read Block 0's `FileEntry` array and the finalization state. Shared by
    /// `open` and `refresh`. Mirrors `ConcurrentCtfsReader::refresh`: one
    /// positional read per root entry, no whole-container scan.
    fn reobserve_block_zero(&mut self) -> Result<(), CtfsError> {
        let entry_start = self.entry_start as u64;
        for i in 0..self.max_root_entries {
            let offset = entry_start + (i * FILE_ENTRY_SIZE) as u64;
            // Stop once an entry would run past the bytes currently on disk —
            // a still-growing container may not yet have all entry slots
            // materialized, exactly as the directory parse tolerates.
            if offset + FILE_ENTRY_SIZE as u64 > self.size {
                break;
            }
            let mut buf = [0u8; FILE_ENTRY_SIZE];
            Self::pread_into(&self.file, offset, &mut buf)?;
            let size = u64::from_le_bytes(
                buf[0..8]
                    .try_into()
                    .map_err(|_| CtfsError::Corrupt("follow: file entry size slice".to_string()))?,
            );
            let name_encoded = u64::from_le_bytes(
                buf[16..24]
                    .try_into()
                    .map_err(|_| CtfsError::Corrupt("follow: file entry name slice".to_string()))?,
            );
            if name_encoded == 0 {
                continue;
            }
            let name = base40_decode(name_encoded);
            self.file_sizes.insert(name, size);
        }

        // Finalization: a non-empty meta file means the writer committed
        // terminal metadata and the trace is sealed.
        if !self.finalized {
            for meta in FINALIZATION_META_FILES {
                if self.file_sizes.get(meta).copied().unwrap_or(0) > 0 {
                    self.finalized = true;
                    break;
                }
            }
        }
        Ok(())
    }

    /// Cross-platform positional read of exactly `buf.len()` bytes at `offset`,
    /// shared by the open/refresh Block 0 reads and [`BlockSource::read_at`].
    fn pread_into(file: &File, offset: u64, buf: &mut [u8]) -> Result<(), CtfsError> {
        #[cfg(unix)]
        {
            use std::os::unix::fs::FileExt;
            file.read_exact_at(buf, offset)?;
        }
        #[cfg(windows)]
        {
            use std::os::windows::fs::FileExt;
            let mut read = 0usize;
            while read < buf.len() {
                let n = file.seek_read(&mut buf[read..], offset + read as u64)?;
                if n == 0 {
                    return Err(CtfsError::Corrupt("follow-file source: unexpected EOF".to_string()));
                }
                read += n;
            }
        }
        #[cfg(not(any(unix, windows)))]
        {
            use std::io::{Read, Seek, SeekFrom};
            let mut f = file;
            f.seek(SeekFrom::Start(offset))?;
            f.read_exact(buf)?;
        }
        Ok(())
    }
}

impl BlockSource for FollowFileSource {
    fn read_at(&self, offset: u64, buf: &mut [u8]) -> Result<usize, CtfsError> {
        Self::pread_into(&self.file, offset, buf)?;
        Ok(buf.len())
    }

    fn current_size(&self) -> u64 {
        self.size
    }

    fn refresh(&mut self) -> Result<(), CtfsError> {
        // Re-observe the raw length first so a Block 0 entry that now points at
        // freshly-appended bytes is read against an up-to-date bound.
        self.size = self.file.metadata()?.len();
        self.reobserve_block_zero()
    }

    fn is_finalized(&self) -> bool {
        self.finalized
    }
}

/// The refusal for a null block pointer on the read path
/// (`ctfs-container.md` §4, "Null block pointers on the read path"): it names
/// the member and the pointer, and does not blame a truncation, which a null
/// pointer is not.
fn null_pointer(name: &str, pointer: &str, size: u64) -> CtfsError {
    CtfsError::Corrupt(format!(
        "file '{name}' (size {size}): its {pointer} is a null block pointer (block 0 is the \
         container header); the container is damaged"
    ))
}

// ── Reader ──────────────────────────────────────────────────────────────

/// Reader for a CTFS version 5 binary container.
///
/// Parses the header and file directory on construction, then provides
/// `read_file(name)` to extract internal files by name.
#[derive(Debug)]
pub struct CtfsReader {
    /// The byte storage backing the container.  Historically this was a
    /// `Vec<u8>` holding the whole file; M0 routes all block reads through a
    /// [`BlockSource`] instead.  The default constructed by [`CtfsReader::open`]
    /// / [`CtfsReader::from_bytes`] is an [`InMemoryBlockSource`], which is
    /// byte-for-byte equivalent to the prior whole-file path.
    source: Box<dyn BlockSource>,
    /// Block size in bytes (1024, 2048, or 4096).
    block_size: usize,
    /// Number of entries per mapping block (`block_size / 8`).
    entries_per_block: usize,
    /// Byte offset of the `FileEntry` array (the header's size).
    entry_start: usize,
    /// Maximum number of file entries in Block 0's root directory.
    max_root_entries: usize,
    /// Parsed file directory, keyed by decoded name.
    files: HashMap<String, FileEntry>,
    /// Which body shape this container carries.
    ///
    /// Versions 2..=4 have no `Profile` byte and are always
    /// [`CtfsProfile::Full`]; a version-6 container's value is read from byte
    /// 16 of its header.
    profile: CtfsProfile,
    /// Member names in DIRECTORY ORDER — the order the container itself
    /// declares them in, which `files` (a `HashMap`) cannot preserve.
    ///
    /// Kept because "a compact and a full container of one recording name the
    /// same members identically" is a claim about the SEQUENCE, and a
    /// comparison taken over a hash map's iteration order would be true
    /// whatever order either writer picked.
    order: Vec<String>,
}

impl CtfsReader {
    /// Open and parse a CTFS container from a file path.
    ///
    /// Loads the whole file into memory (the historical default) and backs the
    /// reader with an [`InMemoryBlockSource`], so behaviour is byte-for-byte
    /// unchanged from the pre-M0 `data: Vec<u8>` reader.
    pub fn open(path: &Path) -> Result<Self, CtfsError> {
        let data = fs::read(path)?;
        Self::from_bytes(data)
    }

    /// Parse a CTFS container from raw bytes, backed by an
    /// [`InMemoryBlockSource`].  This is the M0 default and preserves the exact
    /// prior whole-file behaviour.
    pub fn from_bytes(data: Vec<u8>) -> Result<Self, CtfsError> {
        Self::from_source(Box::new(InMemoryBlockSource::new(data)))
    }

    /// Parse a CTFS container served by an arbitrary [`BlockSource`].
    ///
    /// This is the M0 seam: the header, extended header and file directory are
    /// parsed via positional reads through `source` rather than by slicing an
    /// in-memory buffer, so any backing storage (in-memory, local file,
    /// follow, HTTP range) opens through one code path.
    pub fn from_source(source: Box<dyn BlockSource>) -> Result<Self, CtfsError> {
        let total = source.current_size();
        // A version 6 COMPACT container has no block map; it is routed to its
        // own loader before the full-profile header parser, which refuses it.
        if total >= HEADER_V6_SIZE as u64 {
            let mut probe = [0u8; HEADER_V6_SIZE];
            read_exact_at(source.as_ref(), 0, &mut probe, "header")?;
            if probe[..5] == CTFS_MAGIC
                && probe[5] == CTFS_PROFILED_VERSION
                && parse_profile(probe[PROFILE_OFFSET])? == CtfsProfile::Compact
            {
                return Self::from_profiled_source(source, total);
            }
        }
        let ContainerHeader {
            block_size,
            entry_start,
            max_root_entries,
        } = read_container_header(source.as_ref())?;
        let entries_per_block = block_size / 8;

        let (files, order) = parse_root_directory(source.as_ref(), total, entry_start, max_root_entries)?;

        Ok(CtfsReader {
            source,
            block_size,
            entries_per_block,
            entry_start,
            max_root_entries,
            files,
            profile: CtfsProfile::Full,
            order,
        })
    }

    /// Open a container whose version carries the 24-byte PROFILED header
    /// (version 6), routing on its `Profile` byte.
    ///
    /// This is the compact loader's door. It is a separate function rather than
    /// a branch inside [`CtfsReader::from_source`] because almost nothing is
    /// shared: the header is 24 bytes rather than 16, `BlockSize` and
    /// `MaxRootEntries` must be ZERO rather than valid, there is no
    /// `FileEntry` array, and the directory is read from offset 28.
    fn from_profiled_source(source: Box<dyn BlockSource>, total: u64) -> Result<Self, CtfsError> {
        if total < HEADER_V6_SIZE as u64 {
            return Err(CtfsError::Corrupt(format!(
                "container declares version {CTFS_PROFILED_VERSION} but is only {total} bytes — \
                 too short to carry its {HEADER_V6_SIZE}-byte header, so its Profile byte cannot \
                 be read (a header too short to carry a declared field is a refusal, not a \
                 default)"
            )));
        }

        let mut header = [0u8; HEADER_V6_SIZE];
        read_exact_at(source.as_ref(), 0, &mut header, "version-6 header")?;

        // Read the two closed-set fields BEFORE anything structural, so an
        // unknown value is reported as itself rather than as whatever the body
        // check downstream happens to trip over first.
        let profile = parse_profile(header[PROFILE_OFFSET])?;
        parse_whole_file_compression(header[COMPRESSION_OFFSET])?;
        for offset in RESERVED_RANGE {
            if header[offset] != 0 {
                return Err(CtfsError::Corrupt(format!(
                    "version-6 header byte {offset} is reserved and MUST be zero, but carries \
                     0x{:02x}",
                    header[offset]
                )));
            }
        }

        if profile == CtfsProfile::Full {
            // The full profile is read by `from_source`'s block-mapped path;
            // this loader is reached only for a compact container.
            return Err(CtfsError::Corrupt(
                "the compact loader was handed a version 6 container of profile 0 (full)".to_string(),
            ));
        }

        // The compact profile is specified for a one-shot load and carries
        // nothing a ranged reader could seek with. Gate it on residency HERE,
        // at the door, so no stream can be served from a source that would
        // fetch it piecemeal.
        if !source.is_memory_resident() {
            return Err(compact_residency_refusal(
                "this source fetches bytes on demand and reports itself as not memory-resident",
            ));
        }

        // §1d's two header MUSTs. Writing 4096 here "because it is the
        // default" is the defect they exist to catch: "there are no blocks"
        // spelled as a block size.
        let declared_block_size = u32::from_le_bytes([header[8], header[9], header[10], header[11]]);
        if declared_block_size != 0 {
            return Err(CtfsError::Corrupt(format!(
                "compact container declares BlockSize {declared_block_size}; the compact profile \
                 has no blocks, so §1d requires 0"
            )));
        }
        let declared_max_root_entries = u32::from_le_bytes([header[12], header[13], header[14], header[15]]);
        if declared_max_root_entries != 0 {
            return Err(CtfsError::Corrupt(format!(
                "compact container declares MaxRootEntries {declared_max_root_entries}; the \
                 compact profile has no FileEntry array for a maximum to bound, so §1d requires 0"
            )));
        }

        let (files, order) = parse_compact_directory(source.as_ref(), total)?;

        Ok(CtfsReader {
            source,
            // There are no blocks. These two carry 0 rather than the 4096 a
            // full container would, and every read path that would divide by
            // them is unreachable for a compact entry (`compact_offset` is
            // `Some`, which short-circuits before any block arithmetic).
            block_size: 0,
            entries_per_block: 0,
            entry_start: 0,
            max_root_entries: 0,
            files,
            profile: CtfsProfile::Compact,
            order,
        })
    }

    /// Which body shape this container carries.
    pub fn profile(&self) -> CtfsProfile {
        self.profile
    }

    /// How this container stores the chunks of its chunked streams: a full
    /// container as one zstd frame per chunk, a compact one as the chunk's
    /// content (`ctfs-container.md` §1f).
    pub fn chunk_form(&self) -> codetracer_trace_reader::ChunkForm {
        match self.profile {
            CtfsProfile::Full => codetracer_trace_reader::ChunkForm::Framed,
            CtfsProfile::Compact => codetracer_trace_reader::ChunkForm::Stored,
        }
    }

    /// Whether this container was opened through the compact loader.
    pub fn is_compact(&self) -> bool {
        self.profile == CtfsProfile::Compact
    }

    /// Open a CTFS container backed by a [`LocalFileSource`] (positional
    /// `pread` over the file, no whole-file load).
    ///
    /// M0 implements and tests this path but does not make it the default;
    /// [`CtfsReader::open`] still uses the in-memory source so the production
    /// open path is unchanged.  Follow mode (M1) wires positional sources in.
    pub fn open_local_file(path: &Path) -> Result<Self, CtfsError> {
        Self::from_source(Box::new(LocalFileSource::open(path)?))
    }

    /// Open a CTFS container backed by a [`FollowFileSource`] (M1 follow mode).
    ///
    /// Parses Block 0 (directory + extended header) via positional reads over a
    /// growing file. Because `from_source` re-parses the directory from the
    /// freshly-observed Block 0, re-opening through this constructor always
    /// reflects the latest committed `FileEntry` sizes — which is how the
    /// follow-mode split-stream reader picks up a live writer's appended blocks
    /// without ever loading the whole (still-growing) container into memory.
    pub fn open_follow(path: &Path) -> Result<Self, CtfsError> {
        Self::from_source(Box::new(FollowFileSource::open(path)?))
    }

    /// Re-observe the backing source and refresh Block 0's file directory.
    ///
    /// Fixed sources keep the same directory. Follow/HTTP sources can surface
    /// newly-committed `FileEntry.Size` values without replacing this reader.
    pub fn refresh(&mut self) -> Result<(), CtfsError> {
        self.source.refresh()?;
        let total = self.source.current_size();
        let (files, order) = match self.profile {
            CtfsProfile::Full => {
                parse_root_directory(self.source.as_ref(), total, self.entry_start, self.max_root_entries)?
            }
            // A compact container is fetched whole and its only memory-resident
            // source never grows, so this re-parses the same bytes. It is
            // routed rather than skipped so the two profiles cannot disagree
            // about what a refresh means.
            CtfsProfile::Compact => parse_compact_directory(self.source.as_ref(), total)?,
        };
        self.files = files;
        self.order = order;
        Ok(())
    }

    /// Read the full contents of a named internal file.
    ///
    /// Returns `CtfsError::FileNotFound` if no file with the given name
    /// exists in the container.
    pub fn read_file(&mut self, name: &str) -> Result<Vec<u8>, CtfsError> {
        let entry = self
            .files
            .get(name)
            .ok_or_else(|| CtfsError::FileNotFound(name.to_string()))?
            .clone();

        if entry.size == 0 {
            return Ok(Vec::new());
        }

        self.read_file_range(name, 0, entry.size)
    }

    /// The directory-declared byte size of a named internal file, or `None`
    /// when the container has no such entry.
    ///
    /// This is the writer's *committed* size — the number the writer published
    /// in Block 0 — and is therefore the growth signal a live consumer watches.
    /// It is deliberately NOT the container's own file length: a `.ct` is
    /// block-padded, so a container can gain a whole chunk without its length
    /// changing by a single byte (all four RS-M3 tail fixtures are exactly
    /// 155 648 bytes), which is precisely why a remote tail cannot use
    /// `Content-Length` to detect growth.
    pub fn file_size(&self, name: &str) -> Option<u64> {
        self.files.get(name).map(|e| e.size)
    }

    /// Read `len` bytes at logical `offset` within a named internal file,
    /// touching ONLY the data blocks that range actually covers.
    ///
    /// This is the primitive that makes a remote reader affordable: over an
    /// [`HttpRangeSource`](super::http_range_source::HttpRangeSource) it costs
    /// one bounded `Range:` request per covered block instead of one per block
    /// of the whole file. A request that runs past the file's declared size, or
    /// past bytes the container actually carries, is a
    /// [`CtfsError::Corrupt`] — never a short or zero-padded result.
    pub fn read_file_range(&mut self, name: &str, offset: u64, len: u64) -> Result<Vec<u8>, CtfsError> {
        let got = self.read_range_inner(name, offset, len, /* whole_blocks_only */ true)?;
        if got.len() as u64 != len {
            return Err(CtfsError::Corrupt(format!(
                "file '{name}': range [{offset}, {}) is not fully backed ({} of {len} bytes present)",
                offset.saturating_add(len),
                got.len()
            )));
        }
        Ok(got)
    }

    /// Read AT MOST `len` bytes at logical `offset` within a named internal
    /// file, stopping at the first block the container does not actually carry.
    ///
    /// # Why a tolerant read exists at all
    ///
    /// A container that is still being written — or one whose upload was cut
    /// short — has a Block 0 directory that promises more bytes than the file
    /// currently holds: the writer publishes a `FileEntry.Size` and the bytes
    /// land after it, and an interrupted transfer keeps the (leading) directory
    /// while losing the tail. The append-only stream formats are designed so
    /// that such a file is a **valid prefix** (CTFS-Request-Span-Streams.md
    /// design goal 4), but only a reader that can say "these bytes are here and
    /// those are not" can exploit that; the strict whole-file
    /// [`CtfsReader::read_file`] can only fail.
    ///
    /// This returns the longest backed prefix of the requested range. It NEVER
    /// zero-pads and never returns bytes it did not read: a caller receiving
    /// fewer bytes than it asked for knows exactly how many are real. Deciding
    /// whether a short read is benign (a writer mid-append) or fatal (a torn
    /// record) is the caller's job — see
    /// [`crate::remote_request_spans`], which resolves it at chunk granularity.
    pub fn read_file_range_available(&mut self, name: &str, offset: u64, len: u64) -> Result<Vec<u8>, CtfsError> {
        self.read_range_inner(name, offset, len, /* whole_blocks_only */ false)
    }

    /// The one range-read implementation behind both the strict and the
    /// tolerant entry point above. `whole_blocks_only` is the difference, and
    /// it is the whole of `CTFS-Binary-Format.md` §5d's reader bound.
    ///
    /// # Why the two callers want different bounds
    ///
    /// §5d says a container's addressable blocks are the WHOLE blocks it
    /// carries: `floor(length / block_size)`, never rounded up. Bytes past the
    /// last whole block are the fragment a crash inside an append's tail write
    /// leaves, or the block a live producer has not finished, and a data block
    /// resolved there must be an error rather than content. The other two
    /// readers of this format in the workspace enforce exactly that (the Go
    /// reader's `resolveDataBlock`, the Nim `readInternalFile`), and this
    /// reader did not until `whole_blocks_only` was added: on a truncated
    /// container it read a stream's last, short data block straight out of the
    /// partial region and reported success, so the three implementations gave
    /// different answers about the same bytes.
    ///
    /// But bounding is only right for the reader that is claiming the range is
    /// *intact*. The tolerant reader exists precisely to serve the longest
    /// backed prefix of a container whose tail has not landed yet, and its
    /// boundary is deliberately BYTE-granular (see its doc comment): a 2 KB
    /// stream living inside a half-uploaded 4 KB block still yields its landed
    /// prefix, which a whole-block rule would throw away. It never claims the
    /// range is complete — the caller is told exactly how many bytes are real
    /// — so it is not the reader §5d's rule is about.
    ///
    /// So: the strict path refuses a block outside the container's whole
    /// blocks; the tolerant path stops there and reports the prefix.
    fn read_range_inner(
        &mut self,
        name: &str,
        offset: u64,
        len: u64,
        whole_blocks_only: bool,
    ) -> Result<Vec<u8>, CtfsError> {
        let entry = self
            .files
            .get(name)
            .ok_or_else(|| CtfsError::FileNotFound(name.to_string()))?
            .clone();

        let end = offset
            .checked_add(len)
            .ok_or_else(|| CtfsError::Corrupt(format!("file '{name}': range offset overflow")))?;
        if end > entry.size {
            return Err(CtfsError::Corrupt(format!(
                "file '{name}': range [{offset}, {end}) extends past the declared size {}",
                entry.size
            )));
        }
        if len == 0 {
            return Ok(Vec::new());
        }

        // ── The COMPACT read path ────────────────────────────────────────
        //
        // A compact member is a contiguous byte range of a resident image, so
        // the whole of "resolve logical byte N" is one addition. There is no
        // mapping walk, no block index, no whole-blocks bound and no
        // partial-block clamp: the four things below this branch all answer
        // questions the compact layout does not raise. `whole_blocks_only` has
        // no compact meaning either — it is §5d's rule about the last block a
        // container carries, and a compact container's last byte IS its last
        // member's last byte, which the directory checks already established.
        if let Some(member_base) = entry.compact_offset {
            let src_offset = member_base
                .checked_add(offset)
                .ok_or_else(|| CtfsError::Corrupt(format!("compact member '{name}': offset overflow")))?;
            let mut out = vec![0u8; len as usize];
            read_exact_at(
                self.source.as_ref(),
                src_offset,
                &mut out,
                &format!("compact member '{name}'"),
            )?;
            return Ok(out);
        }

        let block_size = self.block_size as u64;
        // `ctfs-container.md` §2, "Readers": the layout comes from `MapBlock`,
        // and each form has the checks its pointer needs before any block of
        // it is read.
        let layout = entry.layout();
        match layout {
            MemberLayout::Empty => {
                return Err(null_pointer(name, "MapBlock", entry.size));
            }
            MemberLayout::Direct(0) => {
                return Err(CtfsError::Corrupt(format!(
                    "file '{name}' (size {}): its direct data block is a null block pointer: it names \
                     data block 0, and block 0 is the container's root directory, which no member may \
                     name; the container is damaged",
                    entry.size
                )));
            }
            MemberLayout::Direct(_) if entry.size > block_size => {
                return Err(CtfsError::Corrupt(format!(
                    "file '{name}' is stored in one direct block but declares {} bytes, more than one \
                     block ({block_size} bytes) holds",
                    entry.size
                )));
            }
            MemberLayout::Direct(_) | MemberLayout::Mapped(_) => {}
        }

        let first_block = offset / block_size;
        let last_block = (end - 1) / block_size;

        let mut result = Vec::with_capacity(len as usize);
        for block_index in first_block..=last_block {
            let logical = usize::try_from(block_index)
                .map_err(|_| CtfsError::Corrupt(format!("file '{name}': block index does not fit in usize")))?;
            let data_block_num = match layout {
                MemberLayout::Direct(block) => block,
                MemberLayout::Mapped(root) => self.resolve_block(root, logical, whole_blocks_only, name)?,
                MemberLayout::Empty => unreachable!("an empty layout with a size was refused above"),
            };
            if data_block_num == 0 {
                return Err(null_pointer(name, &format!("data block {logical}"), entry.size));
            }
            // §5d's bound, applied to the DATA block — the path that is easy to
            // miss, because the last block's slice is clamped to the requested
            // range and so a short read out of the partial region succeeds.
            if whole_blocks_only {
                let whole_blocks = self.source.current_size() / block_size;
                if data_block_num >= whole_blocks {
                    return Err(CtfsError::Corrupt(format!(
                        "file '{name}': data block {logical} is container block \
                         {data_block_num}, which is outside the {whole_blocks} whole \
                         {block_size}-byte blocks the container carries; it is truncated \
                         or its tail write was interrupted"
                    )));
                }
            }

            // The slice of THIS block that intersects the requested range.
            let block_start = block_index * block_size;
            let want_from = offset.max(block_start) - block_start;
            let want_to = (end.min(block_start + block_size)) - block_start;
            let to_read = (want_to - want_from) as usize;

            let src_offset = data_block_num
                .checked_mul(block_size)
                .and_then(|o| o.checked_add(want_from))
                .ok_or_else(|| {
                    CtfsError::Corrupt(format!(
                        "file '{name}': data block {logical} is container block {data_block_num}, \
                         past any offset the container can address"
                    ))
                })?;
            // The prefix boundary, decided in the ONE place it can be decided:
            // how many of these bytes the container actually carries. Clamping
            // to the available count rather than dropping the whole block keeps
            // the boundary BYTE-granular — a 2 KB stream that lives inside a
            // single 4 KB block still yields its landed prefix, which a
            // block-granular rule would throw away entirely.
            let available = self.source.current_size().saturating_sub(src_offset);
            let readable = (to_read as u64).min(available) as usize;
            if readable > 0 {
                let start = result.len();
                result.resize(start + readable, 0);
                read_exact_at(
                    self.source.as_ref(),
                    src_offset,
                    &mut result[start..start + readable],
                    &format!("file '{name}': block {data_block_num}"),
                )?;
            }
            if readable < to_read {
                // This block ran out; nothing after it can be contiguous.
                break;
            }
        }

        Ok(result)
    }

    /// Resolve a logical block index to a physical block number by walking
    /// the hierarchical mapping structure.
    ///
    /// The mapping uses Unix-like indirect blocks:
    /// - Level 1: entries 0..N-2 are direct block pointers, entry N-1 points
    ///   to the next level
    /// - Level 2+: each entry points to a lower-level mapping block
    ///
    /// Where N = `entries_per_block` (e.g. 128 for 1024-byte blocks).
    ///
    /// # Known writer pitfall (see M-CTFS-LargeFile)
    ///
    /// If a live (streaming) CTFS writer is read concurrently while it is
    /// emitting a file that spans more than `entries_per_block - 1` data
    /// blocks (512 - 1 = 511 for the default 4096-byte block size), the
    /// writer must flush every mapping block in the descent path — including
    /// intermediate level-1 child blocks created inside the multi-level
    /// chain.  An earlier Nim writer bug flushed only the root block and
    /// the level-2 chain block, leaving the level-1 child block as the
    /// zeros written by `flushBlock` at `allocBlock` time.  Concurrent
    /// readers and post-mortem readers of unclosed recordings then saw the
    /// data block pointer for index 511 as 0 and surfaced "unallocated
    /// block at index 511".  The fix lives in
    /// `codetracer-trace-format-nim/src/codetracer_ctfs/block_mapping.nim`
    /// (`navigateAndInsert`); this reader is otherwise correct — do not be
    /// tempted to "patch around" a similar error here by treating zero
    /// pointers as data blocks, because that would silently corrupt reads
    /// of properly-written containers.
    ///
    /// # The §5d bound on the MAPPING blocks
    ///
    /// The strict path first gained its bound on the **data** block and stopped
    /// there, so §5d recorded this reader as "the same bound applied in two of
    /// three places": a mapping block sitting in the partial region was still
    /// readable here, because `read_mapping_entry` only checks that the 8 bytes
    /// it wants are inside `current_size()`. The Nim and Go readers refuse that,
    /// so the implementations still disagreed about a file they now both accept.
    ///
    /// With the current writers' layout a mapping block is allocated after the
    /// data blocks it covers, so this is an agreement and hardening gap rather
    /// than a demonstrated wrong-bytes path — but a bound that holds on two of
    /// three paths is not the bound §5d specifies, and the missing third is
    /// exactly how the data-block gap survived the first sweep.
    ///
    /// Gated on `whole_blocks_only` for the same reason the data-block check is:
    /// the tolerant reader deliberately keeps a byte-granular boundary and never
    /// claims a range is complete.
    fn resolve_block(
        &self,
        root_map_block: u64,
        logical_index: usize,
        whole_blocks_only: bool,
        name: &str,
    ) -> Result<u64, CtfsError> {
        let direct_entries = self.entries_per_block - 1; // Last entry is the indirect pointer

        // Determine which level the logical_index falls into and compute
        // the path through the mapping hierarchy.
        //
        // Level 1: indices 0..direct_entries-1
        // Level 2: indices direct_entries..direct_entries + direct_entries^2 - 1
        // Level 3: ...
        let mut remaining = logical_index;
        let mut level = 1;
        let mut level_capacity = direct_entries;

        while remaining >= level_capacity && level < MAX_MAPPING_LEVELS {
            remaining -= level_capacity;
            level += 1;
            level_capacity *= direct_entries;
        }

        if remaining >= level_capacity {
            return Err(CtfsError::Corrupt(format!(
                "block index {logical_index} exceeds maximum mapping depth"
            )));
        }

        // Navigate from the root mapping block down to the data block.
        // First, get to the correct level by following the indirect pointer
        // (last entry) at each intermediate level.
        let mut current_block = root_map_block;

        // §5d path 1 of 3: the entry's mapping root.
        if whole_blocks_only {
            self.check_block_in_whole_blocks(current_block, name, "mapping root block")?;
        }

        // Follow indirect pointers to reach the target level
        for _ in 1..level {
            let indirect_ptr = self.read_mapping_entry(current_block, self.entries_per_block - 1)?;
            if indirect_ptr == 0 {
                return Err(CtfsError::Corrupt(format!(
                    "file '{name}': a chain pointer in its mapping is a null block pointer \
                     (block 0 is the container header); the container is damaged"
                )));
            }
            // §5d path 2a of 3: a mapping block reached through the chain.
            if whole_blocks_only {
                self.check_block_in_whole_blocks(indirect_ptr, name, "chained mapping block")?;
            }
            current_block = indirect_ptr;
        }

        // Now navigate within the target level. For level > 1, we need to
        // descend through the sub-blocks.
        if level == 1 {
            // Direct lookup in the root mapping block
            self.read_mapping_entry(current_block, remaining)
        } else {
            // Decompose `remaining` into a path of indices through the
            // sub-levels. At level L, each sub-block covers direct_entries^(L-1)
            // data blocks.
            self.resolve_multilevel(current_block, remaining, level - 1, whole_blocks_only, name)
        }
    }

    /// Refuse a block number at or past the container's whole blocks, before
    /// any of its bytes are touched. `floor`, never rounded up — rounding up is
    /// the one arithmetic `CTFS-Binary-Format.md` §5d forbids, because it makes
    /// the incomplete final block addressable.
    fn check_block_in_whole_blocks(&self, block: u64, name: &str, role: &str) -> Result<(), CtfsError> {
        let block_size = self.block_size as u64;
        let whole_blocks = self.source.current_size() / block_size;
        if block >= whole_blocks {
            return Err(CtfsError::Corrupt(format!(
                "file '{name}': {role} is container block {block}, which is outside the \
                 {whole_blocks} whole {block_size}-byte blocks the container carries; it is \
                 truncated or its tail write was interrupted"
            )));
        }
        Ok(())
    }

    /// Recursively resolve a block index through multi-level mapping.
    ///
    /// `depth` is the number of remaining levels to descend (0 = direct lookup).
    fn resolve_multilevel(
        &self,
        map_block: u64,
        index: usize,
        depth: usize,
        whole_blocks_only: bool,
        name: &str,
    ) -> Result<u64, CtfsError> {
        if depth == 0 {
            return self.read_mapping_entry(map_block, index);
        }

        let direct_entries = self.entries_per_block - 1;
        let sub_capacity = direct_entries.pow(depth as u32);
        let sub_index = index / sub_capacity;
        let sub_remaining = index % sub_capacity;

        if sub_index >= direct_entries {
            return Err(CtfsError::Corrupt(format!(
                "mapping sub-index {sub_index} out of range (max {direct_entries})"
            )));
        }

        let next_block = self.read_mapping_entry(map_block, sub_index)?;
        if next_block == 0 {
            return Err(CtfsError::Corrupt(format!(
                "file '{name}': a child pointer in its mapping is a null block pointer \
                 (block 0 is the container header); the container is damaged"
            )));
        }
        // §5d path 2b of 3: a mapping block reached by descending the hierarchy.
        if whole_blocks_only {
            self.check_block_in_whole_blocks(next_block, name, "child mapping block")?;
        }

        self.resolve_multilevel(next_block, sub_remaining, depth - 1, whole_blocks_only, name)
    }

    /// Read a single u64 entry from a mapping block.
    fn read_mapping_entry(&self, block_num: u64, entry_index: usize) -> Result<u64, CtfsError> {
        let offset = block_num
            .checked_mul(self.block_size as u64)
            .and_then(|o| o.checked_add((entry_index * 8) as u64))
            .ok_or_else(|| {
                CtfsError::Corrupt(format!(
                    "mapping entry at block {block_num}, index {entry_index} is past any offset the \
                     container can address"
                ))
            })?;
        let mut buf = [0u8; 8];
        read_exact_at(
            self.source.as_ref(),
            offset,
            &mut buf,
            &format!("mapping entry at block {block_num}, index {entry_index}"),
        )
        .map_err(|_| {
            // Preserve the prior error wording for out-of-bounds mapping reads.
            CtfsError::Corrupt(format!(
                "mapping entry at block {block_num}, index {entry_index} is out of bounds"
            ))
        })?;
        Ok(u64::from_le_bytes(buf))
    }

    /// List the names of all files in the container.
    #[allow(dead_code)]
    pub fn file_names(&self) -> Vec<&str> {
        self.files.keys().map(|s| s.as_str()).collect()
    }

    /// The container's member names in the order its own directory declares
    /// them.
    ///
    /// [`CtfsReader::file_names`] answers from a `HashMap` and is therefore in
    /// no order at all; this is the sequence the container states.
    pub fn member_names_in_order(&self) -> &[String] {
        &self.order
    }

    /// Check whether a named file exists in the container.
    #[allow(dead_code)]
    pub fn has_file(&self, name: &str) -> bool {
        self.files.contains_key(name)
    }

    /// Test-support accessor: the `(size, map_block)` of a named file's
    /// directory entry, or `None` if absent.  Used by the M2 overlay tests
    /// (sibling module) to locate a file's data block / size field in the raw
    /// container image for byte-level verification, without exposing the
    /// private `FileEntry` type.
    #[cfg(test)]
    pub(crate) fn file_entry(&self, name: &str) -> Option<(u64, u64)> {
        self.files.get(name).map(|e| (e.size, e.map_block))
    }

    /// Test-support accessor: the container block holding logical block
    /// `logical_index` of the named member, whichever form its `MapBlock`
    /// takes.  Used by the M2 overlay tests to find a file's data block offset
    /// in the raw image.
    #[cfg(test)]
    pub(crate) fn data_block_for_test(&self, name: &str, logical_index: usize) -> Result<u64, CtfsError> {
        let entry = self
            .files
            .get(name)
            .ok_or_else(|| CtfsError::FileNotFound(name.to_string()))?;
        match entry.layout() {
            MemberLayout::Empty => Err(CtfsError::Corrupt(format!("file '{name}' owns no block"))),
            MemberLayout::Direct(block) if logical_index == 0 => Ok(block),
            MemberLayout::Direct(_) => Err(CtfsError::Corrupt(format!("file '{name}' is one block"))),
            // Bounded like the strict read path: these helpers exist to locate a
            // block in a well-formed container, and a test that resolved a block
            // outside the container's whole blocks would be asserting on bytes
            // the container does not own.
            MemberLayout::Mapped(root) => self.resolve_block(root, logical_index, true, name),
        }
    }
}

// ── Test-only writer ────────────────────────────────────────────────────

/// Write a CTFS container for testing purposes.
///
/// Creates a version 5 container with block_size=4096, max_root_entries=31
/// and lays out each file the way `ctfs-container.md` §2 requires of a
/// closed container:
///
/// - An empty file owns no block: its entry is `(Size, MapBlock) = (0, 0)`.
/// - A file of at most one block owns that one data block and no mapping
///   block: `MapBlock` is the data block with [`CTFS_DIRECT`] set.
/// - A larger file uses the bottom-up multi-level chain mapping, its
///   level-1 mapping block claimed before its data blocks (§5, "Appending
///   Data", case 3):
///
/// - Each mapped file owns a root mapping block.  Entries `[0..usable)` of the
///   root are direct pointers to data blocks; entry `usable`
///   (= `entries_per_block - 1`) is the chain pointer to a level-2
///   mapping block when the file exceeds `usable` data blocks.
/// - Level-2 mapping blocks repeat the layout: entries `[0..usable)` each
///   point to a level-1 child mapping block (which in turn holds up to
///   `usable` direct data block pointers), and entry `usable` is the chain
///   pointer to a level-3 block.
/// - Levels 3..5 follow the same recursive pattern.
///
/// This intentionally mirrors `navigateAndInsert`/`insertDataBlock` in
/// `codetracer-trace-format-nim/src/codetracer_ctfs/block_mapping.nim` so
/// that the reader can be exercised against files large enough to require
/// multi-level mapping (>511 data blocks for the default block size).
///
/// # Panics
///
/// Panics if any file name is longer than 12 characters or contains
/// characters outside the base40 alphabet.
pub fn write_minimal_ctfs(path: &Path, files: &[(&str, &[u8])]) -> Result<(), Box<dyn Error>> {
    const BLOCK_SIZE: usize = 4096;
    const MAX_ROOT_ENTRIES: u32 = 31;
    let entries_per_block: usize = BLOCK_SIZE / 8;
    let usable: u64 = (entries_per_block - 1) as u64;

    // Helpers operating on the in-memory buffer.  Kept as free fns so they
    // can mutually recurse without fighting Rust's closure borrow rules.
    fn alloc_block(buf: &mut Vec<u8>, next_block: &mut u64) -> u64 {
        let blk = *next_block;
        *next_block += 1;
        let needed = (*next_block as usize) * BLOCK_SIZE;
        if needed > buf.len() {
            buf.resize(needed, 0);
        }
        blk
    }

    fn read_ptr(buf: &[u8], block: u64, index: u64) -> u64 {
        let off = (block as usize) * BLOCK_SIZE + (index as usize) * 8;
        // The slice is always exactly 8 bytes — `buf` is grown to a multiple
        // of `BLOCK_SIZE` by `alloc_block`, and `index < BLOCK_SIZE / 8`.
        // Pattern-match instead of `unwrap()` to keep the lint clean.
        let bytes: [u8; 8] = match buf[off..off + 8].try_into() {
            Ok(b) => b,
            Err(_) => unreachable!("test writer: read_ptr slice is always 8 bytes"),
        };
        u64::from_le_bytes(bytes)
    }

    fn write_ptr(buf: &mut [u8], block: u64, index: u64, value: u64) {
        let off = (block as usize) * BLOCK_SIZE + (index as usize) * 8;
        buf[off..off + 8].copy_from_slice(&value.to_le_bytes());
    }

    fn level_capacity(usable: u64, level: u32) -> u64 {
        let mut cap: u64 = 1;
        for _ in 0..level {
            cap = cap.saturating_mul(usable);
        }
        cap
    }

    // Recursive descent through level-k mapping blocks, allocating
    // intermediate child mapping blocks as needed and writing the data
    // block pointer at the final level-1 entry.
    fn navigate_and_insert(
        buf: &mut Vec<u8>,
        next_block: &mut u64,
        mapping_block: u64,
        level: u32,
        idx_within_level: u64,
        data_block: u64,
        usable: u64,
    ) {
        if level == 1 {
            write_ptr(buf, mapping_block, idx_within_level, data_block);
            return;
        }
        let sub_cap = level_capacity(usable, level - 1);
        let entry_idx = idx_within_level / sub_cap;
        let sub_idx = idx_within_level % sub_cap;
        let mut child = read_ptr(buf, mapping_block, entry_idx);
        if child == 0 {
            child = alloc_block(buf, next_block);
            write_ptr(buf, mapping_block, entry_idx, child);
        }
        navigate_and_insert(buf, next_block, child, level - 1, sub_idx, data_block, usable);
    }

    // Bottom-up chain insert (matches `insertDataBlock` in the Nim writer).
    fn insert_data_block(
        buf: &mut Vec<u8>,
        next_block: &mut u64,
        root_block: u64,
        block_index: u64,
        data_block: u64,
        usable: u64,
    ) {
        let mut idx = block_index;
        let mut current_level_block = root_block;
        let mut level: u32 = 1;
        loop {
            let cap = level_capacity(usable, level);
            if idx < cap {
                break;
            }
            idx -= cap;
            level += 1;
            assert!(level <= MAX_MAPPING_LEVELS as u32, "test writer: >5 mapping levels");
            let chain = read_ptr(buf, current_level_block, usable);
            current_level_block = if chain == 0 {
                let new_block = alloc_block(buf, next_block);
                write_ptr(buf, current_level_block, usable, new_block);
                new_block
            } else {
                chain
            };
        }
        navigate_and_insert(buf, next_block, current_level_block, level, idx, data_block, usable);
    }

    // Allocate enough buffer up-front for the root block; grow lazily.
    let mut buf: Vec<u8> = vec![0u8; BLOCK_SIZE];
    let mut next_block: u64 = 1;

    // Header (8 bytes) + extended header (8 bytes) + file entries.
    buf[0..5].copy_from_slice(&CTFS_MAGIC);
    buf[5] = CTFS_VERSION;
    // bytes 6-7: encryption=0, max_shards=0 (already zero)
    buf[8..12].copy_from_slice(&(BLOCK_SIZE as u32).to_le_bytes());
    buf[12..16].copy_from_slice(&MAX_ROOT_ENTRIES.to_le_bytes());

    let entry_start = HEADER_SIZE + EXTENDED_HEADER_SIZE;

    for (i, &(name, data)) in files.iter().enumerate() {
        let name_encoded = base40_encode(name)?;
        let size = data.len() as u64;
        let entry_off = entry_start + i * FILE_ENTRY_SIZE;
        if data.is_empty() {
            buf[entry_off..entry_off + 8].copy_from_slice(&0u64.to_le_bytes());
            buf[entry_off + 8..entry_off + 16].copy_from_slice(&0u64.to_le_bytes());
            buf[entry_off + 16..entry_off + 24].copy_from_slice(&name_encoded.to_le_bytes());
            continue;
        }
        buf[entry_off..entry_off + 8].copy_from_slice(&size.to_le_bytes());
        buf[entry_off + 16..entry_off + 24].copy_from_slice(&name_encoded.to_le_bytes());

        if data.len() <= BLOCK_SIZE {
            let data_block = alloc_block(&mut buf, &mut next_block);
            let off = (data_block as usize) * BLOCK_SIZE;
            buf[off..off + data.len()].copy_from_slice(data);
            buf[entry_off + 8..entry_off + 16].copy_from_slice(&(CTFS_DIRECT | data_block).to_le_bytes());
            continue;
        }

        let map_block = alloc_block(&mut buf, &mut next_block);
        buf[entry_off + 8..entry_off + 16].copy_from_slice(&map_block.to_le_bytes());

        // Stream data blocks, inserting each into the multi-level mapping
        // hierarchy and writing the file contents into the block.
        let num_data_blocks = data.len().div_ceil(BLOCK_SIZE);
        let mut written = 0usize;
        for block_index in 0..num_data_blocks {
            let data_block = alloc_block(&mut buf, &mut next_block);
            insert_data_block(
                &mut buf,
                &mut next_block,
                map_block,
                block_index as u64,
                data_block,
                usable,
            );
            let to_write = (data.len() - written).min(BLOCK_SIZE);
            let off = (data_block as usize) * BLOCK_SIZE;
            buf[off..off + to_write].copy_from_slice(&data[written..written + to_write]);
            written += to_write;
        }
    }

    fs::write(path, &buf)?;
    Ok(())
}

// ── Compact-profile writer (test support + conversion) ──────────────────

/// Encode `members` as a COMPACT container image (`ctfs-container.md` §1d).
///
/// The inverse of [`parse_compact_directory`], and deliberately written against
/// §1d's own size identity rather than against that parser: the image is
/// `24-byte header || MemberCount (u32 LE) || N x 24-byte directory ||
/// members concatenated in directory order`, so its length is exactly
/// `28 + 24*N + sum(len)`. Nothing is padded to a block, a page or a word.
///
/// Member payloads are copied VERBATIM. That is what makes a conversion from a
/// full container byte-exact, and it is also why a compact container built this
/// way inherits whatever per-member compression the source container used: the
/// §1d requirement that a compact container carry raw members is a property of
/// the WRITER that produced the recording, not of this encoder.
pub fn encode_compact_ctfs(members: &[(&str, &[u8])]) -> Result<Vec<u8>, Box<dyn Error>> {
    let n = members.len() as u64;
    let directory_bytes = n * COMPACT_DIRECTORY_ENTRY_SIZE;
    let first_member = COMPACT_DIRECTORY_OFFSET + directory_bytes;

    let mut buf = vec![0u8; first_member as usize];
    buf[0..5].copy_from_slice(&CTFS_MAGIC);
    buf[5] = CTFS_PROFILED_VERSION;
    // bytes 6-7: encryption = 0, max_shards = 0 (already zero).
    // §1d MUSTs: BlockSize = 0 and MaxRootEntries = 0 (already zero).
    buf[PROFILE_OFFSET] = 1; // compact
    buf[COMPRESSION_OFFSET] = 0; // none — the bytes in hand ARE the container
    // bytes 18..24 reserved, already zero.
    buf[COMPACT_MEMBER_COUNT_OFFSET as usize..COMPACT_MEMBER_COUNT_OFFSET as usize + 4]
        .copy_from_slice(&(members.len() as u32).to_le_bytes());

    let mut offset = first_member;
    for (i, (name, data)) in members.iter().enumerate() {
        let name_encoded = base40_encode(name)?;
        if name_encoded == 0 {
            return Err(format!("compact member {i} has an empty name").into());
        }
        let base = COMPACT_DIRECTORY_OFFSET as usize + i * COMPACT_DIRECTORY_ENTRY_SIZE as usize;
        buf[base..base + 8].copy_from_slice(&name_encoded.to_le_bytes());
        buf[base + 8..base + 16].copy_from_slice(&offset.to_le_bytes());
        buf[base + 16..base + 24].copy_from_slice(&(data.len() as u64).to_le_bytes());
        offset += data.len() as u64;
    }

    for (_, data) in members {
        buf.extend_from_slice(data);
    }

    debug_assert_eq!(
        buf.len() as u64,
        first_member + members.iter().map(|(_, d)| d.len() as u64).sum::<u64>(),
        "§1d size identity"
    );
    Ok(buf)
}

/// Write a COMPACT container at `path`.
pub fn write_compact_ctfs(path: &Path, members: &[(&str, &[u8])]) -> Result<(), Box<dyn Error>> {
    fs::write(path, encode_compact_ctfs(members)?)?;
    Ok(())
}

// ── Unit tests ──────────────────────────────────────────────────────────

#[cfg(test)]
#[allow(clippy::unwrap_used, clippy::expect_used)]
mod tests {
    use super::*;

    #[test]
    fn test_base40_roundtrip() {
        let names = [
            "meta.json",
            "events.log",
            "t00000000001",
            "paths.idx",
            "types.idx",
            "funcs.idx",
            "syncord.log",
            "cpdata.bin",
            "geid.idx",
            "a",
            "z",
            "0",
            "test",
        ];

        for name in &names {
            let encoded = base40_encode(name).unwrap();
            let decoded = base40_decode(encoded);
            assert_eq!(&decoded, name, "base40 roundtrip failed for '{name}'");
        }
    }

    #[test]
    fn test_base40_empty_string() {
        assert_eq!(base40_encode("").unwrap(), 0);
        assert_eq!(base40_decode(0), "");
    }

    #[test]
    fn test_base40_max_length() {
        let name = "zzzzzzzzzzzz"; // 12 z's
        let encoded = base40_encode(name).unwrap();
        let decoded = base40_decode(encoded);
        assert_eq!(&decoded, name);
    }

    #[test]
    fn test_base40_too_long() {
        let name = "1234567890123"; // 13 chars
        assert!(base40_encode(name).is_err());
    }

    /// M0 — `LocalFileSource` returns byte-identical block bytes to the
    /// in-memory/index path for every block of a fixture container.
    ///
    /// Builds a fixture container with several files (including one that spans
    /// many blocks so multi-level mapping is exercised), then for every data
    /// block of every file compares the bytes resolved+read through a
    /// `LocalFileSource`-backed reader against the bytes resolved+read through
    /// the in-memory whole-file reader.  A mis-routed block (wrong offset, off
    /// by a block, truncated read) would surface as a byte mismatch here.
    #[test]
    fn test_blocksource_localfile_reads_blocks() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("blocksource.ct");

        // A small file, a multi-block file, and a multi-level (>511 blocks)
        // file so the LocalFileSource is exercised across the whole mapping
        // hierarchy, not just direct level-1 pointers.
        const BLOCK_SIZE: usize = 4096;
        let small = b"small file contents".to_vec();
        let multi: Vec<u8> = (0..(BLOCK_SIZE * 3 + 7)).map(|i| (i % 256) as u8).collect();
        let multilevel: Vec<u8> = (0..(BLOCK_SIZE * 600))
            .map(|i| ((i.wrapping_mul(31).wrapping_add(17)) % 251) as u8)
            .collect();

        write_minimal_ctfs(
            &path,
            &[
                ("small.bin", small.as_slice()),
                ("multi.bin", multi.as_slice()),
                ("multilvl.bin", multilevel.as_slice()),
            ],
        )
        .unwrap();

        // Whole-file (default, InMemoryBlockSource) reader: the reference.
        let mut in_mem = CtfsReader::open(&path).unwrap();
        // Positional (LocalFileSource, pread) reader: the path under test.
        let mut local = CtfsReader::open_local_file(&path).unwrap();

        // The directory parse must agree exactly.
        let mut names_mem = in_mem.file_names();
        let mut names_local = local.file_names();
        names_mem.sort_unstable();
        names_local.sort_unstable();
        assert_eq!(names_mem, names_local, "file directory differs between sources");

        for (name, expected) in [
            ("small.bin", &small),
            ("multi.bin", &multi),
            ("multilvl.bin", &multilevel),
        ] {
            let via_mem = in_mem.read_file(name).unwrap();
            let via_local = local.read_file(name).unwrap();
            assert_eq!(&via_mem, expected, "in-memory read of '{name}' is wrong");
            assert_eq!(
                via_local, via_mem,
                "LocalFileSource read of '{name}' differs from in-memory read"
            );

            // Per-block comparison directly through the BlockSource, so a
            // single misrouted block is pinpointed rather than hidden inside a
            // whole-file equality.
            let entry = in_mem.files.get(name).unwrap().clone();
            let num_blocks = (entry.size as usize).div_ceil(BLOCK_SIZE);
            for block_index in 0..num_blocks {
                let phys = in_mem.data_block_for_test(name, block_index).unwrap();
                let phys_local = local.data_block_for_test(name, block_index).unwrap();
                assert_eq!(phys, phys_local, "block {block_index} of '{name}' resolved differently");

                let offset = phys * BLOCK_SIZE as u64;
                let to_read = (entry.size as usize - block_index * BLOCK_SIZE).min(BLOCK_SIZE);
                let mut mem_block = vec![0u8; to_read];
                let mut local_block = vec![0u8; to_read];
                read_exact_at(in_mem.source.as_ref(), offset, &mut mem_block, "mem block").unwrap();
                read_exact_at(local.source.as_ref(), offset, &mut local_block, "local block").unwrap();
                assert_eq!(
                    local_block, mem_block,
                    "block {block_index} of '{name}': LocalFileSource bytes differ from in-memory bytes"
                );
            }
        }

        // current_size() agrees with the on-disk length.
        let on_disk = std::fs::metadata(&path).unwrap().len();
        assert_eq!(local.source.current_size(), on_disk);
        assert_eq!(in_mem.source.current_size(), on_disk);
    }

    /// M0 — opening a fixture container through the (default InMemory-backed)
    /// `CtfsReader` yields the same file/block contents as a freshly-read
    /// whole-file image.  This pins that routing reads through the
    /// `BlockSource` seam did not change the bytes the reader returns.
    #[test]
    fn test_ctfs_reader_unchanged_via_blocksource() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("unchanged.ct");

        let file_a = b"alpha contents".to_vec();
        let file_b: Vec<u8> = (0..9000u32).map(|i| (i % 256) as u8).collect();
        write_minimal_ctfs(&path, &[("file.a", file_a.as_slice()), ("file.b", file_b.as_slice())]).unwrap();

        // Reference bytes: the raw container image read directly off disk.
        let raw = std::fs::read(&path).unwrap();

        let mut reader = CtfsReader::open(&path).unwrap();
        assert!(reader.has_file("file.a"));
        assert!(reader.has_file("file.b"));
        assert_eq!(reader.read_file("file.a").unwrap(), file_a);
        assert_eq!(reader.read_file("file.b").unwrap(), file_b);

        // The default source is the in-memory whole-file image, byte-identical
        // to the raw file: read the entire container back through the seam.
        let mut whole = vec![0u8; raw.len()];
        read_exact_at(reader.source.as_ref(), 0, &mut whole, "whole container").unwrap();
        assert_eq!(whole, raw, "InMemoryBlockSource image differs from on-disk bytes");

        // A read past the end must be a Corrupt error, not a panic — the seam
        // preserves the historical bounds behaviour.
        let mut overflow = [0u8; 8];
        let err = read_exact_at(reader.source.as_ref(), raw.len() as u64, &mut overflow, "past end");
        assert!(matches!(err, Err(CtfsError::Corrupt(_))));
    }

    /// M1 — `FollowFileSource.refresh()` makes appended bytes / an increased
    /// `FileEntry.Size` visible, and the new bytes are NOT visible before the
    /// refresh.
    ///
    /// Models the recorder growth protocol directly: a base container is written
    /// with one file at its initial size, then — simulating a chunk flush — extra
    /// bytes are appended to that file's data block and the file's
    /// `FileEntry.Size` in Block 0 is bumped to cover them. A `FollowFileSource`
    /// opened over the file BEFORE the bump must still report the old size; only
    /// after `refresh()` does it observe the grown `FileEntry.Size`, the larger
    /// raw `current_size`, and successfully read the appended bytes.
    #[test]
    fn test_followfilesource_observes_growth() {
        use std::io::{Seek, SeekFrom, Write};

        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("growing.ct");

        // Base container: one file "steps.dat" with 100 bytes (one data block,
        // tagged direct). `write_minimal_ctfs` lays down a valid CTFS v5 image.
        let initial: Vec<u8> = (0..100u32).map(|i| (i % 256) as u8).collect();
        write_minimal_ctfs(&path, &[("steps.dat", initial.as_slice())]).unwrap();

        // Open the follow source BEFORE any growth.
        let mut follow = FollowFileSource::open(&path).unwrap();
        assert_eq!(follow.file_size("steps.dat"), Some(100), "initial FileEntry.Size");
        assert!(!follow.is_finalized(), "no meta.dat ⇒ not finalized");
        let size_before = follow.current_size();

        // ── Simulate a chunk flush that grows "steps.dat" by 50 bytes IN PLACE.
        //    Rather than re-derive the physical offset of "steps.dat"'s single
        //    data block, we locate it through a throwaway reader, then append
        //    into that block (the block is 4096 bytes, so 150 bytes still fit in
        //    block 0 of the file).
        let appended: Vec<u8> = (0..50u32).map(|i| (200 + i % 50) as u8).collect();
        let (data_block_offset, entry_offset, block_size) = {
            let reader = CtfsReader::open(&path).unwrap();
            let block_size = reader.block_size as u64;
            // Physical offset of the file's first (only) data block.
            let data_block = reader.data_block_for_test("steps.dat", 0).unwrap();
            // Byte offset of "steps.dat"'s FileEntry.Size field in Block 0.
            // Files are laid out in insertion order from the entry array start;
            // "steps.dat" is the sole entry ⇒ index 0.
            let entry_offset = (HEADER_SIZE + EXTENDED_HEADER_SIZE) as u64;
            (data_block * block_size, entry_offset, block_size)
        };
        assert!(150 <= block_size, "fixture must fit in one block");

        {
            let mut f = std::fs::OpenOptions::new().read(true).write(true).open(&path).unwrap();
            // Append the new bytes after the initial 100 bytes of the data block.
            f.seek(SeekFrom::Start(data_block_offset + 100)).unwrap();
            f.write_all(&appended).unwrap();
            // Bump FileEntry.Size 100 → 150.
            f.seek(SeekFrom::Start(entry_offset)).unwrap();
            f.write_all(&150u64.to_le_bytes()).unwrap();
            f.flush().unwrap();
        }

        // BEFORE refresh: the follow source must still report the OLD size — it
        // only re-observes Block 0 on an explicit refresh.
        assert_eq!(
            follow.file_size("steps.dat"),
            Some(100),
            "appended bytes must NOT be visible before refresh()"
        );
        assert_eq!(
            follow.current_size(),
            size_before,
            "raw size unchanged before refresh()"
        );

        // AFTER refresh: the grown FileEntry.Size and the larger raw size are
        // visible, and the appended bytes read back correctly.
        follow.refresh().unwrap();
        assert_eq!(
            follow.file_size("steps.dat"),
            Some(150),
            "refresh() must observe the grown FileEntry.Size"
        );
        assert!(
            follow.current_size() >= data_block_offset + 150,
            "raw size covers appended bytes"
        );

        let mut buf = vec![0u8; 50];
        follow.read_at(data_block_offset + 100, &mut buf).unwrap();
        assert_eq!(buf, appended, "appended bytes read back through the follow source");
    }

    /// M1 — `FollowFileSource.is_finalized()` flips to `true` once a non-empty
    /// `meta.dat` is observed on `refresh()`, and not before.
    #[test]
    fn test_followfilesource_finalization_signal() {
        use std::io::{Seek, SeekFrom, Write};

        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("seal.ct");

        // Two entries: a data file and a placeholder meta.dat at size 0.
        write_minimal_ctfs(&path, &[("steps.dat", b"abc"), ("meta.dat", &[])]).unwrap();

        let mut follow = FollowFileSource::open(&path).unwrap();
        assert!(!follow.is_finalized(), "meta.dat size 0 ⇒ not finalized");

        // Bump meta.dat's FileEntry.Size to a non-zero value (its entry is the
        // SECOND in insertion order). We do not need real meta bytes — the
        // finalization signal is "FileEntry.Size > 0".
        let entry_offset = (HEADER_SIZE + EXTENDED_HEADER_SIZE + FILE_ENTRY_SIZE) as u64;
        {
            let mut f = std::fs::OpenOptions::new().read(true).write(true).open(&path).unwrap();
            f.seek(SeekFrom::Start(entry_offset)).unwrap();
            f.write_all(&42u64.to_le_bytes()).unwrap();
            f.flush().unwrap();
        }

        assert!(!follow.is_finalized(), "still not finalized before refresh()");
        follow.refresh().unwrap();
        assert!(follow.is_finalized(), "non-empty meta.dat ⇒ finalized after refresh()");
    }

    #[test]
    fn test_write_and_read_minimal_ctfs() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("test.ct");

        let content = b"hello, CTFS!";
        write_minimal_ctfs(&path, &[("test.file", content)]).unwrap();

        let mut reader = CtfsReader::open(&path).unwrap();
        assert!(reader.has_file("test.file"));

        let read_back = reader.read_file("test.file").unwrap();
        assert_eq!(&read_back, content);
    }

    #[test]
    fn test_read_multiple_files() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("multi.ct");

        let file_a = b"first file content";
        let file_b = b"second file with different data";
        write_minimal_ctfs(&path, &[("file.a", file_a.as_slice()), ("file.b", file_b.as_slice())]).unwrap();

        let mut reader = CtfsReader::open(&path).unwrap();
        assert_eq!(reader.read_file("file.a").unwrap(), file_a);
        assert_eq!(reader.read_file("file.b").unwrap(), file_b);
    }

    #[test]
    fn test_read_empty_file() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("empty.ct");

        write_minimal_ctfs(&path, &[("empty.file", &[])]).unwrap();

        let mut reader = CtfsReader::open(&path).unwrap();
        assert!(reader.has_file("empty.file"));
        assert_eq!(reader.read_file("empty.file").unwrap(), Vec::<u8>::new());
    }

    #[test]
    fn test_file_not_found() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("nope.ct");

        write_minimal_ctfs(&path, &[("exists", b"data")]).unwrap();

        let mut reader = CtfsReader::open(&path).unwrap();
        assert!(!reader.has_file("nope"));
        assert!(matches!(reader.read_file("nope"), Err(CtfsError::FileNotFound(_))));
    }

    #[test]
    fn test_invalid_magic() {
        let data = vec![0xFF; 1024];
        assert!(matches!(CtfsReader::from_bytes(data), Err(CtfsError::InvalidMagic)));
    }

    #[test]
    fn test_file_larger_than_one_block() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("big.ct");

        // Create data larger than one 4096-byte block
        let big_data: Vec<u8> = (0..10000).map(|i| (i % 256) as u8).collect();
        write_minimal_ctfs(&path, &[("big.file", &big_data)]).unwrap();

        let mut reader = CtfsReader::open(&path).unwrap();
        let read_back = reader.read_file("big.file").unwrap();
        assert_eq!(read_back.len(), big_data.len());
        assert_eq!(read_back, big_data);
    }

    #[test]
    fn test_base40_all_chars() {
        // Verify each individual character roundtrips correctly
        let charset = "0123456789abcdefghijklmnopqrstuvwxyz./-";
        for ch in charset.chars() {
            let s = ch.to_string();
            let encoded = base40_encode(&s).unwrap();
            let decoded = base40_decode(encoded);
            assert_eq!(decoded, s, "base40 roundtrip failed for char '{ch}'");
        }
    }

    /// Regression test for **M-CTFS-LargeFile**.
    ///
    /// At the default 4096-byte block size, `entries_per_block = 512` and
    /// the level-1 mapping block holds `usable = 511` direct data block
    /// pointers.  The 512th data block of a file (logical index 511) is
    /// the first one that requires the writer to allocate a level-2 chain
    /// block + a level-1 child block and to populate the data block
    /// pointer through two layers of indirection.  Files with more data
    /// blocks fan further into the chain.
    ///
    /// This test writes a multi-block file (>511 blocks) using the
    /// test-only multi-level chain writer, then reads it back through
    /// `CtfsReader::read_file` and asserts a byte-for-byte round-trip.
    /// Before the M-CTFS-LargeFile fix the Nim production writer in
    /// streaming mode left the level-1 child block on disk as zeros, and
    /// `read_file` surfaced the corruption as
    /// `unallocated block at index 511`.  Although this Rust test does not
    /// drive the streaming writer directly, it exercises the same multi-
    /// level mapping path that the reader must traverse, guarding against
    /// any future regression in the reader's `resolve_block` /
    /// `resolve_multilevel` traversal logic.
    #[test]
    fn test_file_spans_multi_level_mapping() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("multi_level.ct");

        // 600 blocks × 4096 bytes ≈ 2.4 MB — comfortably past the
        // usable=511 level-1 boundary so the writer has to use the
        // multi-level chain.
        const BLOCK_SIZE: usize = 4096;
        const NUM_BLOCKS: usize = 600;
        let total = NUM_BLOCKS * BLOCK_SIZE;
        let mut big: Vec<u8> = Vec::with_capacity(total);
        for i in 0..total {
            // Non-trivial pattern so a single zeroed block in the middle
            // would be caught by byte-for-byte comparison.
            big.push(((i.wrapping_mul(31).wrapping_add(17)) % 251) as u8);
        }

        write_minimal_ctfs(&path, &[("big.file", &big)]).unwrap();

        let mut reader = CtfsReader::open(&path).unwrap();
        let read_back = reader.read_file("big.file").unwrap();
        assert_eq!(read_back.len(), big.len(), "size mismatch");
        // Compare in chunks to keep assert output readable on failure.
        for block_index in 0..NUM_BLOCKS {
            let start = block_index * BLOCK_SIZE;
            let end = start + BLOCK_SIZE;
            assert_eq!(
                &read_back[start..end],
                &big[start..end],
                "byte mismatch in block {block_index}"
            );
        }
    }
    /// `CTFS-Binary-Format.md` §5d's bound on the DATA-block path.
    ///
    /// A container is cut so one stream's last, short data block becomes the
    /// first *partial* block, with exactly its own bytes present — so the read
    /// the strict path would issue is fully satisfiable out of bytes the
    /// container does not own. Before the bound, `read_file` returned all
    /// 12 388 bytes and reported success, while the workspace's other two
    /// readers of this format refused the same stream by name. Measured on the
    /// same file, produced by the Nim writer.
    ///
    /// Delete the `whole_blocks_only` check in `read_range_inner` and this goes
    /// red.
    #[test]
    fn test_strict_read_refuses_a_data_block_in_the_partial_region() {
        const BS: usize = 4096;
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("cut.ct");

        let survivor: Vec<u8> = (0..9000u32).map(|i| (i % 251) as u8).collect();
        // A size whose last data block carries only 100 bytes.
        let lost: Vec<u8> = (0..(3 * BS + 100) as u32).map(|i| ((i + 7) % 251) as u8).collect();
        // `z.dat` is written last, so its blocks sit at the end of the image
        // and cutting there cannot also damage `meta.dat`.
        write_minimal_ctfs(&path, &[("meta.dat", &survivor), ("z.dat", &lost)]).unwrap();

        let full = std::fs::read(&path).unwrap();
        assert_eq!(full.len() % BS, 0, "the fixture is not block-aligned to begin with");
        let cut = full.len() - BS + 100;
        std::fs::write(&path, &full[..cut]).unwrap();

        let mut r = CtfsReader::open(&path).unwrap();

        // The survivor is untouched: the bound costs the container only what it
        // actually lost, which is the point of bounding rather than refusing
        // the whole file at `open`.
        assert_eq!(
            r.read_file("meta.dat").unwrap(),
            survivor,
            "a truncation that lost z.dat also cost meta.dat"
        );

        // `assert!` rather than a `match` arm that panics: `clippy::panic` is
        // denied repo-wide (`cargo clippy --all-targets -- -D warnings` in CI),
        // and it does not distinguish a test's deliberate abort from a
        // production one.
        let got = r.read_file("z.dat");
        assert!(
            got.is_err(),
            "read_file returned {} bytes with no error for a stream whose last data \
             block lies outside the container's whole blocks; the partial region was \
             served as content",
            got.as_ref().map(Vec::len).unwrap_or(0)
        );
        let msg = got.unwrap_err().to_string();
        assert!(
            msg.contains("truncated") && msg.contains("whole"),
            "the refusal does not name the truncation: {msg}"
        );

        // The TOLERANT reader keeps its designed byte-granular behaviour: it
        // reports the landed prefix rather than refusing, and never claims the
        // range is complete. Bounding that one at block granularity would throw
        // away a partly-landed block, which RS-M3's remote tail depends on.
        let prefix = r.read_file_range_available("z.dat", 0, lost.len() as u64).unwrap();
        assert_eq!(
            prefix.len(),
            lost.len(),
            "the tolerant reader must still return every byte that is physically present"
        );
    }

    /// §5d's bound on the MAPPING-block paths, which the data-block bound
    /// left out.
    ///
    /// §5d recorded this reader as applying "the same bound in two of three
    /// places": the data block was bounded, the mapping root and the mapping
    /// blocks walked were not, because `read_mapping_entry` only checks that
    /// the 8 bytes it wants are inside `current_size()`. On this fixture that
    /// meant the strict reader gave a raw `... is out of bounds` for a mapping
    /// entry, where the Nim and Go readers name the stream and say the container
    /// is truncated — an agreement gap, and the same shape of omission that let
    /// the data-block gap survive the first sweep.
    ///
    /// The container is cut exactly at `b.dat`'s mapping root, so it is the
    /// first block outside the whole blocks while everything `a.dat` needs
    /// survives. Delete the `check_block_in_whole_blocks` call on the mapping
    /// root in `resolve_block` and this goes red.
    #[test]
    fn test_strict_read_refuses_a_mapping_root_in_the_partial_region() {
        const BS: usize = 4096;
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("map.ct");

        // `a.dat` is an exact multiple of the block size and is written first,
        // so `b.dat`'s mapping root is allocated above every block `a.dat` uses.
        // `b.dat` is larger than one block, so it has a mapping root at all; a
        // member of one block is stored direct, without one.
        let a: Vec<u8> = (0..(3 * BS) as u32).map(|i| (i % 251) as u8).collect();
        let b: Vec<u8> = (0..(BS + 100) as u32).map(|i| ((i + 3) % 251) as u8).collect();
        write_minimal_ctfs(&path, &[("a.dat", &a), ("b.dat", &b)]).unwrap();

        let full = std::fs::read(&path).unwrap();
        assert_eq!(full.len() % BS, 0, "the fixture is not block-aligned to begin with");

        // Read `b.dat`'s mapping root straight out of block 0's entry array, so
        // the cut point comes from the bytes rather than from the reader.
        let entry_off = HEADER_SIZE + EXTENDED_HEADER_SIZE + FILE_ENTRY_SIZE; // second entry
        let map_bytes: [u8; 8] = match full[entry_off + 8..entry_off + 16].try_into() {
            Ok(x) => x,
            Err(_) => unreachable!("file entry map_block field is always 8 bytes"),
        };
        let b_map = u64::from_le_bytes(map_bytes);
        assert!(
            b_map > 0 && (b_map as usize) * BS < full.len(),
            "the fixture did not place b.dat's mapping root inside the {}-byte container (it is {b_map})",
            full.len()
        );
        std::fs::write(&path, &full[..(b_map as usize) * BS]).unwrap();

        let mut r = CtfsReader::open(&path).unwrap();

        // The cut costs the container only b.dat.
        assert_eq!(
            r.read_file("a.dat").unwrap(),
            a,
            "a truncation at b.dat's mapping root also cost a.dat"
        );

        let got = r.read_file("b.dat");
        assert!(
            got.is_err(),
            "read_file returned {} bytes with no error for a stream whose mapping root lies \
             outside the container's whole blocks",
            got.as_ref().map(Vec::len).unwrap_or(0)
        );
        let msg = got.unwrap_err().to_string();
        assert!(
            msg.contains("mapping root") && msg.contains("truncated") && msg.contains("whole"),
            "the refusal does not name the mapping root and the truncation the way the Nim and \
             Go readers do: {msg}"
        );
        assert!(
            msg.contains("b.dat"),
            "the refusal does not name the lost stream: {msg}"
        );
    }

    // ── Container version 5 (ctfs-container.md §1, §2, §4) ───────────────

    const BIT63: u64 = 1 << 63;

    /// A raw version 5 container of `blocks` 4096-byte blocks with the given
    /// `(slot, name, size, map_block)` directory entries; every other byte is
    /// zero, so a test writes the blocks it needs into the returned image.
    fn raw_v5(blocks: usize, max_root_entries: u32, entries: &[(usize, &str, u64, u64)]) -> Vec<u8> {
        let mut buf = vec![0u8; blocks * 4096];
        buf[0..5].copy_from_slice(&CTFS_MAGIC);
        buf[5] = 5;
        buf[8..12].copy_from_slice(&4096u32.to_le_bytes());
        buf[12..16].copy_from_slice(&max_root_entries.to_le_bytes());
        for &(slot, name, size, map_block) in entries {
            let off = 16 + slot * 24;
            buf[off..off + 8].copy_from_slice(&size.to_le_bytes());
            buf[off + 8..off + 16].copy_from_slice(&map_block.to_le_bytes());
            buf[off + 16..off + 24].copy_from_slice(&base40_encode(name).unwrap().to_le_bytes());
        }
        buf
    }

    fn put_u64(buf: &mut [u8], block: usize, slot: usize, value: u64) {
        let off = block * 4096 + slot * 8;
        buf[off..off + 8].copy_from_slice(&value.to_le_bytes());
    }

    fn entry_fields(raw: &[u8], slot: usize) -> (u64, u64) {
        let off = 16 + slot * 24;
        let size = u64::from_le_bytes(raw[off..off + 8].try_into().unwrap());
        let map_block = u64::from_le_bytes(raw[off + 8..off + 16].try_into().unwrap());
        (size, map_block)
    }

    /// A container whose version byte is not 5 is refused by every open path,
    /// and the refusal names the version it found and the one it reads.
    #[test]
    fn a_container_of_another_version_is_refused_by_name() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("old.ct");
        write_minimal_ctfs(&path, &[("meta.dat", b"x")]).unwrap();
        let mut raw = std::fs::read(&path).unwrap();
        for version in [2u8, 3, 4, 7] {
            raw[5] = version;
            std::fs::write(&path, &raw).unwrap();
            let err = CtfsReader::from_bytes(raw.clone()).unwrap_err();
            assert!(
                matches!(err, CtfsError::UnsupportedVersion(v) if v == version),
                "version {version} was not refused as an unsupported version: {err}"
            );
            let msg = err.to_string();
            assert!(
                msg.contains(&format!("version {version}")) && msg.contains('5'),
                "the refusal does not name both versions: {msg}"
            );
            let follow = FollowFileSource::open(&path);
            assert!(
                matches!(follow, Err(CtfsError::UnsupportedVersion(v)) if v == version),
                "the follow source opened a version {version} container"
            );
        }
    }

    /// The test writer lays members out as a version 5 writer must: an empty
    /// member owns no block, a member of at most one block is a tagged direct
    /// block with no mapping block, and a larger one is mapped.
    #[test]
    fn the_test_writer_writes_version_5_layouts() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("layouts.ct");
        let small: Vec<u8> = (0..100u32).map(|i| i as u8).collect();
        let full: Vec<u8> = (0..4096u32).map(|i| (i % 251) as u8).collect();
        let big: Vec<u8> = (0..4097u32).map(|i| (i % 249) as u8).collect();
        write_minimal_ctfs(
            &path,
            &[("small", &small), ("empty", &[]), ("full", &full), ("big", &big)],
        )
        .unwrap();
        let raw = std::fs::read(&path).unwrap();
        assert_eq!(raw[5], 5, "the test writer must write container version 5");

        let (size, map) = entry_fields(&raw, 0);
        assert_eq!(size, 100);
        assert_ne!(map & BIT63, 0, "a one-block member must carry the direct tag");
        let b = (map & !BIT63) as usize;
        assert_eq!(&raw[b * 4096..b * 4096 + 100], small.as_slice());

        assert_eq!(entry_fields(&raw, 1), (0, 0), "an empty member owns no block");

        let (size, map) = entry_fields(&raw, 2);
        assert_eq!(size, 4096);
        assert_ne!(map & BIT63, 0, "a member of exactly one block is direct");

        let (size, map) = entry_fields(&raw, 3);
        assert_eq!(size, 4097);
        assert_eq!(map & BIT63, 0, "a member past one block is mapped");

        // Block 0, small, full, and big's mapping block plus two data blocks.
        assert_eq!(
            raw.len(),
            6 * 4096,
            "a small or empty member must not own a mapping block"
        );

        let mut r = CtfsReader::from_bytes(raw).unwrap();
        assert_eq!(r.read_file("small").unwrap(), small);
        assert_eq!(r.read_file("empty").unwrap(), Vec::<u8>::new());
        assert_eq!(r.read_file("full").unwrap(), full);
        assert_eq!(r.read_file("big").unwrap(), big);
    }

    /// A tagged `MapBlock` names the member's only data block, and is read
    /// without reading a mapping block.
    #[test]
    fn a_direct_member_is_read_from_its_tagged_block() {
        let mut raw = raw_v5(2, 31, &[(0, "x.dat", 5, BIT63 | 1)]);
        raw[4096..4101].copy_from_slice(b"hello");
        let mut r = CtfsReader::from_bytes(raw).unwrap();
        assert_eq!(r.read_file("x.dat").unwrap(), b"hello");
        assert_eq!(r.read_file_range("x.dat", 1, 3).unwrap(), b"ell");
        assert_eq!(r.read_file_range_available("x.dat", 2, 3).unwrap(), b"llo");
    }

    /// An untagged `MapBlock` is a mapping whatever `Size` says: a live reader
    /// can observe a member between the two stores of its direct-to-mapped
    /// transition, with the old size and the new mapping.
    #[test]
    fn a_mapped_member_of_one_block_is_read_through_its_mapping() {
        let mut raw = raw_v5(3, 31, &[(0, "x.dat", 5, 1)]);
        put_u64(&mut raw, 1, 0, 2);
        raw[2 * 4096..2 * 4096 + 5].copy_from_slice(b"hello");
        let mut r = CtfsReader::from_bytes(raw).unwrap();
        assert_eq!(r.read_file("x.dat").unwrap(), b"hello");
    }

    /// One block cannot hold more than `BlockSize` bytes, so a tagged member
    /// claiming more is refused rather than read past its block.
    #[test]
    fn a_direct_member_larger_than_one_block_is_refused() {
        let raw = raw_v5(4, 31, &[(0, "x.dat", 5000, BIT63 | 1)]);
        let mut r = CtfsReader::from_bytes(raw).unwrap();
        let msg = r.read_file("x.dat").unwrap_err().to_string();
        assert!(
            msg.contains("x.dat") && msg.contains("5000") && msg.contains("one block"),
            "the refusal does not name the member and why: {msg}"
        );
    }

    fn assert_null_refusal(raw: Vec<u8>, what: &str) {
        let mut r = CtfsReader::from_bytes(raw).unwrap();
        assert!(
            r.has_file("x.dat"),
            "{what}: a member with a null pointer is still present"
        );
        let err = r.read_file("x.dat").unwrap_err();
        assert!(
            matches!(err, CtfsError::Corrupt(_)),
            "{what}: a null pointer must be refused as damage, not reported as {err:?}"
        );
        let msg = err.to_string();
        assert!(
            msg.contains("x.dat") && msg.contains("null"),
            "{what}: the refusal does not name the member and the null pointer: {msg}"
        );
        assert!(
            !msg.contains("truncat"),
            "{what}: a null pointer is not a truncation, and the refusal must not say it is: {msg}"
        );
    }

    /// `ctfs-container.md` §4 "Null block pointers on the read path", for each
    /// place a null can sit in a version 5 container.
    #[test]
    fn a_null_block_pointer_is_refused_by_name_and_not_as_a_truncation() {
        assert_null_refusal(raw_v5(2, 31, &[(0, "x.dat", 10, 0)]), "MapBlock 0 with a size");
        assert_null_refusal(raw_v5(2, 31, &[(0, "x.dat", 10, BIT63)]), "a tagged block 0");
        assert_null_refusal(raw_v5(2, 31, &[(0, "x.dat", 10, 1)]), "a null data pointer");
        let mut raw = raw_v5(3, 31, &[(0, "x.dat", 600 * 4096, 1)]);
        put_u64(&mut raw, 1, 511, 0);
        for slot in 0..511 {
            put_u64(&mut raw, 1, slot, 2);
        }
        let mut r = CtfsReader::from_bytes(raw).unwrap();
        let msg = r.read_file_range("x.dat", 511 * 4096, 10).unwrap_err().to_string();
        assert!(
            msg.contains("x.dat") && msg.contains("null") && !msg.contains("truncat"),
            "a null chain pointer: {msg}"
        );
    }

    /// An empty member, written as `(0, 0)`, reads as empty and is present.
    #[test]
    fn an_empty_member_is_present_and_empty() {
        let raw = raw_v5(1, 31, &[(0, "x.dat", 0, 0)]);
        let mut r = CtfsReader::from_bytes(raw).unwrap();
        assert!(r.has_file("x.dat"));
        assert_eq!(r.read_file("x.dat").unwrap(), Vec::<u8>::new());
    }

    /// A block number out of the container is refused before it is multiplied
    /// by the block size, on the strict and the tolerant path alike.
    #[test]
    fn a_block_number_past_any_offset_is_refused_without_overflowing() {
        let huge = 1u64 << 60;
        for map_block in [huge, BIT63 | huge] {
            let raw = raw_v5(2, 31, &[(0, "x.dat", 10, map_block)]);
            let mut r = CtfsReader::from_bytes(raw).unwrap();
            assert!(r.read_file("x.dat").is_err(), "MapBlock {map_block:#x} was read");
            assert!(
                r.read_file_range_available("x.dat", 0, 10).is_err(),
                "MapBlock {map_block:#x} was read by the tolerant path"
            );
        }
        let mut raw = raw_v5(2, 31, &[(0, "x.dat", 10, 1)]);
        put_u64(&mut raw, 1, 0, huge);
        let mut r = CtfsReader::from_bytes(raw).unwrap();
        assert!(r.read_file("x.dat").is_err());
        assert!(r.read_file_range_available("x.dat", 0, 10).is_err());
    }

    /// `MaxRootEntries = 0` fills block 0 with entries (`ctfs-container.md`
    /// §1, "Auto-fill").
    #[test]
    fn an_auto_filled_root_directory_is_read_to_the_end_of_block_0() {
        let last = (4096 - 16) / 24 - 1;
        let mut raw = raw_v5(2, 0, &[(last, "x.dat", 3, BIT63 | 1)]);
        raw[4096..4099].copy_from_slice(b"abc");
        let mut r = CtfsReader::from_bytes(raw).unwrap();
        assert_eq!(r.read_file("x.dat").unwrap(), b"abc");
    }

    // ── Container version 6 (ctfs-container.md §1a-§1c) ──────────────────

    /// A version 6 container: version 5's body behind a 24-byte header, so the
    /// entry array starts at 24.
    fn raw_v6(
        blocks: usize,
        profile: u8,
        compression: u8,
        reserved: u8,
        entries: &[(usize, &str, u64, u64)],
    ) -> Vec<u8> {
        let mut buf = vec![0u8; blocks * 4096];
        buf[0..5].copy_from_slice(&CTFS_MAGIC);
        buf[5] = 6;
        buf[8..12].copy_from_slice(&4096u32.to_le_bytes());
        buf[12..16].copy_from_slice(&31u32.to_le_bytes());
        buf[16] = profile;
        buf[17] = compression;
        buf[23] = reserved;
        for &(slot, name, size, map_block) in entries {
            let off = 24 + slot * 24;
            buf[off..off + 8].copy_from_slice(&size.to_le_bytes());
            buf[off + 8..off + 16].copy_from_slice(&map_block.to_le_bytes());
            buf[off + 16..off + 24].copy_from_slice(&base40_encode(name).unwrap().to_le_bytes());
        }
        buf
    }

    #[test]
    fn a_version_6_full_container_without_compression_is_read() {
        let mut raw = raw_v6(2, 0, 0, 0, &[(0, "x.dat", 5, BIT63 | 1)]);
        raw[4096..4101].copy_from_slice(b"hello");
        let mut r = CtfsReader::from_bytes(raw.clone()).unwrap();
        assert_eq!(r.read_file("x.dat").unwrap(), b"hello");

        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("v6.ct");
        std::fs::write(&path, &raw).unwrap();
        let follow = FollowFileSource::open(&path).unwrap();
        assert_eq!(
            follow.file_size("x.dat"),
            Some(5),
            "the follow source reads entries at 24"
        );
    }

    #[test]
    fn a_version_6_field_this_reader_does_not_implement_is_refused_by_value() {
        for (profile, compression, reserved, what) in [
            (7u8, 0u8, 0u8, "profile 7"),
            (0, 1, 0, "compression 1"),
            (0, 9, 0, "compression 9"),
            (0, 0, 3, "reserved"),
        ] {
            let raw = raw_v6(2, profile, compression, reserved, &[]);
            let err = CtfsReader::from_bytes(raw.clone()).unwrap_err().to_string();
            assert!(err.contains(what), "{what}: the refusal does not name the value: {err}");
            let dir = tempfile::tempdir().unwrap();
            let path = dir.path().join("v6.ct");
            std::fs::write(&path, &raw).unwrap();
            assert!(
                FollowFileSource::open(&path).is_err(),
                "{what}: the follow source opened it"
            );
        }
    }

    #[test]
    fn a_version_6_header_too_short_for_its_fields_is_refused() {
        let raw = raw_v6(1, 0, 0, 0, &[]);
        assert!(CtfsReader::from_bytes(raw[..20].to_vec()).is_err());
    }
}

// ── Compact-profile unit tests ──────────────────────────────────────────
//
// These exercise the §1d loader at the BYTE level: the header MUSTs, the six
// directory checks, the residency gate, and the read path. They are unit tests
// rather than integration ones because what they assert is a verdict about
// bytes, and reaching that verdict through a whole trace reader would make a
// refusal indistinguishable from any other way a trace can fail to open.
#[cfg(test)]
#[allow(clippy::unwrap_used, clippy::expect_used)]
mod compact_profile_tests {
    use super::*;

    /// The twenty-one member names of the container this campaign was opened on.
    ///
    /// Round-tripped BY NAME rather than through a generated alphabet, because
    /// the base40 table is off-by-one-able in a way that still reports success:
    /// index 1 is `'0'` and not `'\0'`, and there is no space character, so a
    /// shifted table decodes `meta.dat` into something else entirely.
    const MEASURED_MEMBER_NAMES: [&str; 21] = [
        "events.log",
        "events.fmt",
        "meta.json",
        "paths.json",
        "calls.dat",
        "calls.idx",
        "steps.dat",
        "steps.idx",
        "values.dat",
        "values.idx",
        "events.dat",
        "events.idx",
        "paths.dat",
        "paths.off",
        "funcs.dat",
        "funcs.off",
        "types.dat",
        "types.off",
        "varnames.dat",
        "varnames.off",
        "meta.dat",
    ];

    fn compact_reader(image: Vec<u8>) -> Result<CtfsReader, CtfsError> {
        CtfsReader::from_bytes(image)
    }

    /// Pack `name` the way the SIBLING NIM ENCODER packs it: an
    /// out-of-alphabet character maps to the PADDING index rather than being
    /// refused.
    ///
    /// This exists because of a divergence measured while writing these tests,
    /// and it is worth stating: `base40_encode` in THIS module REFUSES an
    /// out-of-alphabet character by name and position, while
    /// `codetracer-trace-format-nim`'s `base40Encode` silently maps it to index
    /// 0. Both are safe writers; the Rust one is the stricter. But a READER
    /// must still refuse the resulting word, because the word can arrive from
    /// anywhere — a different writer, a corrupted byte — and this module's own
    /// encoder is not what produces the directories it reads. So the hazard is
    /// constructed here arithmetically rather than through the encoder, which
    /// is the only way to reach it at all.
    fn padding_mapped_word(name: &str) -> u64 {
        let mut encoded: u64 = 0;
        let mut multiplier: u64 = 1;
        for ch in name.bytes() {
            let idx = BASE40_CHARS.iter().position(|&c| c == ch).unwrap_or(0) as u64;
            encoded += idx * multiplier;
            multiplier *= 40;
        }
        encoded
    }

    #[test]
    fn the_known_member_names_pack_and_unpack() {
        for name in MEASURED_MEMBER_NAMES {
            // `assert!` + `unwrap`, not a panicking closure: this module's
            // sibling tests already record that `clippy::panic` is denied
            // repo-wide and does not distinguish a test's deliberate abort
            // from a production one.
            let packed = base40_encode(name);
            assert!(packed.is_ok(), "{name} does not encode: {:?}", packed.err());
            let encoded = packed.unwrap();
            assert_ne!(encoded, 0, "{name} encodes to the zero word no member may carry");
            assert_eq!(base40_decode(encoded), name, "{name} does not round-trip");
            assert!(name_is_well_formed(name), "{name} is rejected as malformed");
        }
        // The trap, pinned in the direction a round-trip cannot see: an
        // INTERIOR out-of-alphabet character decodes to a name with an embedded
        // NUL, which re-encodes to itself.
        assert!(
            base40_encode("meta dat").is_err(),
            "this module's encoder must REFUSE an out-of-alphabet character rather than pad it; \
             if it has started padding, padding_mapped_word's reason for existing is gone"
        );
        let with_space = padding_mapped_word("meta dat");
        let decoded = base40_decode(with_space);
        assert!(
            decoded.contains('\0'),
            "expected an embedded NUL from an interior out-of-alphabet character, got {decoded:?}"
        );
        assert_eq!(
            padding_mapped_word(&decoded),
            with_space,
            "the malformed word must re-encode to itself — which is exactly why the round-trip \
             alone is not the whole of §1d check 5"
        );
        assert!(
            !name_is_well_formed(&decoded),
            "the alphabet test is the half that catches it, and it did not"
        );
        // A TRAILING one does collide, which is the correction CCP-2 recorded.
        assert_eq!(
            padding_mapped_word("meta "),
            base40_encode("meta").unwrap(),
            "a trailing out-of-alphabet character is bit for bit the shorter name"
        );
    }

    #[test]
    fn a_compact_container_serves_every_member_byte_exactly() {
        let members: Vec<(&str, Vec<u8>)> = MEASURED_MEMBER_NAMES
            .iter()
            .enumerate()
            .map(|(i, name)| {
                // Deliberately NOT a multiple of any block size, and distinct
                // per member so a shifted read is visible.
                let len = 7 + i * 13;
                (
                    *name,
                    (0..len)
                        .map(|b| (b as u8).wrapping_add((i as u8).wrapping_mul(31)))
                        .collect(),
                )
            })
            .collect();
        let refs: Vec<(&str, &[u8])> = members.iter().map(|(n, d)| (*n, d.as_slice())).collect();
        let image = encode_compact_ctfs(&refs).unwrap();

        // §1d's size identity, recomputed from the members rather than from the
        // encoder's own arithmetic.
        let expected_len = 28 + 24 * members.len() + members.iter().map(|(_, d)| d.len()).sum::<usize>();
        assert_eq!(image.len(), expected_len, "§1d size identity");

        let mut reader = compact_reader(image).expect("the compact container opens");
        assert_eq!(reader.profile(), CtfsProfile::Compact);
        assert!(reader.is_compact());
        assert_eq!(
            reader.member_names_in_order(),
            MEASURED_MEMBER_NAMES.map(str::to_owned).as_slice(),
            "the directory order is not the order the encoder wrote"
        );
        for (name, data) in &members {
            assert_eq!(reader.file_size(name), Some(data.len() as u64), "{name} size");
            assert_eq!(&reader.read_file(name).unwrap(), data, "{name} payload");
            // A range read of the interior, which is the path a chunked stream
            // reader takes and the one block arithmetic would have broken.
            if data.len() > 4 {
                assert_eq!(
                    reader.read_file_range(name, 2, 3).unwrap(),
                    data[2..5].to_vec(),
                    "{name} interior range"
                );
            }
        }
        // At least one member must begin off a 4,096-byte boundary — a thing
        // the full profile cannot satisfy, since every full member begins at a
        // block.
        let mut offset = 28 + 24 * members.len();
        let mut off_boundary = 0;
        for (_, data) in &members {
            if !offset.is_multiple_of(4096) {
                off_boundary += 1;
            }
            offset += data.len();
        }
        assert!(off_boundary > 0, "no member begins off a 4 KiB boundary");
    }

    #[test]
    fn an_unknown_profile_is_refused_not_defaulted() {
        let mut image = encode_compact_ctfs(&[("meta.dat", b"x")]).unwrap();
        for byte in [2u8, 3, 7, 42, 255] {
            image[PROFILE_OFFSET] = byte;
            let err = compact_reader(image.clone()).expect_err("an unknown profile must be refused");
            let msg = err.to_string();
            assert!(
                msg.contains(&byte.to_string()) && msg.contains("profile"),
                "profile {byte} is not refused by name: {msg}"
            );
            assert!(
                matches!(err, CtfsError::Unimplemented(_)),
                "an unknown profile is a well-formed container this reader cannot serve, not a \
                 corrupt one: {err:?}"
            );
        }
        // And profile 0 at version 6 is the FULL body, read by the
        // block-mapped path: a compact image relabelled as full is refused for
        // the block size it lacks, never read through the compact directory.
        image[PROFILE_OFFSET] = 0;
        let err = compact_reader(image.clone()).expect_err("a compact image relabelled full must be refused");
        assert!(err.to_string().contains("invalid block size: 0"), "{err}");
    }

    #[test]
    fn a_declared_whole_file_scheme_is_refused_not_ignored() {
        let base = encode_compact_ctfs(&[("meta.dat", b"x")]).unwrap();
        for byte in [1u8, 2, 9, 255] {
            let mut image = base.clone();
            image[COMPRESSION_OFFSET] = byte;
            let err = compact_reader(image).expect_err("a declared scheme must be refused");
            let msg = err.to_string();
            assert!(
                msg.contains(&byte.to_string()) && msg.contains("compression"),
                "scheme {byte} is not refused by name: {msg}"
            );
        }
        // Scheme 0 — the only one this reader serves — must still open, so the
        // check above is not passing by universal refusal.
        assert!(compact_reader(base).is_ok());
    }

    #[test]
    fn a_poisoned_reserved_byte_is_refused_by_offset() {
        let base = encode_compact_ctfs(&[("meta.dat", b"x")]).unwrap();
        for offset in RESERVED_RANGE {
            let mut image = base.clone();
            image[offset] = 0xAB;
            let err = compact_reader(image).expect_err("a non-zero reserved byte must be refused");
            let msg = err.to_string();
            assert!(
                msg.contains(&offset.to_string()) && msg.contains("reserved"),
                "reserved byte {offset} is not refused by offset: {msg}"
            );
        }
    }

    #[test]
    fn the_two_header_musts_are_enforced() {
        let base = encode_compact_ctfs(&[("meta.dat", b"x")]).unwrap();
        // "there are no blocks", spelled as a block size, is the max_shards
        // defect again.
        let mut with_block_size = base.clone();
        with_block_size[8..12].copy_from_slice(&4096u32.to_le_bytes());
        let err = compact_reader(with_block_size).expect_err("BlockSize 4096 must be refused");
        assert!(err.to_string().contains("BlockSize 4096"), "{err}");

        let mut with_root_entries = base;
        with_root_entries[12..16].copy_from_slice(&31u32.to_le_bytes());
        let err = compact_reader(with_root_entries).expect_err("MaxRootEntries 31 must be refused");
        assert!(err.to_string().contains("MaxRootEntries 31"), "{err}");
    }

    #[test]
    fn the_six_directory_checks_each_refuse_by_value() {
        let members: &[(&str, &[u8])] = &[("meta.dat", b"metadata"), ("events.log", b"eventsevents")];
        let base = encode_compact_ctfs(members).unwrap();
        let n = members.len() as u64;
        let dir = COMPACT_DIRECTORY_OFFSET as usize;

        // check 1 — the directory must fit.
        let mut image = base.clone();
        image[24..28].copy_from_slice(&1_000_000u32.to_le_bytes());
        let err = compact_reader(image).expect_err("an oversized member count must be refused");
        assert!(err.to_string().contains("1000000"), "{err}");

        // check 2 — the first member begins at 28 + 24*N.
        let mut image = base.clone();
        let first = COMPACT_DIRECTORY_OFFSET + 24 * n;
        image[dir + 8..dir + 16].copy_from_slice(&(first + 1).to_le_bytes());
        let err = compact_reader(image).expect_err("a shifted first member must be refused");
        assert!(err.to_string().contains(&format!("must begin at {first}")), "{err}");

        // check 3 — the members are contiguous: shrink entry 0's length and the
        // second member no longer starts where the first ends.
        let mut image = base.clone();
        image[dir + 16..dir + 24].copy_from_slice(&7u64.to_le_bytes());
        let err = compact_reader(image).expect_err("a gap between members must be refused");
        assert!(err.to_string().contains("events.log"), "{err}");

        // check 4 — nothing follows the last member.
        let mut image = base.clone();
        image.push(0);
        let err = compact_reader(image).expect_err("a trailing byte must be refused");
        assert!(
            err.to_string().contains("belonging to no member"),
            "the refusal does not say what the extra byte is: {err}"
        );

        // check 5 — a zero Name, and a name outside the alphabet.
        let mut image = base.clone();
        image[dir..dir + 8].copy_from_slice(&0u64.to_le_bytes());
        let err = compact_reader(image).expect_err("a zero Name must be refused");
        assert!(err.to_string().contains("zero Name"), "{err}");

        let mut image = base.clone();
        image[dir..dir + 8].copy_from_slice(&padding_mapped_word("meta dat").to_le_bytes());
        let err = compact_reader(image).expect_err("a name with an embedded NUL must be refused");
        assert!(err.to_string().contains("base40 alphabet"), "{err}");

        // check 6 — the names are distinct.
        let duplicate = base40_encode("meta.dat").unwrap();
        let mut image = base.clone();
        image[dir + 24..dir + 32].copy_from_slice(&duplicate.to_le_bytes());
        let err = compact_reader(image).expect_err("a duplicated name must be refused");
        assert!(err.to_string().contains("twice"), "{err}");

        // The unmodified image must open, so none of the above passes by
        // universal refusal.
        assert!(compact_reader(base).is_ok(), "the well-formed container must open");
    }

    #[test]
    fn a_compact_container_is_refused_over_a_non_resident_source() {
        let dir = tempfile::tempdir().expect("tempdir");
        let path = dir.path().join("compact.ct");
        write_compact_ctfs(&path, &[("meta.dat", b"metadata")]).unwrap();

        // The memory-resident door opens it.
        let resident = CtfsReader::open(&path).expect("the whole-file loader opens a compact container");
        assert!(resident.is_compact());

        // Every positional door refuses it, by name, with the remedy.
        let err = CtfsReader::open_local_file(&path).expect_err("a positional source must be refused");
        let msg = err.to_string();
        assert!(
            msg.contains("loaded whole") && msg.contains("InMemoryBlockSource"),
            "the refusal does not name the remedy: {msg}"
        );
        let err = CtfsReader::open_follow(&path).expect_err("a follow source must be refused");
        assert!(err.to_string().contains("loaded whole"), "{err}");

        // CONTROL: the same two doors open a FULL container of the same
        // members, so the refusal is attributable to the PROFILE and not to the
        // doors being broken.
        let full_path = dir.path().join("full.ct");
        write_minimal_ctfs(&full_path, &[("meta.dat", b"metadata")]).unwrap();
        assert!(CtfsReader::open_local_file(&full_path).is_ok());
        assert!(CtfsReader::open_follow(&full_path).is_ok());
    }

    #[test]
    fn a_truncated_version_six_header_is_refused_rather_than_defaulted() {
        let base = encode_compact_ctfs(&[("meta.dat", b"x")]).unwrap();
        // Nine truncation lengths, each shorter than the 24-byte header: a
        // 17-byte head carries the profile byte and not the compression byte,
        // so the refusal must be about the HEADER being short rather than about
        // either field's value.
        for len in [0usize, 1, 5, 6, 8, 16, 17, 18, 23] {
            let err = compact_reader(base[..len.min(base.len())].to_vec())
                .expect_err("a head shorter than the v6 header must be refused");
            let msg = err.to_string();
            assert!(
                !msg.contains("profile 0"),
                "a {len}-byte head must not be read as profile 0: {msg}"
            );
        }
    }

    #[test]
    fn a_compact_container_with_no_members_is_well_formed_and_empty() {
        let image = encode_compact_ctfs(&[]).unwrap();
        assert_eq!(image.len(), 28, "a memberless compact container is header + count");
        let reader = compact_reader(image).expect("it opens");
        assert!(reader.member_names_in_order().is_empty());
        assert!(!reader.has_file("meta.dat"));
    }
}
