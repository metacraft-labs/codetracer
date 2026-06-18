//! M32 — distributed omniscient-DB recorder + db-backend round trips.
//!
//! Closes the recorder-side `slice-summary.tc` writer + db-backend
//! reader deferred items per the M32 milestone status note in
//! `codetracer-specs/Planned-Features/Value-Origin-Tracking.milestones.org`.
//! The four tests below exercise the round-trip contracts:
//!
//! 1. `test_slice_summary_writer_round_trips_to_disk` — Nim
//!    recorder-side writer emits an SSUM|v1 blob whose header,
//!    address set, last-write-per-address bucket, and line-hit
//!    triples match the .NET `SliceSummaryCodec.Decode` shape.
//! 2. `test_global_memwrites_loader_round_trips_through_trait` —
//!    a hand-rolled GMWR|v1 blob is loaded via the FFI and the
//!    trait surface serves the records.
//! 3. `test_partial_global_memwrites_loader_surfaces_gap_list` —
//!    a hand-rolled PMWR|v1 blob is loaded and the partial-gap
//!    accessors enumerate the failed slice's tick range.
//! 4. `test_load_sharded_omniscient_namespaces_prefers_global` —
//!    the M32 db-backend integration shim prefers
//!    `global-memwrites.tc` over the per-slice `memwrites.tc`
//!    when a sharded recording's coordinator has run.

use db_backend::emulator_ffi;
use db_backend::omniscient_db::{
    CTFS_GLOBAL_MEMWRITES_FILE, CTFS_PARTIAL_GLOBAL_MEMWRITES_FILE, FfiOmniscientDb, OmniscientDb, ShardedLoadOutcome,
    WriteRecord, load_sharded_omniscient_namespaces, omniscient_ffi_lock,
};
use std::io::Read;
use std::sync::Once;

/// One-shot Nim runtime initialiser. The underlying `NimMain` is
/// idempotent at the C level but the `Once` guard keeps the Rust
/// side from invoking it twice across parallel test binaries.
fn ensure_nim_runtime() {
    static ONCE: Once = Once::new();
    ONCE.call_once(|| unsafe {
        emulator_ffi::NimMain();
    });
}

/// Reset every piece of Nim-global state the omniscient + undo-map
/// surface owns. Called at the top of every test so neighbouring
/// tests in the same `cargo test` process never observe leftover
/// fixture data. Mirrors the discipline in `origin_omniscient_test.rs`.
fn reset_omniscient_state() {
    ensure_nim_runtime();
    // SAFETY: idempotent module-level resets; the Nim shims tolerate
    // an uninitialised module state.
    unsafe {
        emulator_ffi::mcrOmniscientReset();
        emulator_ffi::mcrUndoMapReset();
    }
}

// SSUM|v1 / GMWR|v1 / PMWR|v1 byte layouts are documented in
// `codetracer-native-recorder/ct_emulator/src/ct_emulator/omniscient_db_ffi.nim`
// (§ slice-summary writer at line 416, § global memwrites loaders at
// line 597). Both formats are all-little-endian; the decoders + encoders
// below mirror them byte-for-byte so the round-trip tests can verify
// the writer's output without pulling in the .NET binary.

#[derive(Debug, PartialEq, Eq)]
struct SliceSummary {
    slice_index: u32,
    tick_lo: u64,
    tick_hi: u64,
    addresses: Vec<u64>,
    last_write_per_address: Vec<DecodedWrite>,
    line_hits: Vec<(u32, u32, u64)>,
}

#[derive(Debug, PartialEq, Eq)]
struct DecodedWrite {
    address: u64,
    tick: u64,
    pc: u64,
    size: u8,
    new_value: u64,
}

struct Cursor<'a> {
    bytes: &'a [u8],
    pos: usize,
}

impl<'a> Cursor<'a> {
    fn new(bytes: &'a [u8]) -> Self {
        Self { bytes, pos: 0 }
    }

    fn read_array<const N: usize>(&mut self) -> [u8; N] {
        let end = self.pos + N;
        let mut out = [0u8; N];
        out.copy_from_slice(&self.bytes[self.pos..end]);
        self.pos = end;
        out
    }

    fn read_u8(&mut self) -> u8 {
        let v = self.bytes[self.pos];
        self.pos += 1;
        v
    }
    fn read_u32_le(&mut self) -> u32 {
        u32::from_le_bytes(self.read_array::<4>())
    }
    fn read_u64_le(&mut self) -> u64 {
        u64::from_le_bytes(self.read_array::<8>())
    }
}

fn decode_slice_summary(bytes: &[u8]) -> SliceSummary {
    let mut c = Cursor::new(bytes);
    let magic = c.read_array::<4>();
    assert_eq!(&magic, b"SSUM", "SSUM magic must be present");
    let version = c.read_u32_le();
    assert_eq!(version, 1, "SSUM version must be 1");
    let slice_index = c.read_u32_le();
    let tick_lo = c.read_u64_le();
    let tick_hi = c.read_u64_le();
    let addr_count = c.read_u32_le() as usize;
    let mut addresses = Vec::with_capacity(addr_count);
    for _ in 0..addr_count {
        addresses.push(c.read_u64_le());
    }
    let write_count = c.read_u32_le() as usize;
    let mut last_write_per_address = Vec::with_capacity(write_count);
    for _ in 0..write_count {
        let address = c.read_u64_le();
        let tick = c.read_u64_le();
        let pc = c.read_u64_le();
        let size = c.read_u8();
        let new_value = c.read_u64_le();
        last_write_per_address.push(DecodedWrite {
            address,
            tick,
            pc,
            size,
            new_value,
        });
    }
    let linehit_count = c.read_u32_le() as usize;
    let mut line_hits = Vec::with_capacity(linehit_count);
    for _ in 0..linehit_count {
        let file_id = c.read_u32_le();
        let line = c.read_u32_le();
        let tick = c.read_u64_le();
        line_hits.push((file_id, line, tick));
    }
    assert_eq!(c.pos, bytes.len(), "decoder must consume the entire SSUM blob");
    SliceSummary {
        slice_index,
        tick_lo,
        tick_hi,
        addresses,
        last_write_per_address,
        line_hits,
    }
}

fn read_file(path: &std::path::Path) -> Vec<u8> {
    let mut f = std::fs::File::open(path).expect("slice-summary file must exist");
    let mut bytes = Vec::new();
    f.read_to_end(&mut bytes).expect("read slice-summary bytes");
    bytes
}

// ---------------------------------------------------------------------------
// Test 1 — recorder-side writer round-trip.
// ---------------------------------------------------------------------------

#[test]
fn test_slice_summary_writer_round_trips_to_disk() {
    let _guard = omniscient_ffi_lock().lock().unwrap();
    reset_omniscient_state();

    let db = FfiOmniscientDb::new();
    // Seed three writes across two distinct addresses + two line hits.
    // The writer truncates `last_write_per_address` to the most
    // recent tick per address; both addresses must surface and the
    // tick values must match the seeded maxima.
    let recs = [
        WriteRecord {
            tick: 10,
            pc: 0x1000,
            address: 0xCAFE_1000,
            size: 4,
            old_value: 0,
            new_value: 0xA,
        },
        WriteRecord {
            tick: 20,
            pc: 0x1004,
            address: 0xCAFE_1000,
            size: 4,
            old_value: 0xA,
            new_value: 0xB,
        },
        WriteRecord {
            tick: 30,
            pc: 0x2000,
            address: 0xCAFE_2000,
            size: 8,
            old_value: 0,
            new_value: 0xDEAD_BEEF,
        },
    ];
    for rec in &recs {
        assert!(db.push_write(*rec));
    }
    assert!(db.push_line_hit(42, 7, 10));
    assert!(db.push_line_hit(42, 7, 30));
    assert!(db.finalize());

    let dir = tempfile::tempdir().expect("tempdir");
    let path = dir.path().join("slice-summary.tc");
    assert!(
        db.write_slice_summary_to_path(&path, 3, 0, 40),
        "writer must succeed for a populated store",
    );
    let bytes = read_file(&path);
    let summary = decode_slice_summary(&bytes);

    assert_eq!(summary.slice_index, 3);
    assert_eq!(summary.tick_lo, 0);
    assert_eq!(summary.tick_hi, 40);
    assert_eq!(
        summary.addresses,
        vec![0xCAFE_1000u64, 0xCAFE_2000u64],
        "distinct addresses must be sorted ascending",
    );
    // last_write_per_address: 2 entries (one per address), each
    // holding the most recent write at that address.
    assert_eq!(summary.last_write_per_address.len(), 2);
    let by_addr: std::collections::HashMap<u64, &DecodedWrite> =
        summary.last_write_per_address.iter().map(|w| (w.address, w)).collect();
    let lo = by_addr[&0xCAFE_1000u64];
    assert_eq!(lo.tick, 20, "tail-truncated bucket keeps the latest tick");
    assert_eq!(lo.new_value, 0xB);
    let hi = by_addr[&0xCAFE_2000u64];
    assert_eq!(hi.tick, 30);
    assert_eq!(hi.new_value, 0xDEAD_BEEF);
    // line_hits: 2 entries, both for (42, 7), ticks 10 and 30,
    // sorted ascending per the writer's stable-sort discipline.
    assert_eq!(summary.line_hits, vec![(42, 7, 10), (42, 7, 30)]);
}

// GMWR|v1 + PMWR|v1 encoder helpers — small fixtures for the loader
// tests. Mirror the .NET `CoordinatorWorker.EncodeGlobalMemwrites`
// output (per `omniscient_db_ffi.nim:597-628`).

fn put_u32_le(buf: &mut Vec<u8>, v: u32) {
    buf.extend_from_slice(&v.to_le_bytes());
}

fn put_u64_le(buf: &mut Vec<u8>, v: u64) {
    buf.extend_from_slice(&v.to_le_bytes());
}

/// Build a GMWR|v1 blob from `writes`. Each tuple is
/// `(address, tick, pc, size, new_value, source_slice)`. The blob is
/// the byte-for-byte sibling of the .NET coordinator's output.
fn build_gmwr(writes: &[(u64, u64, u64, u8, u64, u32)]) -> Vec<u8> {
    let mut buf = Vec::with_capacity(8 + writes.len() * 37);
    buf.extend_from_slice(b"GMWR");
    put_u32_le(&mut buf, 1);
    put_u32_le(&mut buf, writes.len() as u32);
    for &(address, tick, pc, size, new_value, source_slice) in writes {
        put_u64_le(&mut buf, address);
        put_u64_le(&mut buf, tick);
        put_u64_le(&mut buf, pc);
        buf.push(size);
        put_u64_le(&mut buf, new_value);
        put_u32_le(&mut buf, source_slice);
    }
    buf
}

/// Build a PMWR|v1 blob carrying `gaps` followed by `writes`. Each
/// gap tuple is `(slice_index, tick_lo, tick_hi, has_range)`.
fn build_pmwr(gaps: &[(u32, u64, u64, bool)], writes: &[(u64, u64, u64, u8, u64, u32)]) -> Vec<u8> {
    let mut buf = Vec::with_capacity(8 + gaps.len() * 21 + writes.len() * 37);
    buf.extend_from_slice(b"PMWR");
    put_u32_le(&mut buf, 1);
    put_u32_le(&mut buf, gaps.len() as u32);
    for &(slice_index, tick_lo, tick_hi, has_range) in gaps {
        put_u32_le(&mut buf, slice_index);
        put_u64_le(&mut buf, tick_lo);
        put_u64_le(&mut buf, tick_hi);
        buf.push(if has_range { 1 } else { 0 });
    }
    put_u32_le(&mut buf, writes.len() as u32);
    for &(address, tick, pc, size, new_value, source_slice) in writes {
        put_u64_le(&mut buf, address);
        put_u64_le(&mut buf, tick);
        put_u64_le(&mut buf, pc);
        buf.push(size);
        put_u64_le(&mut buf, new_value);
        put_u32_le(&mut buf, source_slice);
    }
    buf
}

// ---------------------------------------------------------------------------
// Test 2 — global-memwrites loader round-trip.
// ---------------------------------------------------------------------------

#[test]
fn test_global_memwrites_loader_round_trips_through_trait() {
    let _guard = omniscient_ffi_lock().lock().unwrap();
    reset_omniscient_state();

    // Two writes at the same address from sibling slices A and B —
    // the cross-slice reduce scenario the milestone describes: a
    // slice-B query at the higher tick must see the slice-A write
    // that the per-slice index in slice B would have missed.
    let writes = [
        (0xCAFE_F00D_u64, 5, 0x4000, 4, 0xAAAA, 0u32),
        (0xCAFE_F00D_u64, 50, 0x4004, 4, 0xBBBB, 1u32),
    ];
    let blob = build_gmwr(&writes);
    let dir = tempfile::tempdir().expect("tempdir");
    let path = dir.path().join(CTFS_GLOBAL_MEMWRITES_FILE);
    std::fs::write(&path, &blob).expect("write GMWR blob");

    let db = FfiOmniscientDb::new();
    assert!(
        db.load_global_memwrites_from_path(&path),
        "loader must accept the synthetic GMWR blob",
    );
    assert!(db.finalize());

    // A query at tick=100 must see the slice-1 write (tick=50). A
    // query at tick=20 must see the slice-0 write (tick=5).
    let recent = db
        .last_write_before(0xCAFE_F00D, 4, 100)
        .expect("recent write must be discoverable");
    assert_eq!(recent.tick, 50);
    assert_eq!(recent.new_value, 0xBBBB);

    let earlier = db
        .last_write_before(0xCAFE_F00D, 4, 20)
        .expect("earlier write must be discoverable");
    assert_eq!(earlier.tick, 5);
    assert_eq!(earlier.new_value, 0xAAAA);
}

// ---------------------------------------------------------------------------
// Test 3 — partial-global-memwrites loader surfaces gaps.
// ---------------------------------------------------------------------------

#[test]
fn test_partial_global_memwrites_loader_surfaces_gap_list() {
    let _guard = omniscient_ffi_lock().lock().unwrap();
    reset_omniscient_state();

    // Slice 2's prep failed permanently — ticks [25, 49] are a gap.
    // Slice 0 (tick=5) + slice 3 (tick=75) succeeded.
    let gaps = [(2u32, 25u64, 49u64, true)];
    let writes = [
        (0xCAFE_F00D_u64, 5, 0x4000, 4, 0xAAAA, 0u32),
        (0xCAFE_F00D_u64, 75, 0x4008, 4, 0xCCCC, 3u32),
    ];
    let blob = build_pmwr(&gaps, &writes);
    let dir = tempfile::tempdir().expect("tempdir");
    let path = dir.path().join(CTFS_PARTIAL_GLOBAL_MEMWRITES_FILE);
    std::fs::write(&path, &blob).expect("write PMWR blob");

    let db = FfiOmniscientDb::new();
    assert!(
        db.load_partial_global_memwrites_from_path(&path),
        "loader must accept the synthetic PMWR blob",
    );
    assert!(db.finalize());

    // Gap accessor: one gap, slice 2, tick range [25, 49].
    assert_eq!(db.partial_gap_count(), 1);
    let gap = db.partial_gap_at(0).expect("gap 0 present");
    assert_eq!(gap.slice_index, 2);
    assert_eq!(gap.tick_lo, 25);
    assert_eq!(gap.tick_hi, 49);

    // Tick-in-gap classifier: 30 is in the gap, 5 + 75 + 100 are not.
    assert!(db.tick_falls_in_partial_gap(30));
    assert!(!db.tick_falls_in_partial_gap(5));
    assert!(!db.tick_falls_in_partial_gap(75));
    assert!(!db.tick_falls_in_partial_gap(100));

    // Successful slices' writes still serve queries that don't
    // cross the gap.
    let hit = db
        .last_write_before(0xCAFE_F00D, 4, 100)
        .expect("slice-3 write must be discoverable post-PMWR load");
    assert_eq!(hit.tick, 75);
    assert_eq!(hit.new_value, 0xCCCC);
}

// ---------------------------------------------------------------------------
// Test 4 — M32 db-backend integration shim: prefer global over
// per-slice when the coordinator has run.
// ---------------------------------------------------------------------------

#[test]
fn test_load_sharded_omniscient_namespaces_prefers_global() {
    let _guard = omniscient_ffi_lock().lock().unwrap();
    reset_omniscient_state();

    // Recording root that holds both the per-slice and the global
    // artefact. The shim must drive the global loader and report
    // `Global`; the per-slice fallback is the caller's responsibility
    // and is omitted here.
    let dir = tempfile::tempdir().expect("tempdir");
    let writes = [(0xCAFE_F00D_u64, 42, 0x4000, 4, 0xDEAD_BEEF, 0u32)];
    let blob = build_gmwr(&writes);
    std::fs::write(dir.path().join(CTFS_GLOBAL_MEMWRITES_FILE), &blob).expect("write GMWR");

    let db = FfiOmniscientDb::new();
    let outcome = load_sharded_omniscient_namespaces(dir.path(), &db);
    assert_eq!(outcome, ShardedLoadOutcome::Global);
    assert!(db.finalize());
    let hit = db
        .last_write_before(0xCAFE_F00D, 4, 100)
        .expect("global write must be discoverable post-shim load");
    assert_eq!(hit.tick, 42);
    assert_eq!(hit.new_value, 0xDEAD_BEEF);

    // No artefact present → NoGlobalArtefact + the FFI store stays
    // empty. The caller falls back to the per-slice loader.
    reset_omniscient_state();
    let empty_dir = tempfile::tempdir().expect("tempdir");
    let outcome = load_sharded_omniscient_namespaces(empty_dir.path(), &db);
    assert_eq!(outcome, ShardedLoadOutcome::NoGlobalArtefact);
    assert!(
        !db.is_present(),
        "shim must not pull data into the store when no global artefact is present",
    );

    // Partial-only directory → Partial. The successful writes are
    // queryable; the gap list is enumerable through the trait.
    reset_omniscient_state();
    let partial_dir = tempfile::tempdir().expect("tempdir");
    let gaps = [(2u32, 25u64, 49u64, true)];
    let partial_writes = [(0xCAFE_F00D_u64, 75, 0x4008, 4, 0xCCCC, 3u32)];
    let blob = build_pmwr(&gaps, &partial_writes);
    std::fs::write(partial_dir.path().join(CTFS_PARTIAL_GLOBAL_MEMWRITES_FILE), &blob).expect("write PMWR");
    let outcome = load_sharded_omniscient_namespaces(partial_dir.path(), &db);
    assert_eq!(outcome, ShardedLoadOutcome::Partial);
    assert!(db.finalize());
    assert_eq!(db.partial_gap_count(), 1);
    assert!(db.tick_falls_in_partial_gap(30));
}
