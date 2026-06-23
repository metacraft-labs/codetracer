//! M4 — Rust WRITER for the copy-on-write namespace B-tree page image.
//!
//! ## What this is and why it exists in Rust
//!
//! M3 landed a full path-copying CoW namespace B-tree WRITER in Nim
//! (`codetracer-trace-format-nim/src/codetracer_ctfs/cow_btree.nim`) plus a Rust
//! READER ([`super::cow_namespace_reader`]). M4 is the first real CONSUMER of
//! that store: the `coverage.tc` namespace and the interval-tagged
//! `memwrites.tc` / `linehits.tc` maps. Per the M4 architecture brief, the lazy
//! replay-time population that WRITES those namespaces (M5/M6) runs in the Rust
//! db-backend (over the M2 [`super::block_overlay::CtfsBlockOverlay`]). So the
//! writer must exist Rust-side, not only Nim-side, for the db-backend to persist
//! `coverage.tc` + tagged maps into the overlay at replay time.
//!
//! This module is therefore the Rust mirror of the Nim `CowBTree`: it produces a
//! **byte-compatible** page image that [`super::cow_namespace_reader`] (and the
//! Nim `loadCowBTree`) read back. It implements the same three LMDB-style
//! ingredients (CTFS-Binary-Format.md §10):
//!
//! * **Path-copying CoW**: to modify a node, a fresh page is popped from the
//!   unified whole-block free list (else bump-allocated), the node's bytes are
//!   copied into it, the change is applied there, and the parent chain is
//!   copied-up to a brand-new root. Reachable pages are never mutated in place.
//! * **Double-buffered atomic root commit**: each commit publishes the new root
//!   into the `root_block[2]` / `commit_id[2]` slot NOT currently in use, with a
//!   higher commit id. The reader selects the highest valid commit id.
//! * **Unified whole-block free list**: pages reachable from the old root but not
//!   the new root are reclaimed through an in-page next-pointer chain rooted in
//!   the header (`free_list_head`), the same whole-block size class the sub-block
//!   pools use.
//!
//! ## Scope (honest)
//!
//! This is a focused writer sufficient for M4: single-threaded incremental
//! inserts/updates, serialise to a page image, reload from a page image. The
//! MVCC reader table + reader-gated reclamation (Nim `beginRead`/`reclaimPending`)
//! is NOT mirrored here — at replay time the db-backend is the single writer and
//! a fresh reader is opened per query over a published image, so reader-gated
//! reclamation is a Nim-writer concern, not needed for the Rust replay-time
//! write path. Superseded pages are reclaimed eagerly into the free list at
//! commit (safe because no concurrent Rust reader pins an older root of the
//! same live tree). See `Outstanding Tasks` in the M4 milestone.
//!
//! ## Wire format
//!
//! Byte-identical to the Nim writer and [`super::cow_namespace_reader`]; see that
//! module's header doc for the full layout. All integers little-endian.

use super::cow_namespace_reader::{CowLeafType, PAGE_SIZE};

const HDR_MAGIC: [u8; 4] = *b"NSB1";

const OFF_ROOT0: usize = 4;
const OFF_ROOT1: usize = 12;
const OFF_COMMIT0: usize = 20;
const OFF_COMMIT1: usize = 28;
const OFF_FLAGS: usize = 36;
const OFF_FREE_HEAD: usize = 37;
const OFF_NEXT_FREE: usize = 45;
const OFF_PAGE_COUNT: usize = 53;

const NODE_HEADER_BYTES: usize = 8;
const KIND_INTERNAL: u8 = 0;
const KIND_LEAF: u8 = 1;

/// Errors surfaced while building or reloading a CoW namespace image. Every
/// variant is a "caller misuse / corrupt image" signal; the writer never panics.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum CowWriteError {
    /// A descriptor whose length disagrees with the leaf type's width.
    DescriptorSize {
        /// The descriptor length the caller supplied.
        got: usize,
        /// The descriptor width the leaf type requires.
        expected: usize,
    },
    /// The image to reload is shorter than the fixed header.
    TooShort,
    /// The reload image magic did not match `NSB1`.
    BadMagic([u8; 4]),
    /// The reload image length is not a whole multiple of [`PAGE_SIZE`].
    Unaligned(usize),
}

impl std::fmt::Display for CowWriteError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            CowWriteError::DescriptorSize { got, expected } => {
                write!(f, "cow-namespace descriptor size {got} != expected {expected}")
            }
            CowWriteError::TooShort => write!(f, "cow-namespace reload image shorter than header"),
            CowWriteError::BadMagic(m) => write!(f, "cow-namespace reload bad magic {m:02X?}"),
            CowWriteError::Unaligned(n) => {
                write!(f, "cow-namespace reload image {n} bytes not page-aligned")
            }
        }
    }
}

impl std::error::Error for CowWriteError {}

fn write_u16(buf: &mut [u8], off: usize, v: u16) {
    buf[off..off + 2].copy_from_slice(&v.to_le_bytes());
}

fn read_u16(buf: &[u8], off: usize) -> u16 {
    u16::from_le_bytes([buf[off], buf[off + 1]])
}

fn write_u64(buf: &mut [u8], off: usize, v: u64) {
    buf[off..off + 8].copy_from_slice(&v.to_le_bytes());
}

fn read_u64(buf: &[u8], off: usize) -> u64 {
    let mut b = [0u8; 8];
    b.copy_from_slice(&buf[off..off + 8]);
    u64::from_le_bytes(b)
}

/// The result of a copy-on-write insertion into a subtree: the freshly-copied
/// spine page for the subtree, plus an optional split.
struct CowInsert {
    /// Fresh copy of the visited node (the new spine page).
    new_page: u64,
    did_split: bool,
    was_update: bool,
    promoted_key: u64,
    /// New right sibling when `did_split`.
    right_page: u64,
}

/// A copy-on-write, crash-safe namespace B-tree page store (writer side).
///
/// The page buffer IS the on-disk image: page 0 is the [`NamespaceHeader`], pages
/// 1.. are B-tree node / free pages, each one [`PAGE_SIZE`] bytes. Mirrors the Nim
/// `CowBTree` byte-for-byte so [`super::cow_namespace_reader::CowNamespaceReader`]
/// (and the Nim `loadCowBTree`) read it back.
///
/// [`NamespaceHeader`]: super::cow_namespace_reader
pub struct CowNamespaceWriter {
    descriptor_size: usize,
    leaf_type: CowLeafType,
    skip_sub_blocks: bool,
    /// Max keys per node before a split.
    order: usize,
    /// Flat page buffer; page N at `N * PAGE_SIZE`.
    pages: Vec<u8>,
    /// First never-used page number (bump cursor).
    next_free_page: u64,
    /// Head of the whole-block free chain (0 = none).
    free_list_head: u64,
    /// Double-buffered root slots.
    root0: u64,
    root1: u64,
    /// Commit ids per slot (0 = empty slot).
    commit0: u64,
    commit1: u64,
    /// Highest commit id issued so far.
    last_commit: u64,
    /// Number of live keys.
    count: u64,
}

impl CowNamespaceWriter {
    /// Create an empty CoW namespace writer. The buffer starts with only page 0
    /// (the header); both root slots are empty (commit id 0) until the first
    /// commit.
    pub fn new(leaf_type: CowLeafType, skip_sub_blocks: bool) -> Self {
        let descriptor_size = leaf_type.descriptor_size();
        let order = (PAGE_SIZE - NODE_HEADER_BYTES) / (8 + descriptor_size);
        let mut w = CowNamespaceWriter {
            descriptor_size,
            leaf_type,
            skip_sub_blocks,
            order,
            pages: vec![0u8; PAGE_SIZE],
            next_free_page: 1,
            free_list_head: 0,
            root0: 0,
            root1: 0,
            commit0: 0,
            commit1: 0,
            last_commit: 0,
            count: 0,
        };
        w.write_header();
        w
    }

    /// Reload a writer from a page image (e.g. one staged in the overlay or read
    /// back from the `.ct`) so incremental commits resume from the published
    /// root. Validates the magic and page alignment.
    pub fn load(image: &[u8], leaf_type: CowLeafType) -> Result<Self, CowWriteError> {
        const HEADER_TOTAL: usize = 61;
        if image.len() < HEADER_TOTAL {
            return Err(CowWriteError::TooShort);
        }
        if image[0..4] != HDR_MAGIC {
            return Err(CowWriteError::BadMagic([image[0], image[1], image[2], image[3]]));
        }
        if !image.len().is_multiple_of(PAGE_SIZE) {
            return Err(CowWriteError::Unaligned(image.len()));
        }
        let descriptor_size = leaf_type.descriptor_size();
        let order = (PAGE_SIZE - NODE_HEADER_BYTES) / (8 + descriptor_size);
        let flags = image[OFF_FLAGS];
        let commit0 = read_u64(image, OFF_COMMIT0);
        let commit1 = read_u64(image, OFF_COMMIT1);
        Ok(CowNamespaceWriter {
            descriptor_size,
            leaf_type,
            skip_sub_blocks: flags & 0b10 != 0,
            order,
            pages: image.to_vec(),
            next_free_page: read_u64(image, OFF_NEXT_FREE),
            free_list_head: read_u64(image, OFF_FREE_HEAD),
            root0: read_u64(image, OFF_ROOT0),
            root1: read_u64(image, OFF_ROOT1),
            commit0,
            commit1,
            last_commit: commit0.max(commit1),
            // The live count is not stored in the header; recompute lazily if a
            // caller needs it after reload (tests that need an exact count
            // start from a fresh writer).
            count: 0,
        })
    }

    /// The leaf type this writer encodes.
    pub fn leaf_type(&self) -> CowLeafType {
        self.leaf_type
    }

    /// Number of live keys (only authoritative for a writer built fresh with
    /// [`Self::new`]; a [`Self::load`]ed writer starts its counter at 0).
    pub fn count(&self) -> u64 {
        self.count
    }

    /// The currently published B-tree root page (0 = empty namespace).
    pub fn committed_root(&self) -> u64 {
        match self.committed_slot() {
            None => 0,
            Some(0) => self.root0,
            Some(_) => self.root1,
        }
    }

    /// The commit id of the published root (0 = never committed).
    pub fn committed_commit_id(&self) -> u64 {
        match self.committed_slot() {
            None => 0,
            Some(0) => self.commit0,
            Some(_) => self.commit1,
        }
    }

    /// The serialised on-disk page image (a copy of the page buffer). This is
    /// exactly what [`super::cow_namespace_reader::CowNamespaceReader::open`]
    /// consumes and what a persist-mode overlay flush writes into the `.ct`.
    pub fn serialize(&self) -> Vec<u8> {
        self.pages.clone()
    }

    /// Insert (or update) `key → descriptor` copy-on-write and atomically commit
    /// a new root. Returns the new commit id.
    ///
    /// Mirrors the Nim `insertAndCommit`: copy-on-write the spine from the OLD
    /// committed root to a NEW root, publish the new root into the unused slot
    /// with a higher commit id, then reclaim the superseded pages into the
    /// unified free list.
    pub fn insert_and_commit(&mut self, key: u64, descriptor: &[u8]) -> Result<u64, CowWriteError> {
        if descriptor.len() != self.descriptor_size {
            return Err(CowWriteError::DescriptorSize {
                got: descriptor.len(),
                expected: self.descriptor_size,
            });
        }
        let old_root = self.committed_root();
        let old_slot = self.committed_slot();

        let new_root;
        let mut is_update = false;
        if old_root == 0 {
            // Empty namespace: create the first leaf as the new root.
            let leaf = self.alloc_page();
            self.write_leaf(leaf, &[key], &[descriptor.to_vec()]);
            new_root = leaf;
        } else {
            let res = self.cow_insert(old_root, key, descriptor);
            is_update = res.was_update;
            if res.did_split {
                let np = self.alloc_page();
                self.write_internal(np, &[res.promoted_key], &[res.new_page, res.right_page]);
                new_root = np;
            } else {
                new_root = res.new_page;
            }
        }

        // Publish into the unused slot with a higher commit id (double buffering).
        let new_commit = self.last_commit + 1;
        self.last_commit = new_commit;
        let write_slot = match old_slot {
            None => 0,
            Some(s) => 1 - s,
        };
        if write_slot == 0 {
            self.root0 = new_root;
            self.commit0 = new_commit;
        } else {
            self.root1 = new_root;
            self.commit1 = new_commit;
        }

        if !is_update {
            self.count += 1;
        }

        // Reclaim pages reachable from the OLD root but not the NEW root. The
        // Rust replay-time writer is the single writer with no concurrent reader
        // pinned to the same live tree, so eager reclamation is safe (no MVCC
        // gating needed here — see the module doc).
        if old_root != 0 {
            let old_pages = self.collect_reachable(old_root);
            let new_pages = self.collect_reachable(new_root);
            for p in old_pages {
                if !new_pages.contains(&p) {
                    self.push_free_page(p);
                }
            }
        }

        self.write_header();
        Ok(new_commit)
    }

    // ── committed-root selection ────────────────────────────────────────────

    /// The slot (0 or 1) holding the highest valid commit id, or `None` if the
    /// tree has never been committed.
    fn committed_slot(&self) -> Option<usize> {
        if self.commit0 == 0 && self.commit1 == 0 {
            None
        } else if self.commit1 > self.commit0 {
            Some(1)
        } else {
            Some(0)
        }
    }

    // ── header (page 0) ─────────────────────────────────────────────────────

    fn write_header(&mut self) {
        self.pages[0..4].copy_from_slice(&HDR_MAGIC);
        write_u64(&mut self.pages, OFF_ROOT0, self.root0);
        write_u64(&mut self.pages, OFF_ROOT1, self.root1);
        write_u64(&mut self.pages, OFF_COMMIT0, self.commit0);
        write_u64(&mut self.pages, OFF_COMMIT1, self.commit1);
        let mut flags = self.leaf_type as u8;
        if self.skip_sub_blocks {
            flags |= 0b10;
        }
        self.pages[OFF_FLAGS] = flags;
        write_u64(&mut self.pages, OFF_FREE_HEAD, self.free_list_head);
        write_u64(&mut self.pages, OFF_NEXT_FREE, self.next_free_page);
        // page_count = total pages currently in the buffer.
        let page_count = (self.pages.len() / PAGE_SIZE) as u64;
        write_u64(&mut self.pages, OFF_PAGE_COUNT, page_count);
    }

    // ── page allocation (unified free list + bump fallback) ─────────────────

    fn page_base(page: u64) -> usize {
        page as usize * PAGE_SIZE
    }

    fn ensure_capacity(&mut self, page: u64) {
        let needed = (page as usize + 1) * PAGE_SIZE;
        if self.pages.len() < needed {
            self.pages.resize(needed, 0);
        }
    }

    /// Pop a page off the whole-block free list, or `None` if empty. The in-page
    /// next pointer (first 8 bytes) names the successor.
    fn pop_free_page(&mut self) -> Option<u64> {
        if self.free_list_head == 0 {
            return None;
        }
        let page = self.free_list_head;
        let base = Self::page_base(page);
        self.free_list_head = read_u64(&self.pages, base);
        Some(page)
    }

    /// Push a page onto the whole-block free list. The freed page's first 8 bytes
    /// become the next-pointer to the old head. The page is zeroed first so a
    /// reused page never leaks stale node bytes.
    fn push_free_page(&mut self, page: u64) {
        let base = Self::page_base(page);
        for b in &mut self.pages[base..base + PAGE_SIZE] {
            *b = 0;
        }
        let head = self.free_list_head;
        write_u64(&mut self.pages, base, head);
        self.free_list_head = page;
    }

    /// Allocate a fresh, zero-filled page: pop the unified free list first, else
    /// bump-allocate via the next-free cursor (§10).
    fn alloc_page(&mut self) -> u64 {
        if let Some(reused) = self.pop_free_page() {
            let base = Self::page_base(reused);
            for b in &mut self.pages[base..base + PAGE_SIZE] {
                *b = 0;
            }
            return reused;
        }
        let page = self.next_free_page;
        self.next_free_page += 1;
        self.ensure_capacity(page);
        let base = Self::page_base(page);
        for b in &mut self.pages[base..base + PAGE_SIZE] {
            *b = 0;
        }
        page
    }

    fn copy_page(&mut self, src: u64) -> u64 {
        // `alloc_page` may grow/reuse the buffer, so snapshot the source bytes
        // first, then allocate the destination and copy into it.
        let sb = Self::page_base(src);
        let src_bytes = self.pages[sb..sb + PAGE_SIZE].to_vec();
        let dst = self.alloc_page();
        let db = Self::page_base(dst);
        self.pages[db..db + PAGE_SIZE].copy_from_slice(&src_bytes);
        dst
    }

    // ── node read/write helpers ─────────────────────────────────────────────

    fn node_is_leaf(&self, page: u64) -> bool {
        self.pages[Self::page_base(page)] == KIND_LEAF
    }

    fn node_count(&self, page: u64) -> usize {
        read_u16(&self.pages, Self::page_base(page) + 2) as usize
    }

    fn set_node_header(&mut self, page: u64, is_leaf: bool, count: usize) {
        let base = Self::page_base(page);
        self.pages[base] = if is_leaf { KIND_LEAF } else { KIND_INTERNAL };
        self.pages[base + 1] = 0;
        write_u16(&mut self.pages, base + 2, count as u16);
        for b in &mut self.pages[base + 4..base + 8] {
            *b = 0;
        }
    }

    fn node_key(&self, page: u64, i: usize) -> u64 {
        read_u64(&self.pages, Self::page_base(page) + NODE_HEADER_BYTES + i * 8)
    }

    fn node_child(&self, page: u64, count: usize, i: usize) -> u64 {
        read_u64(
            &self.pages,
            Self::page_base(page) + NODE_HEADER_BYTES + count * 8 + i * 8,
        )
    }

    fn lower_bound(&self, page: u64, count: usize, key: u64) -> usize {
        let mut lo = 0;
        let mut hi = count;
        while lo < hi {
            let mid = (lo + hi) >> 1;
            if self.node_key(page, mid) < key {
                lo = mid + 1;
            } else {
                hi = mid;
            }
        }
        lo
    }

    fn write_leaf(&mut self, page: u64, keys: &[u64], descs: &[Vec<u8>]) {
        self.set_node_header(page, true, keys.len());
        let base = Self::page_base(page);
        for (i, k) in keys.iter().enumerate() {
            write_u64(&mut self.pages, base + NODE_HEADER_BYTES + i * 8, *k);
        }
        let desc_base = base + NODE_HEADER_BYTES + keys.len() * 8;
        for (i, d) in descs.iter().enumerate() {
            let off = desc_base + i * self.descriptor_size;
            for b in 0..self.descriptor_size {
                self.pages[off + b] = if b < d.len() { d[b] } else { 0 };
            }
        }
    }

    fn write_internal(&mut self, page: u64, keys: &[u64], children: &[u64]) {
        self.set_node_header(page, false, keys.len());
        let base = Self::page_base(page);
        for (i, k) in keys.iter().enumerate() {
            write_u64(&mut self.pages, base + NODE_HEADER_BYTES + i * 8, *k);
        }
        let child_base = base + NODE_HEADER_BYTES + keys.len() * 8;
        for (i, c) in children.iter().enumerate() {
            write_u64(&mut self.pages, child_base + i * 8, *c);
        }
    }

    fn read_leaf(&self, page: u64) -> (Vec<u64>, Vec<Vec<u8>>) {
        let count = self.node_count(page);
        let mut keys = Vec::with_capacity(count);
        let mut descs = Vec::with_capacity(count);
        let base = Self::page_base(page);
        for i in 0..count {
            keys.push(self.node_key(page, i));
            let off = base + NODE_HEADER_BYTES + count * 8 + i * self.descriptor_size;
            descs.push(self.pages[off..off + self.descriptor_size].to_vec());
        }
        (keys, descs)
    }

    fn read_internal(&self, page: u64) -> (Vec<u64>, Vec<u64>) {
        let count = self.node_count(page);
        let mut keys = Vec::with_capacity(count);
        let mut children = Vec::with_capacity(count + 1);
        for i in 0..count {
            keys.push(self.node_key(page, i));
        }
        for i in 0..=count {
            children.push(self.node_child(page, count, i));
        }
        (keys, children)
    }

    fn cow_insert(&mut self, page: u64, key: u64, desc: &[u8]) -> CowInsert {
        if self.node_is_leaf(page) {
            let (mut keys, mut descs) = self.read_leaf(page);
            let idx = self.lower_bound(page, keys.len(), key);
            if idx < keys.len() && keys[idx] == key {
                // Update existing key — still CoW: write to a fresh page.
                descs[idx] = desc.to_vec();
                let np = self.copy_page(page);
                self.write_leaf(np, &keys, &descs);
                return CowInsert {
                    new_page: np,
                    did_split: false,
                    was_update: true,
                    promoted_key: 0,
                    right_page: 0,
                };
            }
            keys.insert(idx, key);
            descs.insert(idx, desc.to_vec());
            let np = self.alloc_page();
            if keys.len() > self.order {
                let mid = keys.len() / 2;
                let promoted = keys[mid];
                let right_page = self.alloc_page();
                self.write_leaf(np, &keys[0..mid], &descs[0..mid]);
                self.write_leaf(right_page, &keys[mid..], &descs[mid..]);
                return CowInsert {
                    new_page: np,
                    did_split: true,
                    was_update: false,
                    promoted_key: promoted,
                    right_page,
                };
            }
            self.write_leaf(np, &keys, &descs);
            CowInsert {
                new_page: np,
                did_split: false,
                was_update: false,
                promoted_key: 0,
                right_page: 0,
            }
        } else {
            let (mut keys, mut children) = self.read_internal(page);
            let mut idx = self.lower_bound(page, keys.len(), key);
            if idx < keys.len() && keys[idx] == key {
                idx += 1;
            }
            let sub = self.cow_insert(children[idx], key, desc);
            children[idx] = sub.new_page; // copy-up: redirect to the new child
            if sub.did_split {
                keys.insert(idx, sub.promoted_key);
                children.insert(idx + 1, sub.right_page);
                if keys.len() > self.order {
                    let mid = keys.len() / 2;
                    let promoted = keys[mid];
                    let np = self.alloc_page();
                    let right_page = self.alloc_page();
                    self.write_internal(np, &keys[0..mid], &children[0..mid + 1]);
                    self.write_internal(right_page, &keys[mid + 1..], &children[mid + 1..]);
                    return CowInsert {
                        new_page: np,
                        did_split: true,
                        was_update: sub.was_update,
                        promoted_key: promoted,
                        right_page,
                    };
                }
            }
            let np = self.alloc_page();
            self.write_internal(np, &keys, &children);
            CowInsert {
                new_page: np,
                did_split: false,
                was_update: sub.was_update,
                promoted_key: 0,
                right_page: 0,
            }
        }
    }

    fn collect_reachable(&self, root: u64) -> Vec<u64> {
        let mut out = Vec::new();
        if root == 0 {
            return out;
        }
        let mut stack = vec![root];
        while let Some(page) = stack.pop() {
            out.push(page);
            if !self.node_is_leaf(page) {
                let count = self.node_count(page);
                for i in 0..=count {
                    stack.push(self.node_child(page, count, i));
                }
            }
        }
        out
    }
}

#[cfg(test)]
#[allow(clippy::expect_used, clippy::unwrap_used)]
mod tests {
    use super::super::cow_namespace_reader::{CowNamespaceReader, CowNsError};
    use super::*;

    #[test]
    fn writer_round_trips_through_reader() {
        let mut w = CowNamespaceWriter::new(CowLeafType::TypeA, false);
        // Insert enough keys to force leaf + internal splits.
        for k in 0u64..400 {
            let desc = (k * 7).to_le_bytes();
            w.insert_and_commit(k, &desc).expect("insert");
        }
        // Update one existing key (must stay CoW + readable).
        w.insert_and_commit(123, &999u64.to_le_bytes()).expect("update");

        let image = w.serialize();
        let r = CowNamespaceReader::open(&image, CowLeafType::TypeA).expect("open");
        assert_eq!(r.key_count().expect("count"), 400);
        for k in 0u64..400 {
            let expected = if k == 123 { 999u64 } else { k * 7 };
            assert_eq!(r.lookup(k).expect("lookup"), &expected.to_le_bytes());
        }
        assert_eq!(r.lookup(10_000), Err(CowNsError::KeyNotFound(10_000)));
    }

    #[test]
    fn free_list_reclaims_superseded_pages() {
        // After many commits the page buffer should not grow without bound:
        // superseded spine pages return to the free list and get reused.
        let mut w = CowNamespaceWriter::new(CowLeafType::TypeA, false);
        for k in 0u64..50 {
            w.insert_and_commit(k, &k.to_le_bytes()).expect("insert");
        }
        let pages_after_fill = w.serialize().len() / PAGE_SIZE;
        // Now do many UPDATES of an existing key: each supersedes the spine but
        // reclaims it, so the buffer must not grow.
        for _ in 0..200 {
            w.insert_and_commit(25, &7u64.to_le_bytes()).expect("update");
        }
        let pages_after_updates = w.serialize().len() / PAGE_SIZE;
        assert_eq!(
            pages_after_fill, pages_after_updates,
            "repeated updates must reuse reclaimed pages, not grow the buffer"
        );
        let image2 = w.serialize();
        let r = CowNamespaceReader::open(&image2, CowLeafType::TypeA).expect("open");
        assert_eq!(r.lookup(25).expect("lookup"), &7u64.to_le_bytes());
    }

    #[test]
    fn reload_resumes_commits() {
        let mut w = CowNamespaceWriter::new(CowLeafType::TypeA, false);
        for k in 0u64..20 {
            w.insert_and_commit(k, &k.to_le_bytes()).expect("insert");
        }
        let image = w.serialize();
        let prior_commit = w.committed_commit_id();

        // Reload and append more keys.
        let mut w2 = CowNamespaceWriter::load(&image, CowLeafType::TypeA).expect("load");
        assert_eq!(w2.committed_commit_id(), prior_commit);
        for k in 20u64..40 {
            w2.insert_and_commit(k, &(k * 2).to_le_bytes()).expect("insert");
        }
        let image2 = w2.serialize();
        let r = CowNamespaceReader::open(&image2, CowLeafType::TypeA).expect("open");
        for k in 0u64..20 {
            assert_eq!(r.lookup(k).expect("lookup"), &k.to_le_bytes());
        }
        for k in 20u64..40 {
            assert_eq!(r.lookup(k).expect("lookup"), &(k * 2).to_le_bytes());
        }
    }

    #[test]
    fn type_b_descriptors_round_trip() {
        let mut w = CowNamespaceWriter::new(CowLeafType::TypeB, true);
        for k in 0u64..30 {
            let mut desc = [0u8; 16];
            desc[0..8].copy_from_slice(&k.to_le_bytes());
            desc[8..16].copy_from_slice(&(k + 1000).to_le_bytes());
            w.insert_and_commit(k, &desc).expect("insert");
        }
        let image = w.serialize();
        let r = CowNamespaceReader::open(&image, CowLeafType::TypeB).expect("open");
        for k in 0u64..30 {
            let d = r.lookup(k).expect("lookup");
            assert_eq!(&d[0..8], &k.to_le_bytes());
            assert_eq!(&d[8..16], &(k + 1000).to_le_bytes());
        }
    }

    #[test]
    fn rejects_wrong_descriptor_size() {
        let mut w = CowNamespaceWriter::new(CowLeafType::TypeA, false);
        assert_eq!(
            w.insert_and_commit(1, &[0u8; 4]),
            Err(CowWriteError::DescriptorSize { got: 4, expected: 8 })
        );
    }
}
