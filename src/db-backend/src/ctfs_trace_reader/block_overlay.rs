//! In-memory copy-on-write (CoW) block overlay over a [`BlockSource`] (M2).
//!
//! Implements the **CTFS Block Overlay** described in
//! `codetracer-specs/Trace-Files/CTFS-Binary-Format.md` §11.4. The overlay is an
//! optional in-memory layer interposed on the normal block read/write path so a
//! session can append/mutate blocks **without touching the backing file** — the
//! read-only-media and "don't expand my `.ct`" use cases — with a single mode
//! flip that either discards the staged blocks at close (`InMemory`) or flushes
//! them to the backing file (`Persist`).
//!
//! # Why copy-on-write (not append-only)
//!
//! CTFS is append-only for **data** blocks, but a few block classes are mutated
//! **in place** as a trace grows (§11.4): Block 0 (the free-list roots, each
//! `FileEntry.Size`, and the `NextFreeBlock` counter) and freed sub-block slots.
//! An append-only overlay could capture newly-allocated blocks but would lose
//! these in-place mutations, so the overlay must be copy-on-write: the *first*
//! write to an existing block copies it into the overlay and then mutates the
//! copy there; newly-allocated blocks (`NextFreeBlock++`) are born directly in
//! the overlay and never read from the backing store.
//!
//! # Shadow Block 0
//!
//! §11.4's structure carves out a **shadow block 0** holding the in-place-mutable
//! root state (file-entry sizes, free-list roots, `NextFreeBlock`). The overlay
//! captures Block 0 in the same `blocks` map the moment any root state is
//! mutated (a `FileEntry.Size` update, a free-list push/pop, or a
//! `NextFreeBlock` bump from [`CtfsBlockOverlay::alloc_block`]), so size updates
//! and allocations do not touch the backing file until — and unless — the
//! overlay is flushed in `Persist` mode.
//!
//! # Decoupling
//!
//! The overlay only ever *reads* from its backing [`BlockSource`]; in `InMemory`
//! mode it never writes through, so it works over a read-only file (or, later,
//! an `HttpRangeSource`) whose underlying storage cannot be written. `Persist`
//! mode writes through a separate [`BlockSink`] — a writable handle the caller
//! supplies — so the read path and the (optional) write path stay independent:
//! a read-only backing source never needs to be writable to drive the overlay.

use std::collections::BTreeMap;
use std::fs::{File, OpenOptions};
use std::path::Path;

use super::ctfs_container::{
    base40_decode, base40_encode, BlockSource, CtfsError, EXTENDED_HEADER_SIZE, FILE_ENTRY_SIZE, HEADER_SIZE,
};

/// Byte offset of the `Size` field within a 24-byte `FileEntry`
/// (CTFS-Binary-Format.md §2: `Size` is the first field).
const FILE_ENTRY_SIZE_FIELD_OFFSET: usize = 0;

/// How the overlay reconciles its staged blocks with the backing file at close.
///
/// This is §11.4's single "flip":
///
/// - [`OverlayMode::InMemory`] — never write through; the overlay is discarded
///   at close. Serves read-only media and non-expanding sessions.
/// - [`OverlayMode::Persist`] — [`CtfsBlockOverlay::flush`] writes the staged
///   blocks (data blocks first, then the shadow Block 0 that publishes them)
///   through to the backing file.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum OverlayMode {
    /// Stage all mutations/allocations in RAM only; discard at close. `flush()`
    /// is a no-op so the backing file is never written.
    InMemory,
    /// Stage in RAM, then materialise on `flush()` to the backing file.
    Persist,
}

/// A writable destination for an overlay [`CtfsBlockOverlay::flush`].
///
/// Kept separate from [`BlockSource`] (which is read-only by design) so the
/// overlay's read path never requires a writable backing store. Only `Persist`
/// mode needs a sink; `InMemory` sessions can pass [`NoOpBlockSink`] (or `None`).
pub trait BlockSink {
    /// Write exactly `bytes.len()` bytes at container byte `offset`, extending
    /// the destination if `offset` lands at/after its current end.
    fn write_at(&mut self, offset: u64, bytes: &[u8]) -> Result<(), CtfsError>;

    /// Flush any buffered writes durably to the underlying medium.
    fn sync(&mut self) -> Result<(), CtfsError>;
}

/// A [`BlockSink`] backed by a writable file opened for read+write.
#[derive(Debug)]
pub struct FileBlockSink {
    file: File,
}

impl FileBlockSink {
    /// Open `path` read+write for flushing overlay blocks. The file must already
    /// exist (the overlay flushes onto an existing container image).
    pub fn open(path: &Path) -> Result<Self, CtfsError> {
        let file = OpenOptions::new().read(true).write(true).open(path)?;
        Ok(FileBlockSink { file })
    }
}

impl BlockSink for FileBlockSink {
    fn write_at(&mut self, offset: u64, bytes: &[u8]) -> Result<(), CtfsError> {
        #[cfg(unix)]
        {
            use std::os::unix::fs::FileExt;
            self.file.write_all_at(bytes, offset)?;
        }
        #[cfg(windows)]
        {
            use std::os::windows::fs::FileExt;
            let mut written = 0usize;
            while written < bytes.len() {
                let n = self.file.seek_write(&bytes[written..], offset + written as u64)?;
                if n == 0 {
                    return Err(CtfsError::Corrupt("file sink: zero-length write".to_string()));
                }
                written += n;
            }
        }
        #[cfg(not(any(unix, windows)))]
        {
            use std::io::{Seek, SeekFrom, Write};
            let mut f = &self.file;
            f.seek(SeekFrom::Start(offset))?;
            f.write_all(bytes)?;
        }
        Ok(())
    }

    fn sync(&mut self) -> Result<(), CtfsError> {
        self.file.sync_all()?;
        Ok(())
    }
}

/// A [`BlockSink`] that discards every write. Used for `InMemory`-mode overlays
/// that should never reach a backing file even if a flush is attempted.
#[derive(Debug, Default)]
pub struct NoOpBlockSink;

impl BlockSink for NoOpBlockSink {
    fn write_at(&mut self, _offset: u64, _bytes: &[u8]) -> Result<(), CtfsError> {
        Ok(())
    }
    fn sync(&mut self) -> Result<(), CtfsError> {
        Ok(())
    }
}

/// An in-memory copy-on-write block overlay layered over a [`BlockSource`].
///
/// See the module documentation for the §11.4 model. The overlay is
/// block-addressed: callers read/write whole blocks by number, agnostic to
/// whether a given block currently lives in the overlay's `blocks` map or in the
/// backing store. `block_size` is parsed from the backing container's header at
/// construction so block N maps to backing byte offset `N * block_size`.
#[derive(Debug)]
pub struct CtfsBlockOverlay {
    /// The read-only backing block source (file / follow / network). The overlay
    /// never writes through this; writes go through the optional sink on flush.
    backing: Box<dyn BlockSource>,
    /// Staged blocks: copy-on-written existing blocks and newly-allocated ones.
    /// A `BTreeMap` keeps a deterministic ascending iteration order so a flush
    /// writes data blocks in a stable, low-to-high order before the Block 0
    /// update that publishes them.
    blocks: BTreeMap<u64, Vec<u8>>,
    /// Block size in bytes (1024 / 2048 / 4096), parsed from the header.
    block_size: usize,
    /// Number of root directory entries (extended-header `max_root_entries`).
    max_root_entries: usize,
    /// The shadow `NextFreeBlock` counter: the next block number a fresh
    /// allocation hands out. Initialised from the backing container's block
    /// count and bumped by [`alloc_block`](CtfsBlockOverlay::alloc_block).
    next_free_block: u64,
    /// Persistence mode (the §11.4 "flip").
    mode: OverlayMode,
}

impl CtfsBlockOverlay {
    /// Build an overlay over `backing`, parsing the container header to learn the
    /// block size and root-entry count and to seed the shadow `NextFreeBlock`.
    ///
    /// The backing source must already carry a valid CTFS header (the overlay is
    /// layered over an existing container image, never over empty bytes).
    pub fn new(backing: Box<dyn BlockSource>, mode: OverlayMode) -> Result<Self, CtfsError> {
        let total = backing.current_size();
        if total < (HEADER_SIZE + EXTENDED_HEADER_SIZE) as u64 {
            return Err(CtfsError::Corrupt(format!(
                "overlay: backing too small ({total} bytes, need at least {})",
                HEADER_SIZE + EXTENDED_HEADER_SIZE
            )));
        }

        // Parse the fixed + extended header to learn block_size / max_root_entries.
        let mut header = [0u8; HEADER_SIZE + EXTENDED_HEADER_SIZE];
        // `read_block` would over-read on a sub-block-sized header, so read the
        // 16-byte header directly via read_at.
        let read = backing.read_at(0, &mut header)?;
        if read != header.len() {
            return Err(CtfsError::Corrupt("overlay: short header read".to_string()));
        }
        if header[..5] != super::ctfs_container::CTFS_MAGIC {
            return Err(CtfsError::InvalidMagic);
        }
        let version = header[5];
        if !(super::ctfs_container::CTFS_VERSION_MIN..=super::ctfs_container::CTFS_VERSION_MAX).contains(&version) {
            return Err(CtfsError::UnsupportedVersion(version));
        }
        let block_size = u32::from_le_bytes([header[8], header[9], header[10], header[11]]) as usize;
        let max_root_entries = u32::from_le_bytes([header[12], header[13], header[14], header[15]]) as usize;
        if !matches!(block_size, 1024 | 2048 | 4096) {
            return Err(CtfsError::Corrupt(format!("overlay: invalid block size: {block_size}")));
        }

        // The backing image is laid out as a whole number of blocks; the next
        // free block is the count of blocks currently present. `current_size`
        // is block-aligned for a well-formed container, but tolerate a partial
        // trailing region (a still-growing follow source) by rounding up.
        let next_free_block = total.div_ceil(block_size as u64);

        Ok(CtfsBlockOverlay {
            backing,
            blocks: BTreeMap::new(),
            block_size,
            max_root_entries,
            next_free_block,
            mode,
        })
    }

    /// The container block size in bytes.
    pub fn block_size(&self) -> usize {
        self.block_size
    }

    /// The overlay's persistence mode.
    pub fn mode(&self) -> OverlayMode {
        self.mode
    }

    /// The shadow `NextFreeBlock`: the block number the next allocation returns.
    pub fn next_free_block(&self) -> u64 {
        self.next_free_block
    }

    /// Whether block `block_num` currently lives in the overlay (vs the backing).
    pub fn is_overlaid(&self, block_num: u64) -> bool {
        self.blocks.contains_key(&block_num)
    }

    /// Resolve block `block_num`: the overlay copy if present, else the backing
    /// store's bytes (§11.4 "Read Path"). Returns exactly `block_size` bytes.
    ///
    /// This is the read primitive the namespace/file API uses; it is agnostic to
    /// whether the block lives in the overlay or on disk.
    pub fn read_block(&self, block_num: u64) -> Result<Vec<u8>, CtfsError> {
        if let Some(bytes) = self.blocks.get(&block_num) {
            return Ok(bytes.clone());
        }
        self.backing.read_block(block_num, self.block_size)
    }

    /// Copy-on-write a write of `bytes` (exactly one block) to `block_num`
    /// (§11.4 "Write Path").
    ///
    /// - A block already in the overlay is overwritten in place in the overlay.
    /// - A block **not** yet in the overlay that exists in the backing store is
    ///   copied into the overlay first (copy-on-first-write) and then replaced —
    ///   here the caller supplies the full new block contents, so the copy is
    ///   immediately overwritten; [`mutate_block`](CtfsBlockOverlay::mutate_block)
    ///   offers the read-modify-write variant that preserves untouched bytes.
    /// - A newly-allocated block (>= the backing block count) is simply created
    ///   in the overlay; it is never read from the backing store.
    ///
    /// The backing store is never written here regardless of mode.
    pub fn write_block(&mut self, block_num: u64, bytes: Vec<u8>) -> Result<(), CtfsError> {
        if bytes.len() != self.block_size {
            return Err(CtfsError::Corrupt(format!(
                "overlay write_block: block {block_num} is {} bytes, expected {}",
                bytes.len(),
                self.block_size
            )));
        }
        self.blocks.insert(block_num, bytes);
        Ok(())
    }

    /// Read-modify-write `block_num` through the overlay, preserving the bytes
    /// the closure does not touch.
    ///
    /// This is the faithful §11.4 copy-on-write path for an *in-place mutation*
    /// of an existing block (a `FileEntry.Size` bump, a free-list pointer
    /// rewrite): the first such mutation copies the backing block into the
    /// overlay, then the closure mutates the overlay copy. Subsequent mutations
    /// hit the overlay copy directly. The backing block is never altered.
    pub fn mutate_block<F>(&mut self, block_num: u64, mutate: F) -> Result<(), CtfsError>
    where
        F: FnOnce(&mut [u8]),
    {
        if !self.blocks.contains_key(&block_num) {
            // Copy-on-first-write: pull the current bytes from the backing store.
            let current = self.backing.read_block(block_num, self.block_size)?;
            self.blocks.insert(block_num, current);
        }
        // Unwrap is safe: just inserted above if it was missing.
        let block = self
            .blocks
            .get_mut(&block_num)
            .ok_or_else(|| CtfsError::Corrupt(format!("overlay mutate_block: block {block_num} vanished")))?;
        mutate(block);
        Ok(())
    }

    /// Allocate a fresh block: bump the shadow `NextFreeBlock` and create the
    /// new (zero-filled) block directly in the overlay (§11.4 "Write Path" —
    /// "born in the overlay"). Returns the allocated block number.
    ///
    /// The new block is never read from the backing store; the caller typically
    /// follows with [`write_block`](CtfsBlockOverlay::write_block) /
    /// [`mutate_block`](CtfsBlockOverlay::mutate_block) to populate it.
    pub fn alloc_block(&mut self) -> u64 {
        let block_num = self.next_free_block;
        self.next_free_block += 1;
        self.blocks.insert(block_num, vec![0u8; self.block_size]);
        block_num
    }

    // ── Shadow Block 0 accessors ──────────────────────────────────────────

    /// The byte offset of file-entry slot `index` within Block 0.
    fn file_entry_offset(index: usize) -> usize {
        HEADER_SIZE + EXTENDED_HEADER_SIZE + index * FILE_ENTRY_SIZE
    }

    /// Find the file-entry slot index for the named internal file in Block 0, or
    /// `None` if no entry carries that name. Reads through the overlay so a
    /// shadowed Block 0 is honoured.
    pub fn find_file_entry(&self, name: &str) -> Result<Option<usize>, CtfsError> {
        let target = base40_encode(name).map_err(|e| CtfsError::Corrupt(format!("overlay: bad name '{name}': {e}")))?;
        let block0 = self.read_block(0)?;
        for index in 0..self.max_root_entries {
            let off = Self::file_entry_offset(index);
            if off + FILE_ENTRY_SIZE > block0.len() {
                break;
            }
            let name_encoded = u64::from_le_bytes(
                block0[off + 16..off + 24]
                    .try_into()
                    .map_err(|_| CtfsError::Corrupt("overlay: file entry name slice".to_string()))?,
            );
            if name_encoded == target {
                return Ok(Some(index));
            }
        }
        Ok(None)
    }

    /// The current `FileEntry.Size` for the named internal file (resolved through
    /// the overlay's shadow Block 0 if present).
    pub fn file_size(&self, name: &str) -> Result<Option<u64>, CtfsError> {
        let Some(index) = self.find_file_entry(name)? else {
            return Ok(None);
        };
        let block0 = self.read_block(0)?;
        let off = Self::file_entry_offset(index) + FILE_ENTRY_SIZE_FIELD_OFFSET;
        let size = u64::from_le_bytes(
            block0[off..off + 8]
                .try_into()
                .map_err(|_| CtfsError::Corrupt("overlay: file size slice".to_string()))?,
        );
        Ok(Some(size))
    }

    /// Copy-on-write update of the named file's `FileEntry.Size` in shadow Block
    /// 0. The first such update copies Block 0 into the overlay; the backing
    /// Block 0 is never touched (until a `Persist` flush).
    pub fn set_file_size(&mut self, name: &str, new_size: u64) -> Result<(), CtfsError> {
        let index = self
            .find_file_entry(name)?
            .ok_or_else(|| CtfsError::FileNotFound(name.to_string()))?;
        let off = Self::file_entry_offset(index) + FILE_ENTRY_SIZE_FIELD_OFFSET;
        self.mutate_block(0, |block0| {
            block0[off..off + 8].copy_from_slice(&new_size.to_le_bytes());
        })
    }

    /// Read the raw free-list-roots region of shadow Block 0.
    ///
    /// The free-list roots occupy a fixed area immediately after the 16-byte
    /// container header (CTFS-Binary-Format.md §1 "MaxRootEntries and Block 0
    /// Layout"). `len` is the root-area size in bytes (`R = 8 * max_shards * 6`),
    /// which the caller derives from the container's `max_shards`. The overlay
    /// stays format-agnostic about the *interpretation* of these bytes (that is
    /// the M3 free-list/B-tree work); it only provides copy-on-write access to
    /// the region so allocator state mutates in the overlay, not on disk.
    pub fn read_free_list_roots(&self, len: usize) -> Result<Vec<u8>, CtfsError> {
        let block0 = self.read_block(0)?;
        let start = HEADER_SIZE + EXTENDED_HEADER_SIZE;
        let end = start + len;
        if end > block0.len() {
            return Err(CtfsError::Corrupt(format!(
                "overlay: free-list root area [{start}..{end}) exceeds block 0 ({} bytes)",
                block0.len()
            )));
        }
        Ok(block0[start..end].to_vec())
    }

    /// Copy-on-write update of the free-list-roots region of shadow Block 0.
    ///
    /// `roots` replaces the `roots.len()`-byte region starting immediately after
    /// the container header. Mirrors [`read_free_list_roots`](CtfsBlockOverlay::read_free_list_roots).
    pub fn write_free_list_roots(&mut self, roots: &[u8]) -> Result<(), CtfsError> {
        let start = HEADER_SIZE + EXTENDED_HEADER_SIZE;
        let block_size = self.block_size;
        if start + roots.len() > block_size {
            return Err(CtfsError::Corrupt(format!(
                "overlay: free-list roots ({} bytes) overflow block 0 from offset {start}",
                roots.len()
            )));
        }
        let roots = roots.to_vec();
        self.mutate_block(0, move |block0| {
            block0[start..start + roots.len()].copy_from_slice(&roots);
        })
    }

    // ── Persistence (the "flip") ──────────────────────────────────────────

    /// Reconcile the overlay with the backing file per the persistence mode.
    ///
    /// - [`OverlayMode::InMemory`]: a no-op — the backing file is never written
    ///   and the staged blocks remain in RAM (discarded when the overlay drops).
    /// - [`OverlayMode::Persist`]: write every staged block through `sink` in an
    ///   order that preserves the §6 durability discipline — **all data blocks
    ///   (every staged block except Block 0) are written and synced first, then
    ///   Block 0 is written and synced last**. Block 0 carries the
    ///   `FileEntry.Size` / free-list-root / allocation state that *publishes*
    ///   the data blocks to a reader, so publishing it only after the data is
    ///   durable means a crash mid-flush can never expose a size that points at
    ///   not-yet-written bytes (CTFS-Binary-Format.md §6 "Writer Protocol":
    ///   data + mapping before the `FileEntry.Size` store).
    ///
    /// After a successful `Persist` flush the staged blocks are cleared, so the
    /// overlay reflects the backing file again (a subsequent read falls through
    /// to the now-updated backing store).
    pub fn flush(&mut self, sink: &mut dyn BlockSink) -> Result<(), CtfsError> {
        match self.mode {
            OverlayMode::InMemory => Ok(()),
            OverlayMode::Persist => {
                // Phase 1: data blocks (everything except Block 0), low → high.
                for (&block_num, bytes) in self.blocks.iter() {
                    if block_num == 0 {
                        continue;
                    }
                    let offset = block_num
                        .checked_mul(self.block_size as u64)
                        .ok_or_else(|| CtfsError::Corrupt(format!("flush: block {block_num} offset overflow")))?;
                    sink.write_at(offset, bytes)?;
                }
                // Barrier: data must be durable before the Block 0 update that
                // publishes it.
                sink.sync()?;

                // Phase 2: Block 0 — the size/root/allocation update that makes
                // the data blocks visible to a reader — written and synced last.
                if let Some(block0) = self.blocks.get(&0) {
                    sink.write_at(0, block0)?;
                    sink.sync()?;
                }

                // The backing file now holds the staged state; drop the overlay
                // copies so reads fall through to the updated backing store.
                self.blocks.clear();
                Ok(())
            }
        }
    }

    /// Whether the named file is present in (shadow) Block 0.
    pub fn has_file(&self, name: &str) -> Result<bool, CtfsError> {
        Ok(self.find_file_entry(name)?.is_some())
    }

    /// List the names of every file currently in (shadow) Block 0.
    pub fn file_names(&self) -> Result<Vec<String>, CtfsError> {
        let block0 = self.read_block(0)?;
        let mut names = Vec::new();
        for index in 0..self.max_root_entries {
            let off = Self::file_entry_offset(index);
            if off + FILE_ENTRY_SIZE > block0.len() {
                break;
            }
            let name_encoded = u64::from_le_bytes(
                block0[off + 16..off + 24]
                    .try_into()
                    .map_err(|_| CtfsError::Corrupt("overlay: file entry name slice".to_string()))?,
            );
            if name_encoded == 0 {
                continue;
            }
            names.push(base40_decode(name_encoded));
        }
        Ok(names)
    }
}

#[cfg(test)]
#[allow(clippy::unwrap_used, clippy::expect_used)]
mod tests {
    use super::*;
    use crate::ctfs_trace_reader::ctfs_container::{
        write_minimal_ctfs, CtfsReader, InMemoryBlockSource, LocalFileSource,
    };

    const BLOCK_SIZE: usize = 4096;

    /// Resolve the physical byte offset of the first data block of `name` in a
    /// freshly-written fixture container, plus its `FileEntry.Size` field offset.
    /// Used by the tests to reach into a container's raw bytes for verification.
    fn data_block0_offset(path: &Path, name: &str) -> (u64, u64) {
        let reader = CtfsReader::open(path).unwrap();
        let entry = reader.file_entry(name).unwrap();
        let data_block = reader.resolve_block_for_test(entry.1, 0).unwrap();
        (data_block * BLOCK_SIZE as u64, entry.0)
    }

    /// `test_overlay_cow_read_after_write` — write/mutate a block through the
    /// overlay; reads return the new bytes; the backing file's bytes for that
    /// block are UNCHANGED.
    ///
    /// Mutates "steps.dat"'s sole data block through the overlay (in `Persist`
    /// mode, but *without* flushing) and asserts:
    ///  - `read_block` returns the mutated bytes,
    ///  - the SAME block read straight off the raw backing image is unchanged,
    ///  - a sibling block the overlay never touched still resolves to the
    ///    backing bytes.
    ///
    /// A broken copy-on-write (mutating shared state, or resolving to the
    /// backing copy after a write) fails here.
    #[test]
    fn test_overlay_cow_read_after_write() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("cow.ct");

        let steps: Vec<u8> = (0..200u32).map(|i| (i % 256) as u8).collect();
        let calls: Vec<u8> = (0..200u32).map(|i| ((i + 50) % 256) as u8).collect();
        write_minimal_ctfs(&path, &[("steps.dat", &steps), ("calls.dat", &calls)]).unwrap();

        // Raw backing image captured before any overlay activity.
        let raw_before = std::fs::read(&path).unwrap();
        let (steps_block_off, _steps_size_off) = data_block0_offset(&path, "steps.dat");
        let steps_block_num = steps_block_off / BLOCK_SIZE as u64;

        // Whole-file source so the backing stays read-only-in-spirit; the overlay
        // copies the block on first mutation.
        let backing = Box::new(InMemoryBlockSource::new(std::fs::read(&path).unwrap()));
        let mut overlay = CtfsBlockOverlay::new(backing, OverlayMode::Persist).unwrap();

        // The block reads identical bytes to the backing before any write.
        let before = overlay.read_block(steps_block_num).unwrap();
        assert_eq!(
            &before[..200],
            &steps[..],
            "pre-write overlay read must match backing data"
        );

        // Copy-on-write mutation: flip the first 8 bytes of the data block.
        let sentinel = [0xAB, 0xCD, 0xEF, 0x01, 0x23, 0x45, 0x67, 0x89];
        overlay
            .mutate_block(steps_block_num, |b| b[..8].copy_from_slice(&sentinel))
            .unwrap();

        // Reads now return the mutated bytes…
        let after = overlay.read_block(steps_block_num).unwrap();
        assert_eq!(&after[..8], &sentinel, "overlay read must return mutated bytes");
        assert_eq!(&after[8..200], &steps[8..200], "untouched bytes preserved by COW");
        assert!(overlay.is_overlaid(steps_block_num), "block now lives in overlay");

        // …but the BACKING image is byte-for-byte unchanged (no write-through).
        let raw_after = std::fs::read(&path).unwrap();
        assert_eq!(
            raw_after, raw_before,
            "backing file must be untouched by an overlay write"
        );

        // A block the overlay never wrote still resolves to the backing bytes.
        let (calls_block_off, _) = data_block0_offset(&path, "calls.dat");
        let calls_block_num = calls_block_off / BLOCK_SIZE as u64;
        assert!(!overlay.is_overlaid(calls_block_num), "untouched block not overlaid");
        let calls_block = overlay.read_block(calls_block_num).unwrap();
        assert_eq!(
            &calls_block[..200],
            &calls[..],
            "untouched block resolves to backing bytes"
        );
    }

    /// `test_overlay_in_memory_mode_no_file_writes` — in `InMemory` mode, a
    /// sequence of appends + mutations leaves the backing file byte-for-byte
    /// identical after close (compare before & after).
    ///
    /// Allocates fresh blocks, mutates an existing block, bumps a
    /// `FileEntry.Size`, and even *attempts a flush* — all in `InMemory` mode —
    /// then asserts the backing file is unchanged. A flush that wrote through, or
    /// any accidental backing mutation, fails here.
    #[test]
    fn test_overlay_in_memory_mode_no_file_writes() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("inmem.ct");

        let steps: Vec<u8> = (0..300u32).map(|i| (i % 256) as u8).collect();
        write_minimal_ctfs(&path, &[("steps.dat", &steps)]).unwrap();
        let raw_before = std::fs::read(&path).unwrap();

        let backing = Box::new(InMemoryBlockSource::new(std::fs::read(&path).unwrap()));
        let mut overlay = CtfsBlockOverlay::new(backing, OverlayMode::InMemory).unwrap();

        // Append: allocate two fresh blocks born in the overlay.
        let b1 = overlay.alloc_block();
        let b2 = overlay.alloc_block();
        assert_eq!(b2, b1 + 1, "allocations are sequential");
        overlay.write_block(b1, vec![0x11; BLOCK_SIZE]).unwrap();
        overlay.write_block(b2, vec![0x22; BLOCK_SIZE]).unwrap();

        // Mutate an existing block.
        let (steps_block_off, _) = data_block0_offset(&path, "steps.dat");
        let steps_block_num = steps_block_off / BLOCK_SIZE as u64;
        overlay.mutate_block(steps_block_num, |b| b[0] = 0xFF).unwrap();

        // Bump a FileEntry.Size in shadow block 0.
        overlay.set_file_size("steps.dat", 999).unwrap();
        assert_eq!(overlay.file_size("steps.dat").unwrap(), Some(999));

        // Attempt a flush — must be a no-op in InMemory mode.
        let mut sink = NoOpBlockSink;
        overlay.flush(&mut sink).unwrap();

        // Drop the overlay ("close").
        drop(overlay);

        let raw_after = std::fs::read(&path).unwrap();
        assert_eq!(
            raw_after, raw_before,
            "InMemory mode must leave the backing file byte-for-byte unchanged"
        );
    }

    /// `test_overlay_persist_flush_roundtrip` — in `Persist` mode, after
    /// `flush()` the changes are durable: reopen the backing file (no overlay)
    /// and read back the mutated/appended blocks identically.
    ///
    /// Stages an appended block AND a `FileEntry.Size` bump that publishes it,
    /// flushes to a real file sink, then reopens the file with NO overlay and
    /// asserts the appended block and the grown size are visible. A flush that
    /// dropped data, mis-ordered, or never wrote block 0 fails here.
    #[test]
    fn test_overlay_persist_flush_roundtrip() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("persist.ct");

        // "steps.dat" starts at one block (200 bytes); we grow it to two blocks.
        let steps: Vec<u8> = (0..200u32).map(|i| (i % 256) as u8).collect();
        write_minimal_ctfs(&path, &[("steps.dat", &steps)]).unwrap();

        // Build the overlay over the on-disk image; flush goes to a file sink.
        let backing = Box::new(InMemoryBlockSource::new(std::fs::read(&path).unwrap()));
        let mut overlay = CtfsBlockOverlay::new(backing, OverlayMode::Persist).unwrap();

        // Append a fresh block and record its expected contents.
        let appended_block = overlay.alloc_block();
        let appended_bytes = vec![0x5A; BLOCK_SIZE];
        overlay.write_block(appended_block, appended_bytes.clone()).unwrap();

        // Mutate the existing data block too (so a block-0 + data flush both run).
        let (steps_block_off, _) = data_block0_offset(&path, "steps.dat");
        let steps_block_num = steps_block_off / BLOCK_SIZE as u64;
        overlay.mutate_block(steps_block_num, |b| b[5] = 0x77).unwrap();

        // Publish via a FileEntry.Size bump in shadow block 0.
        overlay.set_file_size("steps.dat", 222).unwrap();

        // Flush to the real file.
        let mut sink = FileBlockSink::open(&path).unwrap();
        overlay.flush(&mut sink).unwrap();

        // Reopen with NO overlay: the appended block, the mutation, and the
        // grown FileEntry.Size must all be durable.
        let reopened = std::fs::read(&path).unwrap();
        let appended_off = appended_block as usize * BLOCK_SIZE;
        assert!(
            appended_off + BLOCK_SIZE <= reopened.len(),
            "appended block must have extended the file"
        );
        assert_eq!(
            &reopened[appended_off..appended_off + BLOCK_SIZE],
            &appended_bytes[..],
            "appended block durable after flush"
        );
        assert_eq!(
            reopened[steps_block_off as usize + 5],
            0x77,
            "in-place mutation durable after flush"
        );

        // The reader (no overlay) sees the published FileEntry.Size.
        let reader = CtfsReader::open(&path).unwrap();
        let entry = reader.file_entry("steps.dat").unwrap();
        assert_eq!(entry.0, 222, "grown FileEntry.Size durable after flush");
    }

    /// `test_overlay_readonly_media_session` — open the overlay over a backing
    /// source treated as read-only, stage appends/mutations in `InMemory` mode,
    /// and read them back through the overlay; ensure no write to the backing
    /// occurs.
    ///
    /// The backing is a file opened READ-ONLY via `LocalFileSource` (so any
    /// write-through would fail at the OS level). We stage an appended block and
    /// an in-place mutation, read both back through the overlay, and confirm the
    /// on-disk file is byte-for-byte unchanged.
    #[test]
    fn test_overlay_readonly_media_session() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("readonly.ct");

        let steps: Vec<u8> = (0..150u32).map(|i| (i % 256) as u8).collect();
        write_minimal_ctfs(&path, &[("steps.dat", &steps)]).unwrap();
        let raw_before = std::fs::read(&path).unwrap();

        // Backing source = the file opened read-only (LocalFileSource uses
        // File::open, i.e. O_RDONLY). The overlay must never need it writable.
        let backing = Box::new(LocalFileSource::open(&path).unwrap());
        let mut overlay = CtfsBlockOverlay::new(backing, OverlayMode::InMemory).unwrap();

        // Stage an appended block.
        let appended = overlay.alloc_block();
        let appended_bytes = vec![0x3C; BLOCK_SIZE];
        overlay.write_block(appended, appended_bytes.clone()).unwrap();

        // Stage an in-place mutation of the existing data block.
        let (steps_block_off, _) = data_block0_offset(&path, "steps.dat");
        let steps_block_num = steps_block_off / BLOCK_SIZE as u64;
        overlay.mutate_block(steps_block_num, |b| b[3] = 0x9E).unwrap();

        // Read both back through the overlay.
        let read_appended = overlay.read_block(appended).unwrap();
        assert_eq!(read_appended, appended_bytes, "appended block reads back from overlay");
        let read_mutated = overlay.read_block(steps_block_num).unwrap();
        assert_eq!(read_mutated[3], 0x9E, "mutation visible through overlay");
        assert_eq!(read_mutated[4], steps[4], "untouched bytes preserved");

        // The read-only backing file is unchanged on disk.
        let raw_after = std::fs::read(&path).unwrap();
        assert_eq!(
            raw_after, raw_before,
            "read-only backing must stay byte-for-byte unchanged"
        );
    }
}
