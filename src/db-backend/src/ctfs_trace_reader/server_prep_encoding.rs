//! M5 — the authoritative `memwrites.tc` / `linehits.tc` flat byte encoders.
//!
//! ## Why this module exists
//!
//! The M5 collapse-to-full (MCR-Omniscient-DB-Algorithms.md §2.4 "Collapse-to-full")
//! must emit a region's merged maps **byte-identical** to what server-side
//! per-slice prep produces (Omniscient-DB-Server-Side-Prep.md §6.2 slice-summary →
//! §6.3 coordinator reduce — `encode_memwrites` / `encode_linehits`). That
//! byte-identity is the load-bearing invariant (§6.7.3): a locally lazy-populated
//! and collapsed slice and a server-prepped slice are then **interchangeable and
//! forward-compatible** — one can replace the other page-for-page.
//!
//! ## Where the authoritative byte layout lives
//!
//! The on-disk `memwrites.tc` namespace is the M18 write log emitted by the Nim
//! recorder's `WriteLogWriter` (`codetracer-native-recorder/ct_emulator/src/
//! ct_emulator/write_log.nim`), driven for finalize/prep by
//! `mcrOmniscientWriteToPath` (`.../ct_emulator/src/ct_emulator/omniscient_db_ffi.nim`).
//! The `linehits.tc` sidecar is the `LHTS|v1` format defined in that same
//! `omniscient_db_ffi.nim`. Both are little-endian throughout.
//!
//! This module ports those two byte layouts into Rust so the Rust-side collapse
//! (which runs in the db-backend over the M2 overlay, with no FFI round-trip into
//! Nim) can emit exactly the same bytes. The layout constants and field order
//! below are pinned to the exact Nim source so the two encoders cannot drift; the
//! [`tests`] module asserts the produced bytes against independently-constructed
//! golden vectors derived straight from the documented format (not from a second
//! call of these same functions), and a Nim-written fixture cross-read
//! (`tests/collapse_server_prep_crossread_test.rs`) closes the loop when the
//! fixture is present.
//!
//! ### `memwrites.tc` — the `WLOG` write-log format
//!
//! ```text
//! Header (32 bytes):
//!   magic           u8[4]  = "WLOG"          (write_log.nim:41)
//!   version         u32 LE = 1               (write_log.nim:42)
//!   write_count     u64 LE                   (write_log.nim:463)
//!   snapshot_count  u64 LE                   (write_log.nim:464)
//!   call_count      u64 LE                   (write_log.nim:465)
//! Records (tagged stream; collapse emits ONLY write records):
//!   for each write (write_log.nim:370-376):
//!     tag           u8     = 1  (tagWrite)
//!     tick          u64 LE
//!     pc            u64 LE
//!     address       u64 LE
//!     size          u8
//!     old_value     u64 LE
//!     new_value     u64 LE
//! ```
//!
//! A collapsed `memwrites.tc` carries no register snapshots and no call records
//! (those are not part of the per-key write maps being collapsed), so
//! `snapshot_count` and `call_count` are 0 and only `tagWrite` records follow the
//! header — matching what `mcrOmniscientWriteToPath` emits when the in-shim store
//! holds writes only.
//!
//! ### `linehits.tc` — the `LHTS|v1` format
//!
//! ```text
//!   magic     u8[4]  = "LHTS"                (omniscient_db_ffi.nim:242)
//!   version   u32 LE = 1                     (omniscient_db_ffi.nim:243)
//!   entries   u64 LE  (number of (file_id, line) groups)
//!   for each entry (omniscient_db_ffi.nim:289-294):
//!     file_id u32 LE
//!     line    u32 LE
//!     count   u64 LE
//!     ticks   u64[count] LE
//! ```

use super::interval_tagged_map::{LineHitEntry, MemWriteEntry};

/// `memwrites.tc` write-log magic (`write_log.nim` `WriteLogMagic`).
pub const WLOG_MAGIC: [u8; 4] = *b"WLOG";
/// `memwrites.tc` write-log version (`write_log.nim` `WriteLogVersion`).
pub const WLOG_VERSION: u32 = 1;
/// Write-log header size in bytes (`write_log.nim` `HeaderSize`).
pub const WLOG_HEADER_SIZE: usize = 32;
/// Record tag for a memory write (`write_log.nim` `RecordTag.tagWrite`).
pub const WLOG_TAG_WRITE: u8 = 1;

/// `linehits.tc` sidecar magic (`omniscient_db_ffi.nim` `LineHitsMagic`).
pub const LHTS_MAGIC: [u8; 4] = *b"LHTS";
/// `linehits.tc` sidecar version (`omniscient_db_ffi.nim` `LineHitsVersion`).
pub const LHTS_VERSION: u32 = 1;

/// One flat, tick-sorted per-address write list — the collapse output for one
/// `memwrites.tc` key. The address is carried alongside so the encoder can emit
/// records in `(address, tick)` order (the §6.3 reduce sort key).
#[derive(Debug, Clone)]
pub struct CollapsedMemwrites {
    /// `(address, tick-sorted writes for that address)`, **ascending by address**.
    ///
    /// Must already be sorted by address (the namespace key) with each per-address
    /// list tick-sorted, so the emitted record stream is in `(address, tick)`
    /// order — byte-identical to `global_writes.sort_by(|w| (w.address, w.tick))`
    /// followed by `encode_memwrites` (Omniscient-DB-Server-Side-Prep.md §6.3).
    pub per_address: Vec<(u64, Vec<MemWriteEntry>)>,
}

/// One flat, tick-sorted per-line hit list — the collapse output for one
/// `linehits.tc` key.
#[derive(Debug, Clone)]
pub struct CollapsedLinehits {
    /// `(file_id, line, tick-sorted hit ticks)`, ascending by `(file_id, line)`.
    pub per_line: Vec<(u32, u32, Vec<u64>)>,
}

/// Encode a collapsed `memwrites.tc` region to the authoritative `WLOG` byte
/// layout (Omniscient-DB-Server-Side-Prep.md §6.3 `encode_memwrites`).
///
/// Emits the 32-byte header (with the exact write count, and zero snapshot/call
/// counts — collapse carries writes only) followed by one `tagWrite` record per
/// write, in `(address, tick)` order.
pub fn encode_memwrites(collapsed: &CollapsedMemwrites) -> Vec<u8> {
    let write_count: u64 = collapsed.per_address.iter().map(|(_, w)| w.len() as u64).sum();

    // Header: 32 bytes (magic 4 + version 4 + 3×u64).
    let mut out = Vec::with_capacity(WLOG_HEADER_SIZE + (write_count as usize) * 42);
    out.extend_from_slice(&WLOG_MAGIC);
    out.extend_from_slice(&WLOG_VERSION.to_le_bytes());
    out.extend_from_slice(&write_count.to_le_bytes());
    out.extend_from_slice(&0u64.to_le_bytes()); // snapshot_count
    out.extend_from_slice(&0u64.to_le_bytes()); // call_count

    // Records: one tagWrite per write, address-major, tick-minor.
    for (address, writes) in &collapsed.per_address {
        for w in writes {
            out.push(WLOG_TAG_WRITE);
            out.extend_from_slice(&w.tick.to_le_bytes());
            out.extend_from_slice(&w.pc.to_le_bytes());
            out.extend_from_slice(&address.to_le_bytes());
            // size is a u8 on disk (write_log.nim:374); the in-memory MemWriteEntry
            // carries it widened to u32, so narrow it back. Sizes are 1/2/4/8/16.
            out.push(w.size as u8);
            out.extend_from_slice(&w.old_value.to_le_bytes());
            out.extend_from_slice(&w.new_value.to_le_bytes());
        }
    }
    out
}

/// Encode a collapsed `linehits.tc` region to the authoritative `LHTS|v1` byte
/// layout (Omniscient-DB-Server-Side-Prep.md §6.3 `encode_linehits`).
pub fn encode_linehits(collapsed: &CollapsedLinehits) -> Vec<u8> {
    let entries = collapsed.per_line.len() as u64;
    let mut out = Vec::new();
    out.extend_from_slice(&LHTS_MAGIC);
    out.extend_from_slice(&LHTS_VERSION.to_le_bytes());
    out.extend_from_slice(&entries.to_le_bytes());
    for (file_id, line, ticks) in &collapsed.per_line {
        out.extend_from_slice(&file_id.to_le_bytes());
        out.extend_from_slice(&line.to_le_bytes());
        out.extend_from_slice(&(ticks.len() as u64).to_le_bytes());
        for t in ticks {
            out.extend_from_slice(&t.to_le_bytes());
        }
    }
    out
}

/// Decode a `WLOG` `memwrites.tc` image back into per-address write lists.
///
/// The inverse of [`encode_memwrites`], used by the warm-restart / cross-read
/// path to confirm a persisted collapsed region reads back the same writes. Only
/// `tagWrite` records are interpreted; snapshot/call records (absent in collapse
/// output) are rejected as unexpected so a malformed image fails loudly rather
/// than silently truncating.
pub fn decode_memwrites(image: &[u8]) -> Result<Vec<(u64, MemWriteEntry)>, String> {
    if image.len() < WLOG_HEADER_SIZE {
        return Err(format!("WLOG image too small: {} bytes", image.len()));
    }
    if image[0..4] != WLOG_MAGIC {
        return Err("WLOG bad magic".to_string());
    }
    let version = u32::from_le_bytes([image[4], image[5], image[6], image[7]]);
    if version != WLOG_VERSION {
        return Err(format!("WLOG bad version {version}"));
    }
    let write_count = u64::from_le_bytes(image[8..16].try_into().map_err(|_| "WLOG count slice")?);

    let mut pos = WLOG_HEADER_SIZE;
    let mut out = Vec::with_capacity(write_count as usize);
    let read_u64 = |buf: &[u8], at: usize| -> Result<u64, String> {
        buf.get(at..at + 8)
            .and_then(|s| s.try_into().ok())
            .map(u64::from_le_bytes)
            .ok_or_else(|| format!("WLOG truncated at {at}"))
    };
    while pos < image.len() {
        let tag = image[pos];
        pos += 1;
        if tag != WLOG_TAG_WRITE {
            return Err(format!("WLOG unexpected record tag {tag} (collapse emits writes only)"));
        }
        let tick = read_u64(image, pos)?;
        pos += 8;
        let pc = read_u64(image, pos)?;
        pos += 8;
        let address = read_u64(image, pos)?;
        pos += 8;
        let size = *image.get(pos).ok_or("WLOG truncated size")?;
        pos += 1;
        let old_value = read_u64(image, pos)?;
        pos += 8;
        let new_value = read_u64(image, pos)?;
        pos += 8;
        out.push((
            address,
            MemWriteEntry {
                tick,
                pc,
                size: size as u32,
                old_value,
                new_value,
            },
        ));
    }
    if out.len() as u64 != write_count {
        return Err(format!("WLOG write_count {write_count} != decoded {}", out.len()));
    }
    Ok(out)
}

/// Decode an `LHTS|v1` `linehits.tc` image back into per-line tick lists.
pub fn decode_linehits(image: &[u8]) -> Result<Vec<(u32, u32, Vec<u64>)>, String> {
    if image.len() < 16 {
        return Err(format!("LHTS image too small: {} bytes", image.len()));
    }
    if image[0..4] != LHTS_MAGIC {
        return Err("LHTS bad magic".to_string());
    }
    let version = u32::from_le_bytes([image[4], image[5], image[6], image[7]]);
    if version != LHTS_VERSION {
        return Err(format!("LHTS bad version {version}"));
    }
    let entries = u64::from_le_bytes(image[8..16].try_into().map_err(|_| "LHTS entries slice")?);
    let mut pos = 16usize;
    let mut out = Vec::with_capacity(entries as usize);
    let read_u32 = |buf: &[u8], at: usize| -> Result<u32, String> {
        buf.get(at..at + 4)
            .and_then(|s| s.try_into().ok())
            .map(u32::from_le_bytes)
            .ok_or_else(|| format!("LHTS truncated u32 at {at}"))
    };
    let read_u64 = |buf: &[u8], at: usize| -> Result<u64, String> {
        buf.get(at..at + 8)
            .and_then(|s| s.try_into().ok())
            .map(u64::from_le_bytes)
            .ok_or_else(|| format!("LHTS truncated u64 at {at}"))
    };
    for _ in 0..entries {
        let file_id = read_u32(image, pos)?;
        pos += 4;
        let line = read_u32(image, pos)?;
        pos += 4;
        let count = read_u64(image, pos)?;
        pos += 8;
        let mut ticks = Vec::with_capacity(count as usize);
        for _ in 0..count {
            ticks.push(read_u64(image, pos)?);
            pos += 8;
        }
        out.push((file_id, line, ticks));
    }
    Ok(out)
}

/// Build a [`CollapsedLinehits`] from `LineHitEntry` per-line lists. A thin
/// adapter so the collapse driver (which holds `LineHitEntry` records) and the
/// encoder (which wants raw ticks) stay decoupled.
pub fn collapsed_linehits_from_entries(per_line: Vec<(u32, u32, Vec<LineHitEntry>)>) -> CollapsedLinehits {
    CollapsedLinehits {
        per_line: per_line
            .into_iter()
            .map(|(file_id, line, hits)| (file_id, line, hits.into_iter().map(|h| h.tick).collect()))
            .collect(),
    }
}

#[cfg(test)]
#[allow(clippy::unwrap_used, clippy::expect_used)]
mod tests {
    use super::*;

    fn mw(tick: u64, pc: u64, size: u32, old_value: u64, new_value: u64) -> MemWriteEntry {
        MemWriteEntry {
            tick,
            pc,
            size,
            old_value,
            new_value,
        }
    }

    /// The encoded `memwrites.tc` header + one record matches a golden byte
    /// vector constructed straight from the documented `WLOG` layout (NOT from a
    /// second call of `encode_memwrites`), so any drift in the encoder's field
    /// order / widths is caught.
    #[test]
    fn memwrites_bytes_match_golden_layout() {
        let collapsed = CollapsedMemwrites {
            per_address: vec![(0x4000u64, vec![mw(42, 0xDEAD_BEEF, 4, 0x1111, 0x2222)])],
        };
        let got = encode_memwrites(&collapsed);

        // Golden: 32-byte header + one 42-byte tagWrite record.
        let mut want = Vec::new();
        want.extend_from_slice(b"WLOG");
        want.extend_from_slice(&1u32.to_le_bytes()); // version
        want.extend_from_slice(&1u64.to_le_bytes()); // write_count
        want.extend_from_slice(&0u64.to_le_bytes()); // snapshot_count
        want.extend_from_slice(&0u64.to_le_bytes()); // call_count
        want.push(1u8); // tagWrite
        want.extend_from_slice(&42u64.to_le_bytes()); // tick
        want.extend_from_slice(&0xDEAD_BEEFu64.to_le_bytes()); // pc
        want.extend_from_slice(&0x4000u64.to_le_bytes()); // address
        want.push(4u8); // size
        want.extend_from_slice(&0x1111u64.to_le_bytes()); // old_value
        want.extend_from_slice(&0x2222u64.to_le_bytes()); // new_value

        assert_eq!(got, want, "memwrites WLOG bytes must match the documented layout");
        assert_eq!(got.len(), WLOG_HEADER_SIZE + 42);
    }

    /// `linehits.tc` bytes match a golden `LHTS|v1` vector.
    #[test]
    fn linehits_bytes_match_golden_layout() {
        let collapsed = CollapsedLinehits {
            per_line: vec![(7, 100, vec![1234, 1235])],
        };
        let got = encode_linehits(&collapsed);

        let mut want = Vec::new();
        want.extend_from_slice(b"LHTS");
        want.extend_from_slice(&1u32.to_le_bytes()); // version
        want.extend_from_slice(&1u64.to_le_bytes()); // entries
        want.extend_from_slice(&7u32.to_le_bytes()); // file_id
        want.extend_from_slice(&100u32.to_le_bytes()); // line
        want.extend_from_slice(&2u64.to_le_bytes()); // count
        want.extend_from_slice(&1234u64.to_le_bytes());
        want.extend_from_slice(&1235u64.to_le_bytes());

        assert_eq!(got, want, "linehits LHTS bytes must match the documented layout");
    }

    /// Round-trip: encode → decode reproduces the per-address writes.
    #[test]
    fn memwrites_round_trip() {
        let collapsed = CollapsedMemwrites {
            per_address: vec![
                (0x1000, vec![mw(10, 0xA, 8, 0, 1), mw(20, 0xB, 8, 1, 2)]),
                (0x2000, vec![mw(15, 0xC, 4, 5, 6)]),
            ],
        };
        let image = encode_memwrites(&collapsed);
        let decoded = decode_memwrites(&image).expect("decode");
        // Records come back in (address, tick) order.
        let keyed: Vec<(u64, u64)> = decoded.iter().map(|(a, w)| (*a, w.tick)).collect();
        assert_eq!(keyed, vec![(0x1000, 10), (0x1000, 20), (0x2000, 15)]);
        assert_eq!(decoded[1].1.new_value, 2);
    }

    /// `decode_memwrites` rejects a non-write record tag loudly.
    #[test]
    fn decode_rejects_unexpected_tag() {
        let mut image = encode_memwrites(&CollapsedMemwrites { per_address: vec![] });
        image.push(2u8); // tagSnapshot — must not silently truncate
        assert!(decode_memwrites(&image).is_err());
    }
}
