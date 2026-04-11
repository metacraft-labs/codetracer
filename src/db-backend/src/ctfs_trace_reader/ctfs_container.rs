//! Minimal CTFS binary container reader (and test-only writer).
//!
//! Implements just enough of the CTFS v2 binary format spec to:
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

/// The format version we support.
const CTFS_VERSION: u8 = 2;

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
        let idx = BASE40_CHARS
            .iter()
            .position(|&c| c == ch)
            .ok_or_else(|| {
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

    // Safety: all base40 characters are valid ASCII
    String::from_utf8(chars).expect("base40 characters are always valid UTF-8")
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
            CtfsError::UnsupportedVersion(v) => write!(f, "unsupported CTFS version {v} (expected {CTFS_VERSION})"),
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

/// Reader for a CTFS v2 binary container.
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

        // Check version
        let version = data[5];
        if version != CTFS_VERSION {
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

            let size = u64::from_le_bytes(data[offset..offset + 8].try_into().unwrap());
            let map_block = u64::from_le_bytes(data[offset + 8..offset + 16].try_into().unwrap());
            let name_encoded = u64::from_le_bytes(data[offset + 16..offset + 24].try_into().unwrap());

            // Skip empty entries (size=0, map_block=0, name=0)
            if name_encoded == 0 {
                continue;
            }

            let name = base40_decode(name_encoded);
            files.insert(
                name.clone(),
                FileEntry {
                    name,
                    size,
                    map_block,
                },
            );
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
    fn resolve_multilevel(
        &self,
        map_block: u64,
        index: usize,
        depth: usize,
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
            return Err(CtfsError::Corrupt(
                "null pointer in mapping sub-block".to_string(),
            ));
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
            self.data[offset..offset + 8].try_into().unwrap(),
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

/// Write a minimal CTFS v2 container for testing purposes.
///
/// Creates a container with block_size=4096, max_root_entries=31, containing
/// the specified files. This is NOT a production writer — it uses the simplest
/// possible layout (one data block per file, no multi-level mapping needed).
///
/// # Panics
///
/// Panics if any file name is longer than 12 characters or contains
/// characters outside the base40 alphabet.
pub fn write_minimal_ctfs(
    path: &Path,
    files: &[(&str, &[u8])],
) -> Result<(), Box<dyn Error>> {
    let block_size: usize = 4096;
    let max_root_entries: u32 = 31;

    // Compute how many blocks we need:
    // Block 0: header + file entries
    // For each file: 1 mapping block + ceil(size / block_size) data blocks
    let mut next_block: u64 = 1; // Block 0 is the root block

    struct FileLayout {
        name_encoded: u64,
        size: u64,
        map_block: u64,
        data_blocks: Vec<u64>,
    }

    let mut layouts = Vec::with_capacity(files.len());

    for &(name, data) in files {
        let name_encoded = base40_encode(name)?;
        let num_data_blocks = if data.is_empty() {
            0
        } else {
            data.len().div_ceil(block_size)
        };

        let map_block = if data.is_empty() {
            0
        } else {
            let mb = next_block;
            next_block += 1;
            mb
        };

        let mut data_blocks = Vec::with_capacity(num_data_blocks);
        for _ in 0..num_data_blocks {
            data_blocks.push(next_block);
            next_block += 1;
        }

        layouts.push(FileLayout {
            name_encoded,
            size: data.len() as u64,
            map_block,
            data_blocks,
        });
    }

    // Allocate the output buffer
    let total_size = next_block as usize * block_size;
    let mut buf = vec![0u8; total_size];

    // Write header
    buf[0..5].copy_from_slice(&CTFS_MAGIC);
    buf[5] = CTFS_VERSION;
    // bytes 6-7 are reserved (already zero)

    // Write extended header
    buf[8..12].copy_from_slice(&(block_size as u32).to_le_bytes());
    buf[12..16].copy_from_slice(&max_root_entries.to_le_bytes());

    // Write file entries
    let entry_start = HEADER_SIZE + EXTENDED_HEADER_SIZE;
    for (i, layout) in layouts.iter().enumerate() {
        let offset = entry_start + i * FILE_ENTRY_SIZE;
        buf[offset..offset + 8].copy_from_slice(&layout.size.to_le_bytes());
        buf[offset + 8..offset + 16].copy_from_slice(&layout.map_block.to_le_bytes());
        buf[offset + 16..offset + 24].copy_from_slice(&layout.name_encoded.to_le_bytes());
    }

    // Write mapping blocks and data blocks
    for (file_idx, &(_, data)) in files.iter().enumerate() {
        let layout = &layouts[file_idx];
        if data.is_empty() {
            continue;
        }

        // Write the mapping block: entries point to data blocks
        let map_offset = layout.map_block as usize * block_size;
        for (j, &db) in layout.data_blocks.iter().enumerate() {
            let entry_offset = map_offset + j * 8;
            buf[entry_offset..entry_offset + 8].copy_from_slice(&db.to_le_bytes());
        }

        // Write data blocks
        let mut remaining = data;
        for &db in &layout.data_blocks {
            let data_offset = db as usize * block_size;
            let to_write = remaining.len().min(block_size);
            buf[data_offset..data_offset + to_write].copy_from_slice(&remaining[..to_write]);
            remaining = &remaining[to_write..];
        }
    }

    fs::write(path, &buf)?;
    Ok(())
}

// ── Unit tests ──────────────────────────────────────────────────────────

#[cfg(test)]
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
        write_minimal_ctfs(
            &path,
            &[("file.a", file_a.as_slice()), ("file.b", file_b.as_slice())],
        )
        .unwrap();

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
        assert!(matches!(
            reader.read_file("nope"),
            Err(CtfsError::FileNotFound(_))
        ));
    }

    #[test]
    fn test_invalid_magic() {
        let data = vec![0xFF; 1024];
        assert!(matches!(
            CtfsReader::from_bytes(data),
            Err(CtfsError::InvalidMagic)
        ));
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
}
