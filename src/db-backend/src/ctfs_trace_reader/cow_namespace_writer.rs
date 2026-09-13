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
    /// [`CowNamespaceWriter::bulk_load`] was called on a writer that is not a
    /// pristine, never-committed tree. Bulk load is a constructor, not a merge.
    BulkLoadNotPristine,
    /// [`CowNamespaceWriter::bulk_load`]'s batch was not strictly ascending by
    /// key (unsorted, or carrying a duplicate) at this entry index.
    BulkLoadNotAscending(usize),
    /// Internal invariant violated: the bottom-up build did not land exactly in
    /// the page budget [`CowNamespaceWriter::bulk_load_image_len`] predicted.
    ///
    /// Surfaced as an error rather than ignored because callers size payload
    /// offsets against that prediction before the index is built — an image
    /// whose length disagrees with it would place every payload offset wrong
    /// while still being a structurally valid `NSB1` image, i.e. it would
    /// corrupt silently.
    BulkLoadPageBudget {
        /// The image length [`CowNamespaceWriter::bulk_load_image_len`] predicted.
        predicted: usize,
        /// The image length the build actually produced.
        actual: usize,
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
            CowWriteError::BulkLoadNotPristine => {
                write!(f, "cow-namespace bulk load requires a fresh, never-committed tree")
            }
            CowWriteError::BulkLoadNotAscending(i) => {
                write!(f, "cow-namespace bulk load batch not strictly ascending at entry {i}")
            }
            CowWriteError::BulkLoadPageBudget { predicted, actual } => write!(
                f,
                "cow-namespace bulk load produced {actual} bytes, predicted {predicted}"
            ),
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
        let order = Self::order_for(leaf_type);
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
        let order = Self::order_for(leaf_type);
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

    // ── bulk load — bottom-up single-pass constructor ───────────────────────
    //
    // [`Self::insert_and_commit`] is the incremental path: each call copy-on-write
    // copies the spine from root to the touched leaf and atomically publishes a
    // NEW root, so building a tree of N keys does N spine-copies + N atomic
    // commits — O(N log N) page writes and N commit-id increments, with every
    // superseded intermediate spine page accumulating in the buffer. It is the
    // right shape when keys arrive one at a time over the life of a session; it
    // is the wrong shape for writing out a finished map.
    //
    // [`Self::bulk_load`] builds the SAME logical tree from a PRE-SORTED batch in
    // one bottom-up pass: pack the leaves left-to-right, build each internal level
    // over the level below, then publish the single final root in ONE commit. It
    // allocates only the LIVE pages (no abandoned spine copies), so the image is
    // both produced in O(N) and is markedly smaller.
    //
    // WIRE-FORMAT NOTE: the produced image is the SAME `NSB1` wire format every
    // other path emits — a valid namespace header (page 0) selecting a committed
    // root in slot 0 with `commit_id == 1`, plus a well-formed immutable page
    // graph in the documented leaf/internal node layout
    // (`ctfs-container.md` §8, and [`super::cow_namespace_reader`]'s header doc).
    // It is therefore read identically by [`super::cow_namespace_reader::CowNamespaceReader`]
    // and the Nim `loadCowBTree`; only the page PACKING differs from a per-key
    // build (denser, no superseded pages), NOT the format. A bulk-built and a
    // per-key-built tree of the same keys are value- and reader-equivalent but
    // NOT byte-identical — the per-key image carries abandoned CoW pages, a
    // higher commit id, and an alternating root slot. Equivalence between the two
    // must therefore be checked on DECODED content, never on bytes.
    //
    // The B-tree separator invariant the lookup relies on: for an internal node
    // with keys `[s0, s1, …]` and children `[c0, c1, …, cn]`, `lookup(key)` takes
    // the `lower_bound(key)` index `i` and descends into `c_{i+1}` when
    // `key == s_i`, else `c_i`. Splits promote the FIRST key of a right leaf
    // (B+-tree-style copy-up), so the separator before child `c` is the SMALLEST
    // key in `c`'s subtree — which is exactly what is used here.
    //
    // Mirrors the Nim `bulkLoad` in
    // `codetracer-trace-format-nim/src/codetracer_ctfs/cow_btree.nim`.

    /// Max keys per node for a given leaf type — the node fan-out both the
    /// incremental and the bulk build honour.
    fn order_for(leaf_type: CowLeafType) -> usize {
        (PAGE_SIZE - NODE_HEADER_BYTES) / (8 + leaf_type.descriptor_size())
    }

    /// The exact byte length of the page image [`Self::bulk_load`] produces for
    /// `key_count` keys, without building it.
    ///
    /// Bulk load allocates only live pages, bump-allocated from page 1, so the
    /// image length is a pure function of the key count and the leaf type. A
    /// caller that has to know where the B-tree image ends *before* it can fill
    /// in descriptors — e.g. one appending a variable-size payload after the
    /// page-aligned index and storing `(offset, len)` in each descriptor — can
    /// use this instead of building a throwaway tree just to measure it.
    ///
    /// An empty batch yields the header page alone.
    pub fn bulk_load_image_len(leaf_type: CowLeafType, key_count: usize) -> usize {
        if key_count == 0 {
            return PAGE_SIZE;
        }
        let order = Self::order_for(leaf_type);
        // The leaf level: consecutive runs of at most `order` keys.
        let mut level = key_count.div_ceil(order);
        let mut nodes = level;
        // Each internal level groups up to `order + 1` children from the level
        // below, until a single root remains.
        while level > 1 {
            level = level.div_ceil(order + 1);
            nodes += level;
        }
        // Page 0 is the header; nodes occupy pages 1..=nodes.
        (1 + nodes) * PAGE_SIZE
    }

    /// Build a committed tree from a PRE-SORTED, duplicate-free batch of
    /// `(key, descriptor)` entries in a single bottom-up pass, publishing ONE
    /// commit (id 1, slot 0). `self` MUST be a fresh, never-committed writer (as
    /// from [`Self::new`]) — bulk load is a constructor, not a merge.
    ///
    /// Requirements, all validated up front so a violation is an error and never
    /// a silent mis-build: the writer has no prior commit or allocation;
    /// `entries` is strictly ascending by key (sorted, no duplicates); every
    /// descriptor is exactly the leaf type's descriptor width. An empty batch
    /// leaves the namespace empty ([`Self::committed_root`] `== 0`), matching a
    /// per-key build of zero keys, and returns commit id 0.
    ///
    /// Returns the new commit id (always 1 for a non-empty batch).
    pub fn bulk_load<D: AsRef<[u8]>>(&mut self, entries: &[(u64, D)]) -> Result<u64, CowWriteError> {
        if self.committed_slot().is_some()
            || self.count != 0
            || self.next_free_page != 1
            || self.pages.len() != PAGE_SIZE
        {
            return Err(CowWriteError::BulkLoadNotPristine);
        }

        // Validate the batch up front (correct descriptor width; ascending, unique).
        for (i, (key, desc)) in entries.iter().enumerate() {
            let got = desc.as_ref().len();
            if got != self.descriptor_size {
                return Err(CowWriteError::DescriptorSize {
                    got,
                    expected: self.descriptor_size,
                });
            }
            if i > 0 && *key <= entries[i - 1].0 {
                return Err(CowWriteError::BulkLoadNotAscending(i));
            }
        }

        if entries.is_empty() {
            // Nothing to commit: leave the empty namespace as-is (no root published).
            self.write_header();
            return Ok(0);
        }

        // Pre-size the page buffer so the bottom-up pass does no incremental
        // growth at all (the incremental path's `ensure_capacity` reallocations
        // are exactly the copying this constructor exists to avoid).
        let predicted = Self::bulk_load_image_len(self.leaf_type, entries.len());
        self.pages.resize(predicted, 0);

        // ---- pack the leaf level ------------------------------------------
        // Split the sorted entries into consecutive runs of at most `order` keys,
        // each written into a freshly allocated leaf page. Remember each leaf's
        // FIRST key (its subtree minimum) — the separator material for the level
        // above.
        //
        // `(page, min_key)` per node of the level being built.
        let mut level: Vec<(u64, u64)> = Vec::with_capacity(entries.len().div_ceil(self.order));
        for run in entries.chunks(self.order) {
            let page = self.alloc_page();
            self.write_leaf_entries(page, run);
            level.push((page, run[0].0));
        }

        // ---- build internal levels until a single root remains ------------
        // Each internal node groups up to `order + 1` children from the level
        // below (so up to `order` separator keys). The separator before child `c`
        // is `c`'s subtree minimum — the smallest key reachable through it.
        let mut keys: Vec<u64> = Vec::with_capacity(self.order);
        let mut children: Vec<u64> = Vec::with_capacity(self.order + 1);
        while level.len() > 1 {
            let mut parent: Vec<(u64, u64)> = Vec::with_capacity(level.len().div_ceil(self.order + 1));
            for group in level.chunks(self.order + 1) {
                keys.clear();
                children.clear();
                for (g, &(page, min_key)) in group.iter().enumerate() {
                    children.push(page);
                    if g > 0 {
                        // Separator before this child == the child's subtree minimum.
                        keys.push(min_key);
                    }
                }
                let page = self.alloc_page();
                self.write_internal(page, &keys, &children);
                // The group's subtree minimum is the leftmost child's minimum.
                parent.push((page, group[0].1));
            }
            level = parent;
        }

        // ---- publish the single root in one commit (slot 0, id 1) ---------
        // `level` is non-empty here: the leaf level had at least one page and the
        // loop above only ever replaces a level with a strictly smaller non-empty
        // one, stopping at length 1.
        let root = level[0].0;
        self.root0 = root;
        self.commit0 = 1;
        self.last_commit = 1;
        self.count = entries.len() as u64;
        self.write_header();

        // The pre-size above means the buffer can only have grown past
        // `predicted` if the page-count formula UNDER-counted, which is the one
        // direction that silently invalidates a caller's payload offsets. Report
        // it instead of handing back a plausible-looking image.
        if self.pages.len() != predicted {
            return Err(CowWriteError::BulkLoadPageBudget {
                predicted,
                actual: self.pages.len(),
            });
        }
        Ok(1)
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

    /// Write a leaf straight out of a `(key, descriptor)` run, without first
    /// splitting it into parallel key / descriptor vectors. Same on-page layout
    /// as [`Self::write_leaf`]; this is the shape [`Self::bulk_load`] has its
    /// data in, and going through it avoids a per-entry copy of every
    /// descriptor.
    fn write_leaf_entries<D: AsRef<[u8]>>(&mut self, page: u64, entries: &[(u64, D)]) {
        self.set_node_header(page, true, entries.len());
        let base = Self::page_base(page);
        let desc_base = base + NODE_HEADER_BYTES + entries.len() * 8;
        for (i, (key, desc)) in entries.iter().enumerate() {
            write_u64(&mut self.pages, base + NODE_HEADER_BYTES + i * 8, *key);
            // The batch is validated to carry exactly `descriptor_size` bytes per
            // entry before any page is written, so this is a straight copy.
            let off = desc_base + i * self.descriptor_size;
            self.pages[off..off + self.descriptor_size].copy_from_slice(desc.as_ref());
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

    // ── bulk load ───────────────────────────────────────────────────────────

    /// Build `n` keys through `bulk_load` and read every one of them back out
    /// through the production reader.
    fn bulk_build(leaf_type: CowLeafType, n: u64) -> Vec<u8> {
        let width = leaf_type.descriptor_size();
        let entries: Vec<(u64, Vec<u8>)> = (0..n).map(|k| (k * 3, desc_for(k, width))).collect();
        let mut w = CowNamespaceWriter::new(leaf_type, false);
        assert_eq!(w.bulk_load(&entries).expect("bulk load"), if n == 0 { 0 } else { 1 });
        assert_eq!(w.count(), n);
        w.serialize()
    }

    /// A deterministic descriptor of the leaf type's width, derived from the key.
    fn desc_for(k: u64, width: usize) -> Vec<u8> {
        let mut d = vec![0u8; width];
        d[0..8].copy_from_slice(&(k * 7 + 1).to_le_bytes());
        if width >= 16 {
            d[8..16].copy_from_slice(&(k + 1_000_000).to_le_bytes());
        }
        d
    }

    /// Every key of a bulk-built tree resolves to its own descriptor, across
    /// cardinalities spanning a single leaf, a two-level and a three-level tree,
    /// for both descriptor widths. A missing key still reports as missing.
    #[test]
    fn bulk_load_round_trips_every_key_through_the_reader() {
        for leaf_type in [CowLeafType::TypeA, CowLeafType::TypeB] {
            let order = CowNamespaceWriter::order_for(leaf_type) as u64;
            let width = leaf_type.descriptor_size();
            // 1 leaf; exactly one full leaf; two leaves; a full second level; and
            // past it, which forces a third level.
            for n in [
                1,
                2,
                order,
                order + 1,
                2 * order,
                order * (order + 1),
                order * (order + 1) + 1,
            ] {
                let image = bulk_build(leaf_type, n);
                let r = CowNamespaceReader::open(&image, leaf_type).expect("open");
                assert_eq!(r.key_count().expect("count"), n as usize, "n={n} {leaf_type:?}");
                assert_eq!(r.commit_id(), 1, "bulk load publishes exactly one commit");
                assert_eq!(
                    r.keys().expect("keys"),
                    (0..n).map(|k| k * 3).collect::<Vec<_>>(),
                    "n={n} {leaf_type:?}"
                );
                for k in 0..n {
                    assert_eq!(
                        r.lookup(k * 3).expect("lookup"),
                        desc_for(k, width).as_slice(),
                        "key {k} of n={n} {leaf_type:?}"
                    );
                }
                // A key between two present keys (the stride is 3) is absent.
                assert_eq!(r.lookup(1), Err(CowNsError::KeyNotFound(1)), "n={n} {leaf_type:?}");
                assert_eq!(
                    r.lookup(n * 3 + 100),
                    Err(CowNsError::KeyNotFound(n * 3 + 100)),
                    "n={n} {leaf_type:?}"
                );
            }
        }
    }

    /// THE SEPARATOR INVARIANT, pinned directly. The bottom-up build uses each
    /// child's subtree MINIMUM as the separator in front of it, and the reader
    /// descends right on an exact separator match. A separator key is therefore
    /// the one class of key a wrong convention (e.g. promoting the left child's
    /// maximum) still stores in a leaf but can no longer reach — the lookup would
    /// silently miss rather than error. So: harvest the actual separators out of
    /// the built internal nodes and assert each one resolves.
    #[test]
    fn bulk_load_lookup_reaches_every_separator_key() {
        let leaf_type = CowLeafType::TypeB;
        let order = CowNamespaceWriter::order_for(leaf_type) as u64;
        // Big enough for three levels, so both internal levels carry separators.
        let n = order * (order + 1) + 5;
        let image = bulk_build(leaf_type, n);
        let r = CowNamespaceReader::open(&image, leaf_type).expect("open");

        // Walk every internal node of the image and collect its separator keys.
        let mut separators: Vec<u64> = Vec::new();
        let mut stack = vec![r.root_page()];
        while let Some(page) = stack.pop() {
            let base = page as usize * PAGE_SIZE;
            let node = &image[base..base + PAGE_SIZE];
            let count = read_u16(node, 2) as usize;
            if node[0] == KIND_LEAF {
                continue;
            }
            for i in 0..count {
                separators.push(read_u64(node, NODE_HEADER_BYTES + i * 8));
            }
            for c in 0..=count {
                stack.push(read_u64(node, NODE_HEADER_BYTES + count * 8 + c * 8));
            }
        }
        assert!(
            separators.len() > order as usize,
            "a three-level tree must carry separators on both internal levels, found {}",
            separators.len()
        );
        for s in separators {
            assert_eq!(
                r.lookup(s).expect("a separator key must still resolve"),
                desc_for(s / 3, leaf_type.descriptor_size()).as_slice(),
                "separator {s} resolved to the wrong descriptor"
            );
        }
    }

    /// DECODED equivalence, not byte equivalence. A bulk-built and a per-key-built
    /// tree over the same batch are value- and reader-equivalent, but the per-key
    /// image is deliberately NOT byte-identical: it carries a higher commit id,
    /// an alternating root slot, and the pages its spine copies left behind. This
    /// test asserts both halves of that — identical decoded content, and a
    /// genuinely different (and larger) image — so neither claim can rot.
    #[test]
    fn bulk_load_and_per_key_build_are_reader_equivalent_but_not_byte_identical() {
        let leaf_type = CowLeafType::TypeB;
        let width = leaf_type.descriptor_size();
        let n = 5_000u64;
        let entries: Vec<(u64, Vec<u8>)> = (0..n).map(|k| (k * 3, desc_for(k, width))).collect();

        let bulk = {
            let mut w = CowNamespaceWriter::new(leaf_type, true);
            w.bulk_load(&entries).expect("bulk load");
            w.serialize()
        };
        let per_key = {
            let mut w = CowNamespaceWriter::new(leaf_type, true);
            for (key, desc) in &entries {
                w.insert_and_commit(*key, desc).expect("insert");
            }
            w.serialize()
        };

        let rb = CowNamespaceReader::open(&bulk, leaf_type).expect("open bulk");
        let rp = CowNamespaceReader::open(&per_key, leaf_type).expect("open per-key");

        // Decoded content is identical, key for key and byte for byte per descriptor.
        assert_eq!(rb.keys().expect("bulk keys"), rp.keys().expect("per-key keys"));
        assert_eq!(rb.key_count().expect("bulk count"), n as usize);
        assert_eq!(rp.key_count().expect("per-key count"), n as usize);
        for (key, desc) in &entries {
            assert_eq!(rb.lookup(*key).expect("bulk lookup"), desc.as_slice());
            assert_eq!(rp.lookup(*key).expect("per-key lookup"), desc.as_slice());
        }

        // The images are NOT the same bytes, and the difference is the documented
        // one: one commit vs one per key, and a smaller image.
        assert_ne!(bulk, per_key, "the two packings must not be byte-identical");
        assert_eq!(rb.commit_id(), 1, "bulk load publishes exactly one commit");
        assert_eq!(rp.commit_id(), n, "the per-key build publishes one commit per key");
        assert!(
            bulk.len() < per_key.len(),
            "bulk image {} must be smaller than the per-key image {}",
            bulk.len(),
            per_key.len()
        );
    }

    /// `bulk_load_image_len` is what callers size payload offsets against BEFORE
    /// the index exists, so it has to predict the built image exactly — an
    /// over- or under-estimate silently misplaces every payload offset while
    /// still producing a structurally valid `NSB1` image. Swept over the awkward
    /// cardinalities: the level boundaries, and one either side of each.
    #[test]
    fn bulk_load_image_len_predicts_the_built_image_exactly() {
        for leaf_type in [CowLeafType::TypeA, CowLeafType::TypeB] {
            let order = CowNamespaceWriter::order_for(leaf_type) as u64;
            let mut cardinalities: Vec<u64> = vec![0, 1, 2, 3];
            for boundary in [order, 2 * order, order * (order + 1), order * (order + 1) + order] {
                cardinalities.extend([boundary - 1, boundary, boundary + 1]);
            }
            for n in cardinalities {
                let image = bulk_build(leaf_type, n);
                assert_eq!(
                    image.len(),
                    CowNamespaceWriter::bulk_load_image_len(leaf_type, n as usize),
                    "predicted length disagrees with the built image at n={n} {leaf_type:?}"
                );
            }
        }
    }

    /// An empty batch commits nothing, matching a per-key build of zero keys.
    #[test]
    fn bulk_load_of_an_empty_batch_leaves_the_namespace_empty() {
        let mut w = CowNamespaceWriter::new(CowLeafType::TypeB, true);
        let empty: [(u64, [u8; 16]); 0] = [];
        assert_eq!(w.bulk_load(&empty).expect("bulk load"), 0);
        assert_eq!(w.committed_root(), 0);
        assert_eq!(w.committed_commit_id(), 0);
        assert_eq!(w.count(), 0);
        let image = w.serialize();
        assert_eq!(&image[0..4], b"NSB1");
        assert_eq!(image.len(), PAGE_SIZE);
        assert_eq!(
            CowNamespaceReader::open(&image, CowLeafType::TypeB).err(),
            Some(CowNsError::Empty)
        );
    }

    /// Every precondition bulk load cannot build correctly is rejected up front,
    /// so a violation can never become a silently mis-built tree.
    #[test]
    fn bulk_load_rejects_a_batch_it_cannot_build_correctly() {
        let d = |k: u64| {
            let mut b = [0u8; 16];
            b[0..8].copy_from_slice(&k.to_le_bytes());
            b
        };

        // Descending / unsorted.
        let mut w = CowNamespaceWriter::new(CowLeafType::TypeB, true);
        assert_eq!(
            w.bulk_load(&[(5, d(5)), (3, d(3))]),
            Err(CowWriteError::BulkLoadNotAscending(1))
        );
        // A duplicate key is not strictly ascending either.
        let mut w = CowNamespaceWriter::new(CowLeafType::TypeB, true);
        assert_eq!(
            w.bulk_load(&[(1, d(1)), (4, d(4)), (4, d(4))]),
            Err(CowWriteError::BulkLoadNotAscending(2))
        );
        // Wrong descriptor width.
        let mut w = CowNamespaceWriter::new(CowLeafType::TypeB, true);
        assert_eq!(
            w.bulk_load(&[(1, [0u8; 8])]),
            Err(CowWriteError::DescriptorSize { got: 8, expected: 16 })
        );
        // Not a pristine tree: bulk load is a constructor, not a merge.
        let mut w = CowNamespaceWriter::new(CowLeafType::TypeB, true);
        w.insert_and_commit(1, &d(1)).expect("insert");
        assert_eq!(w.bulk_load(&[(9, d(9))]), Err(CowWriteError::BulkLoadNotPristine));
        // Nor after a previous bulk load.
        let mut w = CowNamespaceWriter::new(CowLeafType::TypeB, true);
        w.bulk_load(&[(1, d(1))]).expect("first bulk load");
        assert_eq!(w.bulk_load(&[(9, d(9))]), Err(CowWriteError::BulkLoadNotPristine));

        // A rejected batch must not have published anything.
        let mut w = CowNamespaceWriter::new(CowLeafType::TypeB, true);
        assert!(w.bulk_load(&[(5, d(5)), (3, d(3))]).is_err());
        assert_eq!(w.committed_root(), 0);
    }

    /// The incremental path still works on a tree, and still works after a bulk
    /// load hands it a starting image: bulk load ADDS a batch constructor, it
    /// does not replace the per-key path. A reloaded bulk image accepts further
    /// incremental commits and both key sets read back.
    #[test]
    fn incremental_commits_resume_on_top_of_a_bulk_loaded_image() {
        let leaf_type = CowLeafType::TypeB;
        let width = leaf_type.descriptor_size();
        let entries: Vec<(u64, Vec<u8>)> = (0..2_000u64).map(|k| (k * 3, desc_for(k, width))).collect();
        let mut w = CowNamespaceWriter::new(leaf_type, true);
        w.bulk_load(&entries).expect("bulk load");
        let image = w.serialize();

        let mut w2 = CowNamespaceWriter::load(&image, leaf_type).expect("load");
        assert_eq!(w2.committed_commit_id(), 1);
        for k in 0..50u64 {
            // Keys interleaved between the bulk-loaded ones (stride 3).
            w2.insert_and_commit(k * 3 + 1, &desc_for(k + 9_000, width))
                .expect("insert");
        }
        let image2 = w2.serialize();
        let r = CowNamespaceReader::open(&image2, leaf_type).expect("open");
        assert_eq!(r.key_count().expect("count"), 2_050);
        for (key, d) in &entries {
            assert_eq!(r.lookup(*key).expect("bulk key"), d.as_slice(), "bulk key {key}");
        }
        for k in 0..50u64 {
            assert_eq!(
                r.lookup(k * 3 + 1).expect("incremental key"),
                desc_for(k + 9_000, width).as_slice()
            );
        }
    }
}
