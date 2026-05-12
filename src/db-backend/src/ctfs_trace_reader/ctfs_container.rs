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

// ── Reader ──────────────────────────────────────────────────────────────

/// Reader for a CTFS v2/v3/v4 binary container.
///
/// Parses the header and file directory on construction, then provides
/// `read_file(name)` to extract internal files by name.
#[derive(Debug)]
pub struct CtfsReader {
    /// The raw bytes of the entire container. For Phase 1 we load the whole
    /// file into memory. A future Phase 2 implementation would memory-map
    /// the file instead and read blocks on demand.
    data: Vec<u8>,
    /// Block size in bytes (1024, 2048, or 4096).
    block_size: usize,
    /// Number of entries per mapping block (`block_size / 8`).
    entries_per_block: usize,
    /// Parsed file directory, keyed by decoded name.
    files: HashMap<String, FileEntry>,
}

impl CtfsReader {
    /// Open and parse a CTFS container from a file path.
    pub fn open(path: &Path) -> Result<Self, CtfsError> {
        let data = fs::read(path)?;
        Self::from_bytes(data)
    }

    /// Parse a CTFS container from raw bytes.
    pub fn from_bytes(data: Vec<u8>) -> Result<Self, CtfsError> {
        if data.len() < HEADER_SIZE + EXTENDED_HEADER_SIZE {
            return Err(CtfsError::Corrupt(format!(
                "file too small ({} bytes, need at least {})",
                data.len(),
                HEADER_SIZE + EXTENDED_HEADER_SIZE
            )));
        }

        // Validate magic bytes
        if data[..5] != CTFS_MAGIC {
            return Err(CtfsError::InvalidMagic);
        }

        // Check version — we accept v2, v3, and v4 since the extended header
        // and file entry layout is identical across these versions.
        let version = data[5];
        if !(CTFS_VERSION_MIN..=CTFS_VERSION_MAX).contains(&version) {
            return Err(CtfsError::UnsupportedVersion(version));
        }

        // Parse extended header
        let block_size = u32::from_le_bytes([data[8], data[9], data[10], data[11]]) as usize;
        let max_root_entries = u32::from_le_bytes([data[12], data[13], data[14], data[15]]) as usize;

        // Validate block size
        if !matches!(block_size, 1024 | 2048 | 4096) {
            return Err(CtfsError::Corrupt(format!("invalid block size: {block_size}")));
        }

        let entries_per_block = block_size / 8;

        // Parse file entries
        let entry_start = HEADER_SIZE + EXTENDED_HEADER_SIZE;
        let mut files = HashMap::new();

        for i in 0..max_root_entries {
            let offset = entry_start + i * FILE_ENTRY_SIZE;
            if offset + FILE_ENTRY_SIZE > data.len() {
                break;
            }

            // Safety: bounds are checked above (offset + FILE_ENTRY_SIZE <= data.len()),
            // so these 8-byte slices are guaranteed to succeed.
            let size = u64::from_le_bytes(
                data[offset..offset + 8]
                    .try_into()
                    .map_err(|_| CtfsError::Corrupt("file entry size slice".to_string()))?,
            );
            let map_block = u64::from_le_bytes(
                data[offset + 8..offset + 16]
                    .try_into()
                    .map_err(|_| CtfsError::Corrupt("file entry map_block slice".to_string()))?,
            );
            let name_encoded = u64::from_le_bytes(
                data[offset + 16..offset + 24]
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
            data,
            block_size,
            entries_per_block,
            files,
        })
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

            let block_offset = data_block_num as usize * self.block_size;
            let remaining = entry.size as usize - result.len();
            let to_read = remaining.min(self.block_size);

            if block_offset + to_read > self.data.len() {
                return Err(CtfsError::Corrupt(format!(
                    "file '{name}': block {data_block_num} extends beyond end of container"
                )));
            }

            result.extend_from_slice(&self.data[block_offset..block_offset + to_read]);
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
        let offset = block_num as usize * self.block_size + entry_index * 8;
        if offset + 8 > self.data.len() {
            return Err(CtfsError::Corrupt(format!(
                "mapping entry at block {block_num}, index {entry_index} is out of bounds"
            )));
        }
        Ok(u64::from_le_bytes(
            self.data[offset..offset + 8]
                .try_into()
                .map_err(|_| CtfsError::Corrupt("mapping entry slice".to_string()))?,
        ))
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
