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
//! CTFS is append-only for **data** blocks, but the root directory is mutated
//! **in place** as members are created and grow (`ctfs-container.md` §6, "What
//! Is Mutated In Place"): each `FileEntry`'s `Name`, `MapBlock` and `Size`
//! words. An append-only overlay could capture newly-allocated blocks but would
//! lose these in-place mutations, so the overlay must be copy-on-write: the
//! *first* write to an existing block copies it into the overlay and then
//! mutates the copy there; newly-allocated blocks are born directly in the
//! overlay and never read from the backing store.
//!
//! # Shadow root region
//!
//! The root directory is the **root region** `[0, root_blocks)`
//! (`ctfs-container.md` §1): the header followed by `MaxRootEntries` entries,
//! continuing past block 0 when the container declares more entries than block
//! 0 holds (the MCR recorder declares 16 root blocks when it checkpoints). Every
//! directory accessor addresses entry `i` by its container byte offset and
//! copies on write whichever root blocks hold the words it changes, so a
//! directory update does not touch the backing file until — and unless — the
//! overlay is flushed in `Persist` mode.
//!
//! `NextFreeBlock` is not stored in the container (§5, "Adding Members To A
//! Closed Container"): the overlay recovers it from the backing length at
//! construction and keeps it as a field.
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

use super::ctfs_container::{BlockSource, CTFS_DIRECT, CtfsError, FILE_ENTRY_SIZE, base40_decode, base40_encode};

/// Byte offsets of the `Size`, `MapBlock` and `Name` fields within a 24-byte
/// `FileEntry` (`ctfs-container.md` §2).
const FILE_ENTRY_SIZE_FIELD_OFFSET: usize = 0;
const FILE_ENTRY_MAP_BLOCK_OFFSET: usize = 8;
const FILE_ENTRY_NAME_OFFSET: usize = 16;

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
    /// Byte offset of the `FileEntry` array (the header's size).
    entry_start: usize,
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
        // Parse the header to learn block_size / entry_start / max_root_entries.
        // `read_block` would over-read on a sub-block-sized header, so read the
        // header directly via read_at.
        let want = super::ctfs_container::V6_HEADER_SIZE.min(usize::try_from(total).unwrap_or(usize::MAX));
        let mut header = vec![0u8; want];
        if want > 0 {
            let read = backing.read_at(0, &mut header)?;
            if read != header.len() {
                return Err(CtfsError::Corrupt("overlay: short header read".to_string()));
            }
        }
        let super::ctfs_container::ContainerHeader {
            block_size,
            entry_start,
            max_root_entries,
        } = super::ctfs_container::parse_container_header(&header)?;

        // The backing image is laid out as a whole number of blocks; the next
        // free block is the count of WHOLE blocks currently present.
        //
        // `current_size` is block-aligned for a well-formed container, and this
        // tolerates a partial trailing region — a still-growing follow source,
        // or the fragment a crash inside an append's tail write leaves — by
        // **flooring**. It used to round up, which is the one arithmetic
        // `CTFS-Binary-Format.md` §5d forbids: rounding up makes the incomplete
        // final block addressable, and the block counter then names a block the
        // backing source will (correctly) refuse to read, so the counter and the
        // readable range disagree by one.
        //
        // Flooring instead means the fragment is unaddressable and the next
        // allocation reclaims it, which is what §5d's reader rule says happens
        // to bytes past the last whole block. It cannot lose referenced data:
        // §6's writer protocol flushes a data or mapping block in full before
        // the `FileEntry.Size` store that publishes it, so any block a reader
        // can legitimately reach is already whole on disk and therefore below
        // this floor. Anything at or above it is either unreferenced waste or a
        // truncation, and in both cases `read_block`'s bound against
        // `current_size` refuses it rather than serving a short read.
        let next_free_block = total / block_size as u64;

        Ok(CtfsBlockOverlay {
            backing,
            blocks: BTreeMap::new(),
            block_size,
            entry_start,
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
    /// of an existing block (a `FileEntry.Size` bump): the first such mutation
    /// copies the backing block into the overlay, then the closure mutates the
    /// overlay copy. Subsequent mutations hit the overlay copy directly. The
    /// backing block is never altered.
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

    // ── Shadow root region accessors ──────────────────────────────────────

    /// The number of blocks, from block 0, that hold the header and the entry
    /// array (`ctfs-container.md` §1:
    /// `root_blocks = ceil((header + MaxRootEntries * 24) / BlockSize)`). They
    /// are never data or mapping blocks.
    pub fn root_blocks(&self) -> u64 {
        let root_bytes = self.entry_start + self.max_root_entries * FILE_ENTRY_SIZE;
        root_bytes.div_ceil(self.block_size).max(1) as u64
    }

    /// The container byte offset of file-entry slot `index`, as the writer
    /// places it (the Nim `fileEntryOffset`). It lies past block 0 for any slot
    /// block 0 cannot hold, and an entry may straddle two root blocks when the
    /// header is 24 bytes.
    fn file_entry_offset(&self, index: usize) -> usize {
        self.entry_start + index * FILE_ENTRY_SIZE
    }

    /// The whole entry array, read through the overlay from every root block
    /// (so a shadowed root block is honoured): `max_root_entries` entries,
    /// entry `i` at byte `i * FILE_ENTRY_SIZE`.
    fn read_root_directory(&self) -> Result<Vec<u8>, CtfsError> {
        let root_blocks = self.root_blocks();
        let mut directory = Vec::with_capacity(root_blocks as usize * self.block_size);
        for block_num in 0..root_blocks {
            directory.extend_from_slice(&self.read_block(block_num)?);
        }
        directory.drain(..self.entry_start);
        directory.truncate(self.max_root_entries * FILE_ENTRY_SIZE);
        Ok(directory)
    }

    /// The `field` word of entry `index` in a [`read_root_directory`] image.
    ///
    /// [`read_root_directory`]: CtfsBlockOverlay::read_root_directory
    fn entry_word(directory: &[u8], index: usize, field: usize) -> u64 {
        let off = index * FILE_ENTRY_SIZE + field;
        let mut word = [0u8; 8];
        word.copy_from_slice(&directory[off..off + 8]);
        u64::from_le_bytes(word)
    }

    /// The slot whose `Name` is `target` in a directory image, if any.
    fn find_in(directory: &[u8], target: u64) -> Option<usize> {
        (0..directory.len() / FILE_ENTRY_SIZE)
            .find(|&index| Self::entry_word(directory, index, FILE_ENTRY_NAME_OFFSET) == target)
    }

    /// Copy-on-write `bytes` into the root region at container byte `offset`,
    /// split across the root blocks the range spans.
    fn write_root_bytes(&mut self, offset: usize, bytes: &[u8]) -> Result<(), CtfsError> {
        let mut written = 0;
        while written < bytes.len() {
            let at = offset + written;
            let in_block = at % self.block_size;
            let len = (self.block_size - in_block).min(bytes.len() - written);
            let chunk = &bytes[written..written + len];
            self.mutate_block((at / self.block_size) as u64, |block| {
                block[in_block..in_block + len].copy_from_slice(chunk);
            })?;
            written += len;
        }
        Ok(())
    }

    /// Find the file-entry slot index for the named internal file in the root
    /// directory, or `None` if no entry carries that name. Reads through the
    /// overlay so shadowed root blocks are honoured.
    pub fn find_file_entry(&self, name: &str) -> Result<Option<usize>, CtfsError> {
        let target = base40_encode(name).map_err(|e| CtfsError::Corrupt(format!("overlay: bad name '{name}': {e}")))?;
        Ok(Self::find_in(&self.read_root_directory()?, target))
    }

    /// The current `FileEntry.Size` for the named internal file (resolved through
    /// the overlay's shadow root blocks if present).
    pub fn file_size(&self, name: &str) -> Result<Option<u64>, CtfsError> {
        let target = base40_encode(name).map_err(|e| CtfsError::Corrupt(format!("overlay: bad name '{name}': {e}")))?;
        let directory = self.read_root_directory()?;
        Ok(Self::find_in(&directory, target)
            .map(|index| Self::entry_word(&directory, index, FILE_ENTRY_SIZE_FIELD_OFFSET)))
    }

    /// Copy-on-write update of the named file's `FileEntry.Size` in the shadow
    /// root block that holds it. The first such update copies that block into
    /// the overlay; the backing block is never touched (until a `Persist` flush).
    pub fn set_file_size(&mut self, name: &str, new_size: u64) -> Result<(), CtfsError> {
        let index = self
            .find_file_entry(name)?
            .ok_or_else(|| CtfsError::FileNotFound(name.to_string()))?;
        let off = self.file_entry_offset(index) + FILE_ENTRY_SIZE_FIELD_OFFSET;
        self.write_root_bytes(off, &new_size.to_le_bytes())
    }

    // ── Internal-file writing (M5: persist a namespace into the .ct) ──────

    /// Write a whole internal file `name` with contents `data` into the
    /// container through the overlay (M5: persist `coverage.tc` /
    /// `memwrites.tc` / `linehits.tc` namespace images into the `.ct`).
    ///
    /// Allocates fresh blocks (born in the overlay) and a directory `FileEntry`
    /// in shadow Block 0 — all copy-on-write, so the backing file is untouched
    /// until a `Persist` [`flush`](CtfsBlockOverlay::flush). The member is laid
    /// out as `ctfs-container.md` §2 requires of a version 5 container: empty
    /// owns no block (`MapBlock = 0`), at most one block is that data block
    /// tagged with [`CTFS_DIRECT`] and no mapping block, and anything larger is
    /// a single-level mapping whose mapping block is claimed before its data
    /// blocks. A plain [`super::ctfs_container::CtfsReader`] reads the file
    /// back after a flush (the warm-restart proof).
    ///
    /// Constraints (sufficient for the M5 namespace images, which are at most a
    /// few pages): `data` must fit within a single-level mapping — i.e. at most
    /// `entries_per_block - 1` data blocks (511 for a 4096-byte block). A larger
    /// file would need the multi-level chain; that is not required here and is
    /// rejected loudly rather than silently mis-mapped.
    ///
    /// If `name` already has a directory entry, it is **overwritten** (the entry's
    /// size + map block are repointed at the freshly-allocated blocks; the old
    /// blocks are simply abandoned in the overlay — acceptable for the
    /// replay-time single-writer path, where the overlay is short-lived).
    pub fn write_internal_file(&mut self, name: &str, data: &[u8]) -> Result<(), CtfsError> {
        let entries_per_block = self.block_size / 8;
        let usable = entries_per_block - 1; // last slot reserved for the chain ptr
        let num_data_blocks = data.len().div_ceil(self.block_size).max(1);
        if num_data_blocks > usable {
            return Err(CtfsError::Corrupt(format!(
                "overlay write_internal_file '{name}': {num_data_blocks} data blocks exceed single-level capacity {usable}"
            )));
        }

        // Empty file: a directory entry with size 0 and no blocks.
        if data.is_empty() {
            return self.set_or_create_file_entry(name, 0, 0);
        }

        if data.len() <= self.block_size {
            let data_block = self.alloc_block();
            let mut block = vec![0u8; self.block_size];
            block[..data.len()].copy_from_slice(data);
            self.write_block(data_block, block)?;
            return self.set_or_create_file_entry(name, data.len() as u64, CTFS_DIRECT | data_block);
        }

        // Allocate the root mapping block first, then the data blocks.
        let map_block = self.alloc_block();
        let mut map_bytes = vec![0u8; self.block_size];
        let mut written = 0usize;
        for block_index in 0..num_data_blocks {
            let data_block = self.alloc_block();
            // Fill the data block with this slice of `data`.
            let to_write = (data.len() - written).min(self.block_size);
            let mut block = vec![0u8; self.block_size];
            block[..to_write].copy_from_slice(&data[written..written + to_write]);
            self.write_block(data_block, block)?;
            written += to_write;
            // Direct pointer at entry `block_index` of the root map block.
            let off = block_index * 8;
            map_bytes[off..off + 8].copy_from_slice(&data_block.to_le_bytes());
        }
        self.write_block(map_block, map_bytes)?;
        self.set_or_create_file_entry(name, data.len() as u64, map_block)
    }

    /// Set (or create) the directory `FileEntry` for `name` with the given size
    /// and root map block, copy-on-write in the shadow root block(s) holding it.
    ///
    /// Reuses an existing slot for `name`; otherwise claims the first free slot
    /// (name == 0) in any root block. A full directory is refused, naming the
    /// member, the occupancy and `root_blocks` (`ctfs-container.md` §1, "The
    /// Root Directory Is Fixed At Creation", rule 3).
    fn set_or_create_file_entry(&mut self, name: &str, size: u64, map_block: u64) -> Result<(), CtfsError> {
        let name_encoded =
            base40_encode(name).map_err(|e| CtfsError::Corrupt(format!("overlay: bad name '{name}': {e}")))?;
        let directory = self.read_root_directory()?;
        let entries = directory.len() / FILE_ENTRY_SIZE;
        let first_free =
            || (0..entries).find(|&index| Self::entry_word(&directory, index, FILE_ENTRY_NAME_OFFSET) == 0);
        let index = Self::find_in(&directory, name_encoded)
            .or_else(first_free)
            .ok_or_else(|| {
                CtfsError::Corrupt(format!(
                    "overlay: root directory full ({entries} of {entries} entries used, {} root blocks), cannot add '{name}'",
                    self.root_blocks()
                ))
            })?;
        let mut entry = [0u8; FILE_ENTRY_SIZE];
        entry[FILE_ENTRY_SIZE_FIELD_OFFSET..FILE_ENTRY_SIZE_FIELD_OFFSET + 8].copy_from_slice(&size.to_le_bytes());
        entry[FILE_ENTRY_MAP_BLOCK_OFFSET..FILE_ENTRY_MAP_BLOCK_OFFSET + 8].copy_from_slice(&map_block.to_le_bytes());
        entry[FILE_ENTRY_NAME_OFFSET..FILE_ENTRY_NAME_OFFSET + 8].copy_from_slice(&name_encoded.to_le_bytes());
        self.write_root_bytes(self.file_entry_offset(index), &entry)
    }

    // ── Persistence (the "flip") ──────────────────────────────────────────

    /// Reconcile the overlay with the backing file per the persistence mode.
    ///
    /// - [`OverlayMode::InMemory`]: a no-op — the backing file is never written
    ///   and the staged blocks remain in RAM (discarded when the overlay drops).
    /// - [`OverlayMode::Persist`]: write every staged block through `sink` in an
    ///   order that preserves the §6 durability discipline — **all data blocks
    ///   (every staged block past the root region) are written and synced
    ///   first, then the staged root blocks are written and synced last**. The
    ///   root region carries the `FileEntry` words that *publish* the data
    ///   blocks to a reader, so publishing them only after the data is durable
    ///   means a crash mid-flush can never expose a size that points at
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
                let root_blocks = self.root_blocks();
                // Phase 1: data blocks (everything past the root region), low → high.
                for (&block_num, bytes) in self.blocks.range(root_blocks..) {
                    let offset = block_num
                        .checked_mul(self.block_size as u64)
                        .ok_or_else(|| CtfsError::Corrupt(format!("flush: block {block_num} offset overflow")))?;
                    sink.write_at(offset, bytes)?;
                }
                // Barrier: data must be durable before the root update that
                // publishes it.
                sink.sync()?;

                // Phase 2: the root blocks — the entry updates that make the
                // data blocks visible to a reader — written and synced last.
                let mut root_written = false;
                for (&block_num, bytes) in self.blocks.range(..root_blocks) {
                    sink.write_at(block_num * self.block_size as u64, bytes)?;
                    root_written = true;
                }
                if root_written {
                    sink.sync()?;
                }

                // The backing file now holds the staged state; drop the overlay
                // copies so reads fall through to the updated backing store.
                self.blocks.clear();
                Ok(())
            }
        }
    }

    /// Whether the named file is present in the (shadow) root directory.
    pub fn has_file(&self, name: &str) -> Result<bool, CtfsError> {
        Ok(self.find_file_entry(name)?.is_some())
    }

    /// List the names of every file currently in the (shadow) root directory,
    /// in slot order.
    pub fn file_names(&self) -> Result<Vec<String>, CtfsError> {
        let directory = self.read_root_directory()?;
        Ok((0..directory.len() / FILE_ENTRY_SIZE)
            .map(|index| Self::entry_word(&directory, index, FILE_ENTRY_NAME_OFFSET))
            .filter(|&name_encoded| name_encoded != 0)
            .map(base40_decode)
            .collect())
    }
}

#[cfg(test)]
#[allow(clippy::unwrap_used, clippy::expect_used)]
mod tests {
    use super::*;
    use crate::ctfs_trace_reader::ctfs_container::{
        CtfsReader, InMemoryBlockSource, LocalFileSource, write_minimal_ctfs,
    };

    const BLOCK_SIZE: usize = 4096;

    /// Resolve the physical byte offset of the first data block of `name` in a
    /// freshly-written fixture container, plus its `FileEntry.Size` field offset.
    /// Used by the tests to reach into a container's raw bytes for verification.
    fn data_block0_offset(path: &Path, name: &str) -> (u64, u64) {
        let reader = CtfsReader::open(path).unwrap();
        let entry = reader.file_entry(name).unwrap();
        let data_block = reader.data_block_for_test(name, 0).unwrap();
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

    /// Seal a container holding one stream, then append `extra` unreferenced
    /// bytes so its length is no longer a block multiple — byte-for-byte the
    /// state a crash *inside* an append's tail write leaves (block 0 is the
    /// previous complete one, every pointer in it is below the previous EOF).
    fn partial_tail_container(path: &Path, extra: usize) -> Vec<u8> {
        let steps: Vec<u8> = (0..9000u32).map(|i| (i % 251) as u8).collect();
        write_minimal_ctfs(path, &[("steps.dat", &steps)]).unwrap();
        let sealed = std::fs::read(path).unwrap();
        assert_eq!(
            sealed.len() % BLOCK_SIZE,
            0,
            "the sealed fixture is already {} bytes, not a block multiple; it cannot \
             isolate the partial tail",
            sealed.len()
        );
        let mut torn = sealed;
        torn.extend((0..extra).map(|i| (i % 251) as u8));
        std::fs::write(path, &torn).unwrap();
        steps
    }

    /// `next_free_block` must FLOOR, not round up.
    ///
    /// `CtfsBlockOverlay::new` used to compute `total.div_ceil(block_size)` —
    /// the one arithmetic `CTFS-Binary-Format.md` §5d forbids, because it makes
    /// the incomplete final block addressable. Nothing in this crate consulted
    /// the counter as a validity bound and every read path bounds against
    /// `current_size()`, so the rounding never produced wrong bytes; what it
    /// produced was a counter one block ahead of the readable range, and a next
    /// allocation that skipped over the fragment and stranded it as a hole
    /// inside the addressable range. Restore `div_ceil` and this goes red.
    #[test]
    fn test_overlay_next_free_block_floors_a_partial_tail() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("torn.ct");
        // One whole block plus a fragment: the shape a dying tail write leaves,
        // rather than a bare few bytes.
        partial_tail_container(&path, BLOCK_SIZE + 777);

        let total = std::fs::metadata(&path).unwrap().len();
        assert_ne!(total % BLOCK_SIZE as u64, 0, "the fixture is block-aligned");
        let whole_blocks = total / BLOCK_SIZE as u64;

        let backing = Box::new(LocalFileSource::open(&path).unwrap());
        let mut overlay = CtfsBlockOverlay::new(backing, OverlayMode::InMemory).unwrap();

        assert_eq!(
            overlay.next_free_block(),
            whole_blocks,
            "next_free_block is {}; §5d requires floor(length / block_size) = {} so the \
             incomplete final block stays unaddressable",
            overlay.next_free_block(),
            whole_blocks
        );
        assert_eq!(
            overlay.alloc_block(),
            whole_blocks,
            "the next allocation must reclaim the unreferenced fragment rather than \
             skipping past it and stranding it as a hole"
        );
    }

    /// The bound the acceptance rests on: tolerating a non-block-multiple
    /// length is only safe while nothing can resolve bytes out of the partial
    /// region.
    ///
    /// **The read bound here is not a single site, and that was measured rather
    /// than assumed.** Three independent layers refuse the incomplete block:
    /// `BlockSource::read_block`'s `end > current_size()` check, its short-read
    /// check, and each source's own `read_at` (`LocalFileSource` uses
    /// `read_exact_at`, `InMemoryBlockSource` bounds its slice). Disabling the
    /// first two together leaves this test green because the third still
    /// refuses — which is exactly why §5d recorded this reader's exposure as
    /// allocation-side only. What DOES redden here is
    /// `next_free_block` rounding up: the last assertion pairs the counter with
    /// the readable range, so restoring `div_ceil` makes the block the counter
    /// says exists unreadable, and the pair disagree.
    #[test]
    fn test_overlay_never_reads_out_of_the_partial_region() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("torn.ct");
        let steps = partial_tail_container(&path, 777);

        let backing = Box::new(LocalFileSource::open(&path).unwrap());
        let overlay = CtfsBlockOverlay::new(backing, OverlayMode::InMemory).unwrap();
        let partial = overlay.next_free_block();

        // The incomplete final block is not readable…
        assert!(
            overlay.read_block(partial).is_err(),
            "block {partial} lies in the partial region but was read successfully; a \
             short read there can be served as content"
        );
        // …nor is anything past it.
        assert!(
            overlay.read_block(partial + 1).is_err(),
            "a block past EOF was readable"
        );

        // …and the counter agrees with the readable range exactly: every block
        // below `next_free_block` reads, and the one AT it does not. Under
        // `div_ceil` the counter claims a block the source refuses, so the two
        // disagree by one and this fails.
        assert!(
            overlay.read_block(partial - 1).is_ok(),
            "the last WHOLE block must be readable; next_free_block ({partial}) and the \
             readable range must agree exactly, and they do not"
        );

        // …while the pre-existing stream is completely unaffected: accepting the
        // partial tail must cost the container nothing.
        let mut reader = CtfsReader::open(&path).unwrap();
        assert_eq!(
            reader.read_file("steps.dat").unwrap(),
            steps,
            "a partial tail changed what a pre-existing stream reads back as"
        );
        assert_eq!(
            overlay.file_names().unwrap(),
            vec!["steps.dat".to_string()],
            "the unreferenced partial tail surfaced as an internal file"
        );
    }

    /// `write_internal_file` lays a member out as a version 5 writer must
    /// (`ctfs-container.md` §2): empty owns no block, one block is a tagged
    /// direct block with no mapping block, and a larger member is mapped with
    /// its mapping block claimed before its data blocks. After a `Persist`
    /// flush a plain reader reads each one back.
    #[test]
    fn test_overlay_writes_version_5_member_layouts() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("layouts.ct");
        write_minimal_ctfs(&path, &[("meta.dat", b"m")]).unwrap();
        let before = std::fs::metadata(&path).unwrap().len() / BLOCK_SIZE as u64;

        let small: Vec<u8> = (0..300u32).map(|i| (i % 251) as u8).collect();
        let big: Vec<u8> = (0..(2 * BLOCK_SIZE + 5) as u32).map(|i| (i % 247) as u8).collect();
        let backing = Box::new(LocalFileSource::open(&path).unwrap());
        let mut overlay = CtfsBlockOverlay::new(backing, OverlayMode::Persist).unwrap();
        overlay.write_internal_file("empty.tc", &[]).unwrap();
        overlay.write_internal_file("small.tc", &small).unwrap();
        overlay.write_internal_file("big.tc", &big).unwrap();
        // One block for `small.tc`, a mapping block and three data blocks for
        // `big.tc`, none for `empty.tc`.
        assert_eq!(overlay.next_free_block(), before + 5);
        let mut sink = FileBlockSink::open(&path).unwrap();
        overlay.flush(&mut sink).unwrap();

        let mut reader = CtfsReader::open(&path).unwrap();
        assert_eq!(
            reader.file_entry("empty.tc"),
            Some((0, 0)),
            "an empty member owns no block"
        );
        let (size, map_block) = reader.file_entry("small.tc").unwrap();
        assert_eq!(size, small.len() as u64);
        assert_eq!(
            map_block,
            (1 << 63) | before,
            "a one-block member is its tagged data block"
        );
        let (size, map_block) = reader.file_entry("big.tc").unwrap();
        assert_eq!(size, big.len() as u64);
        assert_eq!(
            map_block,
            before + 1,
            "the mapping block is claimed before the data blocks"
        );
        assert_eq!(reader.read_file("empty.tc").unwrap(), Vec::<u8>::new());
        assert_eq!(reader.read_file("small.tc").unwrap(), small);
        assert_eq!(reader.read_file("big.tc").unwrap(), big);
    }

    // ── Root directories larger than block 0 (ctfs-container.md §1) ──────

    /// The entry count the MCR recorder declares when it takes periodic
    /// checkpoints (`trace_writer.RecorderCheckpointedMaxRootEntries`): at a
    /// 16-byte header this is exactly 16 root blocks, and at version 6's
    /// 24-byte header 17.
    const CHECKPOINTED_ROOT_ENTRIES: u32 = 2730;

    /// Entries that fit block 0 of a version 5 container: `(4096 - 16) / 24`.
    const BLOCK0_ENTRIES: usize = 170;

    /// Byte offset of root entry `slot` from the start of the container, as
    /// `ctfs-container.md` §1 and the Nim writer's `fileEntryOffset` place it.
    fn entry_offset(header_size: usize, slot: usize) -> usize {
        header_size + slot * FILE_ENTRY_SIZE
    }

    /// A raw full-profile container (version 5 or 6) declaring
    /// `max_root_entries`, holding the named empty members at the given slots
    /// and nothing else: the root region `[0, root_blocks)` padded to whole
    /// blocks, as the writer lays it out, with no data blocks after it.
    /// Built byte by byte so it does not depend on the code under test.
    fn root_region_container(version: u8, max_root_entries: u32, members: &[(usize, String)]) -> (Vec<u8>, usize) {
        let header_size = if version == 6 { 24 } else { 16 };
        let root_bytes = header_size + max_root_entries as usize * FILE_ENTRY_SIZE;
        let root_blocks = root_bytes.div_ceil(BLOCK_SIZE);
        let mut buf = vec![0u8; root_blocks * BLOCK_SIZE];
        buf[0..5].copy_from_slice(&super::super::ctfs_container::CTFS_MAGIC);
        buf[5] = version;
        buf[8..12].copy_from_slice(&(BLOCK_SIZE as u32).to_le_bytes());
        buf[12..16].copy_from_slice(&max_root_entries.to_le_bytes());
        for (slot, name) in members {
            let off = entry_offset(header_size, *slot) + 16;
            buf[off..off + 8].copy_from_slice(&base40_encode(name).unwrap().to_le_bytes());
        }
        (buf, root_blocks)
    }

    fn member_name(slot: usize) -> String {
        format!("m{slot}.dat")
    }

    /// The `(size, map_block, name)` words of root entry `slot` in a raw image.
    fn raw_entry(raw: &[u8], header_size: usize, slot: usize) -> (u64, u64, String) {
        let off = entry_offset(header_size, slot);
        let word = |at: usize| u64::from_le_bytes(raw[at..at + 8].try_into().unwrap());
        (word(off), word(off + 8), base40_decode(word(off + 16)))
    }

    /// A [`BlockSink`] that writes into a file and records, in order, the
    /// block number of every write and every `sync`, so a test can check the
    /// publication order of a flush.
    struct RecordingSink {
        inner: FileBlockSink,
        events: Vec<Option<u64>>,
    }

    impl BlockSink for RecordingSink {
        fn write_at(&mut self, offset: u64, bytes: &[u8]) -> Result<(), CtfsError> {
            self.events.push(Some(offset / BLOCK_SIZE as u64));
            self.inner.write_at(offset, bytes)
        }
        fn sync(&mut self) -> Result<(), CtfsError> {
            self.events.push(None);
            self.inner.sync()
        }
    }

    /// A member in any root block is found: block 0's first and last slots,
    /// the first slot of block 1, one in the middle, and the container's last
    /// slot in its last root block. Each is listed in slot order, and a size
    /// update of the last one lands at the byte offset the writer reads it from.
    #[test]
    fn test_overlay_finds_entries_in_every_root_block() {
        let last = CHECKPOINTED_ROOT_ENTRIES as usize - 1;
        let slots = [0, BLOCK0_ENTRIES - 1, BLOCK0_ENTRIES, 1000, last];
        let members: Vec<(usize, String)> = slots.iter().map(|&s| (s, member_name(s))).collect();
        let (raw, root_blocks) = root_region_container(5, CHECKPOINTED_ROOT_ENTRIES, &members);
        assert_eq!(root_blocks, 16, "the fixture declares the recorder's 16 root blocks");
        assert_eq!(
            entry_offset(16, last) / BLOCK_SIZE,
            15,
            "the last slot is in the last root block"
        );

        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("roots.ct");
        std::fs::write(&path, &raw).unwrap();
        let backing = Box::new(LocalFileSource::open(&path).unwrap());
        let mut overlay = CtfsBlockOverlay::new(backing, OverlayMode::Persist).unwrap();

        for (slot, name) in &members {
            assert_eq!(
                overlay.find_file_entry(name).unwrap(),
                Some(*slot),
                "'{name}' at root slot {slot} (root block {}) was not found",
                entry_offset(16, *slot) / BLOCK_SIZE
            );
        }
        let names: Vec<String> = members.iter().map(|(_, n)| n.clone()).collect();
        assert_eq!(overlay.file_names().unwrap(), names);

        let last_name = member_name(last);
        overlay.set_file_size(&last_name, 77).unwrap();
        assert_eq!(overlay.file_size(&last_name).unwrap(), Some(77));
        let mut sink = FileBlockSink::open(&path).unwrap();
        overlay.flush(&mut sink).unwrap();

        let written = std::fs::read(&path).unwrap();
        assert_eq!(raw_entry(&written, 16, last), (77, 0, last_name.clone()));
        assert_eq!(
            written[..entry_offset(16, last)],
            raw[..entry_offset(16, last)],
            "a size update of the last entry changed bytes before it"
        );
        let reader = CtfsReader::open(&path).unwrap();
        assert_eq!(reader.file_entry(&last_name), Some((77, 0)));
    }

    /// With block 0 full and free slots after it, a new member takes the first
    /// free slot (in block 1), not "root directory full". The flush writes the
    /// root region after the data it publishes, and a plain reader reads the
    /// member back.
    #[test]
    fn test_overlay_creates_an_entry_past_block_0() {
        let occupied = BLOCK0_ENTRIES + 30;
        let members: Vec<(usize, String)> = (0..occupied).map(|s| (s, member_name(s))).collect();
        let (raw, root_blocks) = root_region_container(5, CHECKPOINTED_ROOT_ENTRIES, &members);

        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("create.ct");
        std::fs::write(&path, &raw).unwrap();
        let backing = Box::new(LocalFileSource::open(&path).unwrap());
        let mut overlay = CtfsBlockOverlay::new(backing, OverlayMode::Persist).unwrap();
        assert_eq!(overlay.next_free_block(), root_blocks as u64);

        let data: Vec<u8> = (0..(BLOCK_SIZE + 100) as u32).map(|i| (i % 241) as u8).collect();
        overlay.write_internal_file("coverage.tc", &data).unwrap();
        assert_eq!(overlay.find_file_entry("coverage.tc").unwrap(), Some(occupied));

        let mut sink = RecordingSink {
            inner: FileBlockSink::open(&path).unwrap(),
            events: Vec::new(),
        };
        overlay.flush(&mut sink).unwrap();
        // Data and mapping blocks, a barrier, then the root region.
        let barrier = sink.events.iter().position(Option::is_none).unwrap();
        let (data_writes, root_writes) = sink.events.split_at(barrier);
        assert!(
            data_writes.iter().all(|b| b.unwrap() >= root_blocks as u64),
            "a root block was written before the data it publishes was synced: {:?}",
            sink.events
        );
        let entry_block = (entry_offset(16, occupied) / BLOCK_SIZE) as u64;
        assert!(
            root_writes.contains(&Some(entry_block)),
            "the root block holding the new entry was not written after the barrier: {:?}",
            sink.events
        );
        assert_eq!(root_writes.last(), Some(&None), "the root region is synced last");

        let written = std::fs::read(&path).unwrap();
        assert_eq!(raw_entry(&written, 16, occupied).2, "coverage.tc");
        let mut reader = CtfsReader::open(&path).unwrap();
        assert_eq!(reader.read_file("coverage.tc").unwrap(), data);
        assert_eq!(reader.file_entry(&member_name(occupied - 1)), Some((0, 0)));
    }

    /// The "full" boundary: with every slot but the last occupied, a new member
    /// lands in the last slot of the last root block; the next one is refused,
    /// naming it and the occupancy; and rewriting an existing member still
    /// reuses its slot.
    #[test]
    fn test_overlay_root_directory_full_boundary() {
        let last = CHECKPOINTED_ROOT_ENTRIES as usize - 1;
        let members: Vec<(usize, String)> = (0..last).map(|s| (s, member_name(s))).collect();
        let (raw, _) = root_region_container(5, CHECKPOINTED_ROOT_ENTRIES, &members);

        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("full.ct");
        std::fs::write(&path, &raw).unwrap();
        let backing = Box::new(LocalFileSource::open(&path).unwrap());
        let mut overlay = CtfsBlockOverlay::new(backing, OverlayMode::Persist).unwrap();

        overlay.write_internal_file("last.tc", b"fits").unwrap();
        assert_eq!(overlay.find_file_entry("last.tc").unwrap(), Some(last));

        let err = overlay
            .write_internal_file("over.tc", b"no room")
            .unwrap_err()
            .to_string();
        assert!(
            err.contains("root directory full") && err.contains("'over.tc'"),
            "unexpected refusal: {err}"
        );
        assert!(err.contains("2730 of 2730 entries used"), "occupancy not named: {err}");
        assert!(err.contains("16 root blocks"), "root_blocks not named: {err}");
        assert!(!overlay.has_file("over.tc").unwrap());

        overlay.write_internal_file("last.tc", b"rewritten").unwrap();
        assert_eq!(overlay.find_file_entry("last.tc").unwrap(), Some(last));

        let mut sink = FileBlockSink::open(&path).unwrap();
        overlay.flush(&mut sink).unwrap();
        let mut reader = CtfsReader::open(&path).unwrap();
        assert_eq!(reader.read_file("last.tc").unwrap(), b"rewritten");
        assert_eq!(reader.file_entry(&member_name(0)), Some((0, 0)));
    }

    /// At version 6 the 24-byte header puts entries across block boundaries:
    /// slot 169 has its size and map words at the end of block 0 and its name
    /// at the start of block 1. Such an entry is found, updated in both
    /// blocks, and read back by a plain reader.
    #[test]
    fn test_overlay_entry_straddling_two_root_blocks() {
        let straddling = BLOCK0_ENTRIES - 1;
        let off = entry_offset(24, straddling);
        assert!(
            off / BLOCK_SIZE == 0 && (off + 16) / BLOCK_SIZE == 1,
            "slot {straddling} does not straddle blocks 0 and 1 at version 6"
        );
        let last = CHECKPOINTED_ROOT_ENTRIES as usize - 1;
        let members = vec![(straddling, member_name(straddling)), (last, member_name(last))];
        let (raw, root_blocks) = root_region_container(6, CHECKPOINTED_ROOT_ENTRIES, &members);
        assert_eq!(root_blocks, 17);

        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("v6.ct");
        std::fs::write(&path, &raw).unwrap();
        let backing = Box::new(LocalFileSource::open(&path).unwrap());
        let mut overlay = CtfsBlockOverlay::new(backing, OverlayMode::Persist).unwrap();

        for (slot, name) in &members {
            assert_eq!(overlay.find_file_entry(name).unwrap(), Some(*slot));
        }
        overlay.set_file_size(&member_name(last), 5).unwrap();
        // Rewriting the member reuses its straddling slot.
        overlay
            .write_internal_file(&member_name(straddling), b"straddles")
            .unwrap();
        assert_eq!(
            overlay.find_file_entry(&member_name(straddling)).unwrap(),
            Some(straddling)
        );

        let mut sink = FileBlockSink::open(&path).unwrap();
        overlay.flush(&mut sink).unwrap();
        let written = std::fs::read(&path).unwrap();
        assert_eq!(raw_entry(&written, 24, straddling).2, member_name(straddling));
        assert_eq!(raw_entry(&written, 24, last), (5, 0, member_name(last)));
        let mut reader = CtfsReader::open(&path).unwrap();
        assert_eq!(reader.read_file(&member_name(straddling)).unwrap(), b"straddles");
        assert_eq!(reader.file_entry(&member_name(last)), Some((5, 0)));
    }
}
