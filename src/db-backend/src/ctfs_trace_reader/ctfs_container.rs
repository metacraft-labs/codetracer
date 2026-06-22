//! Minimal CTFS binary container reader (and test-only writer).
//!
//! Implements just enough of the CTFS v2/v3/v4 binary format spec to:
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
//! File names are base40-encoded into a single `u64`. Block allocation uses
//! a hierarchical mapping structure (up to 5 levels of indirect blocks).

use std::collections::HashMap;
use std::error::Error;
use std::fmt;
use std::fs;
use std::fs::File;
use std::io;
use std::path::Path;

// ── Constants ───────────────────────────────────────────────────────────

/// Magic bytes identifying a CTFS file: "C0DE trACE2" in hex-speak.
const CTFS_MAGIC: [u8; 5] = [0xC0, 0xDE, 0x72, 0xAC, 0xE2];

/// The minimum CTFS format version we support.
const CTFS_VERSION_MIN: u8 = 2;

/// The maximum CTFS format version we support.
///
/// Version history:
///   v2 — extended header with BlockSize and MaxRootEntries; reserved bytes 6-7.
///   v3 — 16-byte header with encryption field at byte 6; binary metadata;
///         default BlockSize 4096; small file optimization; namespaces.
///   v4 — max_shards field at byte 7 (Nim writer default).
///
/// The on-disk layout of the extended header and file entries is unchanged
/// across all three versions, so a single reader handles them all. The only
/// difference is the meaning of header bytes 6 (encryption, ignored) and 7
/// (max_shards, informational only).
const CTFS_VERSION_MAX: u8 = 4;

/// Size of the fixed header (magic + version + reserved).
const HEADER_SIZE: usize = 8;

/// Size of the extended header (block_size + max_root_entries).
const EXTENDED_HEADER_SIZE: usize = 8;

/// Size of each file entry in the root directory.
const FILE_ENTRY_SIZE: usize = 24;

/// Maximum number of mapping levels supported (5 levels handles files up to ~35 TB).
const MAX_MAPPING_LEVELS: usize = 5;

// ── Base40 codec ────────────────────────────────────────────────────────

/// The base40 character set used for CTFS file names.
/// Index 0 is the null/padding character.
const BASE40_CHARS: &[u8; 40] = b"\x000123456789abcdefghijklmnopqrstuvwxyz./-";

/// Encode a file name (up to 12 characters) into a base40-packed `u64`.
///
/// Characters are encoded left-to-right with the leftmost character in the
/// lowest-order position: `c[0]*40^0 + c[1]*40^1 + ...`.
fn base40_encode(name: &str) -> Result<u64, Box<dyn Error>> {
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
fn base40_decode(mut encoded: u64) -> String {
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
}

impl fmt::Display for CtfsError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            CtfsError::InvalidMagic => write!(f, "not a valid CTFS file (bad magic bytes)"),
            CtfsError::UnsupportedVersion(v) => write!(
                f,
                "unsupported CTFS version {v} (expected {CTFS_VERSION_MIN}..={CTFS_VERSION_MAX})"
            ),
            CtfsError::FileNotFound(name) => write!(f, "internal file not found in CTFS container: {name}"),
            CtfsError::Io(e) => write!(f, "CTFS I/O error: {e}"),
            CtfsError::Corrupt(msg) => write!(f, "corrupt CTFS container: {msg}"),
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
    /// Block number of the root mapping block (0 if file is empty).
    map_block: u64,
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
    /// metadata such as `meta.dat`/`meta.json`).
    ///
    /// M0 sources back finalized, fully-written containers, so the default is
    /// `true`; follow-mode (M1) overrides this to surface in-progress
    /// recordings as not-yet-finalized.
    fn is_finalized(&self) -> bool {
        true
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
        return Err(CtfsError::Corrupt(format!("{context}: read extends beyond end of container")));
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
///   container carries a non-empty `meta.dat` (new split-stream format) or
///   `meta.json` (legacy format) — the writer commits terminal metadata last,
///   so its presence means no further growth will occur and a follow reader can
///   stop polling.
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
    /// Number of root directory entries (extended header `max_root_entries`).
    max_root_entries: usize,
    /// The latest `FileEntry.Size` per internal file name, re-read from Block 0
    /// on every `refresh`. This is the per-file growth signal — distinct from
    /// the raw container `size`, which only ever grows monotonically as bytes
    /// land on disk.
    file_sizes: HashMap<String, u64>,
    /// `true` once a non-empty `meta.dat` / `meta.json` is observed.
    finalized: bool,
}

/// Names whose non-empty presence seals a recording: the new split-stream
/// binary metadata (`meta.dat`) and the legacy JSON metadata (`meta.json`).
/// Either committed and non-empty means the writer has finished.
const FINALIZATION_META_FILES: [&str; 2] = ["meta.dat", "meta.json"];

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
        // Parse the extended header to locate the FileEntry array. We read it
        // here (not lazily) so a malformed container fails fast at open.
        let mut header = [0u8; HEADER_SIZE + EXTENDED_HEADER_SIZE];
        Self::pread_into(&file, 0, &mut header)?;
        if header[..5] != CTFS_MAGIC {
            return Err(CtfsError::InvalidMagic);
        }
        let version = header[5];
        if !(CTFS_VERSION_MIN..=CTFS_VERSION_MAX).contains(&version) {
            return Err(CtfsError::UnsupportedVersion(version));
        }
        let block_size = u32::from_le_bytes([header[8], header[9], header[10], header[11]]) as usize;
        let max_root_entries = u32::from_le_bytes([header[12], header[13], header[14], header[15]]) as usize;
        if !matches!(block_size, 1024 | 2048 | 4096) {
            return Err(CtfsError::Corrupt(format!("invalid block size: {block_size}")));
        }

        let mut source = FollowFileSource {
            file,
            size,
            block_size,
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
        let entry_start = (HEADER_SIZE + EXTENDED_HEADER_SIZE) as u64;
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

// ── Reader ──────────────────────────────────────────────────────────────

/// Reader for a CTFS v2/v3/v4 binary container.
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
    /// Parsed file directory, keyed by decoded name.
    files: HashMap<String, FileEntry>,
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
        if total < (HEADER_SIZE + EXTENDED_HEADER_SIZE) as u64 {
            return Err(CtfsError::Corrupt(format!(
                "file too small ({total} bytes, need at least {})",
                HEADER_SIZE + EXTENDED_HEADER_SIZE
            )));
        }

        // Read the fixed + extended header (16 bytes) in one positional read.
        let mut header = [0u8; HEADER_SIZE + EXTENDED_HEADER_SIZE];
        read_exact_at(source.as_ref(), 0, &mut header, "header")?;

        // Validate magic bytes
        if header[..5] != CTFS_MAGIC {
            return Err(CtfsError::InvalidMagic);
        }

        // Check version — we accept v2, v3, and v4 since the extended header
        // and file entry layout is identical across these versions.
        let version = header[5];
        if !(CTFS_VERSION_MIN..=CTFS_VERSION_MAX).contains(&version) {
            return Err(CtfsError::UnsupportedVersion(version));
        }

        // Parse extended header
        let block_size = u32::from_le_bytes([header[8], header[9], header[10], header[11]]) as usize;
        let max_root_entries = u32::from_le_bytes([header[12], header[13], header[14], header[15]]) as usize;

        // Validate block size
        if !matches!(block_size, 1024 | 2048 | 4096) {
            return Err(CtfsError::Corrupt(format!("invalid block size: {block_size}")));
        }

        let entries_per_block = block_size / 8;

        // Parse file entries
        let entry_start = HEADER_SIZE + EXTENDED_HEADER_SIZE;
        let mut files = HashMap::new();

        for i in 0..max_root_entries {
            let offset = (entry_start + i * FILE_ENTRY_SIZE) as u64;
            // Stop at the first entry that would run past the end of the
            // container.  Matches the prior `break` on the in-memory bounds.
            if offset + FILE_ENTRY_SIZE as u64 > total {
                break;
            }

            let mut entry_buf = [0u8; FILE_ENTRY_SIZE];
            read_exact_at(source.as_ref(), offset, &mut entry_buf, "file entry")?;

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
            files.insert(name.clone(), FileEntry { name, size, map_block });
        }

        Ok(CtfsReader {
            source,
            block_size,
            entries_per_block,
            files,
        })
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

        if entry.map_block == 0 {
            return Err(CtfsError::Corrupt(format!(
                "file '{name}' has non-zero size ({}) but map_block is 0",
                entry.size
            )));
        }

        let mut result = Vec::with_capacity(entry.size as usize);
        let total_data_blocks = (entry.size as usize).div_ceil(self.block_size);

        // Read data blocks by walking the mapping hierarchy.
        for block_index in 0..total_data_blocks {
            let data_block_num = self.resolve_block(entry.map_block, block_index)?;
            if data_block_num == 0 {
                return Err(CtfsError::Corrupt(format!(
                    "file '{name}': unallocated block at index {block_index}"
                )));
            }

            let block_offset = data_block_num * self.block_size as u64;
            let remaining = entry.size as usize - result.len();
            let to_read = remaining.min(self.block_size);

            // Read this block's bytes through the BlockSource.  `read_exact_at`
            // bounds-checks against the source's current size, mirroring the
            // prior whole-file `block_offset + to_read > self.data.len()` guard
            // (and reporting the same "extends beyond end of container" error).
            let start = result.len();
            result.resize(start + to_read, 0);
            read_exact_at(
                self.source.as_ref(),
                block_offset,
                &mut result[start..start + to_read],
                &format!("file '{name}': block {data_block_num}"),
            )?;
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
    fn resolve_block(&self, root_map_block: u64, logical_index: usize) -> Result<u64, CtfsError> {
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

        // Follow indirect pointers to reach the target level
        for _ in 1..level {
            let indirect_ptr = self.read_mapping_entry(current_block, self.entries_per_block - 1)?;
            if indirect_ptr == 0 {
                return Err(CtfsError::Corrupt(
                    "null indirect pointer in mapping hierarchy".to_string(),
                ));
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
            self.resolve_multilevel(current_block, remaining, level - 1)
        }
    }

    /// Recursively resolve a block index through multi-level mapping.
    ///
    /// `depth` is the number of remaining levels to descend (0 = direct lookup).
    fn resolve_multilevel(&self, map_block: u64, index: usize, depth: usize) -> Result<u64, CtfsError> {
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
            return Err(CtfsError::Corrupt("null pointer in mapping sub-block".to_string()));
        }

        self.resolve_multilevel(next_block, sub_remaining, depth - 1)
    }

    /// Read a single u64 entry from a mapping block.
    fn read_mapping_entry(&self, block_num: u64, entry_index: usize) -> Result<u64, CtfsError> {
        let offset = block_num * self.block_size as u64 + (entry_index * 8) as u64;
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

    /// Check whether a named file exists in the container.
    #[allow(dead_code)]
    pub fn has_file(&self, name: &str) -> bool {
        self.files.contains_key(name)
    }
}

// ── Test-only writer ────────────────────────────────────────────────────

/// Write a CTFS container for testing purposes.
///
/// Creates a container with block_size=4096, max_root_entries=31 and lays
/// out each file using the same bottom-up multi-level chain mapping that
/// the production Rust and Nim writers use:
///
/// - Each file owns a root mapping block.  Entries `[0..usable)` of the
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
    buf[5] = CTFS_VERSION_MAX;
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
        let map_block = alloc_block(&mut buf, &mut next_block);
        buf[entry_off..entry_off + 8].copy_from_slice(&size.to_le_bytes());
        buf[entry_off + 8..entry_off + 16].copy_from_slice(&map_block.to_le_bytes());
        buf[entry_off + 16..entry_off + 24].copy_from_slice(&name_encoded.to_le_bytes());

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
                let phys = in_mem.resolve_block(entry.map_block, block_index).unwrap();
                let phys_local = local.resolve_block(entry.map_block, block_index).unwrap();
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
        // direct mapping). `write_minimal_ctfs` lays down a valid CTFS v4 image.
        let initial: Vec<u8> = (0..100u32).map(|i| (i % 256) as u8).collect();
        write_minimal_ctfs(&path, &[("steps.dat", initial.as_slice())]).unwrap();

        // Open the follow source BEFORE any growth.
        let mut follow = FollowFileSource::open(&path).unwrap();
        assert_eq!(follow.file_size("steps.dat"), Some(100), "initial FileEntry.Size");
        assert!(!follow.is_finalized(), "no meta.dat/meta.json ⇒ not finalized");
        let size_before = follow.current_size();

        // ── Simulate a chunk flush that grows "steps.dat" by 50 bytes IN PLACE.
        //    The base writer placed "steps.dat"'s single data block right after
        //    the root map block; rather than re-derive its physical offset, we
        //    locate it by reading the FileEntry's map_block and its first direct
        //    pointer through a throwaway reader, then append into that block (the
        //    block is 4096 bytes, so 150 bytes still fit in block 0 of the file).
        let appended: Vec<u8> = (0..50u32).map(|i| (200 + i % 50) as u8).collect();
        let (data_block_offset, entry_offset, block_size) = {
            let reader = CtfsReader::open(&path).unwrap();
            let block_size = reader.block_size as u64;
            let entry = reader.files.get("steps.dat").unwrap().clone();
            // Physical offset of the file's first (only) data block.
            let data_block = reader.resolve_block(entry.map_block, 0).unwrap();
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
        assert_eq!(follow.current_size(), size_before, "raw size unchanged before refresh()");

        // AFTER refresh: the grown FileEntry.Size and the larger raw size are
        // visible, and the appended bytes read back correctly.
        follow.refresh().unwrap();
        assert_eq!(
            follow.file_size("steps.dat"),
            Some(150),
            "refresh() must observe the grown FileEntry.Size"
        );
        assert!(follow.current_size() >= data_block_offset + 150, "raw size covers appended bytes");

        let mut buf = vec![0u8; 50];
        follow.read_at(data_block_offset + 100, &mut buf).unwrap();
        assert_eq!(buf, appended, "appended bytes read back through the follow source");
    }

    /// M1 — `FollowFileSource.is_finalized()` flips to `true` once a non-empty
    /// `meta.json` / `meta.dat` is observed on `refresh()`, and not before.
    #[test]
    fn test_followfilesource_finalization_signal() {
        use std::io::{Seek, SeekFrom, Write};

        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("seal.ct");

        // Two entries: a data file and a placeholder meta.json at size 0.
        write_minimal_ctfs(&path, &[("steps.dat", b"abc"), ("meta.json", &[])]).unwrap();

        let mut follow = FollowFileSource::open(&path).unwrap();
        assert!(!follow.is_finalized(), "meta.json size 0 ⇒ not finalized");

        // Bump meta.json's FileEntry.Size to a non-zero value (its entry is the
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
        assert!(follow.is_finalized(), "non-empty meta.json ⇒ finalized after refresh()");
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
}
